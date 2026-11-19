import '../library/frame_book.dart';
import 'frame_file_source.dart';
import 'frame_transport.dart';

enum FrameCloudFileDelivery {
  sameOriginStream,
  nativeRedirect,
}

typedef FrameAccessCookieProvider = Future<String?> Function(Uri origin);

/// Adapts the existing indexed cloud-book descriptor to the protected
/// Cloudflare Pages file endpoint. Delivery differences remain here, not in
/// reader widgets or EPUB/CBZ parsing code.
class FrameCloudFileSource implements FrameFileSource {
  FrameCloudFileSource({
    required this.baseUri,
    required this.transport,
    required this.delivery,
    this.accessCookieProvider,
  }) {
    if (baseUri.scheme != 'https' ||
        !baseUri.hasAuthority ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.query.isNotEmpty ||
        baseUri.fragment.isNotEmpty) {
      throw const FormatException('FRAME 雲端檔案來源必須使用有效的 HTTPS 網域。');
    }
    if (delivery == FrameCloudFileDelivery.nativeRedirect &&
        accessCookieProvider == null) {
      throw ArgumentError(
        '原生 302 傳輸必須提供 WebView Cloudflare Access Cookie。',
      );
    }
  }

  final Uri baseUri;
  final FrameTransport transport;
  final FrameCloudFileDelivery delivery;
  final FrameAccessCookieProvider? accessCookieProvider;

  Uri buildRequestUri(FrameBook book) {
    final descriptor = book.descriptor();
    final provider = _required(descriptor, 'provider');
    final library = _required(descriptor, 'library');
    final rootPath = _required(descriptor, 'rootPath');
    final path = _required(descriptor, 'path');

    if (!const {'vps', 'worker', 'mobile'}.contains(provider)) {
      throw const FormatException('目前書籍來源不支援雲端閱讀串流。');
    }
    if (!const {'books', 'comics'}.contains(library)) {
      throw const FormatException('書籍分類不支援雲端閱讀串流。');
    }
    _validatePath(rootPath, '書庫根目錄');
    _validatePath(path, '書籍路徑');
    final normalizedRoot = _trimTrailingSlash(rootPath);
    if (path != normalizedRoot &&
        !path.startsWith(normalizedRoot == '/' ? '/' : '$normalizedRoot/')) {
      throw const FormatException('書籍路徑超出目前書庫根目錄。');
    }
    final lowerPath = path.toLowerCase();
    final extensionAllowed = library == 'comics'
        ? lowerPath.endsWith('.epub') || lowerPath.endsWith('.cbz')
        : lowerPath.endsWith('.epub');
    if (!extensionAllowed) {
      throw const FormatException('目前書庫不支援這種檔案格式。');
    }

    return baseUri.replace(
      path: '/api/cloud/file',
      queryParameters: {
        'provider': provider,
        'library': library,
        'root_path': rootPath,
        'path': path,
        'delivery': delivery == FrameCloudFileDelivery.nativeRedirect
            ? 'redirect'
            : 'stream',
      },
    );
  }

  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    if (request.cancellation?.isCancelled == true) {
      throw StateError('檔案讀取已取消。');
    }
    final uri = buildRequestUri(request.book);
    final headers = <String, String>{};
    final cookieProvider = accessCookieProvider;
    if (cookieProvider != null) {
      final cookie = (await cookieProvider(baseUri))?.trim() ?? '';
      if (request.cancellation?.isCancelled == true) {
        throw StateError('檔案讀取已取消。');
      }
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    }
    return transport.openStream(
      uri: uri,
      headers: headers,
      range: request.range,
      cancellation: request.cancellation,
    );
  }

  void close() => transport.close();

  static String _required(Map<String, dynamic> values, String key) {
    final value = values[key]?.toString().trim() ?? '';
    if (value.isEmpty) {
      throw FormatException('閱讀室缺少書籍識別欄位：$key');
    }
    return value;
  }

  static void _validatePath(String value, String label) {
    if (!value.startsWith('/') ||
        value.contains('\u0000') ||
        value.contains('\\') ||
        value.split('/').any((part) => part == '.' || part == '..')) {
      throw FormatException('$label 無效。');
    }
  }

  static String _trimTrailingSlash(String value) {
    if (value == '/') return value;
    return value.replaceFirst(RegExp(r'/+$'), '');
  }
}
