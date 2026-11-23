import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_reader_page_navigation_button.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('paints explicit text and arrows for enabled and disabled controls',
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

    const previousText = '‹  上一頁';
    const nextText = '下一頁  ›';
    expect(find.text(previousText), findsOneWidget);
    expect(find.text(nextText), findsOneWidget);

    final previousLabel = tester.widget<Text>(find.text(previousText));
    final nextLabel = tester.widget<Text>(find.text(nextText));
    expect(previousLabel.style?.color, const Color(0xFFB8ADC9));
    expect(nextLabel.style?.color, const Color(0xFFECE6F5));
    expect(previousLabel.style?.fontSize, 12);
    expect(nextLabel.style?.fontSize, 12);

    final previousLabelSize = tester.getSize(find.text(previousText));
    final nextLabelSize = tester.getSize(find.text(nextText));
    expect(previousLabelSize.width, greaterThan(0));
    expect(previousLabelSize.height, greaterThan(0));
    expect(nextLabelSize.width, greaterThan(0));
    expect(nextLabelSize.height, greaterThan(0));

    final previousRect = tester.getRect(
      find.byKey(const ValueKey('reader-page-turn-previous')),
    );
    final nextRect = tester.getRect(
      find.byKey(const ValueKey('reader-page-turn-next')),
    );
    expect(previousRect.width, 116);
    expect(previousRect.height, 37);
    expect(nextRect.width, 116);
    expect(nextRect.height, 37);

    final previousGesture = tester.widget<GestureDetector>(
      find.byKey(const ValueKey('reader-page-turn-previous')),
    );
    final nextGesture = tester.widget<GestureDetector>(
      find.byKey(const ValueKey('reader-page-turn-next')),
    );
    expect(previousGesture.onTap, isNull);
    expect(nextGesture.onTap, isNotNull);

    await tester.tap(find.byKey(const ValueKey('reader-page-turn-next')));
    await tester.pump();
    expect(nextPressed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
