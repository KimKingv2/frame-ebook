import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_page_layout.dart';

void main() {
  test('groups flow items without exceeding the page height', () {
    final pages = FrameEpubPageLayout.paginate(
      itemHeights: [45, 50, 30, 20],
      availableHeight: 100,
    );

    expect(pages.length, 2);
    expect(pages[0].itemIndices, [0, 1]);
    expect(pages[1].itemIndices, [2, 3]);
    expect(pages.every((page) => !page.requiresVerticalScroll), isTrue);
  });

  test('keeps an oversized block intact on a vertically scrollable page', () {
    final pages = FrameEpubPageLayout.paginate(
      itemHeights: [35, 240, 25, 25],
      availableHeight: 100,
    );

    expect(pages.length, 3);
    expect(pages[0].itemIndices, [0]);
    expect(pages[1].itemIndices, [1]);
    expect(pages[1].requiresVerticalScroll, isTrue);
    expect(pages[2].itemIndices, [2, 3]);
    expect(pages[2].requiresVerticalScroll, isFalse);
  });


  test('honors forced page breaks before and after flow items', () {
    final before = FrameEpubPageLayout.paginate(
      itemHeights: [20, 20, 20, 20],
      availableHeight: 100,
      breakBeforeIndices: {2},
    );
    expect(before.map((page) => page.itemIndices).toList(), [
      [0, 1],
      [2, 3],
    ]);

    final after = FrameEpubPageLayout.paginate(
      itemHeights: [20, 20, 20, 20],
      availableHeight: 100,
      breakAfterIndices: {1},
    );
    expect(after.map((page) => page.itemIndices).toList(), [
      [0, 1],
      [2, 3],
    ]);
  });

  test('keeps zero-height break markers with the following page content', () {
    final pages = FrameEpubPageLayout.paginate(
      itemHeights: [35, 0, 35],
      availableHeight: 100,
      breakBeforeIndices: {1},
    );

    expect(pages.map((page) => page.itemIndices).toList(), [
      [0],
      [1, 2],
    ]);
  });

  test('groups pages into two-page spreads and preserves the final page', () {
    expect(
      FrameEpubPageLayout.groupIntoSpreads(5),
      [
        [0, 1],
        [2, 3],
        [4],
      ],
    );
  });

  test('returns no spreads for an empty chapter', () {
    expect(FrameEpubPageLayout.groupIntoSpreads(0), isEmpty);
  });

  test('produces one empty page for an empty chapter', () {
    final pages = FrameEpubPageLayout.paginate(
      itemHeights: const [],
      availableHeight: 100,
    );

    expect(pages, hasLength(1));
    expect(pages.single.itemIndices, isEmpty);
  });

  test('rejects invalid page heights', () {
    expect(
      () => FrameEpubPageLayout.paginate(
        itemHeights: [1],
        availableHeight: 0,
      ),
      throwsArgumentError,
    );
  });
}
