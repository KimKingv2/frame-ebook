import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/core/frame_api_client.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/library/frame_reader_repository.dart';
import 'package:frame_ebook/reader/frame_reading_time_tracker.dart';

FrameBook _book() => FrameBook.fromJson({
      'id': 'cloud:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/reading-time.epub',
      'fileName': 'reading-time.epub',
      'title': '閱讀時間測試',
      'format': 'EPUB',
      'shelf': 'books',
      'size': 1024,
    });

void main() {
  test('splits persisted intervals at local midnight and 30 seconds', () async {
    final events = <FrameReadingEvent>[];
    final tracker = FrameReadingTimeTracker(
      book: _book(),
      repository: FrameReaderRepository(_UnusedApi()),
      autoHeartbeat: false,
      writeEvent: (event) async {
        events.add(event);
        return true;
      },
    );
    final start = DateTime(2026, 11, 20, 23, 59, 50);

    await tracker.start(at: start);
    await tracker.tick(at: start.add(const Duration(seconds: 30)));
    await tracker.stop(at: start.add(const Duration(seconds: 30)));

    expect(tracker.sessionSeconds, 30);
    expect(events, hasLength(2));
    expect(events.map((event) => event.seconds).toList(), [10, 20]);
    expect(events.map((event) => event.dayKey).toList(), [
      '2026-11-20',
      '2026-11-21',
    ]);
    expect(events.map((event) => event.localHour).toList(), [23, 0]);
    expect(events.every((event) => event.seconds <= 30), isTrue);
    expect(events.every((event) =>
        event.endedAt - event.startedAt <= 30000), isTrue);
    expect(events.map((event) => event.id).toSet(), hasLength(2));
  });

  test('stops at the five-minute idle deadline and resumes on activity',
      () async {
    final events = <FrameReadingEvent>[];
    final tracker = FrameReadingTimeTracker(
      book: _book(),
      repository: FrameReaderRepository(_UnusedApi()),
      autoHeartbeat: false,
      writeEvent: (event) async {
        events.add(event);
        return true;
      },
    );
    final start = DateTime(2026, 11, 20, 9);

    await tracker.start(at: start);
    for (var seconds = 30; seconds <= 330; seconds += 30) {
      await tracker.tick(at: start.add(Duration(seconds: seconds)));
    }

    expect(tracker.sessionSeconds, 300);
    expect(events.fold<int>(0, (sum, event) => sum + event.seconds), 300);

    tracker.activity(at: start.add(const Duration(seconds: 360)));
    await tracker.tick(at: start.add(const Duration(seconds: 390)));
    expect(tracker.sessionSeconds, 330);

    await tracker.stop(at: start.add(const Duration(seconds: 390)));
    expect(events.fold<int>(0, (sum, event) => sum + event.seconds), 330);
    expect(tracker.isRunning, isFalse);
  });

  test('excludes time while backgrounded and restarts on resume', () async {
    final events = <FrameReadingEvent>[];
    final tracker = FrameReadingTimeTracker(
      book: _book(),
      repository: FrameReaderRepository(_UnusedApi()),
      autoHeartbeat: false,
      writeEvent: (event) async {
        events.add(event);
        return true;
      },
    );
    final start = DateTime(2026, 11, 20, 10);

    await tracker.start(at: start);
    await tracker.tick(at: start.add(const Duration(seconds: 30)));
    await tracker.setForeground(
      false,
      at: start.add(const Duration(seconds: 45)),
    );
    await tracker.tick(at: start.add(const Duration(seconds: 90)));

    expect(tracker.sessionSeconds, 45);

    await tracker.setForeground(
      true,
      at: start.add(const Duration(seconds: 100)),
    );
    await tracker.tick(at: start.add(const Duration(seconds: 130)));
    await tracker.stop(at: start.add(const Duration(seconds: 130)));

    expect(tracker.sessionSeconds, 75);
    expect(events.fold<int>(0, (sum, event) => sum + event.seconds), 75);
  });

  test('starts paused when the reader opens in the background', () async {
    final events = <FrameReadingEvent>[];
    final tracker = FrameReadingTimeTracker(
      book: _book(),
      repository: FrameReaderRepository(_UnusedApi()),
      autoHeartbeat: false,
      writeEvent: (event) async {
        events.add(event);
        return true;
      },
    );
    final start = DateTime(2026, 11, 20, 11);

    await tracker.start(at: start, foreground: false);
    await tracker.tick(at: start.add(const Duration(seconds: 30)));
    expect(tracker.sessionSeconds, 0);
    expect(events, isEmpty);

    await tracker.setForeground(
      true,
      at: start.add(const Duration(seconds: 60)),
    );
    await tracker.tick(at: start.add(const Duration(seconds: 90)));
    await tracker.stop(at: start.add(const Duration(seconds: 90)));

    expect(tracker.sessionSeconds, 30);
    expect(events.fold<int>(0, (sum, event) => sum + event.seconds), 30);
  });

  test('stopping does not wait for a stalled event network request', () async {
    final pendingWrite = Completer<bool>();
    final tracker = FrameReadingTimeTracker(
      book: _book(),
      repository: FrameReaderRepository(_UnusedApi()),
      autoHeartbeat: false,
      writeEvent: (_) => pendingWrite.future,
    );
    final start = DateTime(2026, 11, 20, 12);

    await tracker.start(at: start);
    final pendingTick = tracker.tick(
      at: start.add(const Duration(seconds: 30)),
    );
    await tracker.stop(at: start.add(const Duration(seconds: 30)));

    expect(tracker.isRunning, isFalse);
    expect(tracker.sessionSeconds, 30);

    pendingWrite.complete(true);
    await pendingTick;
  });

  test('rejects a non-cloud book before activating a timer', () async {
    final invalid = FrameBook.fromJson({
      'id': 'local-book-id',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/book.epub',
      'fileName': 'book.epub',
      'format': 'EPUB',
      'shelf': 'books',
      'size': 1,
    });
    final tracker = FrameReadingTimeTracker(
      book: invalid,
      repository: FrameReaderRepository(_UnusedApi()),
      autoHeartbeat: false,
      writeEvent: (_) async => true,
    );

    await expectLater(tracker.start(), throwsArgumentError);
    expect(tracker.isRunning, isFalse);
  });
}

class _UnusedApi implements FrameApiClient {
  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      throw StateError('Unexpected GET $path');

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      throw StateError('Unexpected POST $path');

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async =>
      throw StateError('Unexpected binary POST $path');

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      throw StateError('Unexpected DELETE $path');

  @override
  Future<Uint8List> getBytes(String path) async =>
      throw StateError('Unexpected GET bytes $path');

  @override
  void close() {}
}
