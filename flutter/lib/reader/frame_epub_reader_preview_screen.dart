import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:xml/xml.dart';

import '../core/frame_api_scope.dart';
import '../core/frame_app_config.dart';
import '../library/frame_book.dart';
import '../library/frame_reader_repository.dart';
import '../transport/frame_cloud_file_source.dart';
import '../transport/frame_file_source.dart';
import '../transport/frame_file_source_factory.dart';
import 'frame_epub_footnote.dart';
import 'frame_epub_cfi.dart';
import 'frame_epub_chapter_view.dart';
import 'frame_epub_parser.dart';
import 'frame_epub_page_turn_surface.dart';
import 'frame_epub_reader_session.dart';

const _readerChrome = Color(0xFF171420);
const _readerPanel = Color(0xFF211D2D);
const _readerText = Color(0xFFF4F0FA);
const _readerMuted = Color(0xFFAAA2B8);
const _readerAccent = Color(0xFFC5ADFF);

/// An isolated Flutter EPUB reader preview.
///
/// The legacy Reading Room remains the default entry point until the shared
/// renderer has passed the cross-platform EPUB parity inventory.
class FrameEpubReaderPreviewScreen extends StatefulWidget {
  const FrameEpubReaderPreviewScreen({
    required this.book,
    this.fileSource,
    this.repository,
    super.key,
  });

  final FrameBook book;

  /// Optional dependency overrides are used by widget tests. Production
  /// screens obtain the standard platform adapters from the factories.
  final FrameFileSource? fileSource;
  final FrameReaderRepository? repository;

  @override
  State<FrameEpubReaderPreviewScreen> createState() =>
      _FrameEpubReaderPreviewScreenState();
}

class _FrameEpubReaderPreviewScreenState
    extends State<FrameEpubReaderPreviewScreen> {
  bool _initialized = false;
  bool _appearanceInitialized = false;
  String? _setupError;
  FrameFileSource? _fileSource;
  FrameEpubReaderSession? _session;
  late ScrollController _chapterScrollController;
  late PageController _chapterPageController;
  String _layoutMode = 'continuous';
  String? _lastVisibleCfi;
  String? _activeChapterPath;
  Timer? _progressSaveTimer;
  String? _pendingCfi;
  int? _pendingPercent;
  String? _lastSavedCfi;
  _SelectedEpubText? _selectedText;
  bool _isFixedPageZoomed = false;

  double _fontSize = 18;
  double _lineHeight = 1.75;
  String _theme = 'dark';

  @override
  void initState() {
    super.initState();
    _chapterScrollController = ScrollController();
    _chapterPageController = PageController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    try {
      if (widget.book.format.toUpperCase() != 'EPUB') {
        throw const FormatException('Flutter 閱讀預覽目前只接受 EPUB 檔案。');
      }
      final repository = widget.repository ??
          FrameReaderRepository(FrameApiScope.of(context));
      final source = widget.fileSource ??
          createFrameFileSource(baseUri: FrameAppConfig.apiBaseUri);
      _fileSource = source;

      final session = FrameEpubReaderSession(
        book: widget.book,
        fileSource: source,
        repository: repository,
      );
      _session = session;
      session.addListener(_handleSessionChanged);
      unawaited(session.open().catchError((Object _) {}));
    } on Object catch (error) {
      _setupError = error.toString();
    }
  }

  void _handleSessionChanged() {
    final session = _session;
    final chapterPath = session?.currentChapter?.resource.path;
    if (chapterPath != null && chapterPath != _activeChapterPath) {
      _activeChapterPath = chapterPath;
      _lastSavedCfi = null;
      _lastVisibleCfi = null;
      _selectedText = null;
      _isFixedPageZoomed = false;
      final previousController = _chapterScrollController;
      final previousPageController = _chapterPageController;
      _chapterScrollController = ScrollController();
      _chapterPageController = PageController();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previousController.dispose();
        previousPageController.dispose();
      });
    }
    if (session?.status == FrameEpubReaderStatus.ready &&
        !_appearanceInitialized) {
      _restoreAppearance(session!.readerState.appearance);
      _appearanceInitialized = true;
    }
    if (mounted) setState(() {});
  }

  void _restoreAppearance(Map<String, dynamic> appearance) {
    double value(dynamic raw, double fallback) {
      final parsed = raw is num
          ? raw.toDouble()
          : double.tryParse(raw?.toString() ?? '');
      return parsed ?? fallback;
    }

    _fontSize = value(appearance['frameFlutterFontSize'], 18)
        .clamp(14, 30)
        .toDouble();
    _lineHeight = value(appearance['frameFlutterLineHeight'], 1.75)
        .clamp(1.2, 2.4)
        .toDouble();
    final theme = appearance['frameFlutterTheme']?.toString() ?? 'dark';
    _theme = const {'dark', 'sepia', 'light'}.contains(theme) ? theme : 'dark';
    final layoutMode =
        appearance['frameFlutterLayoutMode']?.toString() ?? 'continuous';
    _layoutMode = const {'continuous', 'paginated'}.contains(layoutMode)
        ? layoutMode
        : 'continuous';
  }

  @override
  void dispose() {
    unawaited(_releaseResources());
    super.dispose();
  }

  Future<void> _releaseResources() async {
    await _flushReadingPosition();
    _progressSaveTimer?.cancel();
    final session = _session;
    if (session != null) {
      session.removeListener(_handleSessionChanged);
      await session.close();
      session.dispose();
    }
    final source = _fileSource;
    if (source is FrameCloudFileSource) source.close();
    _chapterScrollController.dispose();
    _chapterPageController.dispose();
  }

  FrameEpubCfiLocation? _initialCfiLocationFor(
    FrameEpubReaderSession session,
  ) {
    final chapter = session.currentChapter;
    final epub = session.epub;
    if (chapter == null || epub == null) return null;
    final visibleCfi = _lastVisibleCfi;
    if (visibleCfi != null &&
        FrameEpubCfi.spineIndexFromCfi(epub, visibleCfi) ==
            session.currentSpineIndex) {
      final location = FrameEpubCfi.resolve(
        book: epub,
        document: chapter.document,
        cfi: visibleCfi,
      );
      if (location != null) return location;
    }
    final restoredCfi = session.initialCfi;
    if (restoredCfi == null) return null;
    return FrameEpubCfi.resolve(
      book: epub,
      document: chapter.document,
      cfi: restoredCfi,
    );
  }

  XmlElement? _initialAnchorFor(FrameEpubReaderSession session) {
    final chapter = session.currentChapter;
    if (chapter == null) return null;
    return _initialCfiLocationFor(session)?.anchorElement ??
        session.initialAnchor ??
        FrameEpubCfi.anchorForFragment(
          chapter.document,
          session.currentFragment,
        );
  }

  FrameEpubCfiPoint? _initialTextPointFor(
    FrameEpubReaderSession session,
  ) {
    final location = _initialCfiLocationFor(session);
    if (location?.node is XmlText) {
      return FrameEpubCfiPoint(
        node: location!.node as XmlText,
        offset: location.offset,
      );
    }
    final anchor = _initialAnchorFor(session);
    return anchor == null ? null : FrameEpubCfi.firstTextPoint(anchor);
  }

  double? _initialScrollFractionFor(FrameEpubReaderSession session) {
    final chapter = session.currentChapter;
    if (chapter == null) return null;
    final restored = session.initialScrollFraction;
    if (session.initialCfi != null && restored != null) return restored;
    final anchor = FrameEpubCfi.anchorForFragment(
      chapter.document,
      session.currentFragment,
    );
    if (anchor == null) return null;
    final point = FrameEpubCfi.firstTextPoint(anchor);
    if (point == null) return null;
    return FrameEpubCfi.textFraction(
      chapter.document,
      point.node,
      point.offset,
    );
  }

  void _queueReadingPosition(String cfi, double chapterFraction) {
    _lastVisibleCfi = cfi;
    final session = _session;
    final index = session?.currentSpineIndex;
    final count = session?.epub?.spine.length ?? 0;
    if (session == null || index == null || count <= 0 ||
        cfi == _lastSavedCfi || cfi == _pendingCfi) {
      return;
    }
    final fraction = chapterFraction.clamp(0.0, 1.0);
    final percent = (((index + fraction) / count) * 100)
        .round()
        .clamp(0, 100)
        .toInt();
    _pendingCfi = cfi;
    _pendingPercent = percent;
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(
      const Duration(milliseconds: 1400),
      () => unawaited(_flushReadingPosition()),
    );
  }

  Future<void> _flushReadingPosition() async {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = null;
    final cfi = _pendingCfi;
    final percent = _pendingPercent;
    _pendingCfi = null;
    _pendingPercent = null;
    final session = _session;
    if (cfi == null || percent == null || session == null) return;
    try {
      await session.saveReadingPosition(percent: percent, cfi: cfi);
      _lastSavedCfi = cfi;
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('閱讀位置尚未同步：$error')),
      );
    }
  }

  Future<void> _runNavigation(Future<bool> Function() navigate) async {
    await _flushReadingPosition();
    await navigate();
  }

  String get _bookTitle => widget.book.title.trim().isNotEmpty
      ? widget.book.title.trim()
      : widget.book.fileName;

  Color get _pageBackground {
    switch (_theme) {
      case 'sepia':
        return const Color(0xFFF1E6D0);
      case 'light':
        return const Color(0xFFFAF9FC);
      case 'dark':
      default:
        return _readerChrome;
    }
  }

  Color get _pageText {
    switch (_theme) {
      case 'sepia':
        return const Color(0xFF3F3529);
      case 'light':
        return const Color(0xFF27232D);
      case 'dark':
      default:
        return const Color(0xFFECE7F4);
    }
  }

  Color get _pageLink {
    switch (_theme) {
      case 'sepia':
        return const Color(0xFF7652A5);
      case 'light':
        return const Color(0xFF6844B4);
      case 'dark':
      default:
        return const Color(0xFFBFA4FF);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      backgroundColor: _readerChrome,
      appBar: AppBar(
        backgroundColor: _readerChrome,
        foregroundColor: _readerText,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _bookTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            Text(
              'Flutter EPUB 預覽',
              style: TextStyle(color: _readerMuted, fontSize: 10),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '目錄',
            onPressed: session == null ? null : _showTableOfContents,
            icon: const Icon(Icons.menu_book_outlined),
          ),
          IconButton(
            tooltip: '加入書籤',
            onPressed: session == null ||
                    session.status != FrameEpubReaderStatus.ready
                ? null
                : _createBookmark,
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
          IconButton(
            tooltip: '筆記與書籤',
            onPressed: session == null ? null : _showAnnotations,
            icon: const Icon(Icons.bookmarks_outlined),
          ),
          IconButton(
            tooltip: '閱讀設定',
            onPressed: session == null ? null : _showAppearance,
            icon: const Icon(Icons.text_fields_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _buildBody(session),
      ),
    );
  }

  Widget _buildBody(FrameEpubReaderSession? session) {
    final setupError = _setupError;
    if (setupError != null) return _errorPanel(setupError);
    if (session == null) return _loadingPanel('正在建立閱讀工作階段……');

    if (session.status == FrameEpubReaderStatus.opening ||
        session.status == FrameEpubReaderStatus.idle) {
      return _loadingPanel('正在讀取 EPUB 結構與章節……');
    }
    if (session.status == FrameEpubReaderStatus.error) {
      return _errorPanel(session.error ?? 'EPUB 開啟失敗。');
    }
    if (session.status != FrameEpubReaderStatus.ready ||
        session.currentChapter == null ||
        session.resourceLoader == null) {
      return _loadingPanel('閱讀工作階段已關閉。');
    }

    final chapter = session.currentChapter!;
    final spineCount = session.epub?.spine.length ?? 0;
    final chapterIndex = session.currentSpineIndex ?? 0;
    final initialTextPoint = _initialTextPointFor(session);

    return Column(
      children: [
        if (session.warning != null)
          Material(
            color: const Color(0xFF33283C),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: Color(0xFFE5C58C),
                    size: 17,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      session.warning!,
                      style: const TextStyle(
                        color: Color(0xFFE8D9C5),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: FrameEpubPageTurnSurface(
                  controller: _chapterScrollController,
                  pageController: _chapterPageController,
                  paginated: _layoutMode == 'paginated' && !session.isFixedLayout,
                  fixedLayout: session.isFixedLayout,
                  isRightToLeft: session.epub?.pageProgressionDirection ==
                      FrameEpubPageProgressionDirection.rightToLeft,
                  selectionActive: _selectedText != null,
                  pageZoomed: _isFixedPageZoomed,
                  onPreviousChapter: session.canGoPrevious
                      ? () async {
                          await _runNavigation(session.goToPreviousChapter);
                        }
                      : null,
                  onNextChapter: session.canGoNext
                      ? () async {
                          await _runNavigation(session.goToNextChapter);
                        }
                      : null,
                  child: FrameEpubChapterView(
                    key: ValueKey(chapter.resource.path),
                    chapter: chapter,
                    resourceLoader: session.resourceLoader!,
                    fixedLayout: session.isFixedLayout,
                    paginated: _layoutMode == 'paginated' && !session.isFixedLayout,
                    isRightToLeft:
                        session.epub?.pageProgressionDirection ==
                            FrameEpubPageProgressionDirection.rightToLeft,
                    pageController: _chapterPageController,
                    annotations: session.annotations,
                    spineIndex: chapterIndex,
                    initialAnchor: _initialAnchorFor(session),
                    initialTextNode: initialTextPoint?.node,
                    initialTextOffset: initialTextPoint?.offset,
                    initialScrollFraction: _initialScrollFractionFor(session),
                    scrollController: _chapterScrollController,
                    onReadingPosition: _queueReadingPosition,
                    onTextSelection: _handleTextSelection,
                    onPageZoomChanged: (zoomed) {
                      if (!mounted || _isFixedPageZoomed == zoomed) return;
                      setState(() => _isFixedPageZoomed = zoomed);
                    },
                    backgroundColor: _pageBackground,
                    textColor: _pageText,
                    linkColor: _pageLink,
                    fontSize: _fontSize,
                    lineHeight: _lineHeight,
                    onInternalLink: (href) {
                      unawaited(
                        _runNavigation(() => session.goToHref(href)),
                      );
                    },
                    onFootnote: _showFootnote,
                  ),
                ),
              ),
              if (_selectedText != null && !session.isFixedLayout)
                Positioned(
                  top: 10,
                  left: 8,
                  right: 8,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: _selectionToolbar(),
                  ),
                ),
              if (session.isChapterLoading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: _readerAccent,
                    backgroundColor: Colors.transparent,
                  ),
                ),
            ],
          ),
        ),
        _chapterControls(
          session,
          chapterIndex: chapterIndex,
          spineCount: spineCount,
        ),
      ],
    );
  }

  Widget _loadingPanel(String message) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: _readerAccent),
            const SizedBox(height: 18),
            Text(message, style: const TextStyle(color: _readerMuted)),
          ],
        ),
      );

  Widget _errorPanel(String message) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.menu_book_outlined,
                  color: Color(0xFFE5A6B2),
                  size: 36,
                ),
                const SizedBox(height: 16),
                const Text(
                  '無法開啟 Flutter EPUB 預覽',
                  style: TextStyle(
                    color: _readerText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _readerMuted,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 22),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                  label: const Text('返回舊版閱讀室'),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _chapterControls(
    FrameEpubReaderSession session, {
    required int chapterIndex,
    required int spineCount,
  }) {
    final label = session.currentChapterLabel.trim();
    return Material(
      color: _readerPanel,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '上一章',
                    onPressed: session.canGoPrevious
                        ? () => unawaited(
                              _runNavigation(session.goToPreviousChapter),
                            )
                        : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label.isEmpty ? '未命名章節' : label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _readerText,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '章節 ${chapterIndex + 1} / ${spineCount}',
                          style: const TextStyle(
                            color: _readerMuted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '下一章',
                    onPressed: session.canGoNext
                        ? () => unawaited(
                              _runNavigation(session.goToNextChapter),
                            )
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: session.chapterProgressPercent / 100,
                  minHeight: 3,
                  color: _readerAccent,
                  backgroundColor: const Color(0xFF423A50),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<_FlattenedTocEntry> _flattenToc(
    List<FrameEpubTocEntry> entries, {
    int depth = 0,
  }) {
    final flattened = <_FlattenedTocEntry>[];
    for (final entry in entries) {
      flattened.add(_FlattenedTocEntry(entry, depth));
      flattened.addAll(_flattenToc(entry.children, depth: depth + 1));
    }
    return flattened;
  }

  Future<void> _showFootnote(FrameEpubFootnote footnote) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: _readerPanel,
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 22,
          vertical: 24,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.of(dialogContext).size.height * 0.72,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        footnote.title,
                        style: const TextStyle(
                          color: _readerText,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '關閉註腳',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: _readerMuted,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 12, color: Color(0x55393247)),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      footnote.content,
                      style: const TextStyle(
                        color: _readerText,
                        fontSize: 15,
                        height: 1.75,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTableOfContents() async {
    final session = _session;
    if (session == null) return;
    final entries = _flattenToc(session.toc);
    final currentIndex = session.currentSpineIndex;
    final currentPath = currentIndex == null
        ? null
        : session.epub?.spine[currentIndex].item.path;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _readerPanel,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.72,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 18, 18, 12),
              child: Row(
                children: [
                  Icon(Icons.menu_book_outlined, color: _readerAccent),
                  SizedBox(width: 10),
                  Text(
                    'EPUB 目錄',
                    style: TextStyle(
                      color: _readerText,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0x55393247)),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Text(
                        '這本 EPUB 沒有提供可用目錄。',
                        style: TextStyle(color: _readerMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final item = entries[index];
                        final entry = item.entry;
                        final available = !entry.isExternal &&
                            entry.reference?.path != null;
                        final selected = entry.path == currentPath;
                        return Padding(
                          padding: EdgeInsets.only(left: item.depth * 14),
                          child: ListTile(
                            dense: true,
                            enabled: available,
                            selected: selected,
                            selectedTileColor: const Color(0x332A213B),
                            title: Text(
                              entry.label.isEmpty ? '未命名項目' : entry.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: selected
                                    ? _readerAccent
                                    : _readerText,
                                fontSize: 13,
                              ),
                            ),
                            onTap: available
                                ? () {
                                    Navigator.of(sheetContext).pop();
                                    unawaited(
                                      _runNavigation(
                                        () => session.goToTocEntry(entry),
                                      ),
                                    );
                                  }
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String? _bookmarkCfi(
    FrameEpubReaderSession session, {
    String? preferred,
  }) {
    final chapter = session.currentChapter;
    final epub = session.epub;
    final index = session.currentSpineIndex;
    if (chapter == null || epub == null || index == null) return null;

    for (final candidate in <String?>[
      preferred,
      _lastSavedCfi,
      session.initialCfi,
    ]) {
      final value = candidate?.trim() ?? '';
      if (value.isEmpty ||
          FrameEpubCfi.spineIndexFromCfi(epub, value) != index) {
        continue;
      }
      if (FrameEpubCfi.resolve(
            book: epub,
            document: chapter.document,
            cfi: value,
          ) !=
          null) {
        return value;
      }
    }

    XmlElement? anchor = session.initialAnchor ??
        FrameEpubCfi.anchorForFragment(
          chapter.document,
          session.currentFragment,
        );
    if (anchor == null) {
      for (final element
          in chapter.document.descendants.whereType<XmlElement>()) {
        if (element.name.local.toLowerCase() == 'body') {
          anchor = element;
          break;
        }
      }
    }
    anchor ??= chapter.document.rootElement;

    final point = FrameEpubCfi.firstTextPoint(anchor);
    if (point != null) {
      return FrameEpubCfi.create(
        book: epub,
        spineIndex: index,
        textNode: point.node,
        offset: point.offset,
      );
    }
    return FrameEpubCfi.createElement(
      book: epub,
      spineIndex: index,
      element: anchor,
    );
  }

  void _handleTextSelection(FrameEpubTextSelection? selection) {
    if (!mounted || selection == null) return;
    final session = _session;
    final chapter = session?.currentChapter;
    final spineIndex = session?.currentSpineIndex;
    final book = session?.epub;
    if (session == null ||
        chapter == null ||
        book == null ||
        spineIndex == null ||
        session.isFixedLayout) {
      return;
    }

    final cfi = FrameEpubCfi.createRange(
      book: book,
      spineIndex: spineIndex,
      startNode: selection.startNode,
      startOffset: selection.startOffset,
      endNode: selection.endNode,
      endOffset: selection.endOffset,
    );
    if (cfi == null) return;
    if (_selectedText?.cfi == cfi && _selectedText?.quote == selection.quote) {
      return;
    }
    setState(() {
      _selectedText = _SelectedEpubText(cfi: cfi, quote: selection.quote);
    });
  }

  Widget _selectionToolbar() => Material(
        color: _readerPanel,
        elevation: 10,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 2,
            children: [
              IconButton(
                tooltip: '黃色高亮',
                visualDensity: VisualDensity.compact,
                onPressed: () => _saveSelectedHighlight('yellow'),
                icon: const Icon(Icons.circle, color: Color(0xFFF2C94C), size: 19),
              ),
              IconButton(
                tooltip: '紫色高亮',
                visualDensity: VisualDensity.compact,
                onPressed: () => _saveSelectedHighlight('violet'),
                icon: const Icon(Icons.circle, color: Color(0xFFA78BFA), size: 19),
              ),
              IconButton(
                tooltip: '綠色高亮',
                visualDensity: VisualDensity.compact,
                onPressed: () => _saveSelectedHighlight('mint'),
                icon: const Icon(Icons.circle, color: Color(0xFF65C9A5), size: 19),
              ),
              IconButton(
                tooltip: '粉色高亮',
                visualDensity: VisualDensity.compact,
                onPressed: () => _saveSelectedHighlight('rose'),
                icon: const Icon(Icons.circle, color: Color(0xFFE88EAF), size: 19),
              ),
              TextButton.icon(
                onPressed: () => _saveSelectedHighlight('underline'),
                icon: const Icon(Icons.format_underline_rounded, size: 17),
                label: const Text('下劃線'),
                style: TextButton.styleFrom(
                  foregroundColor: _readerText,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              TextButton.icon(
                onPressed: _showSelectionNoteEditor,
                icon: const Icon(Icons.edit_note_rounded, size: 18),
                label: const Text('筆記'),
                style: TextButton.styleFrom(
                  foregroundColor: _readerText,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              IconButton(
                tooltip: '關閉選取工具列',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _selectedText = null),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
        ),
      );

  Future<void> _saveSelectedHighlight(String color) async {
    final selected = _selectedText;
    if (selected == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final annotation = FrameReaderAnnotation(
      id: 'flutter-highlight-${DateTime.now().microsecondsSinceEpoch}',
      bookId: widget.book.id,
      type: 'highlight',
      cfi: selected.cfi,
      quote: selected.quote,
      text: '',
      color: color,
      createdAt: now,
      updatedAt: now,
    );
    await _saveAnnotation(annotation);
  }

  Future<void> _showSelectionNoteEditor() => _editNote();

  Future<void> _editNote({FrameReaderAnnotation? annotation}) async {
    final selected = _selectedText;
    final session = _session;
    if (session == null || (annotation == null && selected == null)) return;

    final quote = annotation?.quote ?? selected?.quote ?? '';
    final controller = TextEditingController(text: annotation?.text ?? '');
    final value = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _readerPanel,
        title: Text(
          annotation == null ? '新增閱讀筆記' : '編輯閱讀筆記',
          style: const TextStyle(color: _readerText, fontSize: 17),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (quote.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x332B2635),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      quote,
                      style: const TextStyle(
                        color: _readerMuted,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 4,
                maxLines: 9,
                maxLength: 20000,
                style: const TextStyle(color: _readerText, fontSize: 14),
                decoration: InputDecoration(
                  hintText: '記下你的想法、解讀或補充資料……',
                  hintStyle: const TextStyle(color: _readerMuted),
                  filled: true,
                  fillColor: const Color(0x332B2635),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存筆記'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || value == null) return;
    final text = value.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('筆記內容不可為空白。')),
      );
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final saved = FrameReaderAnnotation(
      id: annotation?.id ??
          'flutter-note-${DateTime.now().microsecondsSinceEpoch}',
      bookId: widget.book.id,
      type: 'note',
      cfi: annotation?.cfi ?? selected!.cfi,
      quote: annotation?.quote ?? selected!.quote,
      text: text,
      color: annotation?.color ?? 'violet',
      createdAt: annotation?.createdAt ?? now,
      updatedAt: now,
    );
    await _saveAnnotation(saved);
  }

  Future<void> _saveAnnotation(FrameReaderAnnotation annotation) async {
    final session = _session;
    if (session == null) return;
    try {
      await session.saveAnnotation(annotation);
      if (!mounted) return;
      setState(() => _selectedText = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            annotation.type == 'highlight'
                ? (annotation.color == 'underline' ? '已新增下劃線。' : '已新增高亮。')
                : '筆記已保存。',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('標註保存失敗：$error')),
      );
    }
  }

  Future<void> _createBookmark() async {
    final session = _session;
    if (session == null ||
        session.status != FrameEpubReaderStatus.ready) {
      return;
    }

    final pendingCfi = _pendingCfi;
    await _flushReadingPosition();
    if (!mounted) return;

    final cfi = _bookmarkCfi(session, preferred: pendingCfi);
    if (cfi == null || cfi.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目前 EPUB 頁面無法建立書籤。')),
      );
      return;
    }
    if (session.annotations.any(
      (item) => item.type == 'bookmark' && item.cfi == cfi,
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('這個位置已經有書籤。')),
      );
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final annotation = FrameReaderAnnotation(
      id: 'flutter-bookmark-${DateTime.now().microsecondsSinceEpoch}',
      bookId: widget.book.id,
      type: 'bookmark',
      cfi: cfi,
      color: 'violet',
      createdAt: now,
    );
    try {
      await session.saveAnnotation(annotation);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已加入書籤。')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('書籤儲存失敗：$error')),
      );
    }
  }

  Future<void> _goToAnnotation(FrameReaderAnnotation annotation) async {
    final session = _session;
    if (session == null) return;
    await _flushReadingPosition();
    try {
      final moved = await session.goToCfi(annotation.cfi);
      if (!mounted || moved) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('這筆標註的位置無法在目前 EPUB 中定位。')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('無法跳轉至標註位置：$error')),
      );
    }
  }

  Future<void> _showAnnotations() async {
    final session = _session;
    if (session == null) return;
    var annotations = session.annotations;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _readerPanel,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.68,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                child: Row(
                  children: [
                    const Icon(Icons.bookmarks_outlined, color: _readerAccent),
                    const SizedBox(width: 10),
                    Text(
                      '筆記與書籤（${annotations.length}）',
                      style: const TextStyle(
                        color: _readerText,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0x55393247)),
              Expanded(
                child: annotations.isEmpty
                    ? const Center(
                        child: Text(
                          '目前沒有已保存的筆記或書籤。',
                          style: TextStyle(color: _readerMuted),
                        ),
                      )
                    : ListView.separated(
                        itemCount: annotations.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, color: Color(0x33393247)),
                        itemBuilder: (context, index) {
                          final annotation = annotations[index];
                          final title = switch (annotation.type) {
                            'bookmark' => '書籤',
                            'highlight' => '劃線',
                            _ => '筆記',
                          };
                          final detail = annotation.text.trim().isNotEmpty
                              ? annotation.text.trim()
                              : annotation.quote.trim();
                          return ListTile(
                            onTap: annotation.cfi.trim().isEmpty
                                ? null
                                : () {
                                    Navigator.of(sheetContext).pop();
                                    unawaited(_goToAnnotation(annotation));
                                  },
                            title: Text(
                              title,
                              style: const TextStyle(
                                color: _readerText,
                                fontSize: 13,
                              ),
                            ),
                            subtitle: Text(
                              detail.isEmpty ? '尚無文字內容' : detail,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _readerMuted,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (annotation.type == 'note')
                                  IconButton(
                                    tooltip: '編輯筆記',
                                    onPressed: () {
                                      Navigator.of(sheetContext).pop();
                                      unawaited(_editNote(annotation: annotation));
                                    },
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      color: _readerAccent,
                                      size: 18,
                                    ),
                                  ),
                                IconButton(
                                  tooltip: '刪除$title',
                                  onPressed: () async {
                                    try {
                                      await session.deleteAnnotation(annotation.id);
                                      if (!mounted) return;
                                      setSheetState(() {
                                        annotations = session.annotations;
                                      });
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('已刪除$title。')),
                                      );
                                    } on Object catch (error) {
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('刪除$title失敗：$error')),
                                      );
                                    }
                                  },
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    color: Color(0xFFBBAFCB),
                                    size: 19,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAppearance() async {
    final session = _session;
    if (session == null) return;
    var fontSize = _fontSize;
    var lineHeight = _lineHeight;
    var theme = _theme;
    var layoutMode = _layoutMode;

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: _readerPanel,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            18 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '閱讀外觀',
                style: TextStyle(
                  color: _readerText,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '字體大小',
                      style: TextStyle(color: _readerMuted),
                    ),
                  ),
                  Text(
                    '${fontSize.round()} px',
                    style: const TextStyle(color: _readerText),
                  ),
                ],
              ),
              Slider(
                value: fontSize,
                min: 14,
                max: 30,
                divisions: 16,
                activeColor: _readerAccent,
                onChanged: (value) =>
                    setSheetState(() => fontSize = value),
              ),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '行距',
                      style: TextStyle(color: _readerMuted),
                    ),
                  ),
                  Text(
                    lineHeight.toStringAsFixed(2),
                    style: const TextStyle(color: _readerText),
                  ),
                ],
              ),
              Slider(
                value: lineHeight,
                min: 1.2,
                max: 2.4,
                divisions: 12,
                activeColor: _readerAccent,
                onChanged: (value) =>
                    setSheetState(() => lineHeight = value),
              ),
              const SizedBox(height: 14),
              const Text(
                '版面模式',
                style: TextStyle(color: _readerMuted),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('連續捲動'),
                    selected: layoutMode == 'continuous',
                    onSelected: session.isFixedLayout
                        ? null
                        : (_) => setSheetState(
                              () => layoutMode = 'continuous',
                            ),
                  ),
                  ChoiceChip(
                    label: const Text('單頁分頁'),
                    selected: layoutMode == 'paginated',
                    onSelected: session.isFixedLayout
                        ? null
                        : (_) => setSheetState(
                              () => layoutMode = 'paginated',
                            ),
                  ),
                ],
              ),
              if (session.isFixedLayout)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '固定版面 EPUB 會依原始頁面顯示，這項設定不適用。',
                    style: TextStyle(color: _readerMuted, fontSize: 11),
                  ),
                ),
              const SizedBox(height: 14),
              const Text(
                '閱讀主題',
                style: TextStyle(color: _readerMuted),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('夜間'),
                    selected: theme == 'dark',
                    onSelected: (_) =>
                        setSheetState(() => theme = 'dark'),
                  ),
                  ChoiceChip(
                    label: const Text('紙本'),
                    selected: theme == 'sepia',
                    onSelected: (_) =>
                        setSheetState(() => theme = 'sepia'),
                  ),
                  ChoiceChip(
                    label: const Text('明亮'),
                    selected: theme == 'light',
                    onSelected: (_) =>
                        setSheetState(() => theme = 'light'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () async {
                  if (_layoutMode != layoutMode ||
                      _fontSize != fontSize ||
                      _lineHeight != lineHeight) {
                    final previousPageController = _chapterPageController;
                    _chapterPageController = PageController();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      previousPageController.dispose();
                    });
                  }
                  setState(() {
                    _fontSize = fontSize;
                    _lineHeight = lineHeight;
                    _theme = theme;
                    _layoutMode = layoutMode;
                  });
                  Navigator.of(sheetContext).pop();
                  try {
                    await session.saveAppearance({
                      'frameFlutterFontSize': fontSize,
                      'frameFlutterLineHeight': lineHeight,
                      'frameFlutterTheme': theme,
                      'frameFlutterLayoutMode': layoutMode,
                    });
                  } on Object catch (error) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('閱讀設定尚未同步：${error}')),
                    );
                  }
                },
                child: const Text('保存設定'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectedEpubText {
  const _SelectedEpubText({required this.cfi, required this.quote});

  final String cfi;
  final String quote;
}

class _FlattenedTocEntry {
  const _FlattenedTocEntry(this.entry, this.depth);

  final FrameEpubTocEntry entry;
  final int depth;
}
