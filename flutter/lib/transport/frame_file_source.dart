import 'dart:async';

import '../library/frame_book.dart';

/// A single byte range using HTTP's inclusive start/end offsets.
///
/// Use [from] for a bounded or open-ended range, or [suffix] for the final
/// number of bytes in a resource. This represents one range only; multipart
/// byte ranges are intentionally not supported by the reader transport.
class FrameByteRange {
  FrameByteRange.from({
    required int start,
    int? end,
  })  : start = start,
        end = end,
        suffixLength = null {
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'Must be zero or greater.');
    }
    if (end != null && end < start) {
      throw ArgumentError.value(end, 'end', 'Must not be smaller than start.');
    }
  }

  FrameByteRange.suffix(int length)
      : start = null,
        end = null,
        suffixLength = length {
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', 'Must be greater than zero.');
    }
  }

  /// The first byte requested, inclusive. Null for suffix ranges.
  final int? start;

  /// The last byte requested, inclusive. Null for an open-ended or suffix range.
  final int? end;

  /// Number of bytes requested from the end of a resource, when this is a
  /// suffix range. Null for normal ranges.
  final int? suffixLength;

  String get headerValue {
    final suffix = suffixLength;
    if (suffix != null) return 'bytes=-$suffix';
    return 'bytes=$start-${end ?? ''}';
  }
}

/// A transport-neutral request to open an indexed cloud book.
///
/// Delivery policy is deliberately absent: the Web adapter may use the
/// same-origin Pages Functions stream while native adapters may follow a
/// credential-safe 302 chain. Reader UI code must not select either path.
class FrameFileRequest {
  const FrameFileRequest({
    required this.book,
    this.range,
  });

  final FrameBook book;
  final FrameByteRange? range;
}

/// A one-shot streaming response from a [FrameFileSource].
///
/// The adapter owns the underlying request. [close] must cancel that request,
/// close its response stream and release the socket/resource. It is safe to
/// call [close] more than once.
class FrameFileResponse {
  FrameFileResponse({
    required this.statusCode,
    required this.stream,
    required FutureOr<void> Function() onClose,
    Map<String, String> headers = const {},
    this.requestedRange,
  })  : headers = _normalizeHeaders(headers),
        _onClose = onClose;

  final int statusCode;

  /// A single-subscription byte stream. Do not buffer the full archive before
  /// returning this response.
  final Stream<List<int>> stream;

  /// Response header names are normalized to lowercase.
  final Map<String, String> headers;

  /// The range supplied to the source, if any. The server may ignore a range
  /// and return 200, so callers must inspect [statusCode] and [contentRange].
  final FrameByteRange? requestedRange;

  final FutureOr<void> Function() _onClose;
  bool _closed = false;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  bool get isPartialContent => statusCode == 206;

  int? get contentLength => int.tryParse(headers['content-length'] ?? '');

  String? get contentType => headers['content-type'];

  String? get contentRange => headers['content-range'];

  bool get acceptsRanges =>
      (headers['accept-ranges'] ?? '').toLowerCase().contains('bytes');

  bool get isClosed => _closed;

  /// Cancels the underlying request and releases the response resources.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose();
  }

  static const _safeHeaderNames = {
    'accept-ranges',
    'cache-control',
    'content-disposition',
    'content-encoding',
    'content-length',
    'content-range',
    'content-type',
    'etag',
    'last-modified',
    'x-content-type-options',
  };

  static Map<String, String> _normalizeHeaders(
    Map<String, String> source,
  ) {
    final normalized = <String, String>{};
    for (final entry in source.entries) {
      final name = entry.key.trim().toLowerCase();
      if (!_safeHeaderNames.contains(name)) continue;
      normalized[name] = entry.value.trim();
    }
    return Map<String, String>.unmodifiable(normalized);
  }
}

/// Platform-neutral interface for opening original cloud book archives.
///
/// Implementations are injected at the application boundary:
/// - Web uses browser Fetch and the protected same-origin stream endpoint.
/// - Android/macOS use the shared Dart HttpClient transport and native cookie
///   acquisition bridge.
///
/// The reader depends only on this interface and never checks the platform.
abstract interface class FrameFileSource {
  Future<FrameFileResponse> open(FrameFileRequest request);
}
