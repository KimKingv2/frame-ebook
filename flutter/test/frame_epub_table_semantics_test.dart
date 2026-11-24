import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_table_semantics.dart';

void main() {
  test('combines explicit column and row headers in authored order', () {
    final labels = FrameEpubTableSemantics.resolve(
      cells: const [
        FrameEpubTableSemanticCell(
          index: 0, row: 0, column: 0, rowSpan: 1, columnSpan: 1,
          rowGroup: 0, rowGroupEnd: 1, isHeader: true,
          isHeaderElement: true, isHeaderRow: true, text: '完整書名',
          id: 'book-title', scope: 'col', abbreviation: '書名',
        ),
        FrameEpubTableSemanticCell(
          index: 1, row: 1, column: 0, rowSpan: 1, columnSpan: 1,
          rowGroup: 1, rowGroupEnd: 2, isHeader: true,
          isHeaderElement: true, isHeaderRow: false, text: '第一本',
          id: 'first-book', scope: 'row',
        ),
        FrameEpubTableSemanticCell(
          index: 2, row: 1, column: 1, rowSpan: 1, columnSpan: 1,
          rowGroup: 1, rowGroupEnd: 2, isHeader: false,
          isHeaderElement: false, isHeaderRow: false, text: '作者甲',
          headers: 'book-title first-book',
        ),
      ],
    );

    expect(labels[2].label,
        '欄標題：書名；列標題：第一本；儲存格內容：作者甲');
    expect(labels[2].isHeader, isFalse);
    expect(labels[0].label, '完整書名');
    expect(labels[0].isHeader, isTrue);
  });

  test('infers column headers from thead and row headers from tbody', () {
    final labels = FrameEpubTableSemantics.resolve(
      cells: const [
        FrameEpubTableSemanticCell(
          index: 0, row: 0, column: 1, rowSpan: 1, columnSpan: 1,
          rowGroup: 0, rowGroupEnd: 1, isHeader: true,
          isHeaderElement: true, isHeaderRow: true, text: '書名',
        ),
        FrameEpubTableSemanticCell(
          index: 1, row: 1, column: 0, rowSpan: 1, columnSpan: 1,
          rowGroup: 1, rowGroupEnd: 2, isHeader: true,
          isHeaderElement: true, isHeaderRow: false, text: '第一本',
          scope: 'row',
        ),
        FrameEpubTableSemanticCell(
          index: 2, row: 1, column: 1, rowSpan: 1, columnSpan: 1,
          rowGroup: 1, rowGroupEnd: 2, isHeader: false,
          isHeaderElement: false, isHeaderRow: false, text: '作者甲',
        ),
      ],
    );

    expect(labels[2].label,
        '欄標題：書名；列標題：第一本；儲存格內容：作者甲');
  });

  test('rowgroup headers do not escape their tbody', () {
    final labels = FrameEpubTableSemantics.resolve(
      cells: const [
        FrameEpubTableSemanticCell(
          index: 0, row: 0, column: 1, rowSpan: 1, columnSpan: 1,
          rowGroup: 1, rowGroupEnd: 2, isHeader: true,
          isHeaderElement: true, isHeaderRow: false, text: '貓',
          scope: 'rowgroup',
        ),
        FrameEpubTableSemanticCell(
          index: 1, row: 1, column: 1, rowSpan: 1, columnSpan: 1,
          rowGroup: 1, rowGroupEnd: 2, isHeader: false,
          isHeaderElement: false, isHeaderRow: false, text: '四隻腳',
        ),
        FrameEpubTableSemanticCell(
          index: 2, row: 2, column: 1, rowSpan: 1, columnSpan: 1,
          rowGroup: 2, rowGroupEnd: 3, isHeader: false,
          isHeaderElement: false, isHeaderRow: false, text: '英文使用者',
        ),
      ],
    );

    expect(labels[1].label, '列群組標題：貓；儲存格內容：四隻腳');
    expect(labels[2].label, '英文使用者');
  });

  test('colgroup headers cover only columns in their colgroup', () {
    final labels = FrameEpubTableSemantics.resolve(
      columnGroups: const [
        FrameEpubTableColumnGroup(startColumn: 0, endColumn: 2),
        FrameEpubTableColumnGroup(startColumn: 2, endColumn: 3),
      ],
      cells: const [
        FrameEpubTableSemanticCell(
          index: 0, row: 0, column: 0, rowSpan: 1, columnSpan: 2,
          rowGroup: 0, rowGroupEnd: 1, isHeader: true,
          isHeaderElement: true, isHeaderRow: true, text: '基本資料',
          scope: 'colgroup',
        ),
        FrameEpubTableSemanticCell(
          index: 1, row: 1, column: 0, rowSpan: 1, columnSpan: 1,
          rowGroup: 1, rowGroupEnd: 2, isHeader: false,
          isHeaderElement: false, isHeaderRow: false, text: '第一欄',
        ),
        FrameEpubTableSemanticCell(
          index: 2, row: 1, column: 2, rowSpan: 1, columnSpan: 1,
          rowGroup: 1, rowGroupEnd: 2, isHeader: false,
          isHeaderElement: false, isHeaderRow: false, text: '第三欄',
        ),
      ],
    );

    expect(labels[1].label, '欄標題：基本資料；儲存格內容：第一欄');
    expect(labels[2].label, '第三欄');
  });

  test('preserves parent headings for explicitly linked multi-level headers', () {
    final labels = FrameEpubTableSemantics.resolve(
      cells: const [
        FrameEpubTableSemanticCell(
          index: 0, row: 0, column: 0, rowSpan: 1, columnSpan: 2,
          rowGroup: 0, rowGroupEnd: 1, isHeader: true,
          isHeaderElement: true, isHeaderRow: true, text: '基本資料',
          id: 'group', scope: 'colgroup',
        ),
        FrameEpubTableSemanticCell(
          index: 1, row: 1, column: 0, rowSpan: 1, columnSpan: 1,
          rowGroup: 0, rowGroupEnd: 2, isHeader: true,
          isHeaderElement: true, isHeaderRow: true, text: '書名',
          id: 'title', scope: 'col', headers: 'group',
        ),
        FrameEpubTableSemanticCell(
          index: 2, row: 2, column: 0, rowSpan: 1, columnSpan: 1,
          rowGroup: 1, rowGroupEnd: 3, isHeader: false,
          isHeaderElement: false, isHeaderRow: false, text: '星際旅行',
          headers: 'title',
        ),
      ],
    );

    expect(labels[1].label, '欄標題：基本資料／書名');
    expect(
      labels[2].label,
      '欄標題：基本資料／書名；儲存格內容：星際旅行',
    );
    expect(labels[1].isHeader, isTrue);
  });

  test('invalid explicit header references do not remove header roles', () {
    final labels = FrameEpubTableSemantics.resolve(
      cells: const [
        FrameEpubTableSemanticCell(
          index: 0, row: 0, column: 0, rowSpan: 1, columnSpan: 1,
          rowGroup: 0, rowGroupEnd: 1, isHeader: true,
          isHeaderElement: true, isHeaderRow: true, text: '標題',
          id: 'heading', headers: 'missing-parent',
        ),
      ],
    );

    expect(labels.single.label, '標題');
    expect(labels.single.isHeader, isTrue);
  });

  test('unknown explicit header ids are safely ignored', () {
    final labels = FrameEpubTableSemantics.resolve(
      cells: const [
        FrameEpubTableSemanticCell(
          index: 0, row: 0, column: 0, rowSpan: 1, columnSpan: 1,
          rowGroup: 0, rowGroupEnd: 1, isHeader: false,
          isHeaderElement: false, isHeaderRow: false, text: '資料',
          headers: 'missing-id',
        ),
      ],
    );

    expect(labels.single.label, '資料');
  });
}
