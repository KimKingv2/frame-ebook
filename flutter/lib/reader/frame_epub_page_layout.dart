/// A group of XHTML flow items that fit on one reader page.
class FrameEpubPage {
  const FrameEpubPage({
    required this.itemIndices,
    this.requiresVerticalScroll = false,
  });

  final List<int> itemIndices;
  final bool requiresVerticalScroll;
}

/// Greedy layout helper shared by the EPUB renderer and its unit tests.
///
/// Items are measured at the final page width before this helper is called.
/// A single item taller than the available page height is kept intact on its
/// own page and marked for vertical overflow scrolling instead of being cut.
class FrameEpubPageLayout {
  FrameEpubPageLayout._();

  /// Groups sequential single pages into two-page spreads.
  ///
  /// The final spread may contain one page. The renderer positions that page
  /// in the first reading slot, respecting the book's reading direction.
  static List<List<int>> groupIntoSpreads(int pageCount) {
    if (pageCount <= 0) return const [];

    final spreads = <List<int>>[];
    for (var page = 0; page < pageCount; page += 2) {
      spreads.add(List<int>.unmodifiable(
        page + 1 < pageCount ? [page, page + 1] : [page],
      ));
    }
    return List<List<int>>.unmodifiable(spreads);
  }

  static List<FrameEpubPage> paginate({
    required List<double> itemHeights,
    required double availableHeight,
    Set<int> breakBeforeIndices = const {},
    Set<int> breakAfterIndices = const {},
  }) {
    if (!availableHeight.isFinite || availableHeight <= 0) {
      throw ArgumentError.value(
        availableHeight,
        'availableHeight',
        'Must be a finite positive page height.',
      );
    }

    final pages = <FrameEpubPage>[];
    var current = <int>[];
    var currentHeight = 0.0;

    void flush() {
      if (current.isEmpty) return;
      pages.add(FrameEpubPage(
        itemIndices: List<int>.unmodifiable(current),
      ));
      current = <int>[];
      currentHeight = 0;
    }

    for (var index = 0; index < itemHeights.length; index++) {
      if (breakBeforeIndices.contains(index)) flush();

      final rawHeight = itemHeights[index];
      final height = rawHeight.isFinite && rawHeight > 0 ? rawHeight : 0.0;

      if (height > availableHeight) {
        flush();
        pages.add(FrameEpubPage(
          itemIndices: List<int>.unmodifiable([index]),
          requiresVerticalScroll: true,
        ));
        continue;
      }

      if (current.isNotEmpty && currentHeight + height > availableHeight) {
        flush();
      }
      current.add(index);
      currentHeight += height;

      if (breakAfterIndices.contains(index)) flush();
    }

    flush();
    if (pages.isEmpty) {
      pages.add(const FrameEpubPage(itemIndices: []));
    }
    return List<FrameEpubPage>.unmodifiable(pages);
  }
}
