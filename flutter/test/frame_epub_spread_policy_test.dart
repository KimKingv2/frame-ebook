import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_spread_policy.dart';

void main() {
  group('FrameEpubSpreadPolicy', () {
    test('never uses synthetic spreads when rendition spread is none', () {
      expect(
        FrameEpubSpreadPolicy.allowsSyntheticSpread(
          renditionSpread: 'none',
          isLandscape: true,
        ),
        isFalse,
      );
      expect(
        FrameEpubSpreadPolicy.allowsSyntheticSpread(
          renditionSpread: 'none',
          isLandscape: false,
        ),
        isFalse,
      );
    });

    test('restricts landscape spreads to landscape orientation', () {
      expect(
        FrameEpubSpreadPolicy.allowsSyntheticSpread(
          renditionSpread: 'landscape',
          isLandscape: true,
        ),
        isTrue,
      );
      expect(
        FrameEpubSpreadPolicy.allowsSyntheticSpread(
          renditionSpread: 'landscape',
          isLandscape: false,
        ),
        isFalse,
      );
    });

    test('allows both spreads in either orientation', () {
      for (final isLandscape in [true, false]) {
        expect(
          FrameEpubSpreadPolicy.allowsSyntheticSpread(
            renditionSpread: 'both',
            isLandscape: isLandscape,
          ),
          isTrue,
        );
      }
    });

    test('treats deprecated portrait as both', () {
      for (final isLandscape in [true, false]) {
        expect(
          FrameEpubSpreadPolicy.allowsSyntheticSpread(
            renditionSpread: 'portrait',
            isLandscape: isLandscape,
          ),
          isTrue,
        );
      }
    });

    test('defaults missing, auto and unknown values to automatic spreading', () {
      for (final value in <String?>[null, '', 'auto', 'future-value']) {
        for (final isLandscape in [true, false]) {
          expect(
            FrameEpubSpreadPolicy.allowsSyntheticSpread(
              renditionSpread: value,
              isLandscape: isLandscape,
            ),
            isTrue,
            reason: 'Unexpected result for spread=$value',
          );
        }
      }
    });

    test('normalizes whitespace and case', () {
      expect(
        FrameEpubSpreadPolicy.allowsSyntheticSpread(
          renditionSpread: ' LANDSCAPE ',
          isLandscape: false,
        ),
        isFalse,
      );
    });
  });
}
