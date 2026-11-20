import 'dart:async';

import '../library/frame_book.dart';
import '../library/frame_reader_repository.dart';

/// Records foreground, recently-active reading time through the existing D1 API.
///
/// Events are split into at most 30-second pieces and never cross a local
/// calendar-day boundary. No local event database or persistent queue is used.
class FrameReadingTimeTracker {
  FrameReadingTimeTracker({
    required this.book,
    required this.repository,
    this.onUpdate,
    this.onError,
    DateTime Function()? clock,
    FrameReadingEventWriter? writeEvent,
    this.autoHeartbeat = true,
  })  : _clock = clock ?? DateTime.now,
        _writeEvent = writeEvent ?? repository.recordReadingEvent;

  static const heartbeatInterval = Duration(seconds: 30);
  static const idleLimit = Duration(minutes: 5);
  static const maxTickInterval = Duration(seconds: 60);
  static const eventChunkLimit = Duration(seconds: 30);
  static const cloudRetryDelay = Duration(minutes: 1);

  final FrameBook book;
  final FrameReaderRepository repository;
  final void Function(int)? onUpdate;
  final void Function(Object)? onError;
  final DateTime Function() _clock;
  final FrameReadingEventWriter _writeEvent;
  final bool autoHeartbeat;

  Timer? _timer;
  DateTime? _lastTickAt;
  DateTime? _lastActivityAt;
  DateTime? _cloudBackoffUntil;
  bool _foreground = true;
  bool _tickWasActive = false;
  bool _running = false;
  int _sessionMilliseconds = 0;
  int _eventSequence = 0;
  Future<void> _writeTail = Future<void>.value();

  bool get isRunning => _running;
  int get sessionSeconds => (_sessionMilliseconds / 1000).round();

  bool isActiveAt(DateTime now) =>
      _running &&
      _foreground &&
      _lastActivityAt != null &&
      now.difference(_lastActivityAt!) <= idleLimit;

  Future<void> start({DateTime? at}) async {
    if (_running) await stop(at: at);
    if (!RegExp(r'^cloud:[a-f0-9]{64}$').hasMatch(book.id)) {
      throw ArgumentError('只能為已掃描索引的雲端書籍記錄閱讀時間。');
    }

    final now = at ?? _clock();
    _running = true;
    _foreground = true;
    _sessionMilliseconds = 0;
    _lastTickAt = now;
    _lastActivityAt = now;
    _tickWasActive = true;
    _cloudBackoffUntil = null;
    onUpdate?.call(0);

    if (autoHeartbeat) {
      _timer = Timer.periodic(
        heartbeatInterval,
        (_) => unawaited(tick()),
      );
    }
  }

  /// Call for pointer, keyboard, touch or reader-scroll activity.
  void activity({DateTime? at}) {
    if (!_running || !_foreground) return;
    final now = at ?? _clock();
    _lastActivityAt = now;
    if (!_tickWasActive) {
      // Do not count the idle gap. Start a new interval at this activity.
      _lastTickAt = now;
      _tickWasActive = true;
    }
  }

  /// Changes whether this app/window is in the foreground.
  ///
  /// Leaving the foreground first accounts for the final active interval.
  /// Returning starts a fresh idle window, so time spent in another app/tab is
  /// never counted.
  Future<void> setForeground(bool foreground, {DateTime? at}) async {
    if (!_running || _foreground == foreground) return;
    final now = at ?? _clock();
    if (!foreground) {
      await tick(at: now);
      _foreground = false;
      _tickWasActive = false;
      return;
    }

    _foreground = true;
    _lastTickAt = now;
    _lastActivityAt = now;
    _tickWasActive = true;
    onUpdate?.call(sessionSeconds);
  }

  /// Processes one heartbeat. Exposed for deterministic tests as well as the
  /// periodic timer.
  Future<void> tick({DateTime? at}) async {
    if (!_running) return;
    final now = at ?? _clock();
    final previous = _lastTickAt;
    if (_tickWasActive && previous != null && now.isAfter(previous)) {
      final elapsed = now.difference(previous);
      final counted = elapsed > maxTickInterval ? maxTickInterval : elapsed;
      if (counted > Duration.zero) {
        _sessionMilliseconds += counted.inMilliseconds;
        _queueInterval(previous, previous.add(counted));
        onUpdate?.call(sessionSeconds);
      }
    }

    _lastTickAt = now;
    _tickWasActive = isActiveAt(now);
    await _writeTail;
  }

  Future<void> stop({DateTime? at}) async {
    if (!_running) return;
    final now = at ?? _clock();
    if (_tickWasActive && _foreground) {
      await tick(at: now);
    }

    _timer?.cancel();
    _timer = null;
    _tickWasActive = false;
    _foreground = false;
    _running = false;
    _lastTickAt = null;
    _lastActivityAt = null;
    await _writeTail;
    onUpdate?.call(sessionSeconds);
  }

  void _queueInterval(DateTime start, DateTime end) {
    var cursor = start;
    final sourceTitle = book.title.trim().isEmpty ? book.fileName : book.title;
    final title = sourceTitle.substring(
      0,
      sourceTitle.length.clamp(0, 240).toInt(),
    );
    final format = book.format.toUpperCase();

    while (cursor.isBefore(end)) {
      final midnight = DateTime(cursor.year, cursor.month, cursor.day + 1);
      final chunkLimit = cursor.add(eventChunkLimit);
      final segmentEnd = _minimumDate(_minimumDate(end, midnight), chunkLimit);
      final seconds = segmentEnd.difference(cursor).inSeconds;
      if (seconds > 0) {
        final eventEnd = cursor.add(Duration(seconds: seconds));
        final event = FrameReadingEvent(
          id: _nextEventId(cursor),
          bookId: book.id,
          dayKey: _localDayKey(cursor),
          seconds: seconds.clamp(1, 30).toInt(),
          startedAt: cursor.millisecondsSinceEpoch,
          endedAt: eventEnd.millisecondsSinceEpoch,
          localHour: cursor.hour,
          bookTitle: title,
          format: format,
        );
        _enqueueEvent(event);
        cursor = eventEnd;
      } else {
        // Drop sub-second fragments rather than manufacturing reading time.
        cursor = segmentEnd;
      }
    }
  }

  void _enqueueEvent(FrameReadingEvent event) {
    _writeTail = _writeTail.then((_) async {
      final retryAt = _cloudBackoffUntil;
      if (retryAt != null && _clock().isBefore(retryAt)) return;
      try {
        final accepted = await _writeEvent(event);
        if (!accepted) {
          throw StateError('雲端未接受閱讀事件。');
        }
      } on Object catch (error) {
        _cloudBackoffUntil = _clock().add(cloudRetryDelay);
        onError?.call(error);
      }
    });
  }

  String _nextEventId(DateTime timestamp) {
    _eventSequence++;
    return 'flutter-\${timestamp.microsecondsSinceEpoch}-$_eventSequence';
  }

  static String _localDayKey(DateTime value) =>
      '\${value.year.toString().padLeft(4, '0')}-'
      '\${value.month.toString().padLeft(2, '0')}-'
      '\${value.day.toString().padLeft(2, '0')}';

  static DateTime _minimumDate(DateTime a, DateTime b) =>
      a.isBefore(b) ? a : b;
}

typedef FrameReadingEventWriter = Future<bool> Function(
  FrameReadingEvent event,
);
