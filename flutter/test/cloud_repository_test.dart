import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:frame_ebook/cloud/frame_cloud_models.dart';
import 'package:frame_ebook/cloud/frame_cloud_repository.dart';
import 'package:frame_ebook/core/frame_api_client.dart';

class _FakeApi implements FrameApiClient {
  final List<String> getRequests = [];
  final List<MapEntry<String, Map<String, dynamic>>> postRequests = [];
  final List<(String, Uint8List, String, Map<String, String>)> binaryPosts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    getRequests.add(path);
    if (path.startsWith('/api/cloud/scan-list?')) {
      return {
        'ok': true,
        'provider': 'worker',
        'library': 'books',
        'rootPath': '/books',
        'path': '/books/Novel',
        'page': 2,
        'perPage': 2,
        'total': 5,
        'items': [
          {
            'name': 'Volume 03.epub',
            'path': '/books/Novel/Volume 03.epub',
            'parentPath': '/books/Novel',
            'isDir': false,
            'format': 'EPUB',
            'size': 4096,
          },
        ],
      };
    }
    if (path.startsWith('/api/cloud/books?')) {
      return {
        'ok': true,
        'provider': 'worker',
        'library': 'comics',
        'rootPath': '/comics',
        'path': '/comics',
        'page': 1,
        'perPage': 80,
        'total': 1,
        'indexed': true,
        'scanState': {'completed': true, 'indexedCount': 1},
        'items': [
          {
            'name': 'Series',
            'path': '/comics/Series',
            'parentPath': '/comics',
            'isDir': true,
            'format': '',
            'size': 0,
          },
        ],
      };
    }
    if (path.startsWith('/api/cloud/index/state?')) {
      return {
        'ok': true,
        'state': {
          'version': 1,
          'provider': 'worker',
          'library': 'comics',
          'rootPath': '/comics',
          'scanId': 'scan_1234567890',
          'pendingFolders': ['/comics'],
          'currentFolder': '/comics',
          'page': 3,
          'seenFolders': ['/comics'],
          'scannedCount': 12,
          'indexedCount': 8,
          'skippedCount': 2,
          'failedCount': 2,
          'visitedFolderCount': 4,
          'coverReadyCount': 3,
          'coverMissingCount': 1,
          'coverFailedCount': 1,
          'metadataProcessedCount': 5,
          'metadataFailedCount': 1,
          'pausedByUser': true,
          'resumeOnNextOpen': true,
          'completed': false,
          'errors': [],
          'customCursor': {'providerPage': 27},
        },
      };
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    postRequests.add(MapEntry(path, body));
    if (path == '/api/cloud/index/entries') {
      return {'ok': true, 'saved': (body['entries'] as List).length};
    }
    if (path == '/api/cloud/index/complete') {
      return {'ok': true, 'removed': 4};
    }
    if (path == '/api/cloud/covers') {
      return {'ok': true, 'retried': 2};
    }
    if (path == '/api/cloud/index/metadata') {
      return {'ok': true, 'updated': (body['entries'] as List).length};
    }
    return {'ok': true, 'value': body['value']};
  }

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async {
    binaryPosts.add((path, body, contentType, Map.from(headers)));
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    return {'ok': true};
  }

  @override
  Future<Uint8List> getBytes(String path) async => Uint8List(0);

  @override
  void close() {}
}

void main() {
  test('normalizes absolute paths and rejects parent traversal', () {
    expect(normalizeFrameCloudPath('/books//Novel/'), '/books/Novel');
    expect(normalizeFrameCloudPath('/books/../private'), isNull);
    expect(frameCloudPathIsWithinRoot('/books/Novel/01.epub', '/books'), isTrue);
    expect(frameCloudPathIsWithinRoot('/bookshelf/01.epub', '/books'), isFalse);
  });

  test('loads main provider readiness and source root suggestions', () {
    final session = FrameCloudSession.fromJson({
      'authenticated': true,
      'accessEnabled': true,
      'databaseConfigured': true,
      'cloudReaderDataConfigured': true,
      'cloudAnnotationsConfigured': true,
      'openListProfiles': {
        'vps': {'label': 'VPS Alist', 'configured': true},
        'worker': {'label': 'OpenList Worker', 'configured': false},
        'mobile': {'label': 'Mobile Device Alist', 'configured': true},
      },
      'rootPaths': {
        'books': '/server/books',
        'comics': '/server/comics',
      },
    });

    expect(session.authenticated, isTrue);
    expect(session.accessEnabled, isTrue);
    expect(session.providers[FrameCloudProvider.vps]?.configured, isTrue);
    expect(session.providers[FrameCloudProvider.worker]?.configured, isFalse);
    expect(session.suggestedRoots[FrameCloudLibrary.books], '/server/books');
  });

  test('reads accepted provider root pairs and falls back across providers', () {
    final preferences = FrameCloudPreferences.fromJson({
      'activeProvider': 'worker',
      'activeLibrary': 'comics',
      'goalMinutes': 45,
      'roots': {
        'vps': {
          'books': '/cloud/books',
          'comics': '/cloud/comics',
        },
      },
    });

    expect(preferences.activeProvider, FrameCloudProvider.worker);
    expect(preferences.activeLibrary, FrameCloudLibrary.comics);
    expect(preferences.rootFor(FrameCloudLibrary.books), '/cloud/books');
    expect(preferences.rootFor(FrameCloudLibrary.comics), '/cloud/comics');
    expect(preferences.goalMinutes, 45);
  });

  test('writes identical Books and Comics roots for the accepted main provider keys', () async {
    final api = _FakeApi();
    final repository = FrameCloudRepository(api);

    await repository.saveSharedRoots(
      booksRoot: '/media/Books',
      comicsRoot: '/media/Comics',
    );

    expect(api.postRequests, hasLength(1));
    expect(api.postRequests.single.key, '/api/reading/preferences');
    final body = api.postRequests.single.value;
    expect(body['key'], 'roots');
    final value = body['value'] as Map<String, dynamic>;
    expect(value.keys, containsAll(['vps', 'worker', 'mobile']));
    for (final pair in value.values.cast<Map<String, dynamic>>()) {
      expect(pair['books'], '/media/Books');
      expect(pair['comics'], '/media/Comics');
    }
  });

  test('loads paginated live directory results from the existing scan-list API', () async {
    final api = _FakeApi();
    final page = await FrameCloudRepository(api).loadServerDirectoryPage(
      provider: FrameCloudProvider.worker,
      library: FrameCloudLibrary.books,
      rootPath: '/books',
      path: '/books/Novel',
      page: 2,
      perPage: 2,
    );

    expect(page.page, 2);
    expect(page.perPage, 2);
    expect(page.total, 5);
    expect(page.pageCount, 3);
    expect(page.items.single.name, 'Volume 03.epub');
    expect(api.getRequests.single, contains('page=2'));
    expect(api.getRequests.single, contains('per_page=2'));
  });

  test('loads indexed pages from the existing D1 bookshelf API', () async {
    final api = _FakeApi();
    final repository = FrameCloudRepository(api);

    final page = await repository.loadIndexedDirectory(
      provider: FrameCloudProvider.worker,
      library: FrameCloudLibrary.comics,
      rootPath: '/comics',
      path: '/comics',
      recursiveRoot: true,
    );

    expect(page.total, 1);
    expect(page.indexed, isTrue);
    expect(page.items.single.name, 'Series');
    expect(page.items.single.isDirectory, isTrue);
    expect(api.getRequests.single, contains('recursive=1'));
  });

  test('preserves unknown scanner cursor fields through pause and save', () async {
    final api = _FakeApi();
    final repository = FrameCloudRepository(api);
    final state = await repository.loadScanState(
      provider: FrameCloudProvider.worker,
      library: FrameCloudLibrary.comics,
      rootPath: '/comics',
    );

    expect(state, isNotNull);
    expect(state!.page, 3);
    expect(state.pausedByUser, isTrue);
    expect(state.raw['customCursor'], {'providerPage': 27});

    await repository.saveScanState(state.copyWith(pausedByUser: true));
    final posted = api.postRequests.single.value;
    final savedState = posted['state'] as Map<String, dynamic>;
    expect(savedState['customCursor'], {'providerPage': 27});
    expect(savedState['page'], 3);
    expect(savedState['pausedByUser'], isTrue);
  });

  test('chunks D1 index writes into batches of at most 100', () async {
    final api = _FakeApi();
    final repository = FrameCloudRepository(api);
    final entries = List.generate(
      205,
      (index) => {
        'name': '$index.epub',
        'path': '/books/$index.epub',
        'parentPath': '/books',
        'isDir': false,
        'format': 'EPUB',
        'size': 1024,
        'modified': null,
      },
    );

    final saved = await repository.writeIndexEntries(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.books,
      rootPath: '/books',
      scanId: 'scan_1234567890',
      entries: entries,
    );

    expect(saved, 205);
    expect(api.postRequests, hasLength(3));
    expect(
      api.postRequests.map((request) =>
          (request.value['entries'] as List).length).toList(),
      [100, 100, 5],
    );
  });

  test('completes a scan and asks the existing API to remove stale index rows', () async {
    final api = _FakeApi();
    final repository = FrameCloudRepository(api);
    final removed = await repository.completeScan(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.books,
      rootPath: '/books',
      scanId: 'scan_1234567890',
    );

    expect(removed, 4);
    expect(api.postRequests.single.key, '/api/cloud/index/complete');
  });

  test('keeps local provider selection out of the unsupported D1 preference value', () async {
    final api = _FakeApi();
    await FrameCloudRepository(api).saveActiveProvider(FrameCloudProvider.local);
    expect(api.postRequests, isEmpty);
  });
}
