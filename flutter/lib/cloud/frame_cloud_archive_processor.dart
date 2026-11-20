import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import '../core/frame_app_config.dart';
import '../library/frame_book.dart';
import '../reader/frame_epub_parser.dart';
import '../reader/frame_zip_archive.dart';
import '../transport/frame_file_source.dart';
import '../transport/frame_file_source_factory.dart';
import 'frame_cloud_models.dart';
import 'frame_cloud_repository.dart';
import 'local_openlist_client.dart';

class FrameCloudArchiveProgress {
  const FrameCloudArchiveProgress({
    required this.message,
    required this.processed,
    required this.pending,
    this.state,
  });

  final String message;
  final int processed;
  final int pending;
  final FrameCloudScanState? state;
}

class FrameCloudArchiveBatchResult {
  const FrameCloudArchiveBatchResult({
    required this.processed,
    required this.uploaded,
    required this.missing,
    required this.failed,
    required this.metadataProcessed,
    required this.pending,
    this.state,
  });

  final int processed;
  final int uploaded;
  final int missing;
  final int failed;
  final int metadataProcessed;
  final int pending;
  final FrameCloudScanState? state;
}

typedef FrameCloudArchiveProgressCallback = void Function(
  FrameCloudArchiveProgress progress,
);

/// Processes the existing D1 pending-cover queue without downloading an
/// original archive in full. EPUB OPF metadata and its cover are read from
/// bounded ZIP entries backed by FrameFileSource HTTP Range requests. CBZ
/// covers use the first natural-sort image, preferring cover/front names.
class FrameCloudArchiveProcessor {
  FrameCloudArchiveProcessor({
    required FrameCloudRepository repository,
    LocalOpenListClient? localClient,
  })  : _repository = repository,
        _localClient = localClient;

  static const int _maxOriginalCoverBytes = 15 * 1024 * 1024;
  static const int _maxUploadBytes = 2 * 1024 * 1024;
  static const int _rangeBytes = 1024 * 1024;
  static const int _coverMaxDimension = 512;

  final FrameCloudRepository _repository;
  final LocalOpenListClient? _localClient;
  bool _running = false;

  bool get isRunning => _running;

  Future<int> retryFailed({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
  }) =>
      _repository.retryFailedCovers(
        provider: provider,
        library: library,
        rootPath: rootPath,
      );

  Future<FrameCloudArchiveBatchResult> processPendingBatch({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    int maxItems = 8,
    FrameCloudScanState? scanState,
    FrameCloudArchiveProgressCallback? onProgress,
  }) async {
    if (_running) {
      throw StateError('封面索引工作已在執行。');
    }
    final root = normalizeFrameCloudPath(rootPath);
    if (root == null) throw const FormatException('封面佇列根目錄無效。');
    if (provider == FrameCloudProvider.local &&
        !(_localClient?.isAuthenticated ?? false)) {
      throw const LocalOpenListException('本地 OpenList 尚未登入，無法讀取封面。');
    }
    if (maxItems < 1 || maxItems > 30) {
      throw ArgumentError.value(maxItems, 'maxItems', '每批必須介於 1 至 30。');
    }

    _running = true;
    var updatedState = scanState ??
        await _repository.loadScanState(
          provider: provider,
          library: library,
          rootPath: root,
        );
    var processed = 0;
    var uploaded = 0;
    var missing = 0;
    var failed = 0;
    var metadataProcessed = 0;
    var pending = 0;

    try {
      final queue = await _repository.loadPendingCovers(
        provider: provider,
        library: library,
        rootPath: root,
        limit: maxItems,
      );
      pending = queue.total;
      final items = queue.items.take(maxItems).toList(growable: false);

      for (final item in items) {
        _emit(
          onProgress,
          '正在處理封面與 EPUB 元資料：${item.name}',
          processed,
          pending,
          updatedState,
        );
        var metadataCount = 0;
        var coverUploaded = false;
        var coverMissing = false;
        String? failure;

        try {
          final result = await _processOne(
            provider: provider,
            library: library,
            rootPath: root,
            item: item,
          );
          metadataCount = result.metadataProcessed ? 1 : 0;
          coverUploaded = result.uploaded;
          coverMissing = result.missing;
        } catch (error) {
          failure = error.toString();
          try {
            await _repository.updateCoverStatus(
              provider: provider,
              library: library,
              rootPath: root,
              path: item.path,
              status: 'error',
              error: failure,
            );
          } catch (statusError) {
            failure = '$failure；保存失敗狀態亦失敗：$statusError';
          }
        }

        processed++;
        if (coverUploaded) uploaded++;
        if (coverMissing) missing++;
        if (failure != null) failed++;
        metadataProcessed += metadataCount;

        if (updatedState != null) {
          final errors = List<Map<String, dynamic>>.from(updatedState.errors);
          if (failure != null) {
            errors.add({
              'path': item.path,
              'message': failure.substring(0, math.min(700, failure.length)),
              'at': DateTime.now().toIso8601String(),
            });
            if (errors.length > 20) {
              errors.removeRange(0, errors.length - 20);
            }
          }
          updatedState = updatedState.copyWith(
            coverReadyCount: updatedState.coverReadyCount + (coverUploaded ? 1 : 0),
            coverMissingCount: updatedState.coverMissingCount + (coverMissing ? 1 : 0),
            coverFailedCount: updatedState.coverFailedCount + (failure != null ? 1 : 0),
            metadataProcessedCount:
                updatedState.metadataProcessedCount + metadataCount,
            failedCount: updatedState.failedCount + (failure != null ? 1 : 0),
            errors: errors,
            updatedAt: DateTime.now().toIso8601String(),
          );
          try {
            await _repository.saveScanState(updatedState);
          } catch (_) {
            // D1 cover status remains authoritative; keep processing the queue
            // even if the aggregate progress snapshot cannot be refreshed.
          }
        }

        final label = failure != null
            ? '封面處理失敗：${item.name}'
            : coverUploaded
                ? '封面已保存至私有 R2：${item.name}'
                : '沒有找到可用封面：${item.name}';
        _emit(onProgress, label, processed, pending, updatedState);
      }

      final remaining = await _repository.loadPendingCovers(
        provider: provider,
        library: library,
        rootPath: root,
        limit: 1,
      );
      pending = remaining.total;
      return FrameCloudArchiveBatchResult(
        processed: processed,
        uploaded: uploaded,
        missing: missing,
        failed: failed,
        metadataProcessed: metadataProcessed,
        pending: pending,
        state: updatedState,
      );
    } finally {
      _running = false;
    }
  }

  Future<_ProcessedArchiveItem> _processOne({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    required FrameCloudEntry item,
  }) async {
    final book = FrameBook.fromJson({
      'id': 'cloud:${sha256.convert(item.path.codeUnits)}',
      'provider': provider.apiValue,
      'library': library.apiValue,
      'rootPath': rootPath,
      'path': item.path,
      'fileName': item.name,
      'format': item.format,
      'shelf': library.apiValue,
      'size': item.size,
      'cloudSource': {
        'provider': provider.apiValue,
        'library': library.apiValue,
        'rootPath': rootPath,
        'path': item.path,
      },
    });

    final FrameFileSource source;
    final bool localSource = provider == FrameCloudProvider.local;
    if (localSource) {
      source = _LocalOpenListArchiveSource(
        client: _localClient!,
        path: item.path,
      );
    } else {
      source = createFrameFileSource(baseUri: FrameAppConfig.apiBaseUri);
    }

    FrameZipArchive? archive;
    try {
      archive = await FrameZipArchive.open(
        source: source,
        book: book,
        maxRangeBytes: _rangeBytes,
        rangeChunkBytes: _rangeBytes,
        maxMetadataReadBytes: 32 * 1024 * 1024,
        maxEntrySize: 256 * 1024 * 1024,
        maxEntryCount: 100000,
      );

      FrameZipArchiveEntry? coverEntry;
      var metadataProcessed = false;
      if (item.format == 'EPUB') {
        final epub = await const FrameEpubParser().parse(archive);
        final metadata = epub.metadata;
        await _repository.saveEpubMetadataBatch(
          provider: provider,
          library: library,
          rootPath: rootPath,
          entries: [
            {
              'path': item.path,
              'metadata': {
                'title': metadata.title,
                'creators': metadata.creators,
                'language': metadata.language,
                'description': metadata.description,
                'publisher': metadata.publisher,
                'date': metadata.publicationDate,
                'identifier': metadata.identifier,
                'subjects': metadata.subjects,
              },
            },
          ],
        );
        metadataProcessed = true;
        final coverPath = epub.coverImage?.path;
        if (coverPath != null) coverEntry = archive.file(coverPath);
        coverEntry ??= _findNamedCover(archive);
      } else if (item.format == 'CBZ' && library == FrameCloudLibrary.comics) {
        coverEntry = _findCbzCover(archive);
      }

      if (coverEntry == null) {
        await _repository.updateCoverStatus(
          provider: provider,
          library: library,
          rootPath: rootPath,
          path: item.path,
          status: 'missing',
        );
        return _ProcessedArchiveItem(
          metadataProcessed: metadataProcessed,
          uploaded: false,
          missing: true,
        );
      }

      final original = await archive.readBytes(
        coverEntry,
        maxBytes: _maxOriginalCoverBytes,
      );
      final thumbnail = await _makePngThumbnail(original);
      if (thumbnail.length > _maxUploadBytes) {
        throw const FormatException('封面縮圖超過 2 MiB 上限。');
      }
      final hash = sha256.convert(thumbnail).toString();
      await _repository.uploadCover(
        provider: provider,
        library: library,
        rootPath: rootPath,
        path: item.path,
        sha256: hash,
        bytes: thumbnail,
      );
      return _ProcessedArchiveItem(
        metadataProcessed: metadataProcessed,
        uploaded: true,
        missing: false,
      );
    } finally {
      await archive?.close();
      if (source is FrameCloudFileSource) source.close();
    }
  }

  FrameZipArchiveEntry? _findNamedCover(FrameZipArchive archive) {
    final candidates = archive.files.where((entry) {
      final lower = entry.path.toLowerCase();
      return _isRasterImage(lower);
    }).toList()
      ..sort((a, b) => compareFrameFileNames(a.path, b.path));
    if (candidates.isEmpty) return null;
    for (final candidate in candidates) {
      if (RegExp(r'(^|[/_-])(cover|front)([/_.-]|$)', caseSensitive: false)
          .hasMatch(candidate.path)) {
        return candidate;
      }
    }
    return candidates.first;
  }

  FrameZipArchiveEntry? _findCbzCover(FrameZipArchive archive) {
    final candidates = archive.files.where((entry) {
      final lower = entry.path.toLowerCase();
      if (!_isRasterImage(lower)) return false;
      if (lower.contains('/__macosx/') ||
          lower.startsWith('__macosx/') ||
          lower.split('/').last.startsWith('._')) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) => compareFrameFileNames(a.path, b.path));
    if (candidates.isEmpty) return null;
    for (final candidate in candidates) {
      if (RegExp(r'(^|[/_-])(cover|front)([/_.-]|$)', caseSensitive: false)
          .hasMatch(candidate.path)) {
        return candidate;
      }
    }
    return candidates.first;
  }

  bool _isRasterImage(String path) =>
      RegExp(r'\.(jpe?g|png|webp|gif|bmp|avif)$', caseSensitive: false)
          .hasMatch(path);

  Future<Uint8List> _makePngThumbnail(Uint8List source) async {
    if (source.isEmpty || source.length > _maxOriginalCoverBytes) {
      throw const FormatException('封面原始圖片不存在或超過 15 MiB。');
    }

    final buffer = await ui.ImmutableBuffer.fromUint8List(source);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width < 1 || height < 1 || width * height > 100000000) {
        throw const FormatException('封面圖片尺寸無效或超過解碼上限。');
      }
      final scale = math.min(
        1.0,
        _coverMaxDimension / math.max(width, height),
      );
      final targetWidth = math.max(1, (width * scale).round());
      final targetHeight = math.max(1, (height * scale).round());
      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes == 0) {
        throw const FormatException('無法產生 PNG 封面縮圖。');
      }
      return Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  void _emit(
    FrameCloudArchiveProgressCallback? callback,
    String message,
    int processed,
    int pending,
    FrameCloudScanState? state,
  ) {
    callback?.call(FrameCloudArchiveProgress(
      message: message,
      processed: processed,
      pending: pending,
      state: state,
    ));
  }
}

class _ProcessedArchiveItem {
  const _ProcessedArchiveItem({
    required this.metadataProcessed,
    required this.uploaded,
    required this.missing,
  });

  final bool metadataProcessed;
  final bool uploaded;
  final bool missing;
}

class _LocalOpenListArchiveSource implements FrameFileSource {
  _LocalOpenListArchiveSource({
    required this.client,
    required this.path,
  });

  final LocalOpenListClient client;
  final String path;

  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    final range = request.range;
    if (range == null || range.start == null) {
      throw const LocalOpenListException('封面 ZIP 讀取必須使用明確的 HTTP Range。');
    }
    final start = range.start!;
    final end = range.end ?? (start + FrameCloudArchiveProcessor._rangeBytes - 1);
    final length = end - start + 1;
    if (length < 1 || length > 1024 * 1024) {
      throw const LocalOpenListException('本地 OpenList 封面 Range 超過 1 MiB 上限。');
    }
    if (request.cancellation?.isCancelled == true) {
      throw StateError('封面讀取已取消。');
    }
    final result = await client.readRange(
      path,
      start: start,
      length: length,
    );
    if (request.cancellation?.isCancelled == true) {
      throw StateError('封面讀取已取消。');
    }
    return FrameFileResponse(
      statusCode: 206,
      headers: {
        'Content-Type': 'application/zip',
        'Content-Length': result.bytes.length.toString(),
        'Content-Range':
            'bytes ${result.start}-${result.end}/${result.totalSize}',
        'Accept-Ranges': 'bytes',
      },
      stream: Stream<List<int>>.value(result.bytes),
      onClose: () {},
      requestedRange: range,
    );
  }
}
