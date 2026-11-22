import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Positions the Flutter appearance panel using the legacy Reading Room CSS
/// breakpoints and viewport-relative geometry.
class FrameEpubAppearancePanelLayout {
  const FrameEpubAppearancePanelLayout({
    required this.isCompact,
    required this.alignment,
    required this.width,
    required this.maxHeight,
    required this.outerPadding,
    required this.contentHorizontalPadding,
  });

  factory FrameEpubAppearancePanelLayout.fromViewport(Size viewport) {
    final isCompact = viewport.width <= 560;
    final rightInset = isCompact
        ? 8.0
        : math.max(20.0, (viewport.width - 1500) / 2 + 20);

    return FrameEpubAppearancePanelLayout(
      isCompact: isCompact,
      alignment: isCompact ? Alignment.bottomRight : Alignment.topRight,
      width: isCompact
          ? math.max(0, viewport.width - 16)
          : math.min(470, math.max(0, viewport.width - 40)),
      maxHeight: isCompact
          ? viewport.height * .84
          : math.max(0, viewport.height - 104),
      outerPadding: EdgeInsets.only(
        top: isCompact ? 8 : 82,
        right: rightInset,
        bottom: isCompact ? 8 : 0,
        left: 8,
      ),
      contentHorizontalPadding: isCompact ? 13 : 17,
    );
  }

  final bool isCompact;
  final Alignment alignment;
  final double width;
  final double maxHeight;
  final EdgeInsets outerPadding;
  final double contentHorizontalPadding;
}
