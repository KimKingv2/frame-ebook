import 'dart:convert';
import 'dart:typed_data';

import 'package:webview_flutter/webview_flutter.dart';

import 'frame_api_client.dart';

/// Runs native API calls in the same WebView that owns the Cloudflare Access
/// HttpOnly cookie. The Access cookie never leaves the WebView cookie store.
class FrameWebViewApiClient implements FrameApiClient {
  FrameWebViewApiClient({required this.baseUri, required this.controller});

  final Uri baseUri;
  final WebViewController controller;

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

  Future<Map<String, dynamic>> _request({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    bool asBytes = false,
  }) async {
    final uri = _resolve(path);
    final bodyLiteral = body == null ? 'null' : jsonEncode(jsonEncode(body));
    final script = '''
(async () => {
  try {
    const origin = ${jsonEncode(baseUri.origin)};
    if (window.location.origin !== origin) {
      return JSON.stringify({ok:false,error:'WebView 尚未返回 FRAME Ebook，請先完成 Cloudflare Access 登入。'});
    }
    const url = new URL(${jsonEncode(uri.toString())});
    if (url.origin !== origin) {
      return JSON.stringify({ok:false,error:'已阻止跨網域 API 請求。'});
    }
    const body = $bodyLiteral;
    const headers = {Accept: ${asBytes ? "'*/*'" : "'application/json'"}};
    if (body !== null) headers['Content-Type'] = 'application/json';
    const response = await fetch(url.href, {
      method: ${jsonEncode(method)},
      credentials: 'include',
      cache: 'no-store',
      redirect: 'follow',
      headers,
      body
    });
    if (new URL(response.url).origin !== origin) {
      return JSON.stringify({ok:false,error:'FRAME API 被重新導向至非正式站網域，已停止請求。'});
    }
    let responseBody;
    if ($asBytes) {
      const bytes = new Uint8Array(await response.arrayBuffer());
      let binary = '';
      for (let i = 0; i < bytes.length; i += 0x8000) {
        binary += String.fromCharCode(...bytes.subarray(i, Math.min(i + 0x8000, bytes.length)));
      }
      responseBody = btoa(binary);
    } else {
      responseBody = await response.text();
    }
    return JSON.stringify({
      ok:true,
      status:response.status,
      contentType:response.headers.get('content-type') || '',
      body:responseBody
    });
  } catch (error) {
    return JSON.stringify({ok:false,error:String(error)});
  }
})()
''';

    try {
      final raw = await controller
          .runJavaScriptReturningResult(script)
          .timeout(const Duration(seconds: 60));
      var resultText = raw.toString();
      if (resultText.startsWith('"') && resultText.endsWith('"')) {
        try {
          final unwrapped = jsonDecode(resultText);
          if (unwrapped is String) resultText = unwrapped;
        } on FormatException {
          // Preserve the platform result for the JSON parser below.
        }
      }
      final result = jsonDecode(resultText);
      if (result is! Map<String, dynamic>) {
        throw const FrameApiException(message: 'WebView API 回應格式不正確。');
      }
      if (result['ok'] != true) {
        throw FrameApiException(
          message: result['error']?.toString() ?? 'WebView API 請求失敗。',
        );
      }
      return result;
    } on FrameApiException {
      rethrow;
    } on Exception catch (error) {
      throw FrameApiException(message: '透過 WebView 連接 FRAME Reader 失敗：$error');
    }
  }

  Map<String, dynamic> _decodeJson(Map<String, dynamic> response) {
    final status = response['status'] as int? ?? 0;
    final contentType = response['contentType']?.toString().toLowerCase() ?? '';
    if (!contentType.contains('application/json')) {
      throw FrameApiException(
        message: 'Cloudflare Access 尚未完成登入，或 API 未回傳 JSON（HTTP $status）。',
        statusCode: status == 0 ? null : status,
      );
    }
    final decoded = jsonDecode(response['body']?.toString() ?? '');
    if (decoded is! Map<String, dynamic>) {
      throw const FrameApiException(message: 'FRAME API 回應格式不正確。');
    }
    if (status < 200 || status >= 300 || decoded['error'] != null) {
      throw FrameApiException(
        message: decoded['error']?.toString() ?? 'FRAME API 請求失敗（HTTP $status）。',
        statusCode: status,
      );
    }
    return decoded;
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      _decodeJson(await _request(method: 'GET', path: path));

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      _decodeJson(await _request(method: 'POST', path: path, body: body));

  @override
  Future<Uint8List> getBytes(String path) async {
    final response = await _request(method: 'GET', path: path, asBytes: true);
    final status = response['status'] as int? ?? 0;
    if (status < 200 || status >= 300) {
      throw FrameApiException(
        message: '讀取 FRAME 檔案失敗（HTTP $status）。',
        statusCode: status,
      );
    }
    return base64Decode(response['body']?.toString() ?? '');
  }

  @override
  void close() {}
}
