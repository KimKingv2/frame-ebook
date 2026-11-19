import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/transport/frame_cloud_file_source.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';
import 'package:frame_ebook/transport/frame_transport.dart';
import 'package:frame_ebook/transport/transport_result.dart';

class _RecordingTransport implements FrameTransport {
  Uri? openedUri;
  Map<String, String>? openedHeaders;
  FrameByteRange? openedRange;
  FrameFileCancellation? openedCancellation;
  int closeCount = 0;

  @override
  Future<FrameFileResponse> openStream({
    required Uri uri,
    Map<String, String> headers = const {},
    FrameByteRange? range,
    FrameFileCancellation? cancellation,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    openedUri = uri;
    openedHeaders = Map<String, String>.from(headers);
    openedRange = range;
    openedCancellation = cancellation;
    return FrameFileResponse(
      statusCode: range == null ? 200 : 206,
      headers: const {
        'Content-Type': 'application/epub+zip',
        'Content-Length': '3',
      },
      stream: Stream<List<int>>.fromIterable(const [
        [1, 2, 3],
      ]),
      onClose: () => closeCount++,
      requestedRange: range,
    );
  }

  @override
  Future<TransportResult> probeRange({
    required Uri uri,
    Map<String, String> headers = const {},
    int start = 0,
    int end = 1023,
    int maxBodyBytes = 4096,
    Duration timeout = const Duration(seconds: 25),
  }) async =>
      const TransportResult(
        statusCode: 206,
        headers: {'Content-Range': 'bytes 0-2/3'},
        bytesRead: 3,
        bodyTruncated: false,
        duration: Duration.zero,
      );

  @override
  void close() {}
}

FrameBook _book({
  String provider = 'vps',
  String library = 'books',
  String rootPath = '/Books',
  String path = '/Books/Novel.epub',
  String format = 'EPUB',
}) {
  return FrameBook.fromJson({
    'id': 'book-1',
    'provider': provider,
    'library': library,
    'rootPath': rootPath,
    'path': path,
    'fileName': path.split('/').last,
    'title': 'Novel',
    'author': 'Author',
    'format': format,
    'shelf': library,
  });
}

void main() {
  group('FrameCloudFileSource', () {
    test('builds the protected native redirect endpoint and keeps Access '
        'Cookie on the initial request only', () async {
      final transport = _RecordingTransport();
      Uri? cookieOrigin;
      final source = FrameCloudFileSource(
        baseUri: Uri.parse('https://frame-ebook.pages.dev/'),
        transport: transport,
        delivery: FrameCloudFileDelivery.nativeRedirect,
        accessCookieProvider: (origin) async {
          cookieOrigin = origin;
          return 'CF_Authorization=opaque-session';
        },
      );
      final range = FrameByteRange.from(start: 1024, end: 2047);
      final cancellation = FrameFileCancellation();

      final response = await source.open(FrameFileRequest(
        book: _book(),
        range: range,
        cancellation: cancellation,
      ));

      expect(transport.openedUri?.origin, 'https://frame-ebook.pages.dev');
      expect(transport.openedUri?.path, '/api/cloud/file');
      expect(transport.openedUri?.queryParameters, {
        'provider': 'vps',
        'library': 'books',
        'root_path': '/Books',
        'path': '/Books/Novel.epub',
        'delivery': 'redirect',
      });
      expect(cookieOrigin, Uri.parse('https://frame-ebook.pages.dev/'));
      expect(transport.openedHeaders, {
        'Cookie': 'CF_Authorization=opaque-session',
      });
      expect(transport.openedRange?.headerValue, 'bytes=1024-2047');
      expect(transport.openedCancellation, same(cancellation));
      expect(response.statusCode, 206);
      expect(response.requestedRange?.headerValue, 'bytes=1024-2047');
      await response.close();
      expect(transport.closeCount, 1);
    });

    test('builds the same-origin Pages Functions stream endpoint for Web',
        () async {
      final transport = _RecordingTransport();
      final source = FrameCloudFileSource(
        baseUri: Uri.parse('https://frame-ebook.pages.dev/'),
        transport: transport,
        delivery: FrameCloudFileDelivery.sameOriginStream,
      );

      await source.open(FrameFileRequest(
        book: _book(
          library: 'comics',
          rootPath: '/Comics',
          path: '/Comics/Issue.cbz',
          format: 'CBZ',
        ),
      ));

      expect(transport.openedUri?.queryParameters['delivery'], 'stream');
      expect(transport.openedUri?.queryParameters['library'], 'comics');
      expect(transport.openedHeaders, isEmpty);
      expect(transport.openedRange, isNull);
    });

    test('requires a cookie provider for native redirects', () {
      expect(
        () => FrameCloudFileSource(
          baseUri: Uri.parse('https://frame-ebook.pages.dev/'),
          transport: _RecordingTransport(),
          delivery: FrameCloudFileDelivery.nativeRedirect,
        ),
        throwsArgumentError,
      );
    });

    test('rejects local and unknown providers', () {
      final source = FrameCloudFileSource(
        baseUri: Uri.parse('https://frame-ebook.pages.dev/'),
        transport: _RecordingTransport(),
        delivery: FrameCloudFileDelivery.sameOriginStream,
      );
      expect(
        () => source.buildRequestUri(_book(provider: 'local')),
        throwsFormatException,
      );
    });

    test('rejects a path outside the selected library root', () {
      final source = FrameCloudFileSource(
        baseUri: Uri.parse('https://frame-ebook.pages.dev/'),
        transport: _RecordingTransport(),
        delivery: FrameCloudFileDelivery.sameOriginStream,
      );
      expect(
        () => source.buildRequestUri(
          _book(path: '/Other/Novel.epub'),
        ),
        throwsFormatException,
      );
    });

    test('rejects formats that the selected library does not serve', () {
      final source = FrameCloudFileSource(
        baseUri: Uri.parse('https://frame-ebook.pages.dev/'),
        transport: _RecordingTransport(),
        delivery: FrameCloudFileDelivery.sameOriginStream,
      );
      expect(
        () => source.buildRequestUri(
          _book(path: '/Books/Novel.pdf', format: 'PDF'),
        ),
        throwsFormatException,
      );
    });

    test('cancellation before open prevents cookie or network access', () async {
      final transport = _RecordingTransport();
      final cancellation = FrameFileCancellation()..cancel();
      final source = FrameCloudFileSource(
        baseUri: Uri.parse('https://frame-ebook.pages.dev/'),
        transport: transport,
        delivery: FrameCloudFileDelivery.sameOriginStream,
      );

      await expectLater(
        source.open(FrameFileRequest(
          book: _book(),
          cancellation: cancellation,
        )),
        throwsStateError,
      );
      expect(transport.openedUri, isNull);
    });
  });
}
