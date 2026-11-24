/// Resolves preferred table column widths into concrete track sizes.
class FrameEpubTableColumnWidthsResult {
  const FrameEpubTableColumnWidthsResult({
    required this.tableWidth,
    required this.widths,
  });

  final double tableWidth;
  final List<double> widths;
}

class FrameEpubTableColumnWidths {
  FrameEpubTableColumnWidths._();

  /// [widthHints] contains preferred pixel widths, or null for auto tracks.
  ///
  /// Explicit tracks keep their requested size when auto tracks can absorb the
  /// remaining space. When every track is explicit, the preferences are scaled
  /// proportionally to fill the table's available width.
  static FrameEpubTableColumnWidthsResult resolve({
    required double requestedWidth,
    required double minimumColumnWidth,
    required List<double?> widthHints,
  }) {
    if (!requestedWidth.isFinite || requestedWidth <= 0) {
      throw ArgumentError.value(
        requestedWidth,
        'requestedWidth',
        'Must be a finite positive width.',
      );
    }
    if (!minimumColumnWidth.isFinite || minimumColumnWidth <= 0) {
      throw ArgumentError.value(
        minimumColumnWidth,
        'minimumColumnWidth',
        'Must be a finite positive width.',
      );
    }
    if (widthHints.isEmpty) {
      return FrameEpubTableColumnWidthsResult(
        tableWidth: requestedWidth,
        widths: const [],
      );
    }

    final normalized = widthHints.map((hint) {
      if (hint == null || !hint.isFinite || hint <= 0) return null;
      return hint < minimumColumnWidth ? minimumColumnWidth : hint;
    }).toList(growable: false);
    final autoCount = normalized.where((width) => width == null).length;
    final explicitTotal = normalized
        .whereType<double>()
        .fold<double>(0, (total, width) => total + width);

    if (autoCount > 0) {
      final minimumTableWidth =
          explicitTotal + minimumColumnWidth * autoCount;
      final tableWidth = requestedWidth > minimumTableWidth
          ? requestedWidth
          : minimumTableWidth;
      final autoWidth = (tableWidth - explicitTotal) / autoCount;
      final widths = normalized
          .map((width) => width ?? autoWidth)
          .toList(growable: false);
      return FrameEpubTableColumnWidthsResult(
        tableWidth: tableWidth,
        widths: List<double>.unmodifiable(widths),
      );
    }

    final tableWidth =
        requestedWidth > explicitTotal ? requestedWidth : explicitTotal;
    final scale = tableWidth / explicitTotal;
    return FrameEpubTableColumnWidthsResult(
      tableWidth: tableWidth,
      widths: List<double>.unmodifiable(
        normalized.map((width) => width! * scale),
      ),
    );
  }
}
