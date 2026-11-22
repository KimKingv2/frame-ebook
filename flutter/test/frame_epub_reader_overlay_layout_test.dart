import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_reader_overlay_layout.dart';

void main() {
  group('FrameEpubAppearancePanelLayout', () {
    test('uses the legacy desktop top-right geometry', () {
      final layout =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(1440, 900));

      expect(layout.isCompact, isFalse);
      expect(layout.alignment, Alignment.topRight);
      expect(layout.width, 470);
      expect(layout.maxHeight, 796);
      expect(layout.outerPadding.top, 82);
      expect(layout.outerPadding.right, 20);
      expect(layout.outerPadding.bottom, 0);
      expect(layout.contentHorizontalPadding, 17);
    });

    test('uses the legacy compact bottom-right geometry', () {
      final layout =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(390, 844));

      expect(layout.isCompact, isTrue);
      expect(layout.alignment, Alignment.bottomRight);
      expect(layout.width, 374);
      expect(layout.maxHeight, closeTo(708.96, .001));
      expect(layout.outerPadding.top, 8);
      expect(layout.outerPadding.right, 8);
      expect(layout.outerPadding.bottom, 8);
      expect(layout.contentHorizontalPadding, 13);
    });

    test('uses the centered app-shell offset on ultra-wide screens', () {
      final layout =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(2560, 1440));

      expect(layout.width, 470);
      expect(layout.maxHeight, 1336);
      expect(layout.outerPadding.top, 82);
      expect(layout.outerPadding.right, 550);
    });

    test('keeps the 560 px legacy breakpoint exact', () {
      final compact =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(560, 900));
      final desktop =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(561, 900));

      expect(compact.isCompact, isTrue);
      expect(compact.alignment, Alignment.bottomRight);
      expect(compact.width, 544);
      expect(desktop.isCompact, isFalse);
      expect(desktop.alignment, Alignment.topRight);
      expect(desktop.outerPadding.top, 82);
    });
  });
}
