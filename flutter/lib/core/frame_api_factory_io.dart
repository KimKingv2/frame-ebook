import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import 'frame_api_client.dart';

FrameApiClient createFrameApiClient({required Uri baseUri}) =>
    _NativeFrameApiClient(baseUri: baseUri);

class _NativeFrameApiClient implements FrameApiClient {
  _NativeFrameApiClient({required this.baseUri})
      : _client = http.Client(),
        _cookieManager = WebViewCookieManager();

  final Uri baseUri;
  final http.Client _client;
  final WebViewCookieManager _cookieManager;

  Uri _resolve(String path) {
    if (!path.startsWith('/api/') ||
        path.startsWith('//') ||
        path.contains('\\') ||
        path.contains('\u0000')) {
      throw const FrameApiException(message: 'FRAME API 路徑無效。');
    }
    final uri = baseUri.resolve(path);
    if (uri.origin != baseUri.origin) {
      throw const FrameApiException(message: '已阻止 FRAME API 跨網域請求。');
    }
    return uri;
  }

  Future<Map<String, String>> _headers({
    required bool jsonBody,
  }) async {
    final cookies = await _cookieManager.getCookies(domain: baseUri);
    final cookieHeader = cookies
        .where((cookie) => cookie.name.isNotEmpty)
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
    final headers = <String, String>{
      'Accept': 'application/json',
      'Origin': baseUri.origin,
      'Referer': baseUri.toString(),
    };
    if (cookieHeader.isNotEmpty) headers['Cookie'] = cookieHeader;
    if (jsonBody) headers['Content-Type'] = 'application/json';
    return headers;
  }

  Future<http.Response> _send({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    List<int>? bodyBytes,
    String? contentType,
    Map<String, String> headers = const {},
  }) async {
    final uri = _resolve(path);
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll(await _headers(jsonBody: body != null))
      ..headers.addAll(headers);
    if (body != null) {
      request.body = jsonEncode(body);
    } else if (bodyBytes != null) {
      request.headers['Content-Type'] = contentType ?? 'application/octet-stream';
      request.bodyBytes = bodyBytes;
    }

    try {
      final streamed = await _client.send(request).timeout(
            const Duration(seconds: 30),
          );
      return await http.Response.fromStream(streamed).timeout(
        const Duration(seconds: 45),
      );
    } on Exception catch (error) {
      if (error is FrameApiException) rethrow;
      throw FrameApiException(message: '連接 FRAME Reader 失敗：$error');
    }
  }

  Map<String, dynamic> _decodeJson(http.Response response) {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (!contentType.contains('application/json')) {
      if (response.statusCode == 302 ||
          response.statusCode == 301 ||
          response.body.toLowerCase().contains('cloudflare access')) {
        throw const FrameApiException(
          message: '尚未完成 Cloudflare Access 登入，請先登入後再試。',
          statusCode: 401,
        );
      }
      throw FrameApiException(
        message: 'FRAME API 沒有回傳 JSON（HTTP ${response.statusCode}）。',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FrameApiException(message: 'FRAME API 回應格式不正確。');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded['error'] != null) {
      throw FrameApiException(
        message: decoded['error']?.toString() ??
            'FRAME API 請求失敗（HTTP ${response.statusCode}）。',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      _decodeJson(await _send(method: 'GET', path: path));

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      _decodeJson(await _send(method: 'POST', path: path, body: body));

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async =>
      _decodeJson(await _send(
        method: 'POST',
        path: path,
        bodyBytes: body,
        contentType: contentType,
        headers: headers,
      ));

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      _decodeJson(await _send(method: 'DELETE', path: path, body: body));

  @override
  Future<Uint8List> getBytes(String path) async {
    final response = await _send(method: 'GET', path: path);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FrameApiException(
        message: '讀取 FRAME 檔案失敗（HTTP ${response.statusCode}）。',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  @override
  void close() => _client.close();
}
