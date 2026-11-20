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

Uint8List _fixture({
  String additionalIntroText = '',
  String additionalTableMarkup = '',
  bool fixedLayout = false,
}) {
  const container = '''
<container><rootfiles>
  <rootfile full-path="OPS/book.opf"
    media-type="application/oebps-package+xml"/>
</rootfiles></container>
''';
  final layoutMeta = fixedLayout
      ? '<meta property="rendition:layout">pre-paginated</meta>'
      : '';
  final imageManifest = fixedLayout
      ? '<item id="page-image" href="Images/page.png" media-type="image/png"/>'
      : '';
  final package = '''
<package xmlns="http://www.idpf.org/2007/opf"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         version="3.0" unique-identifier="uid">
  <metadata>
    <dc:identifier id="uid">urn:uuid:widget-test</dc:identifier>
    <dc:title>Widget test</dc:title>
    <dc:language>zh-TW</dc:language>
    $layoutMeta
  </metadata>
  <manifest>
    <item id="chapter" href="Text/chapter.xhtml"
      media-type="application/xhtml+xml"/>
    <item id="notes" href="Text/notes.xhtml"
      media-type="application/xhtml+xml"/>
    $imageManifest
  </manifest>
  <spine><itemref idref="chapter"/></spine>
</package>
''';
  final chapterBody = fixedLayout
      ? '<img src="../Images/page.png" alt="漫畫頁" style="width:100%;height:100%"/>'
      : '''
    <h1>閱讀畫面測試</h1>
    <p class="intro">這是一段 <strong>EPUB</strong> 文字。$additionalIntroText</p>
    $additionalTableMarkup
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
    ''';
  final chapter = '''
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Widget fixture</title></head>
  <body>$chapterBody</body>
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
    if (fixedLayout)
      _ZipItem(
        'OPS/Images/page.png',
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      ),
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
  testWidgets('restores all highlight colors and underline annotations',
      (tester) async {
    final bytes = _fixture(
      additionalIntroText: ' <span>下劃線測試</span>',
    );
    final book = FrameBook.fromJson({
      'id': 'chapter-annotation-style-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/annotation-style.epub',
      'fileName': 'annotation-style.epub',
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
      final textNodes = chapter.document.descendants.whereType<XmlText>();
      final colorNode =
          textNodes.firstWhere((node) => node.value == 'EPUB');
      final underlineNode =
          textNodes.firstWhere((node) => node.value == '下劃線測試');

      FrameReaderAnnotation annotation({
        required String id,
        required XmlText node,
        required int start,
        required int end,
        required String color,
      }) =>
          FrameReaderAnnotation(
            id: id,
            bookId: book.id,
            type: 'highlight',
            cfi: FrameEpubCfi.createRange(
              book: epub,
              spineIndex: 0,
              startNode: node,
              startOffset: start,
              endNode: node,
              endOffset: end,
            )!,
            quote: node.value.substring(start, end),
            color: color,
          );

      final annotations = [
        annotation(
          id: 'yellow',
          node: colorNode,
          start: 0,
          end: 1,
          color: 'yellow',
        ),
        annotation(
          id: 'violet',
          node: colorNode,
          start: 1,
          end: 2,
          color: 'violet',
        ),
        annotation(
          id: 'mint',
          node: colorNode,
          start: 2,
          end: 3,
          color: 'mint',
        ),
        annotation(
          id: 'rose',
          node: colorNode,
          start: 3,
          end: 4,
          color: 'rose',
        ),
        annotation(
          id: 'underline',
          node: underlineNode,
          start: 0,
          end: underlineNode.value.length,
          color: 'underline',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: FrameEpubChapterView(
                chapter: chapter,
                resourceLoader: loader,
                annotations: annotations,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final spans = <TextSpan>[];
      void collect(InlineSpan span) {
        if (span is! TextSpan) return;
        spans.add(span);
        for (final child in span.children ?? const <InlineSpan>[]) {
          collect(child);
        }
      }

      for (final selectable
          in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
        final span = selectable.textSpan;
        if (span != null) collect(span);
      }

      TextSpan marked(String text) =>
          spans.firstWhere((span) => span.text == text);

      expect(marked('E').style?.backgroundColor, const Color(0x66F2C94C));
      expect(marked('P').style?.backgroundColor, const Color(0x66A78BFA));
      expect(marked('U').style?.backgroundColor, const Color(0x6665C9A5));
      expect(marked('B').style?.backgroundColor, const Color(0x66E88EAF));
      expect(
        marked('下劃線測試').style?.decoration,
        TextDecoration.underline,
      );
      expect(marked('下劃線測試').style?.decorationThickness, 2.2);
    } finally {
      await archive.close();
    }
  });

  testWidgets('renders EPUB table headers, cells and colspan without overflow',
      (tester) async {
    const table = '''
      <table border="1" style="width:100%;border-color:#665577">
        <thead>
          <tr><th>書名</th><th>作者</th></tr>
        </thead>
        <tbody>
          <tr><td colspan="2">合併欄位內容</td></tr>
          <tr><td>第一本書</td><td>作者甲</td></tr>
          <tr><td>第二本書</td><td>作者乙</td></tr>
        </tbody>
      </table>
    ''';
    final bytes = _fixture(additionalTableMarkup: table);
    final book = FrameBook.fromJson({
      'id': 'chapter-table-layout-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/table.epub',
      'fileName': 'table.epub',
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

      tester.view.physicalSize = const Size(520, 720);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FrameEpubChapterView(
            chapter: chapter,
            resourceLoader: loader,
            contentMaxWidth: 480,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('書名'), findsOneWidget);
      expect(find.text('作者'), findsOneWidget);
      expect(find.text('合併欄位內容'), findsOneWidget);
      expect(find.text('第一本書'), findsOneWidget);
      expect(find.text('作者乙'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await archive.close();
    }
  });

  testWidgets('keeps long EPUB tables bounded within a paginated page',
      (tester) async {
    final rowText = List.filled(24, '表格文字內容').join('、');
    final rows = List.generate(
      24,
      (index) => '<tr><td>章節 $index</td><td>$rowText</td></tr>',
    ).join();
    final bytes = _fixture(additionalTableMarkup: '<table border="1">$rows</table>');
    final book = FrameBook.fromJson({
      'id': 'chapter-table-pagination-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/table-pagination.epub',
      'fileName': 'table-pagination.epub',
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
      expect(pageController.hasClients, isTrue);
      final pageCount =
          (pageController.position.maxScrollExtent /
                  pageController.position.viewportDimension)
              .round() +
          1;
      var tableVisible = false;
      for (var page = 0; page < pageCount; page++) {
        pageController.jumpToPage(page);
        await tester.pumpAndSettle();
        if (find.text('章節 0').evaluate().isNotEmpty) {
          tableVisible = true;
          break;
        }
      }

      expect(tableVisible, isTrue);
      expect(find.byType(SingleChildScrollView), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      pageController.dispose();
      await archive.close();
    }
  });

  testWidgets('fixed-layout renderer supports fit-width and fit-page modes',
      (tester) async {
    final bytes = _fixture(fixedLayout: true);
    final book = FrameBook.fromJson({
      'id': 'fixed-layout-comic-fit-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/comic.epub',
      'fileName': 'comic.epub',
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
      expect(epub.isFixedLayout, isTrue);
      final loader = FrameEpubResourceLoader(archive: archive, book: epub);
      final chapter = await loader.loadChapter(epub.spine.single);

      tester.view.physicalSize = const Size(420, 620);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
            child: FrameEpubChapterView(
              chapter: chapter,
              resourceLoader: loader,
              fixedLayout: true,
              fixedLayoutImageFit: 'fit-width',
              fixedLayoutAllowZoom: false,
              fixedLayoutBackdropDecoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF76543A), Color(0xFF30241E)],
                ),
              ),
            ),
          ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      final fitWidthSize = tester.getSize(find.byType(Image));
      expect(fitWidthSize.width, closeTo(420, 1));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
            child: FrameEpubChapterView(
              chapter: chapter,
              resourceLoader: loader,
              fixedLayout: true,
              fixedLayoutImageFit: 'fit-page',
              fixedLayoutAllowZoom: true,
            ),
          ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      final fitPageSize = tester.getSize(find.byType(Image));
      expect(fitPageSize.width, closeTo(420, 1));
      expect(fitPageSize.height, closeTo(620, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
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


  testWidgets('long paragraphs are split into separate paginated text fragments', (tester) async {
    final longText = List.filled(
      900,
      '這是一段用來測試長篇 EPUB 文字自動分頁的內容，粗體、註記與原始文字位置都必須保持正確。',
    ).join();
    final bytes = _fixture(additionalIntroText: longText);
    final book = FrameBook.fromJson({
      'id': 'chapter-long-pagination-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/long-pagination.epub',
      'fileName': 'long-pagination.epub',
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
      expect(pageController.hasClients, isTrue);
      final pageCount =
          (pageController.position.maxScrollExtent /
                  pageController.position.viewportDimension)
              .round() +
          1;
      expect(pageCount, greaterThan(5));

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      pageController.dispose();
      await archive.close();
    }
  });

}
