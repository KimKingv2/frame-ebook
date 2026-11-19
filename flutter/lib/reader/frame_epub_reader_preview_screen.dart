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
import 'frame_epub_fixed_layout_long_strip.dart';
import 'frame_epub_resource_loader.dart';
import 'frame_epub_cfi.dart';
import 'frame_epub_chapter_view.dart';
import 'frame_epub_parser.dart';
import 'frame_epub_page_turn_surface.dart';
import 'frame_epub_reader_session.dart';
import 'frame_epub_reader_sidebar.dart';

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
  double _lineHeight = 1.65;
  double _fontScale = 1;
  String _fontFamilyPreference = 'original';
  String _fontWeightPreference = 'original';
  String _paragraphSpacingPreference = 'original';
  String _textAlignPreference = 'original';
  double _verticalMargin = 16;
  double _horizontalMarginPercent = 7;
  String _theme = 'light';
  String _comicReadingMode = 'paginated';
  String _comicPageLayout = '2';
  String _comicImageFit = 'fit-page';
  String _comicBackdrop = 'wood';
  Timer? _comicSpineNavigationTimer;

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
      final isLongStrip =
          session?.isFixedLayout == true && _comicReadingMode == 'scrolled';
      if (!isLongStrip) {
        final previousController = _chapterScrollController;
        final previousPageController = _chapterPageController;
        _chapterScrollController = ScrollController();
        _chapterPageController = PageController();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          previousController.dispose();
          previousPageController.dispose();
        });
      }
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
    _fontScale = value(appearance['fontScale'], 1)
        .clamp(.9, 1.3)
        .toDouble();
    _lineHeight = value(
      appearance['frameFlutterLineHeight'] ?? appearance['lineHeight'],
      1.65,
    ).clamp(1.2, 2.4).toDouble();
    _fontFamilyPreference =
        const {'original', 'serif', 'sans'}.contains(appearance['fontFamily'])
            ? appearance['fontFamily'].toString()
            : 'original';
    _fontWeightPreference =
        const {'original', 'normal', 'medium'}.contains(appearance['fontWeight'])
            ? appearance['fontWeight'].toString()
            : 'original';
    _paragraphSpacingPreference =
        const {'original', 'compact', 'standard', 'loose'}
                .contains(appearance['paragraphSpacing'])
            ? appearance['paragraphSpacing'].toString()
            : 'original';
    _textAlignPreference =
        const {'original', 'left', 'justify'}.contains(appearance['textAlign'])
            ? appearance['textAlign'].toString()
            : 'original';
    _verticalMargin = value(appearance['verticalMargin'], 16)
        .clamp(8, 64)
        .toDouble();
    _horizontalMarginPercent = value(appearance['horizontalMargin'], 7)
        .clamp(0, 20)
        .toDouble();

    final savedTheme = appearance['frameFlutterTheme']?.toString();
    final legacyTheme = appearance['theme']?.toString();
    final theme = savedTheme ??
        (legacyTheme == 'paper'
            ? 'light'
            : legacyTheme == 'night'
                ? 'dark'
                : legacyTheme);
    _theme = const {'dark', 'sepia', 'light'}.contains(theme) ? theme! : 'light';

    final savedLayout = appearance['frameFlutterLayoutMode']?.toString();
    final legacyReadingMode = appearance['readingMode']?.toString();
    final legacyPageLayout = appearance['pageLayout']?.toString();
    final layoutMode = savedLayout ??
        (legacyReadingMode == 'scrolled'
            ? 'continuous'
            : legacyPageLayout == '2'
                ? 'doublePage'
                : 'paginated');
    _layoutMode = const {'continuous', 'paginated', 'doublePage'}
            .contains(layoutMode)
        ? layoutMode
        : 'continuous';
    _comicReadingMode =
        const {'paginated', 'scrolled'}.contains(appearance['comicReadingMode'])
            ? appearance['comicReadingMode'].toString()
            : 'paginated';
    _comicPageLayout =
        const {'1', '2'}.contains(appearance['comicPageLayout'])
            ? appearance['comicPageLayout'].toString()
            : '2';
    _comicImageFit =
        const {'fit-page', 'fit-width'}.contains(appearance['comicImageFit'])
            ? appearance['comicImageFit'].toString()
            : 'fit-page';
    _comicBackdrop =
        const {'wood', 'linen', 'slate'}.contains(appearance['backdrop'])
            ? appearance['backdrop'].toString()
            : 'wood';
  }

  @override
  void dispose() {
    unawaited(_releaseResources());
    super.dispose();
  }

  Future<void> _releaseResources() async {
    await _flushReadingPosition();
    _progressSaveTimer?.cancel();
    _comicSpineNavigationTimer?.cancel();
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

  BoxDecoration get _comicBackdropDecoration {
    switch (_comicBackdrop) {
      case 'linen':
        return const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFC2B9AA),
              Color(0xFF8E877D),
              Color(0xFF68635D),
            ],
          ),
        );
      case 'slate':
        return const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-.55, -.8),
            radius: 1.35,
            colors: [
              Color(0xFF514A5D),
              Color(0xFF24232D),
              Color(0xFF15141C),
            ],
          ),
        );
      case 'wood':
      default:
        return const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF98704A),
              Color(0xFF63442F),
              Color(0xFF35251F),
            ],
          ),
        );
    }
  }

  bool _usesComicDoublePage(BuildContext context, FrameEpubReaderSession session) =>
      session.isFixedLayout &&
      _comicReadingMode == 'paginated' &&
      _comicPageLayout == '2' &&
      MediaQuery.sizeOf(context).width >= 760;

  int _comicPageStep(BuildContext context, FrameEpubReaderSession session) =>
      _usesComicDoublePage(context, session) ? 2 : 1;

  Future<bool> _navigateComicChapter(
    FrameEpubReaderSession session,
    int direction,
  ) async {
    final index = session.currentSpineIndex;
    final count = session.epub?.spine.length ?? 0;
    if (index == null || count <= 0) return false;
    final step = _comicPageStep(context, session);
    final target = (index + direction * step).clamp(0, count - 1).toInt();
    if (target == index) return false;
    _comicSpineNavigationTimer?.cancel();
    return session.goToSpineIndex(target);
  }

  void _scheduleComicSpineNavigation(
    FrameEpubReaderSession session,
    int targetIndex,
  ) {
    if (session.currentSpineIndex == targetIndex) return;
    _comicSpineNavigationTimer?.cancel();
    _comicSpineNavigationTimer = Timer(
      const Duration(milliseconds: 140),
      () {
        if (!mounted || session.currentSpineIndex == targetIndex) return;
        unawaited(session.goToSpineIndex(targetIndex));
      },
    );
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
            tooltip: '閱讀導覽',
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
                  paginated: _layoutMode != 'continuous' && !session.isFixedLayout,
                  fixedLayout: session.isFixedLayout,
                  isRightToLeft: session.epub?.pageProgressionDirection ==
                      FrameEpubPageProgressionDirection.rightToLeft,
                  selectionActive: _selectedText != null,
                  pageZoomed: _isFixedPageZoomed,
                  onPreviousChapter: session.currentSpineIndex != null &&
                          session.currentSpineIndex! >=
                              _comicPageStep(context, session)
                      ? () async {
                          if (session.isFixedLayout) {
                            await _navigateComicChapter(session, -1);
                          } else {
                            await _runNavigation(session.goToPreviousChapter);
                          }
                        }
                      : null,
                  onNextChapter: session.currentSpineIndex != null &&
                          session.currentSpineIndex! +
                                  _comicPageStep(context, session) <
                              spineCount
                      ? () async {
                          if (session.isFixedLayout) {
                            await _navigateComicChapter(session, 1);
                          } else {
                            await _runNavigation(session.goToNextChapter);
                          }
                        }
                      : null,
                  child: _buildReaderChapterContent(
                    context: context,
                    session: session,
                    chapter: chapter,
                    spineIndex: chapterIndex,
                    initialTextPoint: initialTextPoint,
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

  Widget _buildReaderChapterContent({
    required BuildContext context,
    required FrameEpubReaderSession session,
    required FrameEpubChapterDocument chapter,
    required int spineIndex,
    required FrameEpubCfiPoint? initialTextPoint,
  }) {
    final loader = session.resourceLoader!;
    final epub = session.epub!;
    final isRightToLeft =
        epub.pageProgressionDirection == FrameEpubPageProgressionDirection.rightToLeft;

    if (session.isFixedLayout) {
      if (_comicReadingMode == 'scrolled') {
        return FrameEpubFixedLayoutLongStrip(
          pageCount: epub.spine.length,
          currentPageIndex: spineIndex,
          cachePages: 1,
          onPageChanged: (index) =>
              _scheduleComicSpineNavigation(session, index),
          pageBuilder: (pageContext, index) => _FixedLayoutComicPage(
            key: ValueKey(epub.spine[index].item.path),
            resourceLoader: loader,
            spineItem: epub.spine[index],
            imageFit: 'fit-page',
            allowZoom: false,
            backgroundColor: _pageBackground,
            backdropDecoration: _comicBackdropDecoration,
            textColor: _pageText,
            linkColor: _pageLink,
          ),
        );
      }

      final currentPage = _FixedLayoutComicPage(
        key: ValueKey(epub.spine[spineIndex].item.path),
        resourceLoader: loader,
        spineItem: epub.spine[spineIndex],
        chapter: chapter,
        imageFit: _comicImageFit,
        allowZoom: true,
        backgroundColor: _pageBackground,
        backdropDecoration: _comicBackdropDecoration,
        textColor: _pageText,
        linkColor: _pageLink,
        onZoomChanged: (zoomed) {
          if (!mounted || _isFixedPageZoomed == zoomed) return;
          setState(() => _isFixedPageZoomed = zoomed);
        },
      );
      if (!_usesComicDoublePage(context, session)) return currentPage;

      final nextIndex = spineIndex + 1;
      final nextPage = nextIndex < epub.spine.length
          ? _FixedLayoutComicPage(
              key: ValueKey(epub.spine[nextIndex].item.path),
              resourceLoader: loader,
              spineItem: epub.spine[nextIndex],
              imageFit: _comicImageFit,
              allowZoom: true,
              backgroundColor: _pageBackground,
              backdropDecoration: _comicBackdropDecoration,
              textColor: _pageText,
              linkColor: _pageLink,
              onZoomChanged: (zoomed) {
                if (!mounted || _isFixedPageZoomed == zoomed) return;
                setState(() => _isFixedPageZoomed = zoomed);
              },
            )
          : DecoratedBox(
              decoration: _comicBackdropDecoration,
              child: const SizedBox.expand(),
            );
      final pages = isRightToLeft
          ? [Expanded(child: nextPage), const SizedBox(width: 8), Expanded(child: currentPage)]
          : [Expanded(child: currentPage), const SizedBox(width: 8), Expanded(child: nextPage)];
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: pages,
      );
    }

    return FrameEpubChapterView(
      key: ValueKey(chapter.resource.path),
      chapter: chapter,
      resourceLoader: loader,
      paginated: _layoutMode != 'continuous',
      doublePageSpread: _layoutMode == 'doublePage',
      isRightToLeft: isRightToLeft,
      pageController: _chapterPageController,
      annotations: session.annotations,
      spineIndex: spineIndex,
      initialAnchor: _initialAnchorFor(session),
      initialTextNode: initialTextPoint?.node,
      initialTextOffset: initialTextPoint?.offset,
      initialScrollFraction: _initialScrollFractionFor(session),
      scrollController: _chapterScrollController,
      onReadingPosition: _queueReadingPosition,
      onTextSelection: _handleTextSelection,
      backgroundColor: _pageBackground,
      textColor: _pageText,
      linkColor: _pageLink,
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      fontScale: _fontScale,
      fontFamilyPreference: _fontFamilyPreference,
      fontWeightPreference: _fontWeightPreference,
      paragraphSpacingPreference: _paragraphSpacingPreference,
      textAlignPreference: _textAlignPreference,
      verticalMargin: _verticalMargin,
      horizontalMarginPercent: _horizontalMarginPercent,
      onInternalLink: (href) {
        unawaited(_runNavigation(() => session.goToHref(href)));
      },
      onFootnote: _showFootnote,
    );
  }

  Widget _chapterControls(
    FrameEpubReaderSession session, {
    required int chapterIndex,
    required int spineCount,
  }) {
    final label = session.currentChapterLabel.trim();
    final pageStep = _comicPageStep(context, session);
    final canGoPrevious = chapterIndex > 0;
    final canGoNext = chapterIndex + pageStep < spineCount;
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
                    onPressed: canGoPrevious
                        ? () => unawaited(
                              session.isFixedLayout
                                  ? _navigateComicChapter(session, -1)
                                  : _runNavigation(session.goToPreviousChapter),
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
                    onPressed: canGoNext
                        ? () => unawaited(
                              session.isFixedLayout
                                  ? _navigateComicChapter(session, 1)
                                  : _runNavigation(session.goToNextChapter),
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

  Future<void> _showTableOfContents() =>
      _showReaderSidebar(initialTabIndex: 0);

  Future<void> _showAnnotations() =>
      _showReaderSidebar(initialTabIndex: 2);

  Future<void> _showReaderSidebar({required int initialTabIndex}) async {
    final session = _session;
    if (session == null) return;

    Widget buildSidebar(BuildContext routeContext) =>
        FrameEpubReaderSidebar(
          toc: session.toc,
          currentPath: session.currentSpineIndex == null
              ? null
              : session.epub?.spine[session.currentSpineIndex!].item.path,
          annotations: session.annotations,
          initialTabIndex: initialTabIndex,
          onClose: () => Navigator.of(routeContext).pop(),
          onSelectToc: (entry) {
            Navigator.of(routeContext).pop();
            unawaited(
              _runNavigation(() => session.goToTocEntry(entry)),
            );
          },
          onOpenAnnotation: (annotation) {
            Navigator.of(routeContext).pop();
            unawaited(_goToAnnotation(annotation));
          },
          onEditNote: (annotation) {
            Navigator.of(routeContext).pop();
            unawaited(_editNote(annotation: annotation));
          },
          onDeleteAnnotation: (annotation) async {
            try {
              await session.deleteAnnotation(annotation.id);
              if (!mounted) return false;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已刪除標註。')),
              );
              return true;
            } on Object catch (error) {
              if (!mounted) return false;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('刪除標註失敗：$error')),
              );
              return false;
            }
          },
        );

    final screenSize = MediaQuery.sizeOf(context);
    if (screenSize.width >= 840) {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '關閉閱讀導覽',
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (dialogContext, animation, secondaryAnimation) {
          final width =
              (MediaQuery.sizeOf(dialogContext).width * .42)
                  .clamp(340.0, 460.0)
                  .toDouble();
          return Align(
            alignment: Alignment.centerRight,
            child: SafeArea(
              child: SizedBox(
                width: width,
                height: double.infinity,
                child: buildSidebar(dialogContext),
              ),
            ),
          );
        },
        transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
          final position = Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).chain(
            CurveTween(curve: Curves.easeOutCubic),
          ).animate(animation);
          return SlideTransition(position: position, child: child);
        },
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _readerPanel,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .84,
        child: buildSidebar(sheetContext),
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

  Widget _appearanceDropdown({
    required String label,
    required String value,
    required List<({String value, String label})> options,
    required ValueChanged<String> onChanged,
    bool enabled = true,
  }) {
    return SizedBox(
      width: 148,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: _readerMuted, fontSize: 11)),
          DropdownButton<String>(
            value: value,
            onChanged: enabled ? (next) {
              if (next != null) onChanged(next);
            } : null,
            isExpanded: true,
            dropdownColor: _readerPanel,
            style: const TextStyle(color: _readerText, fontSize: 12),
            underline: const SizedBox.shrink(),
            items: [
              for (final option in options)
                DropdownMenuItem<String>(
                  value: option.value,
                  child: Text(option.label, overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showAppearance() async {
    final session = _session;
    if (session == null) return;
    var fontSize = _fontSize;
    var lineHeight = _lineHeight;
    var fontScale = _fontScale;
    var fontFamilyPreference = _fontFamilyPreference;
    var fontWeightPreference = _fontWeightPreference;
    var paragraphSpacingPreference = _paragraphSpacingPreference;
    var textAlignPreference = _textAlignPreference;
    var verticalMargin = _verticalMargin;
    var horizontalMarginPercent = _horizontalMarginPercent;
    var theme = _theme;
    var layoutMode = _layoutMode;
    var comicReadingMode = _comicReadingMode;
    var comicPageLayout = _comicPageLayout;
    var comicImageFit = _comicImageFit;
    var comicBackdrop = _comicBackdrop;

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
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * .86,
            ),
            child: SingleChildScrollView(
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
              const SizedBox(height: 12),
              const Text(
                '文字排版',
                style: TextStyle(color: _readerMuted),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  _appearanceDropdown(
                    label: '字級比例',
                    value: fontScale.toStringAsFixed(1),
                    options: const [
                      (value: '0.9', label: '偏小 90%'),
                      (value: '1.0', label: '標準 100%'),
                      (value: '1.1', label: '稍大 110%'),
                      (value: '1.2', label: '大字 120%'),
                      (value: '1.3', label: '特大 130%'),
                    ],
                    onChanged: (v) => setSheetState(() => fontScale = double.parse(v)),
                  ),
                  _appearanceDropdown(
                    label: '字體',
                    value: fontFamilyPreference,
                    options: const [
                      (value: 'original', label: '原書字體'),
                      (value: 'serif', label: '明體'),
                      (value: 'sans', label: '黑體'),
                    ],
                    onChanged: (v) => setSheetState(() => fontFamilyPreference = v),
                  ),
                  _appearanceDropdown(
                    label: '字重',
                    value: fontWeightPreference,
                    options: const [
                      (value: 'original', label: '原書設定'),
                      (value: 'normal', label: '標準 400'),
                      (value: 'medium', label: '稍厚 500'),
                    ],
                    onChanged: (v) => setSheetState(() => fontWeightPreference = v),
                  ),
                  _appearanceDropdown(
                    label: '段落間距',
                    value: paragraphSpacingPreference,
                    options: const [
                      (value: 'original', label: '原書設定'),
                      (value: 'compact', label: '緊湊'),
                      (value: 'standard', label: '舒適'),
                      (value: 'loose', label: '寬鬆'),
                    ],
                    onChanged: (v) => setSheetState(() => paragraphSpacingPreference = v),
                  ),
                  _appearanceDropdown(
                    label: '文字對齊',
                    value: textAlignPreference,
                    options: const [
                      (value: 'original', label: '原書設定'),
                      (value: 'left', label: '靠左對齊'),
                      (value: 'justify', label: '左右對齊'),
                    ],
                    onChanged: (v) => setSheetState(() => textAlignPreference = v),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('頁面留白', style: TextStyle(color: _readerMuted)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  _appearanceDropdown(
                    label: '上下留白',
                    value: verticalMargin.round().toString(),
                    options: const [
                      (value: '8', label: '窄 8 px'),
                      (value: '16', label: '標準 16 px'),
                      (value: '24', label: '寬 24 px'),
                      (value: '32', label: '更寬 32 px'),
                      (value: '40', label: '寬裕 40 px'),
                      (value: '48', label: '大留白 48 px'),
                      (value: '64', label: '極寬 64 px'),
                    ],
                    onChanged: (v) => setSheetState(() => verticalMargin = double.parse(v)),
                  ),
                  _appearanceDropdown(
                    label: '左右外側留白',
                    value: horizontalMarginPercent.round().toString(),
                    options: const [
                      (value: '0', label: '0%'),
                      (value: '2', label: '2%'),
                      (value: '4', label: '4%'),
                      (value: '7', label: '7%'),
                      (value: '10', label: '10%'),
                      (value: '13', label: '13%'),
                      (value: '16', label: '16%'),
                      (value: '20', label: '20%'),
                    ],
                    onChanged: (v) => setSheetState(() => horizontalMarginPercent = double.parse(v)),
                  ),
                ],
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
                  ChoiceChip(
                    label: const Text('雙頁跨頁'),
                    selected: layoutMode == 'doublePage',
                    onSelected: session.isFixedLayout
                        ? null
                        : (_) => setSheetState(
                              () => layoutMode = 'doublePage',
                            ),
                  ),
                ],
              ),
              if (!session.isFixedLayout)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '雙頁模式會在寬螢幕並排顯示；窄螢幕會自動退回單頁。',
                    style: TextStyle(color: _readerMuted, fontSize: 11),
                  ),
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
                '漫畫與圖像',
                style: TextStyle(color: _readerMuted),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  _appearanceDropdown(
                    label: '漫畫閱讀模式',
                    value: comicReadingMode,
                    options: const [
                      (value: 'paginated', label: '分頁翻頁'),
                      (value: 'scrolled', label: '直式長卷'),
                    ],
                    onChanged: (value) =>
                        setSheetState(() => comicReadingMode = value),
                    enabled: session.isFixedLayout,
                  ),
                  _appearanceDropdown(
                    label: '頁面編排',
                    value: comicPageLayout,
                    options: const [
                      (value: '1', label: '單頁'),
                      (value: '2', label: '雙頁優先'),
                    ],
                    onChanged: (value) =>
                        setSheetState(() => comicPageLayout = value),
                    enabled: session.isFixedLayout &&
                        comicReadingMode == 'paginated',
                  ),
                  _appearanceDropdown(
                    label: '圖片縮放',
                    value: comicImageFit,
                    options: const [
                      (value: 'fit-page', label: '適合整頁'),
                      (value: 'fit-width', label: '適合寬度'),
                    ],
                    onChanged: (value) =>
                        setSheetState(() => comicImageFit = value),
                    enabled: session.isFixedLayout &&
                        comicReadingMode == 'paginated',
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  !session.isFixedLayout
                      ? '固定版面 EPUB 載入後才會啟用漫畫排版選項。'
                      : comicReadingMode == 'scrolled'
                          ? '直式長卷會按需載入章節，垂直連續閱讀；圖片縮放固定為適合整頁。'
                          : comicPageLayout == '2'
                              ? '雙頁優先會在寬度足夠時並排，窄螢幕自動切回單頁。'
                              : '單頁翻頁模式，每次顯示一個固定版面。',
                  style: const TextStyle(color: _readerMuted, fontSize: 11),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '閱讀背景',
                style: TextStyle(color: _readerMuted),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('木質桌面'),
                    selected: comicBackdrop == 'wood',
                    onSelected: (_) =>
                        setSheetState(() => comicBackdrop = 'wood'),
                  ),
                  ChoiceChip(
                    label: const Text('亞麻暖灰'),
                    selected: comicBackdrop == 'linen',
                    onSelected: (_) =>
                        setSheetState(() => comicBackdrop = 'linen'),
                  ),
                  ChoiceChip(
                    label: const Text('深色石板'),
                    selected: comicBackdrop == 'slate',
                    onSelected: (_) =>
                        setSheetState(() => comicBackdrop = 'slate'),
                  ),
                ],
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
                    label: const Text('暖紙'),
                    selected: theme == 'sepia',
                    onSelected: (_) =>
                        setSheetState(() => theme = 'sepia'),
                  ),
                  ChoiceChip(
                    label: const Text('紙白'),
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
                      _lineHeight != lineHeight ||
                      _fontScale != fontScale ||
                      _fontFamilyPreference != fontFamilyPreference ||
                      _fontWeightPreference != fontWeightPreference ||
                      _paragraphSpacingPreference != paragraphSpacingPreference ||
                      _textAlignPreference != textAlignPreference ||
                      _verticalMargin != verticalMargin ||
                      _horizontalMarginPercent != horizontalMarginPercent) {
                    final previousPageController = _chapterPageController;
                    _chapterPageController = PageController();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      previousPageController.dispose();
                    });
                  }
                  setState(() {
                    _fontSize = fontSize;
                    _lineHeight = lineHeight;
                    _fontScale = fontScale;
                    _fontFamilyPreference = fontFamilyPreference;
                    _fontWeightPreference = fontWeightPreference;
                    _paragraphSpacingPreference = paragraphSpacingPreference;
                    _textAlignPreference = textAlignPreference;
                    _verticalMargin = verticalMargin;
                    _horizontalMarginPercent = horizontalMarginPercent;
                    _theme = theme;
                    _layoutMode = layoutMode;
                    _comicReadingMode = comicReadingMode;
                    _comicPageLayout = comicPageLayout;
                    _comicImageFit = comicImageFit;
                    _comicBackdrop = comicBackdrop;
                  });
                  Navigator.of(sheetContext).pop();
                  try {
                    await session.saveAppearance({
                      // Legacy D1 keys keep Flutter and the existing reader in sync.
                      'fontScale': fontScale.toString(),
                      'lineHeight': lineHeight.toString(),
                      'verticalMargin': verticalMargin.round().toString(),
                      'horizontalMargin': horizontalMarginPercent.round().toString(),
                      'fontFamily': fontFamilyPreference,
                      'fontWeight': fontWeightPreference,
                      'paragraphSpacing': paragraphSpacingPreference,
                      'textAlign': textAlignPreference,
                      'readingMode': layoutMode == 'continuous' ? 'scrolled' : 'paginated',
                      'pageLayout': layoutMode == 'doublePage' ? '2' : '1',
                      'theme': theme == 'light' ? 'paper' : theme == 'dark' ? 'night' : 'sepia',
                      'frameFlutterFontSize': fontSize,
                      'frameFlutterLineHeight': lineHeight,
                      'frameFlutterTheme': theme,
                      'frameFlutterLayoutMode': layoutMode,
                      'comicReadingMode': comicReadingMode,
                      'comicPageLayout': comicPageLayout,
                      'comicImageFit': comicImageFit,
                      'backdrop': comicBackdrop,
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
        ),
      ),
    );
  }
}

class _FixedLayoutComicPage extends StatefulWidget {
  const _FixedLayoutComicPage({
    required this.resourceLoader,
    required this.spineItem,
    required this.imageFit,
    required this.allowZoom,
    required this.backgroundColor,
    required this.backdropDecoration,
    required this.textColor,
    required this.linkColor,
    this.chapter,
    this.onZoomChanged,
    super.key,
  });

  final FrameEpubResourceLoader resourceLoader;
  final FrameEpubSpineItem spineItem;
  final FrameEpubChapterDocument? chapter;
  final String imageFit;
  final bool allowZoom;
  final Color backgroundColor;
  final BoxDecoration backdropDecoration;
  final Color textColor;
  final Color linkColor;
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<_FixedLayoutComicPage> createState() => _FixedLayoutComicPageState();
}

class _FixedLayoutComicPageState extends State<_FixedLayoutComicPage> {
  late Future<FrameEpubChapterDocument> _chapterFuture;

  @override
  void initState() {
    super.initState();
    _chapterFuture = _loadChapter();
  }

  Future<FrameEpubChapterDocument> _loadChapter() =>
      widget.chapter != null
          ? Future.value(widget.chapter)
          : widget.resourceLoader.loadChapter(widget.spineItem);

  @override
  void didUpdateWidget(covariant _FixedLayoutComicPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spineItem.item.path != widget.spineItem.item.path ||
        !identical(oldWidget.resourceLoader, widget.resourceLoader) ||
        oldWidget.chapter != widget.chapter) {
      _chapterFuture = _loadChapter();
    }
  }

  Widget _buildChapter(FrameEpubChapterDocument chapter) =>
      FrameEpubChapterView(
        key: ValueKey(widget.spineItem.item.path),
        chapter: chapter,
        resourceLoader: widget.resourceLoader,
        fixedLayout: true,
        fixedLayoutImageFit: widget.imageFit,
        fixedLayoutAllowZoom: widget.allowZoom,
        fixedLayoutBackdropDecoration: widget.backdropDecoration,
        backgroundColor: widget.backgroundColor,
        textColor: widget.textColor,
        linkColor: widget.linkColor,
        onPageZoomChanged: widget.onZoomChanged,
      );

  @override
  Widget build(BuildContext context) {
    final supplied = widget.chapter;
    if (supplied != null) return _buildChapter(supplied);
    return FutureBuilder<FrameEpubChapterDocument>(
      future: _chapterFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '漫畫頁載入失敗：${snapshot.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFFC1C1), fontSize: 12),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(
              color: Color(0xFFC5ADFF),
              strokeWidth: 1.8,
            ),
          );
        }
        return _buildChapter(snapshot.data!);
      },
    );
  }
}

class _SelectedEpubText {
  const _SelectedEpubText({required this.cfi, required this.quote});

  final String cfi;
  final String quote;
}
