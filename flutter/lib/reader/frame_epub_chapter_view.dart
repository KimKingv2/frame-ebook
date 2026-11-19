import 'dart:collection';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:xml/xml.dart';

import '../library/frame_reader_repository.dart';
import 'frame_epub_cfi.dart';
import 'frame_epub_footnote.dart';
import 'frame_epub_css.dart';
import 'frame_epub_resource_loader.dart';
import 'frame_epub_page_layout.dart';
import 'frame_epub_text_paginator.dart';

/// A text selection mapped back to the original XHTML text nodes.
class FrameEpubTextSelection {
  const FrameEpubTextSelection({
    required this.startNode,
    required this.startOffset,
    required this.endNode,
    required this.endOffset,
    required this.quote,
  });

  final XmlText startNode;
  final int startOffset;
  final XmlText endNode;
  final int endOffset;
  final String quote;
}

class _PreparedEpubText {
  const _PreparedEpubText(this.text, this.sourceOffsets);

  final String text;
  final List<int> sourceOffsets;
}

class _TextSpanSource {
  const _TextSpanSource(this.node, this.sourceOffsets);

  final XmlText node;
  final List<int> sourceOffsets;
}

class FrameEpubTextRangeSource {
  const FrameEpubTextRangeSource({
    required this.start,
    required this.end,
    required this.node,
    required this.sourceOffsets,
  });

  final int start;
  final int end;
  final XmlText node;
  final List<int> sourceOffsets;
}

class _TextSelectionEndpoint {
  const _TextSelectionEndpoint(this.node, this.offset);

  final XmlText node;
  final int offset;
}

class _PaginatedTextPosition {
  const _PaginatedTextPosition(this.node, this.offset);

  final XmlText node;
  final int offset;
}

class _TextSpanSlice {
  const _TextSpanSlice({
    required this.span,
    required this.sources,
  });

  final TextSpan span;
  final List<FrameEpubTextRangeSource> sources;
}

class _ResolvedTextAnnotation {
  const _ResolvedTextAnnotation({
    required this.start,
    required this.end,
    required this.type,
    required this.color,
  });

  final int start;
  final int end;
  final String type;
  final String color;
}

class FrameEpubTextSelectionMapper {
  FrameEpubTextSelectionMapper._();

  /// Maps the UTF-16 offsets reported by Flutter back to the source XHTML
  /// text nodes used to create each rendered TextSpan.
  static FrameEpubTextSelection? map({
    required TextSelection selection,
    required String displayedText,
    required List<FrameEpubTextRangeSource> sources,
  }) {
    if (selection.isCollapsed ||
        sources.isEmpty ||
        selection.start < 0 ||
        selection.end > displayedText.length ||
        selection.end <= selection.start) {
      return null;
    }

    _TextSelectionEndpoint endpoint(int offset, {required bool isEnd}) {
      _TextSelectionEndpoint at(
        FrameEpubTextRangeSource source,
        int displayOffset,
      ) {
        final index = (displayOffset - source.start)
            .clamp(0, source.sourceOffsets.length - 1)
            .toInt();
        return _TextSelectionEndpoint(
          source.node,
          source.sourceOffsets[index],
        );
      }

      if (isEnd) {
        for (final source in sources.reversed) {
          if (offset > source.start && offset <= source.end) {
            return at(source, offset);
          }
        }
        for (final source in sources.reversed) {
          if (source.end <= offset) return at(source, source.end);
        }
        return at(sources.first, sources.first.start);
      }

      for (final source in sources) {
        if (offset >= source.start && offset < source.end) {
          return at(source, offset);
        }
      }
      for (final source in sources) {
        if (source.start >= offset) return at(source, source.start);
      }
      final last = sources.last;
      return at(last, last.end);
    }

    final start = endpoint(selection.start, isEnd: false);
    final end = endpoint(selection.end, isEnd: true);
    if (identical(start.node, end.node) && start.offset >= end.offset) {
      return null;
    }
    final quote = displayedText
        .substring(selection.start, selection.end)
        .replaceAll('\uFFFC', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (quote.isEmpty || quote.length > 12000) return null;
    return FrameEpubTextSelection(
      startNode: start.node,
      startOffset: start.offset,
      endNode: end.node,
      endOffset: end.offset,
      quote: quote,
    );
  }
}

/// Shared Flutter renderer for one parsed EPUB chapter.
///
/// This is a reader-oriented XHTML/CSS subset, not a browser engine. It uses
/// the same Dart widget tree on Web, Android and macOS and never creates a
/// WebView or fetches external document resources.
class FrameEpubChapterView extends StatefulWidget {
  const FrameEpubChapterView({
    required this.chapter,
    required this.resourceLoader,
    this.fixedLayout = false,
    this.paginated = false,
    this.isRightToLeft = false,
    this.pageController,
    this.annotations = const [],
    this.backgroundColor = const Color(0xFF171420),
    this.textColor = const Color(0xFFECE7F4),
    this.linkColor = const Color(0xFFBFA4FF),
    this.fontFamily = 'NotoSansTC',
    this.fontSize = 18,
    this.lineHeight = 1.75,
    this.contentMaxWidth = 760,
    this.horizontalPadding = 26,
    this.maxImageBytes = 16 * 1024 * 1024,
    this.spineIndex = 0,
    this.initialAnchor,
    this.initialScrollFraction,
    this.scrollController,
    this.onReadingPosition,
    this.onTextSelection,
    this.onPageZoomChanged,
    this.onInternalLink,
    this.onFootnote,
    this.onExternalLink,
    super.key,
  })  : assert(fontSize >= 8 && fontSize <= 64),
        assert(lineHeight >= 1 && lineHeight <= 3),
        assert(contentMaxWidth >= 280);

  final FrameEpubChapterDocument chapter;
  final FrameEpubResourceLoader resourceLoader;
  final bool fixedLayout;
  final bool paginated;
  final bool isRightToLeft;
  final PageController? pageController;
  final List<FrameReaderAnnotation> annotations;
  final Color backgroundColor;
  final Color textColor;
  final Color linkColor;
  final String fontFamily;
  final double fontSize;
  final double lineHeight;
  final double contentMaxWidth;
  final double horizontalPadding;
  final int maxImageBytes;
  final int spineIndex;
  final XmlElement? initialAnchor;
  final double? initialScrollFraction;
  final ScrollController? scrollController;
  final void Function(String cfi, double chapterFraction)? onReadingPosition;
  final ValueChanged<FrameEpubTextSelection?>? onTextSelection;
  final ValueChanged<bool>? onPageZoomChanged;
  final ValueChanged<String>? onInternalLink;
  final ValueChanged<FrameEpubFootnote>? onFootnote;
  final ValueChanged<Uri>? onExternalLink;

  @override
  State<FrameEpubChapterView> createState() => _FrameEpubChapterViewState();
}

class _EpubStylesheetBundle {
  const _EpubStylesheetBundle(this.cascade, this.warnings);
  final FrameEpubCssCascade cascade;
  final List<String> warnings;
}

class _FrameEpubChapterViewState extends State<FrameEpubChapterView> {
  late Future<_EpubStylesheetBundle> _stylesFuture;
  final GlobalKey _viewportKey = GlobalKey();
  final Map<XmlElement, GlobalKey> _elementKeys = HashMap.identity();
  Map<XmlText, List<_ResolvedTextAnnotation>> _annotationRangesByNode =
      HashMap.identity();
  bool _restoreScheduled = false;
  final TransformationController _fixedLayoutTransformationController =
      TransformationController();
  bool _pageZoomed = false;
  final List<GlobalKey> _flowItemKeys = [];
  final List<GlobalKey> _paginationTextKeys = [];
  final Map<GlobalKey, _PaginatedTextPosition> _paginationTextPositions = {};
  int _paginationTextKeyCursor = 0;
  List<FrameEpubPage> _paginationPages = const [];
  bool _paginationReady = false;
  bool _paginationMeasurementScheduled = false;
  int _paginationRevision = 0;
  Size? _paginationViewportSize;
  int? _initialPageForRestore;

  @override
  void initState() {
    super.initState();
    _stylesFuture = _loadStylesheets();
    _fixedLayoutTransformationController.addListener(_handleZoomChanged);
  }

  void _handleZoomChanged() {
    final zoomed = _fixedLayoutTransformationController.value
            .getMaxScaleOnAxis() >
        1.02;
    if (zoomed == _pageZoomed) return;
    _pageZoomed = zoomed;
    widget.onPageZoomChanged?.call(zoomed);
  }

  @override
  void dispose() {
    _fixedLayoutTransformationController
      ..removeListener(_handleZoomChanged)
      ..dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FrameEpubChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chapter, widget.chapter) ||
        !identical(oldWidget.resourceLoader, widget.resourceLoader)) {
      _stylesFuture = _loadStylesheets();
      _elementKeys.clear();
      _restoreScheduled = false;
    } else {
      if (oldWidget.paginated != widget.paginated ||
          oldWidget.isRightToLeft != widget.isRightToLeft ||
          oldWidget.pageController != widget.pageController ||
          oldWidget.fontSize != widget.fontSize ||
          oldWidget.lineHeight != widget.lineHeight ||
          oldWidget.contentMaxWidth != widget.contentMaxWidth ||
          oldWidget.horizontalPadding != widget.horizontalPadding) {
        _resetPaginationMeasurement();
      }
      if (oldWidget.initialAnchor != widget.initialAnchor ||
          oldWidget.initialScrollFraction != widget.initialScrollFraction) {
        _restoreScheduled = false;
      }
    }
  }

  Future<_EpubStylesheetBundle> _loadStylesheets() async {
    final stylesheets = <String>[];
    final warnings = <String>[];
    final visited = <String>{};
    final loader = widget.resourceLoader;

    Future<void> appendStylesheet(String path) async {
      final graph = await loader.loadStylesheetGraph(path);
      warnings.addAll(graph.warnings);

      Future<void> appendNode(String currentPath) async {
        if (!visited.add(currentPath)) return;
        final sheet = graph.stylesheets[currentPath];
        if (sheet == null) return;
        for (final imported in sheet.imports) {
          final importedPath = imported.reference.path;
          if (importedPath != null &&
              imported.reference.resource?.kind ==
                  FrameEpubResourceKind.stylesheet) {
            await appendNode(importedPath);
          }
        }
        stylesheets.add(sheet.css);
      }

      await appendNode(path);
    }

    for (final element
        in widget.chapter.document.descendants.whereType<XmlElement>()) {
      final tag = element.name.local.toLowerCase();
      if (tag == 'style') {
        stylesheets.add(element.innerText);
        continue;
      }
      if (tag != 'link') continue;
      final rel = (_attribute(element, 'rel') ?? '')
          .split(RegExp(r'\s+'))
          .map((item) => item.toLowerCase())
          .toSet();
      if (!rel.contains('stylesheet')) continue;
      final media = (_attribute(element, 'media') ?? '').toLowerCase();
      if (media == 'print' || media == 'speech') continue;
      final href = _attribute(element, 'href');
      if (href == null || href.trim().isEmpty) continue;
      final reference = loader.resolve(
        href,
        fromPath: widget.chapter.resource.path,
      );
      final path = reference.path;
      if (!reference.isInternal ||
          path == null ||
          reference.resource?.kind != FrameEpubResourceKind.stylesheet) {
        warnings.add('略過無法載入的 EPUB 樣式表：$href');
        continue;
      }
      try {
        await appendStylesheet(path);
      } on Object catch (error) {
        warnings.add('EPUB 樣式表載入失敗：$path：$error');
      }
    }

    return _EpubStylesheetBundle(
      FrameEpubCssCascade.fromStylesheets(stylesheets),
      List.unmodifiable(warnings),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_EpubStylesheetBundle>(
      future: _stylesFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _message('無法載入 EPUB 樣式：${snapshot.error}');
        }
        if (!snapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFC5ADFF)),
          );
        }

        final body = _bodyElement(widget.chapter.document);
        if (body == null) return _message('EPUB 章節沒有可顯示的 body 內容。');
        _annotationRangesByNode = _resolveAnnotationRanges();

        final baseStyle = <String, String>{
          'display': 'block',
          'font-family': widget.fontFamily,
          'font-size': '${widget.fontSize}px',
          'line-height': '${widget.lineHeight}',
          'color': _colorToCss(widget.textColor),
          'white-space': 'normal',
          'visibility': 'visible',
        };
        final bodyStyle =
            _computedStyle(body, snapshot.data!.cascade, baseStyle);

        if (!widget.fixedLayout) _scheduleInitialRestore();

        if (widget.fixedLayout) {
          return ColoredBox(
            color: widget.backgroundColor,
            child: LayoutBuilder(
              builder: (context, constraints) => InteractiveViewer(
                transformationController: _fixedLayoutTransformationController,
                minScale: 1,
                maxScale: 4,
                boundaryMargin: const EdgeInsets.all(24),
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth,
                        maxHeight: constraints.maxHeight,
                      ),
                      child: _buildFlow(
                        body,
                        bodyStyle,
                        snapshot.data!.cascade,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        if (widget.paginated && widget.pageController != null) {
          return ColoredBox(
            color: widget.backgroundColor,
            child: LayoutBuilder(
              builder: (context, constraints) => _buildPaginatedLayout(
                context: context,
                body: body,
                bodyStyle: bodyStyle,
                cascade: snapshot.data!.cascade,
                constraints: constraints,
              ),
            ),
          );
        }

        return ColoredBox(
          color: widget.backgroundColor,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.contentMaxWidth),
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollUpdateNotification ||
                      notification is ScrollEndNotification) {
                    _scheduleVisiblePosition();
                  }
                  return false;
                },
                child: ListView(
                  key: _viewportKey,
                  controller: widget.scrollController,
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.horizontalPadding,
                    vertical: 30,
                  ),
                  children: _flowChildren(
                    body,
                    bodyStyle,
                    snapshot.data!.cascade,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }


  void _resetPaginationMeasurement() {
    _paginationRevision++;
    _paginationReady = false;
    _paginationMeasurementScheduled = false;
    _paginationPages = const [];
    _paginationViewportSize = null;
    _initialPageForRestore = null;
    _restoreScheduled = false;
  }

  void _ensureFlowItemKeys(int count) {
    while (_flowItemKeys.length < count) {
      _flowItemKeys.add(GlobalKey());
    }
    while (_flowItemKeys.length > count) {
      _flowItemKeys.removeLast();
    }
  }

  Widget _keyedFlowItem(List<Widget> items, int index) => KeyedSubtree(
        key: _flowItemKeys[index],
        child: items[index],
      );

  GlobalKey _nextPaginationTextKey() {
    if (_paginationTextKeyCursor == _paginationTextKeys.length) {
      _paginationTextKeys.add(GlobalKey());
    }
    return _paginationTextKeys[_paginationTextKeyCursor++];
  }

  int? _flowItemIndexForFragment(RenderBox fragment) {
    final origin = fragment.localToGlobal(Offset.zero);
    final center = origin + Offset(
      fragment.size.width / 2,
      fragment.size.height / 2,
    );
    for (var index = 0; index < _flowItemKeys.length; index++) {
      final object =
          _flowItemKeys[index].currentContext?.findRenderObject();
      if (object is! RenderBox || !object.hasSize) continue;
      final itemOrigin = object.localToGlobal(Offset.zero);
      final rect = itemOrigin & object.size;
      if (rect.contains(center)) return index;
    }
    return null;
  }

  _TextSpanSlice? _sliceTextSpan({
    required TextSpan span,
    required int start,
    required int end,
    required Map<TextSpan, _TextSpanSource> sourceSpans,
  }) {
    var cursor = 0;
    final sources = <FrameEpubTextRangeSource>[];

    InlineSpan? slice(InlineSpan current) {
      if (current is TextSpan) {
        final value = current.text ?? '';
        final nodeStart = cursor;
        final nodeEnd = nodeStart + value.length;
        final overlapStart = start > nodeStart ? start : nodeStart;
        final overlapEnd = end < nodeEnd ? end : nodeEnd;
        String? clippedText;
        if (overlapStart < overlapEnd) {
          final localStart = overlapStart - nodeStart;
          final localEnd = overlapEnd - nodeStart;
          clippedText = value.substring(localStart, localEnd);
          final source = sourceSpans[current];
          if (source != null) {
            sources.add(FrameEpubTextRangeSource(
              start: overlapStart - start,
              end: overlapEnd - start,
              node: source.node,
              sourceOffsets:
                  source.sourceOffsets.sublist(localStart, localEnd + 1),
            ));
          }
        }
        cursor = nodeEnd;
        final children = <InlineSpan>[];
        for (final child in current.children ?? const <InlineSpan>[]) {
          final childSlice = slice(child);
          if (childSlice != null) children.add(childSlice);
        }
        if (clippedText == null && children.isEmpty) return null;
        return TextSpan(
          text: clippedText,
          style: current.style,
          children: children,
        );
      }
      if (current is WidgetSpan) {
        final placeholderOffset = cursor++;
        return placeholderOffset >= start && placeholderOffset < end
            ? current
            : null;
      }
      return null;
    }

    final clipped = slice(span);
    if (clipped is! TextSpan) return null;
    return _TextSpanSlice(
      span: clipped,
      sources: List<FrameEpubTextRangeSource>.unmodifiable(sources),
    );
  }

  Widget _buildPaginatedLayout({
    required BuildContext context,
    required XmlElement body,
    required Map<String, String> bodyStyle,
    required FrameEpubCssCascade cascade,
    required BoxConstraints constraints,
  }) {
    if (!constraints.hasBoundedWidth ||
        !constraints.hasBoundedHeight ||
        constraints.maxWidth <= 0 ||
        constraints.maxHeight <= 0) {
      return ListView(
        key: _viewportKey,
        controller: widget.scrollController,
        padding: EdgeInsets.symmetric(
          horizontal: widget.horizontalPadding,
          vertical: 30,
        ),
        children: _flowChildren(body, bodyStyle, cascade),
      );
    }

    final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
    final contentWidth = viewportSize.width < widget.contentMaxWidth
        ? viewportSize.width
        : widget.contentMaxWidth;
    final availableHeight = viewportSize.height - 60;
    _paginationTextKeyCursor = 0;
    _paginationTextPositions.clear();
    final items = _flowChildren(
      body,
      bodyStyle,
      cascade,
      flattenBlockContainers: true,
      paginationWidth: (contentWidth - widget.horizontalPadding * 2)
          .clamp(1.0, contentWidth)
          .toDouble(),
      paginationMaxHeight: availableHeight > 1 ? availableHeight : 1,
      paginationTextScaler:
          MediaQuery.maybeOf(context)?.textScaler ?? TextScaler.noScaling,
    );
    _ensureFlowItemKeys(items.length);

    if (_paginationViewportSize != null &&
        _paginationViewportSize != viewportSize) {
      _resetPaginationMeasurement();
    }

    if (!_paginationReady) {
      _schedulePaginationMeasurement(
        viewportSize: viewportSize,
        availableHeight: availableHeight > 1 ? availableHeight : 1,
      );
      return Stack(
        children: [
          Offstage(
            child: SizedBox(
              width: viewportSize.width,
              child: Center(
                child: SizedBox(
                  width: contentWidth,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.horizontalPadding,
                      vertical: 30,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var index = 0; index < items.length; index++)
                          _keyedFlowItem(items, index),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Center(
            child: CircularProgressIndicator(color: Color(0xFFC5ADFF)),
          ),
        ],
      );
    }

    _scheduleInitialRestore();
    final pages = _paginationPages;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification ||
            notification is ScrollEndNotification) {
          _scheduleVisiblePosition();
        }
        return false;
      },
      child: PageView.builder(
        key: _viewportKey,
        controller: widget.pageController,
        reverse: widget.isRightToLeft,
        itemCount: pages.length,
        onPageChanged: (_) => _scheduleVisiblePosition(),
        itemBuilder: (context, pageIndex) {
          final page = pages[pageIndex];
          final pageItems = [
            for (final itemIndex in page.itemIndices)
              _keyedFlowItem(items, itemIndex),
          ];
          Widget content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: pageItems,
          );
          if (page.requiresVerticalScroll) {
            content = SingleChildScrollView(child: content);
          }
          return SizedBox(
            width: viewportSize.width,
            height: viewportSize.height,
            child: Center(
              child: SizedBox(
                width: contentWidth,
                height: viewportSize.height,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.horizontalPadding,
                    vertical: 30,
                  ),
                  child: content,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _schedulePaginationMeasurement({
    required Size viewportSize,
    required double availableHeight,
  }) {
    if (_paginationMeasurementScheduled) return;
    _paginationMeasurementScheduled = true;
    final revision = _paginationRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _paginationRevision) return;
      final heights = <double>[];
      for (final key in _flowItemKeys) {
        final object = key.currentContext?.findRenderObject();
        heights.add(
          object is RenderBox && object.hasSize ? object.size.height : 0,
        );
      }

      final pages = FrameEpubPageLayout.paginate(
        itemHeights: heights,
        availableHeight: availableHeight,
      );
      _initialPageForRestore = _measureInitialAnchorPage(pages);
      if (!mounted || revision != _paginationRevision) return;
      setState(() {
        _paginationPages = pages;
        _paginationViewportSize = viewportSize;
        _paginationReady = true;
        _paginationMeasurementScheduled = false;
        _restoreScheduled = false;
      });
    });
  }

  int? _measureInitialAnchorPage(List<FrameEpubPage> pages) {
    final anchor = widget.initialAnchor;
    if (anchor != null) {
      final point = FrameEpubCfi.firstTextPoint(anchor);
      if (point != null) {
        _PaginatedTextPosition? best;
        GlobalKey? bestKey;
        var bestDistance = 1 << 30;
        for (final entry in _paginationTextPositions.entries) {
          final position = entry.value;
          if (!identical(position.node, point.node)) continue;
          final distance = point.offset >= position.offset
              ? point.offset - position.offset
              : (1 << 29) + position.offset - point.offset;
          if (distance < bestDistance) {
            bestDistance = distance;
            best = position;
            bestKey = entry.key;
          }
        }
        final fragmentObject =
            bestKey?.currentContext?.findRenderObject();
        if (best != null &&
            fragmentObject is RenderBox &&
            fragmentObject.hasSize) {
          final itemIndex = _flowItemIndexForFragment(fragmentObject);
          if (itemIndex != null) {
            for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
              if (pages[pageIndex].itemIndices.contains(itemIndex)) {
                return pageIndex;
              }
            }
          }
        }
      }
    }

    RenderBox? anchorBox;
    XmlNode? current = widget.initialAnchor;
    while (current is XmlElement && anchorBox == null) {
      final object =
          _elementKeys[current]?.currentContext?.findRenderObject();
      if (object is RenderBox && object.hasSize) anchorBox = object;
      current = current.parent;
    }
    if (anchorBox == null) return null;
    final anchorTop = anchorBox.localToGlobal(Offset.zero).dy;

    var closestItem = 0;
    var closestDistance = double.infinity;
    for (var index = 0; index < _flowItemKeys.length; index++) {
      final object =
          _flowItemKeys[index].currentContext?.findRenderObject();
      if (object is! RenderBox || !object.hasSize) continue;
      final top = object.localToGlobal(Offset.zero).dy;
      final bottom = top + object.size.height;
      final distance = anchorTop < top
          ? top - anchorTop
          : anchorTop > bottom
              ? anchorTop - bottom
              : 0.0;
      if (distance < closestDistance) {
        closestDistance = distance;
        closestItem = index;
      }
      if (distance == 0) break;
    }

    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      if (pages[pageIndex].itemIndices.contains(closestItem)) {
        return pageIndex;
      }
    }
    return null;
  }

  GlobalKey _elementKey(XmlElement element) =>
      _elementKeys.putIfAbsent(element, GlobalKey.new);

  void _scheduleInitialRestore() {
    if (_restoreScheduled ||
        (widget.initialAnchor == null &&
            widget.initialScrollFraction == null)) {
      return;
    }
    _restoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.paginated && widget.pageController?.hasClients == true) {
        final controller = widget.pageController!;
        final targetPage = _initialPageForRestore ??
            (widget.initialScrollFraction != null && _paginationPages.length > 1
                ? (widget.initialScrollFraction! *
                        (_paginationPages.length - 1))
                    .round()
                : 0);
        controller.jumpToPage(
          targetPage.clamp(0, _paginationPages.length - 1).toInt(),
        );
      } else {
        final controller = widget.scrollController;
        if (controller != null &&
            controller.hasClients &&
            widget.initialScrollFraction != null &&
            controller.position.maxScrollExtent > 0) {
          final fraction = widget.initialScrollFraction!.clamp(0.0, 1.0);
          controller.jumpTo(
            controller.position.maxScrollExtent * fraction,
          );
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((__) {
        if (!mounted || widget.initialAnchor == null) return;
        final targetContext =
            _elementKeys[widget.initialAnchor]?.currentContext;
        if (targetContext == null) return;
        Scrollable.ensureVisible(
          targetContext,
          alignment: 0.04,
          duration: Duration.zero,
        );
      });
    });
  }

  void _scheduleVisiblePosition() {
    if (widget.fixedLayout || widget.onReadingPosition == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.onReadingPosition == null) return;
      final viewportObject = _viewportKey.currentContext?.findRenderObject();
      if (viewportObject is! RenderBox || !viewportObject.hasSize) return;
      final viewportOrigin = viewportObject.localToGlobal(Offset.zero);
      final viewportTop = viewportOrigin.dy;
      final viewportBottom = viewportTop + viewportObject.size.height;
      final viewportLeft = viewportOrigin.dx;
      final viewportRight = viewportLeft + viewportObject.size.width;

      if (widget.paginated) {
        final visible = <({XmlText node, int offset, double top})>[];
        for (final entry in _paginationTextPositions.entries) {
          final object = entry.key.currentContext?.findRenderObject();
          if (object is! RenderBox || !object.hasSize) continue;
          final origin = object.localToGlobal(Offset.zero);
          final top = origin.dy;
          final bottom = top + object.size.height;
          final right = origin.dx + object.size.width;
          if (bottom <= viewportTop + 1 ||
              top >= viewportBottom ||
              right <= viewportLeft + 1 ||
              origin.dx >= viewportRight - 1) {
            continue;
          }
          visible.add((
            node: entry.value.node,
            offset: entry.value.offset,
            top: top,
          ));
        }
        if (visible.isEmpty) return;
        visible.sort((a, b) => a.top.compareTo(b.top));
        final first = visible.first;
        final cfi = FrameEpubCfi.create(
          book: widget.resourceLoader.book,
          spineIndex: widget.spineIndex,
          textNode: first.node,
          offset: first.offset,
        );
        if (cfi == null) return;
        final pageController = widget.pageController;
        final fraction = pageController != null &&
                pageController.hasClients &&
                _paginationPages.length > 1
            ? ((pageController.page ?? 0).round() /
                    (_paginationPages.length - 1))
                .clamp(0.0, 1.0)
            : 0.0;
        widget.onReadingPosition!(cfi, fraction);
        return;
      }
      final crossing = <({XmlElement element, double top, int depth})>[];
      final below = <({XmlElement element, double top, int depth})>[];

      for (final entry in _elementKeys.entries) {
        final object = entry.value.currentContext?.findRenderObject();
        if (object is! RenderBox || !object.hasSize) continue;
        final origin = object.localToGlobal(Offset.zero);
        final top = origin.dy;
        final bottom = top + object.size.height;
        final right = origin.dx + object.size.width;
        if (bottom <= viewportTop + 8 ||
            top >= viewportBottom ||
            right <= viewportLeft + 1 ||
            origin.dx >= viewportRight - 1) {
          continue;
        }
        var depth = 0;
        XmlNode? parent = entry.key.parent;
        while (parent != null) {
          if (parent is XmlElement) depth++;
          parent = parent.parent;
        }
        final candidate = (element: entry.key, top: top, depth: depth);
        if (top <= viewportTop + 8) {
          crossing.add(candidate);
        } else {
          below.add(candidate);
        }
      }

      if (crossing.isNotEmpty) {
        crossing.sort((a, b) => b.depth.compareTo(a.depth));
      } else {
        below.sort((a, b) {
          final byTop = a.top.compareTo(b.top);
          return byTop != 0 ? byTop : b.depth.compareTo(a.depth);
        });
      }
      final candidates = crossing.isNotEmpty ? crossing : below;
      if (candidates.isEmpty) return;
      final point = FrameEpubCfi.firstTextPoint(candidates.first.element);
      if (point == null) return;
      final cfi = FrameEpubCfi.create(
        book: widget.resourceLoader.book,
        spineIndex: widget.spineIndex,
        textNode: point.node,
        offset: point.offset,
      );
      if (cfi == null) return;
      final pageController = widget.pageController;
      final fraction = widget.paginated &&
              pageController != null &&
              pageController.hasClients &&
              _paginationPages.length > 1
          ? ((pageController.page ?? 0).round() /
                  (_paginationPages.length - 1))
              .clamp(0.0, 1.0)
          : (() {
              final controller = widget.scrollController;
              return controller != null &&
                      controller.hasClients &&
                      controller.position.maxScrollExtent > 0
                  ? (controller.position.pixels /
                          controller.position.maxScrollExtent)
                      .clamp(0.0, 1.0)
                  : 0.0;
            })();
      widget.onReadingPosition!(cfi, fraction);
    });
  }

  Widget _message(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFFFC1C1),
              height: 1.6,
            ),
          ),
        ),
      );

  Map<XmlText, List<_ResolvedTextAnnotation>> _resolveAnnotationRanges() {
    final result = HashMap<XmlText, List<_ResolvedTextAnnotation>>.identity();
    if (widget.annotations.isEmpty) return result;

    final book = widget.resourceLoader.book;
    final document = widget.chapter.document;
    final textNodes = document.descendants.whereType<XmlText>().toList();
    final indices = HashMap<XmlText, int>.identity();
    for (var index = 0; index < textNodes.length; index++) {
      indices[textNodes[index]] = index;
    }

    for (final annotation in widget.annotations) {
      if (annotation.type != 'highlight' && annotation.type != 'note') {
        continue;
      }
      if (FrameEpubCfi.spineIndexFromCfi(book, annotation.cfi) !=
          widget.spineIndex) {
        continue;
      }
      final range = FrameEpubCfi.resolveRange(
        book: book,
        document: document,
        cfi: annotation.cfi,
      );
      if (range == null ||
          range.start.node is! XmlText ||
          range.end.node is! XmlText) {
        continue;
      }

      final startNode = range.start.node as XmlText;
      final endNode = range.end.node as XmlText;
      final startIndex = indices[startNode];
      final endIndex = indices[endNode];
      if (startIndex == null ||
          endIndex == null ||
          startIndex > endIndex ||
          range.start.offset < 0 ||
          range.start.offset > startNode.value.length ||
          range.end.offset < 0 ||
          range.end.offset > endNode.value.length ||
          (startIndex == endIndex &&
              range.start.offset >= range.end.offset)) {
        continue;
      }

      for (var index = startIndex; index <= endIndex; index++) {
        final node = textNodes[index];
        final start = index == startIndex ? range.start.offset : 0;
        final end = index == endIndex ? range.end.offset : node.value.length;
        if (start >= end) continue;
        result.putIfAbsent(node, () => []).add(
              _ResolvedTextAnnotation(
                start: start,
                end: end,
                type: annotation.type,
                color: annotation.color,
              ),
            );
      }
    }

    return result;
  }

  List<TextSpan> _sourceTextSpans(
    XmlText node,
    _PreparedEpubText prepared,
    Map<TextSpan, _TextSpanSource> sourceSpans,
  ) {
    final text = prepared.text;
    if (text.isEmpty) return const [];
    final ranges = _annotationRangesByNode[node] ??
        const <_ResolvedTextAnnotation>[];
    if (ranges.isEmpty) {
      final span = TextSpan(text: text);
      sourceSpans[span] = _TextSpanSource(node, prepared.sourceOffsets);
      return [span];
    }

    TextStyle? styleForUnit(int index) {
      final sourceStart = prepared.sourceOffsets[index];
      final sourceEnd = prepared.sourceOffsets[index + 1];
      _ResolvedTextAnnotation? highlight;
      _ResolvedTextAnnotation? underline;
      _ResolvedTextAnnotation? note;
      for (final range in ranges) {
        final overlaps = sourceEnd > sourceStart
            ? sourceStart < range.end && sourceEnd > range.start
            : sourceStart >= range.start && sourceStart < range.end;
        if (!overlaps) continue;
        if (range.type == 'note') {
          note ??= range;
        } else if (range.color == 'underline') {
          underline ??= range;
        } else {
          highlight ??= range;
        }
      }

      Color? background;
      Color? decorationColor;
      TextDecorationStyle? decorationStyle;
      double? decorationThickness;
      final decorations = <TextDecoration>[];

      if (highlight != null) {
        background = _highlightBackgroundColor(highlight.color);
      }
      if (underline != null) {
        decorations.add(TextDecoration.underline);
        decorationColor = const Color(0xFFA78BFA);
        decorationThickness = 2.2;
      }
      if (note != null) {
        if (!decorations.contains(TextDecoration.underline)) {
          decorations.add(TextDecoration.underline);
        }
        decorationColor = const Color(0xFF9873D6);
        decorationStyle = TextDecorationStyle.wavy;
        decorationThickness = 1.5;
      }
      if (background == null && decorations.isEmpty) return null;
      return TextStyle(
        backgroundColor: background,
        decoration: decorations.isEmpty
            ? null
            : TextDecoration.combine(decorations),
        decorationColor: decorationColor,
        decorationStyle: decorationStyle,
        decorationThickness: decorationThickness,
      );
    }

    final spans = <TextSpan>[];
    var runStart = 0;
    TextStyle? runStyle = styleForUnit(0);
    for (var index = 1; index < text.length; index++) {
      final nextStyle = styleForUnit(index);
      if (nextStyle == runStyle) continue;
      _appendStyledSourceRun(
        spans,
        sourceSpans,
        node,
        prepared,
        runStart,
        index,
        runStyle,
      );
      runStart = index;
      runStyle = nextStyle;
    }
    _appendStyledSourceRun(
      spans,
      sourceSpans,
      node,
      prepared,
      runStart,
      text.length,
      runStyle,
    );
    return spans;
  }

  void _appendStyledSourceRun(
    List<TextSpan> spans,
    Map<TextSpan, _TextSpanSource> sourceSpans,
    XmlText node,
    _PreparedEpubText prepared,
    int start,
    int end,
    TextStyle? style,
  ) {
    if (start >= end) return;
    final span = TextSpan(
      text: prepared.text.substring(start, end),
      style: style,
    );
    spans.add(span);
    sourceSpans[span] = _TextSpanSource(
      node,
      prepared.sourceOffsets.sublist(start, end + 1),
    );
  }

  Color _highlightBackgroundColor(String name) => switch (name) {
        'violet' => const Color(0x66A78BFA),
        'mint' => const Color(0x6665C9A5),
        'rose' => const Color(0x66E88EAF),
        'sky' => const Color(0x666FB9E8),
        _ => const Color(0x66F2C94C),
      };

  Widget _buildFlow(
    XmlElement element,
    Map<String, String> style,
    FrameEpubCssCascade cascade, {
    double? paginationWidth,
    double? paginationMaxHeight,
    TextScaler? paginationTextScaler,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: _flowChildren(
          element,
          style,
          cascade,
          paginationWidth: paginationWidth,
          paginationMaxHeight: paginationMaxHeight,
          paginationTextScaler: paginationTextScaler,
        ),
      );

  List<Widget> _flowChildren(
    XmlElement parent,
    Map<String, String> parentStyle,
    FrameEpubCssCascade cascade, {
    bool flattenBlockContainers = false,
    double? paginationWidth,
    double? paginationMaxHeight,
    TextScaler? paginationTextScaler,
  }) {
    final widgets = <Widget>[];
    final inlineSpans = <InlineSpan>[];
    final sourceSpans = HashMap<TextSpan, _TextSpanSource>.identity();

    void appendText(
      XmlText node,
      Map<String, String> style, {
      bool skipLeadingWhitespace = false,
    }) {
      final prepared = _prepareText(
        node,
        style['white-space'],
        style['text-transform'],
      );
      if (prepared.text.isEmpty ||
          (skipLeadingWhitespace &&
              prepared.text.trim().isEmpty &&
              inlineSpans.isEmpty)) {
        return;
      }
      inlineSpans.addAll(_sourceTextSpans(node, prepared, sourceSpans));
    }

    void flushInline() {
      if (inlineSpans.isEmpty) return;
      final spans = List<InlineSpan>.unmodifiable(inlineSpans);
      inlineSpans.clear();
      final root = TextSpan(
        style: _textStyle(parentStyle),
        children: spans,
      );
      final positionedSources = <FrameEpubTextRangeSource>[];
      final plainText = StringBuffer();
      var cursor = 0;

      void collect(InlineSpan span) {
        if (span is TextSpan) {
          final value = span.text;
          if (value != null && value.isNotEmpty) {
            final source = sourceSpans[span];
            if (source != null) {
              positionedSources.add(FrameEpubTextRangeSource(
                start: cursor,
                end: cursor + value.length,
                node: source.node,
                sourceOffsets: source.sourceOffsets,
              ));
            }
            plainText.write(value);
            cursor += value.length;
          }
          for (final child in span.children ?? const <InlineSpan>[]) {
            collect(child);
          }
        } else if (span is WidgetSpan) {
          plainText.write('\uFFFC');
          cursor++;
        }
      }

      collect(root);
      sourceSpans.clear();
      final displayedText = plainText.toString();
      final textAlign = _textAlign(parentStyle['text-align']);
      final textDirection = _textDirection(parentStyle['direction']);
      final ranges = paginationWidth != null && paginationMaxHeight != null
          ? FrameEpubTextPaginator.paginate(
              text: root,
              maxWidth: paginationWidth,
              maxHeight: paginationMaxHeight,
              textDirection: textDirection,
              textAlign: textAlign,
              textScaler: paginationTextScaler ?? TextScaler.noScaling,
            )
          : [TextRange(start: 0, end: displayedText.length)];

      for (final range in ranges) {
        final slice = _sliceTextSpan(
          span: root,
          start: range.start,
          end: range.end,
          sourceSpans: sourceSpans,
        );
        if (slice == null) continue;
        final fragmentText =
            displayedText.substring(range.start, range.end);
        final selectionSources = slice.sources;
        final fragmentKey = paginationWidth == null
            ? null
            : _nextPaginationTextKey();
        if (fragmentKey != null && selectionSources.isNotEmpty) {
          final source = selectionSources.first;
          _paginationTextPositions[fragmentKey] = _PaginatedTextPosition(
            source.node,
            source.sourceOffsets.first,
          );
        }
        final selectable = SelectableText.rich(
          slice.span,
          textAlign: textAlign,
          textDirection: textDirection,
          onSelectionChanged: (selection, cause) {
            final callback = widget.onTextSelection;
            if (callback == null) return;
            callback(FrameEpubTextSelectionMapper.map(
              selection: selection,
              displayedText: fragmentText,
              sources: selectionSources,
            ));
          },
        );
        widgets.add(
          fragmentKey == null
              ? selectable
              : KeyedSubtree(key: fragmentKey, child: selectable),
        );
      }
    }

    for (final child in parent.children) {
      if (child is XmlText) {
        appendText(child, parentStyle, skipLeadingWhitespace: true);
        continue;
      }
      if (child is! XmlElement) continue;
      final tag = child.name.local.toLowerCase();
      final childStyle = _computedStyle(child, cascade, parentStyle);
      if (childStyle['display'] == 'none' ||
          childStyle['visibility'] == 'hidden' ||
          _isNonVisualTag(tag) ||
          FrameEpubFootnoteResolver.isFootnoteTarget(child)) {
        continue;
      }
      if (tag == 'br') {
        inlineSpans.add(const TextSpan(text: '\n'));
      } else if (_isBlockElement(tag, childStyle) ||
          (widget.fixedLayout && tag == 'img')) {
        flushInline();
        if (flattenBlockContainers &&
            _canFlattenFlowContainer(child, childStyle)) {
          // Keep a zero-size anchor for fragment links and CFI restoration,
          // while allowing the contained paragraphs to flow onto separate pages.
          widgets.add(SizedBox(key: _elementKey(child), width: 0, height: 0));
          widgets.addAll(_flowChildren(
            child,
            childStyle,
            cascade,
            flattenBlockContainers: true,
            paginationWidth: paginationWidth,
            paginationMaxHeight: paginationMaxHeight,
            paginationTextScaler: paginationTextScaler,
          ));
        } else {
          widgets.add(_buildBlock(
            child,
            childStyle,
            cascade,
            paginationWidth: paginationWidth,
            paginationMaxHeight: paginationMaxHeight,
            paginationTextScaler: paginationTextScaler,
          ));
        }
      } else {
        inlineSpans.add(_inlineSpan(
          child,
          childStyle,
          cascade,
          sourceSpans,
        ));
      }
    }
    flushInline();
    return widgets;
  }

  _PreparedEpubText _prepareText(
    XmlText node,
    String? whiteSpace,
    String? transform,
  ) {
    final source = node.value;
    final collapseWhitespace = whiteSpace != 'pre' && whiteSpace != 'pre-wrap';
    final output = StringBuffer();
    final sourceOffsets = <int>[0];
    var index = 0;

    bool isCollapsibleWhitespace(int codeUnit) =>
        codeUnit == 0x09 ||
        codeUnit == 0x0A ||
        codeUnit == 0x0D ||
        codeUnit == 0x20;

    while (index < source.length) {
      final start = index;
      final firstCodeUnit = source.codeUnitAt(index);
      final hasSurrogatePair = firstCodeUnit >= 0xD800 &&
          firstCodeUnit <= 0xDBFF &&
          index + 1 < source.length &&
          source.codeUnitAt(index + 1) >= 0xDC00 &&
          source.codeUnitAt(index + 1) <= 0xDFFF;
      final rune = hasSurrogatePair
          ? 0x10000 +
              ((firstCodeUnit - 0xD800) << 10) +
              (source.codeUnitAt(index + 1) - 0xDC00)
          : firstCodeUnit;
      final codeUnits = hasSurrogatePair ? 2 : 1;
      var end = index + codeUnits;
      String rendered;
      if (collapseWhitespace && isCollapsibleWhitespace(rune)) {
        while (end < source.length &&
            isCollapsibleWhitespace(source.codeUnitAt(end))) {
          end++;
        }
        rendered = ' ';
      } else {
        rendered = _transformText(String.fromCharCode(rune), transform);
      }

      if (rendered.isNotEmpty) {
        output.write(rendered);
        for (var unit = 1; unit <= rendered.length; unit++) {
          sourceOffsets.add(unit == rendered.length ? end : start);
        }
      }
      index = end;
    }

    return _PreparedEpubText(output.toString(), sourceOffsets);
  }

  bool _canFlattenFlowContainer(
    XmlElement element,
    Map<String, String> style,
  ) {
    const transparentContainers = {
      'div',
      'section',
      'article',
      'main',
      'header',
      'footer',
      'aside',
      'nav',
      'p',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
    };
    if (!transparentContainers.contains(element.name.local.toLowerCase())) {
      return false;
    }
    if (_boxInsets(style, 'padding', widget.fontSize) != EdgeInsets.zero ||
        _boxInsets(style, 'margin', widget.fontSize) != EdgeInsets.zero ||
        _cssColor(style['background-color']) != null ||
        _backgroundFromShorthand(style['background']) != null) {
      return false;
    }
    return true;
  }

  Widget _buildBlock(
    XmlElement element,
    Map<String, String> style,
    FrameEpubCssCascade cascade, {
    double? paginationWidth,
    double? paginationMaxHeight,
    TextScaler? paginationTextScaler,
  }) {
    final tag = element.name.local.toLowerCase();
    final blockPadding = _boxInsets(style, 'padding', widget.fontSize);
    final blockMargin = _boxInsets(style, 'margin', widget.fontSize);
    final innerWidth = paginationWidth == null
        ? null
        : (paginationWidth - blockPadding.horizontal - blockMargin.horizontal)
            .clamp(1.0, paginationWidth)
            .toDouble();
    Widget child;
    if (tag == 'hr') {
      child = const Divider(color: Color(0x664D455B), height: 24);
    } else if (tag == 'ul' || tag == 'ol') {
      child = _buildList(
        element,
        style,
        cascade,
        paginationWidth: innerWidth,
        paginationMaxHeight: paginationMaxHeight,
        paginationTextScaler: paginationTextScaler,
      );
    } else if (tag == 'img') {
      child = _buildImage(element, style, block: true);
    } else if (tag == 'pre') {
      child = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF211D2B),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          element.innerText,
          style: _textStyle(style).copyWith(
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      );
    } else if (tag == 'blockquote') {
      child = Container(
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: Color(0xFF8065B8), width: 3),
          ),
        ),
        padding: const EdgeInsets.only(left: 16),
        child: _buildFlow(
          element,
          style,
          cascade,
          paginationWidth:
              innerWidth == null
                  ? null
                  : (innerWidth - 19).clamp(1.0, innerWidth).toDouble(),
          paginationMaxHeight: paginationMaxHeight,
          paginationTextScaler: paginationTextScaler,
        ),
      );
    } else {
      child = _buildFlow(
        element,
        style,
        cascade,
        paginationWidth: innerWidth,
        paginationMaxHeight: paginationMaxHeight,
        paginationTextScaler: paginationTextScaler,
      );
    }

    final padding = blockPadding;
    final margin = blockMargin;
    final background = _cssColor(style['background-color']) ??
        _backgroundFromShorthand(style['background']);
    if (padding != EdgeInsets.zero) {
      child = Padding(padding: padding, child: child);
    }
    if (background != null) {
      child = DecoratedBox(
        decoration: BoxDecoration(color: background),
        child: child,
      );
    }
    if (margin != EdgeInsets.zero) {
      child = Padding(padding: margin, child: child);
    }
    return KeyedSubtree(key: _elementKey(element), child: child);
  }

  Widget _buildList(
    XmlElement list,
    Map<String, String> style,
    FrameEpubCssCascade cascade, {
    double? paginationWidth,
    double? paginationMaxHeight,
    TextScaler? paginationTextScaler,
  }) {
    final ordered = list.name.local.toLowerCase() == 'ol';
    final items = list.children.whereType<XmlElement>().where(
          (element) =>
              element.name.local.toLowerCase() == 'li' &&
              !FrameEpubFootnoteResolver.isFootnoteTarget(element),
        );
    final widgets = <Widget>[];
    var index = 0;
    for (final item in items) {
      index++;
      final itemStyle = _computedStyle(item, cascade, style);
      final marker = ordered ? '$index.' : _listMarker(style['list-style-type']);
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: KeyedSubtree(
          key: _elementKey(item),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 28,
                child: Text(marker, style: _textStyle(itemStyle)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _flowChildren(
                    item,
                    itemStyle,
                    cascade,
                    paginationWidth: paginationWidth == null
                        ? null
                        : (paginationWidth - 28)
                            .clamp(1.0, paginationWidth)
                            .toDouble(),
                    paginationMaxHeight: paginationMaxHeight,
                    paginationTextScaler: paginationTextScaler,
                  ),
                ),
              ),
            ],
          ),
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }


  Future<void> _handleInternalAnchor(XmlElement anchor, String href) async {
    final footnoteCallback = widget.onFootnote;
    if (footnoteCallback != null) {
      final footnote = await FrameEpubFootnoteResolver.resolve(
        anchor: anchor,
        chapter: widget.chapter,
        resourceLoader: widget.resourceLoader,
      );
      if (!mounted) return;
      if (footnote != null) {
        footnoteCallback(footnote);
        return;
      }
    }
    if (mounted) widget.onInternalLink?.call(href);
  }

  InlineSpan _inlineSpan(
    XmlElement element,
    Map<String, String> style,
    FrameEpubCssCascade cascade,
    Map<TextSpan, _TextSpanSource> sourceSpans,
  ) {
    final tag = element.name.local.toLowerCase();
    if (_isNonVisualTag(tag) ||
        style['display'] == 'none' ||
        FrameEpubFootnoteResolver.isFootnoteTarget(element)) {
      return const TextSpan();
    }
    if (tag == 'br') return const TextSpan(text: '\n');
    if (tag == 'img') {
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _buildImage(element, style),
      );
    }
    if (tag == 'svg' || tag == 'math') {
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _unsupportedInlineObject(tag),
      );
    }

    final children = <InlineSpan>[];
    for (final child in element.children) {
      if (child is XmlText) {
        final prepared = _prepareText(
          child,
          style['white-space'],
          style['text-transform'],
        );
        children.addAll(_sourceTextSpans(child, prepared, sourceSpans));
      } else if (child is XmlElement) {
        final childTag = child.name.local.toLowerCase();
        final childStyle = _computedStyle(child, cascade, style);
        if (_isNonVisualTag(childTag) ||
            childStyle['display'] == 'none' ||
            childStyle['visibility'] == 'hidden') {
          continue;
        }
        children.add(_inlineSpan(
          child,
          childStyle,
          cascade,
          sourceSpans,
        ));
      }
    }

    var textStyle = _textStyle(style);
    if (tag == 'a') {
      final href = _attribute(element, 'href') ?? '';
      VoidCallback? onTap;
      if (href.isNotEmpty) {
        final reference = widget.resourceLoader.resolve(
          href,
          fromPath: widget.chapter.resource.path,
        );
        if (reference.isInternal &&
            (widget.onInternalLink != null || widget.onFootnote != null)) {
          onTap = () => _handleInternalAnchor(element, href);
        } else if (reference.isExternal && widget.onExternalLink != null) {
          final uri = Uri.tryParse(href);
          if (uri != null) onTap = () => widget.onExternalLink!(uri);
        }
      }
      textStyle = textStyle.copyWith(
        color: widget.linkColor,
        decoration: TextDecoration.underline,
      );
      if (onTap != null) {
        return WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Text.rich(
              TextSpan(style: textStyle, children: children),
              softWrap: false,
            ),
          ),
        );
      }
    } else if (tag == 'mark') {
      textStyle = textStyle.copyWith(
        backgroundColor: const Color(0x66D8B45B),
      );
    }
    return TextSpan(
      style: textStyle,
      children: children,
    );
  }

  Widget _buildImage(
    XmlElement element,
    Map<String, String> style, {
    bool block = false,
  }) {
    final source = _attribute(element, 'src');
    final alt = _attribute(element, 'alt') ?? 'EPUB 圖片';
    if (source == null || source.trim().isEmpty) return _imagePlaceholder(alt);
    final reference = widget.resourceLoader.resolve(
      source,
      fromPath: widget.chapter.resource.path,
    );
    final resource = reference.resource;
    if (!reference.isInternal ||
        resource == null ||
        resource.kind != FrameEpubResourceKind.image) {
      return _imagePlaceholder(alt);
    }
    if (resource.size > widget.maxImageBytes) {
      return _imagePlaceholder('$alt（超過圖片讀取上限）');
    }

    return _FrameEpubImage(
      loader: widget.resourceLoader,
      resource: resource,
      maxBytes: widget.maxImageBytes,
      fit: widget.fixedLayout ? BoxFit.contain : BoxFit.scaleDown,
      maxWidth: _cssDimension(style['width'], widget.fontSize) ??
          (block ? double.infinity : 320),
      maxHeight: _cssDimension(style['height'], widget.fontSize) ??
          (widget.fixedLayout ? double.infinity : 680),
      alt: alt,
    );
  }

  Widget _imagePlaceholder(String label) => Container(
        constraints: const BoxConstraints(
          minWidth: 48,
          minHeight: 42,
          maxWidth: 240,
          maxHeight: 90,
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF211D2B),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFAAA2B8),
            fontSize: 11,
          ),
        ),
      );

  Widget _unsupportedInlineObject(String tag) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF211D2B),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          tag == 'svg' ? 'SVG 圖形暫未支援' : '數學公式暫未支援',
          style: const TextStyle(color: Color(0xFFAAA2B8), fontSize: 11),
        ),
      );

  Map<String, String> _computedStyle(
    XmlElement element,
    FrameEpubCssCascade cascade,
    Map<String, String> parent,
  ) {
    final style = Map<String, String>.from(
      cascade.resolve(
        element,
        parentStyle: parent,
        inlineStyle: _attribute(element, 'style'),
      ),
    );
    final parentSize = _length(parent['font-size'], widget.fontSize);
    final size = _cssFontSize(
      style['font-size'],
      parentSize,
      widget.fontSize,
    );
    style['font-size'] = '${size}px';
    return style;
  }

  TextStyle _textStyle(Map<String, String> style) {
    final size = _length(style['font-size'], widget.fontSize);
    return TextStyle(
      color: _cssColor(style['color']) ?? widget.textColor,
      fontFamily: _fontFamily(style['font-family'], widget.fontFamily),
      fontSize: size,
      fontWeight: _fontWeight(style['font-weight']),
      fontStyle: style['font-style'] == 'italic' ||
              style['font-style'] == 'oblique'
          ? FontStyle.italic
          : FontStyle.normal,
      decoration: _textDecoration(style['text-decoration']),
      height: _lineHeight(style['line-height'], size),
      letterSpacing: _cssDimension(style['letter-spacing'], size),
    );
  }

  static bool _isNonVisualTag(String tag) => const {
        'head',
        'title',
        'meta',
        'link',
        'style',
        'script',
        'noscript',
        'template',
        'iframe',
        'object',
        'embed',
      }.contains(tag);

  static bool _isBlockElement(String tag, Map<String, String> style) {
    if (style['display'] == 'block' ||
        style['display'] == 'list-item' ||
        style['display'] == 'table' ||
        style['display'] == 'flex') {
      return true;
    }
    return const {
      'address',
      'article',
      'aside',
      'blockquote',
      'div',
      'dl',
      'dt',
      'dd',
      'figure',
      'figcaption',
      'footer',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'header',
      'hr',
      'li',
      'main',
      'nav',
      'ol',
      'p',
      'pre',
      'section',
      'table',
      'ul',
    }.contains(tag);
  }

  static XmlElement? _bodyElement(XmlDocument document) {
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (element.name.local.toLowerCase() == 'body') return element;
    }
    return document.rootElement;
  }

  static String? _attribute(XmlElement element, String name) {
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() == name.toLowerCase()) {
        return attribute.value;
      }
    }
    return null;
  }

  static String _listMarker(String? value) {
    switch (value?.toLowerCase()) {
      case 'circle':
        return '○';
      case 'square':
        return '▪';
      case 'none':
        return '';
      default:
        return '•';
    }
  }

  static String _transformText(String value, String? transform) {
    switch (transform?.toLowerCase()) {
      case 'uppercase':
        return value.toUpperCase();
      case 'lowercase':
        return value.toLowerCase();
      default:
        return value;
    }
  }

  static TextAlign _textAlign(String? value) {
    switch (value?.toLowerCase()) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      case 'justify':
        return TextAlign.justify;
      case 'start':
        return TextAlign.start;
      case 'end':
        return TextAlign.end;
      default:
        return TextAlign.left;
    }
  }

  static TextDirection _textDirection(String? value) =>
      value?.toLowerCase() == 'rtl' ? TextDirection.rtl : TextDirection.ltr;

  static FontWeight _fontWeight(String? value) {
    switch (value?.toLowerCase()) {
      case 'bold':
      case 'bolder':
      case '600':
      case '700':
      case '800':
      case '900':
        return FontWeight.bold;
      case '100':
        return FontWeight.w100;
      case '200':
        return FontWeight.w200;
      case '300':
        return FontWeight.w300;
      case '500':
        return FontWeight.w500;
      default:
        return FontWeight.normal;
    }
  }

  static TextDecoration _textDecoration(String? value) {
    final tokens = (value ?? 'none').toLowerCase().split(RegExp(r'\s+'));
    final decorations = <TextDecoration>[
      if (tokens.contains('underline')) TextDecoration.underline,
      if (tokens.contains('line-through')) TextDecoration.lineThrough,
      if (tokens.contains('overline')) TextDecoration.overline,
    ];
    return decorations.isEmpty
        ? TextDecoration.none
        : TextDecoration.combine(decorations);
  }

  static String _fontFamily(String? value, String fallback) {
    if (value == null || value.trim().isEmpty) return fallback;
    final first = value
        .split(',')
        .first
        .trim()
        .replaceAll('"', '')
        .replaceAll("'", '');
    if (const {'serif', 'sans-serif', 'monospace', 'cursive', 'fantasy'}
        .contains(first.toLowerCase())) {
      return first.toLowerCase() == 'monospace' ? 'monospace' : fallback;
    }
    if (const {'NotoSansTC', 'NotoSansSCFallback'}.contains(first)) {
      return first;
    }
    return fallback;
  }

  static double _cssFontSize(String? value, double parent, double root) {
    if (value == null || value.isEmpty) return parent;
    switch (value.toLowerCase().trim()) {
      case 'xx-small':
        return root * .65;
      case 'x-small':
        return root * .75;
      case 'small':
        return root * .85;
      case 'medium':
        return root;
      case 'large':
        return root * 1.15;
      case 'x-large':
        return root * 1.3;
      case 'xx-large':
        return root * 1.5;
      case 'smaller':
        return parent * .8;
      case 'larger':
        return parent * 1.2;
    }
    return _cssDimension(value, parent) ?? parent;
  }

  static double _length(String? value, double fallback) =>
      _cssDimension(value, fallback) ?? fallback;

  static double? _cssDimension(String? source, double reference) {
    if (source == null) return null;
    final value = source.trim().toLowerCase();
    if (value == '0') return 0;
    final match =
        RegExp(r'^([+-]?(?:\d+\.?\d*|\.\d+))(px|pt|em|rem|%)?$')
            .firstMatch(value);
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!);
    if (number == null) return null;
    switch (match.group(2)) {
      case 'pt':
        return number * 96 / 72;
      case 'em':
      case 'rem':
        return reference * number;
      case '%':
        return reference * number / 100;
      default:
        return number;
    }
  }

  static double _lineHeight(String? value, double fontSize) {
    if (value == null || value.isEmpty || value == 'normal') return 1.5;
    final number = double.tryParse(value);
    if (number != null) return number.clamp(0.8, 3.5);
    final pixels = _cssDimension(value, fontSize);
    if (pixels == null || fontSize <= 0) return 1.5;
    return (pixels / fontSize).clamp(0.8, 3.5);
  }

  static EdgeInsets _boxInsets(
    Map<String, String> style,
    String prefix,
    double fontSize,
  ) {
    final values = (style[prefix] ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((item) => item.isNotEmpty)
        .toList();

    String pick(int side) {
      final suffix = ['top', 'right', 'bottom', 'left'][side];
      final exact = style['$prefix-$suffix'];
      if (exact != null) return exact;
      final logical = side == 0
          ? style['$prefix-block-start']
          : side == 2
              ? style['$prefix-block-end']
              : side == 1
                  ? style['$prefix-inline-end']
                  : style['$prefix-inline-start'];
      if (logical != null) return logical;
      if (values.isEmpty) return '0';
      if (values.length == 1) return values[0];
      if (values.length == 2) return values[side.isEven ? 0 : 1];
      if (values.length == 3) return values[side == 0 ? 0 : side == 2 ? 2 : 1];
      return values[side];
    }

    double sideValue(int index) =>
        _cssDimension(pick(index), fontSize) ?? 0;
    return EdgeInsets.fromLTRB(
      sideValue(3),
      sideValue(0),
      sideValue(1),
      sideValue(2),
    );
  }

  static Color? _backgroundFromShorthand(String? value) {
    if (value == null) return null;
    for (final token in value.split(RegExp(r'\s+'))) {
      final color = _cssColor(token);
      if (color != null) return color;
    }
    return null;
  }

  static Color? _cssColor(String? source) {
    if (source == null) return null;
    final value = source.trim().toLowerCase();
    const named = {
      'transparent': Color(0x00000000),
      'black': Color(0xFF000000),
      'white': Color(0xFFFFFFFF),
      'red': Color(0xFFFF0000),
      'green': Color(0xFF008000),
      'blue': Color(0xFF0000FF),
      'yellow': Color(0xFFFFFF00),
      'gray': Color(0xFF808080),
      'grey': Color(0xFF808080),
      'purple': Color(0xFF800080),
      'orange': Color(0xFFFFA500),
      'navy': Color(0xFF000080),
    };
    if (named.containsKey(value)) return named[value];
    if (value.startsWith('#')) {
      var hex = value.substring(1);
      if (hex.length == 3 || hex.length == 4) {
        hex = hex.split('').map((char) => '$char$char').join();
      }
      if (hex.length == 6) {
        final rgb = int.tryParse(hex, radix: 16);
        return rgb == null ? null : Color(0xFF000000 | rgb);
      }
      if (hex.length == 8) {
        final rgba = int.tryParse(hex, radix: 16);
        if (rgba == null) return null;
        return Color(((rgba & 0xff) << 24) | (rgba >> 8));
      }
    }
    final rgb = RegExp(r'^rgba?\(([^)]+)\)$').firstMatch(value);
    if (rgb == null) return null;
    final parts = rgb.group(1)!.split(',').map((part) => part.trim()).toList();
    if (parts.length < 3) return null;

    int channel(String part) {
      if (part.endsWith('%')) {
        return ((double.tryParse(part.substring(0, part.length - 1)) ?? 0) *
                2.55)
            .round()
            .clamp(0, 255);
      }
      return (double.tryParse(part) ?? 0).round().clamp(0, 255);
    }

    final red = channel(parts[0]);
    final green = channel(parts[1]);
    final blue = channel(parts[2]);
    final alpha = parts.length > 3
        ? ((double.tryParse(parts[3]) ?? 1) * 255).round().clamp(0, 255)
        : 255;
    return Color((alpha << 24) | (red << 16) | (green << 8) | blue);
  }

  static String _colorToCss(Color color) =>
      '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';
}

class _FrameEpubImage extends StatefulWidget {
  const _FrameEpubImage({
    required this.loader,
    required this.resource,
    required this.maxBytes,
    required this.fit,
    required this.maxWidth,
    required this.maxHeight,
    required this.alt,
  });

  final FrameEpubResourceLoader loader;
  final FrameEpubResource resource;
  final int maxBytes;
  final BoxFit fit;
  final double maxWidth;
  final double maxHeight;
  final String alt;

  @override
  State<_FrameEpubImage> createState() => _FrameEpubImageState();
}

class _FrameEpubImageState extends State<_FrameEpubImage> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant _FrameEpubImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.resource, widget.resource) ||
        !identical(oldWidget.loader, widget.loader)) {
      _bytes = _load();
    }
  }

  Future<Uint8List> _load() => widget.loader.readBytes(
        widget.resource,
        maxBytes: widget.maxBytes,
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return SizedBox(
            width: widget.maxWidth.isFinite ? widget.maxWidth : 48,
            height: 80,
            child: Center(
              child: snapshot.hasError
                  ? const Icon(
                      Icons.broken_image_outlined,
                      color: Color(0xFF8F829F),
                    )
                  : const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : widget.maxWidth;
            final cacheWidth = (availableWidth.isFinite
                    ? availableWidth * dpr
                    : 1600)
                .round()
                .clamp(96, 2048)
                .toInt();
            final image = Image.memory(
              snapshot.data!,
              fit: widget.fit,
              cacheWidth: cacheWidth,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.broken_image_outlined,
                color: Color(0xFF8F829F),
              ),
              semanticLabel: widget.alt,
            );
            if (widget.maxWidth.isInfinite && widget.maxHeight.isInfinite) {
              return SizedBox.expand(child: image);
            }
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.maxWidth,
                maxHeight: widget.maxHeight,
              ),
              child: image,
            );
          },
        );
      },
    );
  }
}
