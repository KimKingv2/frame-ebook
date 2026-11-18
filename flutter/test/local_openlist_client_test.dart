import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/cloud/local_openlist_client.dart';
import 'package:frame_ebook/cloud/local_openlist_transport.dart';

class _RecordedRequest {
  const _RecordedRequest(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;
}

class _FakeTransport implements LocalOpenListTransport {
  final List<_RecordedRequest> requests = [];
  bool expireToken = false;
  bool ignoreRange = false;

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
    requests.add(_RecordedRequest(
      method,
      uri,
      Map<String, String>.from(headers),
      body == null ? '' : utf8.decode(body),
    ));

    if (uri.path.endsWith('/api/auth/login')) {
      return _jsonResponse({
        'code': 200,
        'data': {'token': 'ephemeral-local-token'},
      });
    }
    if (uri.path.endsWith('/api/fs/list')) {
      if (expireToken) {
        return _jsonResponse(
          {'code': 401, 'message': 'token expired'},
          status: 401,
        );
      }
      return _jsonResponse({
        'code': 200,
        'data': {
          'page': 1,
          'per_page': 100,
          'total': 2,
          'content': [
            {'name': 'Series', 'is_dir': true, 'size': 0},
            {'name': 'Novel.epub', 'is_dir': false, 'size': 1234},
          ],
        },
      });
    }
    if (uri.path.endsWith('/api/fs/get')) {
      return _jsonResponse({
        'code': 200,
        'data': {
          'is_dir': false,
          'name': 'Issue.cbz',
          'size': 100,
          'raw_url': 'https://signed.example/Issue.cbz',
        },
      });
    }
    if (uri.host == 'signed.example') {
      if (ignoreRange) {
        return LocalOpenListHttpResponse(
          statusCode: 200,
          headers: {'content-length': '100'},
          body: Uint8List(100),
          bodyTruncated: false,
        );
      }
      return LocalOpenListHttpResponse(
        statusCode: 206,
        headers: const {'content-range': 'bytes 10-19/100'},
        body: Uint8List.fromList(List<int>.generate(10, (index) => index)),
        bodyTruncated: false,
      );
    }
    return LocalOpenListHttpResponse(
      statusCode: 404,
      headers: {},
      body: Uint8List(0),
      bodyTruncated: false,
    );
  }

  LocalOpenListHttpResponse _jsonResponse(
    Map<String, dynamic> value, {
    int status = 200,
  }) {
    return LocalOpenListHttpResponse(
      statusCode: status,
      headers: const {'content-type': 'application/json'},
      body: Uint8List.fromList(utf8.encode(jsonEncode(value))),
      bodyTruncated: false,
    );
  }

  @override
  void close() {}
}

void main() {
  test('accepts only HTTPS public URLs and HTTP private IPv4/localhost', () {
    expect(
      LocalOpenListClient.normalizeLocalOpenListUrl(
        'http://192.168.31.185:5244/dav/',
      ),
      'http://192.168.31.185:5244/dav',
    );
    expect(
      LocalOpenListClient.normalizeLocalOpenListUrl(
        'https://openlist.example.com/dav/',
      ),
      'https://openlist.example.com/dav',
    );
    expect(
      () => LocalOpenListClient.normalizeLocalOpenListUrl(
        'http://example.com/dav',
      ),
      throwsFormatException,
    );
    expect(
      () => LocalOpenListClient.normalizeLocalOpenListUrl(
        'https://user:pass@example.com',
      ),
      throwsFormatException,
    );
  });

  test('login keeps its token in memory and lists one directory page', () async {
    final transport = _FakeTransport();
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244/dav/',
      transport: transport,
    );

    await client.login(username: 'reader', password: 'secret');
    expect(client.isAuthenticated, isTrue);
    final page = await client.listDirectory('/Books', page: 1);

    expect(page.total, 2);
    expect(page.items, hasLength(2));
    expect(page.items.first.isDirectory, isTrue);
    expect(page.items.last.path, '/Books/Novel.epub');

    final login = transport.requests.first;
    expect(login.uri.path, '/dav/api/auth/login');
    expect(login.body, contains('secret'));
    expect(login.headers.containsKey('Authorization'), isFalse);
    final list = transport.requests.last;
    expect(list.headers['Authorization'], 'ephemeral-local-token');
    expect(list.body, contains('"per_page":100'));

    client.logout();
    expect(client.isAuthenticated, isFalse);
    client.close();
  });

  test('expired login token is cleared from memory', () async {
    final transport = _FakeTransport();
    final client = LocalOpenListClient(
      baseUrl: 'http://127.0.0.1:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'secret');
    transport.expireToken = true;

    await expectLater(
      client.listDirectory('/Books'),
      throwsA(isA<LocalOpenListException>()),
    );
    expect(client.isAuthenticated, isFalse);
    client.close();
  });

  test('CBZ Range follows signed file URL without forwarding the API token', () async {
    final transport = _FakeTransport();
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'secret');

    final range = await client.readRange(
      '/Comics/Issue.cbz',
      start: 10,
      length: 10,
    );
    expect(range.start, 10);
    expect(range.end, 19);
    expect(range.totalSize, 100);
    expect(range.bytes, hasLength(10));

    final rawRequest = transport.requests.last;
    expect(rawRequest.uri.host, 'signed.example');
    expect(rawRequest.headers['Range'], 'bytes=10-19');
    expect(rawRequest.headers.containsKey('Authorization'), isFalse);
    client.close();
  });

  test('CBZ Range rejects an upstream that ignores Range', () async {
    final transport = _FakeTransport()..ignoreRange = true;
    final client = LocalOpenListClient(
      baseUrl: 'http://192.168.31.185:5244',
      transport: transport,
    );
    await client.login(username: 'reader', password: 'secret');
    await expectLater(
      client.readRange('/Comics/Issue.cbz', start: 10, length: 10),
      throwsA(isA<LocalOpenListException>()),
    );
    client.close();
  });
}
