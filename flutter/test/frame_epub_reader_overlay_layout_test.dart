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

    test('uses edge-to-edge geometry in fullscreen', () {
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

    test('caps the drawer to narrow viewports without overflow', () {
      final layout =
          FrameEpubAppearancePanelLayout.fromViewport(const Size(320, 568));

      expect(layout.isCompact, isTrue);
      expect(layout.width, closeTo(291.2, .001));
      expect(layout.height, 552);
    });
  });
}
