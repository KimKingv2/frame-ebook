import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/frame_api_scope.dart';
import '../core/frame_app_config.dart';
import '../library/frame_book.dart';
import '../library/frame_reader_repository.dart';
import '../transport/frame_cloud_file_source.dart';
import '../transport/frame_file_source.dart';
import '../transport/frame_file_source_factory.dart';
import 'frame_epub_chapter_view.dart';
import 'frame_epub_parser.dart';
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

  double _fontSize = 18;
  double _lineHeight = 1.75;
  String _theme = 'dark';

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
  }

  @override
  void dispose() {
    unawaited(_releaseResources());
    super.dispose();
  }

  Future<void> _releaseResources() async {
    final session = _session;
    if (session != null) {
      session.removeListener(_handleSessionChanged);
      await session.close();
      session.dispose();
    }
    final source = _fileSource;
    if (source is FrameCloudFileSource) source.close();
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
                child: FrameEpubChapterView(
                  key: ValueKey(chapter.resource.path),
                  chapter: chapter,
                  resourceLoader: session.resourceLoader!,
                  fixedLayout: session.isFixedLayout,
                  backgroundColor: _pageBackground,
                  textColor: _pageText,
                  linkColor: _pageLink,
                  fontSize: _fontSize,
                  lineHeight: _lineHeight,
                  onInternalLink: (href) {
                    unawaited(session.goToHref(href));
                  },
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
                        ? () => unawaited(session.goToPreviousChapter())
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
                        ? () => unawaited(session.goToNextChapter())
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
                                    unawaited(session.goToTocEntry(entry));
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

  Future<void> _showAnnotations() async {
    final session = _session;
    if (session == null) return;
    final annotations = session.annotations;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _readerPanel,
      builder: (sheetContext) => SizedBox(
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
                        );
                      },
                    ),
            ),
          ],
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
              const SizedBox(height: 8),
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
                  setState(() {
                    _fontSize = fontSize;
                    _lineHeight = lineHeight;
                    _theme = theme;
                  });
                  Navigator.of(sheetContext).pop();
                  try {
                    await session.saveAppearance({
                      'frameFlutterFontSize': fontSize,
                      'frameFlutterLineHeight': lineHeight,
                      'frameFlutterTheme': theme,
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

class _FlattenedTocEntry {
  const _FlattenedTocEntry(this.entry, this.depth);

  final FrameEpubTocEntry entry;
  final int depth;
}
