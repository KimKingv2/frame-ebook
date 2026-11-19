import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/reader/frame_epub_page_turn_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PageDown and PageUp move by a viewport', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            child: ListView.builder(
              controller: controller,
              itemExtent: 80,
              itemCount: 80,
              itemBuilder: (context, index) => Text('Paragraph $index'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));

    final forwardOffset = controller.offset;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pumpAndSettle();
    expect(controller.offset, lessThan(forwardOffset));
    expect(controller.offset, closeTo(0, 1));
  });

  testWidgets('fixed-layout key turns call the adjacent chapter callback',
      (tester) async {
    final controller = ScrollController();
    var nextChapterCalls = 0;
    var previousChapterCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            onNextChapter: () async => nextChapterCalls++,
            onPreviousChapter: () async => previousChapterCalls++,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(nextChapterCalls, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(previousChapterCalls, 1);
  });
}
