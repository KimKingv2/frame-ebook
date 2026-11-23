import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:frame_ebook/reader/frame_epub_reader_progress_panel.dart';

void main() {
  testWidgets('desktop progress panel matches legacy track geometry',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FrameEpubReaderProgressPanel(
              chapterProgressPercent: 42,
              bookProgressPercent: 17,
              canGoPrevious: true,
              canGoNext: false,
              onPrevious: () {},
              onNext: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本章進度'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('全書進度'), findsOneWidget);
    expect(find.text('17%'), findsOneWidget);

    final chapterTrack = tester.widget<SizedBox>(
      find.byKey(const ValueKey('reader-progress-chapter-track')),
    );
    final bookTrack = tester.widget<SizedBox>(
      find.byKey(const ValueKey('reader-progress-book-track')),
    );
    expect(chapterTrack.height, 4);
    expect(bookTrack.height, 3);

    final panel = tester.getSize(
      find.byKey(const ValueKey('reader-progress-panel')),
    );
    expect(panel.width, greaterThanOrEqualTo(200));

    final previousButton = tester.getSize(
      find.byKey(const ValueKey('reader-page-turn-previous')),
    );
    expect(previousButton.width, 116);
    expect(previousButton.height, 37);

    final percent = tester.widget<Text>(
      find.byKey(const ValueKey('reader-progress-chapter-row-percent')),
    );
    expect(percent.style?.fontSize, 9);
    expect(percent.style?.fontWeight, FontWeight.w600);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixed layout omits chapter progress and keeps whole-book meter',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubReaderProgressPanel(
            chapterProgressPercent: null,
            bookProgressPercent: 30,
            canGoPrevious: false,
            canGoNext: true,
            onPrevious: () {},
            onNext: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本章進度'), findsNothing);
    expect(find.byKey(const ValueKey('reader-progress-chapter-row')),
        findsNothing);
    expect(find.text('全書進度'), findsOneWidget);
    expect(find.text('30%'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('reader-progress-panel'))).width,
      370,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('percentages are clamped and exposed to accessibility semantics',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubReaderProgressPanel(
            chapterProgressPercent: 113,
            bookProgressPercent: -2,
            canGoPrevious: true,
            canGoNext: true,
            onPrevious: () {},
            onNext: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('100%'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('本章進度')).evaluate(),
      isNotEmpty,
    );
  });
}
