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
    test('uses the 72px bookmark button at every breakpoint', () {
      expect(frameEpubReaderQuickActionWidth(1440, bookmark: true), 72);
      expect(frameEpubReaderQuickActionWidth(820, bookmark: true), 72);
      expect(frameEpubReaderQuickActionWidth(380, bookmark: true), 72);
    });

    test('restores 104px, 92px and 86px action widths', () {
      expect(frameEpubReaderQuickActionWidth(1440, bookmark: false), 104);
      expect(frameEpubReaderQuickActionWidth(821, bookmark: false), 104);
      expect(frameEpubReaderQuickActionWidth(820, bookmark: false), 92);
      expect(frameEpubReaderQuickActionWidth(390, bookmark: false), 92);
      expect(frameEpubReaderQuickActionWidth(380, bookmark: false), 86);
    });

    test('restores the legacy action heights', () {
      expect(frameEpubReaderQuickActionHeight(1440), 34);
      expect(frameEpubReaderQuickActionHeight(820), 33);
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
