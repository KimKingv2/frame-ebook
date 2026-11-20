import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/frame_api_scope.dart';
import '../core/frame_app_config.dart';
import '../legacy/frame_legacy_page.dart';
import 'frame_cloud_models.dart';
import 'frame_cloud_repository.dart';
import 'frame_cloud_archive_processor.dart';
import 'frame_cloud_scan_all_runner.dart';
import 'frame_cloud_scan_runner.dart';
import 'local_openlist_client.dart';
import 'local_openlist_settings_store.dart';

const _cloudBg = Color(0xFF12101A);
const _cloudPanel = Color(0xFF1B1825);
const _cloudRaised = Color(0xFF211D2D);
const _cloudInk = Color(0xFFF4F0FA);
const _cloudMuted = Color(0xFFAAA2B8);
const _cloudAccent = Color(0xFFC5ADFF);
const _cloudLine = Color(0x55393247);

class FrameCloudManagerScreen extends StatefulWidget {
  const FrameCloudManagerScreen({super.key});

  @override
  State<FrameCloudManagerScreen> createState() => _FrameCloudManagerScreenState();
}

class _FrameCloudManagerScreenState extends State<FrameCloudManagerScreen>
    with SingleTickerProviderStateMixin {
  final _booksRoot = TextEditingController(text: FrameCloudDefaults.booksRoot);
  final _comicsRoot = TextEditingController(text: FrameCloudDefaults.comicsRoot);
  final _localUrl = TextEditingController();
  final _localUsername = TextEditingController();
  final _localPassword = TextEditingController();
  final _search = TextEditingController();

  late final TabController _tabs;
  late FrameCloudRepository _repository;
  late LocalOpenListSettingsStore _localSettings;
  bool _dependenciesReady = false;
  bool _loading = true;
  bool _loadingDirectory = false;
  bool _savingRoots = false;
  bool _loggingIn = false;
  bool _testingConnection = false;
  String? _error;
  String? _directoryError;
  FrameCloudSession? _session;
  FrameCloudProvider _provider = FrameCloudProvider.vps;
  FrameCloudLibrary _library = FrameCloudLibrary.books;
  LocalOpenListClient? _localClient;
  List<FrameCloudEntry> _items = const [];
  String _currentPath = FrameCloudDefaults.booksRoot;
  String _query = '';
  int _directoryPage = 1;
  int _totalItems = 0;
  bool _scanRunning = false;
  bool _archiveProcessing = false;
  int _pendingCovers = 0;
  FrameCloudScanState? _scanState;
  FrameCloudScanRunner? _activeScanRunner;
  FrameCloudScanAllRunner? _activeScanAllRunner;
  final Map<FrameCloudLibrary, FrameCloudScanState?> _libraryScanStates = {};
  String _scanMessage = '尚無索引掃描紀錄';

  int get _pageCount => _totalItems == 0 ? 1 : (_totalItems + 99) ~/ 100;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_dependenciesReady) return;
    _dependenciesReady = true;
    _repository = FrameCloudRepository(FrameApiScope.of(context));
    _localSettings = LocalOpenListSettingsStore();
    unawaited(_load());
  }

  @override
  void dispose() {
    _activeScanRunner?.requestPause();
    _activeScanAllRunner?.requestPause();
    _tabs.dispose();
    _booksRoot.dispose();
    _comicsRoot.dispose();
    _localUrl.dispose();
    _localUsername.dispose();
    _localPassword.dispose();
    _search.dispose();
    _localClient?.close();
    super.dispose();
  }

  String get _selectedRoot => (_library == FrameCloudLibrary.books
          ? _booksRoot.text
          : _comicsRoot.text)
      .trim();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<dynamic>([
        _repository.loadSession(),
        _repository.loadPreferences(),
        _localSettings.loadBaseUrl(),
        _localSettings.loadLocalSelected(),
      ]);
      final session = results[0] as FrameCloudSession;
      final preferences = results[1] as FrameCloudPreferences;
      final savedLocalUrl = results[2] as String?;
      final localSelected = results[3] as bool;
      if (!mounted) return;
      setState(() {
        _session = session;
        _provider = localSelected
            ? FrameCloudProvider.local
            : preferences.activeProvider;
        _library = preferences.activeLibrary;
        if (savedLocalUrl != null) _localUrl.text = savedLocalUrl;
        _booksRoot.text =
            preferences.rootFor(FrameCloudLibrary.books, session: session);
        _comicsRoot.text =
            preferences.rootFor(FrameCloudLibrary.comics, session: session);
        _currentPath = _selectedRoot;
        _loading = false;
      });
      await _loadDirectory();
      await _loadScanState();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadDirectory({int page = 1}) async {
    if (!mounted) return;
    final root = normalizeFrameCloudPath(_selectedRoot);
    final path = normalizeFrameCloudPath(_currentPath);
    if (root == null || path == null || !frameCloudPathIsWithinRoot(path, root)) {
      setState(() {
        _items = const [];
        _totalItems = 0;
        _directoryError = '請先設定有效的絕對根目錄。';
        _loadingDirectory = false;
      });
      return;
    }
    if (_provider == FrameCloudProvider.local &&
        !(_localClient?.isAuthenticated ?? false)) {
      setState(() {
        _items = const [];
        _totalItems = 0;
        _directoryError = null;
        _loadingDirectory = false;
      });
      return;
    }
    setState(() {
      _loadingDirectory = true;
      _directoryError = null;
      _directoryPage = page;
    });
    try {
      final List<FrameCloudEntry> items;
      var totalItems = 0;
      if (_provider == FrameCloudProvider.local) {
        final directory = await _localClient!.listDirectory(
          path,
          page: page,
          perPage: 100,
        );
        totalItems = directory.total;
        items = directory.items
            .where((item) {
              if (item.isDirectory) return true;
              final format = _formatForName(item.name);
              return _library == FrameCloudLibrary.books
                  ? format == 'EPUB'
                  : format == 'EPUB' || format == 'CBZ';
            })
            .map((item) => FrameCloudEntry(
                  name: item.name,
                  path: item.path,
                  parentPath: item.parentPath,
                  isDirectory: item.isDirectory,
                  format: _formatForName(item.name),
                  size: item.size,
                  modified: item.modified,
                  coverHash: null,
                  coverType: null,
                  coverStatus: 'pending',
                  coverError: null,
                ))
            .toList(growable: false);
      } else {
        final directory = await _repository.loadServerDirectoryPage(
          provider: _provider,
          library: _library,
          rootPath: root,
          path: path,
          page: page,
          perPage: 100,
        );
        items = directory.items;
        totalItems = directory.total;
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _totalItems = totalItems;
        _loadingDirectory = false;
        _directoryError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _loadingDirectory = false;
        _directoryError = error.toString();
      });
    }
  }

  static String _formatForName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.epub')) return 'EPUB';
    if (lower.endsWith('.cbz')) return 'CBZ';
    return '';
  }

  Future<void> _selectProvider(FrameCloudProvider? value) async {
    if (_scanRunning || _archiveProcessing) return;
    if (value == null || value == _provider) return;
    try {
      if (value == FrameCloudProvider.local) {
        await _localSettings.saveLocalSelected(true);
      } else {
        await _localSettings.saveLocalSelected(false);
        await _repository.saveActiveProvider(value);
      }
    } catch (error) {
      _showMessage('切換來源失敗：$error');
      return;
    }
    if (!mounted) return;
    setState(() {
      _provider = value;
      _currentPath = _selectedRoot;
    });
    await _loadDirectory();
    await _loadScanState();
  }

  Future<void> _selectLibrary(FrameCloudLibrary value) async {
    if (_scanRunning || _archiveProcessing) return;
    if (value == _library) return;
    setState(() {
      _library = value;
      _currentPath = value == FrameCloudLibrary.books
          ? _booksRoot.text.trim()
          : _comicsRoot.text.trim();
    });
    try {
      await _repository.saveActiveLibrary(value);
    } catch (error) {
      _showMessage(error.toString());
    }
    if (!mounted) return;
    await _loadDirectory();
    await _loadScanState();
  }

  Future<void> _saveRoots() async {
    final books = normalizeFrameCloudPath(_booksRoot.text);
    final comics = normalizeFrameCloudPath(_comicsRoot.text);
    if (books == null || comics == null) {
      _showMessage('電子書與漫畫根目錄都必須是有效的絕對路徑。');
      return;
    }
    setState(() => _savingRoots = true);
    try {
      // Root selection is shared across VPS, Worker, Mobile and local
      // OpenList. It is non-sensitive user preference data, not a credential.
      await _repository.saveSharedRoots(
        booksRoot: books,
        comicsRoot: comics,
      );
      if (!mounted) return;
      setState(() {
        _booksRoot.text = books;
        _comicsRoot.text = comics;
        _currentPath = _selectedRoot;
        _savingRoots = false;
      });
      _showMessage('Books 與 Comics 根目錄已保存至雲端 D1，所有來源共用這兩個路徑。');
      await _loadDirectory();
      await _loadScanState();
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingRoots = false);
      _showMessage(error.toString());
    }
  }

  Future<void> _loginLocalOpenList() async {
    final url = _localUrl.text.trim();
    final username = _localUsername.text.trim();
    final password = _localPassword.text;
    if (url.isEmpty || username.isEmpty || password.isEmpty) {
      _showMessage('請輸入本地 OpenList 網址、帳號與密碼。');
      return;
    }
    setState(() => _loggingIn = true);
    LocalOpenListClient? candidate;
    try {
      candidate = LocalOpenListClient(baseUrl: url);
      await candidate.login(username: username, password: password);
      await _localSettings.saveBaseUrl(candidate.baseUrl);
      await _localSettings.saveLocalSelected(true);
      if (!mounted) {
        candidate.close();
        return;
      }
      _localClient?.close();
      _localClient = candidate;
      candidate = null;
      _localPassword.clear();
      if (!mounted) return;
      setState(() {
        _provider = FrameCloudProvider.local;
        _currentPath = _selectedRoot;
        _loggingIn = false;
      });
      await _loadDirectory();
      await _loadScanState();
      _showMessage('本地 OpenList 已登入。Token 僅保留在目前工作階段記憶體中。');
    } catch (error) {
      candidate?.close();
      if (!mounted) return;
      setState(() => _loggingIn = false);
      _showMessage(error.toString());
    }
  }

  Future<void> _testConnection() async {
    if (_testingConnection || _scanRunning || _archiveProcessing) return;
    final root = normalizeFrameCloudPath(_selectedRoot);
    if (root == null) {
      _showMessage('請先設定有效的根目錄，再測試連線。');
      return;
    }
    if (_provider == FrameCloudProvider.local &&
        !(_localClient?.isAuthenticated ?? false)) {
      _showMessage('本地 OpenList 尚未登入，請先登入再測試。');
      return;
    }
    if (_provider.isServerSide &&
        !(_session?.providers[_provider]?.configured ?? false)) {
      _showMessage('目前來源尚未在 Cloudflare Pages Variables／Secrets 設定完成。');
      return;
    }

    setState(() => _testingConnection = true);
    try {
      final total = _provider == FrameCloudProvider.local
          ? (await _localClient!.listDirectory(
              root,
              page: 1,
              perPage: 1,
            )).total
          : (await _repository.loadServerDirectoryPage(
              provider: _provider,
              library: _library,
              rootPath: root,
              path: root,
              page: 1,
              perPage: 1,
            )).total;
      if (!mounted) return;
      _showMessage(
        '連線成功：${_provider.label} · ${_library.label}，根目錄共 $total 個項目。',
      );
    } catch (error) {
      if (!mounted) return;
      _showMessage('來源連線測試失敗：$error');
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  void _setCurrentDirectoryAsRoot(FrameCloudLibrary library) {
    final root = normalizeFrameCloudPath(_selectedRoot);
    final current = normalizeFrameCloudPath(_currentPath);
    if (root == null ||
        current == null ||
        !frameCloudPathIsWithinRoot(current, root)) {
      _showMessage('目前目錄不在所選書庫根目錄內，無法直接套用。');
      return;
    }
    final controller =
        library == FrameCloudLibrary.books ? _booksRoot : _comicsRoot;
    controller.text = current;
    _tabs.animateTo(0);
    _showMessage(
      '已將目前目錄填入${library.label}根目錄欄位，請確認後按「儲存兩個根目錄」。',
    );
  }

  Future<void> _loadScanState() async {
    final root = normalizeFrameCloudPath(_selectedRoot);
    if (root == null) {
      if (mounted) {
        setState(() {
          _scanState = null;
          _scanMessage = '請先設定有效的書庫根目錄。';
        });
      }
      return;
    }
    try {
      final state = await _repository.loadScanState(
        provider: _provider,
        library: _library,
        rootPath: root,
      );
      if (!mounted) return;
      setState(() {
        _scanState = state;
        _libraryScanStates[_library] = state;
        _scanMessage = state == null
            ? '目前沒有 D1 掃描紀錄。'
            : state.completed
                ? '目錄索引已完成。重新掃描不會自動執行。'
                : state.pausedByUser
                    ? '找到手動暫停的進度，可從保存位置續掃。'
                    : '找到尚未完成的進度，可從保存位置續掃。';
      });
      await _refreshPendingCovers();
    } catch (error) {
      if (!mounted) return;
      setState(() => _scanMessage = '讀取 D1 掃描進度失敗：$error');
    }
  }

  Future<void> _refreshPendingCovers() async {
    final root = normalizeFrameCloudPath(_selectedRoot);
    if (root == null) return;
    try {
      final queue = await _repository.loadPendingCovers(
        provider: _provider,
        library: _library,
        rootPath: root,
        limit: 1,
      );
      if (mounted) setState(() => _pendingCovers = queue.total);
    } catch (_) {
      // Keep the last visible count if the queue endpoint is temporarily
      // unavailable; the scanner and reading bookshelf remain usable.
    }
  }

  Future<void> _processArchiveQueue({bool retryFailures = false}) async {
    if (_archiveProcessing || _scanRunning) return;
    final root = normalizeFrameCloudPath(_selectedRoot);
    if (root == null) {
      _showMessage('請先設定有效的書庫根目錄。');
      return;
    }
    if (_provider == FrameCloudProvider.local &&
        !(_localClient?.isAuthenticated ?? false)) {
      _showMessage('請先登入本地 OpenList。');
      return;
    }
    if (_provider.isServerSide &&
        !(_session?.providers[_provider]?.configured ?? false)) {
      _showMessage('目前來源尚未在 Cloudflare Pages 設定完成。');
      return;
    }

    final processor = FrameCloudArchiveProcessor(
      repository: _repository,
      localClient: _localClient,
    );
    setState(() {
      _archiveProcessing = true;
      _scanMessage = retryFailures
          ? '正在重設失敗封面並重新處理…'
          : '正在讀取待處理的封面與 EPUB OPF 元資料…';
    });
    try {
      if (retryFailures) {
        final retried = await processor.retryFailed(
          provider: _provider,
          library: _library,
          rootPath: root,
        );
        if (retried == 0) {
          if (mounted) {
            setState(() {
              _archiveProcessing = false;
              _scanMessage = '目前沒有可重試的失敗封面。';
            });
          }
          await _refreshPendingCovers();
          return;
        }
      }
      final result = await processor.processPendingBatch(
        provider: _provider,
        library: _library,
        rootPath: root,
        maxItems: 8,
        scanState: _scanState,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _scanMessage = progress.message;
            if (progress.state != null) _scanState = progress.state;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _archiveProcessing = false;
        _scanState = result.state ?? _scanState;
        _scanMessage = '本批完成：處理 ${result.processed} 本，封面上傳 ${result.uploaded} 本，'
            '無封面 ${result.missing} 本，失敗 ${result.failed} 本，'
            'EPUB 元資料更新 ${result.metadataProcessed} 本；待處理 ${result.pending} 本。';
      });
      await _loadScanState();
      await _refreshPendingCovers();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _archiveProcessing = false;
        _scanMessage = '封面／元資料處理失敗：$error';
      });
      _showMessage('封面／元資料處理失敗：$error');
      await _refreshPendingCovers();
    }
  }

  Future<void> _startScan({bool forceRescan = false}) async {
    if (_scanRunning || _archiveProcessing) return;
    if (_provider == FrameCloudProvider.local &&
        !(_localClient?.isAuthenticated ?? false)) {
      _showMessage('請先登入本地 OpenList。');
      return;
    }
    if (_provider.isServerSide &&
        !(_session?.providers[_provider]?.configured ?? false)) {
      _showMessage('目前來源尚未在 Cloudflare Pages 設定完成。');
      return;
    }
    final root = normalizeFrameCloudPath(_selectedRoot);
    if (root == null) {
      _showMessage('請先設定有效的書庫根目錄。');
      return;
    }
    if (forceRescan) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('重新建立完整索引？'),
          content: Text(
            '將重新遍歷「$root」，完成後依據新一輪結果清理 D1 中已不存在的項目。原始 EPUB／CBZ 不會下載或修改。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('開始完整重掃'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final runner = FrameCloudScanRunner(
      repository: _repository,
      localClient: _localClient,
    );
    _activeScanRunner = runner;
    setState(() {
      _scanRunning = true;
      _scanMessage = forceRescan ? '正在建立新一輪完整索引…' : '正在開始／續掃…';
    });
    final result = await runner.run(
      provider: _provider,
      library: _library,
      rootPath: root,
      forceRescan: forceRescan,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() {
          _scanState = progress.state;
          _libraryScanStates[_library] = progress.state;
          _scanMessage = progress.phase;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _scanRunning = false;
      _activeScanRunner = null;
      if (result.state != null) _scanState = result.state;
      _scanMessage = result.error ??
          (result.completed
              ? '目錄索引已完成。待處理封面與 EPUB metadata 可在完整管理器中繼續處理。'
              : result.paused
                  ? '已暫停，D1 掃描游標已保存。'
                  : '本批已結束，D1 掃描游標已保存，可再次續掃。');
    });
    await _loadScanState();
    if (result.error == null && !result.paused) {
      await _processArchiveQueue();
    }
    await _loadScanState();
    await _loadDirectory();
    if (result.error != null) _showMessage('索引掃描失敗：${result.error}');
  }

  Future<void> _startFullLibraryScan() async {
    if (_scanRunning || _archiveProcessing) return;
    if (_provider == FrameCloudProvider.local &&
        !(_localClient?.isAuthenticated ?? false)) {
      _showMessage('請先登入本地 OpenList。');
      return;
    }
    if (_provider.isServerSide &&
        !(_session?.providers[_provider]?.configured ?? false)) {
      _showMessage('目前來源尚未在 Cloudflare Pages 設定完成。');
      return;
    }

    final roots = <FrameCloudLibrary, String>{
      FrameCloudLibrary.books: _booksRoot.text.trim(),
      FrameCloudLibrary.comics: _comicsRoot.text.trim(),
    };
    for (final library in FrameCloudLibrary.values) {
      if (normalizeFrameCloudPath(roots[library] ?? '') == null) {
        _showMessage('${library.label}根目錄尚未設定為有效的絕對路徑。');
        return;
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('開始全庫掃描？'),
        content: Text(
          '將依序完整掃描 Books：${roots[FrameCloudLibrary.books]}，'
          '以及 Comics：${roots[FrameCloudLibrary.comics]}。'
          '每個分類都會逐頁保存 D1 游標；若中斷，可再次執行全庫掃描續接。'
          '已完成的索引只會在該分類完整掃描結束後清理失效項目。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('開始全庫掃描'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final runner = FrameCloudScanAllRunner(
      repository: _repository,
      localClient: _localClient,
    );
    _activeScanAllRunner = runner;
    setState(() {
      _scanRunning = true;
      _scanMessage = '正在依序掃描 Books 與 Comics…';
    });

    final result = await runner.run(
      provider: _provider,
      rootPaths: roots,
      onProgress: (library, progress) {
        if (!mounted) return;
        setState(() {
          _libraryScanStates[library] = progress.state;
          if (_library == library) _scanState = progress.state;
          _scanMessage = '${library.label} · ${progress.phase}';
        });
      },
    );

    if (!mounted) return;
    for (final libraryResult in result.libraries) {
      _libraryScanStates[libraryResult.library] = libraryResult.state;
    }
    final summary = result.libraries.map((item) {
      final status = item.skippedExisting
          ? '沿用已完成'
          : item.paused
              ? '已暫停'
              : item.completed
                  ? '完成'
                  : '未完成';
      return '${item.library.label}：$status，掃描 ${item.scannedCount}，'
          '索引 ${item.indexedCount}，略過 ${item.skippedCount}，'
          '移除過期索引 ${item.removedCount}';
    }).join('；');

    final finalMessage = result.error != null
        ? '全庫流程中止：${result.error}（$summary）'
        : result.paused
            ? '全庫掃描已暫停，可再次執行全庫掃描續接。（$summary）'
            : result.completed
                ? 'Books 與 Comics 全部掃描完成。（$summary）'
                : '全庫掃描尚未全部完成。（$summary）';
    setState(() {
      _scanRunning = false;
      _activeScanAllRunner = null;
      _scanState = _libraryScanStates[_library];
      _scanMessage = finalMessage;
    });

    await _loadScanState();
    await _loadDirectory();
    if (mounted) setState(() => _scanMessage = finalMessage);
    if (result.error != null) {
      _showMessage('全庫掃描中止：${result.error}');
    } else if (result.completed) {
      _showMessage('Books 與 Comics 全庫掃描已完成。');
    }
  }

  Future<void> _showScanLog() async {
    final state = _scanState;
    if (state == null) {
      _showMessage('目前沒有可檢視的掃描日誌。');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cloudBg,
      builder: (sheetContext) {
        final errors = state.errors.reversed.toList(growable: false);
        return SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.86,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '掃描日誌',
                          style: TextStyle(
                            color: _cloudInk,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        '${state.library.label} · ${state.provider.label}',
                        style: const TextStyle(
                          color: _cloudMuted,
                          fontSize: 11,
                        ),
                      ),
                      IconButton(
                        tooltip: '關閉',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: _cloudLine),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                    children: [
                      _scanLogInfo('狀態', state.completed
                          ? '已完成'
                          : state.pausedByUser
                              ? '手動暫停'
                              : '尚未完成'),
                      _scanLogInfo('根目錄', state.rootPath),
                      _scanLogInfo('掃描識別碼', state.scanId),
                      _scanLogInfo('開始時間', _formatScanTime(state.createdAt)),
                      _scanLogInfo('最近更新', _formatScanTime(state.updatedAt)),
                      _scanLogInfo('目前資料夾', state.currentFolder ?? '目前沒有進行中的資料夾'),
                      _scanLogInfo('下一頁', state.page.toString()),
                      _scanLogInfo('待處理資料夾', state.pendingFolders.length.toString()),
                      _scanLogInfo('已讀取項目', state.scannedCount.toString()),
                      _scanLogInfo('已寫入索引', state.indexedCount.toString()),
                      _scanLogInfo('略過項目', state.skippedCount.toString()),
                      _scanLogInfo('失敗累計', state.failedCount.toString()),
                      _scanLogInfo('封面已完成／缺失／失敗',
                          '${state.coverReadyCount}／${state.coverMissingCount}／${state.coverFailedCount}'),
                      _scanLogInfo('元資料成功／失敗',
                          '${state.metadataProcessedCount}／${state.metadataFailedCount}'),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '錯誤明細',
                              style: TextStyle(
                                color: _cloudInk,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${errors.length} 筆（最多保留最近 20 筆）',
                            style: const TextStyle(
                              color: _cloudMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (errors.isEmpty)
                        const Card(
                          color: _cloudPanel,
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              '目前沒有保存的錯誤明細。',
                              style: TextStyle(color: _cloudMuted),
                            ),
                          ),
                        ),
                      for (var index = 0; index < errors.length; index++)
                        Card(
                          color: _cloudPanel,
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '錯誤 ${errors.length - index}',
                                  style: const TextStyle(
                                    color: _cloudAccent,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SelectableText(
                                  errors[index]['path']?.toString() ?? state.rootPath,
                                  style: const TextStyle(
                                    color: _cloudInk,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                SelectableText(
                                  errors[index]['message']?.toString() ?? '未提供錯誤訊息',
                                  style: const TextStyle(
                                    color: _cloudMuted,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  _formatScanTime(errors[index]['at']?.toString()),
                                  style: const TextStyle(
                                    color: _cloudMuted,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      OutlinedButton.icon(
                        onPressed: errors.isEmpty ? null : () => _copyScanLog(state),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('複製日誌'),
                      ),
                      OutlinedButton.icon(
                        onPressed: errors.isEmpty || _scanRunning
                            ? null
                            : () {
                                Navigator.of(sheetContext).pop();
                                unawaited(_clearScanErrors());
                              },
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('清除錯誤明細'),
                      ),
                      FilledButton.icon(
                        onPressed: state.completed || _scanRunning
                            ? null
                            : () {
                                Navigator.of(sheetContext).pop();
                                unawaited(_startScan());
                              },
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('從保存位置續掃'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _copyScanLog(FrameCloudScanState state) async {
    final lines = <String>[
      'FRAME Ebook 掃描日誌',
      '分類：${state.library.label}',
      '來源：${state.provider.label}',
      '根目錄：${state.rootPath}',
      '掃描識別碼：${state.scanId}',
      '已讀取：${state.scannedCount}',
      '已索引：${state.indexedCount}',
      '略過：${state.skippedCount}',
      '失敗累計：${state.failedCount}',
      '',
      for (final error in state.errors.reversed) ...[
        '[${error['at'] ?? ''}]',
        '路徑：${error['path'] ?? state.rootPath}',
        '錯誤：${error['message'] ?? ''}',
        '',
      ],
    ];
    try {
      await Clipboard.setData(ClipboardData(text: lines.join('\n')));
      _showMessage('掃描日誌已複製。');
    } catch (error) {
      _showMessage('無法複製掃描日誌：$error');
    }
  }

  Future<void> _clearScanErrors() async {
    final state = _scanState;
    if (state == null || state.errors.isEmpty || _scanRunning) return;
    try {
      final cleared = state.copyWith(
        errors: const [],
        clearLastError: true,
        updatedAt: DateTime.now().toIso8601String(),
      );
      await _repository.saveScanState(cleared);
      if (!mounted) return;
      setState(() {
        _scanState = cleared;
        _libraryScanStates[_library] = cleared;
      });
      _showMessage('已清除錯誤明細；掃描游標、書目索引與累計統計均保留。');
    } catch (error) {
      _showMessage('清除錯誤明細失敗：$error');
    }
  }

  String _formatScanTime(String? value) {
    if (value == null || value.isEmpty) return '未記錄';
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Widget _scanLogInfo(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 116,
              child: Text(
                label,
                style: const TextStyle(color: _cloudMuted, fontSize: 11),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(color: _cloudInk, fontSize: 11),
              ),
            ),
          ],
        ),
      );

  void _pauseScan() {
    _activeScanRunner?.requestPause();
    _activeScanAllRunner?.requestPause();
    if (mounted && _scanRunning) {
      setState(() => _scanMessage = '已要求暫停，待目前目錄頁完成並保存游標…');
    }
  }

  void _logoutLocalOpenList() {
    _localClient?.logout();
    setState(() {
      _items = const [];
      _directoryError = null;
    });
    _showMessage('已登出本地 OpenList。');
  }

  void _openDirectory(FrameCloudEntry entry) {
    if (!entry.isDirectory) return;
    setState(() {
      _currentPath = entry.path;
      _query = '';
      _search.clear();
    });
    unawaited(_loadDirectory());
  }

  void _goToPath(String path) {
    final normalized = normalizeFrameCloudPath(path);
    final root = normalizeFrameCloudPath(_selectedRoot);
    if (normalized == null ||
        root == null ||
        !frameCloudPathIsWithinRoot(normalized, root)) {
      return;
    }
    setState(() {
      _currentPath = normalized;
      _query = '';
      _search.clear();
    });
    unawaited(_loadDirectory());
  }

  List<String> get _breadcrumbs {
    final root = normalizeFrameCloudPath(_selectedRoot) ?? '/';
    final current = normalizeFrameCloudPath(_currentPath) ?? root;
    if (current == root) return [root];
    final relative = current
        .substring(root == '/' ? 0 : root.length)
        .replaceFirst(RegExp(r'^/+'), '');
    final parts = relative.split('/').where((part) => part.isNotEmpty);
    final result = <String>[root];
    var path = root == '/' ? '' : root;
    for (final part in parts) {
      path = path.isEmpty ? '/$part' : '$path/$part';
      result.add(path);
    }
    return result;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return (bytes / 1024).round().toString() + ' KB';
    if (bytes >= 1024 * 1024 * 1024) {
      return (bytes / (1024 * 1024 * 1024)).toStringAsFixed(2) + ' GB';
    }
    return (bytes / (1024 * 1024)).toStringAsFixed(1) + ' MB';
  }

  List<FrameCloudEntry> get _visibleItems {
    final query = _query.trim().toLowerCase();
    final items = _items.where((item) {
      return query.isEmpty ||
          item.name.toLowerCase().contains(query) ||
          item.path.toLowerCase().contains(query);
    }).toList();
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _openLegacyManager() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => buildFrameLegacyPage(
          uri: FrameAppConfig.apiBaseUri.replace(
            path: '/cloud/',
            queryParameters: const {'manager': '1'},
          ),
          title: '完整連接與掃描',
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: _cloudBg,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: _cloudBg,
        appBar: AppBar(title: const Text('連接與書庫')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined,
                      size: 42, color: _cloudMuted),
                  const SizedBox(height: 16),
                  const Text('無法載入雲端連接設定',
                      style: TextStyle(color: _cloudInk, fontSize: 18)),
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: const TextStyle(color: _cloudMuted),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _scanRunning ? null : _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新載入'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: _cloudBg,
      appBar: AppBar(
        title: const Text('連接與書庫'),
        actions: [
          IconButton(
            tooltip: '重新整理',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.hub_outlined), text: '連接設定'),
            Tab(icon: Icon(Icons.folder_open_outlined), text: '書庫瀏覽'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildConnectionTab(),
          _buildLibraryTab(),
        ],
      ),
    );
  }

  Widget _buildConnectionTab() {
    final session = _session!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        _sectionTitle('資料來源', '選擇目前使用的網盤連接'),
        const SizedBox(height: 12),
        DropdownButtonFormField<FrameCloudProvider>(
          value: _provider,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '目前來源',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
          items: FrameCloudProvider.values
              .map((provider) => DropdownMenuItem(
                    value: provider,
                    child: Text(provider.label),
                  ))
              .toList(),
          onChanged: _selectProvider,
        ),
        const SizedBox(height: 12),
        ...FrameCloudProvider.values.map((provider) {
          final configured = provider == FrameCloudProvider.local
              ? (_localClient?.isAuthenticated ?? false)
              : (session.providers[provider]?.configured ?? false);
          final selected = provider == _provider;
          return Card(
            color: _cloudPanel,
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(
                provider == FrameCloudProvider.local
                    ? Icons.lan_outlined
                    : Icons.cloud_outlined,
                color: configured ? const Color(0xFF8AD7B0) : _cloudMuted,
              ),
              title:
                  Text(provider.label, style: const TextStyle(color: _cloudInk)),
              subtitle: Text(
                provider == FrameCloudProvider.local
                    ? '本機直接連線，登入 Token 不會寫入磁碟'
                    : (session.providers[provider]?.label ?? provider.label),
                style: const TextStyle(color: _cloudMuted, fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(configured ? '已就緒' : '未設定',
                      style: TextStyle(
                        color:
                            configured ? const Color(0xFF8AD7B0) : _cloudMuted,
                        fontSize: 12,
                      )),
                  if (selected)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.check_circle,
                          color: _cloudAccent, size: 18),
                    ),
                ],
              ),
              onTap: (_scanRunning || _archiveProcessing) ? null : () => _selectProvider(provider),
            ),
          );
        }),
        const SizedBox(height: 12),
        if (_provider == FrameCloudProvider.local)
          _buildLocalLoginPanel()
        else
          _statusPanel(
            title: '伺服器連接狀態',
            rows: [
              MapEntry('Cloudflare Access',
                  session.accessEnabled ? '已驗證' : '未驗證'),
              MapEntry('D1 資料庫',
                  session.databaseConfigured ? '已綁定' : '未綁定'),
              MapEntry('閱讀資料',
                  session.cloudReaderDataConfigured ? '已就緒' : '未就緒'),
              MapEntry('標註資料',
                  session.cloudAnnotationsConfigured ? '已就緒' : '未就緒'),
            ],
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _testingConnection || _scanRunning || _archiveProcessing
              ? null
              : _testConnection,
          icon: _testingConnection
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_tethering_outlined),
          label: const Text('測試目前來源連線'),
        ),
        const SizedBox(height: 18),
        _sectionTitle('書庫根目錄', 'Books 與 Comics 分開設定，所有來源共用這兩個路徑'),
        const SizedBox(height: 12),
        _rootField(
            controller: _booksRoot, label: 'Books 根目錄', hint: '/path/to/books'),
        const SizedBox(height: 10),
        _rootField(
            controller: _comicsRoot,
            label: 'Comics 根目錄',
            hint: '/path/to/comics'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _savingRoots || _scanRunning || _archiveProcessing ? null : _saveRoots,
          icon: _savingRoots
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: const Text('儲存兩個根目錄'),
        ),
        const SizedBox(height: 22),
        OutlinedButton.icon(
          onPressed: (_scanRunning || _archiveProcessing) ? null : _openLegacyManager,
          icon: const Icon(Icons.settings_suggest_outlined),
          label: const Text('開啟完整連接與掃描管理器'),
        ),
        const SizedBox(height: 8),
        const Text(
          'Flutter 原生介面已支援 Books／Comics 全庫掃描、續掃、封面佇列與掃描日誌；仍可開啟原版管理器使用完整連接診斷與其他進階操作。',
          style: TextStyle(color: _cloudMuted, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }

  Widget _buildLocalLoginPanel() {
    final authenticated = _localClient?.isAuthenticated ?? false;
    if (authenticated) {
      return _statusPanel(
        title: '本地 OpenList 已登入',
        rows: [
          MapEntry('服務網址', _localClient!.baseUrl),
          MapEntry('登入狀態', '有效，Token 僅存於記憶體'),
        ],
        trailing: TextButton(
          onPressed: _logoutLocalOpenList,
          child: const Text('登出'),
        ),
      );
    }
    return Card(
      color: _cloudPanel,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('本地 OpenList 登入',
                style: TextStyle(
                    color: _cloudInk, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              '只保存服務網址。帳號、密碼與登入 Token 不會保存；Token 僅在目前工作階段使用。',
              style: TextStyle(color: _cloudMuted, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _localUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'OpenList 網址',
                hintText: 'http://192.168.x.x:5244',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _localUsername,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: '帳號'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _localPassword,
              obscureText: true,
              onSubmitted: (_) => _loginLocalOpenList(),
              decoration: const InputDecoration(labelText: '密碼'),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _loggingIn ? null : _loginLocalOpenList,
              icon: _loggingIn
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: const Text('登入並測試連線'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLibraryTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<FrameCloudLibrary>(
                segments: const [
                  ButtonSegment(
                    value: FrameCloudLibrary.books,
                    icon: Icon(Icons.menu_book_outlined),
                    label: Text('Books'),
                  ),
                  ButtonSegment(
                    value: FrameCloudLibrary.comics,
                    icon: Icon(Icons.auto_stories_outlined),
                    label: Text('Comics'),
                  ),
                ],
                selected: {_library},
                onSelectionChanged: (_scanRunning || _archiveProcessing)
                    ? null
                    : (value) => _selectLibrary(value.first),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: '搜尋目前目錄',
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final crumb in _breadcrumbs)
                    ActionChip(
                      label: Text(
                        crumb == _selectedRoot
                            ? _library.label
                            : crumb.split('/').where((part) => part.isNotEmpty).last,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: () => _goToPath(crumb),
                    ),
                  IconButton(
                    tooltip: '重新載入目錄',
                    onPressed: (_loadingDirectory || _scanRunning || _archiveProcessing)
                        ? null
                        : () => _loadDirectory(page: _directoryPage),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              Text(
                _currentPath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _cloudMuted, fontSize: 11),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _scanRunning || _archiveProcessing
                          ? null
                          : () => _setCurrentDirectoryAsRoot(
                                FrameCloudLibrary.books,
                              ),
                      icon: const Icon(Icons.menu_book_outlined, size: 16),
                      label: const Text('設為 Books 根目錄'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _scanRunning || _archiveProcessing
                          ? null
                          : () => _setCurrentDirectoryAsRoot(
                                FrameCloudLibrary.comics,
                              ),
                      icon: const Icon(Icons.auto_stories_outlined, size: 16),
                      label: const Text('設為 Comics 根目錄'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: _cloudLine),
        Expanded(child: _buildDirectoryBody()),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Card(
                  color: _cloudPanel,
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.sync_alt, color: _cloudAccent, size: 18),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'D1 書庫索引',
                                style: TextStyle(
                                  color: _cloudInk,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              _scanState?.completed == true
                                  ? '已完成'
                                  : _scanState == null
                                      ? '尚未掃描'
                                      : '可續掃',
                              style: const TextStyle(
                                color: _cloudMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                        if (_scanRunning || _archiveProcessing) ...[
                          const SizedBox(height: 9),
                          const LinearProgressIndicator(minHeight: 2),
                        ],
                        const SizedBox(height: 6),
                        Text(
                          _scanMessage,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _cloudMuted,
                            fontSize: 11,
                          ),
                        ),
                        if (_scanState != null) ...[
                          const SizedBox(height: 7),
                          Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              _scanMetric('索引', _scanState!.indexedCount),
                              _scanMetric('已讀取', _scanState!.scannedCount),
                              _scanMetric('資料夾', _scanState!.visitedFolderCount),
                              _scanMetric('失敗', _scanState!.failedCount),
                              _scanMetric('封面待處理', _pendingCovers),
                              _scanMetric('封面已完成', _scanState!.coverReadyCount),
                              _scanMetric('封面失敗', _scanState!.coverFailedCount),
                              _scanMetric('元資料', _scanState!.metadataProcessedCount),
                            ],
                          ),
                        ],
                        const SizedBox(height: 9),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            FilledButton.icon(
                              onPressed: _scanRunning ? null : _startScan,
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: Text(
                                _scanState?.completed == true
                                    ? '索引已完成'
                                    : '開始／續掃',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _scanRunning || _archiveProcessing
                                  ? null
                                  : _startFullLibraryScan,
                              icon: const Icon(Icons.library_books_outlined, size: 18),
                              label: const Text('全庫掃描'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _scanState == null ? null : _showScanLog,
                              icon: const Icon(Icons.receipt_long_outlined, size: 18),
                              label: Text('掃描日誌 (${_scanState?.errors.length ?? 0})'),
                            ),
                            OutlinedButton.icon(
                              onPressed: (_scanRunning || _archiveProcessing || _pendingCovers == 0)
                                  ? null
                                  : () => _processArchiveQueue(),
                              icon: const Icon(Icons.image_outlined, size: 18),
                              label: const Text('封面／元資料'),
                            ),
                            OutlinedButton.icon(
                              onPressed: (_scanRunning || _archiveProcessing ||
                                      (_scanState?.coverFailedCount ?? 0) == 0)
                                  ? null
                                  : () => _processArchiveQueue(retryFailures: true),
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('重試失敗'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _scanRunning ? _pauseScan : null,
                              icon: const Icon(Icons.pause, size: 18),
                              label: const Text('暫停'),
                            ),
                            TextButton.icon(
                              onPressed: _scanRunning
                                  ? null
                                  : () => _startScan(forceRescan: true),
                              icon: const Icon(Icons.restart_alt, size: 18),
                              label: const Text('完整重掃'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '索引掃描會逐頁寫入 D1 並保存續掃游標。封面與 OPF 元資料透過 ZIP Range 讀取，縮圖上傳私有 R2；不會下載整本 EPUB／CBZ。',
                          style: TextStyle(
                            color: _cloudMuted,
                            fontSize: 10,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _totalItems.toString() + ' 個項目 · 第 ' +
                            _directoryPage.toString() + ' / ' + _pageCount.toString() + ' 頁',
                        style: const TextStyle(color: _cloudMuted, fontSize: 11),
                      ),
                    ),
                    IconButton(
                      tooltip: '上一頁',
                      visualDensity: VisualDensity.compact,
                      onPressed: _directoryPage > 1 && !_loadingDirectory
                          ? () => _loadDirectory(page: _directoryPage - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    IconButton(
                      tooltip: '下一頁',
                      visualDensity: VisualDensity.compact,
                      onPressed: _directoryPage < _pageCount && !_loadingDirectory
                          ? () => _loadDirectory(page: _directoryPage + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                    TextButton.icon(
                      onPressed: _scanRunning ? null : _openLegacyManager,
                      icon: const Icon(Icons.tune, size: 16),
                      label: const Text('完整管理器'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDirectoryBody() {
    if (_loadingDirectory) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_directoryError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_off_outlined,
                  size: 36, color: _cloudMuted),
              const SizedBox(height: 12),
              Text(_directoryError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _cloudMuted)),
              if (_provider == FrameCloudProvider.local &&
                  !(_localClient?.isAuthenticated ?? false)) ...[
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => _tabs.animateTo(0),
                  child: const Text('前往連接設定'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_provider == FrameCloudProvider.local &&
        !(_localClient?.isAuthenticated ?? false)) {
      return Center(
        child: FilledButton.icon(
          onPressed: () => _tabs.animateTo(0),
          icon: const Icon(Icons.login),
          label: const Text('先登入本地 OpenList'),
        ),
      );
    }
    final items = _visibleItems;
    if (items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined,
                size: 36, color: _cloudMuted),
            SizedBox(height: 12),
            Text('這個目錄目前沒有項目',
                style: TextStyle(color: _cloudMuted)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadDirectory,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        separatorBuilder: (_, __) =>
            const Divider(height: 1, color: _cloudLine, indent: 68),
        itemBuilder: (context, index) {
          final item = items[index];
          final directory = item.isDirectory;
          final supported = item.isSupportedBook;
          return ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _cloudRaised,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                directory
                    ? Icons.folder_outlined
                    : (item.format == 'EPUB'
                        ? Icons.menu_book_outlined
                        : (item.format == 'CBZ'
                            ? Icons.auto_stories_outlined
                            : Icons.insert_drive_file_outlined)),
                color: directory ? _cloudAccent : _cloudMuted,
              ),
            ),
            title: Text(item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: supported || directory ? _cloudInk : _cloudMuted,
                  fontSize: 14,
                )),
            subtitle: Text(
              directory
                  ? '資料夾'
                  : (item.format.isNotEmpty
                      ? item.format + ' · ' + _formatBytes(item.size)
                      : _formatBytes(item.size)),
              style: const TextStyle(color: _cloudMuted, fontSize: 11),
            ),
            trailing: directory
                ? const Icon(Icons.chevron_right, color: _cloudMuted)
                : null,
            onTap: directory ? () => _openDirectory(item) : null,
          );
        },
      ),
    );
  }

  Widget _scanMetric(String label, int value) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: _cloudMuted, fontSize: 10)),
          const SizedBox(width: 4),
          Text(
            value.toString(),
            style: const TextStyle(
              color: _cloudInk,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );

  Widget _sectionTitle(String title, String subtitle) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                color: _cloudInk,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(height: 3),
          Text(subtitle,
              style: const TextStyle(color: _cloudMuted, fontSize: 12)),
        ],
      );

  Widget _rootField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) =>
      TextField(
        controller: controller,
        autocorrect: false,
        enabled: !_scanRunning,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: const Icon(Icons.folder_outlined),
        ),
      );

  Widget _statusPanel({
    required String title,
    required List<MapEntry<String, String>> rows,
    Widget? trailing,
  }) =>
      Card(
        color: _cloudPanel,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            color: _cloudInk, fontWeight: FontWeight.w600)),
                  ),
                  if (trailing != null) trailing,
                ],
              ),
              const SizedBox(height: 8),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(row.key,
                            style: const TextStyle(
                                color: _cloudMuted, fontSize: 12)),
                      ),
                      Flexible(
                        child: Text(row.value,
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                                color: _cloudInk, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
}
