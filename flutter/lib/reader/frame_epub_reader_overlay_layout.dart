import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Geometry of the legacy Reading Room's final right-side appearance drawer.
class FrameEpubAppearancePanelLayout {
  const FrameEpubAppearancePanelLayout({
    required this.isCompact,
    required this.alignment,
    required this.width,
    required this.height,
    required this.outerPadding,
    required this.contentHorizontalPadding,
  });

  factory FrameEpubAppearancePanelLayout.fromViewport(
    Size viewport, {
    bool fullscreen = false,
    EdgeInsets safeArea = EdgeInsets.zero,
  }) {
    // Final legacy CSS cascade: 420 px at <= 820 px, 440 px above it.
    final isCompact = viewport.width <= 820;
    final widthCap = isCompact ? 420.0 : 440.0;
    final width = math.min(
      math.min(widthCap, viewport.width * .91),
      math.max(0.0, viewport.width - 16),
    ).toDouble();
    final edgeInset = fullscreen ? (isCompact ? 6.0 : 0.0) : 8.0;
    final topInset = safeArea.top + edgeInset;
    final bottomInset = safeArea.bottom + edgeInset;

    return FrameEpubAppearancePanelLayout(
      isCompact: isCompact,
      alignment: Alignment.centerRight,
      width: width,
      height:
          math.max(0.0, viewport.height - topInset - bottomInset).toDouble(),
      outerPadding: EdgeInsets.only(
        top: topInset,
        bottom: bottomInset,
      ),
      contentHorizontalPadding: isCompact ? 15 : 18,
    );
  }

  final bool isCompact;
  final Alignment alignment;
  final double width;
  final double height;
  final EdgeInsets outerPadding;
  final double contentHorizontalPadding;
}
