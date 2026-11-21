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
    expect(find.text('第二章'), findsOneWidget);
    expect(find.text('第一節'), findsNothing);
    expect(find.text('第一小節'), findsNothing);

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

    await tester.binding.setSurfaceSize(const Size(1100, 850));
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
    expect(find.text('個人筆記'), findsOneWidget);
    expect(find.text('我的書籤'), findsOneWidget);
    expect(find.text('桌面筆記內容'), findsNothing);
    expect(find.text('書籤摘錄'), findsOneWidget);

    await tester.tap(find.text('筆記與標註'));
    await tester.pumpAndSettle();
    expect(find.text('桌面筆記內容'), findsOneWidget);

    await tester.tap(find.text('第一章：開始'));
    await tester.pumpAndSettle();
    expect(selectedPath, 'OPS/Text/chapter01.xhtml');

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
            initialTabIndex: 2,
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

    await tester.tap(find.byTooltip('刪除筆記'));
    await tester.pumpAndSettle();
    expect(find.text('確定刪除這筆標註嗎？'), findsOneWidget);

    await tester.tap(find.text('刪除').last);
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
    expect(find.text('目前沒有筆記或劃線。'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}
