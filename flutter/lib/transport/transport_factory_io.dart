import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'frame_file_source.dart';
import 'frame_transport.dart';
import 'transport_result.dart';

FrameTransport createFrameTransport() => _NativeFrameTransport();

class _NativeFrameTransport implements FrameTransport {
  _NativeFrameTransport()
      : _client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 20)
          ..autoUncompress = false;

  final HttpClient _client;

  @override
  Future<TransportResult> probeRange({
    required Uri uri,
    Map<String, String> headers = const {},
    int start = 0,
    int end = 1023,
    int maxBodyBytes = 4096,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    _validateUri(uri);
    if (start < 0 || end < start || maxBodyBytes < 1) {
      throw ArgumentError('Range 或最大回應大小不正確。');
    }

    final stopwatch = Stopwatch()..start();
    final originalOrigin = _origin(uri);
    final visited = <String>{};
    var current = uri;
    var redirectCount = 0;

    while (true) {
      if (!visited.add(current.toString())) {
        throw const HttpException('偵測到 HTTP 跳轉循環。');
      }
      if (redirectCount > 10) {
        throw const HttpException('HTTP 跳轉超過 10 次上限。');
      }

      final request = await _client.openUrl('GET', current).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final sameOrigin = redirectCount == 0 && _origin(current) == originalOrigin;
      for (final entry in headers.entries) {
        final name = entry.key.toLowerCase();
        if (_blockedRequestHeaders.contains(name)) continue;
        if (!sameOrigin && _sensitiveHeaders.contains(name)) continue;
        request.headers.set(entry.key, entry.value);
      }

      final response = await request.close().timeout(timeout);
      if (_isRedirect(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || location.trim().isEmpty) {
          throw HttpException(
            'HTTP ${response.statusCode} 沒有 Location 標頭。',
            uri: current,
          );
        }
        final next = current.resolve(location.trim());
        _validateUri(next);
        if (current.scheme == 'https' && next.scheme != 'https') {
          throw const HttpException('已阻止 HTTPS 降級到 HTTP 的跳轉。');
        }
        current = next;
        redirectCount += 1;
        continue;
      }

      final builder = BytesBuilder(copy: false);
      var truncated = false;
      await for (final chunk in response.timeout(timeout)) {
        final remaining = maxBodyBytes - builder.length;
        if (remaining <= 0) {
          truncated = true;
          break;
        }
        final take = math.min(remaining, chunk.length).toInt();
        builder.add(take == chunk.length ? chunk : chunk.sublist(0, take));
        if (take < chunk.length || builder.length >= maxBodyBytes) {
          truncated = true;
          break;
        }
      }

      final responseHeaders = <String, String>{};
      for (final name in _visibleResponseHeaders) {
        final value = response.headers.value(name);
        if (value != null) responseHeaders[name] = value;
      }

      stopwatch.stop();
      return TransportResult(
        statusCode: response.statusCode,
        headers: responseHeaders,
        bytesRead: builder.length,
        bodyTruncated: truncated,
        duration: stopwatch.elapsed,
        finalUri: _safeUri(current),
        redirectCount: redirectCount,
      );
    }
  }


  @override
  Future<FrameFileResponse> openStream({
    required Uri uri,
    Map<String, String> headers = const {},
    FrameByteRange? range,
    FrameFileCancellation? cancellation,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    _validateUri(uri);
    if (cancellation?.isCancelled == true) {
      throw const HttpException('檔案讀取已取消。');
    }

    final originalOrigin = _origin(uri);
    final visited = <String>{};
    var current = uri;
    var redirectCount = 0;
    var cancelled = false;
    HttpClientRequest? activeRequest;
    StreamSubscription<List<int>>? activeSubscription;
    StreamController<List<int>>? bodyController;

    void abortRequest() {
      cancelled = true;
      activeRequest?.abort(const HttpException('檔案讀取已取消。'));
      final subscription = activeSubscription;
      if (subscription != null) unawaited(subscription.cancel());
      final controller = bodyController;
      if (controller != null && !controller.isClosed) {
        unawaited(controller.close());
      }
    }

    if (cancellation != null) {
      unawaited(cancellation.whenCancelled.then((_) => abortRequest()));
    }

    try {
      while (true) {
        if (cancelled || cancellation?.isCancelled == true) {
          throw const HttpException('檔案讀取已取消。');
        }
        if (!visited.add(current.toString())) {
          throw const HttpException('偵測到 HTTP 跳轉循環。');
        }
        if (redirectCount > 10) {
          throw const HttpException('HTTP 跳轉超過 10 次上限。');
        }

        final request = await _client.openUrl('GET', current).timeout(timeout);
        activeRequest = request;
        if (cancelled || cancellation?.isCancelled == true) {
          request.abort(const HttpException('檔案讀取已取消。'));
          throw const HttpException('檔案讀取已取消。');
        }

        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final requestedRange = range;
        if (requestedRange != null) {
          request.headers.set(
            HttpHeaders.rangeHeader,
            requestedRange.headerValue,
          );
        }

        // Credentials are valid only for the initial Pages request. Do not
        // restore them if a redirect chain later returns to the Pages origin.
        final sameOrigin =
            redirectCount == 0 && _origin(current) == originalOrigin;
        for (final entry in headers.entries) {
          final name = entry.key.toLowerCase();
          if (_blockedRequestHeaders.contains(name)) continue;
          if (!sameOrigin && _sensitiveHeaders.contains(name)) continue;
          request.headers.set(entry.key, entry.value);
        }

        final response = await request.close().timeout(timeout);
        if (cancelled || cancellation?.isCancelled == true) {
          request.abort(const HttpException('檔案讀取已取消。'));
          throw const HttpException('檔案讀取已取消。');
        }

        if (_isRedirect(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null || location.trim().isEmpty) {
            throw HttpException(
              'HTTP ' + response.statusCode.toString() + ' 沒有 Location 標頭。',
              uri: current,
            );
          }
          final next = current.resolve(location.trim());
          _validateUri(next);
          if (_isAccessLogin(next)) {
            throw const HttpException(
              'Cloudflare Access 登入已過期，請返回書架重新登入。',
            );
          }
          if (current.scheme == 'https' && next.scheme != 'https') {
            throw const HttpException('已阻止 HTTPS 降級到 HTTP 的跳轉。');
          }
          current = next;
          redirectCount += 1;
          continue;
        }

        final responseHeaders = <String, String>{};
        for (final name in _visibleResponseHeaders) {
          final value = response.headers.value(name);
          if (value != null) responseHeaders[name] = value;
        }

        late final StreamController<List<int>> controller;
        controller = StreamController<List<int>>(
          onListen: () {
            activeSubscription = response.timeout(timeout).listen(
              controller.add,
              onError: (Object error, StackTrace stackTrace) {
                if (controller.isClosed) return;
                controller.addError(error, stackTrace);
                unawaited(controller.close());
              },
              onDone: () {
                if (!controller.isClosed) unawaited(controller.close());
              },
              cancelOnError: true,
            );
          },
          onPause: () => activeSubscription?.pause(),
          onResume: () => activeSubscription?.resume(),
          onCancel: () async {
            await activeSubscription?.cancel();
            request.abort();
          },
        );
        bodyController = controller;

        return FrameFileResponse(
          statusCode: response.statusCode,
          headers: responseHeaders,
          requestedRange: requestedRange,
          stream: controller.stream,
          onClose: () async {
            cancelled = true;
            request.abort();
            await activeSubscription?.cancel();
            if (!controller.isClosed) unawaited(controller.close());
          },
        );
      }
    } catch (_) {
      activeRequest?.abort();
      rethrow;
    }
  }

  void _validateUri(Uri uri) {
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('HTTP 位址無效，或包含不允許的 URL 帳密。');
    }
  }

  String _origin(Uri uri) =>
      '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:${uri.port}';

  Uri _safeUri(Uri uri) => uri.replace(query: '', fragment: '');

  bool _isAccessLogin(Uri uri) {
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    return host.endsWith('.cloudflareaccess.com') ||
        path.startsWith('/cdn-cgi/access/login');
  }

  bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 ||
      status == 307 || status == 308;

  @override
  void close() => _client.close(force: true);
}

const _blockedRequestHeaders = <String>{
  'host', 'content-length', 'connection', 'transfer-encoding',
  'range', 'accept-encoding',
};

const _sensitiveHeaders = <String>{
  'authorization', 'cookie', 'proxy-authorization',
};

const _visibleResponseHeaders = <String>[
  'content-range', 'accept-ranges', 'content-length',
  'content-type', 'etag', 'last-modified',
];
