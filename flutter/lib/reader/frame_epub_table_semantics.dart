/// A resolved column group in an EPUB/XHTML table.
class FrameEpubTableColumnGroup {
  const FrameEpubTableColumnGroup({
    required this.startColumn,
    required this.endColumn,
  })  : assert(startColumn >= 0),
        assert(endColumn > startColumn);

  final int startColumn;

  /// Exclusive end column.
  final int endColumn;

  bool overlaps(int start, int end) =>
      start < endColumn && end > startColumn;
}

/// Source and grid information needed to derive table header relationships.
class FrameEpubTableSemanticCell {
  const FrameEpubTableSemanticCell({
    required this.index,
    required this.row,
    required this.column,
    required this.rowSpan,
    required this.columnSpan,
    required this.rowGroup,
    required this.rowGroupEnd,
    required this.isHeader,
    required this.isHeaderElement,
    required this.isHeaderRow,
    required this.text,
    this.id,
    this.headers,
    this.scope,
    this.abbreviation,
  });

  final int index;
  final int row;
  final int column;
  final int rowSpan;
  final int columnSpan;
  final int rowGroup;

  /// Exclusive end row for this cell's row group.
  final int rowGroupEnd;

  /// Whether the renderer should expose this cell with the header role.
  final bool isHeader;

  /// Whether the source element is actually a th element.
  final bool isHeaderElement;

  /// Whether the cell belongs to a thead row.
  final bool isHeaderRow;

  final String text;
  final String? id;
  final String? headers;
  final String? scope;
  final String? abbreviation;

  int get endRow => row + rowSpan;
  int get endColumn => column + columnSpan;

  String get accessibleHeaderText {
    final shortLabel = abbreviation?.trim();
    return shortLabel == null || shortLabel.isEmpty ? text : shortLabel;
  }
}

/// Accessible label for one rendered table cell.
class FrameEpubTableSemanticLabel {
  const FrameEpubTableSemanticLabel({
    required this.label,
    required this.isHeader,
  });

  final String label;
  final bool isHeader;
}

/// Resolves explicit header references and structural scope relations.
///
/// Flutter exposes header cells as semantic headers, but does not expose an
/// HTML table's header-association graph directly. Data-cell labels therefore
/// include their associated headings so assistive technology can announce
/// the context when a cell is focused.
class FrameEpubTableSemantics {
  FrameEpubTableSemantics._();

  static List<FrameEpubTableSemanticLabel> resolve({
    required List<FrameEpubTableSemanticCell> cells,
    List<FrameEpubTableColumnGroup> columnGroups = const [],
  }) {
    final headersById = <String, FrameEpubTableSemanticCell>{};
    for (final cell in cells) {
      final id = cell.id?.trim();
      if (cell.isHeaderElement && id != null && id.isNotEmpty) {
        headersById.putIfAbsent(id, () => cell);
      }
    }

    return List.unmodifiable([
      for (final cell in cells)
        _resolveCell(
          cell,
          cells,
          headersById,
          columnGroups,
        ),
    ]);
  }

  static FrameEpubTableSemanticLabel _resolveCell(
    FrameEpubTableSemanticCell cell,
    List<FrameEpubTableSemanticCell> cells,
    Map<String, FrameEpubTableSemanticCell> headersById,
    List<FrameEpubTableColumnGroup> columnGroups,
  ) {
    if (cell.isHeader) {
      return FrameEpubTableSemanticLabel(
        label: cell.text,
        isHeader: true,
      );
    }

    final explicitHeaderIds = (cell.headers ?? '')
        .split(RegExp(r'\\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    final associated = <FrameEpubTableSemanticCell>[];
    if (explicitHeaderIds.isNotEmpty) {
      for (final id in explicitHeaderIds) {
        final header = headersById[id];
        if (header != null && header.index != cell.index) {
          associated.add(header);
        }
      }
    } else {
      for (final header in cells) {
        if (!header.isHeaderElement || header.index == cell.index) continue;
        if (_appliesByScope(header, cell, columnGroups)) {
          associated.add(header);
        }
      }
    }

    if (associated.isEmpty) {
      return FrameEpubTableSemanticLabel(
        label: cell.text,
        isHeader: false,
      );
    }

    final columnHeaders = <String>[];
    final rowHeaders = <String>[];
    final rowGroupHeaders = <String>[];
    final otherHeaders = <String>[];

    for (final header in associated) {
      final label = header.accessibleHeaderText;
      if (label.isEmpty) continue;
      final scope = _normalizedScope(header.scope, header.isHeaderRow);
      final bucket = switch (scope) {
        'col' || 'colgroup' => columnHeaders,
        'row' => rowHeaders,
        'rowgroup' => rowGroupHeaders,
        _ => otherHeaders,
      };
      if (!bucket.contains(label)) bucket.add(label);
    }

    final parts = <String>[
      if (columnHeaders.isNotEmpty) '欄標題：${columnHeaders.join('、')}',
      if (rowHeaders.isNotEmpty) '列標題：${rowHeaders.join('、')}',
      if (rowGroupHeaders.isNotEmpty)
        '列群組標題：${rowGroupHeaders.join('、')}',
      if (otherHeaders.isNotEmpty)
        '關聯標題：${otherHeaders.join('、')}',
      if (cell.text.isNotEmpty) '儲存格內容：${cell.text}',
    ];

    return FrameEpubTableSemanticLabel(
      label: parts.join('；'),
      isHeader: false,
    );
  }

  static bool _appliesByScope(
    FrameEpubTableSemanticCell header,
    FrameEpubTableSemanticCell cell,
    List<FrameEpubTableColumnGroup> columnGroups,
  ) {
    final scope = _normalizedScope(header.scope, header.isHeaderRow);

    switch (scope) {
      case 'col':
        return cell.row >= header.endRow &&
            _columnsOverlap(header, cell);
      case 'row':
        return cell.row >= header.row &&
            cell.row < header.endRow &&
            cell.column >= header.endColumn;
      case 'rowgroup':
        return cell.row >= header.row &&
            cell.row < header.rowGroupEnd &&
            cell.rowGroup == header.rowGroup &&
            // Row-group headers apply to the remaining cells, except the
            // first table column as defined by the HTML table model.
            cell.column > 0;
      case 'colgroup':
        if (cell.row < header.endRow) return false;
        final headerGroups = columnGroups
            .where((group) => group.overlaps(header.column, header.endColumn))
            .toList(growable: false);
        return headerGroups.any(
          (group) => group.overlaps(cell.column, cell.endColumn),
        );
      default:
        return false;
    }
  }

  static bool _columnsOverlap(
    FrameEpubTableSemanticCell left,
    FrameEpubTableSemanticCell right,
  ) =>
      left.column < right.endColumn && right.column < left.endColumn;

  static String _normalizedScope(String? rawScope, bool headerRow) {
    switch ((rawScope ?? '').trim().toLowerCase()) {
      case 'row':
      case 'col':
      case 'rowgroup':
      case 'colgroup':
        return rawScope!.trim().toLowerCase();
      default:
        // The common automatic case for a thead is a column heading. For
        // ordinary tbody rows, a leading th defaults to a row heading.
        return headerRow ? 'col' : 'row';
    }
  }
}
