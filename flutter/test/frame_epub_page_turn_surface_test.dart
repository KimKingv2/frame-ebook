import 'package:flutter/gestures.dart';
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

  testWidgets('reflowable layout does not change chapters before scroll attaches',
      (tester) async {
    final controller = ScrollController();
    var nextChapterCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            onNextChapter: () async {
              nextChapterCalls++;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(nextChapterCalls, 0);
  });

  testWidgets('fixed-layout left swipe advances to next page', (tester) async {
    final controller = ScrollController();
    var nextChapterCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            fixedLayout: true,
            onNextChapter: () async {
              nextChapterCalls++;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      const Offset(600, 320),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(
      const Offset(-120, 0),
      timeStamp: const Duration(milliseconds: 100),
    );
    await gesture.up();
    await tester.pump();

    expect(nextChapterCalls, 1);
  });

  testWidgets('fixed-layout edge tap navigates according to reading direction',
      (tester) async {
    final controller = ScrollController();
    var nextChapterCalls = 0;
    var previousChapterCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            fixedLayout: true,
            isRightToLeft: true,
            onNextChapter: () async {
              nextChapterCalls++;
            },
            onPreviousChapter: () async {
              previousChapterCalls++;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    var gesture = await tester.startGesture(
      const Offset(30, 320),
      kind: PointerDeviceKind.touch,
    );
    await gesture.up();
    await tester.pump();
    expect(nextChapterCalls, 1);

    gesture = await tester.startGesture(
      const Offset(760, 320),
      kind: PointerDeviceKind.touch,
    );
    await gesture.up();
    await tester.pump();
    expect(previousChapterCalls, 1);
  });

  testWidgets('zoomed pages and selected text ignore touch page turns',
      (tester) async {
    final controller = ScrollController();
    var nextChapterCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            fixedLayout: true,
            pageZoomed: true,
            onNextChapter: () async {
              nextChapterCalls++;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    var gesture = await tester.startGesture(
      const Offset(760, 320),
      kind: PointerDeviceKind.touch,
    );
    await gesture.up();
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            fixedLayout: true,
            selectionActive: true,
            onNextChapter: () async {
              nextChapterCalls++;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    gesture = await tester.startGesture(
      const Offset(760, 320),
      kind: PointerDeviceKind.touch,
    );
    await gesture.up();
    await tester.pump();

    expect(nextChapterCalls, 0);
  });

  testWidgets('vertical touch movement does not trigger page navigation',
      (tester) async {
    final controller = ScrollController();
    var nextChapterCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            fixedLayout: true,
            onNextChapter: () async {
              nextChapterCalls++;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      const Offset(400, 360),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(
      const Offset(2, -140),
      timeStamp: const Duration(milliseconds: 100),
    );
    await gesture.up();
    await tester.pump();

    expect(nextChapterCalls, 0);
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
            fixedLayout: true,
            onNextChapter: () async {
              nextChapterCalls++;
            },
            onPreviousChapter: () async {
              previousChapterCalls++;
            },
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
