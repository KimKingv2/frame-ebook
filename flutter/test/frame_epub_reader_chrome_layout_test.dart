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
}
