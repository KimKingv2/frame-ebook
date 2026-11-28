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

  group('Reader quick-action geometry', () {
    test('uses 48px circular actions on desktop', () {
      expect(frameEpubReaderQuickActionWidth(1440), 48);
      expect(frameEpubReaderQuickActionWidth(821), 48);
      expect(frameEpubReaderQuickActionHeight(1440), 48);
      expect(frameEpubReaderQuickActionHeight(821), 48);
      expect(frameEpubReaderQuickActionGap(1440), 2);
      expect(frameEpubReaderQuickActionsWidth(1440), 198);
    });

    test('switches to 44px edge-to-edge actions at the 820px breakpoint', () {
      expect(frameEpubReaderQuickActionWidth(820), 44);
      expect(frameEpubReaderQuickActionWidth(560), 44);
      expect(frameEpubReaderQuickActionWidth(390), 44);
      expect(frameEpubReaderQuickActionHeight(820), 44);
      expect(frameEpubReaderQuickActionHeight(560), 44);
      expect(frameEpubReaderQuickActionHeight(390), 44);
      expect(frameEpubReaderQuickActionGap(820), 0);
      expect(frameEpubReaderQuickActionGap(390), 0);
      expect(frameEpubReaderQuickActionsWidth(820), 176);
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
