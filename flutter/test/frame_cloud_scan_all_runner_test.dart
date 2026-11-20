import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:frame_ebook/cloud/frame_cloud_models.dart';
import 'package:frame_ebook/cloud/frame_cloud_repository.dart';
import 'package:frame_ebook/cloud/frame_cloud_scan_all_runner.dart';
import 'package:frame_ebook/core/frame_api_client.dart';

class _AllScanApi implements FrameApiClient {
  final Map<String, Map<String, dynamic>> savedStates = {};
  final List<String> completedLibraries = [];
  final List<String> indexedPaths = [];

  String _key(String library, String root) => '$library|$root';

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final uri = Uri.parse('https://frame.test$path');
    if (path.startsWith('/api/cloud/index/state?')) {
      final key = _key(
        uri.queryParameters['library'] ?? '',
        uri.queryParameters['root_path'] ?? '',
      );
      return {'ok': true, 'state': savedStates[key]};
    }
    if (path.startsWith('/api/cloud/scan-list?')) {
      final library = uri.queryParameters['library'] ?? 'books';
      final root = uri.queryParameters['root_path'] ?? '/books';
      final name = library == 'books' ? 'Novel.epub' : 'Comic.cbz';
      final format = library == 'books' ? 'EPUB' : 'CBZ';
      return {
        'ok': true,
        'provider': 'vps',
        'library': library,
        'rootPath': root,
        'path': root,
        'page': 1,
        'perPage': 100,
        'total': 1,
        'items': [
          {
            'name': name,
            'path': '$root/$name',
            'parentPath': root,
            'isDir': false,
            'format': format,
            'size': 1024,
          },
        ],
      };
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path == '/api/cloud/index/state') {
      final state = Map<String, dynamic>.from(body['state'] as Map);
      final library = body['library'] as String;
      final root = body['rootPath'] as String;
      savedStates[_key(library, root)] = state;
      return {'ok': true};
    }
    if (path == '/api/cloud/index/entries') {
      final library = body['library'] as String;
      final entries = (body['entries'] as List).cast<Map<String, dynamic>>();
      indexedPaths.addAll(entries.map((entry) => '$library:${entry['path']}'));
      return {'ok': true, 'saved': entries.length};
    }
    if (path == '/api/cloud/index/complete') {
      completedLibraries.add(body['library'] as String);
      return {'ok': true, 'removed': 0};
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async =>
      {'ok': true};

  @override
  Future<Uint8List> getBytes(String path) async => Uint8List(0);

  @override
  void close() {}
}

void main() {
  test('scans Books first and Comics second through to completion', () async {
    final api = _AllScanApi();
    final runner = FrameCloudScanAllRunner(
      repository: FrameCloudRepository(api),
    );

    final result = await runner.run(
      provider: FrameCloudProvider.vps,
      rootPaths: {
        FrameCloudLibrary.books: '/books',
        FrameCloudLibrary.comics: '/comics',
      },
    );

    expect(result.completed, isTrue);
    expect(result.libraries.map((item) => item.library), [
      FrameCloudLibrary.books,
      FrameCloudLibrary.comics,
    ]);
    expect(api.completedLibraries, ['books', 'comics']);
    expect(api.indexedPaths, [
      'books:/books/Novel.epub',
      'comics:/comics/Comic.cbz',
    ]);
  });

  test('resumes unfinished library without rescanning completed library', () async {
    final api = _AllScanApi();
    final books = FrameCloudScanState.initial(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.books,
      rootPath: '/books',
      scanId: 'books_scan_123456',
    ).copyWith(
      completed: true,
      pendingFolders: const [],
      seenFolders: ['/books'],
    );
    final comics = FrameCloudScanState.initial(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.comics,
      rootPath: '/comics',
      scanId: 'comics_scan_123456',
    );
    api.savedStates['books|/books'] = books.toJson();
    api.savedStates['comics|/comics'] = comics.toJson();

    final runner = FrameCloudScanAllRunner(
      repository: FrameCloudRepository(api),
    );
    final result = await runner.run(
      provider: FrameCloudProvider.vps,
      rootPaths: {
        FrameCloudLibrary.books: '/books',
        FrameCloudLibrary.comics: '/comics',
      },
    );

    expect(result.completed, isTrue);
    expect(result.libraries.first.skippedExisting, isTrue);
    expect(api.completedLibraries, ['comics']);
    expect(api.indexedPaths, ['comics:/comics/Comic.cbz']);
  });

  test('pause between libraries resumes at the unstarted library', () async {
    final api = _AllScanApi();
    final runner = FrameCloudScanAllRunner(
      repository: FrameCloudRepository(api),
    );

    final paused = await runner.run(
      provider: FrameCloudProvider.vps,
      rootPaths: {
        FrameCloudLibrary.books: '/books',
        FrameCloudLibrary.comics: '/comics',
      },
      onProgress: (library, progress) {
        if (library == FrameCloudLibrary.books &&
            progress.phase == '目錄索引完成') {
          runner.requestPause();
        }
      },
    );

    expect(paused.paused, isTrue);
    expect(paused.libraries, hasLength(1));
    expect(paused.libraries.single.library, FrameCloudLibrary.books);
    expect(api.savedStates['comics|/comics'], isNotNull);

    final resumed = await runner.run(
      provider: FrameCloudProvider.vps,
      rootPaths: {
        FrameCloudLibrary.books: '/books',
        FrameCloudLibrary.comics: '/comics',
      },
    );

    expect(resumed.completed, isTrue);
    expect(resumed.libraries.first.skippedExisting, isTrue);
    expect(api.completedLibraries, ['books', 'comics']);
    expect(api.indexedPaths, [
      'books:/books/Novel.epub',
      'comics:/comics/Comic.cbz',
    ]);
  });

  test('clearing error details preserves scan cursor and counters', () {
    final state = FrameCloudScanState.fromJson({
      'version': 1,
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/books',
      'scanId': 'scan_1234567890',
      'pendingFolders': ['/books/Novel'],
      'currentFolder': '/books/Novel',
      'page': 3,
      'seenFolders': ['/books', '/books/Novel'],
      'scannedCount': 24,
      'indexedCount': 12,
      'failedCount': 1,
      'errors': [
        {
          'path': '/books/Novel',
          'message': 'temporary provider error',
          'at': '2026-11-20T12:00:00Z',
        },
      ],
      'lastError': 'temporary provider error',
    });

    final cleared = state.copyWith(
      errors: const [],
      clearLastError: true,
      updatedAt: '2026-11-20T12:01:00Z',
    );

    expect(cleared.errors, isEmpty);
    expect(cleared.raw.containsKey('lastError'), isFalse);
    expect(cleared.currentFolder, '/books/Novel');
    expect(cleared.page, 3);
    expect(cleared.scannedCount, 24);
    expect(cleared.indexedCount, 12);
    expect(cleared.failedCount, 1);
  });
}
