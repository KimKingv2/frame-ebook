import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_reader_chrome_layout.dart';

void main() {
  test('uses the fixed quick-action dock through the legacy 820px breakpoint',
      () {
    expect(frameEpubUsesMobileQuickActions(390), isTrue);
    expect(frameEpubUsesMobileQuickActions(560), isTrue);
    expect(frameEpubUsesMobileQuickActions(720), isTrue);
    expect(frameEpubUsesMobileQuickActions(820), isTrue);
    expect(frameEpubUsesMobileQuickActions(821), isFalse);
    expect(frameEpubUsesMobileQuickActions(1440), isFalse);
  });

  group('FrameEpubReaderWorkspaceLayout', () {
    test('uses the legacy 250px sidebar and 16px gap on wide desktop', () {
      final layout = FrameEpubReaderWorkspaceLayout.fromViewport(
        viewportWidth: 1440,
      );
      expect(layout.sidebarWidth, 250);
      expect(layout.gap, 16);
    });

    test('uses the legacy compact desktop dimensions through 1050px', () {
      final layout = FrameEpubReaderWorkspaceLayout.fromViewport(
        viewportWidth: 1024,
      );
      expect(layout.sidebarWidth, 220);
      expect(layout.gap, 12);
    });

    test('uses the compact 220px column in fullscreen', () {
      final layout = FrameEpubReaderWorkspaceLayout.fromViewport(
        viewportWidth: 1440,
        fullscreen: true,
      );
      expect(layout.sidebarWidth, 220);
      expect(layout.gap, 12);
    });

    test('collapsing navigation gives the reading window the full width', () {
      final layout = FrameEpubReaderWorkspaceLayout.fromViewport(
        viewportWidth: 1440,
        sidebarVisible: false,
      );
      expect(layout.sidebarWidth, 0);
      expect(layout.gap, 0);
    });

    test('compact screens use the overlay drawer instead of a fixed column', () {
      final layout = FrameEpubReaderWorkspaceLayout.fromViewport(
        viewportWidth: 820,
      );
      expect(layout.sidebarWidth, 0);
      expect(layout.gap, 0);
    });
  });
}
