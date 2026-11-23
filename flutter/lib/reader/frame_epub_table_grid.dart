import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Positions table cells in a shared row/column grid and gives rowspan cells
/// the combined height of the rows they cover.
class FrameEpubTableGrid extends MultiChildRenderObjectWidget {
  const FrameEpubTableGrid({
    required this.width,
    required this.columnCount,
    required this.rowCount,
    required super.children,
    super.key,
  })  : assert(width >= 0),
        assert(columnCount > 0),
        assert(rowCount > 0);

  final double width;
  final int columnCount;
  final int rowCount;

  @override
  RenderFrameEpubTableGrid createRenderObject(BuildContext context) {
    return RenderFrameEpubTableGrid(
      width: width,
      columnCount: columnCount,
      rowCount: rowCount,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderFrameEpubTableGrid renderObject,
  ) {
    renderObject
      ..width = width
      ..columnCount = columnCount
      ..rowCount = rowCount;
  }
}

class FrameEpubTableGridCell
    extends ParentDataWidget<FrameEpubTableGridParentData> {
  const FrameEpubTableGridCell({
    required this.row,
    required this.column,
    required this.columnSpan,
    required this.rowSpan,
    required super.child,
    super.key,
  })  : assert(row >= 0),
        assert(column >= 0),
        assert(columnSpan > 0),
        assert(rowSpan > 0);

  final int row;
  final int column;
  final int columnSpan;
  final int rowSpan;

  @override
  void applyParentData(RenderObject renderObject) {
    final parentData =
        renderObject.parentData! as FrameEpubTableGridParentData;
    if (parentData.row == row &&
        parentData.column == column &&
        parentData.columnSpan == columnSpan &&
        parentData.rowSpan == rowSpan) {
      return;
    }
    parentData
      ..row = row
      ..column = column
      ..columnSpan = columnSpan
      ..rowSpan = rowSpan;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => FrameEpubTableGrid;
}

class FrameEpubTableGridParentData
    extends ContainerBoxParentData<RenderBox> {
  int row = 0;
  int column = 0;
  int columnSpan = 1;
  int rowSpan = 1;
}

class _MeasuredTableCell {
  const _MeasuredTableCell({
    required this.child,
    required this.parentData,
    required this.naturalHeight,
  });

  final RenderBox child;
  final FrameEpubTableGridParentData parentData;
  final double naturalHeight;
}

class RenderFrameEpubTableGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, FrameEpubTableGridParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox,
            FrameEpubTableGridParentData> {
  RenderFrameEpubTableGrid({
    required double width,
    required int columnCount,
    required int rowCount,
  })  : _width = width,
        _columnCount = columnCount,
        _rowCount = rowCount;

  double _width;
  int _columnCount;
  int _rowCount;

  double get width => _width;

  set width(double value) {
    if (_width == value) return;
    _width = value;
    markNeedsLayout();
  }

  int get columnCount => _columnCount;

  set columnCount(int value) {
    if (_columnCount == value) return;
    _columnCount = value;
    markNeedsLayout();
  }

  int get rowCount => _rowCount;

  set rowCount(int value) {
    if (_rowCount == value) return;
    _rowCount = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! FrameEpubTableGridParentData) {
      child.parentData = FrameEpubTableGridParentData();
    }
  }

  List<double> _resolveRowHeights(
    List<_MeasuredTableCell> measurements,
  ) {
    final rowHeights = List<double>.filled(_rowCount, 0);

    for (final measurement in measurements) {
      final data = measurement.parentData;
      final span = data.rowSpan.clamp(1, _rowCount - data.row).toInt();
      if (span == 1) {
        rowHeights[data.row] =
            rowHeights[data.row] < measurement.naturalHeight
                ? measurement.naturalHeight
                : rowHeights[data.row];
      }
    }

    // A spanning cell may be taller than the rows' normal content combined.
    // Spread only its remaining height across those rows. Later spanning cells
    // can increase the same rows further, so previously satisfied spans stay
    // satisfied without a second layout pass over the table.
    for (final measurement in measurements) {
      final data = measurement.parentData;
      final span = data.rowSpan.clamp(1, _rowCount - data.row).toInt();
      if (span <= 1) continue;
      var coveredHeight = 0.0;
      for (var offset = 0; offset < span; offset++) {
        coveredHeight += rowHeights[data.row + offset];
      }
      final deficit = measurement.naturalHeight - coveredHeight;
      if (deficit <= 0) continue;
      final addition = deficit / span;
      for (var offset = 0; offset < span; offset++) {
        rowHeights[data.row + offset] += addition;
      }
    }
    return rowHeights;
  }

  double _heightForWidth(double availableWidth) {
    if (_rowCount <= 0 || _columnCount <= 0) return 0;
    final measurements = <_MeasuredTableCell>[];
    RenderBox? child = firstChild;
    while (child != null) {
      final data = child.parentData! as FrameEpubTableGridParentData;
      final span = data.columnSpan.clamp(1, _columnCount - data.column).toInt();
      final cellWidth = availableWidth * span / _columnCount;
      measurements.add(_MeasuredTableCell(
        child: child,
        parentData: data,
        naturalHeight: child.getMaxIntrinsicHeight(cellWidth),
      ));
      child = data.nextSibling;
    }
    return _resolveRowHeights(measurements)
        .fold<double>(0, (total, value) => total + value);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _width;

  @override
  double computeMaxIntrinsicWidth(double height) => _width;

  @override
  double computeMinIntrinsicHeight(double width) =>
      _heightForWidth(width.isFinite ? width : _width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _heightForWidth(width.isFinite ? width : _width);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final width = constraints.constrainWidth(_width);
    return constraints.constrain(Size(width, _heightForWidth(width)));
  }

  @override
  void performLayout() {
    final width = constraints.constrainWidth(_width);
    if (_rowCount <= 0 || _columnCount <= 0) {
      size = constraints.constrain(Size(width, 0));
      return;
    }

    final measurements = <_MeasuredTableCell>[];
    RenderBox? child = firstChild;
    while (child != null) {
      final data = child.parentData! as FrameEpubTableGridParentData;
      final span = data.columnSpan.clamp(1, _columnCount - data.column).toInt();
      final cellWidth = width * span / _columnCount;
      child.layout(
        BoxConstraints(minWidth: cellWidth, maxWidth: cellWidth),
        parentUsesSize: true,
      );
      measurements.add(_MeasuredTableCell(
        child: child,
        parentData: data,
        naturalHeight: child.size.height,
      ));
      child = data.nextSibling;
    }

    final rowHeights = _resolveRowHeights(measurements);
    for (final measurement in measurements) {
      final data = measurement.parentData;
      final columnSpan =
          data.columnSpan.clamp(1, _columnCount - data.column).toInt();
      final rowSpan = data.rowSpan.clamp(1, _rowCount - data.row).toInt();
      final cellWidth = width * columnSpan / _columnCount;
      var cellHeight = 0.0;
      for (var offset = 0; offset < rowSpan; offset++) {
        cellHeight += rowHeights[data.row + offset];
      }
      var top = 0.0;
      for (var row = 0; row < data.row; row++) {
        top += rowHeights[row];
      }
      final left = width * data.column / _columnCount;
      measurement.child.layout(
        BoxConstraints.tightFor(width: cellWidth, height: cellHeight),
        parentUsesSize: true,
      );
      data.offset = Offset(left, top);
    }

    final height = rowHeights.fold<double>(0, (total, value) => total + value);
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(
    BoxHitTestResult result, {
    required Offset position,
  }) {
    return defaultHitTestChildren(result, position: position);
  }
}
