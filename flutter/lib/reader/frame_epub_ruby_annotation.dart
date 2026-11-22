import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';

/// A ruby annotation that paints above or below its source run.
///
/// The enclosing WidgetSpan reserves vertical space but no horizontal width,
/// allowing the base characters to remain ordinary selectable TextSpans.
class FrameEpubRubyAnnotation extends StatelessWidget {
  const FrameEpubRubyAnnotation({
    required this.annotation,
    required this.textScaler,
    required this.annotationWidth,
    required this.annotationHeight,
    required this.placeholderHeight,
    required this.horizontalOffset,
    required this.verticalOffset,
    super.key,
  });

  final InlineSpan annotation;
  final TextScaler textScaler;
  final double annotationWidth;
  final double annotationHeight;
  final double placeholderHeight;
  final double horizontalOffset;
  final double verticalOffset;

  PlaceholderDimensions get placeholderDimensions => PlaceholderDimensions(
        size: Size(0, placeholderHeight),
        alignment: verticalOffset == 0
            ? PlaceholderAlignment.aboveBaseline
            : PlaceholderAlignment.belowBaseline,
        baseline: TextBaseline.alphabetic,
      );

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 0,
        height: placeholderHeight,
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minWidth: annotationWidth,
          maxWidth: annotationWidth,
          minHeight: annotationHeight,
          maxHeight: annotationHeight,
          child: Transform.translate(
            offset: Offset(horizontalOffset, verticalOffset),
            child: Text.rich(
              annotation,
              textScaler: textScaler,
              softWrap: false,
              maxLines: 1,
              overflow: TextOverflow.visible,
            ),
          ),
        ),
      );
}
