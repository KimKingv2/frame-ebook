import 'dart:convert';
import 'dart:typed_data';

import 'local_openlist_transport.dart';

class LocalOpenListEntry {
  const LocalOpenListEntry({
    required this.name,
    required this.path,
    required this.parentPath,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });

  final String name;
  final String path;
  final String parentPath;
  final bool isDirectory;
  final int size;
  final String? modified;
}

class LocalOpenListDirectory {
  const LocalOpenListDirectory({
    required this.path,
    required this.page,
    required this.perPage,
    required this.total,
    required this.items,
  });

  final String path;
  final int page;
  final int perPage;
  final int total;
  final List<LocalOpenListEntry> items;
}

class LocalOpenListFileInfo {
  const LocalOpenListFileInfo({
    required this.rawUri,
    required this.size,
    required this.name,
    required this.modified,
  });

  final Uri rawUri;
  final int size;
  final String name;
  final String? modified;
}

class LocalOpenListRange {
  const LocalOpenListRange({
    required this.bytes,
    required this.start,
    required this.end,
    required this.totalSize,
  });

  final Uint8List bytes;
  final int start;
  final int end;
  final int totalSize;
}

class LocalOpenListException implements Exception {
  const LocalOpenListException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalOpenListClient {
  LocalOpenListClient({
    required String baseUrl,
    LocalOpenListTransport? transport,
  })  : baseUrl = normalizeLocalOpenListUrl(baseUrl),
        _transport = transport ?? createLocalOpenListTransport();

  final String baseUrl;
  final LocalOpenListTransport _transport;
  String _token = '';
  final Map<String, LocalOpenListFileInfo> _fileInfoCache = {};

  bool get isAuthenticated => _token.isNotEmpty;

  static String normalizeLocalOpenListUrl(String value) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.host.isEmpty ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.userInfo.isNotEmpty ||
        parsed.query.isNotEmpty ||
        parsed.fragment.isNotEmpty) {
      throw const FormatException('本地 OpenList 網址格式不正確。');
    }
    if (parsed.scheme == 'http' && !_isPrivateAddress(parsed.host)) {
      throw const FormatException(
        'HTTP 僅允許 localhost 或私有區域網路 IPv4；其他網域請使用 HTTPS。',
      );
    }
    final path = parsed.path.replaceFirst(RegExp(r'/+$'), '');
    return parsed.replace(path: path).toString();
  }

  static bool _isPrivateAddress(String input) {
    final host = input.toLowerCase();
    if (host == 'localhost' || host == '::1' || host == '[::1]' ||
        host.startsWith('127.')) {
      return true;
    }
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((value) => value == null || value < 0 || value > 255)) {
      return false;
    }
    final first = octets[0]!;
    final second = octets[1]!;
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168) ||
        (first == 169 && second == 254) ||
        first == 127;
  }

  static String normalizePath(String value) {
    final path = value.trim().replaceAll('\\', '/');
    if (!path.startsWith('/') || path.contains('\u0000')) {
      throw const FormatException('本地 OpenList 目錄路徑無效。');
    }
    if (path.split('/').any((part) => part == '.' || part == '..')) {
      throw const FormatException('本地 OpenList 路徑不可包含 . 或 ..。');
    }
    final clean = path.split('/').where((part) => part.isNotEmpty).join('/');
    return clean.isEmpty ? '/' : '/$clean';
  }

  Uri _endpoint(String relative) => Uri.parse(baseUrl.endsWith('/')
      ? '$baseUrl$relative'
      : '$baseUrl/$relative');

  Future<void> login({
    required String username,
    required String password,
  }) async {
    final user = username.trim();
    if (user.isEmpty || password.isEmpty) {
      throw const LocalOpenListException('請輸入本地 OpenList 帳號與密碼。');
    }
    final response = await _transport.send(
      method: 'POST',
      uri: _endpoint('api/auth/login'),
      headers: const {'Content-Type': 'application/json'},
      body: utf8.encode(jsonEncode({'username': user, 'password': password})),
      maxResponseBytes: 64 * 1024,
      timeout: const Duration(seconds: 20),
    );
    final payload = _decode(response, '登入', requireData: true);
    final data = _map(payload['data']);
    final token = data['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw const LocalOpenListException('本地 OpenList 登入沒有回傳 Token。');
    }
    _token = token;
    _fileInfoCache.clear();
  }

  void logout() {
    _token = '';
    _fileInfoCache.clear();
  }

  Future<LocalOpenListDirectory> listDirectory(
    String path, {
    int page = 1,
    int perPage = 100,
  }) async {
    final safePath = normalizePath(path);
    final data = await _postApi('fs/list', {
      'path': safePath,
      'password': '',
      'page': page.clamp(1, 100000).toInt(),
      'per_page': perPage.clamp(1, 500).toInt(),
      'refresh': false,
    });
    final rawItems = data['content'];
    final items = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((raw) {
              final item = Map<String, dynamic>.from(raw);
              final name = item['name']?.toString() ?? '';
              if (name.isEmpty || name.contains('/') || name.contains('\\')) {
                return null;
              }
              final size = _integer(item['size']);
              final parent = safePath.replaceFirst(RegExp(r'/+$'), '');
              final itemPath = parent.isEmpty ? '/$name' : '$parent/$name';
              return LocalOpenListEntry(
                name: name,
                path: itemPath,
                parentPath: safePath,
                isDirectory: item['is_dir'] == true,
                size: size < 0 ? 0 : size,
                modified: (item['modified'] ?? item['created'])?.toString(),
              );
            })
            .whereType<LocalOpenListEntry>()
            .toList(growable: false)
        : const <LocalOpenListEntry>[];
    return LocalOpenListDirectory(
      path: safePath,
      page: _integer(data['page'], page).clamp(1, 100000).toInt(),
      perPage: _integer(data['per_page'], perPage).clamp(1, 500).toInt(),
      total: _integer(data['total'], items.length).clamp(0, 9007199254740991).toInt(),
      items: items,
    );
  }

  Future<LocalOpenListFileInfo> getFileInfo(String path) async {
    final safePath = normalizePath(path);
    final cached = _fileInfoCache[safePath];
    if (cached != null) return cached;
    final data = await _postApi('fs/get', {
      'path': safePath,
      'password': '',
      'page': 1,
      'per_page': 0,
      'refresh': false,
    });
    if (data['is_dir'] == true || data['raw_url'] == null) {
      throw const LocalOpenListException('本地 OpenList 沒有提供檔案下載位址。');
    }
    final rawUri = Uri.tryParse(data['raw_url'].toString());
    if (rawUri == null ||
        !rawUri.hasAuthority ||
        (rawUri.scheme != 'https' && rawUri.scheme != 'http') ||
        rawUri.userInfo.isNotEmpty) {
      throw const LocalOpenListException('本地 OpenList 回傳的檔案位址無效。');
    }
    final file = LocalOpenListFileInfo(
      rawUri: rawUri,
      size: _integer(data['size']),
      name: data['name']?.toString() ?? safePath.split('/').last,
      modified: data['modified']?.toString(),
    );
    _fileInfoCache[safePath] = file;
    return file;
  }

  Future<LocalOpenListRange> readRange(
    String path, {
    required int start,
    required int length,
  }) async {
    if (start < 0 || length < 1 || length > 1024 * 1024) {
      throw ArgumentError('本地 OpenList 單次 Range 必須介於 1 byte 至 1 MiB。');
    }
    final file = await getFileInfo(path);
    final end = start + length - 1;
    final response = await _transport.send(
      method: 'GET',
      uri: file.rawUri,
      headers: {'Range': 'bytes=$start-$end'},
      followRedirects: true,
      maxRedirects: 8,
      maxResponseBytes: length + 1,
      timeout: const Duration(seconds: 60),
    );
    if (response.statusCode != 206 || response.bodyTruncated) {
      throw LocalOpenListException(
        '本地 OpenList Range 讀取失敗（HTTP ${response.statusCode}），'
        '預期 HTTP 206；為避免整包讀入記憶體，已停止。',
      );
    }
    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$', caseSensitive: false)
        .firstMatch(response.header('content-range')?.trim() ?? '');
    if (match == null) {
      throw const LocalOpenListException('本地 OpenList Range 回應缺少有效的 Content-Range。');
    }
    final actualStart = int.parse(match.group(1)!);
    final actualEnd = int.parse(match.group(2)!);
    final total = int.parse(match.group(3)!);
    if (actualStart != start ||
        actualEnd < actualStart ||
        actualEnd > end ||
        total <= actualEnd ||
        response.body.length != actualEnd - actualStart + 1) {
      throw const LocalOpenListException('本地 OpenList Range 回應位移或資料長度不正確。');
    }
    return LocalOpenListRange(
      bytes: response.body,
      start: actualStart,
      end: actualEnd,
      totalSize: total,
    );
  }

  Future<Uint8List> downloadEpubToMemory(
    String path, {
    int maxBytes = 512 * 1024 * 1024,
  }) async {
    final safePath = normalizePath(path);
    if (!safePath.toLowerCase().endsWith('.epub')) {
      throw const LocalOpenListException('只有 EPUB 可以使用完整記憶體讀取；CBZ 必須採 Range。');
    }
    final file = await getFileInfo(safePath);
    if (file.size > 0 && file.size > maxBytes) {
      throw LocalOpenListException('EPUB 超過記憶體讀取上限 ${_formatBytes(maxBytes)}。');
    }
    final response = await _transport.send(
      method: 'GET',
      uri: file.rawUri,
      followRedirects: true,
      maxRedirects: 8,
      maxResponseBytes: maxBytes,
      timeout: const Duration(minutes: 5),
    );
    if (response.statusCode != 200 || response.bodyTruncated || response.body.isEmpty) {
      throw LocalOpenListException(
        '本地 OpenList EPUB 讀取失敗（HTTP ${response.statusCode}）或超過記憶體上限；沒有建立暫存檔。',
      );
    }
    return response.body;
  }

  Future<Map<String, dynamic>> _postApi(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    if (_token.isEmpty) {
      throw const LocalOpenListException('本地 OpenList 尚未登入，請重新輸入帳號與密碼。');
    }
    final response = await _transport.send(
      method: 'POST',
      uri: _endpoint('api/$endpoint'),
      headers: {
        'Authorization': _token,
        'Content-Type': 'application/json',
      },
      body: utf8.encode(jsonEncode(body)),
      maxResponseBytes: 2 * 1024 * 1024,
      timeout: const Duration(seconds: 45),
    );
    final payload = _decode(response, endpoint, requireData: true);
    return _map(payload['data']);
  }

  Map<String, dynamic> _decode(
    LocalOpenListHttpResponse response,
    String operation, {
    required bool requireData,
  }) {
    Map<String, dynamic> payload;
    try {
      payload = _map(jsonDecode(utf8.decode(response.body)));
    } catch (_) {
      throw LocalOpenListException(
        '本地 OpenList $operation 回應不是有效 JSON（HTTP ${response.statusCode}）。',
      );
    }
    final code = _integer(payload['code']);
    final data = payload['data'];
    if (response.statusCode == 401 || code == 401) {
      logout();
      throw const LocalOpenListException('本地 OpenList 登入已失效，請重新登入。');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        code != 200 ||
        (requireData && data == null)) {
      final reason = (payload['message'] ?? payload['error'])?.toString();
      throw LocalOpenListException(
        '本地 OpenList $operation 失敗（HTTP ${response.statusCode}）'
        '${reason == null || reason.isEmpty ? '。' : '：$reason'}',
      );
    }
    return payload;
  }

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static int _integer(dynamic value, [int fallback = 0]) {
    if (value is int) return value;
    if (value is num && value.isFinite) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MiB';
  }

  void close() {
    logout();
    _transport.close();
  }
}
