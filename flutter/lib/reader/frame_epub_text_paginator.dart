import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';

import 'frame_epub_ruby_annotation.dart';

/// Splits rich text into line-aligned fragments that fit a page's height.
///
/// Placeholder widgets (images, SVG placeholders, and interactive link
/// widgets) are deliberately kept intact. Their intrinsic dimensions are
/// supplied by the widget tree rather than TextPainter, so fragmenting them
/// without a full render pass could clip or overlap content.
class FrameEpubTextPaginator {
  FrameEpubTextPaginator._();

  static List<TextRange> paginate({
    required InlineSpan text,
    required double maxWidth,
    required double maxHeight,
    required TextDirection textDirection,
    required TextAlign textAlign,
    required TextScaler textScaler,
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
    final placeholderDimensions = _rubyPlaceholderDimensions(text);
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

      final fragments = <TextRange>[];
      var fragmentStart = 0;
      var fragmentHeight = 0.0;
      for (final line in lines) {
        if (!line.height.isFinite || line.height > maxHeight) return [whole];
        if (fragmentHeight > 0 &&
            fragmentHeight + line.height > maxHeight + 0.5) {
          fragments.add(TextRange(
            start: fragmentStart,
            end: line.range.start,
          ));
          fragmentStart = line.range.start;
          fragmentHeight = 0;
        }
        fragmentHeight += line.height;
      }
      if (fragmentStart < plainText.length) {
        fragments.add(TextRange(
          start: fragmentStart,
          end: plainText.length,
        ));
      }
      if (fragments.length <= 1) return [whole];

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

  static List<PlaceholderDimensions>? _rubyPlaceholderDimensions(
    InlineSpan span,
  ) {
    final dimensions = <PlaceholderDimensions>[];
    var hasUnsupportedPlaceholder = false;
    span.visitChildren((child) {
      if (child is WidgetSpan) {
        final widget = child.child;
        if (widget is FrameEpubRubyAnnotation) {
          dimensions.add(widget.placeholderDimensions);
        } else {
          // Images and interactive widgets still need their real render-box
          // dimensions, so keep those paragraphs in one intact fragment.
          hasUnsupportedPlaceholder = true;
        }
      }
      return true;
    });
    return hasUnsupportedPlaceholder ? null : dimensions;
  }
}
