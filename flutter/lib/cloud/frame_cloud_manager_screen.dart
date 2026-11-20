import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/frame_api_scope.dart';
import '../core/frame_app_config.dart';
import '../legacy/frame_legacy_page.dart';
import 'frame_cloud_models.dart';
import 'frame_cloud_repository.dart';
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
  FrameCloudScanState? _scanState;
  FrameCloudScanRunner? _activeScanRunner;
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
      ]);
      final session = results[0] as FrameCloudSession;
      final preferences = results[1] as FrameCloudPreferences;
      final savedLocalUrl = results[2] as String?;
      if (!mounted) return;
      setState(() {
        _session = session;
        _provider = preferences.activeProvider;
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
    if (value == null || value == _provider) return;
    setState(() {
      _provider = value;
      _currentPath = _selectedRoot;
    });
    try {
      await _repository.saveActiveProvider(value);
    } catch (error) {
      _showMessage(error.toString());
    }
    if (!mounted) return;
    await _loadDirectory();
    await _loadScanState();
  }

  Future<void> _selectLibrary(FrameCloudLibrary value) async {
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
      if (_provider.isServerSide) {
        await _repository.saveSharedRoots(
          booksRoot: books,
          comicsRoot: comics,
        );
      }
      if (!mounted) return;
      setState(() {
        _booksRoot.text = books;
        _comicsRoot.text = comics;
        _currentPath = _selectedRoot;
        _savingRoots = false;
      });
      _showMessage(_provider.isServerSide
          ? 'Books 與 Comics 根目錄已儲存至雲端偏好設定。'
          : '本次工作階段已套用根目錄。');
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
        _scanMessage = state == null
            ? '目前沒有 D1 掃描紀錄。'
            : state.completed
                ? '目錄索引已完成。重新掃描不會自動執行。'
                : state.pausedByUser
                    ? '找到手動暫停的進度，可從保存位置續掃。'
                    : '找到尚未完成的進度，可從保存位置續掃。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _scanMessage = '讀取 D1 掃描進度失敗：$error');
    }
  }

  Future<void> _startScan({bool forceRescan = false}) async {
    if (_scanRunning) return;
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
    await _loadDirectory();
    if (result.error != null) _showMessage('索引掃描失敗：${result.error}');
  }

  void _pauseScan() {
    _activeScanRunner?.requestPause();
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
                    onPressed: _load,
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
              onTap: () => _selectProvider(provider),
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
        const SizedBox(height: 18),
        _sectionTitle('書庫根目錄', 'Books 與 Comics 分開設定，兩個路徑互不取代'),
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
          onPressed: _savingRoots ? null : _saveRoots,
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
          onPressed: _openLegacyManager,
          icon: const Icon(Icons.settings_suggest_outlined),
          label: const Text('開啟完整連接與掃描管理器'),
        ),
        const SizedBox(height: 8),
        const Text(
          '完整掃描、續傳檢查點、封面重試與掃描日誌目前仍由原版管理器執行；Flutter 原生介面正逐步接手。',
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
                onSelectionChanged: (value) => _selectLibrary(value.first),
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
                    onPressed: _loadingDirectory
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
            ],
          ),
        ),
        const Divider(height: 1, color: _cloudLine),
        Expanded(child: _buildDirectoryBody()),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _totalItems.toString() + ' 個項目 · 第 ' +
                        _directoryPage.toString() + ' / ' + _pageCount.toString() + ' 頁',
                    style: const TextStyle(color: _cloudMuted, fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: '上一頁',
                  onPressed: _directoryPage > 1 && !_loadingDirectory
                      ? () => _loadDirectory(page: _directoryPage - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: '下一頁',
                  onPressed: _directoryPage < _pageCount && !_loadingDirectory
                      ? () => _loadDirectory(page: _directoryPage + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
                TextButton.icon(
                  onPressed: _openLegacyManager,
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('掃描與封面管理'),
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
