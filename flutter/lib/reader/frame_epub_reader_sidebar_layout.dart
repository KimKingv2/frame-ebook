import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Responsive geometry of the legacy Reading Room's compact left drawer.
class FrameEpubReaderSidebarLayout {
  const FrameEpubReaderSidebarLayout({
    required this.width,
    required this.topInset,
    required this.bottomInset,
  });

  factory FrameEpubReaderSidebarLayout.fromViewport(
    Size viewport, {
    bool fullscreen = false,
    EdgeInsets safeArea = EdgeInsets.zero,
  }) {
    final width = math.min(
      math.min(390.0, viewport.width * .91),
      math.max(0, viewport.width - 18),
    ).toDouble();
    return FrameEpubReaderSidebarLayout(
      width: width,
      topInset: safeArea.top + (fullscreen ? 6 : 8),
      bottomInset: safeArea.bottom + (fullscreen ? 6 : 8),
    );
  }

  final double width;
  final double topInset;
  final double bottomInset;
}
