import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Responsive geometry of the legacy Reading Room's compact left drawer.
class FrameEpubReaderSidebarLayout {
  const FrameEpubReaderSidebarLayout({
    required this.width,
    required this.verticalInset,
  });

  factory FrameEpubReaderSidebarLayout.fromViewport(
    Size viewport, {
    bool fullscreen = false,
  }) {
    final width = math.min(
      math.min(390.0, viewport.width * .91),
      math.max(0, viewport.width - 18),
    ).toDouble();
    return FrameEpubReaderSidebarLayout(
      width: width,
      verticalInset: fullscreen ? 6 : 8,
    );
  }

  final double width;
  final double verticalInset;
}
