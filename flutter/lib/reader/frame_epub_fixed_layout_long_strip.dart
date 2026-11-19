import 'package:flutter/material.dart';

/// Vertically presents fixed-layout EPUB spine items as a lazy comic strip.
///
/// Each item is built only when it enters the viewport/cache extent. The
/// caller owns archive-backed chapter loading and reports the visible spine
/// index to the existing reader session for progress persistence.
class FrameEpubFixedLayoutLongStrip extends StatefulWidget {
  const FrameEpubFixedLayoutLongStrip({
    required this.pageCount,
    required this.currentPageIndex,
    required this.pageBuilder,
    required this.onPageChanged,
    this.cachePages = 1,
    super.key,
  })  : assert(pageCount > 0),
        assert(cachePages >= 0);

  final int pageCount;
  final int currentPageIndex;
  final Widget Function(BuildContext context, int pageIndex) pageBuilder;
  final ValueChanged<int> onPageChanged;

  /// Number of full pages to retain just outside the visible viewport.
  /// Keep this small because each page may own decoded image resources.
  final int cachePages;

  @override
  State<FrameEpubFixedLayoutLongStrip> createState() =>
      _FrameEpubFixedLayoutLongStripState();
}

class _FrameEpubFixedLayoutLongStripState
    extends State<FrameEpubFixedLayoutLongStrip> {
  late final ScrollController _scrollController;
  int? _lastReportedIndex;
  bool _initialPositionApplied = false;
  double _pageExtent = 0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()
      ..addListener(_handleScrollChanged);
  }

  @override
  void didUpdateWidget(covariant FrameEpubFixedLayoutLongStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageCount != widget.pageCount) {
      _lastReportedIndex = null;
    }
    if (oldWidget.currentPageIndex != widget.currentPageIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients || _pageExtent <= 0) {
          return;
        }
        final target = widget.currentPageIndex
            .clamp(0, widget.pageCount - 1)
            .toDouble() * _pageExtent;
        final position = _scrollController.position;
        if ((position.pixels - target).abs() > _pageExtent * .45) {
          _scrollController.jumpTo(
            target.clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ).toDouble(),
          );
        }
      });
    }
  }

  void _handleScrollChanged() {
    if (!_scrollController.hasClients || _pageExtent <= 0) return;
    final position = _scrollController.position;
    final index = (position.pixels / _pageExtent)
        .floor()
        .clamp(0, widget.pageCount - 1)
        .toInt();
    if (_lastReportedIndex == index) return;
    _lastReportedIndex = index;
    widget.onPageChanged(index);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScrollChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final extent = constraints.maxHeight;
          if (extent.isFinite && extent > 0) {
            _pageExtent = extent;
          }
          if (!_initialPositionApplied && _pageExtent > 0) {
            _initialPositionApplied = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_scrollController.hasClients) return;
              final initialOffset = widget.currentPageIndex
                      .clamp(0, widget.pageCount - 1)
                      .toDouble() *
                  _pageExtent;
              if (initialOffset > 0) {
                _scrollController.jumpTo(
                  initialOffset.clamp(
                    _scrollController.position.minScrollExtent,
                    _scrollController.position.maxScrollExtent,
                  ).toDouble(),
                );
              } else {
                _handleScrollChanged();
              }
            });
          }
          final cacheExtent =
              _pageExtent * widget.cachePages.toDouble();
          return ListView.builder(
            controller: _scrollController,
            itemCount: widget.pageCount,
            itemExtent: _pageExtent > 0 ? _pageExtent : null,
            cacheExtent: cacheExtent,
            padding: EdgeInsets.zero,
            physics: const ClampingScrollPhysics(),
            itemBuilder: (context, index) => SizedBox(
              height: _pageExtent > 0 ? _pageExtent : null,
              width: double.infinity,
              child: widget.pageBuilder(context, index),
            ),
          );
        },
      );
}
