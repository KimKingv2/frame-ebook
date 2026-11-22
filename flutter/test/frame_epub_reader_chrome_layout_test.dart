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

  group('Legacy reader quick-action geometry', () {
    test('uses 48px desktop and 44px compact circular targets', () {
      expect(frameEpubReaderQuickActionSize(1440), 48);
      expect(frameEpubReaderQuickActionSize(821), 48);
      expect(frameEpubReaderQuickActionSize(820), 44);
      expect(frameEpubReaderQuickActionSize(390), 44);
    });

    test('restores the exact desktop and compact row gaps', () {
      expect(frameEpubReaderQuickActionGap(1440), 2);
      expect(frameEpubReaderQuickActionGap(821), 2);
      expect(frameEpubReaderQuickActionGap(820), 0);
      expect(frameEpubReaderQuickActionGap(390), 0);
    });

    test('restores progress-label spacing and four-button group widths', () {
      expect(frameEpubReaderQuickActionStackGap(1440), 10);
      expect(frameEpubReaderQuickActionStackGap(820), 6);
      expect(frameEpubReaderQuickActionsWidth(1440), 198);
      expect(frameEpubReaderQuickActionsWidth(390), 176);
    });
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
