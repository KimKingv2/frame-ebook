import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';
import 'package:frame_ebook/transport/transport_factory.dart';
import 'package:frame_ebook/transport/frame_transport.dart';

void main() {
  group('Native 302 and Range transport', () {
    late HttpServer firstServer;
    late HttpServer secondServer;
    late FrameTransport transport;

    setUp(() async {
      secondServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      secondServer.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/auth-check') {
          response.statusCode = request.headers.value('range') == 'bytes=0-1023'
              ? HttpStatus.partialContent
              : HttpStatus.badRequest;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-1023/8192');
          response.headers.set(
            HttpHeaders.etagHeader,
            request.headers.value(HttpHeaders.authorizationHeader) == null
                ? '"stripped"'
                : '"leaked"',
          );
          response.add(List<int>.filled(1024, 65));
        } else if (request.uri.path == '/stream-auth-check') {
          final safe =
              request.headers.value(HttpHeaders.authorizationHeader) == null &&
                  request.headers.value(HttpHeaders.cookieHeader) == null;
          response.statusCode =
              request.headers.value(HttpHeaders.rangeHeader) == 'bytes=4-7'
                  ? HttpStatus.partialContent
                  : HttpStatus.badRequest;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 4-7/16');
          response.headers.set(HttpHeaders.contentLengthHeader, '4');
          response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          response.headers.set(HttpHeaders.etagHeader, safe ? '"stripped"' : '"leaked"');
          response.add([4, 5, 6, 7]);
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });

      firstServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      firstServer.listen((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/redirect':
            response.statusCode = HttpStatus.found;
            response.headers.set(HttpHeaders.locationHeader, '/range');
            break;
          case '/cross-origin':
            response.statusCode = HttpStatus.found;
            response.headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${secondServer.port}/auth-check',
            );
            break;
          case '/stream-cross-origin':
            response.statusCode = HttpStatus.found;
            response.headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${secondServer.port}/stream-auth-check',
            );
            break;
          case '/loop':
            response.statusCode = HttpStatus.found;
            response.headers.set(HttpHeaders.locationHeader, '/loop');
            break;
          case '/ignore':
            response.statusCode = HttpStatus.ok;
            response.add(List<int>.filled(8192, 66));
            break;
          case '/range':
            response.statusCode = request.headers.value('range') == 'bytes=0-1023'
                ? HttpStatus.partialContent
                : HttpStatus.badRequest;
            response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-1023/8192');
            response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
            response.add(List<int>.filled(1024, 67));
            break;
          default:
            response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });

      transport = createFrameTransport();
    });

    tearDown(() async {
      transport.close();
      await firstServer.close(force: true);
      await secondServer.close(force: true);
    });

    test('follows a relative 302 and preserves the Range header', () async {
      final result = await transport.probeRange(
        uri: Uri.parse('http://127.0.0.1:${firstServer.port}/redirect'),
      );

      expect(result.statusCode, HttpStatus.partialContent);
      expect(result.redirectCount, 1);
      expect(result.contentRange, 'bytes 0-1023/8192');
      expect(result.bytesRead, 1024);
      expect(result.finalUri?.path, '/range');
    });

    test('does not forward Authorization to another origin', () async {
      final result = await transport.probeRange(
        uri: Uri.parse('http://127.0.0.1:${firstServer.port}/cross-origin'),
        headers: {'Authorization': 'Basic not-a-real-secret'},
      );

      expect(result.statusCode, HttpStatus.partialContent);
      expect(result.redirectCount, 1);
      expect(result.headers['etag'], '"stripped"');
    });

    test('detects a server that ignores Range and returns 200', () async {
      final result = await transport.probeRange(
        uri: Uri.parse('http://127.0.0.1:${firstServer.port}/ignore'),
        maxBodyBytes: 4096,
      );

      expect(result.statusCode, HttpStatus.ok);
      expect(result.bytesRead, 4096);
      expect(result.bodyTruncated, isTrue);
    });


    test('streams a 302 Range response without forwarding Access credentials',
        () async {
      final response = await transport.openStream(
        uri: Uri.parse(
          'http://127.0.0.1:${firstServer.port}/stream-cross-origin',
        ),
        headers: const {
          'Cookie': 'CF_Authorization=opaque-session',
          'Authorization': 'Bearer not-a-real-secret',
        },
        range: FrameByteRange.from(start: 4, end: 7),
      );

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.isPartialContent, isTrue);
      expect(response.contentRange, 'bytes 4-7/16');
      expect(response.contentLength, 4);
      expect(response.acceptsRanges, isTrue);
      expect(response.headers['etag'], '"stripped"');
      expect(response.headers.containsKey('location'), isFalse);

      final bytes = await response.stream.expand((chunk) => chunk).toList();
      expect(bytes, [4, 5, 6, 7]);
      await response.close();
      await response.close();
    });

    test('cancels an in-flight native stream', () async {
      final cancellation = FrameFileCancellation();
      final response = await transport.openStream(
        uri: Uri.parse('http://127.0.0.1:${firstServer.port}/range'),
        range: FrameByteRange.from(start: 0, end: 1023),
        cancellation: cancellation,
      );

      expect(response.statusCode, HttpStatus.partialContent);
      cancellation.cancel();
      await expectLater(response.stream, emitsDone);
      await response.close();
      expect(response.isClosed, isTrue);
    });

    test('rejects a redirect loop', () async {
      final future = transport.probeRange(
        uri: Uri.parse('http://127.0.0.1:${firstServer.port}/loop'),
      );

      await expectLater(future, throwsA(isA<HttpException>()));
    });
  });
}
