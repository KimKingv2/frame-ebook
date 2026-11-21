import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xml/xml.dart';

import '../core/frame_api_scope.dart';
import '../core/frame_app_config.dart';
import '../library/frame_book.dart';
import '../library/frame_reader_repository.dart';
import '../transport/frame_cloud_file_source.dart';
import '../transport/frame_file_source.dart';
import '../transport/frame_file_source_factory.dart';
import '../transport/frame_local_openlist_file_source.dart';
import 'frame_epub_footnote.dart';
import 'frame_epub_fixed_layout_long_strip.dart';
import 'frame_epub_resource_loader.dart';
import 'frame_epub_cfi.dart';
import 'frame_epub_chapter_view.dart';
import 'frame_epub_parser.dart';
import 'frame_epub_page_turn_surface.dart';
import 'frame_epub_reader_session.dart';
import 'frame_reading_time_tracker.dart';
import 'frame_epub_reader_sidebar.dart';
import 'frame_epub_note_editor_dialog.dart';

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
    extends State<FrameEpubReaderPreviewScreen>
    with WidgetsBindingObserver, FullScreenListener {
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
  FrameReadingTimeTracker? _readingTimeTracker;
  int _readingSeconds = 0;
  bool _isImmersive = false;
  bool _isSidebarVisible = true;
  bool _bookmarkBusy = false;
  bool _fullScreenListenerRegistered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      FullScreen.addListener(this);
      _fullScreenListenerRegistered = true;
      _isImmersive = FullScreen.isFullScreen;
    } on Object {
      // Widget tests and embedded hosts may mount this screen without running
      // the app-level fullscreen plugin bootstrap. Keep normal reader mode
      // available; the production app initializes the plugin in main().
      _fullScreenListenerRegistered = false;
      _isImmersive = false;
    }
    HardwareKeyboard.instance.addHandler(_handleReadingKeyEvent);
    _chapterScrollController = ScrollController();
    _chapterPageController = PageController();
  }

  @override
  void onFullScreenChanged(bool enabled, SystemUiMode? systemUiMode) {
    if (!mounted || _isImmersive == enabled) return;
    setState(() => _isImmersive = enabled);
  }

  void _toggleImmersiveMode() {
    try {
      FullScreen.setFullScreen(!_isImmersive);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('無法切換全螢幕：$error')),
      );
    }
  }

  void _exitImmersiveMode() {
    if (!_isImmersive) return;
    try {
      FullScreen.setFullScreen(false);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('無法退出全螢幕：$error')),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final tracker = _readingTimeTracker;
    if (tracker == null) return;
    unawaited(tracker.setForeground(state == AppLifecycleState.resumed));
  }

  void _startReadingTimeTracking(FrameEpubReaderSession session) {
    if (_readingTimeTracker != null) return;
    final tracker = FrameReadingTimeTracker(
      book: widget.book,
      repository: session.repository,
      onUpdate: (seconds) {
        if (!mounted) return;
        setState(() => _readingSeconds = seconds);
      },
      onError: (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('閱讀時光尚未同步：$error')),
        );
      },
    );
    _readingTimeTracker = tracker;
    unawaited(
      tracker.start(
        foreground: WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      ).catchError((Object error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('無法啟動閱讀時光記錄：$error')),
        );
      }),
    );
  }

  bool _handleReadingKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      _recordReadingActivity();
      if (event.logicalKey == LogicalKeyboardKey.escape && _isImmersive) {
        _exitImmersiveMode();
        return true;
      }
    }
    return false;
  }

  void _recordReadingActivity() {
    _readingTimeTracker?.activity();
  }

  String _readingDurationLabel(int seconds) {
    final safe = seconds < 0 ? 0 : seconds;
    final hours = safe ~/ 3600;
    final minutes = (safe % 3600) ~/ 60;
    final remainder = safe % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${remainder.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
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
      final source = widget.fileSource ?? _createFileSource();
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

  FrameFileSource _createFileSource() {
    if (widget.book.provider == 'local') {
      final client = FrameApiScope.localSessionOf(context)?.client;
      if (client == null || !client.isAuthenticated) {
        throw StateError(
          '本地 OpenList 登入只保留在目前工作階段記憶體中，請返回「檔案瀏覽」重新登入。',
        );
      }
      return FrameLocalOpenListFileSource(client: client);
    }
    return createFrameFileSource(baseUri: FrameAppConfig.apiBaseUri);
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
    if (session?.status == FrameEpubReaderStatus.ready) {
      _startReadingTimeTracking(session!);
      if (!_appearanceInitialized) {
        _restoreAppearance(session.readerState.appearance);
        _appearanceInitialized = true;
      }
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
    WidgetsBinding.instance.removeObserver(this);
    try {
      if (_fullScreenListenerRegistered) FullScreen.removeListener(this);
      if (FullScreen.isFullScreen) FullScreen.setFullScreen(false);
    } on Object {
      // The plugin may never have been initialized in an embedding/test host.
    }
    HardwareKeyboard.instance.removeHandler(_handleReadingKeyEvent);
    unawaited(_releaseResources());
    super.dispose();
  }

  Future<void> _releaseResources() async {
    final readingTracker = _readingTimeTracker;
    _readingTimeTracker = null;
    if (readingTracker != null) await readingTracker.stop();
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
    final session = _session;
    final previousCfi =
        _lastVisibleCfi ?? _pendingCfi ?? _lastSavedCfi ?? session?.initialCfi;
    final wasBookmarked =
        findFrameBookmarkAtCfi(session?.annotations ?? const [], previousCfi) !=
            null;
    _lastVisibleCfi = cfi;
    final isBookmarked =
        findFrameBookmarkAtCfi(session?.annotations ?? const [], cfi) != null;
    if (wasBookmarked != isBookmarked && mounted) {
      setState(() {});
    }
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
      session.epub?.spread.toLowerCase() != 'none' &&
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

  int _readingProgressPercent(FrameEpubReaderSession? session) {
    final pending = _pendingPercent;
    if (pending != null) return pending.clamp(0, 100).toInt();
    final saved = session?.readerState.progress['percent'];
    if (saved is num) return saved.round().clamp(0, 100).toInt();
    return session?.chapterProgressPercent ?? 0;
  }

  double _currentChapterFraction(FrameEpubReaderSession session) {
    if (session.isFixedLayout) return 1;
    if (_layoutMode == 'continuous') {
      final controller = _chapterScrollController;
      if (!controller.hasClients) return 0;
      final position = controller.position;
      if (!position.hasContentDimensions ||
          position.maxScrollExtent <= position.minScrollExtent) {
        return 0;
      }
      return ((position.pixels - position.minScrollExtent) /
              (position.maxScrollExtent - position.minScrollExtent))
          .clamp(0.0, 1.0)
          .toDouble();
    }

    final controller = _chapterPageController;
    if (!controller.hasClients) return 0;
    final position = controller.position;
    if (!position.hasContentDimensions ||
        !position.viewportDimension.isFinite ||
        position.viewportDimension <= 0) {
      return 0;
    }
    final lastPage =
        (position.maxScrollExtent / position.viewportDimension).round();
    if (lastPage <= 0) return 1;
    return ((controller.page ?? 0) / lastPage)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  bool _canTurnReaderPage(
    FrameEpubReaderSession session, {
    required bool forward,
  }) {
    final index = session.currentSpineIndex;
    final count = session.epub?.spine.length ?? 0;
    if (index == null || count <= 0) return false;

    if (session.isFixedLayout) {
      final step = _comicPageStep(context, session);
      return forward ? index + step < count : index > 0;
    }

    final hasAdjacentChapter = forward ? index + 1 < count : index > 0;
    if (_layoutMode == 'continuous') {
      final controller = _chapterScrollController;
      if (!controller.hasClients) return hasAdjacentChapter;
      final position = controller.position;
      if (!position.hasContentDimensions) return hasAdjacentChapter;
      final hasLocalPage = forward
          ? position.pixels < position.maxScrollExtent - 1
          : position.pixels > position.minScrollExtent + 1;
      return hasLocalPage || hasAdjacentChapter;
    }

    final controller = _chapterPageController;
    if (!controller.hasClients) return hasAdjacentChapter;
    final position = controller.position;
    if (!position.hasContentDimensions ||
        !position.viewportDimension.isFinite ||
        position.viewportDimension <= 0) {
      return hasAdjacentChapter;
    }
    final current = (controller.page ?? 0).round();
    final lastPage =
        (position.maxScrollExtent / position.viewportDimension).round();
    final hasLocalPage = forward ? current < lastPage : current > 0;
    return hasLocalPage || hasAdjacentChapter;
  }

  Future<void> _turnReaderPage(
    FrameEpubReaderSession session, {
    required bool forward,
  }) async {
    if (session.isFixedLayout) {
      await _navigateComicChapter(session, forward ? 1 : -1);
      return;
    }

    if (_layoutMode == 'continuous') {
      final controller = _chapterScrollController;
      if (!controller.hasClients) return;
      final position = controller.position;
      if (!position.hasContentDimensions ||
          !position.viewportDimension.isFinite ||
          position.viewportDimension <= 0) {
        return;
      }
      final atBoundary = forward
          ? position.pixels >= position.maxScrollExtent - 1
          : position.pixels <= position.minScrollExtent + 1;
      if (atBoundary) {
        await _runNavigation(
          forward ? session.goToNextChapter : session.goToPreviousChapter,
        );
        return;
      }
      final delta = position.viewportDimension * .86;
      final target = (position.pixels + (forward ? delta : -delta))
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      await controller.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return;
    }

    final controller = _chapterPageController;
    if (!controller.hasClients) return;
    final position = controller.position;
    if (!position.hasContentDimensions ||
        !position.viewportDimension.isFinite ||
        position.viewportDimension <= 0) {
      return;
    }
    final current = (controller.page ?? 0).round();
    final lastPage =
        (position.maxScrollExtent / position.viewportDimension).round();
    final atBoundary = forward ? current >= lastPage : current <= 0;
    if (atBoundary) {
      await _runNavigation(
        forward ? session.goToNextChapter : session.goToPreviousChapter,
      );
      return;
    }
    await controller.animateToPage(
      current + (forward ? 1 : -1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _readerQuickAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    required bool selected,
  }) {
    final iconColor = onPressed == null
        ? const Color(0xFF746C80)
        : selected
            ? _readerAccent
            : const Color(0xFFDCD2ED);
    return Container(
      width: 36,
      height: 32,
      margin: const EdgeInsets.only(left: 6),
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFF30263F)
            : const Color(0xFF2D253C),
        border: Border.all(
          color: selected
              ? const Color(0x887F68AA)
              : const Color(0x443F3552),
        ),
        borderRadius: BorderRadius.circular(7),
      ),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 36, height: 32),
        icon: Icon(icon, size: 18, color: iconColor),
      ),
    );
  }

  Widget _buildReaderHeader(
    FrameEpubReaderSession? session, {
    required bool wide,
  }) {
    final ready = session?.status == FrameEpubReaderStatus.ready;
    final percent = _readingProgressPercent(session);
    final currentBookmarkCfi = ready
        ? _bookmarkCfi(
            session!,
            preferred: _pendingCfi ?? _lastVisibleCfi,
          )
        : null;
    final bookmarked = findFrameBookmarkAtCfi(
          session?.annotations ?? const [],
          currentBookmarkCfi,
        ) !=
        null;

    Widget actionButtons() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _readerQuickAction(
              tooltip: bookmarked ? '移除目前位置的書籤' : '加入目前位置的書籤',
              icon: bookmarked
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_add_outlined,
              selected: bookmarked,
              onPressed: ready && !_bookmarkBusy ? _toggleBookmark : null,
            ),
            _readerQuickAction(
              tooltip: wide
                  ? (_isSidebarVisible ? '隱藏閱讀導覽' : '顯示閱讀導覽')
                  : '目錄、筆記與書籤',
              icon: Icons.menu_book_outlined,
              selected: wide && _isSidebarVisible,
              onPressed: !ready
                  ? null
                  : () {
                      if (wide) {
                        setState(
                          () => _isSidebarVisible = !_isSidebarVisible,
                        );
                      } else {
                        unawaited(_showTableOfContents());
                      }
                    },
            ),
            _readerQuickAction(
              tooltip: '閱讀設定',
              icon: Icons.tune_rounded,
              selected: false,
              onPressed: ready ? _showAppearance : null,
            ),
            _readerQuickAction(
              tooltip: '進入沉浸式全螢幕',
              icon: Icons.fullscreen_rounded,
              selected: false,
              onPressed: ready ? _toggleImmersiveMode : null,
            ),
          ],
        );

    Widget titleBlock() => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'NOW READING',
                style: TextStyle(
                  color: Color(0xFF887A9C),
                  fontSize: 8,
                  letterSpacing: 1.7,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _bookTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _readerText,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                [
                  widget.book.author.trim().isEmpty
                      ? widget.book.fileName
                      : widget.book.author.trim(),
                  if (_readingTimeTracker != null)
                    '本次閱讀 ${_readingDurationLabel(_readingSeconds)}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _readerMuted,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        );

    Widget progressBlock({bool compact = false}) => Column(
          crossAxisAlignment:
              compact ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '全書進度  $percent%',
              style: const TextStyle(
                color: _readerText,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: compact ? double.infinity : 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: ready ? percent / 100 : 0,
                  minHeight: 4,
                  color: _readerAccent,
                  backgroundColor: const Color(0xFF423A50),
                ),
              ),
            ),
          ],
        );

    return Container(
      padding: EdgeInsets.fromLTRB(wide ? 22 : 10, 12, wide ? 22 : 8, 13),
      decoration: const BoxDecoration(
        color: _readerChrome,
        border: Border(
          bottom: BorderSide(color: Color(0x332F293B), width: 1),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 660;
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: '返回書架',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: _readerMuted,
                      ),
                    ),
                    titleBlock(),
                    const SizedBox(width: 8),
                    progressBlock(),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: actionButtons(),
                ),
              ],
            );
          }

          return Row(
            children: [
              IconButton(
                tooltip: '返回書架',
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(
                  Icons.arrow_back_rounded,
                  color: _readerMuted,
                ),
              ),
              const SizedBox(width: 7),
              titleBlock(),
              const SizedBox(width: 20),
              progressBlock(),
              const SizedBox(width: 12),
              actionButtons(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReaderFrame(Widget child, {required bool wide}) => Container(
        margin: EdgeInsets.fromLTRB(wide ? 0 : 2, 0, 2, 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: _readerPanel,
          border: Border.all(color: const Color(0x33CFBEEF)),
          borderRadius: BorderRadius.circular(13),
          boxShadow: const [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 22,
              offset: Offset(0, 9),
            ),
          ],
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return PopScope<Object?>(
      canPop: !_isImmersive,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _exitImmersiveMode();
      },
      child: Listener(
        onPointerDown: (_) => _recordReadingActivity(),
        onPointerSignal: (_) => _recordReadingActivity(),
        child: Scaffold(
          backgroundColor: _readerChrome,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (_isImmersive) return _buildBody(session);

                final wide = constraints.maxWidth >= 960;
                final showDesktopSidebar = wide &&
                    _isSidebarVisible &&
                    session?.status == FrameEpubReaderStatus.ready;
                return Column(
                  children: [
                    _buildReaderHeader(session, wide: wide),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 18 : 8,
                          10,
                          wide ? 18 : 8,
                          8,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (showDesktopSidebar) ...[
                              SizedBox(
                                width: 250,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: _readerPanel,
                                    border: Border.all(
                                      color: const Color(0x33C1AAEE),
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: _buildReaderSidebar(
                                    session!,
                                    initialTabIndex: 0,
                                    desktopLayout: true,
                                    onClose: () => setState(
                                      () => _isSidebarVisible = false,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                            ],
                            Expanded(
                              child: _buildReaderFrame(
                                _buildBody(session),
                                wide: wide,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
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
                  immersive: _isImmersive,
                  onToggleImmersive: _toggleImmersiveMode,
                  onExitImmersive: _exitImmersiveMode,
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
        _chapterControls(session),
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

  Widget _chapterControls(FrameEpubReaderSession session) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _chapterScrollController,
        _chapterPageController,
      ]),
      builder: (context, child) {
        final chapterPercent =
            (_currentChapterFraction(session) * 100).round().clamp(0, 100);
        final bookPercent = _readingProgressPercent(session);
        final canGoPrevious =
            _canTurnReaderPage(session, forward: false);
        final canGoNext = _canTurnReaderPage(session, forward: true);
        final label = session.currentChapterLabel.trim();

        return Material(
          color: _readerPanel,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(7, 7, 7, 9),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: canGoPrevious
                        ? () => unawaited(
                              _turnReaderPage(session, forward: false),
                            )
                        : null,
                    icon: const Icon(Icons.chevron_left_rounded, size: 18),
                    label: const Text('上一頁'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _readerText,
                      side: const BorderSide(color: Color(0x44393247)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 9,
                      ),
                      textStyle: const TextStyle(fontSize: 10),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                label.isEmpty ? '未命名章節' : label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: _readerText,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            Text(
                              '本章 $chapterPercent%',
                              style: const TextStyle(
                                color: _readerMuted,
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: chapterPercent / 100,
                            minHeight: 3,
                            color: _readerAccent,
                            backgroundColor: const Color(0xFF423A50),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '全書進度',
                                style: TextStyle(
                                  color: _readerMuted,
                                  fontSize: 9,
                                ),
                              ),
                            ),
                            Text(
                              '$bookPercent%',
                              style: const TextStyle(
                                color: _readerText,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: bookPercent / 100,
                            minHeight: 4,
                            color: _readerAccent,
                            backgroundColor: const Color(0xFF423A50),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: canGoNext
                        ? () => unawaited(
                              _turnReaderPage(session, forward: true),
                            )
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded, size: 18),
                    label: const Text('下一頁'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _readerText,
                      side: const BorderSide(color: Color(0x44393247)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 9,
                      ),
                      textStyle: const TextStyle(fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

  Widget _buildReaderSidebar(
    FrameEpubReaderSession session, {
    required int initialTabIndex,
    required VoidCallback onClose,
    bool desktopLayout = false,
  }) {
    return FrameEpubReaderSidebar(
      toc: session.toc,
      currentPath: session.currentSpineIndex == null
          ? null
          : session.epub?.spine[session.currentSpineIndex!].item.path,
      annotations: session.annotations,
      initialTabIndex: initialTabIndex,
      desktopLayout: desktopLayout,
      onClose: onClose,
      onSelectToc: (entry) {
        if (!desktopLayout) onClose();
        unawaited(_runNavigation(() => session.goToTocEntry(entry)));
      },
      onOpenAnnotation: (annotation) {
        if (!desktopLayout) onClose();
        unawaited(_goToAnnotation(annotation));
      },
      onEditNote: (annotation) {
        if (!desktopLayout) onClose();
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
      onRefreshAnnotations: () async {
        try {
          await session.refreshAnnotations();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已重新整理本書標註與書籤。')),
          );
        } on Object catch (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('讀取標註失敗：$error')),
          );
        }
      },
    );
  }

  Future<void> _showReaderSidebar({required int initialTabIndex}) async {
    final session = _session;
    if (session == null || session.status != FrameEpubReaderStatus.ready) {
      return;
    }

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '關閉閱讀導覽',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final screen = MediaQuery.sizeOf(dialogContext);
        final width = (screen.width * .88).clamp(280.0, 420.0).toDouble();
        return Align(
          alignment: Alignment.centerLeft,
          child: SafeArea(
            child: SizedBox(
              width: width,
              height: double.infinity,
              child: _buildReaderSidebar(
                session,
                initialTabIndex: initialTabIndex,
                onClose: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
        final position = Tween<Offset>(
          begin: const Offset(-1, 0),
          end: Offset.zero,
        ).chain(
          CurveTween(curve: Curves.easeOutCubic),
        ).animate(animation);
        return SlideTransition(position: position, child: child);
      },
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
    if (!mounted) return;
    if (selection == null) {
      if (_selectedText != null) {
        setState(() => _selectedText = null);
      }
      return;
    }

    final session = _session;
    final chapter = session?.currentChapter;
    final spineIndex = session?.currentSpineIndex;
    final book = session?.epub;
    if (session == null ||
        chapter == null ||
        book == null ||
        spineIndex == null ||
        session.isFixedLayout) {
      if (_selectedText != null) {
        setState(() => _selectedText = null);
      }
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
    if (cfi == null) {
      if (_selectedText != null) {
        setState(() => _selectedText = null);
      }
      return;
    }
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
    final result = await showDialog<FrameEpubNoteEditorResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => FrameEpubNoteEditorDialog(
        quote: quote,
        initialText: annotation?.text ?? '',
        isEditing: annotation != null,
      ),
    );
    if (!mounted || result == null) return;

    if (result.action == FrameEpubNoteEditorAction.delete) {
      if (annotation == null) return;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: _readerPanel,
          title: const Text(
            '刪除閱讀筆記',
            style: TextStyle(color: _readerText, fontSize: 17),
          ),
          content: const Text(
            '確定刪除這筆筆記嗎？刪除後無法復原。',
            style: TextStyle(color: _readerMuted, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF9F526D),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('刪除筆記'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      try {
        await session.deleteAnnotation(annotation.id);
        if (!mounted) return;
        setState(() => _selectedText = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('筆記已刪除。')),
        );
      } on Object catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('筆記刪除失敗：$error')),
        );
      }
      return;
    }

    final text = (result.text ?? '').trim();
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

  Future<void> _toggleBookmark() async {
    final session = _session;
    if (session == null ||
        session.status != FrameEpubReaderStatus.ready ||
        _bookmarkBusy) {
      return;
    }

    final preferredCfi = _pendingCfi ?? _lastVisibleCfi;
    setState(() => _bookmarkBusy = true);
    try {
      await _flushReadingPosition();
      if (!mounted || session.status != FrameEpubReaderStatus.ready) return;

      final cfi = _bookmarkCfi(session, preferred: preferredCfi);
      if (cfi == null || cfi.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('目前 EPUB 頁面無法建立書籤。')),
        );
        return;
      }

      final existing = findFrameBookmarkAtCfi(session.annotations, cfi);
      if (existing != null) {
        await session.deleteAnnotation(existing.id);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已移除目前位置的書籤。')),
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
        updatedAt: now,
      );
      await session.saveAnnotation(annotation);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已加入書籤。')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('書籤更新失敗：$error')),
      );
    } finally {
      _bookmarkBusy = false;
      if (mounted) setState(() {});
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

    Widget buildSettingsPanel(BuildContext closeContext) =>
        StatefulBuilder(
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
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '閱讀外觀',
                          style: TextStyle(
                            color: _readerText,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'PERSONALIZE YOUR PAGE',
                          style: TextStyle(
                            color: Color(0xFF887A9C),
                            fontSize: 8,
                            letterSpacing: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '關閉閱讀設定',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(closeContext).pop(),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: _readerMuted,
                    ),
                  ),
                ],
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
                  Navigator.of(closeContext).pop();
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
      );

    final screenSize = MediaQuery.sizeOf(context);
    final panelWidth = (screenSize.width - 32).clamp(280.0, 470.0).toDouble();
    final panelMaxHeight = (screenSize.height - 104).clamp(320.0, 900.0).toDouble();

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '關閉閱讀設定',
      barrierColor: Colors.black45,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondaryAnimation) => Align(
        alignment: screenSize.width >= 840
            ? Alignment.topRight
            : Alignment.topCenter,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              top: screenSize.width >= 840 ? 12 : 8,
              right: screenSize.width >= 840 ? 20 : 8,
              left: 8,
            ),
            child: Material(
              color: _readerPanel,
              elevation: 24,
              borderRadius: BorderRadius.circular(15),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: panelWidth,
                  maxHeight: panelMaxHeight,
                ),
                child: SizedBox(
                  width: panelWidth,
                  child: buildSettingsPanel(dialogContext),
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
        final offset = Tween<Offset>(
          begin: const Offset(0, -0.025),
          end: Offset.zero,
        ).chain(
          CurveTween(curve: Curves.easeOutCubic),
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
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
