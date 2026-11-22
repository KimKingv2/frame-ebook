/// Shared responsive breakpoint for the reader's compact quick-action row.
bool frameEpubUsesMobileQuickActions(double viewportWidth) =>
    viewportWidth <= 820;

/// Normal-sized rectangular icon actions, matching the earlier reader style.
/// The 560px breakpoint is used for the compact phone toolbar.
double frameEpubReaderQuickActionWidth(double viewportWidth) =>
    viewportWidth <= 560 ? 32 : 36;

double frameEpubReaderQuickActionHeight(double viewportWidth) =>
    viewportWidth <= 560 ? 27 : 31;

/// The action row uses a small, consistent gap rather than a wide dock.
double frameEpubReaderQuickActionGap(double viewportWidth) => 4;

/// Width of the four-button group, including the gaps between buttons.
double frameEpubReaderQuickActionsWidth(double viewportWidth) {
  final width = frameEpubReaderQuickActionWidth(viewportWidth);
  return width * 4 + frameEpubReaderQuickActionGap(viewportWidth) * 3;
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
