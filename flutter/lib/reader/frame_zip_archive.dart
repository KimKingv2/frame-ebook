import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' as zip_core;
import 'package:koni_zip/koni_zip.dart';

import '../library/frame_book.dart';
import '../transport/frame_file_source.dart';
import 'frame_range_reader.dart';

class FrameZipArchiveException implements Exception {
  const FrameZipArchiveException(this.message);

  final String message;

  @override
  String toString() => 'FrameZipArchiveException: $message';
}

/// FRAME-owned entry metadata. The third-party ZIP type stays private.
class FrameZipArchiveEntry {
  const FrameZipArchiveEntry._(this._archive, this._entry);

  final FrameZipArchive _archive;
  final zip_core.ArchiveEntry _entry;

  String get path => _entry.path;
  int get size => _entry.uncompressedSize;
  int? get compressedSize => _entry.compressedSize;
  int? get crc32 => _entry.crc32;
  DateTime? get modified => _entry.modified;
  String get compression => _entry.compression.name;
  bool get isFile => _entry.isFile;
  bool get isDirectory => _entry.isDirectory;
  bool get isSafePath => !_entry.pathEscapedRoot;
}

/// Read-only ZIP/CBZ archive backed by bounded requests to the original file.
///
/// This class never downloads the complete EPUB/CBZ container. ZIP metadata
/// and individual entries are read through the shared FrameFileSource API.
class FrameZipArchive {
  FrameZipArchive._(this._reader, this._source) {
    entries = List.unmodifiable([
      for (final entry in _reader.entries)
        FrameZipArchiveEntry._(this, entry),
    ]);
  }

  final zip_core.ArchiveReader _reader;
  final _FrameRangeByteSource _source;

  late final List<FrameZipArchiveEntry> entries;
  bool _closed = false;

  /// Safe regular files only. Paths that escape the archive root are hidden.
  List<FrameZipArchiveEntry> get files => List.unmodifiable(
        entries.where((entry) => entry.isFile && entry.isSafePath),
      );

  List<FrameZipArchiveEntry> get directories => List.unmodifiable(
        entries.where((entry) => entry.isDirectory && entry.isSafePath),
      );

  static Future<FrameZipArchive> open({
    required FrameFileSource source,
    required FrameBook book,
    int maxRangeBytes = 16 * 1024 * 1024,
    int rangeChunkBytes = 4 * 1024 * 1024,
    int maxMetadataReadBytes = 32 * 1024 * 1024,
    int maxEntrySize = 256 * 1024 * 1024,
    int maxEntryCount = 100000,
  }) async {
    if (book.size <= 0) {
      throw const FrameZipArchiveException(
        '雲端索引沒有提供有效檔案大小，請先重新掃描書庫。',
      );
    }
    if (rangeChunkBytes <= 0 || rangeChunkBytes > maxRangeBytes) {
      throw ArgumentError.value(
        rangeChunkBytes,
        'rangeChunkBytes',
        '必須大於 0，且不可超過 maxRangeBytes。',
      );
    }
    if (maxMetadataReadBytes <= 0 ||
        maxEntrySize <= 0 ||
        maxEntryCount <= 0) {
      throw ArgumentError('ZIP 讀取上限必須大於 0。');
    }

    final byteSource = _FrameRangeByteSource(
      rangeReader: FrameRangeReader(
        source: source,
        book: book,
        maxRangeBytes: maxRangeBytes,
      ),
      name: book.fileName,
      length: book.size,
      rangeChunkBytes: rangeChunkBytes,
      maxReadBytes: maxMetadataReadBytes,
    );

    try {
      final reader = await const ZipFormat().openReader(
        byteSource,
        zip_core.ArchiveReadOptions(
          verifyChecksums: true,
          maxEntryCount: maxEntryCount,
          maxEntrySize: maxEntrySize,
        ),
      );
      return FrameZipArchive._(reader, byteSource);
    } catch (_) {
      await byteSource.close();
      rethrow;
    }
  }

  /// Finds the last safe regular file with this exact normalized path.
  FrameZipArchiveEntry? file(String path) {
    _ensureOpen();
    for (final entry in entries.reversed) {
      if (entry.isFile && entry.isSafePath && entry.path == path) {
        return entry;
      }
    }
    return null;
  }

  /// Streams one decoded entry with bounded memory use.
  Stream<Uint8List> openRead(FrameZipArchiveEntry entry) {
    _ensureEntry(entry);
    if (!entry.isFile) {
      throw const FrameZipArchiveException('只能讀取 ZIP 內的檔案項目。');
    }
    if (!entry.isSafePath) {
      throw const FrameZipArchiveException(
        'ZIP 項目的路徑試圖離開壓縮檔根目錄，已拒絕讀取。',
      );
    }
    return _reader.openRead(entry._entry);
  }

  /// Collects one entry only. Prefer openRead when the consumer supports
  /// streaming. The limit applies to the decoded entry, not the full archive.
  Future<Uint8List> readBytes(
    FrameZipArchiveEntry entry, {
    int maxBytes = 32 * 1024 * 1024,
  }) async {
    _ensureEntry(entry);
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', '必須大於 0。');
    }
    if (!entry.isFile || !entry.isSafePath) {
      throw const FrameZipArchiveException('無法讀取這個 ZIP 項目。');
    }
    if (entry.size > maxBytes) {
      throw FrameZipArchiveException(
        '項目 ' + entry.path + ' 解壓後超過單項讀取上限 ' +
            maxBytes.toString() + ' bytes。',
      );
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in openRead(entry)) {
      if (builder.length + chunk.length > maxBytes) {
        throw FrameZipArchiveException(
          '項目 ' + entry.path + ' 解壓後超過單項讀取上限 ' +
              maxBytes.toString() + ' bytes。',
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _source.close();
    await _reader.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw const FrameZipArchiveException('ZIP 閱讀來源已關閉。');
    }
  }

  void _ensureEntry(FrameZipArchiveEntry entry) {
    _ensureOpen();
    if (!identical(entry._archive, this)) {
      throw ArgumentError.value(
        entry,
        'entry',
        '項目不屬於目前的 ZIP 閱讀來源。',
      );
    }
  }
}

/// Adapts FRAME's bounded HTTP range API to the ZIP library's positional
/// ByteSource contract. Reads have independent offsets and may overlap.
class _FrameRangeByteSource implements zip_core.ByteSource {
  _FrameRangeByteSource({
    required this.rangeReader,
    required this.name,
    required this.length,
    required this.rangeChunkBytes,
    required this.maxReadBytes,
  });

  final FrameRangeReader rangeReader;

  @override
  final String? name;

  @override
  final int length;

  final int rangeChunkBytes;
  final int maxReadBytes;
  final FrameFileCancellation _cancellation = FrameFileCancellation();
  bool _closed = false;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (_closed) {
      throw zip_core.ArchiveClosedException(
        'ZIP byte source is closed',
        format: 'zip',
      );
    }
    zip_core.checkByteSourceRange(this, offset, length);
    if (length == 0) return Uint8List(0);
    if (length > maxReadBytes) {
      throw zip_core.SizeLimitExceededException(
        'ZIP metadata read exceeds the configured limit',
        limit: maxReadBytes,
        format: 'zip',
        offset: offset,
      );
    }

    final output = Uint8List(length);
    var copied = 0;
    while (copied < length) {
      if (_closed || _cancellation.isCancelled) {
        throw zip_core.ArchiveClosedException(
          'ZIP byte source was closed during a read',
          format: 'zip',
          offset: offset + copied,
        );
      }
      final remaining = length - copied;
      final count =
          remaining < rangeChunkBytes ? remaining : rangeChunkBytes;
      final result = await rangeReader.readRange(
        offset + copied,
        offset + copied + count - 1,
        cancellation: _cancellation,
      );
      output.setRange(copied, copied + count, result.bytes);
      copied += count;
    }
    return output;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancellation.cancel();
  }
}
