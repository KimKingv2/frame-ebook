import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'local_openlist_transport.dart';

LocalOpenListTransport createLocalOpenListTransport() =>
    _IoLocalOpenListTransport();

class _IoLocalOpenListTransport implements LocalOpenListTransport {
  final http.Client _client = http.Client();

  @override
  Future<LocalOpenListHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    List<int>? body,
    bool followRedirects = false,
    int maxRedirects = 5,
    int maxResponseBytes = 1024 * 1024,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = followRedirects
      ..maxRedirects = maxRedirects
      ..headers.addAll(headers);
    if (body != null) request.bodyBytes = body;
    final streamed = await _client.send(request).timeout(timeout);
    final builder = <int>[];
    var truncated = false;
    await for (final chunk in streamed.stream.timeout(timeout)) {
      final remaining = maxResponseBytes - builder.length;
      if (remaining <= 0) {
        truncated = true;
        break;
      }
      final take = math.min(remaining, chunk.length).toInt();
      builder.addAll(chunk.take(take));
      if (take < chunk.length) {
        truncated = true;
        break;
      }
    }
    return LocalOpenListHttpResponse(
      statusCode: streamed.statusCode,
      headers: Map<String, String>.from(streamed.headers),
      body: Uint8List.fromList(builder),
      bodyTruncated: truncated,
    );
  }

  @override
  void close() => _client.close();
}
