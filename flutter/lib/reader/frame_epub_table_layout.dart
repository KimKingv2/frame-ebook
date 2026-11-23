/// Grid placement for an XHTML table, after normalizing rowspan/colspan.
///
/// The result gives every row the same number of flex tracks. Cells covered by
/// an earlier rowspan and unoccupied trailing tracks are represented by null
/// cell placements, keeping row widths aligned without duplicating source cells.
class FrameEpubTableCellSpec {
  const FrameEpubTableCellSpec({
    required this.columnSpan,
    required this.rowSpan,
    required this.header,
  });

  final int columnSpan;
  final int rowSpan;
  final bool header;
}

class FrameEpubTableCellPlacement {
  const FrameEpubTableCellPlacement({
    required this.cellIndex,
    required this.columnSpan,
    this.rowSpan = 1,
    this.header = false,
  });

  /// Index in the source row, or null for an occupied/empty grid track.
  final int? cellIndex;
  final int columnSpan;
  final int rowSpan;
  final bool header;
}

class FrameEpubTableRowLayout {
  const FrameEpubTableRowLayout(this.placements);

  final List<FrameEpubTableCellPlacement> placements;
}

class FrameEpubTableLayoutResult {
  const FrameEpubTableLayoutResult({
    required this.columnCount,
    required this.rows,
  });

  final int columnCount;
  final List<FrameEpubTableRowLayout> rows;
}

class FrameEpubTableLayout {
  FrameEpubTableLayout._();

  static FrameEpubTableLayoutResult build({
    required List<List<FrameEpubTableCellSpec>> rows,
  }) {
    if (rows.isEmpty) {
      return const FrameEpubTableLayoutResult(
        columnCount: 0,
        rows: [],
      );
    }

    // An exclusive row index until which each column is occupied by a
    // rowspan. Rowspan=1 occupies only the current row.
    final occupiedUntil = <int>[];
    final rawPlacements =
        <Map<int, FrameEpubTableCellPlacement>>[];
    var columnCount = 0;

    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final occupied = List<bool>.generate(
        occupiedUntil.length,
        (column) => occupiedUntil[column] > rowIndex,
      );
      final placements = <int, FrameEpubTableCellPlacement>{};
      var cursor = 0;

      for (var cellIndex = 0;
          cellIndex < rows[rowIndex].length;
          cellIndex++) {
        final spec = rows[rowIndex][cellIndex];
        final columnSpan = spec.columnSpan.clamp(1, 12).toInt();
        while (true) {
          final requiredLength = cursor + columnSpan;
          while (occupied.length < requiredLength) {
            occupied.add(false);
            occupiedUntil.add(0);
          }

          var blockedOffset = -1;
          for (var offset = 0; offset < columnSpan; offset++) {
            if (occupied[cursor + offset]) {
              blockedOffset = offset;
              break;
            }
          }
          if (blockedOffset >= 0) {
            cursor += blockedOffset + 1;
            continue;
          }

          final rowSpan = spec.rowSpan
              .clamp(1, rows.length - rowIndex)
              .toInt();
          placements[cursor] = FrameEpubTableCellPlacement(
            cellIndex: cellIndex,
            columnSpan: columnSpan,
            rowSpan: rowSpan,
            header: spec.header,
          );
          final occupiedThrough = rowIndex + rowSpan;
          for (var offset = 0; offset < columnSpan; offset++) {
            final column = cursor + offset;
            occupied[column] = true;
            if (occupiedThrough > occupiedUntil[column]) {
              occupiedUntil[column] = occupiedThrough;
            }
          }
          cursor += columnSpan;
          break;
        }
      }

      rawPlacements.add(placements);
      if (occupied.length > columnCount) columnCount = occupied.length;
    }

    final resultRows = <FrameEpubTableRowLayout>[];
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final sourcePlacements = rawPlacements[rowIndex];
      final placements = <FrameEpubTableCellPlacement>[];
      var column = 0;
      while (column < columnCount) {
        final cell = sourcePlacements[column];
        if (cell != null) {
          placements.add(cell);
          column += cell.columnSpan;
          continue;
        }

        var emptySpan = 1;
        while (column + emptySpan < columnCount &&
            !sourcePlacements.containsKey(column + emptySpan)) {
          emptySpan++;
        }
        placements.add(FrameEpubTableCellPlacement(
          cellIndex: null,
          columnSpan: emptySpan,
        ));
        column += emptySpan;
      }
      resultRows.add(FrameEpubTableRowLayout(
        List<FrameEpubTableCellPlacement>.unmodifiable(placements),
      ));
    }

    return FrameEpubTableLayoutResult(
      columnCount: columnCount,
      rows: List<FrameEpubTableRowLayout>.unmodifiable(resultRows),
    );
  }
}
