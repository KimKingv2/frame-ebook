import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';

import 'frame_epub_ruby_annotation.dart';

/// Semantic hit target paired with selectable inline anchor text.
///
/// The visible link remains ordinary selectable TextSpan content. This
/// one-pixel placeholder only exposes a semantic link action and has known
/// dimensions, so long linked paragraphs can still be paginated safely.
class FrameEpubLinkSemanticsPlaceholder extends StatelessWidget {
  const FrameEpubLinkSemanticsPlaceholder({
    required this.label,
    required this.onTap,
    required this.width,
    required this.height,
    super.key,
  })  : assert(width > 0),
        assert(height > 0);

  final String label;
  final VoidCallback onTap;
  final double width;
  final double height;

  PlaceholderDimensions get placeholderDimensions => PlaceholderDimensions(
        size: Size(width, height),
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
      );

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        explicitChildNodes: true,
        label: label,
        link: true,
        onTap: onTap,
        child: GestureDetector(
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(width: width, height: height),
        ),
      );
}

/// Splits rich text into line-aligned fragments that fit a page's height.
///
/// Fixed-size, childless SizedBoxes (such as the reader's first-line indent)
/// and ruby annotations have deterministic placeholder dimensions and can be
/// measured by TextPainter. Images, SVG and interactive widgets still require
/// their real render boxes, so paragraphs containing them remain intact.
class FrameEpubTextPaginator {
  FrameEpubTextPaginator._();

  static List<TextRange> paginate({
    required InlineSpan text,
    required double maxWidth,
    required double maxHeight,
    required TextDirection textDirection,
    required TextAlign textAlign,
    required TextScaler textScaler,
    int orphans = 2,
    int widows = 2,
  }) {
    final plainText = text.toPlainText(
      includeSemanticsLabels: false,
      includePlaceholders: true,
    );
    final whole = TextRange(start: 0, end: plainText.length);
    if (plainText.isEmpty ||
        !maxWidth.isFinite ||
        !maxHeight.isFinite ||
        maxWidth <= 0 ||
        maxHeight <= 0) {
      return [whole];
    }
    final placeholderDimensions = _supportedPlaceholderDimensions(text);
    if (placeholderDimensions == null) return [whole];

    final painter = TextPainter(
      text: text,
      textDirection: textDirection,
      textAlign: textAlign,
      textScaler: textScaler,
    );
    try {
      if (placeholderDimensions.isNotEmpty) {
        painter.setPlaceholderDimensions(placeholderDimensions);
      }
      painter.layout(maxWidth: maxWidth);
      if (painter.height <= maxHeight + 0.5) return [whole];

      final metrics = painter.computeLineMetrics();
      if (metrics.length <= 1) return [whole];

      final lines = <({TextRange range, double height})>[];
      var cursor = 0;
      for (final metric in metrics) {
        if (cursor >= plainText.length) break;
        final boundary = painter.getLineBoundary(
          TextPosition(offset: cursor),
        );
        final end = boundary.end.clamp(0, plainText.length).toInt();
        if (end <= cursor) return [whole];
        lines.add((
          range: TextRange(start: cursor, end: end),
          height: metric.height,
        ));
        cursor = end;
      }
      // A mismatch means TextPainter's line ranges cannot safely represent
      // the rendered text (for example, unusual bidi/paragraph boundaries).
      if (cursor != plainText.length || lines.isEmpty) return [whole];

      final lineGroups =
          <List<({TextRange range, double height})>>[];
      var currentLines = <({TextRange range, double height})>[];
      var currentHeight = 0.0;
      for (final line in lines) {
        if (!line.height.isFinite || line.height > maxHeight) return [whole];
        if (currentLines.isNotEmpty &&
            currentHeight + line.height > maxHeight + 0.5) {
          lineGroups.add(currentLines);
          currentLines = <({TextRange range, double height})>[];
          currentHeight = 0;
        }
        currentLines.add(line);
        currentHeight += line.height;
      }
      if (currentLines.isNotEmpty) lineGroups.add(currentLines);
      if (lineGroups.length <= 1) return [whole];

      final minimumOrphans = orphans.clamp(1, 50).toInt();
      final minimumWidows = widows.clamp(1, 50).toInt();
      int minimumLinesForGroup(int index) {
        if (index == 0) return minimumOrphans;
        if (index == lineGroups.length - 1) return minimumWidows;
        return minimumOrphans > minimumWidows
            ? minimumOrphans
            : minimumWidows;
      }

      double groupHeight(
        List<({TextRange range, double height})> group,
      ) =>
          group.fold<double>(0, (total, line) => total + line.height);

      for (var index = 0; index < lineGroups.length; index++) {
        final group = lineGroups[index];
        var deficit = minimumLinesForGroup(index) - group.length;
        while (deficit > 0) {
          if (index > 0) {
            final previous = lineGroups[index - 1];
            final previousMinimum = minimumLinesForGroup(index - 1);
            while (deficit > 0 &&
                previous.length > previousMinimum &&
                groupHeight(group) + previous.last.height <= maxHeight + 0.5) {
              group.insert(0, previous.removeLast());
              deficit--;
            }
          }

          if (deficit > 0 && index + 1 < lineGroups.length) {
            final next = lineGroups[index + 1];
            final nextMinimum = minimumLinesForGroup(index + 1);
            while (deficit > 0 &&
                next.length > nextMinimum &&
                groupHeight(group) + next.first.height <= maxHeight + 0.5) {
              group.add(next.removeAt(0));
              deficit--;
            }
          }
          if (deficit > 0) return [whole];
        }
      }

      final fragments = <TextRange>[
        for (final group in lineGroups)
          TextRange(
            start: group.first.range.start,
            end: group.last.range.end,
          ),
      ];

      var expectedStart = 0;
      for (final fragment in fragments) {
        if (fragment.start != expectedStart ||
            fragment.end <= fragment.start) {
          return [whole];
        }
        expectedStart = fragment.end;
      }
      return expectedStart == plainText.length ? fragments : [whole];
    } finally {
      painter.dispose();
    }
  }

  static List<PlaceholderDimensions>? _supportedPlaceholderDimensions(
    InlineSpan span,
  ) {
    final dimensions = <PlaceholderDimensions>[];
    var hasUnsupportedPlaceholder = false;
    span.visitChildren((child) {
      if (child is! WidgetSpan) return true;
      final widget = child.child;
      if (widget is FrameEpubRubyAnnotation) {
        dimensions.add(widget.placeholderDimensions);
        return true;
      }
      if (widget is FrameEpubLinkSemanticsPlaceholder) {
        dimensions.add(widget.placeholderDimensions);
        return true;
      }

      // The chapter renderer uses this exact shape for CSS text-indent:
      // WidgetSpan(middle, SizedBox(width: indent, height: 0)).
      // It is safe to measure because no intrinsic child layout is involved.
      if (widget is SizedBox &&
          widget.child == null &&
          widget.width != null &&
          widget.height != null &&
          widget.width!.isFinite &&
          widget.height!.isFinite &&
          widget.width! >= 0 &&
          widget.height! >= 0 &&
          ((child.alignment != PlaceholderAlignment.baseline &&
                  child.alignment != PlaceholderAlignment.aboveBaseline &&
                  child.alignment != PlaceholderAlignment.belowBaseline) ||
              child.baseline != null)) {
        dimensions.add(PlaceholderDimensions(
          size: Size(widget.width!, widget.height!),
          alignment: child.alignment,
          baseline: child.baseline,
        ));
        return true;
      }

      // Images, SVG and interactive widgets need their actual render-box
      // dimensions. Do not guess: leave their containing paragraph intact.
      hasUnsupportedPlaceholder = true;
      return true;
    });
    return hasUnsupportedPlaceholder ? null : dimensions;
  }
}
