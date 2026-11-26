import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_fonts.dart';

void main() {
  group('EPUB embedded font CSS parsing', () {
    test('parses font-face declarations and preserves stylesheet base path', () {
      const css = '''
        /* @font-face { font-family: "fake"; src: url(fake.ttf); } */
        .chapter::after { content: "@font-face { not a font rule }"; }
        @font-face {
          font-family: "Book Serif";
          font-style: italic;
          font-weight: 700;
          src: local("Installed Font"),
               url("../Fonts/book.woff2") format("woff2"),
               url('../Fonts/book-bold.otf') format('opentype');
        }
        @font-face {
          font-family: ChapterSans;
          src: url(../Fonts/chapter.ttf) format(truetype);
        }
      ''';

      final faces = FrameEpubEmbeddedFontLoader.parseFontFaces(
        css,
        stylesheetPath: 'OPS/Styles/main.css',
      );

      expect(faces, hasLength(2));
      expect(faces.first.family, 'Book Serif');
      expect(faces.first.stylesheetPath, 'OPS/Styles/main.css');
      expect(faces.first.weight, '700');
      expect(faces.first.style, 'italic');
      expect(faces.first.sources, [
        '../Fonts/book.woff2',
        '../Fonts/book-bold.otf',
      ]);
      expect(faces.last.family, 'ChapterSans');
      expect(faces.last.sources, ['../Fonts/chapter.ttf']);
    });

    test('selects exact and nearest embedded font faces by CSS weight/style', () {
      String key(String weight, String style) =>
          FrameEpubEmbeddedFontLoader.fontFaceAliasKey(
            'Book Serif',
            weight,
            style,
          );
      final aliases = <String, String>{
        key('400', 'normal'): 'regular',
        key('700', 'normal'): 'bold',
        key('400', 'italic'): 'italic',
      };

      expect(
        FrameEpubFontLoadResult.resolveAlias(
          aliases,
          family: 'book serif',
          weight: '700',
        ),
        'bold',
      );
      expect(
        FrameEpubFontLoadResult.resolveAlias(
          aliases,
          family: 'Book Serif',
          weight: '500',
        ),
        'regular',
        reason: 'CSS 400–500 matching searches lower weights before weights above 500.',
      );
      expect(
        FrameEpubFontLoadResult.resolveAlias(
          aliases,
          family: 'Book Serif',
          weight: '600',
        ),
        'bold',
        reason: 'CSS weights above 500 search upward before lower weights.',
      );
      expect(
        FrameEpubFontLoadResult.resolveAlias(
          aliases,
          family: 'Book Serif',
          weight: '700',
          style: 'italic',
        ),
        'italic',
        reason: 'A matching italic face takes priority over a closer normal face.',
      );
      expect(
        FrameEpubFontLoadResult.resolveAlias(
          aliases,
          family: 'Unknown Family',
        ),
        isNull,
      );
    });

    test('ignores incomplete and generic-family declarations', () {
      final faces = FrameEpubEmbeddedFontLoader.parseFontFaces('''
        @font-face { font-family: serif; src: url(book.ttf); }
        @font-face { font-family: "Missing Source"; }
        @font-face { font-family: "Broken"; src: url(book.ttf);
      ''');

      expect(faces, hasLength(1));
      expect(faces.single.family, 'serif');
    });
  });

  test('normalizes static CSS weights and rejects variable font ranges', () {
    expect(FrameEpubEmbeddedFontLoader.normalizeFaceWeight('normal'), 400);
    expect(FrameEpubEmbeddedFontLoader.normalizeFaceWeight('bold'), 700);
    expect(FrameEpubEmbeddedFontLoader.normalizeFaceWeight('650'), 700);
    expect(FrameEpubEmbeddedFontLoader.normalizeFaceWeight('100 900'), isNull);
  });

  group('EPUB font obfuscation', () {
    test('reverses IDPF XOR for exactly the first 1040 bytes', () {
      const identifier = 'urn:uuid:1234-5678';
      final plain = Uint8List.fromList(
        List<int>.generate(1100, (index) => index % 251),
      );
      final key = sha1.convert(utf8.encode(identifier)).bytes;
      final obfuscated = Uint8List.fromList(plain);
      for (var index = 0; index < 1040; index++) {
        obfuscated[index] ^= key[index % key.length];
      }

      final restored =
          FrameEpubEmbeddedFontLoader.deobfuscateIdpf(obfuscated, identifier);

      expect(restored, plain);
      expect(restored.sublist(1040), plain.sublist(1040));
    });

    test('removes only XML whitespace before deriving the IDPF key', () {
      const identifier = ' urn:uuid:\t1234-\r\n5678 ';
      const normalized = 'urn:uuid:1234-5678';
      final plain = Uint8List.fromList(
        List<int>.generate(80, (index) => (index * 7) % 256),
      );
      final key = sha1.convert(utf8.encode(normalized)).bytes;
      final obfuscated = Uint8List.fromList(plain);
      for (var index = 0; index < obfuscated.length; index++) {
        obfuscated[index] ^= key[index % key.length];
      }

      expect(
        FrameEpubEmbeddedFontLoader.deobfuscateIdpf(obfuscated, identifier),
        plain,
      );
    });

    test('reverses Adobe UUID XOR for exactly the first 1024 bytes', () {
      const identifier = 'urn:uuid:00112233-4455-6677-8899-aabbccddeeff';
      final plain = Uint8List.fromList(
        List<int>.generate(1080, (index) => (index * 11) % 256),
      );
      const hex = '00112233445566778899aabbccddeeff';
      final key = <int>[
        for (var index = 0; index < hex.length; index += 2)
          int.parse(hex.substring(index, index + 2), radix: 16),
      ];
      final obfuscated = Uint8List.fromList(plain);
      for (var index = 0; index < 1024; index++) {
        obfuscated[index] ^= key[index % key.length];
      }

      final restored = FrameEpubEmbeddedFontLoader.deobfuscateAdobe(
        obfuscated,
        identifier,
      );

      expect(restored, plain);
      expect(restored.sublist(1024), plain.sublist(1024));
    });

    test('rejects missing IDPF identifiers and invalid Adobe UUIDs', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(
        () => FrameEpubEmbeddedFontLoader.deobfuscateIdpf(bytes, '  \t\n'),
        throwsFormatException,
      );
      expect(
        () => FrameEpubEmbeddedFontLoader.deobfuscateAdobe(bytes, 'not-a-uuid'),
        throwsFormatException,
      );
    });
  });

  group('EPUB font format validation', () {
    test('accepts TrueType and OpenType sfnt signatures only', () {
      Uint8List fontWith(List<int> signature) => Uint8List.fromList([
            ...signature,
            0, 0, 0, 0, 0, 0, 0, 0,
          ]);

      expect(
        FrameEpubEmbeddedFontLoader.hasSupportedSfntHeader(
          fontWith([0x00, 0x01, 0x00, 0x00]),
        ),
        isTrue,
      );
      expect(
        FrameEpubEmbeddedFontLoader.hasSupportedSfntHeader(
          fontWith([0x4F, 0x54, 0x54, 0x4F]),
        ),
        isTrue,
      );
      expect(
        FrameEpubEmbeddedFontLoader.hasSupportedSfntHeader(
          fontWith([0x77, 0x4F, 0x46, 0x32]),
        ),
        isFalse,
      );
      expect(
        FrameEpubEmbeddedFontLoader.hasSupportedSfntHeader(
          Uint8List.fromList([0, 1, 0, 0]),
        ),
        isFalse,
      );
    });
  });
}
