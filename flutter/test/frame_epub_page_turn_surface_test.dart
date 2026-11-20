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
  testWidgets('paginated mode advances and reverses one real page', (tester) async {
    final scrollController = ScrollController();
    final pageController = PageController();
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: scrollController,
            pageController: pageController,
            paginated: true,
            child: PageView(
              controller: pageController,
              children: const [
                ColoredBox(color: Colors.red),
                ColoredBox(color: Colors.green),
                ColoredBox(color: Colors.blue),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(pageController.page, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(pageController.page, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pumpAndSettle();
    expect(pageController.page, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    pageController.dispose();
    scrollController.dispose();
  });

  testWidgets('paginated mode changes chapter only at the last page', (tester) async {
    final scrollController = ScrollController();
    final pageController = PageController();
    var nextChapterCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: scrollController,
            pageController: pageController,
            paginated: true,
            onNextChapter: () async {
              nextChapterCalls++;
            },
            child: PageView(
              controller: pageController,
              children: const [
                ColoredBox(color: Colors.red),
                ColoredBox(color: Colors.green),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(pageController.page, 1);
    expect(nextChapterCalls, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(nextChapterCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    pageController.dispose();
    scrollController.dispose();
  });


  testWidgets('paginated horizontal swipe is handled by PageView once', (tester) async {
    final scrollController = ScrollController();
    final pageController = PageController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: scrollController,
            pageController: pageController,
            paginated: true,
            child: PageView(
              controller: pageController,
              children: const [
                ColoredBox(color: Colors.red),
                ColoredBox(color: Colors.green),
                ColoredBox(color: Colors.blue),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(pageController.page, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    pageController.dispose();
    scrollController.dispose();
  });


  testWidgets('upper viewport taps toggle immersive mode without turning pages',
      (tester) async {
    final controller = ScrollController();
    var immersiveToggles = 0;
    var nextChapterCalls = 0;
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            onToggleImmersive: () => immersiveToggles++,
            onNextChapter: () async => nextChapterCalls++,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final touch = await tester.startGesture(
      const Offset(400, 45),
      kind: PointerDeviceKind.touch,
    );
    await touch.up();
    await tester.pump();

    final mouse = await tester.startGesture(
      const Offset(400, 45),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.up();
    await tester.pump();

    expect(immersiveToggles, 2);
    expect(nextChapterCalls, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    controller.dispose();
  });

  testWidgets('Escape exits immersive mode without turning an EPUB page',
      (tester) async {
    final controller = ScrollController();
    var exitCalls = 0;
    var nextChapterCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubPageTurnSurface(
            controller: controller,
            immersive: true,
            onExitImmersive: () => exitCalls++,
            onNextChapter: () async => nextChapterCalls++,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(exitCalls, 1);
    expect(nextChapterCalls, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

}
