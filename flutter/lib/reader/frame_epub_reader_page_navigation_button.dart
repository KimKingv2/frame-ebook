import 'package:material_ui/material_ui.dart';

/// A page-turn control that draws its own label and arrow instead of relying
/// on the inherited Material button text style.
class FrameEpubReaderPageNavigationButton extends StatelessWidget {
  const FrameEpubReaderPageNavigationButton({
    required this.previous,
    required this.enabled,
    required this.onPressed,
    super.key,
  });

  final bool previous;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = previous ? '上一頁' : '下一頁';
    final text = previous ? '‹  上一頁' : '下一頁  ›';
    final foreground =
        enabled ? const Color(0xFFECE6F5) : const Color(0xFFB8ADC9);
    final background =
        enabled ? const Color(0xFF342B43) : const Color(0xFF292432);
    final border =
        enabled ? const Color(0xFF8D79A8) : const Color(0xFF8A7B9C);

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            key: ValueKey(
              previous ? 'reader-page-turn-previous' : 'reader-page-turn-next',
            ),
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? onPressed : null,
            child: Container(
              width: 116,
              height: 37,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: background,
                border: Border.all(color: border, width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                text,
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  color: foreground,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
