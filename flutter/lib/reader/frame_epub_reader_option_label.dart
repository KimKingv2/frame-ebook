import 'package:flutter/widgets.dart';

/// Visible text used inside appearance option cards and dropdown entries.
///
/// The font and foreground are deliberately explicit because these labels are
/// nested inside Material button/menu widgets whose inherited style can differ
/// between desktop and Flutter Web renderers.
class FrameEpubReaderOptionLabel extends StatelessWidget {
  const FrameEpubReaderOptionLabel({
    required this.label,
    required this.color,
    required this.fontSize,
    super.key,
  });

  final String label;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontFamily: 'NotoSansTC',
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
        ),
      );
}
