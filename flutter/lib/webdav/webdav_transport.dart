import 'dart:typed_data';

import 'webdav_transport_stub.dart'
    if (dart.library.io) 'webdav_transport_io.dart'
    if (dart.library.js_interop) 'webdav_transport_web.dart' as platform;

class WebDavHttpResponse {
  const WebDavHttpResponse({
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
    final target = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == target) return entry.value;
    }
    return null;
  }
}

abstract interface class WebDavTransport {
  bool get browserManagedRedirect;

  Future<WebDavHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    List<int>? body,
    int maxResponseBytes = 1024 * 1024,
    Duration timeout = const Duration(seconds: 30),
  });

  void close();
}

WebDavTransport createWebDavTransport() => platform.createWebDavTransport();
