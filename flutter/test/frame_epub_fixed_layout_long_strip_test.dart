import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_fixed_layout_long_strip.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('builds long-strip pages lazily and reports the visible page',
      (tester) async {
    final visited = <int>{};
    final reported = <int>[];

    await tester.view.setPhysicalSize(const Size(400, 600));
    await tester.view.setDevicePixelRatio(1);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubFixedLayoutLongStrip(
            pageCount: 12,
            currentPageIndex: 0,
            cachePages: 1,
            onPageChanged: reported.add,
            pageBuilder: (context, index) {
              visited.add(index);
              return ColoredBox(
                color: Colors.white,
                child: Center(child: Text('漫畫頁 \${index + 1}')),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('漫畫頁 1'), findsOneWidget);
    expect(visited.length, lessThan(12));
    expect(reported, contains(0));

    await tester.drag(find.text('漫畫頁 1'), const Offset(0, -620));
    await tester.pumpAndSettle();

    expect(find.text('漫畫頁 2'), findsOneWidget);
    expect(reported, contains(1));
    expect(visited.length, lessThan(12));
  });

  testWidgets('restores the requested page without building the whole book',
      (tester) async {
    final visited = <int>{};

    await tester.view.setPhysicalSize(const Size(420, 700));
    await tester.view.setDevicePixelRatio(1);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubFixedLayoutLongStrip(
            pageCount: 30,
            currentPageIndex: 17,
            onPageChanged: (_) {},
            pageBuilder: (context, index) {
              visited.add(index);
              return Center(child: Text('第 \${index + 1} 頁'));
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('第 18 頁'), findsOneWidget);
    expect(visited.length, lessThan(8));
    expect(visited, contains(17));
  });
}
