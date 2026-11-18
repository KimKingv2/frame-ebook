import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'webdav_models.dart';
import 'webdav_transport.dart';

class WebDavClient {
  WebDavClient({
    required this.profile,
    required this.password,
    WebDavTransport? transport,
  }) : _transport = transport ?? createWebDavTransport() {
    if (password.isEmpty) throw ArgumentError('WebDAV 密碼不可為空。');
    _baseUri = normalizeBaseUrl(profile.baseUrl);
    _username = profile.username.trim();
    if (_username.isEmpty) throw ArgumentError('WebDAV 帳號不可為空。');
  }

  final WebDavProfile profile;
  final String password;
  final WebDavTransport _transport;
  late final Uri _baseUri;
  late final String _username;

  static const int maxRangeBytes = 1024 * 1024;
  static const int defaultMaxArchiveBytes = 512 * 1024 * 1024;

  static Uri normalizeBaseUrl(String value) {
    final input = value.trim();
    late final Uri uri;
    try {
      uri = Uri.parse(input);
    } catch (_) {
      throw const FormatException('WebDAV 網址格式不正確。');
    }
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException('WebDAV 網址必須是沒有帳密、查詢參數或片段的 HTTP／HTTPS 網址。');
    }
    if (uri.scheme == 'http' && !_isLocalHost(uri.host)) {
      throw const FormatException('HTTP 僅允許 localhost、.local 或私有區域網路位址；外網請使用 HTTPS。');
    }
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path, query: null, fragment: null);
  }

  static String normalizeRemotePath(String value) {
    final input = value.trim().replaceAll('\\', '/');
    if (input.isEmpty || input.contains('\u0000')) {
      throw const FormatException('WebDAV 路徑格式不正確。');
    }
    final parts = input.split('/');
    if (parts.any((part) => part == '.' || part == '..')) {
      throw const FormatException('WebDAV 路徑不可包含 . 或 ..。');
    }
    final clean = parts.where((part) => part.isNotEmpty).join('/');
    return clean.isEmpty ? '/' : '/$clean';
  }

  static bool _isLocalHost(String host) {
    final clean = host.toLowerCase().replaceAll('[', '').replaceAll(']', '');
    if (clean == 'localhost' || clean.endsWith('.localhost') ||
        clean.endsWith('.local') || clean == '::1' ||
        clean.startsWith('fc') || clean.startsWith('fd') ||
        clean.startsWith('fe80:')) {
      return true;
    }
    final parts = clean.split('.');
    if (parts.length != 4) return false;
    final values = parts.map(int.tryParse).toList();
    if (values.any((part) => part == null || part < 0 || part > 255)) {
      return false;
    }
    final first = values[0]!;
    final second = values[1]!;
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168) ||
        (first == 169 && second == 254) ||
        first == 127;
  }

  Uri _resourceUri(String path, {required bool collection}) {
    final normalized = normalizeRemotePath(path);
    final baseSegments =
        _baseUri.pathSegments.where((segment) => segment.isNotEmpty);
    final remoteSegments =
        normalized.split('/').where((segment) => segment.isNotEmpty);
    final segments = <String>[...baseSegments, ...remoteSegments];
    if (collection) segments.add('');
    return _baseUri.replace(pathSegments: segments, query: null, fragment: null);
  }

  String _basicAuthorization() =>
      'Basic ${base64Encode(utf8.encode('$_username:$password'))}';

  Future<WebDavHttpResponse> _send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    List<int>? body,
    int maxResponseBytes = 1024 * 1024,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    var current = uri;
    final visited = <String>{};
    for (var hop = 0; hop <= 6; hop++) {
      if (!visited.add(current.toString())) {
        throw const WebDavException('WebDAV HTTP 跳轉發生循環，已停止請求。');
      }
      final requestHeaders = <String, String>{...headers};
      if (hop == 0) requestHeaders['Authorization'] = _basicAuthorization();
      final response = await _transport.send(
        method: method,
        uri: current,
        headers: requestHeaders,
        body: body,
        maxResponseBytes: maxResponseBytes,
        timeout: timeout,
      );
      if (_transport.browserManagedRedirect || !_isRedirect(response.statusCode)) {
        return response;
      }
      final location = response.header('location');
      if (location == null || location.trim().isEmpty) {
        throw WebDavException('WebDAV HTTP ${response.statusCode} 缺少 Location 標頭。');
      }
      final next = current.resolve(location.trim());
      _validateRedirect(current, next);
      current = next;
    }
    throw const WebDavException('WebDAV HTTP 跳轉超過 6 次上限。');
  }

  bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 ||
      status == 307 || status == 308;

  void _validateRedirect(Uri previous, Uri next) {
    if (!next.hasAuthority ||
        next.host.isEmpty ||
        (next.scheme != 'http' && next.scheme != 'https') ||
        next.userInfo.isNotEmpty) {
      throw const WebDavException('WebDAV 302 目的網址無效，已拒絕跳轉。');
    }
    if (previous.scheme == 'https' && next.scheme != 'https') {
      throw const WebDavException('已阻止 WebDAV 從 HTTPS 降級到 HTTP。');
    }
    if (next.scheme == 'http' && !_isLocalHost(next.host)) {
      throw const WebDavException('WebDAV 302 目的網址必須使用 HTTPS；僅區域網路允許 HTTP。');
    }
  }

  Future<List<WebDavEntry>> listDirectory(String path) async {
    final normalized = normalizeRemotePath(path);
    const body = '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/></d:prop></d:propfind>''';
    final response = await _send(
      method: 'PROPFIND',
      uri: _resourceUri(normalized, collection: true),
      headers: const {
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
        'Accept': 'application/xml, text/xml',
      },
      body: utf8.encode(body),
      maxResponseBytes: 4 * 1024 * 1024,
      timeout: const Duration(seconds: 60),
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const WebDavException('WebDAV 驗證失敗，請檢查帳號與密碼。');
    }
    if (response.bodyTruncated) {
      throw const WebDavException('WebDAV 目錄清單超過 4 MiB，已停止讀取。');
    }
    if (response.statusCode != 207 && ![200, 204].contains(response.statusCode)) {
      throw WebDavException(_statusMessage('讀取 WebDAV 目錄失敗', response));
    }
    if (response.body.isEmpty) {
      throw const WebDavException('WebDAV 沒有回傳目錄清單。');
    }
    return _parseMultiStatus(utf8.decode(response.body, allowMalformed: true),
        normalized, _resourceUri(normalized, collection: true));
  }

  List<WebDavEntry> _parseMultiStatus(
      String xml, String requestedPath, Uri targetUri) {
    late final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException {
      throw const WebDavException('WebDAV PROPFIND 回傳的 XML 無法解析。');
    }
    final entries = <WebDavEntry>[];
    for (final response in document.descendants.whereType<XmlElement>().where(
          (element) => element.name.local == 'response',
        )) {
      final href = _descendantText(response, 'href');
      if (href.isEmpty) continue;
      final resolved = targetUri.resolve(href);
      if (resolved.path.replaceFirst(RegExp(r'/+$'), '') ==
          targetUri.path.replaceFirst(RegExp(r'/+$'), '')) {
        continue;
      }
      final name = _descendantText(response, 'displayname').isNotEmpty
          ? _descendantText(response, 'displayname')
          : _decodeLastSegment(href);
      if (name.isEmpty || name == '.' || name == '..' ||
          name.contains('/') || name.contains('\\')) {
        continue;
      }
      final isDirectory = response.descendants
          .whereType<XmlElement>()
          .any((element) => element.name.local == 'collection');
      final size = int.tryParse(_descendantText(response, 'getcontentlength')) ?? 0;
      final path = requestedPath == '/'
          ? '/$name'
          : '${requestedPath.replaceFirst(RegExp(r'/+$'), '')}/$name';
      entries.add(WebDavEntry(
        name: name,
        path: path,
        isDirectory: isDirectory,
        size: size < 0 ? 0 : size,
        modified: _descendantText(response, 'getlastmodified'),
        contentType: _descendantText(response, 'getcontenttype'),
      ));
    }
    entries.sort((a, b) {
      final directoryOrder = b.isDirectory.compareTo(a.isDirectory);
      return directoryOrder != 0
          ? directoryOrder
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  String _descendantText(XmlElement element, String localName) {
    for (final child in element.descendants.whereType<XmlElement>()) {
      if (child.name.local == localName) return child.innerText.trim();
    }
    return '';
  }

  String _decodeLastSegment(String href) {
    final path = Uri.tryParse(href)?.path ?? href;
    final segment = path.replaceFirst(RegExp(r'/+$'), '').split('/').last;
    try {
      return Uri.decodeComponent(segment);
    } on FormatException {
      return segment;
    }
  }

  Future<WebDavFileMetadata> getFileMetadata(String path) async {
    final normalized = normalizeRemotePath(path);
    final uri = _resourceUri(normalized, collection: false);
    final response = await _send(
      method: 'HEAD',
      uri: uri,
      headers: const {'Accept': '*/*'},
      maxResponseBytes: 1024,
      timeout: const Duration(seconds: 30),
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const WebDavException('WebDAV 驗證失敗，請檢查帳號與密碼。');
    }
    final size = int.tryParse(response.header('content-length') ?? '');
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        size != null &&
        size > 0) {
      return WebDavFileMetadata(
        size: size,
        contentType: response.header('content-type') ?? '',
        etag: response.header('etag') ?? '',
        lastModified: response.header('last-modified') ?? '',
      );
    }
    if (![404, 405, 501].contains(response.statusCode) &&
        (response.statusCode < 200 || response.statusCode >= 300)) {
      throw WebDavException(_statusMessage('讀取 WebDAV 檔案資訊失敗', response));
    }
    final firstByte = await readRange(normalized, start: 0, length: 1);
    return WebDavFileMetadata(
      size: firstByte.totalSize,
      contentType: '',
      etag: '',
      lastModified: '',
    );
  }

  Future<WebDavFileRange> readRange(
    String path, {
    required int start,
    int length = 1024 * 1024,
  }) async {
    final normalized = normalizeRemotePath(path);
    if (start < 0 || length < 1 || length > maxRangeBytes) {
      throw ArgumentError('WebDAV Range 單次讀取必須介於 1 byte 至 1 MiB。');
    }
    final end = start + length - 1;
    final response = await _send(
      method: 'GET',
      uri: _resourceUri(normalized, collection: false),
      headers: {'Range': 'bytes=$start-$end', 'Accept': '*/*'},
      maxResponseBytes: length + 1,
      timeout: const Duration(seconds: 60),
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const WebDavException('WebDAV 驗證失敗，請檢查帳號與密碼。');
    }
    if (response.statusCode != 206) {
      throw WebDavException(
        '這個 WebDAV 來源沒有正確支援 HTTP Range（收到 HTTP ${response.statusCode}，預期 206）。為避免把漫畫整包讀入記憶體，已停止讀取。',
      );
    }
    if (response.bodyTruncated) {
      throw const WebDavException('WebDAV Range 回應超過請求長度，已停止讀取。');
    }
    final contentRange = response.header('content-range') ?? '';
    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$', caseSensitive: false)
        .firstMatch(contentRange.trim());
    if (match == null) {
      throw const WebDavException('WebDAV Range 回應缺少有效的 Content-Range。');
    }
    final actualStart = int.parse(match.group(1)!);
    final actualEnd = int.parse(match.group(2)!);
    final total = int.parse(match.group(3)!);
    if (actualStart != start ||
        actualEnd < actualStart ||
        actualEnd > end ||
        total <= actualEnd) {
      throw const WebDavException('WebDAV Range 回應的位移或檔案總長度不正確。');
    }
    final expectedLength = actualEnd - actualStart + 1;
    if (response.body.length != expectedLength) {
      throw WebDavException(
        'WebDAV Range 資料不完整：預期 $expectedLength bytes，實際 ${response.body.length} bytes。',
      );
    }
    return WebDavFileRange(
      bytes: response.body,
      start: actualStart,
      end: actualEnd,
      totalSize: total,
      redirected: !_transport.browserManagedRedirect &&
          _resourceUri(normalized, collection: false).toString() != uri.toString(),
    );
  }

  Future<Uint8List> downloadEpubToMemory(
    String path, {
    int maxBytes = defaultMaxArchiveBytes,
  }) async {
    final normalized = normalizeRemotePath(path);
    if (!normalized.toLowerCase().endsWith('.epub')) {
      throw const WebDavException('記憶體完整讀取僅供 EPUB 使用；CBZ 必須採分段 Range。');
    }
    final response = await _send(
      method: 'GET',
      uri: _resourceUri(normalized, collection: false),
      headers: const {'Accept': 'application/epub+zip, application/octet-stream'},
      maxResponseBytes: maxBytes,
      timeout: const Duration(minutes: 5),
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const WebDavException('WebDAV 驗證失敗，請檢查帳號與密碼。');
    }
    if (response.statusCode != 200) {
      throw WebDavException(_statusMessage('讀取 EPUB 失敗', response));
    }
    if (response.bodyTruncated) {
      throw WebDavException('EPUB 超過記憶體讀取上限（${_formatBytes(maxBytes)}），沒有建立暫存檔。');
    }
    if (response.body.isEmpty) {
      throw const WebDavException('WebDAV 回傳的 EPUB 檔案是空的。');
    }
    return response.body;
  }

  Future<void> testConnection() async {
    await listDirectory(profile.booksRoot);
  }

  String _statusMessage(String operation, WebDavHttpResponse response) {
    final snippet = utf8.decode(response.body, allowMalformed: true).trim();
    final detail = snippet.isEmpty ? '' : '：${snippet.substring(0, snippet.length > 240 ? 240 : snippet.length)}';
    return '$operation（HTTP ${response.statusCode}）$detail';
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MiB';
  }

  void close() => _transport.close();
}

class WebDavException implements Exception {
  const WebDavException(this.message);

  final String message;

  @override
  String toString() => message;
}
