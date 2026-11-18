import 'dart:math' as math;

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

import 'frame_transport.dart';
import 'transport_result.dart';

FrameTransport createFrameTransport() => _BrowserFrameTransport();

class _BrowserFrameTransport implements FrameTransport {
  final BrowserClient _client = BrowserClient()..withCredentials = false;

  @override
  Future<TransportResult> probeRange({
    required Uri uri,
    Map<String, String> headers = const {},
    int start = 0,
    int end = 1023,
    int maxBodyBytes = 4096,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        start < 0 ||
        end < start ||
        maxBodyBytes < 1) {
      throw const FormatException('HTTP 位址、Range 或回應大小不正確。');
    }

    final stopwatch = Stopwatch()..start();
    final request = http.Request('GET', uri)
      ..followRedirects = true
      ..maxRedirects = 10
      ..headers.addAll(headers)
      ..headers['Range'] = 'bytes=$start-$end'
      ..headers['Accept'] = '*/*';

    // Fetch controls Accept-Encoding. Cross-origin redirects require CORS.
    final response = await _client.send(request).timeout(timeout);
    final body = <int>[];
    var truncated = false;
    await for (final chunk in response.stream.timeout(timeout)) {
      final remaining = maxBodyBytes - body.length;
      if (remaining <= 0) {
        truncated = true;
        break;
      }
      final take = math.min(remaining, chunk.length).toInt();
      body.addAll(chunk.take(take));
      if (take < chunk.length || body.length >= maxBodyBytes) {
        truncated = true;
        break;
      }
    }

    stopwatch.stop();
    return TransportResult(
      statusCode: response.statusCode,
      headers: Map<String, String>.from(response.headers),
      bytesRead: body.length,
      bodyTruncated: truncated,
      duration: stopwatch.elapsed,
      browserManagedRedirect: true,
      finalUri: null,
      redirectCount: null,
    );
  }

  @override
  void close() => _client.close();
}
