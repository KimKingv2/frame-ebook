import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_reader_overlay_layout.dart';

void main() {
  group('FrameEpubAppearancePanelLayout', () {
    test('uses the final legacy desktop full-height right drawer', () {
      final layout =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(1440, 900));

      expect(layout.isCompact, isFalse);
      expect(layout.alignment, Alignment.centerRight);
      expect(layout.width, 440);
      expect(layout.height, 884);
      expect(layout.outerPadding.top, 8);
      expect(layout.outerPadding.right, 0);
      expect(layout.outerPadding.bottom, 8);
      expect(layout.contentHorizontalPadding, 18);
    });

    test('uses the final legacy compact right drawer geometry', () {
      final layout =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(390, 844));

      expect(layout.isCompact, isTrue);
      expect(layout.alignment, Alignment.centerRight);
      expect(layout.width, closeTo(354.9, .001));
      expect(layout.height, 828);
      expect(layout.outerPadding.top, 8);
      expect(layout.outerPadding.right, 0);
      expect(layout.outerPadding.bottom, 8);
      expect(layout.contentHorizontalPadding, 15);
    });

    test('uses the 820px compact drawer breakpoint exactly', () {
      final compact =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(820, 900));
      final desktop =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(821, 900));

      expect(compact.isCompact, isTrue);
      expect(compact.width, 420);
      expect(compact.contentHorizontalPadding, 15);
      expect(desktop.isCompact, isFalse);
      expect(desktop.width, 440);
      expect(desktop.contentHorizontalPadding, 18);
    });

    test('uses desktop edge-to-edge geometry in fullscreen', () {
      final layout = FrameEpubAppearancePanelLayout.fromViewport(
        const Size(1440, 900),
        fullscreen: true,
      );

      expect(layout.alignment, Alignment.centerRight);
      expect(layout.width, 440);
      expect(layout.height, 900);
      expect(layout.outerPadding.top, 0);
      expect(layout.outerPadding.bottom, 0);
    });

    test('ignores desktop safe-area insets in fullscreen', () {
      final layout = FrameEpubAppearancePanelLayout.fromViewport(
        const Size(1440, 900),
        fullscreen: true,
        safeArea: const EdgeInsets.only(top: 24, bottom: 20),
      );

      expect(layout.outerPadding.top, 0);
      expect(layout.outerPadding.bottom, 0);
      expect(layout.height, 900);
    });

    test('keeps compact fullscreen drawer clear of safe areas', () {
      final layout = FrameEpubAppearancePanelLayout.fromViewport(
        const Size(390, 844),
        fullscreen: true,
      );

      expect(layout.outerPadding.top, 6);
      expect(layout.outerPadding.bottom, 6);
      expect(layout.height, 832);
    });

    test('includes phone safe-area insets in normal and fullscreen modes', () {
      const safeArea = EdgeInsets.only(top: 47, bottom: 34);
      final normal = FrameEpubAppearancePanelLayout.fromViewport(
        const Size(390, 844),
        safeArea: safeArea,
      );
      final fullscreen = FrameEpubAppearancePanelLayout.fromViewport(
        const Size(390, 844),
        fullscreen: true,
        safeArea: safeArea,
      );

      expect(normal.outerPadding.top, 55);
      expect(normal.outerPadding.bottom, 42);
      expect(normal.height, 747);
      expect(fullscreen.outerPadding.top, 53);
      expect(fullscreen.outerPadding.bottom, 40);
      expect(fullscreen.height, 751);
    });

    test('caps the drawer to narrow viewports without overflow', () {
      final layout =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(320, 568));

      expect(layout.isCompact, isTrue);
      expect(layout.width, closeTo(291.2, .001));
      expect(layout.height, 552);
    });
  });
}
