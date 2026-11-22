import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/reader/frame_epub_parser.dart';
import 'package:frame_ebook/reader/frame_epub_resource_loader.dart';
import 'package:frame_ebook/reader/frame_zip_archive.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';

class _ZipItem {
  const _ZipItem(this.name, this.bytes);
  final String name;
  final List<int> bytes;
}

class _RangeRecord {
  const _RangeRecord(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;
}

class _MemoryFrameFileSource implements FrameFileSource {
  _MemoryFrameFileSource(this.bytes);
  final Uint8List bytes;
  final List<_RangeRecord> requests = [];

  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    final range = request.range;
    if (range == null) {
      throw StateError('EPUB resource reads must use explicit byte ranges.');
    }
    final suffix = range.suffixLength;
    final start = suffix == null ? range.start! : bytes.length - suffix;
    final requestedEnd = range.end ?? bytes.length - 1;
    final end = requestedEnd < bytes.length ? requestedEnd : bytes.length - 1;
    if (start < 0 || end < start) throw RangeError('Invalid fixture range.');
    requests.add(_RangeRecord(start, end));
    final body = Uint8List.sublistView(bytes, start, end + 1);
    return FrameFileResponse(
      statusCode: 206,
      headers: {
        'Content-Type': 'application/epub+zip',
        'Content-Length': body.length.toString(),
        'Content-Range': 'bytes $start-$end/' + bytes.length.toString(),
        'Accept-Ranges': 'bytes',
      },
      stream: Stream<List<int>>.value(body),
      onClose: () {},
      requestedRange: range,
    );
  }
}

FrameBook _book(int size) => FrameBook.fromJson({
      'id': 'epub-resource-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/resource-test.epub',
      'fileName': 'resource-test.epub',
      'title': 'Resource test',
      'author': '',
      'format': 'EPUB',
      'shelf': 'books',
      'size': size,
    });

Uint8List _zipFixture(List<_ZipItem> items) {
  final output = <int>[];
  final central = <int>[];
  for (final item in items) {
    final name = utf8.encode(item.name);
    final plain = Uint8List.fromList(item.bytes);
    final crc = _crc32(plain);
    final offset = output.length;

    _write32(output, 0x04034b50);
    _write16(output, 20);
    _write16(output, 0x0800);
    _write16(output, 0);
    _write16(output, 0);
    _write16(output, 0);
    _write32(output, crc);
    _write32(output, plain.length);
    _write32(output, plain.length);
    _write16(output, name.length);
    _write16(output, 0);
    output
      ..addAll(name)
      ..addAll(plain);

    _write32(central, 0x02014b50);
    _write16(central, 0x0314);
    _write16(central, 20);
    _write16(central, 0x0800);
    _write16(central, 0);
    _write16(central, 0);
    _write16(central, 0);
    _write32(central, crc);
    _write32(central, plain.length);
    _write32(central, plain.length);
    _write16(central, name.length);
    _write16(central, 0);
    _write16(central, 0);
    _write16(central, 0);
    _write16(central, 0);
    _write32(central, 0);
    _write32(central, offset);
    central.addAll(name);
  }

  final centralOffset = output.length;
  output.addAll(central);
  _write32(output, 0x06054b50);
  _write16(output, 0);
  _write16(output, 0);
  _write16(output, items.length);
  _write16(output, items.length);
  _write32(output, central.length);
  _write32(output, centralOffset);
  _write16(output, 0);
  return Uint8List.fromList(output);
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

void _write16(List<int> output, int value) {
  output
    ..add(value & 0xff)
    ..add((value >> 8) & 0xff);
}

void _write32(List<int> output, int value) {
  output
    ..add(value & 0xff)
    ..add((value >> 8) & 0xff)
    ..add((value >> 16) & 0xff)
    ..add((value >> 24) & 0xff);
}

const _container = '''
<container>
  <rootfiles>
    <rootfile full-path="OPS/book.opf"
              media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const _package = '''
<package xmlns="http://www.idpf.org/2007/opf"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         version="3.0" unique-identifier="uid">
  <metadata>
    <dc:identifier id="uid">urn:uuid:resource-loader</dc:identifier>
    <dc:title>Resource loader</dc:title>
    <dc:language>zh-TW</dc:language>
  </metadata>
  <manifest>
    <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="main-css" href="Styles/main.css" media-type="text/css"/>
    <item id="theme-css" href="Styles/theme.css" media-type="text/css"/>
    <item id="print-css" href="Styles/print.css" media-type="text/css"/>
    <item id="page" href="Images/page one.png" media-type="image/png"/>
    <item id="bg" href="Images/bg.png" media-type="image/png"/>
    <item id="body" href="Images/body.png" media-type="image/png"/>
    <item id="svg" href="Images/inline.svg" media-type="image/svg+xml"/>
    <item id="font" href="Fonts/font.woff2" media-type="font/woff2"/>
  </manifest>
  <spine><itemref idref="chapter"/></spine>
</package>
''';

const _chapter = '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:svg="http://www.w3.org/2000/svg"
      xmlns:xlink="http://www.w3.org/1999/xlink">
  <head>
    <link rel="stylesheet" href="../Styles/main.css"/>
    <title>章節測試</title>
  </head>
  <body>
    <img src="../Images/page%20one.png" alt="page"/>
    <a href="#inside">章內連結</a>
    <a href="chapter.xhtml#next">下一節</a>
    <a href="https://example.com">外部連結</a>
    <svg:svg><svg:image xlink:href="../Images/inline.svg"/></svg:svg>
    <div style="background-image: url('../Images/bg.png')"></div>
    <img src="../Images/missing.png"/>
    <style>
      @font-face { src: url('../Fonts/font.woff2') format('woff2'); }
      .page { background: url('../Images/body.png'); }
    </style>
  </body>
</html>
''';

const _mainCss = '''
@import url("theme.css") screen;
@import 'print.css';
@font-face { src: url(../Fonts/font.woff2) format('woff2'); }
.page { background-image: url("../Images/bg.png"); }
.icon { background-image: url(../Images/page\\20 one.png); }
/* url(comment.png) must not be read */
.fake { content: "url(not-a-resource.png)"; }
.remote { background: url(https://example.com/image.png); }
.embedded { background: url(data:image/png;base64,AA==); }
''';

const _themeCss = '''
@import "main.css";
h1 { background: url("../Images/body.png"); }
''';

List<_ZipItem> _items() => [
      _ZipItem('mimetype', utf8.encode('application/epub+zip')),
      _ZipItem('META-INF/container.xml', utf8.encode(_container)),
      _ZipItem('OPS/book.opf', utf8.encode(_package)),
      _ZipItem('OPS/Text/chapter.xhtml', utf8.encode(_chapter)),
      _ZipItem('OPS/Styles/main.css', utf8.encode(_mainCss)),
      _ZipItem('OPS/Styles/theme.css', utf8.encode(_themeCss)),
      _ZipItem('OPS/Styles/print.css', utf8.encode('body { color: black; }')),
      _ZipItem('OPS/Images/page one.png', [0x89, 0x50, 0x4e, 0x47]),
      _ZipItem('OPS/Images/bg.png', [1, 2, 3]),
      _ZipItem('OPS/Images/body.png', [4, 5, 6]),
      _ZipItem('OPS/Images/inline.svg', utf8.encode('<svg/>')),
      _ZipItem('OPS/Fonts/font.woff2', [7, 8, 9]),
      _ZipItem(
        'OPS/Media/unopened-large-resource.bin',
        List<int>.filled(100000, 0x78),
      ),
    ];

Future<(FrameZipArchive, FrameEpubResourceLoader, _MemoryFrameFileSource)>
    _openFixture() async {
  final fixture = _zipFixture(_items());
  final source = _MemoryFrameFileSource(fixture);
  final archive = await FrameZipArchive.open(
    source: source,
    book: _book(fixture.length),
  );
  final epub = await const FrameEpubParser().parse(archive);
  return (
    archive,
    FrameEpubResourceLoader(archive: archive, book: epub),
    source,
  );
}

void main() {
  group('FrameEpubResourceLoader', () {
    test('loads a chapter and resolves relative XHTML resources', () async {
      final (archive, loader, source) = await _openFixture();
      try {
        final chapter = await loader.loadChapter(loader.book.spine.single);
        expect(chapter.document.rootElement.name.local, 'html');

        final image = chapter.references.firstWhere(
          (reference) =>
              reference.elementName == 'img' &&
              reference.reference.path == 'OPS/Images/page one.png',
        );
        expect(image.kind, FrameEpubResourceKind.image);
        expect(image.reference.resource?.mediaType, 'image/png');

        final stylesheet = chapter.stylesheets.single;
        expect(stylesheet.reference.path, 'OPS/Styles/main.css');

        final inlineSvg = chapter.references.firstWhere(
          (reference) => reference.reference.path == 'OPS/Images/inline.svg',
        );
        expect(inlineSvg.kind, FrameEpubResourceKind.svg);
        final svgResource = loader.resource('OPS/Images/inline.svg')!;
        expect(await loader.readText(svgResource), '<svg/>');

        final sameChapterLink = chapter.references.firstWhere(
          (reference) =>
              reference.elementName == 'a' &&
              reference.reference.fragment == 'inside',
        );
        expect(sameChapterLink.reference.path, 'OPS/Text/chapter.xhtml');
        expect(sameChapterLink.reference.resource?.kind,
            FrameEpubResourceKind.document);

        final externalLink = chapter.references.firstWhere(
          (reference) =>
              reference.elementName == 'a' &&
              reference.reference.isExternal,
        );
        expect(externalLink.reference.resource, isNull);

        expect(chapter.warnings, hasLength(1));
        expect(chapter.warnings.single, contains('missing.png'));

        final pngBytes = await loader.readBytes(image.reference.resource!);
        expect(pngBytes, [0x89, 0x50, 0x4e, 0x47]);
        expect(
          source.requests.any((range) => range.length == 100000),
          isFalse,
          reason: 'Chapter parsing must not read unrelated archive entries.',
        );
      } finally {
        await archive.close();
      }
    });

    test('caches parsed chapters in bounded memory and reuses range reads',
        () async {
      final (archive, loader, source) = await _openFixture();
      try {
        final first = await loader.loadChapter(loader.book.spine.single);
        final requestCount = source.requests.length;
        final cached = await loader.loadChapter(loader.book.spine.single);

        expect(identical(cached, first), isTrue);
        expect(source.requests, hasLength(requestCount));

        loader.clearChapterCache();
        final reloaded = await loader.loadChapter(loader.book.spine.single);
        expect(identical(reloaded, first), isFalse);
        expect(source.requests.length, greaterThan(requestCount));
      } finally {
        loader.dispose();
        await archive.close();
      }
    });

    test('preloads a small chapter for later navigation without duplicate reads',
        () async {
      final (archive, loader, source) = await _openFixture();
      try {
        await loader.preloadChapter(loader.book.spine.single);
        final requestCount = source.requests.length;
        final chapter = await loader.loadChapter(loader.book.spine.single);

        expect(chapter.document.rootElement.name.local, 'html');
        expect(source.requests, hasLength(requestCount));
      } finally {
        loader.dispose();
        await archive.close();
      }
    });

    test('resolves CSS imports, images and fonts with cycle protection',
        () async {
      final (archive, loader, _) = await _openFixture();
      try {
        final graph = await loader.loadStylesheetGraph('OPS/Styles/main.css');
        expect(
          graph.stylesheets.keys,
          containsAll([
            'OPS/Styles/main.css',
            'OPS/Styles/theme.css',
            'OPS/Styles/print.css',
          ]),
        );
        expect(graph.stylesheets, hasLength(3));

        final main = graph.stylesheets['OPS/Styles/main.css']!;
        expect(main.imports, hasLength(2));
        expect(
          main.imports.map((item) => item.reference.path),
          containsAll([
            'OPS/Styles/theme.css',
            'OPS/Styles/print.css',
          ]),
        );
        expect(
          main.urls.map((item) => item.reference.path),
          containsAll([
            'OPS/Fonts/font.woff2',
            'OPS/Images/bg.png',
            'OPS/Images/page one.png',
          ]),
        );
        expect(
          main.urls.any((item) => item.reference.isExternal),
          isTrue,
          reason: 'External and data URLs are identified, not fetched.',
        );
        expect(graph.warnings, isEmpty);
      } finally {
        await archive.close();
      }
    });

    test('enforces per-resource read bounds', () async {
      final (archive, loader, _) = await _openFixture();
      try {
        final image = loader.resource('OPS/Images/page one.png')!;
        await expectLater(
          loader.readBytes(image, maxBytes: 2),
          throwsA(isA<FrameZipArchiveException>()),
        );
      } finally {
        await archive.close();
      }
    });

    test('rejects resources from another EPUB loader', () async {
      final (archiveA, loaderA, _) = await _openFixture();
      final (archiveB, loaderB, _) = await _openFixture();
      try {
        final foreign = loaderA.resource('OPS/Images/bg.png')!;
        expect(
          () => loaderB.openRead(foreign),
          throwsA(isA<ArgumentError>()),
        );
      } finally {
        await archiveA.close();
        await archiveB.close();
      }
    });
  });

  group('EPUB CSS reference scanner', () {
    test('extracts imports and url functions outside comments and strings',
        () {
      final refs =
          FrameEpubResourceLoader.extractCssReferences(_mainCss);
      expect(refs, hasLength(7));
      expect(
        refs.where((item) => item.kind == FrameEpubCssReferenceKind.import)
            .map((item) => item.href),
        ['theme.css', 'print.css'],
      );
      expect(
        refs.where((item) => item.kind == FrameEpubCssReferenceKind.url)
            .map((item) => item.href),
        containsAll([
          '../Fonts/font.woff2',
          '../Images/bg.png',
          '../Images/page one.png',
          'https://example.com/image.png',
          'data:image/png;base64,AA==',
        ]),
      );
      expect(refs.map((item) => item.href), isNot(contains('comment.png')));
      expect(
        refs.map((item) => item.href),
        isNot(contains('not-a-resource.png')),
      );
    });

    test('honors CSS import depth and stylesheet-count bounds', () async {
      final (archive, loader, _) = await _openFixture();
      try {
        final graph = await loader.loadStylesheetGraph(
          'OPS/Styles/main.css',
          maxDepth: 0,
        );
        expect(graph.stylesheets, hasLength(1));
        expect(graph.warnings, isNotEmpty);
        expect(graph.warnings.first, contains('深度'));
      } finally {
        await archive.close();
      }
    });
  });
}
