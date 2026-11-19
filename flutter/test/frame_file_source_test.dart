import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';

void main() {
  group('FrameByteRange', () {
    test('formats a bounded inclusive range', () {
      final range = FrameByteRange.from(start: 0, end: 1023);

      expect(range.headerValue, 'bytes=0-1023');
      expect(range.start, 0);
      expect(range.end, 1023);
      expect(range.suffixLength, isNull);
    });

    test('formats an open-ended range', () {
      final range = FrameByteRange.from(start: 1048576);

      expect(range.headerValue, 'bytes=1048576-');
    });

    test('formats a suffix range', () {
      final range = FrameByteRange.suffix(4096);

      expect(range.headerValue, 'bytes=-4096');
      expect(range.start, isNull);
      expect(range.end, isNull);
      expect(range.suffixLength, 4096);
    });

    test('rejects invalid range bounds', () {
      expect(
        () => FrameByteRange.from(start: -1),
        throwsArgumentError,
      );
      expect(
        () => FrameByteRange.from(start: 10, end: 9),
        throwsArgumentError,
      );
      expect(
        () => FrameByteRange.suffix(0),
        throwsArgumentError,
      );
    });
  });

  group('FrameFileRequest', () {
    test('keeps the indexed book and optional range together', () {
      final book = FrameBook.fromJson({
        'id': 'book-1',
        'provider': 'vps',
        'library': 'books',
        'rootPath': '/books',
        'path': '/books/example.epub',
        'fileName': 'example.epub',
        'format': 'EPUB',
      });
      final range = FrameByteRange.from(start: 0, end: 31);
      final request = FrameFileRequest(book: book, range: range);

      expect(request.book.id, 'book-1');
      expect(request.book.descriptor()['provider'], 'vps');
      expect(request.range?.headerValue, 'bytes=0-31');
    });
  });

  group('FrameFileResponse', () {
    test('normalizes headers and exposes range metadata', () {
      final response = FrameFileResponse(
        statusCode: 206,
        stream: Stream<List<int>>.value([1, 2, 3]),
        onClose: () {},
        requestedRange: FrameByteRange.from(start: 1, end: 3),
        headers: const {
          'Content-Type': 'application/epub+zip',
          'Content-Length': '3',
          'Content-Range': 'bytes 1-3/10',
          'Accept-Ranges': 'bytes',
          'Set-Cookie': 'sensitive=secret',
          'Location': 'https://signed-storage.example/file',
        },
      );

      expect(response.isSuccess, isTrue);
      expect(response.isPartialContent, isTrue);
      expect(response.contentType, 'application/epub+zip');
      expect(response.contentLength, 3);
      expect(response.contentRange, 'bytes 1-3/10');
      expect(response.acceptsRanges, isTrue);
      expect(
        response.headers.keys,
        unorderedEquals([
          'content-type',
          'content-length',
          'content-range',
          'accept-ranges',
        ]),
      );
      expect(response.headers.containsKey('set-cookie'), isFalse);
      expect(response.headers.containsKey('location'), isFalse);
      expect(
        () => response.headers['x-test'] = 'mutable',
        throwsUnsupportedError,
      );
    });

    test('exposes a one-shot byte stream without buffering it', () async {
      final response = FrameFileResponse(
        statusCode: 200,
        stream: Stream<List<int>>.fromIterable([
          [1, 2],
          [3, 4],
        ]),
        onClose: () {},
      );

      await expectLater(response.stream, emitsInOrder([
        [1, 2],
        [3, 4],
      ]));
    });

    test('close is idempotent and releases the source once', () async {
      var closeCount = 0;
      final response = FrameFileResponse(
        statusCode: 200,
        stream: const Stream<List<int>>.empty(),
        onClose: () async {
          closeCount++;
        },
      );

      expect(response.isClosed, isFalse);
      await response.close();
      await response.close();

      expect(response.isClosed, isTrue);
      expect(closeCount, 1);
    });

    test('keeps failed HTTP status visible to the caller', () {
      final response = FrameFileResponse(
        statusCode: 416,
        stream: const Stream<List<int>>.empty(),
        onClose: () {},
        headers: const {
          'Content-Range': 'bytes */10',
        },
        requestedRange: FrameByteRange.from(start: 100),
      );

      expect(response.isSuccess, isFalse);
      expect(response.isPartialContent, isFalse);
      expect(response.contentRange, 'bytes */10');
      expect(response.statusCode, 416);
    });
  });
}
