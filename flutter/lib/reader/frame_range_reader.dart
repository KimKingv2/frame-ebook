import 'dart:typed_data';

import '../library/frame_book.dart';
import '../transport/frame_file_source.dart';

/// A bounded byte-range result read from the original cloud archive.
///
/// The bytes are the requested archive slice only. This class never downloads
/// or stores the complete EPUB/CBZ archive.
class FrameRangeReadResult {
  const FrameRangeReadResult({
    required this.bytes,
    required this.start,
    required this.end,
    required this.totalLength,
  });

  final Uint8List bytes;
  final int start;
  final int end;
  final int totalLength;

  int get length => bytes.length;
}

class FrameRangeReadException implements Exception {
  const FrameRangeReadException(
    this.message, {
    this.statusCode,
  });

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'FrameRangeReadException: $message'
      : 'FrameRangeReadException: $message (HTTP $statusCode)';
}

/// Reads bounded sections of an indexed cloud EPUB/CBZ through the shared
/// [FrameFileSource] contract.
///
/// A server must honor HTTP Range and return a verifiable 206 response. A 200
/// response is rejected before its body is listened to, so a range fallback
/// can never silently download the entire archive.
class FrameRangeReader {
  FrameRangeReader({
    required this.source,
    required this.book,
    this.maxRangeBytes = 16 * 1024 * 1024,
  }) {
    if (maxRangeBytes <= 0) {
      throw ArgumentError.value(
        maxRangeBytes,
        'maxRangeBytes',
        '必須大於 0。',
      );
    }
  }

  final FrameFileSource source;
  final FrameBook book;

  /// Maximum archive bytes buffered by one request.
  ///
  /// This is a per-range bound, not a whole-book cache. ZIP directory readers
  /// may override it for unusually large central directories.
  final int maxRangeBytes;

  Future<FrameRangeReadResult> readRange(
    int start,
    int end, {
    FrameFileCancellation? cancellation,
  }) async {
    if (start < 0) {
      throw ArgumentError.value(start, 'start', '不可小於 0。');
    }
    if (end < start) {
      throw ArgumentError.value(end, 'end', '不可小於起始位置。');
    }
    final requestedLength = end - start + 1;
    _checkRangeLimit(requestedLength);
    if (book.size > 0 && end >= book.size) {
      throw RangeError(
        '要求的 Range 超出索引檔案大小（${book.size} bytes）。',
      );
    }

    return _read(
      range: FrameByteRange.from(start: start, end: end),
      requestedStart: start,
      requestedEnd: end,
      suffixLength: null,
      cancellation: cancellation,
    );
  }

  /// Reads the final [length] bytes. When the indexed size is known this is
  /// translated into a normal bounded Range; otherwise it uses a suffix Range.
  Future<FrameRangeReadResult> readSuffix(
    int length, {
    FrameFileCancellation? cancellation,
  }) async {
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', '必須大於 0。');
    }
    _checkRangeLimit(length);

    if (book.size > 0) {
      final actualLength = length < book.size ? length : book.size;
      return readRange(
        book.size - actualLength,
        book.size - 1,
        cancellation: cancellation,
      );
    }

    return _read(
      range: FrameByteRange.suffix(length),
      requestedStart: null,
      requestedEnd: null,
      suffixLength: length,
      cancellation: cancellation,
    );
  }

  Future<FrameRangeReadResult> _read({
    required FrameByteRange range,
    required int? requestedStart,
    required int? requestedEnd,
    required int? suffixLength,
    required FrameFileCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled == true) {
      throw StateError('檔案讀取已取消。');
    }

    final response = await source.open(
      FrameFileRequest(
        book: book,
        range: range,
        cancellation: cancellation,
      ),
    );

    try {
      if (response.statusCode != 206) {
        throw FrameRangeReadException(
          '檔案來源沒有遵循 Range 請求，已停止讀取，避免退回完整檔案下載。',
          statusCode: response.statusCode,
        );
      }

      final contentRange = _parseContentRange(response.contentRange);
      final start = contentRange.start;
      final end = contentRange.end;
      final totalLength = contentRange.totalLength;
      final responseLength = end - start + 1;

      if (requestedStart != null && start != requestedStart) {
        throw const FrameRangeReadException('伺服器回傳的 Range 起點不符。');
      }
      if (requestedEnd != null && end > requestedEnd) {
        throw const FrameRangeReadException('伺服器回傳的 Range 超過要求範圍。');
      }
      if (requestedEnd != null &&
          end < requestedEnd &&
          end != totalLength - 1) {
        throw const FrameRangeReadException('伺服器回傳的 Range 不完整。');
      }
      if (suffixLength != null) {
        final expectedStart = totalLength > suffixLength
            ? totalLength - suffixLength
            : 0;
        if (start != expectedStart || end != totalLength - 1) {
          throw const FrameRangeReadException('伺服器回傳的尾端 Range 不符。');
        }
      }
      if (book.size > 0 && totalLength != book.size) {
        throw const FrameRangeReadException(
          '雲端檔案大小與書庫索引不一致，請重新掃描書庫。',
        );
      }
      _checkRangeLimit(responseLength);

      final declaredLength = response.contentLength;
      if (declaredLength != null && declaredLength != responseLength) {
        throw const FrameRangeReadException(
          'Content-Length 與 Content-Range 不一致。',
        );
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (cancellation?.isCancelled == true) {
          throw StateError('檔案讀取已取消。');
        }
        if (builder.length + chunk.length > responseLength) {
          throw const FrameRangeReadException(
            '伺服器回傳的位元組超過指定 Range，已停止讀取。',
          );
        }
        builder.add(chunk);
      }

      if (cancellation?.isCancelled == true) {
        throw StateError('檔案讀取已取消。');
      }
      final bytes = builder.takeBytes();
      if (bytes.length != responseLength) {
        throw const FrameRangeReadException(
          '檔案 Range 回應提前結束，資料長度不完整。',
        );
      }

      return FrameRangeReadResult(
        bytes: Uint8List.fromList(bytes),
        start: start,
        end: end,
        totalLength: totalLength,
      );
    } finally {
      await response.close();
    }
  }

  void _checkRangeLimit(int length) {
    if (length > maxRangeBytes) {
      throw FrameRangeReadException(
        '單次 Range 超過上限（${maxRangeBytes} bytes）。',
      );
    }
  }

  _ParsedContentRange _parseContentRange(String? value) {
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+)$',
      caseSensitive: false,
    ).firstMatch(value?.trim() ?? '');
    if (match == null) {
      throw const FrameRangeReadException(
        '伺服器沒有提供有效的 Content-Range。',
      );
    }

    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    final totalLength = int.parse(match.group(3)!);
    if (start < 0 || end < start || totalLength <= end) {
      throw const FrameRangeReadException('Content-Range 數值無效。');
    }

    return _ParsedContentRange(
      start: start,
      end: end,
      totalLength: totalLength,
    );
  }
}

class _ParsedContentRange {
  const _ParsedContentRange({
    required this.start,
    required this.end,
    required this.totalLength,
  });

  final int start;
  final int end;
  final int totalLength;
}
