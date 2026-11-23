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
}
