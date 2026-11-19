import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/library/frame_reader_repository.dart';
import 'package:frame_ebook/reader/frame_epub_chapter_view.dart';
import 'package:frame_ebook/reader/frame_epub_cfi.dart';
import 'package:frame_ebook/reader/frame_epub_footnote.dart';
import 'package:frame_ebook/reader/frame_epub_parser.dart';
import 'package:frame_ebook/reader/frame_epub_resource_loader.dart';
import 'package:frame_ebook/reader/frame_zip_archive.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xml/xml.dart';

class _ZipItem {
  const _ZipItem(this.name, this.bytes);
  final String name;
  final List<int> bytes;
}

class _MemoryFileSource implements FrameFileSource {
  _MemoryFileSource(this.bytes);
  final Uint8List bytes;

  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    final range = request.range;
    if (range == null) throw StateError('An explicit ZIP Range is required.');
    final start = range.suffixLength == null
        ? range.start!
        : bytes.length - range.suffixLength!;
    final requestedEnd = range.end ?? bytes.length - 1;
    final end = requestedEnd < bytes.length ? requestedEnd : bytes.length - 1;
    final body = Uint8List.sublistView(bytes, start, end + 1);
    return FrameFileResponse(
      statusCode: 206,
      headers: {
        'content-type': 'application/epub+zip',
        'content-length': body.length.toString(),
        'content-range': 'bytes $start-$end/' + bytes.length.toString(),
        'accept-ranges': 'bytes',
      },
      stream: Stream<List<int>>.value(body),
      onClose: () {},
      requestedRange: range,
    );
  }
}

Uint8List _fixture() {
  const container = '''
<container><rootfiles>
  <rootfile full-path="OPS/book.opf"
    media-type="application/oebps-package+xml"/>
</rootfiles></container>
''';
  const package = '''
<package xmlns="http://www.idpf.org/2007/opf"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         version="3.0" unique-identifier="uid">
  <metadata>
    <dc:identifier id="uid">urn:uuid:widget-test</dc:identifier>
    <dc:title>Widget test</dc:title>
    <dc:language>zh-TW</dc:language>
  </metadata>
  <manifest>
    <item id="chapter" href="Text/chapter.xhtml"
      media-type="application/xhtml+xml"/>
    <item id="notes" href="Text/notes.xhtml"
      media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="chapter"/></spine>
</package>
''';
  const chapter = '''
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Widget fixture</title></head>
  <body>
    <h1>閱讀畫面測試</h1>
    <p class="intro">這是一段 <strong>EPUB</strong> 文字。</p>
    <p><a href="chapter.xhtml#inside">章內連結</a></p>
    <p>句尾註腳 <a id="note-ref-1" epub:type="noteref" href="#footnote-1">[1]</a></p>
    <p>跨文件尾註 <a epub:type="noteref" href="notes.xhtml#endnote-2">[2]</a></p>
    <p>舊版註腳 <a class="noteref" href="#legacy-note">[3]</a></p>
    <div id="legacy-note" class="footnote"><p>這是 EPUB 2 註腳。</p></div>
    <aside id="footnote-1" epub:type="footnote">
      <p>這是註腳的內文。</p>
      <a role="doc-backlink" href="#note-ref-1">返回正文</a>
    </aside>
    <p id="inside">章節目標</p>
  </body>
</html>
''';
  const notes = '''
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <body>
    <ol epub:type="endnotes">
      <li id="endnote-2" epub:type="endnote"><p>這是跨文件尾註。</p></li>
    </ol>
  </body>
</html>
''';
  return _buildZip([
    _ZipItem('mimetype', utf8.encode('application/epub+zip')),
    _ZipItem('META-INF/container.xml', utf8.encode(container)),
    _ZipItem('OPS/book.opf', utf8.encode(package)),
    _ZipItem('OPS/Text/chapter.xhtml', utf8.encode(chapter)),
    _ZipItem('OPS/Text/notes.xhtml', utf8.encode(notes)),
  ]);
}

Uint8List _buildZip(List<_ZipItem> items) {
  final output = <int>[];
  final central = <int>[];
  for (final item in items) {
    final name = utf8.encode(item.name);
    final bytes = Uint8List.fromList(item.bytes);
    final crc = _crc32(bytes);
    final offset = output.length;

    _write32(output, 0x04034b50);
    _write16(output, 20);
    _write16(output, 0x0800);
    _write16(output, 0);
    _write16(output, 0);
    _write16(output, 0);
    _write32(output, crc);
    _write32(output, bytes.length);
    _write32(output, bytes.length);
    _write16(output, name.length);
    _write16(output, 0);
    output
      ..addAll(name)
      ..addAll(bytes);

    _write32(central, 0x02014b50);
    _write16(central, 0x0314);
    _write16(central, 20);
    _write16(central, 0x0800);
    _write16(central, 0);
    _write16(central, 0);
    _write16(central, 0);
    _write32(central, crc);
    _write32(central, bytes.length);
    _write32(central, bytes.length);
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

void main() {
  test('maps a cross-inline selection to its original XHTML text nodes', () {
    final first = XmlText('Hello ');
    final second = XmlText('bold world');
    final selection = FrameEpubTextSelectionMapper.map(
      selection: const TextSelection(baseOffset: 2, extentOffset: 12),
      displayedText: 'Hello bold world',
      sources: [
        FrameEpubTextRangeSource(
          start: 0,
          end: 6,
          node: first,
          sourceOffsets: [0, 1, 2, 3, 4, 5, 6],
        ),
        FrameEpubTextRangeSource(
          start: 6,
          end: 16,
          node: second,
          sourceOffsets: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        ),
      ],
    );

    expect(selection, isNotNull);
    expect(selection!.quote, 'llo bold w');
    expect(identical(selection.startNode, first), isTrue);
    expect(selection.startOffset, 2);
    expect(identical(selection.endNode, second), isTrue);
    expect(selection.endOffset, 6);
  });

  test('maps UTF-16 selection offsets around supplementary Unicode characters', () {
    final source = XmlText('a😀b');
    final selection = FrameEpubTextSelectionMapper.map(
      selection: const TextSelection(baseOffset: 1, extentOffset: 3),
      displayedText: 'a😀b',
      sources: [
        FrameEpubTextRangeSource(
          start: 0,
          end: 4,
          node: source,
          sourceOffsets: [0, 1, 1, 3, 4],
        ),
      ],
    );

    expect(selection, isNotNull);
    expect(selection!.quote, '😀');
    expect(selection.startOffset, 1);
    expect(selection.endOffset, 3);
  });

  test('rejects collapsed or text-free placeholder-only selections', () {
    final source = XmlText('visible');
    expect(
      FrameEpubTextSelectionMapper.map(
        selection: const TextSelection.collapsed(offset: 2),
        displayedText: 'visible',
        sources: [
          FrameEpubTextRangeSource(
            start: 0,
            end: 7,
            node: source,
            sourceOffsets: [0, 1, 2, 3, 4, 5, 6, 7],
          ),
        ],
      ),
      isNull,
    );
    expect(
      FrameEpubTextSelectionMapper.map(
        selection: const TextSelection(baseOffset: 0, extentOffset: 1),
        displayedText: '\uFFFC',
        sources: const [],
      ),
      isNull,
    );
  });

  testWidgets('renders XHTML text and forwards internal links', (tester) async {
    final bytes = _fixture();
    final book = FrameBook.fromJson({
      'id': 'chapter-widget-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/widget.epub',
      'fileName': 'widget.epub',
      'format': 'EPUB',
      'shelf': 'books',
      'size': bytes.length,
    });
    final archive = await FrameZipArchive.open(
      source: _MemoryFileSource(bytes),
      book: book,
    );
    try {
      final epub = await const FrameEpubParser().parse(archive);
      final loader = FrameEpubResourceLoader(archive: archive, book: epub);
      final chapter = await loader.loadChapter(epub.spine.single);
      final selectedNode = chapter.document.descendants
          .whereType<XmlText>()
          .firstWhere((node) => node.value == 'EPUB');
      final annotationCfi = FrameEpubCfi.createRange(
        book: epub,
        spineIndex: 0,
        startNode: selectedNode,
        startOffset: 0,
        endNode: selectedNode,
        endOffset: selectedNode.value.length,
      )!;
      String? followedHref;
      FrameEpubFootnote? openedFootnote;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: FrameEpubChapterView(
              chapter: chapter,
              resourceLoader: loader,
              annotations: [
                FrameReaderAnnotation(
                  id: 'test-yellow-highlight',
                  bookId: book.id,
                  type: 'highlight',
                  cfi: annotationCfi,
                  quote: 'EPUB',
                  color: 'yellow',
                  createdAt: 1,
                ),
                FrameReaderAnnotation(
                  id: 'test-note',
                  bookId: book.id,
                  type: 'note',
                  cfi: annotationCfi,
                  quote: 'EPUB',
                  text: '測試筆記',
                  color: 'violet',
                  createdAt: 2,
                ),
              ],
              onInternalLink: (href) => followedHref = href,
              onFootnote: (footnote) => openedFootnote = footnote,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('閱讀畫面測試'), findsOneWidget);
      expect(find.textContaining('EPUB'), findsOneWidget);
      expect(find.text('章節目標'), findsOneWidget);
      expect(find.byType(SelectableText), findsWidgets);
      final paragraph = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .firstWhere(
            (widget) =>
                widget.textSpan?.toPlainText().contains('EPUB') ?? false,
          );
      final paragraphSpan = paragraph.textSpan!;
      final markedSpan = <TextSpan>[];
      void collectMarkedSpans(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style?.backgroundColor != null ||
            span.style?.decoration != null) {
          markedSpan.add(span);
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          collectMarkedSpans(child);
        }
      }
      collectMarkedSpans(paragraphSpan);
      expect(
        markedSpan.any(
          (span) =>
              span.text == 'EPUB' &&
              span.style?.backgroundColor != null &&
              span.style?.decorationStyle == TextDecorationStyle.wavy,
        ),
        isTrue,
      );

      await tester.tap(find.text('[1]'));
      await tester.pumpAndSettle();
      expect(openedFootnote?.title, '註腳');
      expect(openedFootnote?.content, '這是註腳的內文。');
      expect(followedHref, isNull);
      expect(find.text('這是註腳的內文。'), findsNothing);

      await tester.tap(find.text('[2]'));
      await tester.pumpAndSettle();
      expect(openedFootnote?.title, '尾註');
      expect(openedFootnote?.content, '這是跨文件尾註。');
      expect(followedHref, isNull);

      await tester.tap(find.text('[3]'));
      await tester.pumpAndSettle();
      expect(openedFootnote?.title, '註腳');
      expect(openedFootnote?.content, '這是 EPUB 2 註腳。');
      expect(followedHref, isNull);

      await tester.tap(find.text('章內連結'));
      expect(followedHref, 'chapter.xhtml#inside');
    } finally {
      await archive.close();
    }
  });
  testWidgets('paginated renderer lays out XHTML as horizontal pages', (tester) async {
    final bytes = _fixture();
    final book = FrameBook.fromJson({
      'id': 'chapter-pagination-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/pagination.epub',
      'fileName': 'pagination.epub',
      'format': 'EPUB',
      'shelf': 'books',
      'size': bytes.length,
    });
    final archive = await FrameZipArchive.open(
      source: _MemoryFileSource(bytes),
      book: book,
    );
    final pageController = PageController();
    try {
      final epub = await const FrameEpubParser().parse(archive);
      final loader = FrameEpubResourceLoader(archive: archive, book: epub);
      final chapter = await loader.loadChapter(epub.spine.single);

      tester.view.physicalSize = const Size(320, 220);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FrameEpubChapterView(
            chapter: chapter,
            resourceLoader: loader,
            paginated: true,
            pageController: pageController,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(PageView), findsOneWidget);
      expect(find.byType(SelectableText), findsWidgets);
      expect(pageController.hasClients, isTrue);
      expect(pageController.position.maxScrollExtent, greaterThan(0));
      final nextPage = pageController.nextPage(
        duration: const Duration(milliseconds: 1),
        curve: Curves.linear,
      );
      await tester.pumpAndSettle();
      await nextPage;
      expect(pageController.page, 1);

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      pageController.dispose();
      await archive.close();
    }
  });


}
