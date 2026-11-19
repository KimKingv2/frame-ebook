import 'package:flutter/material.dart';

import '../library/frame_reader_repository.dart';
import 'frame_epub_parser.dart';

const _sidebarPanel = Color(0xFF211D2D);
const _sidebarText = Color(0xFFF4F0FA);
const _sidebarMuted = Color(0xFFAAA2B8);
const _sidebarAccent = Color(0xFFC5ADFF);

/// Shared TOC, bookmark and note navigation for the Flutter EPUB reader.
///
/// The host presents this widget as a bottom sheet on compact layouts and as
/// a right-side drawer on wide layouts. Annotation changes remain delegated to
/// the reader session so the existing D1 contract is unchanged.
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
    required this.onClose,
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
  final VoidCallback onClose;

  @override
  State<FrameEpubReaderSidebar> createState() =>
      _FrameEpubReaderSidebarState();
}

class _FrameEpubReaderSidebarState extends State<FrameEpubReaderSidebar>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late List<FrameReaderAnnotation> _annotations;

  @override
  void initState() {
    super.initState();
    _annotations = List<FrameReaderAnnotation>.of(widget.annotations);
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 2).toInt(),
    )..addListener(_handleTabControllerChanged);
  }

  void _handleTabControllerChanged() {
    if (!mounted || _tabController.indexIsChanging) return;
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant FrameEpubReaderSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.annotations != widget.annotations) {
      _annotations = List<FrameReaderAnnotation>.of(widget.annotations);
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabControllerChanged);
    _tabController.dispose();
    super.dispose();
  }

  List<_SidebarTocEntry> _flattenToc(
    List<FrameEpubTocEntry> entries, {
    int depth = 0,
  }) {
    final flattened = <_SidebarTocEntry>[];
    for (final entry in entries) {
      flattened.add(_SidebarTocEntry(entry, depth));
      flattened.addAll(_flattenToc(entry.children, depth: depth + 1));
    }
    return flattened;
  }

  Future<void> _deleteAnnotation(FrameReaderAnnotation annotation) async {
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
      color: _sidebarPanel,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
            child: Row(
              children: [
                const Icon(Icons.menu_book_outlined, color: _sidebarAccent),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '閱讀導覽',
                    style: TextStyle(
                      color: _sidebarText,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '關閉閱讀導覽',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: const Icon(
                    Icons.close_rounded,
                    color: _sidebarMuted,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0x55393247)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              children: [
                _buildTabButton('目錄', 0),
                _buildTabButton('書籤 $bookmarkCount', 1),
                _buildTabButton('筆記 $noteCount', 2),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0x33393247)),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildToc(),
                _buildAnnotations(bookmarksOnly: true),
                _buildAnnotations(bookmarksOnly: false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton(String label, int index) {
    final selected = _tabController.index == index;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: TextButton(
          onPressed: () => _tabController.animateTo(index),
          style: TextButton.styleFrom(
            foregroundColor: selected ? _sidebarAccent : _sidebarMuted,
            backgroundColor:
                selected ? const Color(0x332A213B) : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToc() {
    final entries = _flattenToc(widget.toc);
    if (entries.isEmpty) {
      return const _SidebarEmptyState(message: '這本 EPUB 沒有提供可用目錄。');
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final item = entries[index];
        final entry = item.entry;
        final available = !entry.isExternal && entry.reference?.path != null;
        final selected = entry.path == widget.currentPath;
        return Padding(
          padding: EdgeInsets.only(left: item.depth * 12),
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
                color: selected ? _sidebarAccent : _sidebarText,
                fontSize: 13,
              ),
            ),
            onTap: available ? () => widget.onSelectToc(entry) : null,
          ),
        );
      },
    );
  }

  Widget _buildAnnotations({required bool bookmarksOnly}) {
    final items = _annotations
        .where((item) =>
            bookmarksOnly ? item.type == 'bookmark' : item.type != 'bookmark')
        .toList(growable: false);
    if (items.isEmpty) {
      return _SidebarEmptyState(
        message: bookmarksOnly ? '目前沒有已保存的書籤。' : '目前沒有筆記或劃線。',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: Color(0x33393247)),
      itemBuilder: (context, index) {
        final annotation = items[index];
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
              : () => widget.onOpenAnnotation(annotation),
          title: Text(
            title,
            style: const TextStyle(color: _sidebarText, fontSize: 13),
          ),
          subtitle: Text(
            detail.isEmpty ? '尚無文字內容' : detail,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _sidebarMuted,
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
                  visualDensity: VisualDensity.compact,
                  onPressed: () => widget.onEditNote(annotation),
                  icon: const Icon(
                    Icons.edit_outlined,
                    color: _sidebarAccent,
                    size: 18,
                  ),
                ),
              IconButton(
                tooltip: '刪除$title',
                visualDensity: VisualDensity.compact,
                onPressed: () => _deleteAnnotation(annotation),
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
    );
  }
}

class _SidebarEmptyState extends StatelessWidget {
  const _SidebarEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _sidebarMuted, fontSize: 13),
          ),
        ),
      );
}

class _SidebarTocEntry {
  const _SidebarTocEntry(this.entry, this.depth);

  final FrameEpubTocEntry entry;
  final int depth;
}
