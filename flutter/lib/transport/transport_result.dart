class TransportResult {
  const TransportResult({
    required this.statusCode,
    required this.headers,
    required this.bytesRead,
    required this.bodyTruncated,
    required this.duration,
    this.finalUri,
    this.redirectCount,
    this.browserManagedRedirect = false,
  });

  final int statusCode;
  final Map<String, String> headers;
  final int bytesRead;
  final bool bodyTruncated;
  final Duration duration;
  final Uri? finalUri;
  final int? redirectCount;
  final bool browserManagedRedirect;

  String? get contentRange => _header('content-range');
  String? get acceptRanges => _header('accept-ranges');
  String? get contentLength => _header('content-length');
  bool get receivedPartialContent => statusCode == 206;

  bool get contentRangeVerified {
    final value = contentRange;
    if (value == null) return false;
    return RegExp(r'^bytes\s+\d+-\d+/\d+$', caseSensitive: false)
        .hasMatch(value);
  }

  String? _header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }
}
