import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../core/frame_api_client.dart';
import '../core/frame_api_scope.dart';
import '../core/frame_app_config.dart';
import '../legacy/frame_legacy_page.dart';
import 'frame_book.dart';
import '../cloud/frame_cloud_manager_screen.dart';
import 'frame_book_details_dialog.dart';
import '../stats/frame_reading_stats_screen.dart';
import 'frame_library_repository.dart';

const _bg = Color(0xFF12101A);
const _panel = Color(0xFF1B1825);
const _panelSoft = Color(0xFF211C2B);
const _text = Color(0xFFF4F0FA);
const _muted = Color(0xFFAAA2B8);
const _faint = Color(0xFF797184);
const _line = Color(0xFF393247);
const _accent = Color(0xFFC5ADFF);
const _accentStrong = Color(0xFF9875EC);

class FrameBookshelfScreen extends StatefulWidget {
  const FrameBookshelfScreen({super.key});

  @override
  State<FrameBookshelfScreen> createState() => _FrameBookshelfScreenState();
}

class _FrameBookshelfScreenState extends State<FrameBookshelfScreen>
    with WidgetsBindingObserver {
  FrameLibraryRepository? _repository;
  FrameApiClient? _api;
  List<FrameBook> _books = <FrameBook>[];
  final Map<String, Future<Uint8List>> _coverRequests =
      <String, Future<Uint8List>>{};
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String _sort = 'recent';
  String _view = 'grid';
  String? _activeFolderKey;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  bool _apiReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_apiReady) {
      _apiReady = true;
      _api = FrameApiScope.of(context);
      _repository = FrameLibraryRepository(_api!);
      unawaited(_refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _apiReady) {
      unawaited(_refresh(silent: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _coverRequests.clear();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    final repository = _repository;
    if (repository == null) return;
    if (mounted) {
      setState(() {
        if (!silent) _loading = true;
        _refreshing = true;
        _error = null;
      });
    }
    try {
      final books = await repository.loadBookshelf();
      if (!mounted) return;
      setState(() {
        _books = books;
        _loading = false;
        _refreshing = false;
        _error = null;
        if (_activeFolderKey != null &&
            !groupFrameBooks(_books).any((entry) => entry.key == _activeFolderKey)) {
          _activeFolderKey = null;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = error.toString();
      });
    }
  }

  List<FrameShelfEntry> get _shelves => groupFrameBooks(_books);

  List<FrameShelfEntry> get _filteredEntries {
    final query = _query.trim().toLowerCase();
    final result = _shelves.where((entry) {
      if (query.isEmpty) return true;
      return entry.searchText.join(' ').toLowerCase().contains(query);
    }).toList();
    switch (_sort) {
      case 'title':
        result.sort((a, b) => a.title.compareTo(b.title));
        break;
      case 'added':
        result.sort((a, b) => b.first.addedAt.compareTo(a.first.addedAt));
        break;
      case 'progress':
        result.sort((a, b) => b.progressPercent.compareTo(a.progressPercent));
        break;
      default:
        result.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
        break;
    }
    return result;
  }

  List<FrameShelfEntry> get _recentEntries {
    final result = _shelves.where((entry) => entry.lastOpenedAt > 0).toList()
      ..sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
    return result.take(3).toList();
  }

  FrameShelfEntry? get _activeFolder {
    final key = _activeFolderKey;
    if (key == null) return null;
    for (final entry in _shelves) {
      if (entry.key == key && entry.isFolder) return entry;
    }
    return null;
  }

  Future<Uint8List> _coverFuture(String hash) {
    if (_coverRequests.containsKey(hash)) return _coverRequests[hash]!;
    // Keep thumbnail responses RAM-only and bound the number of retained
    // cover futures so a large library cannot grow this cache indefinitely.
    if (_coverRequests.length >= 20) {
      _coverRequests.remove(_coverRequests.keys.first);
    }
    return _coverRequests.putIfAbsent(
      hash,
      () => _repository!.loadCover(hash),
    );
  }

  void _openStats() {
    final api = _api;
    if (api == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FrameReadingStatsScreen(api: api),
      ),
    );
  }

  void _openCloudManager() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const FrameCloudManagerScreen(),
      ),
    );
  }

  Uri _legacyUri(String path, [Map<String, String> query = const {}]) {
    return FrameAppConfig.apiBaseUri.replace(
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  void _openLegacy(String path, String title, [Map<String, String> query = const {}]) {
    final uri = _legacyUri(path, query);
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => buildFrameLegacyPage(uri: uri, title: title),
        ),
      ),
    );
  }

  void _openReader(FrameBook book) {
    _openLegacy(
      '/epub-lab/',
      book.title.isNotEmpty ? book.title : book.fileName,
      {
        'book': book.id,
        'provider': book.provider,
        'library': book.library,
        'root_path': book.rootPath,
        'path': book.path,
      },
    );
  }

  void _openFolder(FrameShelfEntry entry) {
    setState(() => _activeFolderKey = entry.key);
  }

  void _leaveFolder() {
    setState(() => _activeFolderKey = null);
  }

  Future<void> _showBookDetails(FrameBook book) async {
    final action = await showDialog<String>(
      context: context,
      builder: (_) => FrameBookDetailsDialog(book: book, books: _books),
    );
    if (!mounted || action == null) return;
    await _refresh(silent: true);
    if (!mounted) return;

    switch (action) {
      case 'saved':
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('作品資訊已保存至雲端。')),
        );
        break;
      case 'reset':
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已恢復 EPUB 內部書名與作者。')),
        );
        break;
      case 'linked':
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('舊書籍閱讀資料已完成關聯。')),
        );
        final updated = _books.where((item) => item.id == book.id);
        if (updated.isNotEmpty) await _showBookDetails(updated.first);
        break;
      case 'bangumi':
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bangumi 資料已套用至同資料夾卷冊。')),
        );
        final updated = _books.where((item) => item.id == book.id);
        if (updated.isNotEmpty) await _showBookDetails(updated.first);
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final folder = _activeFolder;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: RefreshIndicator(
          color: _accent,
          backgroundColor: _panel,
          onRefresh: () => _refresh(silent: true),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final narrow = width < 760;
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1180),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: width < 520 ? 18 : 30,
                        vertical: 14,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _topBar(narrow),
                          if (folder == null) ...[
                            const SizedBox(height: 22),
                            _hero(narrow),
                            const SizedBox(height: 22),
                            _stats(),
                            if (_recentEntries.isNotEmpty) ...[
                              const SizedBox(height: 34),
                              _recentSection(width),
                            ],
                            const SizedBox(height: 36),
                            _librarySection(width),
                            const SizedBox(height: 24),
                            _privacyNote(),
                            const SizedBox(height: 22),
                            _bottomBanner(narrow),
                          ] else ...[
                            const SizedBox(height: 26),
                            _folderDetail(folder, width),
                          ],
                          const SizedBox(height: 26),
                          _footer(),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topBar(bool narrow) {
    return Container(
      padding: const EdgeInsets.only(bottom: 15),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x33205AD0), width: 0)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 14,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFA485EF), Color(0xFF61469F)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: const Color(0x59D8C7FF)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x4D7A53CA),
                      blurRadius: 24,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: const Text(
                  'F',
                  style: TextStyle(
                    color: Colors.white,
                    fontFamily: 'NotoSansTC',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'FRAME  READER',
                    style: TextStyle(
                      color: _accent,
                      fontSize: 12,
                      letterSpacing: 2.1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'CLOUD LIBRARY',
                    style: TextStyle(
                      color: _faint,
                      fontSize: 8,
                      letterSpacing: 2.3,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Wrap(
            spacing: 18,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _navText('我的書架', true, () => _leaveFolder()),
              _navText('閱讀時光', false, () => _openStats()),
              _navText('閱讀室', false, () => _openLegacy('/epub-lab/', '閱讀室')),
              OutlinedButton(
                onPressed: () => _openCloudManager(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: const BorderSide(color: Color(0x668F7BB7)),
                  backgroundColor: const Color(0x332F2444),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                child: const Text('連接與掃描'),
              ),
            ],
          ),
          if (!narrow)
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 6, color: _accent),
                SizedBox(width: 8),
                Text(
                  'PRIVATE LIBRARY · 0.7',
                  style: TextStyle(
                    color: _faint,
                    fontSize: 9,
                    letterSpacing: 1.4,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _navText(String label, bool selected, VoidCallback onTap) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: selected ? _text : _muted,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
        textStyle: const TextStyle(fontSize: 12),
      ),
      child: Text(label),
    );
  }

  Widget _hero(bool narrow) {
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            SizedBox(width: 24, child: Divider(color: _accentStrong)),
            SizedBox(width: 11),
            Text(
              'YOUR PRIVATE READING ROOM',
              style: TextStyle(
                color: Color(0xFFB7A0ED),
                fontSize: 9,
                letterSpacing: 2.6,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: '把喜歡的書，\n'),
              TextSpan(
                text: '安放在自己的書架。',
                style: const TextStyle(color: Color(0xFFC1A9FA)),
              ),
            ],
          ),
          style: TextStyle(
            color: const Color(0xFFF5F1FB),
            fontSize: narrow ? 38 : 48,
            height: 1.26,
            fontWeight: FontWeight.w600,
            letterSpacing: -1.8,
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          '只從 Alist／OpenList 掃描索引導入書籍。書檔留在你的雲端儲存，書架、閱讀進度、外觀偏好、書籤與筆記均透過 Cloudflare D1／R2 保存，跨裝置自動同步。',
          style: TextStyle(color: _muted, fontSize: 13, height: 1.9),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 22,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: () => _openCloudManager(),
              icon: const Icon(Icons.add_link_rounded, size: 17),
              label: const Text('連接與掃描'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF7253B6),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
              ),
            ),
            TextButton.icon(
              onPressed: () => _openLegacy('/epub-lab/', '閱讀室'),
              icon: const Icon(Icons.menu_book_rounded, size: 17),
              label: const Text('前往閱讀室'),
              style: TextButton.styleFrom(foregroundColor: _muted),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Wrap(
          spacing: 11,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('ALIST · OPENLIST', style: _tinyLabel),
            Icon(Icons.circle, color: _faint, size: 3),
            Text('BOOKS · EPUB', style: _tinyLabel),
            Icon(Icons.circle, color: _faint, size: 3),
            Text('COMICS · CBZ', style: _tinyLabel),
          ],
        ),
      ],
    );
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [copy, const SizedBox(height: 26), _heroArtwork()],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(flex: 11, child: Padding(padding: const EdgeInsets.only(left: 22), child: copy)),
        const SizedBox(width: 30),
        const Expanded(flex: 9, child: _HeroArtwork()),
      ],
    );
  }

  Widget _heroArtwork() => const _HeroArtwork();

  Widget _stats() {
    final shelves = _shelves;
    final started = shelves.where((entry) => entry.progressPercent > 0).length;
    final books = shelves.where((entry) => !entry.isComic).length;
    final comics = shelves.where((entry) => entry.isComic).length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth = (constraints.maxWidth - 30) / 4;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _StatTile(label: 'BOOKS IN LIBRARY', value: shelves.length, caption: '已收藏書籍', width: cellWidth),
            _StatTile(label: 'IN PROGRESS', value: started, caption: '正在閱讀', width: cellWidth),
            _StatTile(label: 'EPUB', value: books, caption: '文字與固定版面', width: cellWidth),
            _StatTile(label: 'COMICS', value: comics, caption: 'CBZ 圖像封存', width: cellWidth),
          ],
        );
      },
    );
  }

  Widget _recentSection(double width) {
    final recent = _recentEntries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeading(
          kicker: 'PICK UP WHERE YOU LEFT OFF',
          title: '最近閱讀',
          subtitle: '從上次停下的地方接著讀',
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 340,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: recent.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, index) => SizedBox(
              width: width < 560 ? 220 : 245,
              child: _bookCard(recent[index], compact: true),
            ),
          ),
        ),
      ],
    );
  }

  Widget _librarySection(double width) {
    final all = _shelves;
    final visible = _filteredEntries;
    final books = all.where((entry) => !entry.isComic).toList();
    final comics = all.where((entry) => entry.isComic).toList();
    final visibleBooks = visible.where((entry) => !entry.isComic).toList();
    final visibleComics = visible.where((entry) => entry.isComic).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: _sectionHeading(
                kicker: 'YOUR PERSONAL COLLECTION',
                title: '兩種收藏，各自成架',
                subtitle: '掃描完成自動入架；書架與個人閱讀資料均保存在雲端。',
              ),
            ),
            if (width > 560)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${all.length.toString().padLeft(2, '0')} ITEMS',
                    style: const TextStyle(
                      color: Color(0xFFD3C2F5),
                      fontFamily: 'NotoSansTC',
                      fontSize: 24,
                    ),
                  ),
                  const Text('IN YOUR LIBRARY', style: _tinyLabel),
                ],
              ),
          ],
        ),
        const SizedBox(height: 20),
        _toolbar(),
        const SizedBox(height: 24),
        _categorySection(
          title: '電子書',
          kicker: 'READING EDITION · EPUB',
          description: '小說、散文、非虛構與各類文字作品',
          count: books.length,
          entries: visibleBooks,
          allCount: books.length,
          emptyTitle: '電子書架尚未收藏作品',
          emptyText: '先從「連接與掃描」選擇 Alist／OpenList，設定電子書目錄並執行掃描。',
          width: width,
        ),
        const SizedBox(height: 30),
        _categorySection(
          title: '漫畫',
          kicker: 'ILLUSTRATED EDITION · EPUB / CBZ',
          description: '固定版面 EPUB、漫畫與圖像小說',
          count: comics.length,
          entries: visibleComics,
          allCount: comics.length,
          emptyTitle: '漫畫書架尚未收藏作品',
          emptyText: '從「連接與掃描」設定漫畫目錄，掃描 EPUB／CBZ 後便會自動加入書架。',
          width: width,
          comics: true,
        ),
        const SizedBox(height: 16),
        Text(
          '目前顯示 ${visibleBooks.length} 本電子書 · ${visibleComics.length} 部漫畫',
          style: const TextStyle(color: _faint, fontSize: 10),
        ),
        const SizedBox(height: 10),
        _statusLine(),
      ],
    );
  }

  Widget _toolbar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final search = SizedBox(
          width: constraints.maxWidth > 600 ? 430 : constraints.maxWidth,
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            style: const TextStyle(color: _text, fontSize: 12),
            decoration: InputDecoration(
              hintText: '搜尋書名、作者或檔案名稱',
              prefixIcon: const Icon(Icons.search, color: Color(0xFFA996C8)),
              filled: true,
              fillColor: _panelSoft,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: Color(0x33205AD0)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: _accentStrong),
              ),
            ),
          ),
        );
        final actions = Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
              value: _sort,
              dropdownColor: _panel,
              underline: const SizedBox.shrink(),
              style: const TextStyle(color: _muted, fontSize: 11),
              items: const [
                DropdownMenuItem(value: 'recent', child: Text('最近閱讀')),
                DropdownMenuItem(value: 'added', child: Text('最近加入')),
                DropdownMenuItem(value: 'title', child: Text('書名 A-Z')),
                DropdownMenuItem(value: 'progress', child: Text('閱讀進度')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _sort = value);
              },
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'grid', icon: Icon(Icons.grid_view_rounded)),
                ButtonSegment(value: 'list', icon: Icon(Icons.view_list_rounded)),
              ],
              selected: {_view},
              onSelectionChanged: (value) => setState(() => _view = value.first),
              style: ButtonStyle(
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected) ? _text : _muted,
                ),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected) ? const Color(0xFF413451) : _panel,
                ),
                side: WidgetStateProperty.all(const BorderSide(color: _line)),
              ),
            ),
          ],
        );
        if (constraints.maxWidth > 780) {
          return Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: 18),
              actions,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [search, const SizedBox(height: 12), Align(alignment: Alignment.centerRight, child: actions)],
        );
      },
    );
  }

  Widget _categorySection({
    required String title,
    required String kicker,
    required String description,
    required int count,
    required int allCount,
    required List<FrameShelfEntry> entries,
    required String emptyTitle,
    required String emptyText,
    required double width,
    bool comics = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kicker, style: _tinyLabel),
                  const SizedBox(height: 7),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xFFEDE7F5),
                      fontSize: 21,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(description, style: const TextStyle(color: _faint, fontSize: 10)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  count.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    color: Color(0xFFD3C2F5),
                    fontFamily: 'NotoSansTC',
                    fontSize: 23,
                  ),
                ),
                Text(comics ? 'COMICS' : 'BOOKS', style: _tinyLabel),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (allCount == 0)
          _emptyShelf(title: emptyTitle, detail: emptyText, comic: comics)
        else if (entries.isEmpty)
          _searchEmpty(title)
        else if (_view == 'list')
          Column(
            children: entries
                .map((entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _bookCard(entry, listMode: true),
                    ))
                .toList(),
          )
        else
          _bookGrid(entries, width),
      ],
    );
  }

  Widget _bookGrid(
    List<FrameShelfEntry> entries,
    double width, {
    bool forceVolume = false,
  }) {
    final columns = width >= 1050 ? 4 : width >= 760 ? 3 : width >= 520 ? 2 : 2;
    return GridView.builder(
      itemCount: entries.length,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 16,
        mainAxisSpacing: 18,
        childAspectRatio: 0.59,
      ),
      itemBuilder: (context, index) =>
          _bookCard(entries[index], forceVolume: forceVolume),
    );
  }

  Widget _bookCard(
    FrameShelfEntry entry, {
    bool compact = false,
    bool listMode = false,
    bool forceVolume = false,
  }) {
    final folder = entry.isFolder && !forceVolume;
    final book = entry.first;
    final heading = forceVolume ? _volumeTitle(book) : entry.title;
    final subtitle = book.author.isNotEmpty
        ? book.author
        : (entry.isComic ? '漫畫／圖像書' : '作者未提供');
    final percent = entry.progressPercent;
    return Material(
      color: _panel,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: () {
          if (folder) {
            _openFolder(entry);
          } else {
            _openReader(book);
          }
        },
        child: Container(
          padding: EdgeInsets.all(listMode ? 12 : 10),
          decoration: BoxDecoration(
            border: Border.all(color: _line.withValues(alpha: 0.55)),
            borderRadius: BorderRadius.circular(11),
          ),
          child: listMode
              ? Row(
                  children: [
                    SizedBox(width: 62, height: 84, child: _cover(entry, compact: true, forceVolume: forceVolume)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(heading, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _text, fontWeight: FontWeight.w600, fontSize: 13)),
                          const SizedBox(height: 5),
                          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _muted, fontSize: 10)),
                          const SizedBox(height: 8),
                          _progressLine(entry, folder),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '作品資訊',
                      onPressed: folder ? () => _openFolder(entry) : () => _showBookDetails(book),
                      icon: const Icon(Icons.more_horiz, color: _muted),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _cover(entry, compact: compact, forceVolume: forceVolume),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      heading,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _text, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 10),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Expanded(child: Text(folder ? '${entry.volumeCount} 冊' : entry.format,
                            style: const TextStyle(color: Color(0xFFC5B2E8), fontSize: 9))),
                        if (!folder && percent > 0)
                          Text('$percent%', style: const TextStyle(color: _accent, fontSize: 9)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _progressLine(entry, folder),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            folder ? '開啟資料夾 ↗' : (percent > 0 ? '繼續閱讀 ↗' : '開始閱讀 ↗'),
                            style: const TextStyle(color: _accent, fontSize: 9, fontWeight: FontWeight.w600),
                          ),
                        ),
                        InkWell(
                          onTap: () => folder ? _openFolder(entry) : _showBookDetails(book),
                          child: const Padding(
                            padding: EdgeInsets.all(3),
                            child: Icon(Icons.more_horiz, color: _muted, size: 18),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _cover(
    FrameShelfEntry entry, {
    bool compact = false,
    bool forceVolume = false,
  }) {
    if (entry.isFolder && !forceVolume) {
      final members = entry.sortedMembers().take(3).toList();
      if (members.length > 1) {
        final visual = members.length == 3
            ? [members[1], members[0], members[2]]
            : [members[1], members[0]];
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LayoutBuilder(
            builder: (context, box) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: box.maxWidth * 0.12,
                    top: box.maxHeight * 0.09,
                    bottom: box.maxHeight * 0.04,
                    width: box.maxWidth * 0.62,
                    child: Transform.rotate(
                      angle: -0.12,
                      child: _coverFace(visual[0], compact: compact),
                    ),
                  ),
                  Positioned(
                    right: box.maxWidth * 0.12,
                    top: box.maxHeight * 0.09,
                    bottom: box.maxHeight * 0.04,
                    width: box.maxWidth * 0.62,
                    child: Transform.rotate(
                      angle: 0.12,
                      child: _coverFace(visual[visual.length - 1], compact: compact),
                    ),
                  ),
                  if (members.length == 3)
                    Positioned(
                      left: box.maxWidth * 0.25,
                      right: box.maxWidth * 0.25,
                      top: box.maxHeight * 0.02,
                      bottom: box.maxHeight * 0.01,
                      child: _coverFace(members[0], compact: compact),
                    ),
                ],
              );
            },
          ),
        );
      }
      return _coverFace(members.first, compact: compact);
    }
    return _coverFace(entry.first, compact: compact, showFormat: true);
  }

  Widget _coverFace(
    FrameBook book, {
    bool compact = false,
    bool showFormat = false,
  }) {
    final hash = book.coverStatus == 'ready' &&
            RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(book.coverHash)
        ? book.coverHash
        : '';
    final fallback = Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF46375F), Color(0xFF221C31), Color(0xFF171420)],
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('FRAME READER',
              style: TextStyle(color: Color(0xFFC7B4EA), fontSize: 7, letterSpacing: 1.5)),
          const Spacer(),
          Text(
            book.title.isNotEmpty ? book.title : book.fileName,
            maxLines: compact ? 2 : 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: const Color(0xFFECE4F8),
              fontSize: compact ? 10 : 12,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            book.isComic ? 'COMIC EDITION' : 'READING EDITION',
            style: const TextStyle(color: Color(0xFF9684B5), fontSize: 6, letterSpacing: 1.0),
          ),
        ],
      ),
    );
    Widget image;
    if (hash.isEmpty || _repository == null) {
      image = fallback;
    } else {
      image = FutureBuilder<Uint8List>(
        future: _coverFuture(hash),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true);
          }
          return fallback;
        },
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(borderRadius: BorderRadius.circular(5), child: image),
        if (showFormat)
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xCC171420),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(book.format,
                  style: const TextStyle(color: _accent, fontSize: 8, letterSpacing: 0.7)),
            ),
          ),
      ],
    );
  }

  Widget _progressLine(FrameShelfEntry entry, bool folder) {
    final percent = folder ? 0 : entry.progressPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: LinearProgressIndicator(
            minHeight: 3,
            value: percent / 100,
            backgroundColor: const Color(0xFF383044),
            color: _accentStrong,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          folder
              ? '${entry.volumeCount} 本作品，點擊查看資料夾'
              : percent > 0
                  ? '$percent% · ${entry.progressLabel}'
                  : '尚未開始',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _faint, fontSize: 8),
        ),
      ],
    );
  }

  Widget _folderDetail(FrameShelfEntry folder, double width) {
    final volumes = folder.sortedMembers();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            TextButton.icon(
              onPressed: _leaveFolder,
              icon: const Icon(Icons.arrow_back, size: 17),
              label: const Text('返回我的書架'),
              style: TextButton.styleFrom(foregroundColor: _accent),
            ),
            const Spacer(),
            Text('${volumes.length} 冊 · ${_formatBytes(folder.totalSize)}',
                style: const TextStyle(color: _muted, fontSize: 10)),
          ],
        ),
        const SizedBox(height: 24),
        const Text('YOUR FOLDER · BOOK COLLECTION',
            style: TextStyle(color: Color(0xFF8F7BB7), fontSize: 9, letterSpacing: 2.2)),
        const SizedBox(height: 10),
        Text(folder.title,
            style: const TextStyle(color: _text, fontSize: 31, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(folder.folderPath, style: const TextStyle(color: _faint, fontSize: 10)),
        const SizedBox(height: 8),
        Text(
          '這個資料夾共有 ${volumes.length} 個可閱讀檔案。選擇下方任一本作品即可進入閱讀室。',
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
        const SizedBox(height: 24),
        if (_view == 'list')
          Column(
            children: volumes
                .map((book) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _bookCard(FrameShelfEntry(book), listMode: true, forceVolume: true),
                    ))
                .toList(),
          )
        else
          _bookGrid(
            volumes.map(FrameShelfEntry.new).toList(),
            width,
            forceVolume: true,
          ),
      ],
    );
  }

  String _volumeTitle(FrameBook book) {
    final raw = book.fileName.replaceFirst(RegExp(r'\.(epub|cbz)$', caseSensitive: false), '');
    return raw.isEmpty ? book.title : raw;
  }

  Widget _sectionHeading({
    required String kicker,
    required String title,
    String? subtitle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(kicker,
            style: const TextStyle(color: Color(0xFF8F7BB7), fontSize: 8, letterSpacing: 2.3)),
        const SizedBox(height: 8),
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFFF1EDF8),
            fontSize: 24,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 5),
          Text(subtitle, style: const TextStyle(color: Color(0xFF8D859A), fontSize: 10)),
        ],
      ],
    );
  }

  Widget _emptyShelf({
    required String title,
    required String detail,
    bool comic = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 35, horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0x331B1825),
        border: Border.all(color: _line.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        children: [
          Icon(comic ? Icons.auto_stories_outlined : Icons.menu_book_outlined,
              color: const Color(0xFFBBA5E8), size: 27),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(color: Color(0xFFDCD3E8), fontSize: 12)),
          const SizedBox(height: 6),
          Text(detail, textAlign: TextAlign.center,
              style: const TextStyle(color: _faint, fontSize: 9, height: 1.6)),
        ],
      ),
    );
  }

  Widget _searchEmpty(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Text('沒有符合條件的$title。',
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 11)),
    );
  }

  Widget _statusLine() {
    String message;
    Color color;
    if (_loading) {
      message = '正在讀取雲端書架索引……';
      color = _muted;
    } else if (_error != null) {
      message = '雲端書架載入失敗：$_error';
      color = const Color(0xFFFFA5A5);
    } else {
      final books = _shelves.where((entry) => !entry.isComic).length;
      final comics = _shelves.where((entry) => entry.isComic).length;
      message = '雲端書架已載入：電子書 $books 本、漫畫 $comics 部。書目及閱讀記憶由 D1 同步保存。';
      color = const Color(0xFF9E95AE);
    }
    return Row(
      children: [
        if (_refreshing)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: _accent),
            ),
          ),
        Expanded(child: Text(message, style: TextStyle(color: color, fontSize: 9, height: 1.5))),
        IconButton(
          tooltip: '重新整理書架',
          onPressed: _refreshing ? null : () => _refresh(),
          icon: const Icon(Icons.refresh, color: _faint, size: 17),
        ),
      ],
    );
  }

  Widget _privacyNote() {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: const Color(0x551F1B28),
        border: Border.all(color: const Color(0x33C4ADEF)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.home_work_outlined, color: _accent, size: 21),
              SizedBox(width: 13),
              Expanded(
                child: Text(
                  '雲端保存書檔，Cloudflare 保存你的閱讀資料。',
                  style: TextStyle(color: Color(0xFFD8CFE7), fontSize: 10, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            '原始 EPUB／CBZ 留在 Alist／OpenList；D1 保存索引、閱讀位置、閱讀統計、分類與外觀偏好，R2 保存索引封面。書籤、螢光標記與筆記也保存在 D1，依 Cloudflare Access 使用者身分隔離。瀏覽器只在閱讀時暫時載入書檔，不會建立本機書庫或持久化副本。',
            style: TextStyle(color: Color(0xFF898096), fontSize: 8, height: 1.8),
          ),
          SizedBox(height: 7),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'PRIVATE BY DESIGN',
              style: TextStyle(color: _faint, fontSize: 7, letterSpacing: 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBanner(bool narrow) {
    const copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ONE BOOK · YOUR OWN RHYTHM', style: _tinyLabel),
        SizedBox(height: 9),
        Text(
          '翻到下一頁，繼續自己的故事。',
          style: TextStyle(color: _text, fontSize: 19, fontWeight: FontWeight.w600),
        ),
      ],
    );
    final button = FilledButton.icon(
      onPressed: () => _openLegacy('/epub-lab/', '閱讀室'),
      icon: const Icon(Icons.arrow_outward, size: 16),
      label: const Text('進入閱讀空間'),
      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF7253B6)),
    );
    return Container(
      padding: EdgeInsets.all(narrow ? 18 : 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF302641), Color(0xFF1A1724)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0x40BAA0EE)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [copy, const SizedBox(height: 16), button],
            )
          : Row(
              children: [const Expanded(child: copy), button],
            ),
    );
  }

  Widget _footer() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 15),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        runSpacing: 8,
        spacing: 16,
        children: [
          Text('FRAME READER',
              style: TextStyle(color: _accent, fontSize: 9, letterSpacing: 1.8)),
          Text('MADE FOR THE LOVE OF READING',
              style: TextStyle(color: _faint, fontSize: 7, letterSpacing: 1.4)),
          Text('CLOUD CATALOG · CLOUD READING DATA',
              style: TextStyle(color: _faint, fontSize: 7, letterSpacing: 1.1)),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).round()} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

const _tinyLabel = TextStyle(
  color: Color(0xFF8D829D),
  fontSize: 8,
  letterSpacing: 1.8,
  fontWeight: FontWeight.w600,
);

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.caption,
    required this.width,
  });

  final String label;
  final int value;
  final String caption;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width < 120 ? 120 : width,
      constraints: const BoxConstraints(minHeight: 92),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panel,
        border: Border.all(color: _line.withValues(alpha: 0.75)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: _faint, fontSize: 7, letterSpacing: 1.6)),
          const SizedBox(height: 11),
          Text(
            value.toString().padLeft(2, '0'),
            style: const TextStyle(
              color: Color(0xFFE9E1F4),
              fontFamily: 'NotoSansTC',
              fontSize: 27,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(caption, style: const TextStyle(color: _faint, fontSize: 8)),
        ],
      ),
    );
  }
}

class _HeroArtwork extends StatelessWidget {
  const _HeroArtwork();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 380,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 300,
            height: 300,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(0xFF8F6BDA).withValues(alpha: 0.22),
                  const Color(0xFF5B408F).withValues(alpha: 0.04),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          Container(
            width: 320,
            height: 245,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0x1AC4B0F2)),
              borderRadius: BorderRadius.circular(160),
            ),
          ),
          Transform.rotate(
            angle: -0.12,
            child: Container(
              width: 190,
              height: 275,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF9C7AD0), Color(0xFF393050), Color(0xFF171420)],
                ),
                border: Border.all(color: const Color(0x66E7DBFF)),
                borderRadius: BorderRadius.circular(5),
                boxShadow: const [
                  BoxShadow(color: Color(0x99000000), blurRadius: 55, offset: Offset(22, 27)),
                  BoxShadow(color: Color(0x339F7EE2), blurRadius: 45),
                ],
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('F R A M E', style: TextStyle(color: Color(0xFFEADFFF), fontSize: 11, letterSpacing: 2)),
                  Spacer(),
                  Icon(Icons.menu_book_rounded, size: 54, color: Color(0xFFE9DDFB)),
                  SizedBox(height: 15),
                  Text('YOUR OWN\nLIBRARY', style: TextStyle(color: Colors.white, fontSize: 20, height: 1.25, fontWeight: FontWeight.w600)),
                  Spacer(),
                  Text('READER EDITION · 2026', style: TextStyle(color: Color(0xFFD0BDEA), fontSize: 7, letterSpacing: 1.4)),
                ],
              ),
            ),
          ),
          Positioned(
            top: 42,
            right: 4,
            child: _FloatingNote(icon: Icons.auto_awesome, title: 'YOUR OWN', subtitle: 'LIBRARY'),
          ),
          const Positioned(
            bottom: 42,
            left: 2,
            child: _FloatingNote(icon: Icons.circle, title: '一座書架', subtitle: '隨時續讀'),
          ),
        ],
      ),
    );
  }
}

class _FloatingNote extends StatelessWidget {
  const _FloatingNote({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xD91F1A2B),
        border: Border.all(color: const Color(0x33D3C2F4)),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 22)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFFD4C1FF), size: 16),
          const SizedBox(width: 9),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: _muted, fontSize: 8)),
              Text(subtitle, style: const TextStyle(color: Color(0xFFEEE6FF), fontSize: 9, fontWeight: FontWeight.w600)),
            ],
          ),
        ],
      ),
    );
  }
}
