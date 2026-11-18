import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

import 'webdav_transport.dart';

WebDavTransport createWebDavTransport() => _BrowserWebDavTransport();

class _BrowserWebDavTransport implements WebDavTransport {
  final BrowserClient _client = BrowserClient()..withCredentials = false;

  @override
  bool get browserManagedRedirect => true;

  @override
  Future<WebDavHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    List<int>? body,
    int maxResponseBytes = 1024 * 1024,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = true
      ..maxRedirects = 8
      ..headers.addAll(headers);
    if (body != null) request.bodyBytes = Uint8List.fromList(body);

    final response = await _client.send(request).timeout(timeout);
    final builder = BytesBuilder(copy: false);
    var truncated = false;
    await for (final chunk in response.stream.timeout(timeout)) {
      final remaining = maxResponseBytes - builder.length;
      if (remaining <= 0) {
        truncated = true;
        break;
      }
      final take = math.min(remaining, chunk.length).toInt();
      builder.add(take == chunk.length ? chunk : chunk.sublist(0, take));
      if (take < chunk.length) {
        truncated = true;
        break;
      }
    }

    return WebDavHttpResponse(
      statusCode: response.statusCode,
      headers: Map<String, String>.from(response.headers),
      body: builder.takeBytes(),
      bodyTruncated: truncated,
    );
  }

  @override
  void close() => _client.close();
}
