import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_table_column_widths.dart';

void main() {
  test('keeps explicit tracks and divides remaining space among auto tracks',
      () {
    final result = FrameEpubTableColumnWidths.resolve(
      requestedWidth: 600,
      minimumColumnWidth: 104,
      widthHints: const [120, null, 180],
    );

    expect(result.tableWidth, 600);
    expect(result.widths, [120, 300, 180]);
  });

  test('expands the table when explicit tracks leave too little room', () {
    final result = FrameEpubTableColumnWidths.resolve(
      requestedWidth: 400,
      minimumColumnWidth: 104,
      widthHints: const [240, 240, null],
    );

    expect(result.tableWidth, 584);
    expect(result.widths, [240, 240, 104]);
  });

  test('scales fully declared tracks proportionally to fill available width',
      () {
    final result = FrameEpubTableColumnWidths.resolve(
      requestedWidth: 600,
      minimumColumnWidth: 104,
      widthHints: const [120, 360],
    );

    expect(result.tableWidth, 600);
    expect(result.widths, [150, 450]);
  });

  test('distributes an all-auto table evenly', () {
    final result = FrameEpubTableColumnWidths.resolve(
      requestedWidth: 500,
      minimumColumnWidth: 104,
      widthHints: const [null, null],
    );

    expect(result.tableWidth, 500);
    expect(result.widths, [250, 250]);
  });

  test('returns an empty width list for a zero-column table', () {
    final result = FrameEpubTableColumnWidths.resolve(
      requestedWidth: 500,
      minimumColumnWidth: 104,
      widthHints: const [],
    );

    expect(result.tableWidth, 500);
    expect(result.widths, isEmpty);
  });

  test('rejects non-positive requested widths', () {
    expect(
      () => FrameEpubTableColumnWidths.resolve(
        requestedWidth: 0,
        minimumColumnWidth: 104,
        widthHints: const [100],
      ),
      throwsArgumentError,
    );
  });
}
