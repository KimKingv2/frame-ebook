import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:frame_ebook/cloud/frame_cloud_models.dart';
import 'package:frame_ebook/cloud/frame_cloud_repository.dart';
import 'package:frame_ebook/cloud/frame_cloud_scan_runner.dart';
import 'package:frame_ebook/core/frame_api_client.dart';

class _ScanApi implements FrameApiClient {
  Map<String, dynamic>? savedState;
  final List<Map<String, dynamic>> indexedEntries = [];
  final List<String> directoryRequests = [];
  int completeCalls = 0;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/api/cloud/index/state?')) {
      return {'ok': true, 'state': savedState};
    }
    if (path.startsWith('/api/cloud/scan-list?')) {
      final uri = Uri.parse('https://frame.test$path');
      final folder = uri.queryParameters['path'] ?? '/books';
      final page = int.tryParse(uri.queryParameters['page'] ?? '1') ?? 1;
      directoryRequests.add('$folder:$page');
      if (folder == '/books' && page == 1) {
        return {
          'ok': true,
          'provider': 'vps',
          'library': 'books',
          'rootPath': '/books',
          'path': '/books',
          'page': 1,
          'perPage': 1,
          'total': 2,
          'items': [
            {
              'name': 'Novel',
              'path': '/books/Novel',
              'parentPath': '/books',
              'isDir': true,
              'format': '',
              'size': 0,
            },
          ],
        };
      }
      if (folder == '/books' && page == 2) {
        return {
          'ok': true,
          'provider': 'vps',
          'library': 'books',
          'rootPath': '/books',
          'path': '/books',
          'page': 2,
          'perPage': 1,
          'total': 2,
          'items': [
            {
              'name': 'Standalone.epub',
              'path': '/books/Standalone.epub',
              'parentPath': '/books',
              'isDir': false,
              'format': 'EPUB',
              'size': 1024,
            },
          ],
        };
      }
      if (folder == '/books/Novel') {
        return {
          'ok': true,
          'provider': 'vps',
          'library': 'books',
          'rootPath': '/books',
          'path': folder,
          'page': 1,
          'perPage': 1,
          'total': 1,
          'items': [
            {
              'name': 'Volume 01.epub',
              'path': '$folder/Volume 01.epub',
              'parentPath': folder,
              'isDir': false,
              'format': 'EPUB',
              'size': 2048,
            },
          ],
        };
      }
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path == '/api/cloud/index/state') {
      savedState = Map<String, dynamic>.from(body['state'] as Map);
      return {'ok': true};
    }
    if (path == '/api/cloud/index/entries') {
      final entries = (body['entries'] as List).cast<Map<String, dynamic>>();
      indexedEntries.addAll(entries);
      return {'ok': true, 'saved': entries.length};
    }
    if (path == '/api/cloud/index/complete') {
      completeCalls++;
      return {'ok': true, 'removed': 2};
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
  Future<Uint8List> getBytes(String path) async => Uint8List(0);

  @override
  void close() {}
}

void main() {
  test('walks folders, writes index entries and completes D1 scan', () async {
    final api = _ScanApi();
    final runner = FrameCloudScanRunner(
      repository: FrameCloudRepository(api),
      createScanId: () => 'scan_1234567890',
    );

    final result = await runner.run(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.books,
      rootPath: '/books',
      pageSize: 1,
    );

    expect(result.succeeded, isTrue);
    expect(result.completed, isTrue);
    expect(result.removedCount, 2);
    expect(api.completeCalls, 1);
    expect(
      api.indexedEntries.map((entry) => entry['path']).toSet(),
      {
        '/books/Novel',
        '/books/Standalone.epub',
        '/books/Novel/Volume 01.epub',
      },
    );
    expect(api.savedState?['completed'], isTrue);
    expect(api.savedState?['removedCount'], 2);
    expect(api.directoryRequests, [
      '/books:1',
      '/books:2',
      '/books/Novel:1',
    ]);
  });

  test('manual pause saves the page cursor and the next run resumes it', () async {
    final api = _ScanApi();
    final runner = FrameCloudScanRunner(
      repository: FrameCloudRepository(api),
      createScanId: () => 'scan_1234567890',
    );

    final first = await runner.run(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.books,
      rootPath: '/books',
      pageSize: 1,
      onProgress: (progress) {
        if (progress.phase.startsWith('已保存')) runner.requestPause();
      },
    );

    expect(first.succeeded, isTrue);
    expect(first.paused, isTrue);
    expect(first.completed, isFalse);
    expect(first.state?.pausedByUser, isTrue);
    expect(first.state?.currentFolder, '/books');
    expect(first.state?.page, 2);

    final second = await runner.run(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.books,
      rootPath: '/books',
      pageSize: 1,
    );

    expect(second.succeeded, isTrue);
    expect(second.completed, isTrue);
    expect(api.completeCalls, 1);
    expect(api.directoryRequests, [
      '/books:1',
      '/books:2',
      '/books/Novel:1',
    ]);
    expect(api.indexedEntries.length, 3);
  });

  test('does not silently repeat an already completed scan', () async {
    final api = _ScanApi()
      ..savedState = {
        'version': 1,
        'provider': 'vps',
        'library': 'books',
        'rootPath': '/books',
        'scanId': 'scan_1234567890',
        'pendingFolders': <String>[],
        'currentFolder': null,
        'page': 1,
        'seenFolders': <String>['/books'],
        'completed': true,
      };
    final runner = FrameCloudScanRunner(
      repository: FrameCloudRepository(api),
      createScanId: () => 'scan_abcdefghijkl',
    );

    final result = await runner.run(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.books,
      rootPath: '/books',
    );

    expect(result.completed, isTrue);
    expect(api.completeCalls, 0);
    expect(api.directoryRequests, isEmpty);
  });
}
