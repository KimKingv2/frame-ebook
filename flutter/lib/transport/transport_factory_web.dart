import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:http/browser_client.dart';
import 'package:web/web.dart' as web;
import 'package:http/http.dart' as http;

import 'frame_file_source.dart';
import 'frame_transport.dart';
import 'transport_result.dart';

FrameTransport createFrameTransport() => _BrowserFrameTransport();

class _BrowserFrameTransport implements FrameTransport {
  static const _visibleResponseHeaders = <String>[
    'accept-ranges',
    'cache-control',
    'content-disposition',
    'content-encoding',
    'content-length',
    'content-range',
    'content-type',
    'etag',
    'last-modified',
    'x-content-type-options',
  ];

  final BrowserClient _client = BrowserClient()..withCredentials = false;
  final Set<web.AbortController> _activeStreams = <web.AbortController>{};

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
  Future<FrameFileResponse> openStream({
    required Uri uri,
    Map<String, String> headers = const {},
    FrameByteRange? range,
    FrameFileCancellation? cancellation,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.origin != web.window.location.origin ||
        cancellation?.isCancelled == true) {
      throw const FormatException('Web 閱讀請求必須使用有效的 HTTPS 同源網址。');
    }

    final abortController = web.AbortController();
    _activeStreams.add(abortController);
    web.ReadableStreamDefaultReader<JSUint8Array>? reader;
    var cancelled = false;
    StreamController<List<int>>? bodyController;

    void abortRequest() {
      cancelled = true;
      _activeStreams.remove(abortController);
      abortController.abort();
      final currentReader = reader;
      if (currentReader != null) {
        unawaited(currentReader.cancel().toDart);
      }
      final controller = bodyController;
      if (controller != null && !controller.isClosed) {
        unawaited(controller.close());
      }
    }

    cancellation?.whenCancelled.then((_) => abortRequest());

    final requestHeaders = web.Headers();
    requestHeaders.set('Accept', '*/*');
    if (range != null) requestHeaders.set('Range', range.headerValue);
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'accept') {
        requestHeaders.set(entry.key, entry.value);
      }
    }

    final init = web.RequestInit(
      method: 'GET',
      headers: requestHeaders,
      credentials: 'same-origin',
      redirect: 'error',
      cache: 'no-store',
      signal: abortController.signal,
    );

    late final web.Response response;
    try {
      response = await web.window.fetch(uri.toString().toJS, init).toDart;
    } catch (_) {
      _activeStreams.remove(abortController);
      if (cancelled || cancellation?.isCancelled == true) {
        throw StateError('檔案讀取已取消。');
      }
      rethrow;
    }
    if (cancelled || cancellation?.isCancelled == true) {
      abortRequest();
      throw StateError('檔案讀取已取消。');
    }

    final responseHeaders = <String, String>{};
    for (final name in _visibleResponseHeaders) {
      final value = response.headers.get(name);
      if (value != null) responseHeaders[name] = value;
    }

    late final StreamController<List<int>> controller;
    var paused = false;
    Completer<void>? resumeSignal;

    Future<void> pumpFetchBody() async {
      final currentReader = reader;
      if (currentReader == null) {
        _activeStreams.remove(abortController);
        if (!controller.isClosed) await controller.close();
        return;
      }
      try {
        while (!cancelled) {
          if (paused) await resumeSignal?.future;
          if (cancelled) break;
          final result = await currentReader.read().toDart;
          if (result.done) break;
          final chunk = result.value;
          if (chunk != null && !controller.isClosed) {
            controller.add(chunk.toDart);
          }
        }
        _activeStreams.remove(abortController);
        if (!controller.isClosed) await controller.close();
      } catch (error, stackTrace) {
        _activeStreams.remove(abortController);
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
          await controller.close();
        }
      }
    }

    controller = StreamController<List<int>>(
      onListen: () => unawaited(pumpFetchBody()),
      onPause: () {
        paused = true;
        resumeSignal ??= Completer<void>();
      },
      onResume: () {
        paused = false;
        final signal = resumeSignal;
        if (signal != null && !signal.isCompleted) signal.complete();
        resumeSignal = null;
      },
      onCancel: () async {
        abortRequest();
      },
    );
    bodyController = controller;
    reader = response.body?.getReader();

    return FrameFileResponse(
      statusCode: response.status,
      headers: responseHeaders,
      requestedRange: range,
      stream: controller.stream,
      onClose: () async {
        abortRequest();
      },
    );
  }

  @override
  void close() {
    for (final controller in _activeStreams.toList()) {
      controller.abort();
    }
    _activeStreams.clear();
    _client.close();
  }
}
