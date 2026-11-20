import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:frame_ebook/library/frame_reader_repository.dart';
import 'package:frame_ebook/reader/frame_epub_reader_sidebar.dart';

void main() {
  testWidgets('cancel keeps a bookmark and does not call the delete handler',
      (tester) async {
    var deleteCalls = 0;
    const bookmark = FrameReaderAnnotation(
      id: 'bookmark-one',
      bookId: 'book-one',
      type: 'bookmark',
      cfi: 'epubcfi(/6/2!/4/2:3)',
      createdAt: 10,
    );

    await tester.binding.setSurfaceSize(const Size(420, 760));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubReaderSidebar(
            toc: const [],
            currentPath: null,
            annotations: const [bookmark],
            initialTabIndex: 1,
            onSelectToc: (_) {},
            onOpenAnnotation: (_) {},
            onEditNote: (_) {},
            onDeleteAnnotation: (_) async {
              deleteCalls++;
              return true;
            },
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('刪除書籤'));
    await tester.pumpAndSettle();
    expect(find.text('確定刪除這個書籤嗎？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 0);
    expect(find.text('目前沒有已保存的書籤。'), findsNothing);
    expect(find.byTooltip('刪除書籤'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('confirms a note deletion before calling the delete handler',
      (tester) async {
    var deleteCalls = 0;
    const note = FrameReaderAnnotation(
      id: 'note-one',
      bookId: 'book-one',
      type: 'note',
      cfi: 'epubcfi(/6/2!/4/2:3)',
      quote: '原文摘錄',
      text: '我的閱讀筆記',
      createdAt: 10,
    );

    await tester.binding.setSurfaceSize(const Size(420, 760));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubReaderSidebar(
            toc: const [],
            currentPath: null,
            annotations: const [note],
            initialTabIndex: 2,
            onSelectToc: (_) {},
            onOpenAnnotation: (_) {},
            onEditNote: (_) {},
            onDeleteAnnotation: (_) async {
              deleteCalls++;
              return true;
            },
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('刪除筆記'));
    await tester.pumpAndSettle();
    expect(find.text('確定刪除這筆標註嗎？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
    expect(find.text('目前沒有筆記或劃線。'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}
