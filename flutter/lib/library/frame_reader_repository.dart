import 'dart:async';

import '../core/frame_api_client.dart';
import 'frame_book.dart';

Map<String, dynamic> _readerMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

class FrameReaderState {
  FrameReaderState(Map<String, dynamic> json)
      : _data = Map<String, dynamic>.unmodifiable(_readerMap(json));

  final Map<String, dynamic> _data;

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_data);

  Map<String, dynamic> get progress => _readerMap(_data['progress']);
  Map<String, dynamic> get appearance => _readerMap(_data['appearance']);
  Map<String, dynamic> get metadata => _readerMap(_data['metadata']);

  int get lastOpenedAt {
    final value = _data['lastOpenedAt'];
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  FrameReaderState merge({
    Map<String, dynamic>? progress,
    Map<String, dynamic>? appearance,
    Map<String, dynamic>? metadata,
    int? lastOpenedAt,
  }) {
    final next = toJson();
    if (progress != null) {
      next['progress'] = {
        'percent': 0,
        'label': '尚未閱讀',
        'cfi': '',
        'index': null,
        ...this.progress,
        ...progress,
      };
    }
    if (appearance != null) {
      next['appearance'] = {...this.appearance, ...appearance};
    }
    if (metadata != null) {
      next['metadata'] = {...this.metadata, ...metadata};
    }
    if (lastOpenedAt != null) next['lastOpenedAt'] = lastOpenedAt;
    return FrameReaderState(next);
  }

  factory FrameReaderState.fromJson(Map<String, dynamic> json) =>
      FrameReaderState(json);

  factory FrameReaderState.empty() => FrameReaderState(const {});
}

class FrameReaderAnnotation {
  const FrameReaderAnnotation({
    required this.id,
    required this.bookId,
    required this.type,
    required this.cfi,
    this.quote = '',
    this.text = '',
    this.color = 'yellow',
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String bookId;
  final String type;
  final String cfi;
  final String quote;
  final String text;
  final String color;
  final int createdAt;
  final int updatedAt;

  factory FrameReaderAnnotation.fromJson(Map<String, dynamic> json) {
    int integer(dynamic value) {
      if (value is num) return value.round();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return FrameReaderAnnotation(
      id: json['id']?.toString() ?? '',
      bookId: json['bookId']?.toString() ?? '',
      type: json['type']?.toString() ?? 'note',
      cfi: json['cfi']?.toString() ?? '',
      quote: json['quote']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      color: json['color']?.toString() ?? 'yellow',
      createdAt: integer(json['createdAt']),
      updatedAt: integer(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'type': type,
        'cfi': cfi,
        'quote': quote,
        'text': text,
        'color': color,
        'createdAt': createdAt,
      };
}

/// Returns the bookmark saved at an exact EPUB CFI, ignoring notes/highlights.
FrameReaderAnnotation? findFrameBookmarkAtCfi(
  Iterable<FrameReaderAnnotation> annotations,
  String? cfi,
) {
  final target = cfi?.trim() ?? '';
  if (target.isEmpty) return null;
  for (final annotation in annotations) {
    if (annotation.type == 'bookmark' && annotation.cfi.trim() == target) {
      return annotation;
    }
  }
  return null;
}

class FrameReadingEvent {
  const FrameReadingEvent({
    required this.id,
    required this.bookId,
    required this.dayKey,
    required this.seconds,
    required this.startedAt,
    required this.endedAt,
    required this.localHour,
    this.bookTitle = '',
    this.format = 'EPUB',
  });

  final String id;
  final String bookId;
  final String dayKey;
  final int seconds;
  final int startedAt;
  final int endedAt;
  final int localHour;
  final String bookTitle;
  final String format;

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'dayKey': dayKey,
        'seconds': seconds,
        'startedAt': startedAt,
        'endedAt': endedAt,
        'localHour': localHour,
        'bookTitle': bookTitle,
        'format': format.toUpperCase(),
      };
}

/// Typed access to the existing Reading Room APIs.
///
/// The repository deliberately keeps the current D1 contract and cloud book
/// identity unchanged. The reader engine can therefore be migrated in stages
/// without moving source archives or rewriting existing progress/annotations.
class FrameReaderRepository {
  FrameReaderRepository(this.api);

  final FrameApiClient api;
  final Map<String, FrameReaderState> _stateCache = {};
  final Map<String, Future<void>> _stateWriteTails = {};

  String _bookUrl(String endpoint, FrameBook book) {
    final descriptor = book.descriptor();
    final required = ['id', 'provider', 'library', 'rootPath', 'path'];
    for (final key in required) {
      if ((descriptor[key]?.toString() ?? '').trim().isEmpty) {
        throw FrameApiException(message: '閱讀室缺少書籍識別欄位：$key');
      }
    }
    final query = <String, String>{
      'book_id': descriptor['id'].toString(),
      'provider': descriptor['provider'].toString(),
      'library': descriptor['library'].toString(),
      'root_path': descriptor['rootPath'].toString(),
      'path': descriptor['path'].toString(),
    };
    final profileId = descriptor['profileId']?.toString() ?? '';
    final sourceId = descriptor['sourceId']?.toString() ?? '';
    if (profileId.isNotEmpty) query['profile_id'] = profileId;
    if (sourceId.isNotEmpty) query['source_id'] = sourceId;
    return '$endpoint?${Uri(queryParameters: query).query}';
  }

  Future<FrameReaderState> loadState(FrameBook book) async {
    final response = await api.getJson(_bookUrl('/api/reading/state', book));
    final state = FrameReaderState.fromJson(_readerMap(response['state']));
    _stateCache[book.id] = state;
    return state;
  }

  Future<FrameReaderState> saveState(
    FrameBook book, {
    Map<String, dynamic>? progress,
    Map<String, dynamic>? appearance,
    Map<String, dynamic>? metadata,
    int? lastOpenedAt,
  }) {
    final previous = _stateWriteTails[book.id] ?? Future<void>.value();
    final operation = previous.catchError((Object _) {}).then<FrameReaderState>(
      (_) async {
        final current = _stateCache[book.id] ?? await loadState(book);
        final next = current.merge(
          progress: progress,
          appearance: appearance,
          metadata: metadata,
          lastOpenedAt: lastOpenedAt,
        );
        final response = await api.postJson('/api/reading/state', {
          'book': book.descriptor(),
          'state': next.toJson(),
        });
        final saved = FrameReaderState.fromJson(
          response['state'] is Map
              ? _readerMap(response['state'])
              : next.toJson(),
        );
        _stateCache[book.id] = saved;
        return saved;
      },
    );
    _stateWriteTails[book.id] = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<List<FrameReaderAnnotation>> loadAnnotations(FrameBook book) async {
    final response =
        await api.getJson(_bookUrl('/api/reading/annotations', book));
    final raw = response['annotations'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => FrameReaderAnnotation.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList(growable: false);
  }

  Future<FrameReaderAnnotation> saveAnnotation(
    FrameBook book,
    FrameReaderAnnotation annotation,
  ) async {
    if (annotation.bookId != book.id) {
      throw ArgumentError('標註所屬書籍與目前書籍不一致。');
    }
    if (annotation.id.trim().isEmpty ||
        annotation.cfi.trim().isEmpty ||
        !const {'highlight', 'note', 'bookmark'}.contains(annotation.type)) {
      throw ArgumentError('標註識別碼、類型或 EPUB 定位資訊無效。');
    }
    final response = await api.postJson('/api/reading/annotations', {
      'book': book.descriptor(),
      'annotation': annotation.toJson(),
    });
    return FrameReaderAnnotation.fromJson(
      _readerMap(response['annotation']),
    );
  }

  Future<void> deleteAnnotation(FrameBook book, String annotationId) async {
    if (annotationId.trim().isEmpty) {
      throw ArgumentError.value(annotationId, 'annotationId', '不可為空白。');
    }
    await api.deleteJson('/api/reading/annotations', {
      'book': book.descriptor(),
      'id': annotationId,
    });
  }

  Future<bool> recordReadingEvent(FrameReadingEvent event) async {
    if (event.id.length < 8 ||
        !RegExp(r'^cloud:[a-f0-9]{64}$').hasMatch(event.bookId) ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(event.dayKey) ||
        event.seconds < 1 ||
        event.seconds > 30 ||
        event.endedAt < event.startedAt ||
        event.endedAt - event.startedAt > 45000 ||
        event.localHour < 0 ||
        event.localHour > 23) {
      throw ArgumentError('閱讀事件欄位無效。');
    }
    final response = await api.postJson('/api/reading/events', {
      'events': [event.toJson()],
    });
    final accepted = response['accepted'];
    return accepted is num
        ? accepted > 0
        : (int.tryParse(accepted?.toString() ?? '') ?? 0) > 0;
  }

  void clearStateCache() => _stateCache.clear();
}
