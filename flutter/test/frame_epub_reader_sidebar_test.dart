import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_reader_repository.dart';
import 'package:frame_ebook/reader/frame_epub_parser.dart';
import 'package:frame_ebook/reader/frame_epub_reader_sidebar.dart';
import 'package:material_ui/material_ui.dart';

FrameEpubTocEntry _tocEntry(String label, String path) => FrameEpubTocEntry(
      label: label,
      reference: FrameEpubResourceReference(
        originalHref: path,
        path: path,
        fragment: '',
        query: '',
        isExternal: false,
      ),
      children: const [],
    );

void main() {
  testWidgets('shows TOC, bookmarks and notes in separate tabs',
      (tester) async {
    final bookmark = FrameReaderAnnotation(
      id: 'bookmark-1',
      bookId: 'book-1',
      type: 'bookmark',
      cfi: 'epubcfi(/6/2!/4/1:0)',
      quote: '第一章的書籤位置',
    );
    final note = FrameReaderAnnotation(
      id: 'note-1',
      bookId: 'book-1',
      type: 'note',
      cfi: 'epubcfi(/6/2!/4/1:5)',
      quote: '被選取的原文',
      text: '這是我的閱讀筆記',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 680,
            width: 420,
            child: FrameEpubReaderSidebar(
              toc: [_tocEntry('第一章', 'chapter-one.xhtml')],
              currentPath: 'chapter-one.xhtml',
              annotations: [bookmark, note],
              initialTabIndex: 0,
              onSelectToc: (_) {},
              onOpenAnnotation: (_) {},
              onEditNote: (_) {},
              onDeleteAnnotation: (_) async => true,
              onClose: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('第一章'), findsOneWidget);
    await tester.tap(find.text('書籤 1'));
    await tester.pumpAndSettle();
    expect(find.text('第一章的書籤位置'), findsOneWidget);

    await tester.tap(find.text('筆記 1'));
    await tester.pumpAndSettle();
    expect(find.text('這是我的閱讀筆記'), findsOneWidget);
    expect(find.text('被選取的原文'), findsNothing);
  });

  testWidgets('selecting a TOC entry invokes navigation callback',
      (tester) async {
    final entry = _tocEntry('第二章', 'chapter-two.xhtml');
    FrameEpubTocEntry? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            width: 400,
            child: FrameEpubReaderSidebar(
              toc: [entry],
              currentPath: null,
              annotations: const [],
              initialTabIndex: 0,
              onSelectToc: (value) => selected = value,
              onOpenAnnotation: (_) {},
              onEditNote: (_) {},
              onDeleteAnnotation: (_) async => true,
              onClose: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('第二章'));
    expect(selected, same(entry));
  });
}
