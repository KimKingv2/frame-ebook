import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_table_grid.dart';

void main() {
  testWidgets('rowspan cell occupies the combined height of its rows',
      (tester) async {
    const spanKey = ValueKey('spanning-cell');
    const firstRowKey = ValueKey('first-row-cell');
    const secondRowKey = ValueKey('second-row-cell');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FrameEpubTableGrid(
          width: 300,
          columnCount: 2,
          rowCount: 2,
          children: const [
            FrameEpubTableGridCell(
              row: 0,
              column: 0,
              columnSpan: 1,
              rowSpan: 2,
              child: SizedBox(
                key: spanKey,
                height: 90,
              ),
            ),
            FrameEpubTableGridCell(
              row: 0,
              column: 1,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(
                key: firstRowKey,
                height: 20,
              ),
            ),
            FrameEpubTableGridCell(
              row: 1,
              column: 1,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(
                key: secondRowKey,
                height: 30,
              ),
            ),
          ],
        ),
      ),
    ));

    final spanningRect = tester.getRect(find.byKey(spanKey));
    final firstRowRect = tester.getRect(find.byKey(firstRowKey));
    final secondRowRect = tester.getRect(find.byKey(secondRowKey));

    expect(spanningRect.top, closeTo(firstRowRect.top, 0.01));
    expect(secondRowRect.top, closeTo(firstRowRect.bottom, 0.01));
    expect(spanningRect.bottom, closeTo(secondRowRect.bottom, 0.01));
    expect(spanningRect.height, closeTo(90, 0.01));
    expect(tester.takeException(), isNull);
  });


  testWidgets('uses explicit column widths when laying out grid tracks',
      (tester) async {
    const firstKey = ValueKey('narrow-table-track');
    const secondKey = ValueKey('wide-table-track');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FrameEpubTableGrid(
          width: 300,
          columnCount: 2,
          rowCount: 1,
          columnWidths: const [75, 225],
          children: const [
            FrameEpubTableGridCell(
              row: 0,
              column: 0,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(key: firstKey, height: 24),
            ),
            FrameEpubTableGridCell(
              row: 0,
              column: 1,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(key: secondKey, height: 24),
            ),
          ],
        ),
      ),
    ));

    final firstRect = tester.getRect(find.byKey(firstKey));
    final secondRect = tester.getRect(find.byKey(secondKey));
    expect(firstRect.width, closeTo(75, 0.01));
    expect(secondRect.width, closeTo(225, 0.01));
    expect(secondRect.left, closeTo(firstRect.right, 0.01));
    expect(tester.takeException(), isNull);
  });


  testWidgets('includes separate border spacing between table tracks',
      (tester) async {
    const firstKey = ValueKey('separate-first-cell');
    const nextRowKey = ValueKey('separate-next-row-cell');
    const spanKey = ValueKey('separate-spanning-cell');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FrameEpubTableGrid(
          width: 300,
          columnCount: 2,
          rowCount: 2,
          columnWidths: const [100, 190],
          columnSpacing: 10,
          rowSpacing: 8,
          children: const [
            FrameEpubTableGridCell(
              row: 0,
              column: 0,
              columnSpan: 1,
              rowSpan: 2,
              child: SizedBox(key: spanKey, height: 58),
            ),
            FrameEpubTableGridCell(
              row: 0,
              column: 1,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(key: firstKey, height: 20),
            ),
            FrameEpubTableGridCell(
              row: 1,
              column: 1,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(key: nextRowKey, height: 30),
            ),
          ],
        ),
      ),
    ));

    final firstRect = tester.getRect(find.byKey(firstKey));
    final secondRect = tester.getRect(find.byKey(nextRowKey));
    final spanningRect = tester.getRect(find.byKey(spanKey));
    expect(firstRect.left, closeTo(110, 0.01));
    expect(firstRect.width, closeTo(190, 0.01));
    expect(secondRect.top, closeTo(firstRect.bottom + 8, 0.01));
    expect(spanningRect.height, closeTo(secondRect.bottom - spanningRect.top, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('satisfies several overlapping rowspan height constraints',
      (tester) async {
    const aKey = ValueKey('span-a');
    const bKey = ValueKey('span-b');
    const dKey = ValueKey('span-d');
    const eKey = ValueKey('span-e');
    const fKey = ValueKey('span-f');
    const markerKeys = [
      ValueKey('row-marker-0'),
      ValueKey('row-marker-1'),
      ValueKey('row-marker-2'),
      ValueKey('row-marker-3'),
      ValueKey('row-marker-4'),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FrameEpubTableGrid(
          width: 480,
          columnCount: 4,
          rowCount: 5,
          children: [
            FrameEpubTableGridCell(
              row: 0,
              column: 0,
              columnSpan: 1,
              rowSpan: 3,
              child: const SizedBox(key: aKey, height: 125),
            ),
            FrameEpubTableGridCell(
              row: 0,
              column: 1,
              columnSpan: 1,
              rowSpan: 2,
              child: const SizedBox(key: bKey, height: 90),
            ),
            const FrameEpubTableGridCell(
              row: 0,
              column: 2,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(height: 22),
            ),
            FrameEpubTableGridCell(
              row: 0,
              column: 3,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(key: markerKeys[0], height: 16),
            ),
            FrameEpubTableGridCell(
              row: 1,
              column: 2,
              columnSpan: 1,
              rowSpan: 3,
              child: const SizedBox(key: dKey, height: 155),
            ),
            FrameEpubTableGridCell(
              row: 1,
              column: 3,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(key: markerKeys[1], height: 20),
            ),
            FrameEpubTableGridCell(
              row: 2,
              column: 1,
              columnSpan: 1,
              rowSpan: 3,
              child: const SizedBox(key: eKey, height: 130),
            ),
            FrameEpubTableGridCell(
              row: 2,
              column: 3,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(key: markerKeys[2], height: 24),
            ),
            FrameEpubTableGridCell(
              row: 3,
              column: 0,
              columnSpan: 1,
              rowSpan: 2,
              child: const SizedBox(key: fKey, height: 95),
            ),
            FrameEpubTableGridCell(
              row: 3,
              column: 3,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(key: markerKeys[3], height: 28),
            ),
            FrameEpubTableGridCell(
              row: 4,
              column: 3,
              columnSpan: 1,
              rowSpan: 1,
              child: SizedBox(key: markerKeys[4], height: 32),
            ),
          ],
        ),
      ),
    ));

    final markers = markerKeys.map((key) => tester.getRect(find.byKey(key)));
    final rowRects = markers.toList(growable: false);
    Rect spanRect(ValueKey<String> key) => tester.getRect(find.byKey(key));

    expect(spanRect(aKey).top, closeTo(rowRects[0].top, 0.01));
    expect(spanRect(aKey).bottom, closeTo(rowRects[2].bottom, 0.01));
    expect(spanRect(bKey).top, closeTo(rowRects[0].top, 0.01));
    expect(spanRect(bKey).bottom, closeTo(rowRects[1].bottom, 0.01));
    expect(spanRect(dKey).top, closeTo(rowRects[1].top, 0.01));
    expect(spanRect(dKey).bottom, closeTo(rowRects[3].bottom, 0.01));
    expect(spanRect(eKey).top, closeTo(rowRects[2].top, 0.01));
    expect(spanRect(eKey).bottom, closeTo(rowRects[4].bottom, 0.01));
    expect(spanRect(fKey).top, closeTo(rowRects[3].top, 0.01));
    expect(spanRect(fKey).bottom, closeTo(rowRects[4].bottom, 0.01));
    expect(tester.takeException(), isNull);
  });
}
