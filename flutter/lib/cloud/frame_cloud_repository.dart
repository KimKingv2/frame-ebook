import 'dart:convert';

import '../core/frame_api_client.dart';
import 'frame_cloud_models.dart';

class FrameCloudRepository {
  FrameCloudRepository(this.api);

  final FrameApiClient api;

  Future<FrameCloudSession> loadSession() async {
    final data = await api.getJson('/api/auth/session');
    final session = FrameCloudSession.fromJson(data);
    if (!session.authenticated || !session.accessEnabled) {
      throw const FrameApiException(
        message: 'Cloudflare Access 工作階段尚未驗證。',
        statusCode: 401,
      );
    }
    return session;
  }

  Future<FrameCloudPreferences> loadPreferences() async {
    final data = await api.getJson('/api/reading/preferences');
    final raw = data['preferences'];
    return FrameCloudPreferences.fromJson(
      raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{},
    );
  }

  Future<void> savePreference(String key, dynamic value) async {
    final data = await api.postJson('/api/reading/preferences', {
      'key': key,
      'value': value,
    });
    if (data['ok'] != true) {
      throw const FrameApiException(message: '雲端偏好設定保存失敗。');
    }
  }

  Future<void> saveActiveLibrary(FrameCloudLibrary library) =>
      savePreference('activeLibrary', library.apiValue);

  Future<void> saveActiveProvider(FrameCloudProvider provider) async {
    // The existing main-branch preferences API accepts server-side provider
    // IDs only. Local OpenList is a device/browser direct connection and its
    // selected state stays local rather than sending an unsupported value.
    if (!provider.isServerSide) return;
    await savePreference('activeProvider', provider.apiValue);
  }

  Future<void> saveSharedRoots({
    required String booksRoot,
    required String comicsRoot,
  }) async {
    final books = normalizeFrameCloudPath(booksRoot);
    final comics = normalizeFrameCloudPath(comicsRoot);
    if (books == null || comics == null) {
      throw const FormatException(
        '電子書與漫畫根目錄必須是有效的絕對路徑，且不可包含 . 或 ..。',
      );
    }

    // Main's preference validator stores roots under vps/worker/mobile,
    // not under the UI's shared key. Write the same pair to each accepted
    // provider key so that all sources keep using the same two library roots.
    await savePreference('roots', {
      for (final provider in [
        FrameCloudProvider.vps,
        FrameCloudProvider.worker,
        FrameCloudProvider.mobile,
      ])
        provider.apiValue: {
          FrameCloudLibrary.books.apiValue: books,
          FrameCloudLibrary.comics.apiValue: comics,
        },
    });
  }

  Future<FrameCloudDirectoryPage> loadIndexedDirectory({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    required String path,
    int page = 1,
    int perPage = 80,
    bool recursiveRoot = false,
  }) async {
    final root = normalizeFrameCloudPath(rootPath);
    final current = normalizeFrameCloudPath(path);
    if (root == null || current == null || !frameCloudPathIsWithinRoot(current, root)) {
      throw const FormatException('目錄路徑無效或超出目前書庫根目錄。');
    }
    final query = <String, String>{
      'provider': provider.apiValue,
      'library': library.apiValue,
      'root_path': root,
      'path': current,
      'page': page.clamp(1, 100000).toString(),
      'per_page': perPage.clamp(1, 100).toString(),
      if (recursiveRoot && current == root) 'recursive': '1',
    };
    final data = await api.getJson('/api/cloud/books?${Uri(queryParameters: query).query}');
    return FrameCloudDirectoryPage.fromJson(data);
  }

  Future<List<FrameCloudEntry>> listServerDirectory({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    required String path,
    int page = 1,
    int perPage = 100,
  }) async {
    if (!provider.isServerSide) {
      throw ArgumentError('本地 OpenList 必須透過目前裝置直接列出目錄。');
    }
    final root = normalizeFrameCloudPath(rootPath);
    final current = normalizeFrameCloudPath(path);
    if (root == null || current == null || !frameCloudPathIsWithinRoot(current, root)) {
      throw const FormatException('掃描目錄無效或超出目前書庫根目錄。');
    }
    final query = {
      'provider': provider.apiValue,
      'library': library.apiValue,
      'root_path': root,
      'path': current,
      'page': page.clamp(1, 100000).toString(),
      'per_page': perPage.clamp(1, 100).toString(),
    };
    final data = await api.getJson('/api/cloud/scan-list?${Uri(queryParameters: query).query}');
    final raw = data['items'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => FrameCloudEntry.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.path.isNotEmpty && item.name.isNotEmpty)
        .toList(growable: false);
  }

  Future<FrameCloudScanState?> loadScanState({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
  }) async {
    final root = normalizeFrameCloudPath(rootPath);
    if (root == null) throw const FormatException('掃描根目錄無效。');
    final query = {
      'provider': provider.apiValue,
      'library': library.apiValue,
      'root_path': root,
    };
    final data = await api.getJson('/api/cloud/index/state?${Uri(queryParameters: query).query}');
    final state = data['state'];
    return state is Map
        ? FrameCloudScanState.fromJson(Map<String, dynamic>.from(state))
        : null;
  }

  Future<void> saveScanState(FrameCloudScanState state) async {
    final root = normalizeFrameCloudPath(state.rootPath);
    if (root == null || state.version != 1 || state.scanId.length < 12) {
      throw const FormatException('掃描進度格式無效。');
    }
    final value = state.toJson()
      ..['updatedAt'] = DateTime.now().toIso8601String();
    await api.postJson('/api/cloud/index/state', {
      'provider': state.provider.apiValue,
      'library': state.library.apiValue,
      'rootPath': root,
      'state': value,
    });
  }

  Future<int> writeIndexEntries({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    required String scanId,
    required List<Map<String, dynamic>> entries,
  }) async {
    final root = normalizeFrameCloudPath(rootPath);
    if (root == null) throw const FormatException('書庫根目錄無效。');
    if (!RegExp(r'^[a-zA-Z0-9_-]{12,100}$').hasMatch(scanId)) {
      throw const FormatException('掃描識別碼格式無效。');
    }
    var saved = 0;
    for (var offset = 0; offset < entries.length; offset += 100) {
      final end = offset + 100 < entries.length ? offset + 100 : entries.length;
      final data = await api.postJson('/api/cloud/index/entries', {
        'provider': provider.apiValue,
        'library': library.apiValue,
        'rootPath': root,
        'scanId': scanId,
        'entries': entries.sublist(offset, end),
      });
      saved += _safeInt(data['saved']);
    }
    return saved;
  }

  Future<int> completeScan({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    required String scanId,
  }) async {
    final root = normalizeFrameCloudPath(rootPath);
    if (root == null) throw const FormatException('書庫根目錄無效。');
    final data = await api.postJson('/api/cloud/index/complete', {
      'provider': provider.apiValue,
      'library': library.apiValue,
      'rootPath': root,
      'scanId': scanId,
    });
    return _safeInt(data['removed']);
  }

  Future<FrameCloudCoverQueue> loadPendingCovers({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    int limit = 12,
  }) async {
    final root = normalizeFrameCloudPath(rootPath);
    if (root == null) throw const FormatException('封面佇列根目錄無效。');
    final query = {
      'provider': provider.apiValue,
      'library': library.apiValue,
      'root_path': root,
      'limit': limit.clamp(1, 30).toString(),
    };
    final data = await api.getJson('/api/cloud/covers?${Uri(queryParameters: query).query}');
    final raw = data['items'];
    return FrameCloudCoverQueue(
      total: _safeInt(data['total']),
      items: raw is List
          ? raw
              .whereType<Map>()
              .map((item) => FrameCloudEntry.fromJson(Map<String, dynamic>.from(item)))
              .toList(growable: false)
          : const [],
    );
  }

  Future<int> retryFailedCovers({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
  }) async {
    final root = normalizeFrameCloudPath(rootPath);
    if (root == null) throw const FormatException('封面佇列根目錄無效。');
    final data = await api.postJson('/api/cloud/covers', {
      'action': 'retry-errors',
      'provider': provider.apiValue,
      'library': library.apiValue,
      'rootPath': root,
    });
    return _safeInt(data['retried']);
  }

  Future<void> updateCoverStatus({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    required String path,
    required String status,
    String? error,
  }) async {
    final root = normalizeFrameCloudPath(rootPath);
    final file = normalizeFrameCloudPath(path);
    if (root == null ||
        file == null ||
        !frameCloudPathIsWithinRoot(file, root) ||
        !['missing', 'error'].contains(status)) {
      throw const FormatException('封面索引更新參數無效。');
    }
    await api.postJson('/api/cloud/covers', {
      'provider': provider.apiValue,
      'library': library.apiValue,
      'rootPath': root,
      'path': file,
      'status': status,
      if (error != null) 'error': error,
    });
  }

  Future<int> saveEpubMetadataBatch({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    required List<Map<String, dynamic>> entries,
  }) async {
    if (entries.isEmpty) return 0;
    if (entries.length > 50) {
      throw ArgumentError('EPUB metadata 每批最多 50 筆。');
    }
    final root = normalizeFrameCloudPath(rootPath);
    if (root == null) throw const FormatException('EPUB metadata 根目錄無效。');
    final data = await api.postJson('/api/cloud/index/metadata', {
      'provider': provider.apiValue,
      'library': library.apiValue,
      'rootPath': root,
      'entries': entries,
    });
    return _safeInt(data['updated']);
  }

  static int _safeInt(dynamic value) {
    if (value is int) return value;
    if (value is num && value.isFinite) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
