import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_cfi.dart';
import 'package:frame_ebook/reader/frame_epub_parser.dart';
import 'package:xml/xml.dart';

FrameEpubBook _book() {
  final first = FrameEpubManifestItem(
    id: 'chapter-one',
    href: 'Text/chapter-one.xhtml',
    mediaType: 'application/xhtml+xml',
    reference: const FrameEpubResourceReference(
      originalHref: 'Text/chapter-one.xhtml',
      path: 'OPS/Text/chapter-one.xhtml',
      fragment: '',
      query: '',
      isExternal: false,
    ),
    properties: const {},
    fallback: '',
  );
  final second = FrameEpubManifestItem(
    id: 'chapter-two',
    href: 'Text/chapter-two.xhtml',
    mediaType: 'application/xhtml+xml',
    reference: const FrameEpubResourceReference(
      originalHref: 'Text/chapter-two.xhtml',
      path: 'OPS/Text/chapter-two.xhtml',
      fragment: '',
      query: '',
      isExternal: false,
    ),
    properties: const {},
    fallback: '',
  );
  return FrameEpubBook(
    packagePath: 'OPS/book.opf',
    version: '3.0',
    uniqueIdentifierId: 'uid',
    metadata: const FrameEpubMetadata(
      title: 'CFI test',
      creators: [],
      language: 'en',
      publisher: '',
      publicationDate: '',
      identifier: 'urn:uuid:cfi-test',
      subjects: [],
      description: '',
    ),
    manifest: {'chapter-one': first, 'chapter-two': second},
    spine: [
      FrameEpubSpineItem(
        idref: 'chapter-one',
        item: first,
        linear: true,
        itemrefId: 'ref-one',
      ),
      FrameEpubSpineItem(
        idref: 'chapter-two',
        item: second,
        linear: true,
        itemrefId: 'ref-two',
      ),
    ],
    toc: const [],
    navigationPath: null,
    coverImage: null,
    layout: FrameEpubLayout.reflowable,
    pageProgressionDirection: FrameEpubPageProgressionDirection.defaultDirection,
    spread: 'auto',
    orientation: 'auto',
    flow: 'auto',
    warnings: const [],
  );
}

void main() {
  group('FrameEpubCfi', () {
    test('creates and resolves a text CFI with spine and XML ID assertions',
        () {
      final book = _book();
      final document = XmlDocument.parse(
        '<html><head/><body id="body"><p id="para">alpha'
        '<em id="emphasis">beta</em>gamma</p></body></html>',
      );
      final paragraph = document.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'p');
      final firstText = paragraph.children.whereType<XmlText>().first;

      final cfi = FrameEpubCfi.create(
        book: book,
        spineIndex: 0,
        textNode: firstText,
        offset: 2,
      );

      expect(
        cfi,
        startsWith('epubcfi(/6/2[ref-one]!/4[body]/2[para]/1:2'),
      );
      final location = FrameEpubCfi.resolve(
        book: book,
        document: document,
        cfi: cfi!,
      );
      expect(location, isNotNull);
      expect(location!.spineIndex, 0);
      expect(identical(location.node, firstText), isTrue);
      expect(location.offset, 2);
      expect(location.anchorElement?.name.local, 'p');
    });

    test('round trips a text node after an inline element', () {
      final book = _book();
      final document = XmlDocument.parse(
        '<html><head/><body id="body"><p id="para">alpha'
        '<em id="emphasis">beta</em>gamma</p></body></html>',
      );
      final paragraph = document.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'p');
      final gamma = paragraph.children.whereType<XmlText>().last;

      final cfi = FrameEpubCfi.create(
        book: book,
        spineIndex: 1,
        textNode: gamma,
        offset: 2,
      )!;
      expect(cfi, contains('/6/4[ref-two]!'));
      expect(cfi, contains('/3:2'));

      final location = FrameEpubCfi.resolve(
        book: book,
        document: document,
        cfi: cfi,
      );
      expect(location, isNotNull);
      expect(location!.spineIndex, 1);
      expect(identical(location.node, gamma), isTrue);
      expect(location.offset, 2);
    });

    test('accepts a legacy Foliate range CFI and restores its start', () {
      final book = _book();
      final document = XmlDocument.parse(
        '<html><head/><body id="body"><p id="para">alpha'
        '<em>beta</em>gamma</p></body></html>',
      );
      const rangeCfi =
          'epubcfi(/6/2[ref-one]!/4[body]/2[para],/1:2,/1:4)';

      final location = FrameEpubCfi.resolve(
        book: book,
        document: document,
        cfi: rangeCfi,
      );
      final firstText = document.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'p')
          .children
          .whereType<XmlText>()
          .first;
      expect(location, isNotNull);
      expect(location!.spineIndex, 0);
      expect(identical(location.node, firstText), isTrue);
      expect(location.offset, 2);
    });

    test('uses the itemref ID to recover a spine position before loading XHTML',
        () {
      final book = _book();
      expect(
        FrameEpubCfi.spineIndexFromCfi(
          book,
          'epubcfi(/6/4[ref-two]!/4/2/1:0)',
        ),
        1,
      );
      expect(
        FrameEpubCfi.spineIndexFromCfi(
          book,
          'epubcfi(/6/2[unknown-ref]!/4/2/1:0)',
        ),
        0,
      );
    });

    test('escapes reserved CFI characters in text assertions', () {
      final book = _book();
      final document = XmlDocument.parse(
        '<html><body><p id="para">A [bracket] and ^ caret.</p></body></html>',
      );
      final text = document.descendants.whereType<XmlText>().firstWhere(
            (node) => node.value.contains('bracket'),
          );
      final cfi = FrameEpubCfi.create(
        book: book,
        spineIndex: 0,
        textNode: text,
        offset: 5,
      )!;
      expect(cfi, contains('^['));
      expect(cfi, contains('^]'));
      expect(cfi, contains('^^'));
      final location = FrameEpubCfi.resolve(
        book: book,
        document: document,
        cfi: cfi,
      );
      expect(location, isNotNull);
      expect(location!.offset, 5);
    });
  });
}
