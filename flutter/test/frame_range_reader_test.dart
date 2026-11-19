import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/reader/frame_range_reader.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';

class _FakeFrameFileSource implements FrameFileSource {
  _FakeFrameFileSource(this.response);

  final FrameFileResponse response;
  FrameFileRequest? request;
  int openCount = 0;

  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    this.request = request;
    openCount += 1;
    return response;
  }
}

FrameBook _book({int size = 1000}) {
  return FrameBook.fromJson({
    'id': 'book-1',
    'provider': 'vps',
    'library': 'books',
    'rootPath': '/Books',
    'path': '/Books/Novel.epub',
    'fileName': 'Novel.epub',
    'title': 'Novel',
    'author': 'Author',
    'format': 'EPUB',
    'shelf': 'books',
    'size': size,
  });
}

FrameFileResponse _response({
  int statusCode = 206,
  String? contentRange,
  String? contentLength,
  required List<int> bytes,
  required void Function() onClose,
  void Function()? onListen,
}) {
  return FrameFileResponse(
    statusCode: statusCode,
    headers: {
      if (contentRange != null) 'content-range': contentRange,
      if (contentLength != null) 'content-length': contentLength,
      'accept-ranges': 'bytes',
    },
    stream: Stream<List<int>>.multi((controller) {
      onListen?.call();
      controller.add(bytes);
      controller.close();
    }),
    onClose: onClose,
  );
}

void main() {
  group('FrameRangeReader', () {
    test('requests and returns only the exact requested byte range', () async {
      var closeCount = 0;
      final source = _FakeFrameFileSource(
        _response(
          contentRange: 'bytes 10-13/1000',
          contentLength: '4',
          bytes: [10, 11, 12, 13],
          onClose: () => closeCount++,
        ),
      );
      final reader = FrameRangeReader(source: source, book: _book());

      final result = await reader.readRange(10, 13);

      expect(source.openCount, 1);
      expect(source.request?.range?.headerValue, 'bytes=10-13');
      expect(source.request?.book.id, 'book-1');
      expect(result.bytes, [10, 11, 12, 13]);
      expect(result.start, 10);
      expect(result.end, 13);
      expect(result.totalLength, 1000);
      expect(closeCount, 1);
    });

    test('rejects HTTP 200 before listening to the full-file body', () async {
      var listened = false;
      var closeCount = 0;
      final source = _FakeFrameFileSource(
        _response(
          statusCode: 200,
          bytes: List<int>.filled(1000, 1),
          onClose: () => closeCount++,
          onListen: () => listened = true,
        ),
      );
      final reader = FrameRangeReader(source: source, book: _book());

      await expectLater(
        reader.readRange(0, 3),
        throwsA(isA<FrameRangeReadException>()),
      );

      expect(listened, isFalse);
      expect(closeCount, 1);
    });

    test('rejects a mismatched Content-Range and closes the response', () async {
      var closeCount = 0;
      final source = _FakeFrameFileSource(
        _response(
          contentRange: 'bytes 9-12/1000',
          contentLength: '4',
          bytes: [9, 10, 11, 12],
          onClose: () => closeCount++,
        ),
      );
      final reader = FrameRangeReader(source: source, book: _book());

      await expectLater(
        reader.readRange(10, 13),
        throwsA(isA<FrameRangeReadException>()),
      );
      expect(closeCount, 1);
    });

    test('rejects a truncated response body', () async {
      var closeCount = 0;
      final source = _FakeFrameFileSource(
        _response(
          contentRange: 'bytes 10-13/1000',
          contentLength: '4',
          bytes: [10, 11, 12],
          onClose: () => closeCount++,
        ),
      );
      final reader = FrameRangeReader(source: source, book: _book());

      await expectLater(
        reader.readRange(10, 13),
        throwsA(isA<FrameRangeReadException>()),
      );
      expect(closeCount, 1);
    });

    test('rejects a range larger than the configured memory bound', () async {
      final source = _FakeFrameFileSource(
        _response(
          contentRange: 'bytes 0-3/1000',
          contentLength: '4',
          bytes: [0, 1, 2, 3],
          onClose: () {},
        ),
      );
      final reader = FrameRangeReader(
        source: source,
        book: _book(),
        maxRangeBytes: 3,
      );

      await expectLater(
        reader.readRange(0, 3),
        throwsA(isA<FrameRangeReadException>()),
      );
      expect(source.openCount, 0);
    });

    test('reads an unknown-size archive tail using a suffix Range', () async {
      var closeCount = 0;
      final source = _FakeFrameFileSource(
        _response(
          contentRange: 'bytes 6-9/10',
          contentLength: '4',
          bytes: [6, 7, 8, 9],
          onClose: () => closeCount++,
        ),
      );
      final reader = FrameRangeReader(source: source, book: _book(size: 0));

      final result = await reader.readSuffix(4);

      expect(source.request?.range?.headerValue, 'bytes=-4');
      expect(result.bytes, [6, 7, 8, 9]);
      expect(result.start, 6);
      expect(result.end, 9);
      expect(result.totalLength, 10);
      expect(closeCount, 1);
    });

    test('rejects a file-size change against the indexed book descriptor', () async {
      var closeCount = 0;
      final source = _FakeFrameFileSource(
        _response(
          contentRange: 'bytes 10-13/999',
          contentLength: '4',
          bytes: [10, 11, 12, 13],
          onClose: () => closeCount++,
        ),
      );
      final reader = FrameRangeReader(source: source, book: _book(size: 1000));

      await expectLater(
        reader.readRange(10, 13),
        throwsA(isA<FrameRangeReadException>()),
      );
      expect(closeCount, 1);
    });
  });
}
