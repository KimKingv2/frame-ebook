import 'package:material_ui/material_ui.dart';

import '../library/frame_reader_repository.dart';
import 'frame_epub_parser.dart';

const _sidebarPanel = Color(0xFF211D2D);
const _sidebarText = Color(0xFFF4F0FA);
const _sidebarMuted = Color(0xFFAAA2B8);
const _sidebarAccent = Color(0xFFC5ADFF);

/// Shared TOC, bookmark and note navigation for the Flutter EPUB reader.
///
/// The host presents this widget as a persistent left column on wide layouts
/// and as a slide-in drawer on compact layouts. Annotation changes remain
/// delegated to the reader session so the existing D1 contract is unchanged.
class FrameEpubReaderSidebar extends StatefulWidget {
  const FrameEpubReaderSidebar({
    required this.toc,
    required this.currentPath,
    required this.annotations,
    required this.initialTabIndex,
    required this.onSelectToc,
    required this.onOpenAnnotation,
    required this.onEditNote,
    required this.onDeleteAnnotation,
    required this.onRefreshAnnotations,
    required this.onClose,
    this.desktopLayout = false,
    super.key,
  });

  final List<FrameEpubTocEntry> toc;
  final String? currentPath;
  final List<FrameReaderAnnotation> annotations;
  final int initialTabIndex;
  final ValueChanged<FrameEpubTocEntry> onSelectToc;
  final ValueChanged<FrameReaderAnnotation> onOpenAnnotation;
  final ValueChanged<FrameReaderAnnotation> onEditNote;
  final Future<bool> Function(FrameReaderAnnotation) onDeleteAnnotation;
  final Future<void> Function() onRefreshAnnotations;
  final VoidCallback onClose;
  final bool desktopLayout;

  @override
  State<FrameEpubReaderSidebar> createState() =>
      _FrameEpubReaderSidebarState();
}

class _FrameEpubReaderSidebarState extends State<FrameEpubReaderSidebar> {
  late final PageController _pageController;
  late int _activeTab;
  late List<FrameReaderAnnotation> _annotations;
  bool _refreshingAnnotations = false;
  bool _showDesktopAnnotations = false;
  final Set<String> _expandedTocKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _annotations = List<FrameReaderAnnotation>.of(widget.annotations);
    _activeTab = widget.initialTabIndex.clamp(0, 2).toInt();
    _pageController = PageController(initialPage: _activeTab);
    if (widget.toc.length == 1 && widget.toc.first.children.isNotEmpty) {
      _expandedTocKeys.add('0');
    }
    _expandAncestorsForPath(widget.toc, widget.currentPath);
  }

  void _selectTab(int index) {
    if (index == _activeTab) return;
    setState(() => _activeTab = index);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _handlePageChanged(int index) {
    if (mounted && _activeTab != index) {
      setState(() => _activeTab = index);
    }
  }

  Future<void> _refreshAnnotations() async {
    if (_refreshingAnnotations) return;
    setState(() => _refreshingAnnotations = true);
    try {
      await widget.onRefreshAnnotations();
    } finally {
      if (mounted) setState(() => _refreshingAnnotations = false);
    }
  }

  @override
  void didUpdateWidget(covariant FrameEpubReaderSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.annotations != widget.annotations) {
      _annotations = List<FrameReaderAnnotation>.of(widget.annotations);
    }
    if (oldWidget.currentPath != widget.currentPath) {
      _expandAncestorsForPath(widget.toc, widget.currentPath);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool _expandAncestorsForPath(
    List<FrameEpubTocEntry> entries,
    String? currentPath, {
    String prefix = '',
  }) {
    if (currentPath == null || currentPath.isEmpty) return false;
    var found = false;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final key = prefix.isEmpty ? '$index' : '$prefix.$index';
      final isCurrent = entry.path == currentPath;
      final containsCurrent = _expandAncestorsForPath(
        entry.children,
        currentPath,
        prefix: key,
      );
      if (containsCurrent) {
        _expandedTocKeys.add(key);
        found = true;
      } else if (isCurrent) {
        found = true;
      }
    }
    return found;
  }

  List<Widget> _buildTocTree(
    List<FrameEpubTocEntry> entries, {
    int depth = 0,
    String prefix = '',
    bool compact = false,
  }) {
    final widgets = <Widget>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final key = prefix.isEmpty ? '$index' : '$prefix.$index';
      final hasChildren = entry.children.isNotEmpty;
      final expanded = _expandedTocKeys.contains(key);
      final selected = entry.path != null && entry.path == widget.currentPath;
      final available = !entry.isExternal && entry.reference?.path != null;
      final label =
          entry.label.trim().isEmpty ? '未命名項目' : entry.label.trim();

      widgets.add(
        Padding(
          padding: EdgeInsets.only(
            left: depth * (compact ? 13 : 10),
            top: 1,
            bottom: 1,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0x332A213B)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: selected
                  ? Border.all(color: const Color(0x55A78BFA))
                  : null,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: compact ? 40 : 30),
              child: Row(
                children: [
                  SizedBox(
                    width: compact ? 30 : 24,
                    height: compact ? 36 : 28,
                    child: hasChildren
                        ? IconButton(
                            tooltip: expanded
                                ? '收合「$label」子目錄'
                                : '展開「$label」子目錄',
                            onPressed: () {
                              setState(() {
                                if (expanded) {
                                  _expandedTocKeys.remove(key);
                                } else {
                                  _expandedTocKeys.add(key);
                                }
                              });
                            },
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              expanded
                                  ? Icons.expand_more_rounded
                                  : Icons.chevron_right_rounded,
                              color: const Color(0xFFA99ABF),
                              size: 18,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed:
                          available ? () => widget.onSelectToc(entry) : null,
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        foregroundColor: selected
                            ? const Color(0xFFF6F0FF)
                            : depth == 0
                                ? const Color(0xFFE1D7EF)
                                : _sidebarText,
                        disabledForegroundColor: _sidebarText,
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 10 : 7,
                          vertical: compact ? 9 : 5,
                        ),
                        minimumSize: Size(0, compact ? 40 : 29),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        backgroundColor: selected
                            ? const Color(0x221A1328)
                            : Colors.transparent,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          label,
                          maxLines: widget.desktopLayout ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected
                                ? const Color(0xFFF6F0FF)
                                : depth == 0
                                    ? const Color(0xFFE1D7EF)
                                    : _sidebarText,
                            fontFamily: 'NotoSansTC',
                            fontSize: widget.desktopLayout ? 9 : 12,
                            height: 1.45,
                            fontWeight: depth == 0
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
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

      if (hasChildren && expanded) {
        widgets.addAll(
          _buildTocTree(
            entry.children,
            depth: depth + 1,
            prefix: key,
            compact: compact,
          ),
        );
      }
    }
    return widgets;
  }

  Future<void> _deleteAnnotation(FrameReaderAnnotation annotation) async {
    final isBookmark = annotation.type == 'bookmark';
    final confirmed = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '關閉刪除確認',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondaryAnimation) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
          child: Material(
            color: _sidebarPanel,
            elevation: 24,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 18, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isBookmark ? '刪除書籤' : '刪除標註',
                    style: const TextStyle(
                      color: _sidebarText,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isBookmark ? '確定刪除這個書籤嗎？' : '確定刪除這筆標註嗎？',
                    style: const TextStyle(
                      color: _sidebarMuted,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () =>
                            Navigator.of(dialogContext).pop(false),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () =>
                            Navigator.of(dialogContext).pop(true),
                        child: const Text('刪除'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (dialogContext, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    );
    if (!mounted || confirmed != true) return;

    final deleted = await widget.onDeleteAnnotation(annotation);
    if (!mounted || !deleted) return;
    setState(() {
      _annotations.removeWhere((item) => item.id == annotation.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bookmarkCount =
        _annotations.where((item) => item.type == 'bookmark').length;
    final noteCount =
        _annotations.where((item) => item.type != 'bookmark').length;

    return Material(
      color: widget.desktopLayout ? _sidebarPanel : const Color(0xFF1B1726),
      child: widget.desktopLayout
          ? _buildDesktopLayout(bookmarkCount, noteCount)
          : Padding(
              padding: EdgeInsets.fromLTRB(
                15,
                18,
                15,
                16 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              child: _buildCompactLayout(bookmarkCount),
            ),
    );
  }

  Widget _buildCompactSectionHeading(String title, String kicker) =>
      Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFFD8CDEA),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            kicker,
            style: const TextStyle(
              color: Color(0xFF766C85),
              fontSize: 8,
              letterSpacing: 1.25,
            ),
          ),
        ],
      );

  Widget _buildCompactLayout(int bookmarkCount) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              height: 46,
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '閱讀導覽',
                      style: TextStyle(
                        color: _sidebarText,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0x33BEA6E5)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: IconButton(
                      tooltip: '關閉閱讀導覽',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 42, height: 42),
                      onPressed: widget.onClose,
                      icon: const Icon(
                        Icons.close_rounded,
                        color: _sidebarMuted,
                        size: 19,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(2, 2, 2, 4),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0x6B0B0910),
              border: Border.all(color: const Color(0x24C1AAEE)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _buildTabButton('目錄', 0),
                _buildTabButton('筆記', 1),
                _buildTabButton('書籤 $bookmarkCount', 2),
              ],
            ),
          ),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: _handlePageChanged,
              physics: const PageScrollPhysics(),
              children: [
                _buildCompactTocPane(),
                _buildCompactNotesPane(),
                _buildCompactBookmarksPane(bookmarkCount),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 11),
            padding: const EdgeInsets.only(top: 11),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Color(0x1AC1AAEE)),
              ),
            ),
            child: const Text(
              '閱讀位置、筆記與書籤都會同步保存至雲端',
              style: TextStyle(
                color: Color(0xFF94899F),
                fontSize: 9,
              ),
            ),
          ),
        ],
      );

  Widget _buildCompactTocPane() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCompactSectionHeading('章節目錄', 'CONTENTS'),
          const SizedBox(height: 12),
          Expanded(
            child: widget.toc.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: 14,
                        horizontal: 8,
                      ),
                      child: Text(
                        '這本 EPUB 沒有提供可用目錄。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _sidebarMuted,
                          fontSize: 10,
                          height: 1.8,
                        ),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(right: 2),
                    children: _buildTocTree(widget.toc, compact: true),
                  ),
          ),
        ],
      );

  Widget _buildCompactNotesPane() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCompactSectionHeading('個人筆記', 'MY NOTES'),
          const SizedBox(height: 12),
          SizedBox(
            height: 38,
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '筆記與標註',
                    style: TextStyle(
                      color: Color(0xFFECE4F8),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Tooltip(
                  message: '重新整理標註',
                  child: OutlinedButton(
                    onPressed:
                        _refreshingAnnotations ? null : _refreshAnnotations,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _sidebarText,
                      backgroundColor: const Color(0x332A213B),
                      side: const BorderSide(color: Color(0x443F3552)),
                      minimumSize: const Size(0, 27),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                      textStyle: const TextStyle(fontSize: 9),
                    ),
                    child: _refreshingAnnotations
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: _sidebarAccent,
                            ),
                          )
                        : const Text(
                            '重新整理',
                            style: TextStyle(
                              color: _sidebarText,
                              fontFamily: 'NotoSansTC',
                              fontSize: 9,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: _buildAnnotations(bookmarksOnly: false)),
        ],
      );

  Widget _buildCompactBookmarksPane(int bookmarkCount) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCompactSectionHeading('我的書籤 $bookmarkCount', 'BOOKMARKS'),
          const SizedBox(height: 12),
          Expanded(child: _buildAnnotations(bookmarksOnly: true)),
        ],
      );

  Widget _buildDesktopLayout(int bookmarkCount, int noteCount) {
    final notes = _annotations
        .where((item) => item.type != 'bookmark')
        .toList()
      ..sort((a, b) {
        final created = b.createdAt.compareTo(a.createdAt);
        return created != 0 ? created : b.updatedAt.compareTo(a.updatedAt);
      });
    final bookmarks = _annotations
        .where((item) => item.type == 'bookmark')
        .toList()
      ..sort((a, b) {
        final created = b.createdAt.compareTo(a.createdAt);
        return created != 0 ? created : b.updatedAt.compareTo(a.updatedAt);
      });

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 8, 11),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'IN THIS BOOK',
                      style: TextStyle(
                        color: Color(0xFF887A9C),
                        fontSize: 8,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '閱讀導覽',
                      style: TextStyle(
                        color: Color(0xFFEEE7F8),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 31,
                height: 31,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0x4DB397ED)),
                  borderRadius: BorderRadius.circular(9),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0x527F5DBE), Color(0xB8362A4B)],
                  ),
                ),
                alignment: Alignment.center,
                child: const Text(
                  'F',
                  style: TextStyle(
                    color: Color(0xFFD8C6FF),
                    fontFamily: 'Georgia',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              IconButton(
                tooltip: '重新整理標註',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 31,
                  height: 34,
                ),
                onPressed:
                    _refreshingAnnotations ? null : _refreshAnnotations,
                icon: _refreshingAnnotations
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _sidebarAccent,
                        ),
                      )
                    : const Icon(
                        Icons.refresh_rounded,
                        color: _sidebarMuted,
                        size: 18,
                      ),
              ),
              IconButton(
                tooltip: '隱藏閱讀導覽',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 34,
                ),
                onPressed: widget.onClose,
                icon: const Icon(
                  Icons.close_rounded,
                  color: _sidebarMuted,
                  size: 18,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0x55393247)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(11, 13, 11, 14),
            children: [
              _desktopSectionHeading('章節目錄', 'CONTENTS'),
              const SizedBox(height: 7),
              if (widget.toc.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14, horizontal: 7),
                  child: Text(
                    '正在等待 EPUB 章節資料。',
                    style: TextStyle(
                      color: _sidebarMuted,
                      fontSize: 11,
                      height: 1.6,
                    ),
                  ),
                )
              else
                ..._buildTocTree(widget.toc),
              const SizedBox(height: 14),
              _desktopSectionHeading('個人筆記', 'MY NOTES'),
              const SizedBox(height: 6),
              OutlinedButton(
                onPressed: () => setState(
                  () => _showDesktopAnnotations = !_showDesktopAnnotations,
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _sidebarText,
                  side: const BorderSide(color: Color(0x443F3552)),
                  backgroundColor: const Color(0x332A213B),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '筆記與標註',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    Text(
                      '$noteCount',
                      style: const TextStyle(
                        color: _sidebarMuted,
                        fontSize: 10,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Icon(
                      _showDesktopAnnotations
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: _sidebarMuted,
                      size: 18,
                    ),
                  ],
                ),
              ),
              if (_showDesktopAnnotations) ...[
                const SizedBox(height: 5),
                if (notes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 9, horizontal: 7),
                    child: Text(
                      '目前沒有筆記或劃線。',
                      style: TextStyle(
                        color: _sidebarMuted,
                        fontSize: 10,
                      ),
                    ),
                  )
                else
                  ...notes.map(_buildDesktopAnnotationTile),
              ],
              const SizedBox(height: 15),
              _desktopSectionHeading('我的書籤', 'BOOKMARKS · $bookmarkCount'),
              const SizedBox(height: 5),
              if (bookmarks.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 9, horizontal: 7),
                  child: Text(
                    '目前沒有已保存的書籤。',
                    style: TextStyle(
                      color: _sidebarMuted,
                      fontSize: 10,
                    ),
                  ),
                )
              else
                ...bookmarks.map(_buildDesktopAnnotationTile),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0x55393247)),
        const Padding(
          padding: EdgeInsets.fromLTRB(13, 9, 13, 11),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '閱讀位置、筆記與書籤都會同步保存至雲端',
              style: TextStyle(
                color: Color(0xFF8B8198),
                fontSize: 9,
                height: 1.6,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _desktopSectionHeading(String title, String english) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFD8CDEA),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            english,
            style: const TextStyle(
              color: Color(0xFF766C85),
              fontSize: 7,
              letterSpacing: 1.25,
            ),
          ),
        ],
      );

  Widget _buildDesktopAnnotationTile(FrameReaderAnnotation annotation) =>
      _buildAnnotationCard(annotation, desktop: true);

  Widget _buildAnnotationCard(
    FrameReaderAnnotation annotation, {
    required bool desktop,
  }) {
    final isBookmark = annotation.type == 'bookmark';
    final isNote = annotation.type == 'note';
    final isUnderline =
        annotation.type == 'highlight' && annotation.color == 'underline';
    final title = switch (annotation.type) {
      'bookmark' => '書籤',
      'highlight' => isUnderline ? '下劃線' : '高亮',
      'note' => '筆記',
      _ => '標註',
    };
    final markerColor = switch (annotation.color) {
      'yellow' => const Color(0xFFF2C94C),
      'violet' => const Color(0xFFA78BFA),
      'mint' => const Color(0xFF65C9A5),
      'rose' => const Color(0xFFE88EAF),
      _ => _sidebarAccent,
    };
    final quote = annotation.quote.trim();
    final note = annotation.text.trim();
    final quoteFallback = isBookmark ? '已保存的閱讀位置' : '未附選取文字';

    Widget marker;
    if (isBookmark) {
      marker = Icon(
        Icons.star_rounded,
        color: const Color(0xFFC5A6FF),
        size: desktop ? 13 : 16,
      );
    } else if (isNote) {
      marker = Container(
        width: 3,
        height: desktop ? 34 : 42,
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: markerColor,
              width: 2,
              style: BorderStyle.solid,
            ),
          ),
        ),
      );
    } else if (isUnderline) {
      marker = Container(
        width: 6,
        height: 34,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: markerColor, width: 3),
          ),
        ),
      );
    } else {
      marker = Container(
        width: 6,
        height: desktop ? 34 : 42,
        decoration: BoxDecoration(
          color: markerColor,
          borderRadius: BorderRadius.circular(5),
          boxShadow: [
            BoxShadow(
              color: markerColor.withValues(alpha: .18),
              blurRadius: 8,
            ),
          ],
        ),
      );
    }

    return Container(
      margin: EdgeInsets.only(bottom: desktop ? 3 : 9),
      padding: EdgeInsets.symmetric(
        horizontal: desktop ? 7 : 10,
        vertical: desktop ? 7 : 12,
      ),
      decoration: BoxDecoration(
        color: const Color(0x07FFFFFF),
        border: Border.all(
          color: desktop
              ? const Color(0x1CBEA6E5)
              : const Color(0x17BEA6E5),
        ),
        borderRadius: BorderRadius.circular(desktop ? 8 : 11),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: desktop ? 12 : 6,
            child: Padding(
              padding: EdgeInsets.only(top: isBookmark ? 2 : 1),
              child: marker,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: TextButton(
              onPressed: annotation.cfi.trim().isEmpty
                  ? null
                  : () => widget.onOpenAnnotation(annotation),
              style: TextButton.styleFrom(
                alignment: Alignment.topLeft,
                foregroundColor: _sidebarText,
                disabledForegroundColor: _sidebarMuted,
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: const RoundedRectangleBorder(),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: const Color(0xFFBCA8E9),
                      fontSize: desktop ? 8 : 10,
                      letterSpacing: .35,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    quote.isEmpty ? quoteFallback : quote,
                    maxLines: desktop ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: const Color(0xFFE4DDEC),
                      fontSize: desktop ? 9 : 11,
                      height: desktop ? 1.55 : 1.65,
                    ),
                  ),
                  if (isNote && note.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      note,
                      maxLines: desktop ? 2 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: const Color(0xFF9F94AD),
                        fontSize: desktop ? 8 : 10,
                        height: desktop ? 1.5 : 1.6,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: '刪除$title',
            child: TextButton(
              onPressed: () => _deleteAnnotation(annotation),
              style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFC99AAA),
              padding: EdgeInsets.symmetric(
                horizontal: desktop ? 5 : 9,
                vertical: desktop ? 3 : 0,
              ),
              minimumSize: Size(0, desktop ? 27 : 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
                child: Text(
                  '刪除',
                  style: TextStyle(fontSize: desktop ? 8 : 10),
                ),
              ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton(String label, int index) {
    final selected = _activeTab == index;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: InkWell(
          onTap: () => _selectTab(index),
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? const Color(0x5C49346F) : Colors.transparent,
              gradient: selected
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0x5C8061D0),
                        Color(0x614C3970),
                      ],
                    )
                  : null,
              border: Border.all(
                color: selected
                    ? const Color(0x59A78BFA)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(9),
              boxShadow: selected
                  ? const [
                      BoxShadow(
                        color: Color(0x0DFFFFFF),
                        blurRadius: 0,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : const [],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected
                    ? const Color(0xFFF2EBFF)
                    : const Color(0xFF9E93AD),
                fontFamily: 'NotoSansTC',
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAnnotations({required bool bookmarksOnly}) {
    final items = _annotations
        .where((item) =>
            bookmarksOnly ? item.type == 'bookmark' : item.type != 'bookmark')
        .toList()
      ..sort((a, b) {
        final created = b.createdAt.compareTo(a.createdAt);
        return created != 0 ? created : b.updatedAt.compareTo(a.updatedAt);
      });
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Text(
            bookmarksOnly
                ? '目前沒有已保存的書籤。'
                : '這本書還沒有筆記或高亮。選取正文中的文字即可新增。',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF90869E),
              fontSize: 10,
              height: 1.8,
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      children: [
        for (final annotation in items)
          _buildAnnotationCard(annotation, desktop: false),
      ],
    );
  }

}



