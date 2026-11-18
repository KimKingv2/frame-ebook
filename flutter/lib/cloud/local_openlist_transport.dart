import 'dart:typed_data';

import 'local_openlist_transport_stub.dart'
    if (dart.library.io) 'local_openlist_transport_io.dart'
    if (dart.library.js_interop) 'local_openlist_transport_web.dart' as platform;

class LocalOpenListHttpResponse {
  const LocalOpenListHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.bodyTruncated,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
  final bool bodyTruncated;

  String? header(String name) {
    final key = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == key) return entry.value;
    }
    return null;
  }
}

abstract interface class LocalOpenListTransport {
  Future<LocalOpenListHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers,
    List<int>? body,
    bool followRedirects,
    int maxRedirects,
    int maxResponseBytes,
    Duration timeout,
  });

  void close();
}

LocalOpenListTransport createLocalOpenListTransport() =>
    platform.createLocalOpenListTransport();
