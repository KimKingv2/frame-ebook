import 'dart:math';

import 'frame_cloud_models.dart';
import 'frame_cloud_repository.dart';
import 'local_openlist_client.dart';

class FrameCloudScanProgress {
  const FrameCloudScanProgress({
    required this.phase,
    required this.state,
    required this.scannedThisBatch,
    required this.indexedThisBatch,
    required this.skippedThisBatch,
    required this.foldersThisBatch,
  });

  final String phase;
  final FrameCloudScanState state;
  final int scannedThisBatch;
  final int indexedThisBatch;
  final int skippedThisBatch;
  final int foldersThisBatch;
}

class FrameCloudScanRunResult {
  const FrameCloudScanRunResult({
    required this.state,
    required this.scannedThisBatch,
    required this.indexedThisBatch,
    required this.skippedThisBatch,
    required this.foldersThisBatch,
    required this.removedCount,
    required this.completed,
    required this.paused,
    this.error,
  });

  final FrameCloudScanState? state;
  final int scannedThisBatch;
  final int indexedThisBatch;
  final int skippedThisBatch;
  final int foldersThisBatch;
  final int removedCount;
  final bool completed;
  final bool paused;
  final String? error;

  bool get succeeded => error == null && state != null;
}

class FrameCloudScanRunner {
  FrameCloudScanRunner({
    required FrameCloudRepository repository,
    LocalOpenListClient? localClient,
    DateTime Function()? clock,
    String Function()? createScanId,
  })  : _repository = repository,
        _localClient = localClient,
        _clock = clock ?? DateTime.now,
        _createScanId = createScanId ?? _makeScanId;

  final FrameCloudRepository _repository;
  final LocalOpenListClient? _localClient;
  final DateTime Function() _clock;
  final String Function() _createScanId;
  bool _running = false;
  bool _pauseRequested = false;

  bool get isRunning => _running;

  void requestPause() {
    if (_running) _pauseRequested = true;
  }

  Future<FrameCloudScanRunResult> run({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    bool forceRescan = false,
    int maxEntriesPerBatch = 500,
    int maxFoldersPerBatch = 500,
    Duration maxDuration = const Duration(minutes: 4),
    int pageSize = 100,
    void Function(FrameCloudScanProgress progress)? onProgress,
  }) async {
    if (_running) {
      return const FrameCloudScanRunResult(
        state: null,
        scannedThisBatch: 0,
        indexedThisBatch: 0,
        skippedThisBatch: 0,
        foldersThisBatch: 0,
        removedCount: 0,
        completed: false,
        paused: false,
        error: '目前已有掃描工作正在執行。',
      );
    }
    final root = normalizeFrameCloudPath(rootPath);
    if (root == null) {
      return const FrameCloudScanRunResult(
        state: null,
        scannedThisBatch: 0,
        indexedThisBatch: 0,
        skippedThisBatch: 0,
        foldersThisBatch: 0,
        removedCount: 0,
        completed: false,
        paused: false,
        error: '書庫根目錄必須是有效的絕對路徑。',
      );
    }
    if (provider == FrameCloudProvider.local &&
        !(_localClient?.isAuthenticated ?? false)) {
      return const FrameCloudScanRunResult(
        state: null,
        scannedThisBatch: 0,
        indexedThisBatch: 0,
        skippedThisBatch: 0,
        foldersThisBatch: 0,
        removedCount: 0,
        completed: false,
        paused: false,
        error: '本地 OpenList 尚未登入，請先登入再開始掃描。',
      );
    }

    _running = true;
    _pauseRequested = false;
    final startedAt = _clock();
    FrameCloudScanState? state;
    var scanned = 0;
    var indexed = 0;
    var skipped = 0;
    var folders = 0;
    var removed = 0;

    try {
      state = await _repository.loadScanState(
        provider: provider,
        library: library,
        rootPath: root,
      );
      final matchesScope = state != null &&
          state.version == 1 &&
          state.provider == provider &&
          state.library == library &&
          state.rootPath == root;
      if (!matchesScope || forceRescan) {
        state = FrameCloudScanState.initial(
          provider: provider,
          library: library,
          rootPath: root,
          scanId: _createScanId(),
        );
        state = _withRaw(state, {
          'scanMode': forceRescan ? '完整重掃' : '首次完整掃描',
        });
        await _repository.saveScanState(state);
      } else if (state.completed) {
        return FrameCloudScanRunResult(
          state: state,
          scannedThisBatch: 0,
          indexedThisBatch: 0,
          skippedThisBatch: 0,
          foldersThisBatch: 0,
          removedCount: _safeInt(state.raw['removedCount']),
          completed: true,
          paused: false,
        );
      } else {
        state = state.copyWith(pausedByUser: false, resumeOnNextOpen: false);
        await _repository.saveScanState(state);
      }

      _emit(
        onProgress,
        '已載入 D1 掃描進度',
        state,
        scanned,
        indexed,
        skipped,
        folders,
      );

      while (!state.completed &&
          scanned < maxEntriesPerBatch &&
          folders < maxFoldersPerBatch &&
          _clock().difference(startedAt) < maxDuration &&
          !_pauseRequested) {
        if (state.currentFolder == null) {
          if (state.pendingFolders.isEmpty) break;
          final nextFolder = state.pendingFolders.removeAt(0);
          state = state.copyWith(
            currentFolder: nextFolder,
            page: 1,
            pendingFolders: state.pendingFolders,
          );
          await _repository.saveScanState(state);
          _emit(onProgress, '進入資料夾：$nextFolder', state, scanned, indexed,
              skipped, folders);
        }

        final folder = state.currentFolder!;
        final page = state.page.clamp(1, 100000).toInt();
        final listing = await _loadDirectory(
          provider: provider,
          library: library,
          rootPath: root,
          path: folder,
          page: page,
          perPage: pageSize.clamp(1, 100).toInt(),
        );

        final entries = <Map<String, dynamic>>[];
        final seen = state.seenFolders.toSet();
        var foundFolders = 0;
        for (final item in listing.items) {
          final path = normalizeFrameCloudPath(item.path);
          if (path == null ||
              path == root ||
              !frameCloudPathIsWithinRoot(path, root) ||
              item.name.isEmpty) {
            continue;
          }
          if (item.isDirectory) {
            entries.add(_entryJson(item, folder));
            foundFolders++;
            if (seen.add(path)) {
              state.seenFolders.add(path);
              state.pendingFolders.add(path);
            }
            continue;
          }
          final supported = library == FrameCloudLibrary.books
              ? item.format == 'EPUB'
              : item.format == 'EPUB' || item.format == 'CBZ';
          if (!supported) continue;
          entries.add(_entryJson(item, folder));
        }

        final pageSkipped = listing.items.length - entries.length;
        scanned += listing.items.length;
        skipped += pageSkipped;
        var saved = 0;
        if (entries.isNotEmpty) {
          saved = await _repository.writeIndexEntries(
            provider: provider,
            library: library,
            rootPath: root,
            scanId: state.scanId,
            entries: entries,
          );
        }
        indexed += saved;

        final nextPage = page * listing.perPage < listing.total;
        if (nextPage) {
          state = state.copyWith(
            page: page + 1,
            scannedCount: state.scannedCount + listing.items.length,
            indexedCount: state.indexedCount + saved,
            skippedCount: state.skippedCount + pageSkipped,
            pendingFolders: state.pendingFolders,
            seenFolders: state.seenFolders,
          );
        } else {
          state = state.copyWith(
            clearCurrentFolder: true,
            page: 1,
            visitedFolderCount: state.visitedFolderCount + 1,
            scannedCount: state.scannedCount + listing.items.length,
            indexedCount: state.indexedCount + saved,
            skippedCount: state.skippedCount + pageSkipped,
            pendingFolders: state.pendingFolders,
            seenFolders: state.seenFolders,
          );
          folders++;
        }
        await _repository.saveScanState(state);
        _emit(
          onProgress,
          '已保存 $folder 第 $page 頁：新增／更新 $saved 筆索引',
          state,
          scanned,
          indexed,
          skipped,
          folders,
        );
      }

      if (!_pauseRequested &&
          state.currentFolder == null &&
          state.pendingFolders.isEmpty) {
        removed = await _repository.completeScan(
          provider: provider,
          library: library,
          rootPath: root,
          scanId: state.scanId,
        );
        state = _withRaw(state, {
          'removedCount': removed,
          'completedAt': _clock().toIso8601String(),
        });
        state = state.copyWith(
          completed: true,
          pausedByUser: false,
          resumeOnNextOpen: false,
        );
        await _repository.saveScanState(state);
        _emit(onProgress, '目錄索引完成', state, scanned, indexed, skipped,
            folders);
      } else {
        state = state.copyWith(
          pausedByUser: _pauseRequested,
          resumeOnNextOpen: false,
        );
        await _repository.saveScanState(state);
        _emit(
          onProgress,
          _pauseRequested ? '已暫停，掃描游標已保存' : '本批已結束，掃描游標已保存',
          state,
          scanned,
          indexed,
          skipped,
          folders,
        );
      }

      return FrameCloudScanRunResult(
        state: state,
        scannedThisBatch: scanned,
        indexedThisBatch: indexed,
        skippedThisBatch: skipped,
        foldersThisBatch: folders,
        removedCount: removed,
        completed: state.completed,
        paused: _pauseRequested,
      );
    } catch (error) {
      if (state != null) {
        final message = error.toString().substring(
              0,
              min(700, error.toString().length),
            );
        state = _withRaw(state, {'lastError': message});
        state.errors.add({
          'path': state.currentFolder ?? root,
          'message': message,
          'at': _clock().toIso8601String(),
        });
        if (state.errors.length > 20) {
          state.errors.removeRange(0, state.errors.length - 20);
        }
        state = state.copyWith(failedCount: state.failedCount + 1);
        try {
          await _repository.saveScanState(state);
        } catch (_) {
          // Preserve the original scan failure; the last successfully saved
          // page cursor remains safe to resume.
        }
      }
      return FrameCloudScanRunResult(
        state: state,
        scannedThisBatch: scanned,
        indexedThisBatch: indexed,
        skippedThisBatch: skipped,
        foldersThisBatch: folders,
        removedCount: removed,
        completed: false,
        paused: _pauseRequested,
        error: error.toString(),
      );
    } finally {
      _running = false;
      _pauseRequested = false;
    }
  }

  Future<FrameCloudDirectoryPage> _loadDirectory({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    required String path,
    required int page,
    required int perPage,
  }) async {
    if (provider != FrameCloudProvider.local) {
      return _repository.loadServerDirectoryPage(
        provider: provider,
        library: library,
        rootPath: rootPath,
        path: path,
        page: page,
        perPage: perPage,
      );
    }
    final directory = await _localClient!.listDirectory(
      path,
      page: page,
      perPage: perPage,
    );
    final items = directory.items
        .map((entry) {
          final lower = entry.name.toLowerCase();
          final format = lower.endsWith('.epub')
              ? 'EPUB'
              : lower.endsWith('.cbz')
                  ? 'CBZ'
                  : '';
          return FrameCloudEntry(
            name: entry.name,
            path: entry.path,
            parentPath: entry.parentPath,
            isDirectory: entry.isDirectory,
            format: format,
            size: entry.size,
            modified: entry.modified,
            coverHash: null,
            coverType: null,
            coverStatus: 'pending',
            coverError: null,
          );
        })
        .toList(growable: false);
    return FrameCloudDirectoryPage(
      provider: provider,
      library: library,
      rootPath: rootPath,
      path: path,
      page: directory.page,
      perPage: directory.perPage,
      total: directory.total,
      indexed: false,
      scanSummary: null,
      items: items,
    );
  }

  static FrameCloudScanState _withRaw(
    FrameCloudScanState state,
    Map<String, dynamic> updates,
  ) =>
      FrameCloudScanState(
        version: state.version,
        provider: state.provider,
        library: state.library,
        rootPath: state.rootPath,
        scanId: state.scanId,
        pendingFolders: state.pendingFolders,
        currentFolder: state.currentFolder,
        page: state.page,
        seenFolders: state.seenFolders,
        scannedCount: state.scannedCount,
        indexedCount: state.indexedCount,
        skippedCount: state.skippedCount,
        failedCount: state.failedCount,
        visitedFolderCount: state.visitedFolderCount,
        coverReadyCount: state.coverReadyCount,
        coverMissingCount: state.coverMissingCount,
        coverFailedCount: state.coverFailedCount,
        metadataProcessedCount: state.metadataProcessedCount,
        metadataFailedCount: state.metadataFailedCount,
        pausedByUser: state.pausedByUser,
        resumeOnNextOpen: state.resumeOnNextOpen,
        completed: state.completed,
        errors: state.errors,
        createdAt: state.createdAt,
        updatedAt: state.updatedAt,
        raw: {...state.raw, ...updates},
      );

  static Map<String, dynamic> _entryJson(
    FrameCloudEntry item,
    String parentPath,
  ) =>
      {
        'path': item.path,
        'parentPath': parentPath,
        'name': item.name,
        'isDir': item.isDirectory,
        'format': item.isDirectory ? '' : item.format,
        'size': item.size < 0 ? 0 : item.size,
        'modified': item.modified,
      };

  static void _emit(
    void Function(FrameCloudScanProgress progress)? callback,
    String phase,
    FrameCloudScanState state,
    int scanned,
    int indexed,
    int skipped,
    int folders,
  ) {
    callback?.call(
      FrameCloudScanProgress(
        phase: phase,
        state: state,
        scannedThisBatch: scanned,
        indexedThisBatch: indexed,
        skippedThisBatch: skipped,
        foldersThisBatch: folders,
      ),
    );
  }

  static String _makeScanId() {
    final random = Random.secure().nextInt(0x7fffffff);
    return 'scan_${DateTime.now().microsecondsSinceEpoch}_${random.toRadixString(36)}';
  }

  static int _safeInt(dynamic value) {
    if (value is int) return value;
    if (value is num && value.isFinite) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
