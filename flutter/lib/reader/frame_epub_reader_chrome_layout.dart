/// Shared responsive breakpoint for the legacy Reading Room action row.
bool frameEpubUsesMobileQuickActions(double viewportWidth) =>
    viewportWidth <= 820;

/// The old reader uses four 48px circular icon buttons on desktop, then
/// compact 44px targets at the 820px breakpoint.
double frameEpubReaderQuickActionSize(double viewportWidth) =>
    viewportWidth <= 820 ? 44 : 48;

/// The legacy action row has a 2px desktop gap and no compact-screen gap.
double frameEpubReaderQuickActionGap(double viewportWidth) =>
    viewportWidth <= 820 ? 0 : 2;

/// Effective gap between the chapter label and icon row. The old CSS combines
/// the parent column gap with the action row's own top margin.
double frameEpubReaderQuickActionStackGap(double viewportWidth) =>
    viewportWidth <= 820 ? 6 : 10;

/// Width of the four-button group, including the inter-button gaps.
double frameEpubReaderQuickActionsWidth(double viewportWidth) {
  final size = frameEpubReaderQuickActionSize(viewportWidth);
  final gap = frameEpubReaderQuickActionGap(viewportWidth);
  return size * 4 + gap * 3;
}

/// Desktop navigation-column geometry copied from the legacy Reading Room CSS.
///
/// Wide desktop: 250px + 16px gap. At <=1050px, and in normal fullscreen,
/// the legacy reader uses 220px + 12px. At <=820px the legacy reader switches
/// to an overlay drawer rather than reserving a permanent column.
class FrameEpubReaderWorkspaceLayout {
  const FrameEpubReaderWorkspaceLayout({
    required this.sidebarWidth,
    required this.gap,
  });

  factory FrameEpubReaderWorkspaceLayout.fromViewport({
    required double viewportWidth,
    bool fullscreen = false,
    bool sidebarVisible = true,
  }) {
    if (!sidebarVisible || viewportWidth <= 820) {
      return const FrameEpubReaderWorkspaceLayout(
        sidebarWidth: 0,
        gap: 0,
      );
    }

    final compactDesktop = fullscreen || viewportWidth <= 1050;
    return FrameEpubReaderWorkspaceLayout(
      sidebarWidth: compactDesktop ? 220 : 250,
      gap: compactDesktop ? 12 : 16,
    );
  }

  final double sidebarWidth;
  final double gap;
}
