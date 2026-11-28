/// Shared responsive breakpoint for the reader's compact quick-action row.
bool frameEpubUsesMobileQuickActions(double viewportWidth) =>
    viewportWidth <= 820;

/// Square, icon-only quick actions matching the final legacy Reading Room
/// cascade: 48px on desktop and 44px through the mobile 820px breakpoint.
double frameEpubReaderQuickActionWidth(double viewportWidth) =>
    viewportWidth <= 820 ? 44 : 48;

double frameEpubReaderQuickActionHeight(double viewportWidth) =>
    viewportWidth <= 820 ? 44 : 48;

/// The final legacy cascade uses a 2px desktop gap and no mobile gap.
double frameEpubReaderQuickActionGap(double viewportWidth) =>
    viewportWidth <= 820 ? 0 : 2;

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
