import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/cloud/local_openlist_client.dart';
import 'package:frame_ebook/cloud/local_openlist_transport.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';
import 'package:frame_ebook/transport/frame_local_openlist_file_source.dart';

class _FakeLocalOpenListTransport implements LocalOpenListTransport {
  _FakeLocalOpenListTransport(this.fileBytes);

  final Uint8List fileBytes;
  final List<(int start, int end)> ranges = [];
  bool closed = false;

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
    if (closed) throw StateError('Transport is closed.');
    if (uri.path.endsWith('/api/auth/login')) {
      return _json({'code': 200, 'data': {'token': 'memory-only-test-token'}});
    }
    if (uri.path.endsWith('/api/fs/get')) {
      return _json({
        'code': 200,
        'data': {
          'name': 'sample.epub',
          'size': fileBytes.length,
          'raw_url': 'https://files.example.test/sample.epub',
        },
      });
    }
    if (uri.host == 'files.example.test') {
      String? rangeHeader;
      for (final entry in headers.entries) {
        if (entry.key.toLowerCase() == 'range') {
          rangeHeader = entry.value;
          break;
        }
      }
      final match = RegExp(r'^bytes=(\d+)-(\d+)$')
          .firstMatch(rangeHeader ?? '');
      if (method != 'GET' || match == null) {
        return LocalOpenListHttpResponse(
          statusCode: 400,
          headers: const {},
          body: Uint8List(0),
          bodyTruncated: false,
        );
      }
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      if (start < 0 || end < start || end >= fileBytes.length) {
        return LocalOpenListHttpResponse(
          statusCode: 416,
          headers: const {},
          body: Uint8List(0),
          bodyTruncated: false,
        );
      }
      ranges.add((start, end));
      final bytes = fileBytes.sublist(start, end + 1);
      if (bytes.length > maxResponseBytes) {
        return LocalOpenListHttpResponse(
          statusCode: 206,
          headers: {
            'content-range': 'bytes $start-$end/${fileBytes.length}',
            'content-length': bytes.length.toString(),
          },
          body: Uint8List.fromList(bytes.sublist(0, maxResponseBytes)),
          bodyTruncated: true,
        );
      }
      return LocalOpenListHttpResponse(
        statusCode: 206,
        headers: {
          'content-range': 'bytes $start-$end/${fileBytes.length}',
          'content-length': bytes.length.toString(),
          'accept-ranges': 'bytes',
        },
        body: Uint8List.fromList(bytes),
        bodyTruncated: false,
      );
    }
    return LocalOpenListHttpResponse(
      statusCode: 404,
      headers: const {},
      body: Uint8List(0),
      bodyTruncated: false,
    );
  }

  LocalOpenListHttpResponse _json(Map<String, dynamic> value) {
    final bytes = utf8.encode(jsonEncode(value));
    return LocalOpenListHttpResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: Uint8List.fromList(bytes),
      bodyTruncated: false,
    );
  }

  @override
  void close() => closed = true;
}

FrameBook _book({
  String provider = 'local',
  String rootPath = '/Books',
  String path = '/Books/sample.epub',
  int size = 0,
}) =>
    FrameBook.fromJson({
      'id': 'local-book-1',
      'provider': provider,
      'library': 'books',
      'rootPath': rootPath,
      'path': path,
      'fileName': path.split('/').last,
      'title': 'Sample',
      'format': 'EPUB',
      'shelf': 'books',
      'size': size,
    });

void main() {
  test('reads a large local EPUB through sequential 1 MiB Range requests', () async {
    final bytes = Uint8List.fromList(
      List<int>.generate(1024 * 1024 + 17, (index) => index % 251),
    );
    final transport = _FakeLocalOpenListTransport(bytes);
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'not-persisted');

    final source = FrameLocalOpenListFileSource(client: client);
    final response = await source.open(FrameFileRequest(
      book: _book(size: bytes.length),
      range: FrameByteRange.from(start: 0, end: bytes.length - 1),
    ));

    expect(response.statusCode, 206);
    expect(response.contentRange, 'bytes 0-${bytes.length - 1}/${bytes.length}');
    expect(response.contentLength, bytes.length);

    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      builder.add(chunk);
    }
    expect(builder.takeBytes(), bytes);
    expect(transport.ranges, [
      (0, 1024 * 1024 - 1),
      (1024 * 1024, bytes.length - 1),
    ]);
    expect(
      transport.ranges.every(
        (range) => range.$2 - range.$1 + 1 <= 1024 * 1024,
      ),
      isTrue,
    );
    await response.close();
    client.close();
  });

  test('refuses unauthenticated access before querying the source', () async {
    final transport = _FakeLocalOpenListTransport(Uint8List.fromList([1, 2, 3]));
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    final source = FrameLocalOpenListFileSource(client: client);

    await expectLater(
      source.open(FrameFileRequest(
        book: _book(size: 3),
        range: FrameByteRange.from(start: 0, end: 2),
      )),
      throwsA(isA<LocalOpenListException>()),
    );
    expect(transport.ranges, isEmpty);
    client.close();
  });

  test('rejects paths outside the selected root before contacting OpenList', () async {
    final transport = _FakeLocalOpenListTransport(Uint8List.fromList([1, 2, 3]));
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'not-persisted');
    final source = FrameLocalOpenListFileSource(client: client);

    await expectLater(
      source.open(FrameFileRequest(
        book: _book(
          rootPath: '/Books/Allowed',
          path: '/Books/Other/file.epub',
          size: 3,
        ),
        range: FrameByteRange.from(start: 0, end: 2),
      )),
      throwsFormatException,
    );
    expect(transport.ranges, isEmpty);
    client.close();
  });

  test('rejects requests that would read the whole file without Range', () async {
    final transport = _FakeLocalOpenListTransport(Uint8List.fromList([1, 2, 3]));
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'not-persisted');
    final source = FrameLocalOpenListFileSource(client: client);

    await expectLater(
      source.open(FrameFileRequest(book: _book(size: 3))),
      throwsFormatException,
    );
    expect(transport.ranges, isEmpty);
    client.close();
  });

  test('stops before issuing the next bounded request when cancelled', () async {
    final bytes = Uint8List.fromList(
      List<int>.generate(1024 * 1024 + 3, (index) => index % 251),
    );
    final transport = _FakeLocalOpenListTransport(bytes);
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'not-persisted');
    final cancellation = FrameFileCancellation();
    final source = FrameLocalOpenListFileSource(client: client);
    final response = await source.open(FrameFileRequest(
      book: _book(size: bytes.length),
      range: FrameByteRange.from(start: 0, end: bytes.length - 1),
      cancellation: cancellation,
    ));

    final iterator = StreamIterator<List<int>>(response.stream);
    expect(await iterator.moveNext(), isTrue);
    cancellation.cancel();
    await expectLater(iterator.moveNext(), throwsStateError);
    await iterator.cancel();
    await response.close();
    expect(transport.ranges, hasLength(1));
    client.close();
  });
}
)
          .firstMatch(rangeHeader ?? '');
      if (method != 'GET' || match == null) {
        return LocalOpenListHttpResponse(
          statusCode: 400,
          headers: const {},
          body: Uint8List(0),
          bodyTruncated: false,
        );
      }
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      if (start < 0 || end < start || end >= fileBytes.length) {
        return LocalOpenListHttpResponse(
          statusCode: 416,
          headers: const {},
          body: Uint8List(0),
          bodyTruncated: false,
        );
      }
      ranges.add((start, end));
      final bytes = fileBytes.sublist(start, end + 1);
      if (bytes.length > maxResponseBytes) {
        return LocalOpenListHttpResponse(
          statusCode: 206,
          headers: {
            'content-range': 'bytes $start-$end/${fileBytes.length}',
            'content-length': bytes.length.toString(),
          },
          body: Uint8List.fromList(bytes.sublist(0, maxResponseBytes)),
          bodyTruncated: true,
        );
      }
      return LocalOpenListHttpResponse(
        statusCode: 206,
        headers: {
          'content-range': 'bytes $start-$end/${fileBytes.length}',
          'content-length': bytes.length.toString(),
          'accept-ranges': 'bytes',
        },
        body: Uint8List.fromList(bytes),
        bodyTruncated: false,
      );
    }
    return LocalOpenListHttpResponse(
      statusCode: 404,
      headers: const {},
      body: Uint8List(0),
      bodyTruncated: false,
    );
  }

  LocalOpenListHttpResponse _json(Map<String, dynamic> value) {
    final bytes = utf8.encode(jsonEncode(value));
    return LocalOpenListHttpResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: Uint8List.fromList(bytes),
      bodyTruncated: false,
    );
  }

  @override
  void close() => closed = true;
}

FrameBook _book({
  String provider = 'local',
  String rootPath = '/Books',
  String path = '/Books/sample.epub',
  int size = 0,
}) =>
    FrameBook.fromJson({
      'id': 'local-book-1',
      'provider': provider,
      'library': 'books',
      'rootPath': rootPath,
      'path': path,
      'fileName': path.split('/').last,
      'title': 'Sample',
      'format': 'EPUB',
      'shelf': 'books',
      'size': size,
    });

void main() {
  test('reads a large local EPUB through sequential 1 MiB Range requests', () async {
    final bytes = Uint8List.fromList(
      List<int>.generate(1024 * 1024 + 17, (index) => index % 251),
    );
    final transport = _FakeLocalOpenListTransport(bytes);
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'not-persisted');

    final source = FrameLocalOpenListFileSource(client: client);
    final response = await source.open(FrameFileRequest(
      book: _book(size: bytes.length),
      range: FrameByteRange.from(start: 0, end: bytes.length - 1),
    ));

    expect(response.statusCode, 206);
    expect(response.contentRange, 'bytes 0-${bytes.length - 1}/${bytes.length}');
    expect(response.contentLength, bytes.length);

    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      builder.add(chunk);
    }
    expect(builder.takeBytes(), bytes);
    expect(transport.ranges, [
      (0, 1024 * 1024 - 1),
      (1024 * 1024, bytes.length - 1),
    ]);
    expect(
      transport.ranges.every(
        (range) => range.$2 - range.$1 + 1 <= 1024 * 1024,
      ),
      isTrue,
    );
    await response.close();
    client.close();
  });

  test('refuses unauthenticated access before querying the source', () async {
    final transport = _FakeLocalOpenListTransport(Uint8List.fromList([1, 2, 3]));
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    final source = FrameLocalOpenListFileSource(client: client);

    await expectLater(
      source.open(FrameFileRequest(
        book: _book(size: 3),
        range: FrameByteRange.from(start: 0, end: 2),
      )),
      throwsA(isA<LocalOpenListException>()),
    );
    expect(transport.ranges, isEmpty);
    client.close();
  });

  test('rejects paths outside the selected root before contacting OpenList', () async {
    final transport = _FakeLocalOpenListTransport(Uint8List.fromList([1, 2, 3]));
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'not-persisted');
    final source = FrameLocalOpenListFileSource(client: client);

    await expectLater(
      source.open(FrameFileRequest(
        book: _book(
          rootPath: '/Books/Allowed',
          path: '/Books/Other/file.epub',
          size: 3,
        ),
        range: FrameByteRange.from(start: 0, end: 2),
      )),
      throwsFormatException,
    );
    expect(transport.ranges, isEmpty);
    client.close();
  });

  test('rejects requests that would read the whole file without Range', () async {
    final transport = _FakeLocalOpenListTransport(Uint8List.fromList([1, 2, 3]));
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'not-persisted');
    final source = FrameLocalOpenListFileSource(client: client);

    await expectLater(
      source.open(FrameFileRequest(book: _book(size: 3))),
      throwsFormatException,
    );
    expect(transport.ranges, isEmpty);
    client.close();
  });

  test('stops before issuing the next bounded request when cancelled', () async {
    final bytes = Uint8List.fromList(
      List<int>.generate(1024 * 1024 + 3, (index) => index % 251),
    );
    final transport = _FakeLocalOpenListTransport(bytes);
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'not-persisted');
    final cancellation = FrameFileCancellation();
    final source = FrameLocalOpenListFileSource(client: client);
    final response = await source.open(FrameFileRequest(
      book: _book(size: bytes.length),
      range: FrameByteRange.from(start: 0, end: bytes.length - 1),
      cancellation: cancellation,
    ));

    final iterator = StreamIterator<List<int>>(response.stream);
    expect(await iterator.moveNext(), isTrue);
    cancellation.cancel();
    await expectLater(iterator.moveNext(), throwsStateError);
    await iterator.cancel();
    await response.close();
    expect(transport.ranges, hasLength(1));
    client.close();
  });
}
