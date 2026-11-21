import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/reader/frame_epub_parser.dart';
import 'package:frame_ebook/reader/frame_zip_archive.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';

class _ZipItem {
  const _ZipItem(this.name, this.text);
  final String name;
  final String text;
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
      throw StateError('EPUB archive reads must use explicit byte ranges.');
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
        'Content-Range':
            'bytes $start-$end/' + bytes.length.toString(),
        'Accept-Ranges': 'bytes',
      },
      stream: Stream<List<int>>.value(body),
      onClose: () {},
      requestedRange: range,
    );
  }
}

FrameBook _book(int size) => FrameBook.fromJson({
      'id': 'epub-fixture-1',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/fixture.epub',
      'fileName': 'fixture.epub',
      'title': 'Fixture',
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
    final plain = utf8.encode(item.text);
    final crc = _crc32(plain);
    final localOffset = output.length;

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
    _write32(central, localOffset);
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
<?xml version="1.0" encoding="UTF-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const _epub3Package = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         version="3.0" unique-identifier="book-id">
  <metadata>
    <dc:identifier id="book-id">urn:uuid:frame-epub-fixture</dc:identifier>
    <dc:title>繁體中文漫畫</dc:title>
    <dc:creator>FRAME Studio</dc:creator>
    <dc:language>zh-TW</dc:language>
    <dc:publisher>FRAME Press</dc:publisher>
    <dc:date>2026-11-19</dc:date>
    <dc:subject>漫畫</dc:subject>
    <dc:description>固定版面 EPUB 測試書。</dc:description>
    <meta property="rendition:layout">pre-paginated</meta>
    <meta property="rendition:orientation">landscape</meta>
    <meta property="rendition:spread">both</meta>
    <meta property="rendition:flow">paginated</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter-one" href="Text/chapter01.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter-two" href="Text/chapter02.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="Images/cover%20art.png" media-type="image/png" properties="cover-image"/>
    <item id="style" href="Styles/book.css" media-type="text/css"/>
  </manifest>
  <spine page-progression-direction="rtl">
    <itemref idref="chapter-one"/>
    <itemref idref="chapter-two" linear="no"/>
  </spine>
</package>
''';

const _epub3Nav = '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>目錄</title></head>
  <body>
    <nav epub:type="toc">
      <h1>目錄</h1>
      <ol>
        <li>
          <a href="Text/chapter01.xhtml#page-1">第一章：起點</a>
          <ol><li><a href="Text/chapter02.xhtml">第二章：旅程</a></li></ol>
        </li>
        <li><a href="https://example.com/external">作者網站</a></li>
      </ol>
    </nav>
  </body>
</html>
''';

const _epub2Package = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         version="2.0" unique-identifier="uid">
  <metadata>
    <dc:identifier id="uid">urn:isbn:0000000000000</dc:identifier>
    <dc:title>EPUB 2 小說</dc:title>
    <dc:creator>作者甲</dc:creator>
    <dc:language>zh-Hant</dc:language>
    <meta name="cover" content="cover-image"/>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover-image" href="Images/cover.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter"/>
  </spine>
</package>
''';

const _epub2Ncx = '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="navpoint-1" playOrder="1">
      <navLabel><text>第一章</text></navLabel>
      <content src="Text/chapter.xhtml#top"/>
      <navPoint id="navpoint-2" playOrder="2">
        <navLabel><text>第一節</text></navLabel>
        <content src="Text/chapter.xhtml#section-1"/>
      </navPoint>
    </navPoint>
  </navMap>
</ncx>
''';

List<_ZipItem> _epub3Items() => [
      const _ZipItem('mimetype', 'application/epub+zip'),
      const _ZipItem('META-INF/container.xml', _container),
      const _ZipItem('OPS/package.opf', _epub3Package),
      const _ZipItem('OPS/nav.xhtml', _epub3Nav),
      const _ZipItem('OPS/Text/chapter01.xhtml', '<html/>'),
      const _ZipItem('OPS/Text/chapter02.xhtml', '<html/>'),
      const _ZipItem('OPS/Images/cover art.png', 'image-bytes'),
      const _ZipItem('OPS/Styles/book.css', 'body { margin: 0; }'),
      _ZipItem(
        'OPS/Media/unopened-large-resource.bin',
        String.fromCharCodes(List<int>.filled(100000, 0x78)),
      ),
    ];

void main() {
  group('FrameEpubParser', () {
    test('parses EPUB 3 metadata, spine, cover and nested navigation', () async {
      final fixture = _zipFixture(_epub3Items());
      final source = _MemoryFrameFileSource(fixture);
      final archive = await FrameZipArchive.open(
        source: source,
        book: _book(fixture.length),
      );

      try {
        final epub = await const FrameEpubParser().parse(archive);

        expect(epub.version, '3.0');
        expect(epub.packagePath, 'OPS/package.opf');
        expect(epub.metadata.title, '繁體中文漫畫');
        expect(epub.metadata.author, 'FRAME Studio');
        expect(epub.metadata.language, 'zh-TW');
        expect(epub.metadata.publisher, 'FRAME Press');
        expect(epub.metadata.publicationDate, '2026-11-19');
        expect(epub.metadata.identifier, 'urn:uuid:frame-epub-fixture');
        expect(epub.metadata.subjects, ['漫畫']);
        expect(epub.metadata.description, '固定版面 EPUB 測試書。');

        expect(epub.isFixedLayout, isTrue);
        expect(epub.spread, 'both');
        expect(epub.orientation, 'landscape');
        expect(epub.flow, 'paginated');
        expect(
          epub.pageProgressionDirection,
          FrameEpubPageProgressionDirection.rightToLeft,
        );
        expect(
          epub.spine.map((item) => item.item.path).toList(),
          ['OPS/Text/chapter01.xhtml', 'OPS/Text/chapter02.xhtml'],
        );
        expect(epub.spine.first.linear, isTrue);
        expect(epub.spine.last.linear, isFalse);
        expect(epub.coverImage?.path, 'OPS/Images/cover art.png');
        expect(epub.navigationPath, 'OPS/nav.xhtml');

        expect(epub.toc, hasLength(2));
        expect(epub.toc.first.label, '第一章：起點');
        expect(epub.toc.first.path, 'OPS/Text/chapter01.xhtml');
        expect(epub.toc.first.fragment, 'page-1');
        expect(epub.toc.first.children.single.label, '第二章：旅程');
        expect(epub.toc[1].isExternal, isTrue);
        expect(epub.warnings, isEmpty);

        expect(
          source.requests.any((range) => range.length == fixture.length),
          isFalse,
          reason: 'Parsing must not download the complete EPUB archive.',
        );
      } finally {
        await archive.close();
      }
    });

    test('parses EPUB 2 NCX and legacy cover metadata', () async {
      final fixture = _zipFixture([
        const _ZipItem('mimetype', 'application/epub+zip'),
        const _ZipItem(
          'META-INF/container.xml',
          '''
          <container>
            <rootfiles>
              <rootfile full-path="OEBPS/book.opf"
                        media-type="application/oebps-package+xml"/>
            </rootfiles>
          </container>
          ''',
        ),
        const _ZipItem('OEBPS/book.opf', _epub2Package),
        const _ZipItem('OEBPS/toc.ncx', _epub2Ncx),
        const _ZipItem('OEBPS/Text/chapter.xhtml', '<html/>'),
        const _ZipItem('OEBPS/Images/cover.jpg', 'cover'),
      ]);
      final archive = await FrameZipArchive.open(
        source: _MemoryFrameFileSource(fixture),
        book: _book(fixture.length),
      );

      try {
        final epub = await const FrameEpubParser().parse(archive);
        expect(epub.version, '2.0');
        expect(epub.metadata.title, 'EPUB 2 小說');
        expect(epub.metadata.identifier, 'urn:isbn:0000000000000');
        expect(epub.layout, FrameEpubLayout.reflowable);
        expect(epub.coverImage?.id, 'cover-image');
        expect(epub.navigationPath, 'OEBPS/toc.ncx');
        expect(epub.toc.single.label, '第一章');
        expect(epub.toc.single.path, 'OEBPS/Text/chapter.xhtml');
        expect(epub.toc.single.fragment, 'top');
        expect(epub.toc.single.children.single.label, '第一節');
        expect(epub.toc.single.children.single.fragment, 'section-1');
      } finally {
        await archive.close();
      }
    });

    test('creates usable chapter navigation when the EPUB has no TOC', () async {
      final packageWithoutNavigation = _epub3Package.replaceAll(
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
        '',
      );
      final fixture = _zipFixture([
        const _ZipItem('mimetype', 'application/epub+zip'),
        const _ZipItem('META-INF/container.xml', _container),
        _ZipItem('OPS/package.opf', packageWithoutNavigation),
        const _ZipItem('OPS/Text/chapter01.xhtml', '<html/>'),
        const _ZipItem('OPS/Text/chapter02.xhtml', '<html/>'),
        const _ZipItem('OPS/Images/cover art.png', 'image-bytes'),
      ]);
      final archive = await FrameZipArchive.open(
        source: _MemoryFrameFileSource(fixture),
        book: _book(fixture.length),
      );

      try {
        final epub = await const FrameEpubParser().parse(archive);
        expect(epub.toc, hasLength(2));
        expect(epub.toc.first.label, '第1章');
        expect(epub.toc.first.path, 'OPS/Text/chapter01.xhtml');
        expect(epub.toc.last.label, '第2章');
        expect(epub.toc.last.path, 'OPS/Text/chapter02.xhtml');
      } finally {
        await archive.close();
      }
    });

    test('accepts a nested EPUB 3 nav list when toc type is omitted',
        () async {
      const navigation = '''
        <html xmlns="http://www.w3.org/1999/xhtml">
          <body><nav id="toc"><div><ol>
            <li><a href="Text/chapter01.xhtml">Chapter One</a></li>
          </ol></div></nav></body>
        </html>
      ''';
      final packageWithNav = _epub3Package;
      final fixture = _zipFixture([
        const _ZipItem('mimetype', 'application/epub+zip'),
        const _ZipItem('META-INF/container.xml', _container),
        _ZipItem('OPS/package.opf', packageWithNav),
        const _ZipItem('OPS/nav.xhtml', navigation),
        const _ZipItem('OPS/Text/chapter01.xhtml', '<html/>'),
        const _ZipItem('OPS/Text/chapter02.xhtml', '<html/>'),
        const _ZipItem('OPS/Images/cover art.png', 'image-bytes'),
      ]);
      final archive = await FrameZipArchive.open(
        source: _MemoryFrameFileSource(fixture),
        book: _book(fixture.length),
      );

      try {
        final epub = await const FrameEpubParser().parse(archive);
        expect(epub.toc.first.label, 'Chapter One');
        expect(epub.toc.first.path, 'OPS/Text/chapter01.xhtml');
      } finally {
        await archive.close();
      }
    });

    test('rejects malformed mimetype', () async {
      final fixture = _zipFixture([
        const _ZipItem('mimetype', 'application/zip'),
        const _ZipItem('META-INF/container.xml', _container),
      ]);
      final archive = await FrameZipArchive.open(
        source: _MemoryFrameFileSource(fixture),
        book: _book(fixture.length),
      );

      try {
        await expectLater(
          const FrameEpubParser().parse(archive),
          throwsA(isA<FrameEpubParserException>()),
        );
      } finally {
        await archive.close();
      }
    });
  });

  group('EPUB resource URI resolution', () {
    test('resolves relative paths, fragments and encoded filenames', () {
      final result = FrameEpubParser.resolveHref(
        'Images/cover%20art.png#front',
        baseFilePath: 'OPS/nav.xhtml',
      );
      expect(result.path, 'OPS/Images/cover art.png');
      expect(result.fragment, 'front');
      expect(result.isInternal, isTrue);
    });

    test('resolves fragment-only links to the current XHTML document', () {
      final result = FrameEpubParser.resolveHref(
        '#chapter-start',
        baseFilePath: 'OPS/Text/chapter.xhtml',
      );
      expect(result.path, 'OPS/Text/chapter.xhtml');
      expect(result.fragment, 'chapter-start');
    });

    test('marks external links without attempting to fetch them', () {
      final result = FrameEpubParser.resolveHref(
        'https://example.com/book',
        baseFilePath: 'OPS/nav.xhtml',
      );
      expect(result.isExternal, isTrue);
      expect(result.path, isNull);
      expect(result.originalHref, 'https://example.com/book');
    });

    test('rejects paths that escape the archive root', () {
      expect(
        () => FrameEpubParser.resolveHref(
          '../../outside.xhtml',
          baseFilePath: 'OPS/nav.xhtml',
        ),
        throwsA(isA<FrameEpubParserException>()),
      );
    });

    test('rejects encoded path separators', () {
      expect(
        () => FrameEpubParser.resolveHref(
          'Text%2F..%2Foutside.xhtml',
          baseFilePath: 'OPS/nav.xhtml',
        ),
        throwsA(isA<FrameEpubParserException>()),
      );
    });
  });
}
