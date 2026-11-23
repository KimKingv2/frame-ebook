import 'package:material_ui/material_ui.dart';

/// A page-turn action whose disabled state remains visibly legible at the
/// beginning or end of a book.
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
    return OutlinedButton(
      key: ValueKey(
        previous ? 'reader-page-turn-previous' : 'reader-page-turn-next',
      ),
      onPressed: enabled ? onPressed : null,
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? const Color(0xFFB8ADC9)
              : const Color(0xFFECE6F5);
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? const Color(0xFF292432)
              : const Color(0xFF342B43);
        }),
        side: WidgetStateProperty.resolveWith((states) {
          return BorderSide(
            color: states.contains(WidgetState.disabled)
                ? const Color(0xFF665B78)
                : const Color(0xFF8D79A8),
          );
        }),
        minimumSize: const WidgetStatePropertyAll(Size(104, 37)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (previous) ...[
            const Icon(Icons.chevron_left_rounded, size: 17),
            const SizedBox(width: 3),
          ],
          Text(previous ? '上一頁' : '下一頁'),
          if (!previous) ...[
            const SizedBox(width: 3),
            const Icon(Icons.chevron_right_rounded, size: 17),
          ],
        ],
      ),
    );
  }
}
