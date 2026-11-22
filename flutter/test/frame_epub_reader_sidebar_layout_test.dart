import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:frame_ebook/reader/frame_epub_reader_sidebar_layout.dart';

void main() {
  group('FrameEpubReaderSidebarLayout', () {
    test('matches the 390px mobile drawer cap and 91vw sizing', () {
      final layout =
          FrameEpubReaderSidebarLayout.fromViewport(const Size(390, 844));

      expect(layout.width, closeTo(354.9, .001));
      expect(layout.topInset, 8);
      expect(layout.bottomInset, 8);
    });

    test('caps medium phones at the CSS max width', () {
      final layout =
          FrameEpubReaderSidebarLayout.fromViewport(const Size(820, 1180));

      expect(layout.width, 390);
      expect(layout.topInset, 8);
      expect(layout.bottomInset, 8);
    });

    test('avoids overflow on narrow viewports', () {
      final layout =
          FrameEpubReaderSidebarLayout.fromViewport(const Size(320, 568));

      expect(layout.width, closeTo(291.2, .001));
    });

    test('uses the tighter six pixel inset in fullscreen', () {
      final layout = FrameEpubReaderSidebarLayout.fromViewport(
        const Size(390, 844),
        fullscreen: true,
      );

      expect(layout.topInset, 6);
      expect(layout.bottomInset, 6);
    });

    test('includes phone safe-area insets', () {
      final layout = FrameEpubReaderSidebarLayout.fromViewport(
        const Size(390, 844),
        safeArea: const EdgeInsets.only(top: 47, bottom: 34),
      );

      expect(layout.topInset, 55);
      expect(layout.bottomInset, 42);
    });

    test('includes safe-area plus compact fullscreen padding', () {
      final layout = FrameEpubReaderSidebarLayout.fromViewport(
        const Size(390, 844),
        fullscreen: true,
        safeArea: const EdgeInsets.only(top: 47, bottom: 34),
      );

      expect(layout.topInset, 53);
      expect(layout.bottomInset, 40);
    });
  });
}
