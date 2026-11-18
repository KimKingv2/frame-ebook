import 'dart:convert';
import 'dart:typed_data';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

import 'frame_api_client.dart';

FrameApiClient createFrameApiClient({required Uri baseUri}) =>
    _BrowserFrameApiClient(baseUri: baseUri);

class _BrowserFrameApiClient implements FrameApiClient {
  _BrowserFrameApiClient({required this.baseUri})
      : _client = BrowserClient()..withCredentials = true;

  final Uri baseUri;
  final BrowserClient _client;

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

  Future<http.Response> _send({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, _resolve(path))
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final streamed = await _client.send(request).timeout(
            const Duration(seconds: 30),
          );
      return await http.Response.fromStream(streamed).timeout(
        const Duration(seconds: 45),
      );
    } on Exception catch (error) {
      throw FrameApiException(message: '連接 FRAME Reader 失敗：$error');
    }
  }

  Map<String, dynamic> _decodeJson(http.Response response) {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (!contentType.contains('application/json')) {
      throw FrameApiException(
        message: 'FRAME API 沒有回傳 JSON。請確認目前網域已通過 Cloudflare Access。',
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
