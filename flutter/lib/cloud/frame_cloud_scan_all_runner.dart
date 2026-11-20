import 'frame_cloud_models.dart';
import 'frame_cloud_repository.dart';
import 'frame_cloud_scan_runner.dart';
import 'local_openlist_client.dart';

class FrameCloudScanAllLibraryResult {
  const FrameCloudScanAllLibraryResult({
    required this.library,
    required this.rootPath,
    required this.state,
    required this.scannedCount,
    required this.indexedCount,
    required this.skippedCount,
    required this.visitedFolderCount,
    required this.removedCount,
    required this.completed,
    required this.paused,
    this.error,
    this.skippedExisting = false,
  });

  final FrameCloudLibrary library;
  final String rootPath;
  final FrameCloudScanState? state;
  final int scannedCount;
  final int indexedCount;
  final int skippedCount;
  final int visitedFolderCount;
  final int removedCount;
  final bool completed;
  final bool paused;
  final bool skippedExisting;
  final String? error;
}

class FrameCloudScanAllResult {
  const FrameCloudScanAllResult({
    required this.libraries,
    required this.paused,
    this.error,
  });

  final List<FrameCloudScanAllLibraryResult> libraries;
  final bool paused;
  final String? error;

  bool get completed =>
      error == null &&
      !paused &&
      libraries.length == FrameCloudLibrary.values.length &&
      libraries.every((result) => result.completed);
}

class FrameCloudScanAllRunner {
  FrameCloudScanAllRunner({
    required FrameCloudRepository repository,
    LocalOpenListClient? localClient,
  })  : _repository = repository,
        _localClient = localClient;

  final FrameCloudRepository _repository;
  final LocalOpenListClient? _localClient;
  bool _running = false;
  bool _pauseRequested = false;
  FrameCloudScanRunner? _activeRunner;

  bool get isRunning => _running;

  void requestPause() {
    if (!_running) return;
    _pauseRequested = true;
    _activeRunner?.requestPause();
  }

  Future<FrameCloudScanAllResult> run({
    required FrameCloudProvider provider,
    required Map<FrameCloudLibrary, String> rootPaths,
    void Function(
      FrameCloudLibrary library,
      FrameCloudScanProgress progress,
    )? onProgress,
  }) async {
    if (_running) {
      return const FrameCloudScanAllResult(
        libraries: [],
        paused: false,
        error: '目前已有全庫掃描工作正在執行。',
      );
    }

    final normalizedRoots = <FrameCloudLibrary, String>{};
    for (final library in FrameCloudLibrary.values) {
      final root = normalizeFrameCloudPath(rootPaths[library] ?? '');
      if (root == null) {
        return FrameCloudScanAllResult(
          libraries: const [],
          paused: false,
          error: '${library.label}根目錄必須是有效的絕對路徑。',
        );
      }
      normalizedRoots[library] = root;
    }

    if (provider == FrameCloudProvider.local &&
        !(_localClient?.isAuthenticated ?? false)) {
      return const FrameCloudScanAllResult(
        libraries: [],
        paused: false,
        error: '本地 OpenList 尚未登入，請先登入再開始全庫掃描。',
      );
    }

    _running = true;
    _pauseRequested = false;
    final completedLibraries = <FrameCloudScanAllLibraryResult>[];
    try {
      final previousStates = <FrameCloudLibrary, FrameCloudScanState?>{};
      for (final library in FrameCloudLibrary.values) {
        previousStates[library] = await _repository.loadScanState(
          provider: provider,
          library: library,
          rootPath: normalizedRoots[library]!,
        );
      }

      // If either library has an unfinished checkpoint, this is a resume pass.
      // Already completed libraries stay untouched while the unfinished one
      // resumes. When neither has an unfinished checkpoint, a new all-library
      // run refreshes previously completed indexes as well.
      final resumePass = previousStates.values
          .any((state) => state != null && !state.completed);

      // Persist a checkpoint for the library that has not started yet. This
      // lets a pause between Books and Comics resume at the correct library
      // instead of mistaking a completed first library for a fresh run.
      for (final library in FrameCloudLibrary.values) {
        if (previousStates[library] != null) continue;
        final placeholder = FrameCloudScanState.initial(
          provider: provider,
          library: library,
          rootPath: normalizedRoots[library]!,
          scanId: 'scan_all_${DateTime.now().microsecondsSinceEpoch}_${library.apiValue}',
        );
        await _repository.saveScanState(placeholder);
        previousStates[library] = placeholder;
      }

      for (final library in FrameCloudLibrary.values) {
        if (_pauseRequested) {
          return FrameCloudScanAllResult(
            libraries: List.unmodifiable(completedLibraries),
            paused: true,
          );
        }
        final root = normalizedRoots[library]!;
        var state = previousStates[library];

        if (resumePass && state?.completed == true) {
          completedLibraries.add(
            FrameCloudScanAllLibraryResult(
              library: library,
              rootPath: root,
              state: state,
              scannedCount: 0,
              indexedCount: 0,
              skippedCount: 0,
              visitedFolderCount: 0,
              removedCount: 0,
              completed: true,
              paused: false,
              skippedExisting: true,
            ),
          );
          continue;
        }

        final runner = FrameCloudScanRunner(
          repository: _repository,
          localClient: _localClient,
        );
        _activeRunner = runner;
        var forceRescan = !resumePass && state?.completed == true;
        var scanned = 0;
        var indexed = 0;
        var skipped = 0;
        var folders = 0;
        var removed = 0;
        var completed = false;
        var paused = false;
        String? failure;

        while (true) {
          if (_pauseRequested) {
            paused = true;
            if (state != null) {
              state = state.copyWith(
                pausedByUser: true,
                resumeOnNextOpen: false,
              );
              await _repository.saveScanState(state);
            }
            break;
          }
          final batch = await runner.run(
            provider: provider,
            library: library,
            rootPath: root,
            forceRescan: forceRescan,
            onProgress: (progress) => onProgress?.call(library, progress),
          );
          forceRescan = false;
          state = batch.state ?? state;
          scanned += batch.scannedThisBatch;
          indexed += batch.indexedThisBatch;
          skipped += batch.skippedThisBatch;
          folders += batch.foldersThisBatch;
          removed += batch.removedCount;
          completed = batch.completed;
          paused = batch.paused;
          failure = batch.error;

          if (failure != null || paused || completed) break;
          if (!batch.succeeded ||
              (batch.scannedThisBatch == 0 && batch.foldersThisBatch == 0)) {
            failure = '本批掃描未能推進游標，已停止全庫流程以避免重複執行。';
            break;
          }
        }

        _activeRunner = null;
        completedLibraries.add(
          FrameCloudScanAllLibraryResult(
            library: library,
            rootPath: root,
            state: state,
            scannedCount: scanned,
            indexedCount: indexed,
            skippedCount: skipped,
            visitedFolderCount: folders,
            removedCount: removed,
            completed: completed,
            paused: paused,
            error: failure,
          ),
        );

        if (failure != null || paused || !completed) {
          return FrameCloudScanAllResult(
            libraries: List.unmodifiable(completedLibraries),
            paused: paused,
            error: failure,
          );
        }
      }

      return FrameCloudScanAllResult(
        libraries: List.unmodifiable(completedLibraries),
        paused: false,
      );
    } catch (error) {
      return FrameCloudScanAllResult(
        libraries: List.unmodifiable(completedLibraries),
        paused: false,
        error: error.toString(),
      );
    } finally {
      _activeRunner = null;
      _pauseRequested = false;
      _running = false;
    }
  }
}
