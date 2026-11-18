import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'webdav_transport.dart';

WebDavTransport createWebDavTransport() => _IoWebDavTransport();

class _IoWebDavTransport implements WebDavTransport {
  _IoWebDavTransport()
      : _client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 30)
          ..autoUncompress = false;

  final HttpClient _client;

  @override
  bool get browserManagedRedirect => false;

  @override
  Future<WebDavHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    List<int>? body,
    int maxResponseBytes = 1024 * 1024,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request = await _client.openUrl(method, uri).timeout(timeout);
    request.followRedirects = false;
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (body != null && body.isNotEmpty) request.add(body);

    final response = await request.close().timeout(timeout);
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      responseHeaders[name.toLowerCase()] = values.join(', ');
    });

    final builder = BytesBuilder(copy: false);
    var truncated = false;
    await for (final chunk in response.timeout(timeout)) {
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
      headers: responseHeaders,
      body: builder.takeBytes(),
      bodyTruncated: truncated,
    );
  }

  @override
  void close() => _client.close(force: true);
}
