import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_reader_page_navigation_button.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('keeps previous and next controls visible when disabled',
      (tester) async {
    var nextPressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF12101A),
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FrameEpubReaderPageNavigationButton(
                  previous: true,
                  enabled: false,
                  onPressed: () {},
                ),
                const SizedBox(width: 12),
                FrameEpubReaderPageNavigationButton(
                  previous: false,
                  enabled: true,
                  onPressed: () => nextPressed = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('上一頁'), findsOneWidget);
    expect(find.text('下一頁'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    final previous = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('reader-page-turn-previous')),
    );
    final previousStyle = previous.style!;
    expect(previous.onPressed, isNull);
    expect(
      previousStyle.foregroundColor!.resolve({WidgetState.disabled}),
      const Color(0xFFB8ADC9),
    );
    expect(
      previousStyle.backgroundColor!.resolve({WidgetState.disabled}),
      const Color(0xFF292432),
    );
    expect(
      previousStyle.side!.resolve({WidgetState.disabled})!.color,
      const Color(0xFF665B78),
    );

    final previousRect = tester.getRect(
      find.byKey(const ValueKey('reader-page-turn-previous')),
    );
    final nextRect = tester.getRect(
      find.byKey(const ValueKey('reader-page-turn-next')),
    );
    expect(previousRect.width, greaterThanOrEqualTo(104));
    expect(previousRect.height, greaterThanOrEqualTo(37));
    expect(nextRect.width, greaterThanOrEqualTo(104));
    expect(nextRect.height, greaterThanOrEqualTo(37));

    await tester.tap(find.byKey(const ValueKey('reader-page-turn-next')));
    await tester.pump();
    expect(nextPressed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
