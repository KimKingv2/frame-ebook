import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:frame_ebook/library/frame_reader_repository.dart';
import 'package:frame_ebook/reader/frame_epub_parser.dart';
import 'package:frame_ebook/reader/frame_epub_reader_sidebar.dart';

void main() {
  testWidgets('TOC nodes expand and collapse like the legacy tree',
      (tester) async {
    var selectedPath = '';
    final toc = <FrameEpubTocEntry>[
      FrameEpubTocEntry(
        label: '第一章',
        reference: null,
        children: [
          FrameEpubTocEntry(
            label: '第一節',
            reference: const FrameEpubResourceReference(
              originalHref: 'Text/section01.xhtml',
              path: 'OPS/Text/section01.xhtml',
              fragment: '',
              query: '',
              isExternal: false,
            ),
            children: [
              FrameEpubTocEntry(
                label: '第一小節',
                reference: const FrameEpubResourceReference(
                  originalHref: 'Text/section01.xhtml#part-a',
                  path: 'OPS/Text/section01.xhtml',
                  fragment: 'part-a',
                  query: '',
                  isExternal: false,
                ),
                children: const [],
              ),
            ],
          ),
        ],
      ),
      FrameEpubTocEntry(
        label: '第二章',
        reference: const FrameEpubResourceReference(
          originalHref: 'Text/chapter02.xhtml',
          path: 'OPS/Text/chapter02.xhtml',
          fragment: '',
          query: '',
          isExternal: false,
        ),
        children: const [],
      ),
    ];

    await tester.binding.setSurfaceSize(const Size(1100, 850));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 250,
            child: FrameEpubReaderSidebar(
              toc: toc,
              currentPath: null,
              annotations: const [],
              initialTabIndex: 0,
              desktopLayout: true,
              onSelectToc: (entry) => selectedPath = entry.path ?? '',
              onOpenAnnotation: (_) {},
              onEditNote: (_) {},
              onRefreshAnnotations: () async {},
              onDeleteAnnotation: (_) async => true,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一章'), findsOneWidget);
    final chapterLabel = tester.widget<Text>(find.text('第一章'));
    expect(chapterLabel.style?.color, const Color(0xFFE1D7EF));
    expect(chapterLabel.style?.fontFamily, 'NotoSansTC');
    expect(find.text('第二章'), findsOneWidget);
    expect(find.text('第一節'), findsNothing);
    expect(find.text('第一小節'), findsNothing);

    await tester.tap(find.text('第一章'));
    await tester.pumpAndSettle();
    expect(find.text('第一節'), findsOneWidget);
    await tester.tap(find.text('第一章'));
    await tester.pumpAndSettle();
    expect(find.text('第一節'), findsNothing);

    await tester.tap(find.byTooltip('展開「第一章」子目錄'));
    await tester.pumpAndSettle();
    expect(find.text('第一節'), findsOneWidget);
    expect(find.text('第一小節'), findsNothing);

    await tester.tap(find.byTooltip('展開「第一節」子目錄'));
    await tester.pumpAndSettle();
    expect(find.text('第一小節'), findsOneWidget);

    await tester.tap(find.text('第一小節'));
    await tester.pumpAndSettle();
    expect(selectedPath, 'OPS/Text/section01.xhtml');

    await tester.tap(find.byTooltip('收合「第一章」子目錄'));
    await tester.pumpAndSettle();
    expect(find.text('第一節'), findsNothing);
    expect(find.text('第一小節'), findsNothing);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('non-spine TOC entries expand instead of navigating',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 800));
    var selectedPath = '';
    final toc = <FrameEpubTocEntry>[
      FrameEpubTocEntry(
        label: '附錄索引',
        reference: const FrameEpubResourceReference(
          originalHref: 'Text/supplement.xhtml',
          path: 'OPS/Text/supplement.xhtml',
          fragment: '',
          query: '',
          isExternal: false,
        ),
        children: [
          FrameEpubTocEntry(
            label: '附錄章節',
            reference: const FrameEpubResourceReference(
              originalHref: 'Text/chapter-one.xhtml#start',
              path: 'OPS/Text/chapter-one.xhtml',
              fragment: 'start',
              query: '',
              isExternal: false,
            ),
            children: const [],
          ),
        ],
      ),
      FrameEpubTocEntry(
        label: '版權頁',
        reference: null,
        children: const [],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 250,
            child: FrameEpubReaderSidebar(
              toc: toc,
              currentPath: null,
              annotations: const [],
              initialTabIndex: 0,
              desktopLayout: true,
              canNavigateTocEntry: (entry) =>
                  entry.path == 'OPS/Text/chapter-one.xhtml',
              onSelectToc: (entry) => selectedPath = entry.path ?? '',
              onOpenAnnotation: (_) {},
              onEditNote: (_) {},
              onRefreshAnnotations: () async {},
              onDeleteAnnotation: (_) async => true,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('附錄索引'));
    await tester.pumpAndSettle();
    expect(find.text('附錄章節'), findsOneWidget);
    expect(selectedPath, isEmpty);

    await tester.tap(find.text('附錄章節'));
    await tester.pumpAndSettle();
    expect(selectedPath, 'OPS/Text/chapter-one.xhtml');

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('TOC automatically expands ancestors of the current chapter',
      (tester) async {
    final toc = <FrameEpubTocEntry>[
      FrameEpubTocEntry(
        label: '第一章',
        reference: null,
        children: [
          FrameEpubTocEntry(
            label: '第一節',
            reference: null,
            children: [
              FrameEpubTocEntry(
                label: '目前所在的小節',
                reference: const FrameEpubResourceReference(
                  originalHref: 'Text/section01.xhtml#current',
                  path: 'OPS/Text/section01.xhtml',
                  fragment: 'current',
                  query: '',
                  isExternal: false,
                ),
                children: const [],
              ),
            ],
          ),
        ],
      ),
      FrameEpubTocEntry(
        label: '第二章',
        reference: null,
        children: const [],
      ),
    ];

    await tester.binding.setSurfaceSize(const Size(1100, 850));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 250,
            child: FrameEpubReaderSidebar(
              toc: toc,
              currentPath: 'OPS/Text/section01.xhtml',
              annotations: const [],
              initialTabIndex: 0,
              desktopLayout: true,
              onSelectToc: (_) {},
              onOpenAnnotation: (_) {},
              onEditNote: (_) {},
              onRefreshAnnotations: () async {},
              onDeleteAnnotation: (_) async => true,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一節'), findsOneWidget);
    expect(find.text('目前所在的小節'), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });


  testWidgets('desktop sidebar keeps TOC, notes and bookmarks in one column',
      (tester) async {
    var selectedPath = '';
    final tocEntry = FrameEpubTocEntry(
      label: '第一章：開始',
      reference: const FrameEpubResourceReference(
        originalHref: 'Text/chapter01.xhtml',
        path: 'OPS/Text/chapter01.xhtml',
        fragment: '',
        query: '',
        isExternal: false,
      ),
      children: const [],
    );
    const note = FrameReaderAnnotation(
      id: 'note-desktop',
      bookId: 'book-one',
      type: 'note',
      cfi: 'epubcfi(/6/2!/4/2:3)',
      quote: '引用文字',
      text: '桌面筆記內容',
      color: 'violet',
      createdAt: 20,
    );
    const bookmark = FrameReaderAnnotation(
      id: 'bookmark-desktop',
      bookId: 'book-one',
      type: 'bookmark',
      cfi: 'epubcfi(/6/2!/4/2:3)',
      quote: '書籤摘錄',
      createdAt: 10,
    );

    await tester.binding.setSurfaceSize(const Size(1440, 850));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 250,
            child: FrameEpubReaderSidebar(
              toc: [tocEntry],
              currentPath: 'OPS/Text/chapter01.xhtml',
              annotations: const [note, bookmark],
              initialTabIndex: 0,
              desktopLayout: true,
              onSelectToc: (entry) => selectedPath = entry.path ?? '',
              onOpenAnnotation: (_) {},
              onEditNote: (_) {},
              onRefreshAnnotations: () async {},
              onDeleteAnnotation: (_) async => true,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('IN THIS BOOK'), findsOneWidget);
    expect(find.text('閱讀導覽'), findsOneWidget);
    expect(find.text('F'), findsOneWidget);
    expect(find.text('章節目錄'), findsOneWidget);
    expect(find.text('第一章：開始'), findsOneWidget);
    final selectedChapter = tester.widget<Text>(find.text('第一章：開始'));
    expect(selectedChapter.style?.color, const Color(0xFFF6F0FF));
    expect(selectedChapter.style?.fontFamily, 'NotoSansTC');
    expect(find.text('個人筆記'), findsOneWidget);
    expect(find.text('我的書籤'), findsOneWidget);
    expect(find.text('桌面筆記內容'), findsNothing);
    expect(find.text('書籤摘錄'), findsOneWidget);

    final sidebarSurface = tester.widget<Material>(
      find.descendant(
        of: find.byType(FrameEpubReaderSidebar),
        matching: find.byType(Material),
      ).first,
    );
    expect(sidebarSurface.color, Colors.transparent);

    final tocHeadingRect = tester.getRect(find.text('章節目錄'));
    expect(tocHeadingRect.left, greaterThanOrEqualTo(11));

    final cloudFootnote = tester.widget<Text>(
      find.text('閱讀位置、筆記與書籤都會同步保存至雲端'),
    );
    expect(cloudFootnote.style?.color, const Color(0xFF776D85));
    expect(cloudFootnote.style?.fontSize, 8);
    expect(cloudFootnote.style?.height, 1.7);

    await tester.tap(find.text('筆記與標註'));
    await tester.pumpAndSettle();
    expect(find.text('桌面筆記內容'), findsOneWidget);

    await tester.tap(find.text('第一章：開始'));
    await tester.pumpAndSettle();
    expect(selectedPath, 'OPS/Text/chapter01.xhtml');

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('desktop annotation cards match legacy density and typography',
      (tester) async {
    const note = FrameReaderAnnotation(
      id: 'desktop-style-note',
      bookId: 'book-one',
      type: 'note',
      cfi: 'epubcfi(/6/2!/4/2:3)',
      quote: '舊版閱讀室引用文字',
      text: '舊版閱讀室筆記預覽',
      color: 'violet',
      createdAt: 30,
    );

    await tester.binding.setSurfaceSize(const Size(1440, 850));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 250,
            child: FrameEpubReaderSidebar(
              toc: const [],
              currentPath: null,
              annotations: const [note],
              initialTabIndex: 0,
              desktopLayout: true,
              onSelectToc: (_) {},
              onOpenAnnotation: (_) {},
              onEditNote: (_) {},
              onRefreshAnnotations: () async {},
              onDeleteAnnotation: (_) async => true,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('筆記與標註'));
    await tester.pumpAndSettle();

    final card = tester.widget<Container>(
      find.byKey(const ValueKey('reader-annotation-card-desktop-style-note')),
    );
    expect(
      card.padding,
      const EdgeInsets.symmetric(horizontal: 7, vertical: 9),
    );
    expect(card.margin, const EdgeInsets.only(bottom: 7));
    final decoration = card.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(8));
    expect(
      (decoration.border! as Border).top.color,
      const Color(0x17BEA6E5),
    );

    final markerRail = tester.getSize(
      find.byKey(
        const ValueKey('reader-annotation-marker-rail-desktop-style-note'),
      ),
    );
    expect(markerRail.width, 5);

    final kind = tester.widget<Text>(find.text('筆記').last);
    expect(kind.style?.fontSize, 8);
    expect(kind.style?.letterSpacing, .5);

    final quote = tester.widget<Text>(
      find.byKey(
        const ValueKey('reader-annotation-quote-desktop-style-note'),
      ),
    );
    expect(quote.style?.fontSize, 9);
    expect(quote.style?.height, 1.65);
    expect(quote.maxLines, 2);

    final preview = tester.widget<Text>(
      find.byKey(
        const ValueKey('reader-annotation-note-preview-desktop-style-note'),
      ),
    );
    expect(preview.style?.fontSize, 8);
    expect(preview.style?.height, 1.6);
    expect(preview.maxLines, 2);

    final deleteButton = tester.widget<TextButton>(
      find.byKey(
        const ValueKey('reader-annotation-delete-desktop-style-note'),
      ),
    );
    expect(deleteButton.style?.minimumSize?.resolve({})?.height, 25);
    expect(
      deleteButton.style?.padding?.resolve({}),
      const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
    );

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('annotation cards keep selected quote and note preview separate',
      (tester) async {
    const note = FrameReaderAnnotation(
      id: 'note-quote-preview',
      bookId: 'book-one',
      type: 'note',
      cfi: 'epubcfi(/6/2!/4/2:3)',
      quote: '這是原文摘錄',
      text: '這是另外保存的筆記內容',
      color: 'violet',
      createdAt: 30,
    );
    const bookmark = FrameReaderAnnotation(
      id: 'bookmark-preview',
      bookId: 'book-one',
      type: 'bookmark',
      cfi: 'epubcfi(/6/2!/4/2:5)',
      quote: '這是書籤所在位置',
      createdAt: 20,
    );

    await tester.binding.setSurfaceSize(const Size(420, 760));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubReaderSidebar(
            toc: const [],
            currentPath: null,
            annotations: const [note, bookmark],
            initialTabIndex: 1,
            onSelectToc: (_) {},
            onOpenAnnotation: (_) {},
            onEditNote: (_) {},
            onRefreshAnnotations: () async {},
            onDeleteAnnotation: (_) async => true,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('目錄'), findsOneWidget);
    expect(find.text('筆記').first, findsOneWidget);
    expect(find.text('書籤 1'), findsOneWidget);
    final inactiveTocTab = tester.widget<Text>(find.text('目錄'));
    expect(inactiveTocTab.style?.color, const Color(0xFF9E93AD));
    expect(inactiveTocTab.style?.fontFamily, 'NotoSansTC');
    final activeNotesTab = tester.widget<Text>(find.text('筆記').first);
    expect(activeNotesTab.style?.color, const Color(0xFFF2EBFF));
    expect(activeNotesTab.style?.fontFamily, 'NotoSansTC');

    expect(find.text('個人筆記'), findsOneWidget);
    expect(find.text('MY NOTES'), findsOneWidget);
    expect(find.text('筆記與標註'), findsOneWidget);
    expect(find.text('這是原文摘錄'), findsOneWidget);
    expect(find.text('這是另外保存的筆記內容'), findsOneWidget);

    await tester.tap(find.text('書籤 1'));
    await tester.pumpAndSettle();
    expect(find.text('我的書籤 1'), findsOneWidget);
    expect(find.text('BOOKMARKS'), findsOneWidget);
    expect(find.text('這是書籤所在位置'), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

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
            initialTabIndex: 2,
            onSelectToc: (_) {},
            onOpenAnnotation: (_) {},
            onEditNote: (_) {},
            onRefreshAnnotations: () async {},
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

  testWidgets('refresh button calls the annotation refresh handler',
      (tester) async {
    var refreshCalls = 0;

    await tester.binding.setSurfaceSize(const Size(420, 760));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrameEpubReaderSidebar(
            toc: const [],
            currentPath: null,
            annotations: const [],
            initialTabIndex: 1,
            onSelectToc: (_) {},
            onOpenAnnotation: (_) {},
            onEditNote: (_) {},
            onDeleteAnnotation: (_) async => true,
            onRefreshAnnotations: () async {
              refreshCalls++;
            },
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('重新整理標註'));
    await tester.pumpAndSettle();

    expect(refreshCalls, 1);
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
            initialTabIndex: 1,
            onSelectToc: (_) {},
            onOpenAnnotation: (_) {},
            onEditNote: (_) {},
            onRefreshAnnotations: () async {},
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

    await tester.tap(find.text('刪除').last);
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
    expect(
      find.text('這本書還沒有筆記或高亮。選取正文中的文字即可新增。'),
      findsOneWidget,
    );
    await tester.binding.setSurfaceSize(null);
  });
}
