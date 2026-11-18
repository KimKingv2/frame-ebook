import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/webdav/webdav_client.dart';
import '../lib/webdav/webdav_models.dart';

void main() {
  late HttpServer server;
  late WebDavClient client;
  var authOnRedirectTarget = 'not-requested';
  var rangeOnRedirectTarget = '';

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    authOnRedirectTarget = 'not-requested';
    rangeOnRedirectTarget = '';
    server.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/dav/books/' &&
          request.method == 'PROPFIND') {
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
            'Basic \${base64Encode(utf8.encode('reader:secret'))}') {
          response.statusCode = HttpStatus.unauthorized;
          await response.close();
          return;
        }
        expect(request.headers.value('depth'), '1');
        response.statusCode = 207;
        response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        response.write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/dav/books/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
 <d:response><d:href>/dav/books/Novel%20Folder/</d:href><d:propstat><d:prop><d:displayname>Novel Folder</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
 <d:response><d:href>/dav/books/Story.epub</d:href><d:propstat><d:prop><d:displayname>Story.epub</d:displayname><d:resourcetype/><d:getcontentlength>12345</d:getcontentlength></d:prop></d:propstat></d:response>
 <d:response><d:href>/dav/books/ignore.txt</d:href><d:propstat><d:prop><d:displayname>ignore.txt</d:displayname><d:resourcetype/></d:prop></d:propstat></d:response>
</d:multistatus>''');
        await response.close();
        return;
      }
      if (request.uri.path == '/dav/redirect.cbz' &&
          request.method == 'GET') {
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, '/signed/redirect.cbz');
        await response.close();
        return;
      }
      if (request.uri.path == '/signed/redirect.cbz' &&
          request.method == 'GET') {
        authOnRedirectTarget =
            request.headers.value(HttpHeaders.authorizationHeader) ?? '';
        rangeOnRedirectTarget =
            request.headers.value(HttpHeaders.rangeHeader) ?? '';
        final match = RegExp(r'^bytes=(\d+)-(\d+)\$').firstMatch(rangeOnRedirectTarget);
        if (match == null) {
          response.statusCode = HttpStatus.badRequest;
          await response.close();
          return;
        }
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        final bytes = List<int>.generate(end - start + 1, (i) => 65 + i);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/100');
        response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
        response.add(bytes);
        await response.close();
        return;
      }
      if (request.uri.path == '/dav/ignore-range.cbz' &&
          request.method == 'GET') {
        response.statusCode = HttpStatus.ok;
        response.headers.set(HttpHeaders.contentLengthHeader, 2048);
        response.add(List<int>.filled(2048, 1));
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    });
    final profile = WebDavProfile(
      baseUrl: 'http://127.0.0.1:\${server.port}/dav/',
      username: 'reader',
      booksRoot: '/books',
      comicsRoot: '/comics',
    );
    client = WebDavClient(profile: profile, password: 'secret');
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('PROPFIND parses one-level listing and authenticates source origin', () async {
    final entries = await client.listDirectory('/books');
    expect(entries, hasLength(3));
    expect(entries.first.isDirectory, isTrue);
    expect(entries.first.name, 'Novel Folder');
    expect(entries.first.path, '/books/Novel Folder');
    expect(entries[1].isEpub, isTrue);
    expect(entries.last.name, 'ignore.txt');
  });

  test('Range follows relative 302, preserves Range and drops credentials', () async {
    final result = await client.readRange(
      '/redirect.cbz',
      start: 20,
      length: 10,
    );
    expect(result.start, 20);
    expect(result.end, 29);
    expect(result.totalSize, 100);
    expect(result.bytes, hasLength(10));
    expect(result.redirected, isTrue);
    expect(rangeOnRedirectTarget, 'bytes=20-29');
    expect(authOnRedirectTarget, isEmpty);
  });

  test('Range rejects a server that silently returns HTTP 200', () async {
    await expectLater(
      client.readRange('/ignore-range.cbz', start: 0, length: 1024),
      throwsA(isA<WebDavException>()),
    );
  });

  test('HTTP external host and parent path are rejected', () {
    expect(
      () => WebDavClient.normalizeBaseUrl('http://example.com/dav/'),
      throwsFormatException,
    );
    expect(
      () => WebDavClient.normalizeRemotePath('/books/../private'),
      throwsFormatException,
    );
  });
}
