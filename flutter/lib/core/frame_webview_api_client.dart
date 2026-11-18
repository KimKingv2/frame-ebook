import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:webview_flutter/webview_flutter.dart';

import 'frame_api_client.dart';

/// Executes API calls inside the WebView that owns the Cloudflare Access
/// HttpOnly cookie. A JavaScript channel returns async fetch() results to Dart.
class FrameWebViewApiClient implements FrameApiClient {
  FrameWebViewApiClient({required this.baseUri, required this.controller}) {
    _channelReady = controller.addJavaScriptChannel(
      'FrameApiBridge',
      onMessageReceived: _receiveMessage,
    );
  }

  final Uri baseUri;
  final WebViewController controller;

  late final Future<void> _channelReady;
  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};
  int _requestSequence = 0;

  Future<void> get ready => _channelReady;

  void _receiveMessage(JavaScriptMessage message) {
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map<String, dynamic>) return;
      final id = decoded['id']?.toString();
      if (id == null) return;
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      completer.complete(decoded);
    } on FormatException {
      // Ignore malformed messages from pages that do not belong to this API call.
    }
  }

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
    await _channelReady;
    final currentUrl = await controller.currentUrl();
    final currentUri =
        currentUrl == null ? null : Uri.tryParse(currentUrl);
    if (currentUri == null ||
        currentUri.origin != baseUri.origin ||
        currentUri.path.startsWith('/cdn-cgi/access/')) {
      throw const FrameApiException(
        message: 'WebView 尚未返回 FRAME Ebook，請先完成 Cloudflare Access 登入。',
      );
    }

    final uri = _resolve(path);
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    final bodyLiteral = body == null ? 'null' : jsonEncode(jsonEncode(body));
    final script = '''
(() => {
  const requestId = ${jsonEncode(requestId)};
  const deliver = (payload) => {
    try {
      window.FrameApiBridge.postMessage(JSON.stringify(payload));
    } catch (_) {}
  };
  (async () => {
    try {
      const origin = ${jsonEncode(baseUri.origin)};
      if (window.location.origin !== origin) {
        deliver({id:requestId,ok:false,error:'WebView 尚未返回 FRAME Ebook，請先完成 Cloudflare Access 登入。'});
        return;
      }
      const url = new URL(${jsonEncode(uri.toString())});
      if (url.origin !== origin) {
        deliver({id:requestId,ok:false,error:'已阻止跨網域 API 請求。'});
        return;
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
        deliver({id:requestId,ok:false,error:'FRAME API 被重新導向至非正式站網域，已停止請求。'});
        return;
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
      deliver({
        id:requestId,
        ok:true,
        status:response.status,
        contentType:response.headers.get('content-type') || '',
        body:responseBody
      });
    } catch (error) {
      deliver({id:requestId,ok:false,error:String(error)});
    }
  })();
})();
''';

    try {
      await controller.runJavaScript(script).timeout(
            const Duration(seconds: 10),
          );
      final result = await completer.future.timeout(
        const Duration(seconds: 60),
      );
      if (result['ok'] != true) {
        throw FrameApiException(
          message: result['error']?.toString() ?? 'WebView API 請求失敗。',
        );
      }
      return result;
    } on TimeoutException {
      throw const FrameApiException(
        message: 'WebView API 等待逾時，請確認網路與 Cloudflare Access 登入狀態。',
      );
    } finally {
      _pending.remove(requestId);
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
        message:
            decoded['error']?.toString() ?? 'FRAME API 請求失敗（HTTP $status）。',
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
  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      _decodeJson(await _request(method: 'DELETE', path: path, body: body));

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
  void close() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const FrameApiException(message: 'WebView API 用戶端已關閉。'),
        );
      }
    }
    _pending.clear();
    unawaited(controller.removeJavaScriptChannel('FrameApiBridge'));
  }
}
