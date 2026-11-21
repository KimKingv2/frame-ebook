import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_appearance_preferences.dart';

void main() {
  group('FrameEpubAppearancePreferences', () {
    test('uses Legacy line height ahead of the preview duplicate', () {
      expect(
        FrameEpubAppearancePreferences.lineHeight({
          'lineHeight': '1.45',
          'frameFlutterLineHeight': 2.4,
        }),
        1.45,
      );
    });

    test('normalizes line height to the closest Legacy option', () {
      expect(
        FrameEpubAppearancePreferences.lineHeight({'lineHeight': '1.91'}),
        1.85,
      );
      expect(
        FrameEpubAppearancePreferences.lineHeight({'lineHeight': 'invalid'}),
        1.65,
      );
      expect(
        FrameEpubAppearancePreferences.lineHeight(const {}),
        1.65,
      );
    });

    test('uses Legacy theme ahead of the preview duplicate', () {
      expect(
        FrameEpubAppearancePreferences.theme({
          'theme': 'paper',
          'frameFlutterTheme': 'dark',
        }),
        'light',
      );
      expect(
        FrameEpubAppearancePreferences.theme({'theme': 'night'}),
        'dark',
      );
    });

    test('keeps reading mode separate from page layout preference', () {
      const appearance = <String, dynamic>{
        'readingMode': 'scrolled',
        'pageLayout': '2',
        'frameFlutterLayoutMode': 'paginated',
      };

      expect(
        FrameEpubAppearancePreferences.readingMode(appearance),
        'scrolled',
      );
      expect(
        FrameEpubAppearancePreferences.pageLayout(appearance),
        '2',
      );
      expect(
        FrameEpubAppearancePreferences.layoutMode(appearance),
        'continuous',
      );
    });

    test('restores the Legacy single- or double-page preference', () {
      expect(
        FrameEpubAppearancePreferences.layoutMode({
          'readingMode': 'paginated',
          'pageLayout': '2',
        }),
        'doublePage',
      );
      expect(
        FrameEpubAppearancePreferences.layoutMode({
          'readingMode': 'paginated',
          'pageLayout': '1',
        }),
        'paginated',
      );
    });

    test('uses the original Legacy defaults when no appearance is saved', () {
      const appearance = <String, dynamic>{};
      expect(
        FrameEpubAppearancePreferences.readingMode(appearance),
        'paginated',
      );
      expect(
        FrameEpubAppearancePreferences.pageLayout(appearance),
        '2',
      );
      expect(
        FrameEpubAppearancePreferences.layoutMode(appearance),
        'doublePage',
      );
      expect(FrameEpubAppearancePreferences.theme(appearance), 'light');
    });

    test('supports earlier preview-only values as a fallback', () {
      expect(
        FrameEpubAppearancePreferences.theme({
          'frameFlutterTheme': 'sepia',
        }),
        'sepia',
      );
      expect(
        FrameEpubAppearancePreferences.lineHeight({
          'frameFlutterLineHeight': 1.8,
        }),
        1.85,
      );
      expect(
        FrameEpubAppearancePreferences.layoutMode({
          'frameFlutterLayoutMode': 'doublePage',
        }),
        'doublePage',
      );
    });
  });
}
