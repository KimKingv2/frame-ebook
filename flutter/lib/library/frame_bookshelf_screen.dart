import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/frame_api_scope.dart';
import '../core/frame_app_config.dart';
import '../legacy/frame_legacy_page.dart';
import 'frame_book.dart';
import 'frame_book_details_screen.dart';
import 'frame_library_repository.dart';
import 'frame_reader_screen.dart';

const _bg = Color(0xFF12101A);
const _panel = Color(0xFF1B1825);
const _raised = Color(0xFF211D2D);
const _ink = Color(0xFFF4F0FA);
const _muted = Color(0xFFAAA2B8);
const _faint = Color(0xFF81788F);
const _accent = Color(0xFFC5ADFF);
const _line = Color(0x55393247);

class FrameBookshelfScreen extends StatefulWidget {
  const FrameBookshelfScreen({super.key});

  @override
  State<FrameBookshelfScreen> createState() => _FrameBookshelfScreenState();
}

class _FrameBookshelfScreenState extends State<FrameBookshelfScreen> {
  final TextEditingController _search = TextEditingController();
  final _CoverCache _covers = _CoverCache();
  late FrameLibraryRepository _repository;
  bool _ready = false;
  bool _loading = true;
  bool _listView = false;
  String _query = '';
  String _sort = 'recent';
  String? _error;
  String? _folderKey;
  List<FrameBook> _books = const [];
  FrameBook? _detailsBook;

  Uri get _base => FrameAppConfig.apiBaseUri;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _repository = FrameLibraryRepository(FrameApiScope.of(context));
    _ready = true;
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (!_ready) return;
    if (mounted && showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final books = await _repository.loadBookshelf();
      if (!mounted) return;
      setState(() {
        _books = books;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _refresh() {
    _covers.clear();
    return _load();
  }

  List<FrameShelfEntry> get _entries {
    final result = groupFrameBooks(_books);
    result.sort(_compareEntries);
    return result;
  }

  List<FrameShelfEntry> get _visibleEntries {
    final query = _query.trim().toLowerCase();
    final result = _entries.where((entry) {
      return query.isEmpty ||
          entry.searchText.join(' ').toLowerCase().contains(query);
    }).toList();
    result.sort(_compareEntries);
    return result;
  }

  List<FrameShelfEntry> _shelf(bool comics) =>
      _visibleEntries.where((entry) => entry.isComic == comics).toList();

  int _compareEntries(FrameShelfEntry a, FrameShelfEntry b) {
    switch (_sort) {
      case 'title':
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      case 'added':
        final aTime = a.first.addedAt > 0 ? a.first.addedAt : a.first.lastModified;
        final bTime = b.first.addedAt > 0 ? b.first.addedAt : b.first.lastModified;
        return bTime.compareTo(aTime);
      case 'progress':
        return b.progressPercent.compareTo(a.progressPercent);
      case 'recent':
      default:
        return b.lastOpenedAt.compareTo(a.lastOpenedAt);
    }
  }

  FrameShelfEntry? _findFolder() {
    final key = _folderKey;
    if (key == null) return null;
    for (final entry in _entries) {
      if (entry.key == key && entry.isFolder) return entry;
    }
    return null;
  }

  Future<void> _openPage(Uri uri, String title, {bool toolbar = true}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => buildFrameLegacyPage(
          uri: uri,
          title: title,
          showToolbar: toolbar,
        ),
      ),
    );
    if (mounted) unawaited(_load(showLoading: false));
  }

  Future<void> _openManager() => _openPage(
        _base.replace(path: '/cloud/', queryParameters: const {'manager': '1'}),
        '連接與掃描',
      );

  Future<void> _openStats() =>
      _openPage(_base.replace(path: '/reading-stats/'), '閱讀時光');

  Future<void> _openReader(FrameBook book) async {
    if (kIsWeb) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => FrameReaderScreen(book: book),
        ),
      );
      if (mounted) unawaited(_load(showLoading: false));
      return;
    }

    final descriptor = book.descriptor();
    final query = <String, String>{
      'book': book.id,
      'provider': book.provider,
      'library': book.library,
      'root_path': book.rootPath,
      'path': book.path,
    };
    final profileId = descriptor['profileId']?.toString() ?? '';
    final sourceId = descriptor['sourceId']?.toString() ?? '';
    if (profileId.isNotEmpty) query['profile_id'] = profileId;
    if (sourceId.isNotEmpty) query['source_id'] = sourceId;
    await _openPage(
      _base.replace(path: '/epub-lab/', queryParameters: query),
      '閱讀室',
      toolbar: false,
    );
  }

  void _showDetails(FrameBook book) {
    setState(() => _detailsBook = book);
  }

  void _openFolder(FrameShelfEntry entry) {
    setState(() => _folderKey = entry.key);
  }

  void _closeFolder() => setState(() => _folderKey = null);

  String _coverHash(FrameBook book) {
    if (book.coverStatus == 'ready' &&
        RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(book.coverHash)) {
      return book.coverHash;
    }
    final hashes = book.raw['cloudCoverHashes'];
    if (hashes is List) {
      for (final value in hashes) {
        final hash = value?.toString() ?? '';
        if (RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(hash)) {
          return hash;
        }
      }
    }
    return '';
  }

  Widget _cover(FrameBook book, {bool contain = false}) {
    final hash = _coverHash(book);
    if (hash.isEmpty) {
      return _CoverFallback(title: _volumeTitle(book), comic: book.isComic);
    }
    return FutureBuilder<Uint8List>(
      future: _covers.load(hash, () => _repository.loadCover(hash)),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return Image.memory(
            snapshot.data!,
            fit: contain ? BoxFit.contain : BoxFit.cover,
            cacheWidth: 360,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) =>
                _CoverFallback(title: _volumeTitle(book), comic: book.isComic),
          );
        }
        if (snapshot.hasError) {
          return _CoverFallback(title: _volumeTitle(book), comic: book.isComic);
        }
        return const _CoverLoading();
      },
    );
  }

  String _volumeTitle(FrameBook book) {
    if (book.manualTitle && book.title.isNotEmpty) return book.title;
    final name = book.fileName.isNotEmpty ? book.fileName : book.title;
    final stem = name.replaceFirst(RegExp(r'\.(epub|cbz)$', caseSensitive: false), '');
    final embedded = book.raw['bookTitle']?.toString() ?? '';
    final ownTitle = embedded.isNotEmpty
        ? embedded
        : (book.title.isNotEmpty && book.title != book.folderTitle ? book.title : '');
    if (ownTitle.isNotEmpty) return ownTitle;
    if (book.isComic) {
      final series = book.comicMetadata['nameCn'] ?? book.comicMetadata['name'];
      if (series != null && series.toString().isNotEmpty) return series.toString();
    }
    return stem;
  }

  String _volumeAuthor(FrameBook book) {
    if (book.manualAuthor) return book.author;
    if (book.isComic) {
      final author = book.comicMetadata['author']?.toString() ?? '';
      if (author.isNotEmpty) return author;
    }
    return (book.raw['bookCreator'] ?? book.author).toString();
  }

  String _entryTitle(FrameShelfEntry entry) {
    if (!entry.isFolder) return entry.title;
    if (entry.first.manualTitle && entry.first.title.isNotEmpty) return entry.first.title;
    if (entry.isComic) {
      for (final member in entry.members) {
        final title = member.comicMetadata['nameCn'] ??
            member.comicMetadata['name'] ??
            '';
        if (title.toString().isNotEmpty) return title.toString();
      }
    }
    if (!entry.isComic && entry.members.length == 1) return _volumeTitle(entry.first);
    if (entry.first.folderTitle.isNotEmpty) return entry.first.folderTitle;
    return entry.title;
  }

  String _entryAuthor(FrameShelfEntry entry) {
    if (!entry.isFolder) return entry.author;
    if (!entry.isComic && entry.members.length == 1) return _volumeAuthor(entry.first);
    if (entry.isComic) {
      for (final member in entry.members) {
        final author = member.comicMetadata['author']?.toString() ?? '';
        if (author.isNotEmpty) return author;
      }
    }
    return entry.author;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return (bytes / 1024).round().toString() + ' KB';
    if (bytes >= 1024 * 1024 * 1024) {
      return (bytes / (1024 * 1024 * 1024)).toStringAsFixed(2) + ' GB';
    }
    return (bytes / (1024 * 1024)).toStringAsFixed(1) + ' MB';
  }

  Widget _coverStack(FrameShelfEntry entry) {
    final members = entry.sortedMembers();
    if (members.length <= 1) {
      final book = members.first;
      return _coverHash(book).isEmpty
          ? const _FolderCoverEmpty()
          : _cover(book);
    }
    final visible = members.take(3).toList();
    final visual = visible.length == 3
        ? [visible[1], visible[0], visible[2]]
        : [visible[1], visible[0]];
    return LayoutBuilder(
      builder: (context, bounds) {
        final w = bounds.maxWidth;
        final h = bounds.maxHeight;
        // Match the original CSS z-index: left sheet, right sheet, then
        // the smaller center cover above both side covers.
        final paintOrder = visual.length == 3 ? [0, 2, 1] : [0, 1];
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (final index in paintOrder)
              _stackSheet(visual[index], index, w, h, visual.length),
          ],
        );
      },
    );
  }

  Widget _stackSheet(FrameBook book, int index, double w, double h, int count) {
    final center = index == 1;
    final left = count == 2
        ? (center ? .21 : -.03)
        : (index == 0 ? -.07 : (center ? .21 : .29));
    final top = center ? .08 : -.02;
    final sheetWidth = center ? .58 : .78;
    final sheetHeight = center ? .84 : 1.04;
    final angle = center
        ? 0.0
        : (count == 2
            ? -.122173
            : (index == 0 ? -.139626 : .139626));
    return Positioned(
      left: w * left,
      top: h * top,
      width: w * sheetWidth,
      height: h * sheetHeight,
      child: Transform.rotate(
        angle: angle,
        alignment: const Alignment(0, .76),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: center ? Colors.transparent : const Color(0xFFF3EFE8),
            borderRadius: center ? BorderRadius.zero : BorderRadius.circular(3),
            border: center
                ? Border.all(color: Colors.transparent, width: 0)
                : Border.all(color: const Color(0x88F5F0FA)),
            boxShadow: center
                ? const []
                : const [
                    BoxShadow(
                      color: Color(0x44000000),
                      blurRadius: 12,
                      offset: Offset(0, 5),
                    ),
                  ],
          ),
          child: _coverHash(book).isEmpty
              ? const _StackCoverFallback()
              : _cover(book, contain: center),
        ),
      ),
    );
  }

  Widget _card(FrameShelfEntry entry, {FrameBook? volume, bool compact = false}) {
    final folder = volume == null && entry.isFolder;
    final book = volume ?? entry.first;
    final title = volume == null ? _entryTitle(entry) : _volumeTitle(volume);
    final author = volume == null ? _entryAuthor(entry) : _volumeAuthor(volume);
    final percent = book.progressPercent;
    final progressText = folder
        ? entry.volumeCount.toString() + ' 本作品，點擊查看資料夾'
        : (percent > 0 ? percent.toString() + '% · ' + book.progressLabel : '尚未開始');
    final actionText = folder ? '開啟資料夾' : (percent > 0 ? '繼續閱讀' : '開始閱讀');

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0x33205A50)),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, 7)),
        ],
      ),
      child: compact
          ? _compactCard(entry, book, title, author, folder, volume != null, actionText, progressText)
          : _gridCard(entry, book, title, author, folder, volume != null, actionText, progressText),
    );
  }

  Widget _cardActionButton({
    required String label,
    required VoidCallback onPressed,
    required bool primary,
  }) {
    final foreground = primary ? const Color(0xFFE4D6FF) : const Color(0xFFC7BBD9);
    final background = primary ? const Color(0xFF403252) : const Color(0xFF211D2B);
    final border = primary ? const Color(0xFF6C568E) : const Color(0xFF665A78);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            height: 36,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              border: Border.all(color: border, width: 1),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'NotoSansTC',
                fontFamilyFallback: ['NotoSansSCFallback'],
                color: Color(0xFFE4D6FF),
                fontSize: 10,
                height: 1.15,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.none,
              ).copyWith(color: foreground),
            ),
          ),
        ),
      ),
    );
  }

  Widget _gridCard(
    FrameShelfEntry entry,
    FrameBook book,
    String title,
    String author,
    bool folder,
    bool isVolume,
    String actionText,
    String progressText,
  ) {
    final percent = book.progressPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: folder || isVolume ? 2 / 3 : 3 / 4,
          child: InkWell(
            onTap: () => folder ? _openFolder(entry) : _openReader(book),
            child: Stack(
              fit: StackFit.expand,
              children: [
                folder ? _coverStack(entry) : _cover(book),
                if (!folder)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xCC17141F),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0x55E7D9FF)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                        child: Text(book.format,
                            style: const TextStyle(color: _ink, fontSize: 8, letterSpacing: 1)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title.isEmpty ? book.fileName : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _ink, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(author.isEmpty ? (book.isComic ? '漫畫／圖像書' : '作者未提供') : author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 9)),
              if (isVolume)
                Text(book.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _faint, fontSize: 8)),
              const SizedBox(height: 8),
              if (!folder)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: percent / 100,
                    minHeight: 3,
                    backgroundColor: const Color(0x33205A50),
                    valueColor: const AlwaysStoppedAnimation(_accent),
                  ),
                )
              else
                const SizedBox(height: 3),
              const SizedBox(height: 5),
              Text(progressText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _faint, fontSize: 8)),
              const SizedBox(height: 5),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: SizedBox(
            height: 36,
            child: folder
                ? _cardActionButton(
                    label: '開啟資料夾',
                    primary: true,
                    onPressed: () => _openFolder(entry),
                  )
                : Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: _cardActionButton(
                          label: actionText,
                          primary: true,
                          onPressed: () => _openReader(book),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        flex: 2,
                        child: _cardActionButton(
                          label: '作品資訊',
                          primary: false,
                          onPressed: () => _showDetails(book),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _compactCard(
    FrameShelfEntry entry,
    FrameBook book,
    String title,
    String author,
    bool folder,
    bool isVolume,
    String actionText,
    String progressText,
  ) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: AspectRatio(
              aspectRatio: folder || isVolume ? 2 / 3 : 3 / 4,
              child: InkWell(
                onTap: () => folder ? _openFolder(entry) : _openReader(book),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: folder ? _coverStack(entry) : _cover(book),
                ),
              ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title.isEmpty ? book.fileName : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _ink, fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(author.isEmpty ? '作者未提供' : author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 9)),
                if (isVolume)
                  Text(book.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _faint, fontSize: 8)),
                const SizedBox(height: 8),
                if (!folder)
                  LinearProgressIndicator(
                    value: book.progressPercent / 100,
                    minHeight: 3,
                    backgroundColor: const Color(0x33205A50),
                    valueColor: const AlwaysStoppedAnimation(_accent),
                  ),
                const SizedBox(height: 5),
                Text(folder ? entry.volumeCount.toString() + ' 冊' : progressText,
                    style: const TextStyle(color: _faint, fontSize: 8)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: actionText,
                onPressed: () => folder ? _openFolder(entry) : _openReader(book),
                icon: const Icon(Icons.arrow_forward_rounded, color: _accent),
              ),
              if (!folder)
                IconButton(
                  tooltip: '作品資訊',
                  onPressed: () => _showDetails(book),
                  icon: const Icon(Icons.more_horiz, color: _muted),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _header(double width) {
    final compact = width < 760;
    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 18 : 30, 17, compact ? 18 : 30, 15),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x222D263A))),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 13,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 37,
                height: 37,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFA485EF), Color(0xFF61469F)],
                  ),
                ),
                child: const Center(
                  child: Text('F',
                      style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 10),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FRAME READER',
                      style: TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.8)),
                  SizedBox(height: 2),
                  Text('CLOUD LIBRARY',
                      style: TextStyle(color: _faint, fontSize: 8, letterSpacing: 2)),
                ],
              ),
            ],
          ),
          Wrap(
            spacing: 3,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _nav('我的書架', selected: true, onTap: () {}),
              _nav('閱讀時光', onTap: _openStats),
              _nav('閱讀室', onTap: () =>
                  _openPage(_base.replace(path: '/epub-lab/'), '閱讀室', toolbar: false)),
            ],
          ),
          FilledButton.icon(
            onPressed: _openManager,
            icon: const Icon(Icons.add_link, size: 15),
            label: const Text('連接與掃描'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6F579E),
              foregroundColor: _ink,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              textStyle: const TextStyle(fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _nav(String label, {bool selected = false, required VoidCallback onTap}) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: selected ? _ink : _muted,
        backgroundColor: selected ? const Color(0x4439304B) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 10),
      ),
      child: Text(label),
    );
  }

  Widget _hero(double width) {
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            SizedBox(width: 25, child: Divider(color: _accent)),
            SizedBox(width: 9),
            Text('YOUR PRIVATE READING ROOM',
                style: TextStyle(color: _accent, fontSize: 8, letterSpacing: 2)),
          ],
        ),
        const SizedBox(height: 18),
        const Text.rich(
          TextSpan(children: [
            TextSpan(text: '把喜歡的書，\n'),
            TextSpan(
              text: '安放在自己的書架。',
              style: TextStyle(color: _accent, fontStyle: FontStyle.italic),
            ),
          ]),
          style: TextStyle(color: _ink, fontSize: 29, height: 1.45, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const Text(
          '只從 Alist／OpenList 掃描索引導入書籍。書檔留在你的雲端儲存，書架、閱讀進度、外觀偏好、書籤與筆記均透過 Cloudflare D1／R2 保存，跨裝置自動同步。',
          style: TextStyle(color: _muted, fontSize: 10, height: 1.9),
        ),
        const SizedBox(height: 17),
        Wrap(
          spacing: 9,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _openManager,
              icon: const Icon(Icons.add_link, size: 14),
              label: const Text('連接與掃描'),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF6F579E), foregroundColor: _ink),
            ),
            TextButton.icon(
              onPressed: () =>
                  _openPage(_base.replace(path: '/epub-lab/'), '閱讀室', toolbar: false),
              icon: const Icon(Icons.menu_book, size: 14),
              label: const Text('前往閱讀室'),
              style: TextButton.styleFrom(foregroundColor: _accent),
            ),
          ],
        ),
        const SizedBox(height: 15),
        const Wrap(
          spacing: 9,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _Tag('ALIST · OPENLIST'),
            _Dot(),
            _Tag('BOOKS · EPUB'),
            _Dot(),
            _Tag('COMICS · CBZ'),
          ],
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(width < 760 ? 22 : 48, 35, width < 760 ? 22 : 48, 22),
      child: width < 760
          ? Column(children: [copy, const SizedBox(height: 18), const _HeroArt()])
          : Row(children: [Expanded(flex: 6, child: copy), const Expanded(flex: 4, child: _HeroArt())]),
    );
  }

  Widget _stats() {
    final items = _entries;
    final started = items.where((entry) => entry.progressPercent > 0).length;
    final books = items.where((entry) => !entry.isComic).length;
    final comics = items.length - books;
    final stats = [
      ('BOOKS IN LIBRARY', items.length, '已收藏作品', Icons.auto_stories_outlined),
      ('IN PROGRESS', started, '正在閱讀', Icons.bookmark_added_outlined),
      ('EPUB', books, '文字與固定版面', Icons.menu_book_outlined),
      ('COMICS', comics, 'CBZ 圖像封存', Icons.collections_bookmark_outlined),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumns = constraints.maxWidth < 620;
          final itemWidth = twoColumns
              ? (constraints.maxWidth - 12) / 2
              : (constraints.maxWidth - 36) / 4;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: stats.map((item) {
              return SizedBox(
                width: itemWidth,
                child: Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: _panel,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: const Color(0x33205A50)),
                  ),
                  child: Row(
                    children: [
                      Icon(item.$4, color: _accent, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.$1,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: _faint, fontSize: 7, letterSpacing: 1.1)),
                            const SizedBox(height: 3),
                            Text(item.$2.toString().padLeft(2, '0'),
                                style: const TextStyle(color: _ink, fontSize: 22, fontWeight: FontWeight.w500)),
                            Text(item.$3, style: const TextStyle(color: _muted, fontSize: 8)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  Widget _sectionHeading(String kicker, String title,
      {String? subtitle, Widget? trailing}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(kicker, style: const TextStyle(color: _accent, fontSize: 8, letterSpacing: 1.8)),
              const SizedBox(height: 5),
              Text(title, style: const TextStyle(color: _ink, fontSize: 21, fontWeight: FontWeight.w600)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle, style: const TextStyle(color: _muted, fontSize: 9)),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _recentSliver() {
    final recent = _entries.where((entry) => entry.lastOpenedAt > 0).toList()
      ..sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
    if (recent.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 30, 24, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeading('PICK UP WHERE YOU LEFT OFF', '最近閱讀',
                subtitle: '從上次停下的地方接著讀'),
            const SizedBox(height: 15),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: recent.take(3).map((entry) {
                  return SizedBox(
                    width: 174,
                    height: 354,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _card(entry),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 25, 24, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final search = SizedBox(
              width: constraints.maxWidth < 600 ? constraints.maxWidth : 410,
              child: TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                style: const TextStyle(color: _ink, fontSize: 10),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, color: _faint, size: 18),
                  hintText: '搜尋書名、作者或檔案名稱',
                  hintStyle: const TextStyle(color: _faint, fontSize: 10),
                  filled: true,
                  fillColor: _panel,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(7),
                    borderSide: const BorderSide(color: _line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(7),
                    borderSide: const BorderSide(color: _line),
                  ),
                ),
              ),
            );
            final actions = Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('排序', style: TextStyle(color: _muted, fontSize: 9)),
                DropdownButton<String>(
                  value: _sort,
                  dropdownColor: _raised,
                  underline: const SizedBox.shrink(),
                  style: const TextStyle(color: _ink, fontSize: 9),
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
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: _panel,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: const Color(0x33205A50)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _viewButton(Icons.grid_view_rounded, !_listView, false),
                      _viewButton(Icons.view_list_rounded, _listView, true),
                    ],
                  ),
                ),
              ],
            );
            if (constraints.maxWidth < 720) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [search, const SizedBox(height: 9), actions],
              );
            }
            return Row(children: [search, const Spacer(), actions]);
          },
        ),
      ),
    );
  }

  Widget _viewButton(IconData icon, bool selected, bool list) {
    return IconButton(
      tooltip: list ? '列表' : '封面網格',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 33, height: 30),
      padding: EdgeInsets.zero,
      onPressed: () => setState(() => _listView = list),
      icon: Icon(icon, size: 16, color: selected ? _ink : _faint),
      style: IconButton.styleFrom(
        backgroundColor: selected ? const Color(0xFF39304B) : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
    );
  }

  Widget _shelfHeading(bool comics, int count) {
    return Container(
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 12),
      decoration: BoxDecoration(
        color: comics ? const Color(0xFF1D1B2B) : _panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
        border: const Border(
          top: BorderSide(color: Color(0x33205A50)),
          left: BorderSide(color: Color(0x33205A50)),
          right: BorderSide(color: Color(0x33205A50)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comics ? 'ILLUSTRATED EDITION · EPUB / CBZ' : 'READING EDITION · EPUB',
                  style: const TextStyle(color: _faint, fontSize: 7, letterSpacing: 1.6),
                ),
                const SizedBox(height: 6),
                Text(
                  comics ? '漫畫' : '電子書',
                  style: const TextStyle(color: _ink, fontSize: 21, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  comics ? '固定版面 EPUB、漫畫與圖像小說' : '小說、散文、非虛構與各類文字作品',
                  style: const TextStyle(color: _muted, fontSize: 9),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(count.toString().padLeft(2, '0'),
                  style: const TextStyle(color: _ink, fontSize: 26)),
              Text(comics ? 'COMICS' : 'BOOKS',
                  style: const TextStyle(color: _faint, fontSize: 7, letterSpacing: 1.5)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _gridSliver(
    int itemCount,
    Widget Function(int index) itemBuilder,
  ) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    const horizontalPadding = 48.0;
    const gap = 13.0;
    final availableWidth = (viewportWidth - horizontalPadding).clamp(0.0, double.infinity);
    final minimumCardWidth = viewportWidth <= 980 ? 132.0 : 142.0;
    final columnGap = viewportWidth <= 520 ? 11.0 : gap;
    final columns = viewportWidth <= 520
        ? 2
        : viewportWidth <= 760
            ? 3
            : ((availableWidth + columnGap) / (minimumCardWidth + columnGap))
                .floor()
                .clamp(1, 12)
                .toInt();
    final rowCount = (itemCount + columns - 1) ~/ columns;

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, rowIndex) {
            final firstIndex = rowIndex * columns;
            return Padding(
              padding: EdgeInsets.only(bottom: rowIndex == rowCount - 1 ? 0 : 19),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var column = 0; column < columns; column++) ...[
                    Expanded(
                      child: firstIndex + column < itemCount
                          ? itemBuilder(firstIndex + column)
                          : const SizedBox.shrink(),
                    ),
                    if (column != columns - 1) SizedBox(width: columnGap),
                  ],
                ],
              ),
            );
          },
          childCount: rowCount,
        ),
      ),
    );
  }

  List<Widget> _shelfSlivers(bool comics) {
    final all = _entries.where((entry) => entry.isComic == comics).toList();
    final visible = _shelf(comics);
    final result = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: _shelfHeading(comics, all.length),
        ),
      ),
    ];
    if (visible.isEmpty) {
      result.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 19),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 30),
              decoration: BoxDecoration(
                color: _panel,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(11)),
                border: Border.all(color: const Color(0x33205A50)),
              ),
              child: Column(
                children: [
                  Icon(
                    comics ? Icons.collections_bookmark_outlined : Icons.menu_book_outlined,
                    color: _accent,
                    size: 32,
                  ),
                  const SizedBox(height: 11),
                  Text(
                    all.isEmpty
                        ? (comics ? '漫畫書架尚未收藏作品' : '電子書架尚未收藏作品')
                        : '沒有符合條件的' + (comics ? '漫畫' : '電子書') + '。',
                    style: const TextStyle(color: _ink, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    all.isEmpty
                        ? '先從「連接與掃描」設定 Alist／OpenList 目錄，掃描完成後作品便會自動加入書架。'
                        : '試試其他書名、作者或檔案名稱。',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _muted, fontSize: 9, height: 1.7),
                  ),
                  if (all.isEmpty) ...[
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: _openManager,
                      icon: const Icon(Icons.add_link, size: 14),
                      label: const Text('連接與掃描'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
      return result;
    }
    if (_listView) {
      result.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: _card(visible[index], compact: true),
              ),
              childCount: visible.length,
            ),
          ),
        ),
      );
    } else {
      result.add(
        _gridSliver(
          visible.length,
          (index) => _card(visible[index]),
        ),
      );
    }
    return result;
  }

  List<Widget> _folderSlivers(FrameShelfEntry folder) {
    final volumes = folder.sortedMembers();
    final size = volumes.fold<int>(0, (sum, book) => sum + book.size);
    final result = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 25, 24, 17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                onPressed: _closeFolder,
                icon: const Icon(Icons.arrow_back, size: 15),
                label: const Text('返回我的書架'),
                style: TextButton.styleFrom(foregroundColor: _accent, padding: EdgeInsets.zero),
              ),
              const SizedBox(height: 15),
              const Text('YOUR FOLDER · BOOK COLLECTION',
                  style: TextStyle(color: _accent, fontSize: 8, letterSpacing: 1.8)),
              const SizedBox(height: 7),
              Text(
                _entryTitle(folder),
                style: const TextStyle(color: _ink, fontSize: 24, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 5),
              Text(folder.first.folderPath, style: const TextStyle(color: _muted, fontSize: 10)),
              const SizedBox(height: 7),
              Text(
                volumes.length.toString() + ' 冊 · ' + _formatBytes(size) + ' · 選擇卷冊即可進入閱讀室',
                style: const TextStyle(color: _faint, fontSize: 9),
              ),
            ],
          ),
        ),
      ),
    ];
    if (_listView) {
      result.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: _card(folder, volume: volumes[index], compact: true),
              ),
              childCount: volumes.length,
            ),
          ),
        ),
      );
    } else {
      result.add(
        _gridSliver(
          volumes.length,
          (index) => _card(folder, volume: volumes[index]),
        ),
      );
    }
    return result;
  }

  Widget _privacy() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0x33205A50)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.home_work_outlined, color: _accent, size: 20),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '雲端保存書檔，Cloudflare 保存你的閱讀資料。',
                      style: TextStyle(color: _ink, fontSize: 10, fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 6),
                    Text(
                      '原始 EPUB／CBZ 留在 Alist／OpenList；D1 保存索引、閱讀位置、閱讀統計、分類與外觀偏好，R2 保存索引封面。書籤、螢光標記與筆記也保存在 D1，依 Cloudflare Access 使用者身分隔離。',
                      style: TextStyle(color: _muted, fontSize: 9, height: 1.7),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _footer() => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, 15, 24, 28),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('FRAME READER',
                  style: TextStyle(color: _accent, fontSize: 8, letterSpacing: 1.7)),
              Text('MADE FOR THE LOVE OF READING',
                  style: TextStyle(color: _faint, fontSize: 7)),
              Text('CLOUD CATALOG · CLOUD READING DATA',
                  style: TextStyle(color: _faint, fontSize: 7)),
            ],
          ),
        ),
      );

  Widget _loadingState() => const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: _accent, strokeWidth: 2),
              SizedBox(height: 14),
              Text('正在讀取雲端書架索引……',
                  style: TextStyle(color: _muted, fontSize: 10)),
            ],
          ),
        ),
      );

  Widget _errorState() => SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_outlined,
                    color: Color(0xFFFFB7B7), size: 35),
                const SizedBox(height: 12),
                const Text('無法載入雲端書架',
                    style: TextStyle(color: _ink, fontSize: 15)),
                const SizedBox(height: 8),
                Text(
                  _error ?? '發生未知錯誤。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFFB7B7),
                    fontSize: 10,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh, size: 15),
                  label: const Text('重新載入'),
                ),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final detailsBook = _detailsBook;
    if (detailsBook != null) {
      return FrameBookDetailsScreen(
        book: detailsBook,
        cover: _cover(detailsBook, contain: true),
        onBack: () => setState(() => _detailsBook = null),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final folder = _findFolder();
    return Scaffold(
      backgroundColor: _bg,
      body: RefreshIndicator(
        color: _accent,
        backgroundColor: _panel,
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header(width)),
            if (_loading && _books.isEmpty)
              _loadingState()
            else if (_error != null && _books.isEmpty)
              _errorState()
            else if (folder != null)
              ..._folderSlivers(folder)
            else ...[
              SliverToBoxAdapter(child: _hero(width)),
              SliverToBoxAdapter(child: _stats()),
              _recentSliver(),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 34, 24, 0),
                  child: _sectionHeading(
                    'YOUR PERSONAL COLLECTION',
                    '兩種收藏，各自成架。',
                    subtitle: '掃描完成自動入架；書架與個人閱讀資料均保存在雲端。',
                    trailing: Text(
                      _entries.length.toString() + ' ITEMS',
                      style: const TextStyle(color: _faint, fontSize: 8, letterSpacing: 1.4),
                    ),
                  ),
                ),
              ),
              _toolbar(),
              ..._shelfSlivers(false),
              ..._shelfSlivers(true),
              SliverToBoxAdapter(child: _privacy()),
              _footer(),
            ],
            if (_loading && _books.isNotEmpty)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: _accent,
                  backgroundColor: Colors.transparent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CoverCache {
  final LinkedHashMap<String, Future<Uint8List>> _items =
      LinkedHashMap<String, Future<Uint8List>>();

  Future<Uint8List> load(String hash, Future<Uint8List> Function() loader) {
    final cached = _items.remove(hash);
    if (cached != null) {
      _items[hash] = cached;
      return cached;
    }
    final future = loader();
    _items[hash] = future;
    while (_items.length > 48) {
      _items.remove(_items.keys.first);
    }
    return future;
  }

  void clear() => _items.clear();
}

class _FolderCoverEmpty extends StatelessWidget {
  const _FolderCoverEmpty();

  @override
  Widget build(BuildContext context) => const CustomPaint(
        painter: _FolderCoverEmptyPainter(),
        child: SizedBox.expand(),
      );
}

class _FolderCoverEmptyPainter extends CustomPainter {
  const _FolderCoverEmptyPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFD9D1C4),
    );
    final green = Path()
      ..moveTo(size.width * .58, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height * .61)
      ..close();
    canvas.drawPath(green, Paint()..color = const Color(0xFF355047));
    final terracotta = Path()
      ..moveTo(0, size.height * .74)
      ..lineTo(0, size.height)
      ..lineTo(size.width * .34, size.height)
      ..close();
    canvas.drawPath(terracotta, Paint()..color = const Color(0xFFC58C70));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _StackCoverFallback extends StatelessWidget {
  const _StackCoverFallback();

  @override
  Widget build(BuildContext context) => const CustomPaint(
        painter: _StackCoverFallbackPainter(),
        child: SizedBox.expand(),
      );
}

class _StackCoverFallbackPainter extends CustomPainter {
  const _StackCoverFallbackPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFD9D1C4),
    );
    final diameter = size.width * .68;
    final topCircle = Rect.fromLTWH(
      size.width * .24,
      size.height * .18,
      diameter,
      diameter,
    );
    canvas.drawOval(topCircle, Paint()..color = const Color(0xFF355047));

    final ringDiameter = size.width * .72;
    final ringRect = Rect.fromLTWH(
      -size.width * .16,
      size.height - ringDiameter + size.height * .22,
      ringDiameter,
      ringDiameter,
    );
    canvas.drawOval(
      ringRect,
      Paint()
        ..color = const Color(0xFF9E7C55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CoverLoading extends StatelessWidget {
  const _CoverLoading();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Color(0xFF211B2E),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.7,
              color: Color(0x88C5ADFF),
            ),
          ),
        ),
      );
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({required this.title, required this.comic});

  final String title;
  final bool comic;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.35, -0.65),
            radius: 1.1,
            colors: [Color(0xFF51416D), Color(0xFF292333), Color(0xFF17141E)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('FRAME READER',
                style: TextStyle(color: Color(0xFFC3AFE5), fontSize: 7, letterSpacing: 1.5)),
            Text(
              title.isEmpty ? '未命名書籍' : title,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFF5EFFB),
                fontFamily: 'Georgia',
                fontSize: 14,
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(comic ? 'COMIC EDITION' : 'READING EDITION',
                style: const TextStyle(color: Color(0xFF9E8EB8), fontSize: 7, letterSpacing: 1.2)),
          ],
        ),
      );
}

class _HeroArt extends StatelessWidget {
  const _HeroArt();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 300,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 270,
              height: 190,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x447F60BE), Color(0x227F60BE), Colors.transparent],
                ),
              ),
            ),
            Container(
              width: 270,
              height: 190,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0x227E6AA3)),
                borderRadius: BorderRadius.circular(150),
              ),
            ),
            Transform.rotate(
              angle: -.07,
              child: Container(
                width: 170,
                height: 225,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0x66E7DBFF)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 32,
                      offset: Offset(18, 23),
                    ),
                    BoxShadow(color: Color(0x447F60BE), blurRadius: 40),
                  ],
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF50416A), Color(0xFF282332), Color(0xFF17141E)],
                  ),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('FRAME\nREADER',
                        style: TextStyle(color: Color(0xFFD3C1F0), fontSize: 9, height: 1.3, letterSpacing: 1.8)),
                    Icon(Icons.auto_stories_rounded, color: Color(0xFFCEB8F1), size: 48),
                    Text('YOUR OWN\nLIBRARY',
                        style: TextStyle(color: Color(0xFFEDE5F6), fontSize: 14, height: 1.35, letterSpacing: 1.2)),
                  ],
                ),
              ),
            ),
            const Positioned(
              right: 2,
              top: 43,
              child: _FloatNote(top: 'YOUR OWN', bottom: 'LIBRARY', icon: Icons.auto_awesome),
            ),
            const Positioned(
              left: 0,
              bottom: 34,
              child: _FloatNote(top: '一座書架', bottom: '隨時續讀', icon: Icons.circle),
            ),
          ],
        ),
      );
}

class _FloatNote extends StatelessWidget {
  const _FloatNote({required this.top, required this.bottom, required this.icon});

  final String top;
  final String bottom;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xDD211C2D),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x44393247)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _accent, size: 13),
            const SizedBox(width: 7),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(top, style: const TextStyle(color: _muted, fontSize: 8)),
                Text(bottom,
                    style: const TextStyle(color: _ink, fontSize: 9, fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
      );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(color: _faint, fontSize: 7, letterSpacing: 1.4),
      );
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(color: _faint, shape: BoxShape.circle),
        child: SizedBox(width: 3, height: 3),
      );
}
