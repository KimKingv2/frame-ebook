import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_table_layout.dart';

void main() {
  test('adds tracks pushed right by an active rowspan', () {
    final layout = FrameEpubTableLayout.build(
      rows: [
        const [
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 2, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
        ],
        const [
          FrameEpubTableCellSpec(columnSpan: 2, rowSpan: 1, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
        ],
      ],
    );

    expect(layout.columnCount, 4);
    expect(
      layout.rows.map((row) => row.placements.fold<int>(
            0,
            (total, placement) => total + placement.columnSpan,
          )),
      [4, 4],
      reason: 'Every rendered row must allocate the same four table tracks.',
    );
    expect(
      layout.rows[0].placements.map((placement) => (
        placement.cellIndex,
        placement.columnSpan,
      )),
      [
        (0, 1),
        (1, 1),
        (2, 1),
        (null, 1),
      ],
    );
    expect(
      layout.rows[1].placements.map((placement) => (
        placement.cellIndex,
        placement.columnSpan,
      )),
      [
        (null, 1),
        (0, 2),
        (1, 1),
      ],
    );
    expect(
      layout.rows[0].placements.map((placement) => placement.rowSpan),
      [2, 1, 1, 1],
    );
    expect(
      layout.rows[1].placements.map((placement) => placement.rowSpan),
      [1, 1, 1],
    );
  });

  test('places several rowspans before preserving following source cells', () {
    final layout = FrameEpubTableLayout.build(
      rows: [
        const [
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 3, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 2, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
        ],
        const [
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 3, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
        ],
        const [
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 3, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
        ],
        const [
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 2, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
        ],
        const [
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
        ],
      ],
    );

    expect(layout.columnCount, 4);
    final rowTwo = layout.rows[2].placements;
    expect(
      rowTwo.map((placement) => (placement.cellIndex, placement.columnSpan)),
      [(null, 1), (0, 1), (null, 1), (1, 1)],
    );
    expect(
      layout.rows.map((row) => row.placements.fold<int>(
            0,
            (sum, placement) => sum + placement.columnSpan,
          )),
      everyElement(4),
    );
    expect(layout.rows[0].placements.first.rowSpan, 3);
    expect(layout.rows[1].placements[1].rowSpan, 3);
    expect(layout.rows[2].placements[1].rowSpan, 3);
    expect(layout.rows[3].placements.first.rowSpan, 2);
  });

  test('keeps source cell order and header flags after grid placement', () {
    final layout = FrameEpubTableLayout.build(
      rows: [
        const [
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 2, header: true),
          FrameEpubTableCellSpec(columnSpan: 2, rowSpan: 1, header: true),
        ],
        const [
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
        ],
      ],
    );

    expect(layout.columnCount, 3);
    expect(layout.rows[0].placements.first.cellIndex, 0);
    expect(layout.rows[0].placements[1].cellIndex, 1);
    expect(layout.rows[0].placements[1].header, isTrue);
    expect(layout.rows[1].placements.first.cellIndex, isNull);
    expect(layout.rows[1].placements[1].cellIndex, 0);
    expect(layout.rows[1].placements[2].cellIndex, 1);
    expect(layout.rows[1].placements.every((placement) => !placement.header),
        isTrue);
  });

  test('creates a single empty grid track for each empty source row', () {
    final layout = FrameEpubTableLayout.build(
      rows: [
        const [
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
          FrameEpubTableCellSpec(columnSpan: 1, rowSpan: 1, header: false),
        ],
        const [],
      ],
    );

    expect(layout.columnCount, 2);
    expect(layout.rows[1].placements, hasLength(1));
    expect(layout.rows[1].placements.single.cellIndex, isNull);
    expect(layout.rows[1].placements.single.columnSpan, 2);
  });

  test('returns an empty layout for a table without rows', () {
    final layout = FrameEpubTableLayout.build(rows: const []);

    expect(layout.columnCount, 0);
    expect(layout.rows, isEmpty);
  });
}
