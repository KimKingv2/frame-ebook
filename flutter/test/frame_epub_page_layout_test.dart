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
