import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:frame_ebook/core/frame_api_client.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/library/frame_reader_repository.dart';

void main() {
  group('FrameReaderRepository', () {
    late _FakeFrameApi api;
    late FrameReaderRepository repository;
    late FrameBook book;

    setUp(() {
      api = _FakeFrameApi();
      repository = FrameReaderRepository(api);
      book = FrameBook.fromJson({
        'id': 'cloud:${List<String>.filled(64, 'a').join()}',
        'provider': 'vps',
        'library': 'books',
        'rootPath': '/電子書',
        'path': '/電子書/測試 書籍.epub',
        'fileName': '測試 書籍.epub',
        'format': 'EPUB',
        'cloudSource': {
          'provider': 'vps',
          'library': 'books',
          'rootPath': '/電子書',
          'path': '/電子書/測試 書籍.epub',
        },
      });
    });

    test('loads state using the existing book descriptor query', () async {
      api.getResponse = {
        'ok': true,
        'state': {
          'progress': {'percent': 42, 'label': '第 3 章', 'cfi': 'epubcfi(/6/8)', 'index': 2},
          'appearance': {'theme': 'sepia'},
        },
      };

      final state = await repository.loadState(book);

      expect(state.progress['percent'], 42);
      expect(state.appearance['theme'], 'sepia');
      final uri = Uri.parse(api.lastGetPath!);
      expect(uri.path, '/api/reading/state');
      expect(uri.queryParameters['book_id'], book.id);
      expect(uri.queryParameters['provider'], 'vps');
      expect(uri.queryParameters['library'], 'books');
      expect(uri.queryParameters['root_path'], '/電子書');
      expect(uri.queryParameters['path'], '/電子書/測試 書籍.epub');
    });

    test('merges progress and appearance instead of replacing old keys', () async {
      api.getResponse = {
        'ok': true,
        'state': {
          'progress': {'percent': 20, 'label': '第 1 章', 'cfi': 'saved-cfi', 'index': 1},
          'appearance': {'theme': 'sepia', 'fontScale': '1.1'},
          'lastOpenedAt': 100,
        },
      };

      final saved = await repository.saveState(
        book,
        progress: {'percent': 55, 'label': '第 4 章'},
        appearance: {'theme': 'night'},
        lastOpenedAt: 200,
      );

      final posted = api.lastPostBody!['state'] as Map<String, dynamic>;
      final progress = posted['progress'] as Map<String, dynamic>;
      final appearance = posted['appearance'] as Map<String, dynamic>;
      expect(progress['percent'], 55);
      expect(progress['cfi'], 'saved-cfi');
      expect(progress['index'], 1);
      expect(appearance['theme'], 'night');
      expect(appearance['fontScale'], '1.1');
      expect(posted['lastOpenedAt'], 200);
      expect(saved.progress['percent'], 55);
    });

    test('loads, saves and deletes annotations through compatible endpoints', () async {
      api.getResponse = {
        'annotations': [
          {
            'id': 'note-0001',
            'bookId': book.id,
            'type': 'note',
            'cfi': 'epubcfi(/6/4)',
            'quote': '原文',
            'text': '我的想法',
            'color': 'violet',
            'createdAt': 123,
            'updatedAt': 124,
          },
        ],
      };

      final loaded = await repository.loadAnnotations(book);
      expect(loaded, hasLength(1));
      expect(loaded.single.text, '我的想法');
      expect(Uri.parse(api.lastGetPath!).queryParameters['book_id'], book.id);

      final annotation = FrameReaderAnnotation(
        id: 'note-0002',
        bookId: book.id,
        type: 'note',
        cfi: 'epubcfi(/6/6)',
        quote: '另一段原文',
        text: '新增筆記',
        color: 'violet',
        createdAt: 200,
      );
      api.postResponse = {'ok': true, 'annotation': annotation.toJson()};
      final saved = await repository.saveAnnotation(book, annotation);
      expect(saved.id, 'note-0002');
      expect(api.lastPostPath, '/api/reading/annotations');
      expect(api.lastPostBody!['book'], book.descriptor());

      await repository.deleteAnnotation(book, 'note-0002');
      expect(api.lastDeletePath, '/api/reading/annotations');
      expect(api.lastDeleteBody!['id'], 'note-0002');
      expect(api.lastDeleteBody!['book'], book.descriptor());
    });

    test('records a bounded reading event', () async {
      api.postResponse = {'accepted': 1, 'ignored': 0};
      final accepted = await repository.recordReadingEvent(
        FrameReadingEvent(
          id: 'event-0001',
          bookId: book.id,
          dayKey: '2026-11-18',
          seconds: 25,
          startedAt: 1000,
          endedAt: 26000,
          localHour: 10,
          bookTitle: '測試書籍',
          format: 'epub',
        ),
      );

      expect(accepted, isTrue);
      expect(api.lastPostPath, '/api/reading/events');
      final events = api.lastPostBody!['events'] as List;
      expect(events.single['format'], 'EPUB');
      expect(events.single['seconds'], 25);
    });

    test('rejects malformed reading events before sending them', () async {
      await expectLater(
        repository.recordReadingEvent(
          FrameReadingEvent(
            id: 'event-0001',
            bookId: book.id,
            dayKey: '2026-11-18',
            seconds: 31,
            startedAt: 1000,
            endedAt: 32000,
            localHour: 10,
          ),
        ),
        throwsArgumentError,
      );
      expect(api.lastPostPath, isNull);
    });
  });
}

class _FakeFrameApi implements FrameApiClient {
  Map<String, dynamic> getResponse = {'ok': true, 'state': <String, dynamic>{}};
  Map<String, dynamic> postResponse = {'ok': true};
  String? lastGetPath;
  String? lastPostPath;
  String? lastDeletePath;
  Map<String, dynamic>? lastPostBody;
  Map<String, dynamic>? lastDeleteBody;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    lastGetPath = path;
    return getResponse;
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    lastPostPath = path;
    lastPostBody = body;
    return postResponse;
  }

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    lastDeletePath = path;
    lastDeleteBody = body;
    return {'ok': true};
  }

  @override
  Future<Uint8List> getBytes(String path) async => Uint8List(0);

  @override
  void close() {}
}
