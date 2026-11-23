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
import 'package:frame_ebook/reader/frame_epub_ruby_annotation.dart';
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
  String additionalParagraphMarkup = '',
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
    $additionalParagraphMarkup
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

  test('maps selection offsets after a first-line layout placeholder', () {
    final source = XmlText('首行縮排');
    final selection = FrameEpubTextSelectionMapper.map(
      selection: const TextSelection(baseOffset: 1, extentOffset: 5),
      displayedText: '\uFFFC首行縮排',
      sources: [
        FrameEpubTextRangeSource(
          start: 1,
          end: 5,
          node: source,
          sourceOffsets: [0, 1, 2, 3, 4],
        ),
      ],
    );

    expect(selection, isNotNull);
    expect(selection!.quote, '首行縮排');
    expect(selection.startOffset, 0);
    expect(selection.endOffset, 4);
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
    final bytes = _fixture(
      additionalParagraphMarkup:
          '<p style="text-indent: 2em">首行縮排回歸</p>',
    );
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
      final indentedParagraph = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .firstWhere(
            (widget) =>
                widget.textSpan?.toPlainText().contains('首行縮排回歸') ?? false,
          );
      final indent = (indentedParagraph.textSpan!.children!
          .whereType<WidgetSpan>()
          .single
          .child) as SizedBox;
      expect(indent.width, 32);
      expect(indent.height, 0);

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
  testWidgets('renders superscript and subscript without replacing source text',
      (tester) async {
    final bytes = _fixture(
      additionalParagraphMarkup: '''
        <p>Water H<sub>2</sub>O and x<sup>3</sup>.</p>
        <p>Author style: CO<span style="font-variant-position: sub">2</span>.</p>
      ''',
    );
    final book = FrameBook.fromJson({
      'id': 'chapter-script-position-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/script-position.epub',
      'fileName': 'script-position.epub',
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
      final subscriptNode = chapter.document.descendants
          .whereType<XmlText>()
          .firstWhere((node) => node.value == '2');
      final subscriptCfi = FrameEpubCfi.createRange(
        book: epub,
        spineIndex: 0,
        startNode: subscriptNode,
        startOffset: 0,
        endNode: subscriptNode,
        endOffset: subscriptNode.value.length,
      )!;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: FrameEpubChapterView(
                chapter: chapter,
                resourceLoader: loader,
                annotations: [
                  FrameReaderAnnotation(
                    id: 'subscript-source-range',
                    bookId: book.id,
                    type: 'highlight',
                    cfi: subscriptCfi,
                    quote: '2',
                    color: 'mint',
                    createdAt: 1,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selectable = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .firstWhere(
            (widget) =>
                widget.textSpan?.toPlainText().contains('Water H2O and x3') ??
                false,
          );
      final root = selectable.textSpan!;
      final spans = <TextSpan>[];

      void collect(InlineSpan span) {
        if (span is! TextSpan) return;
        spans.add(span);
        for (final child in span.children ?? const <InlineSpan>[]) {
          collect(child);
        }
      }

      collect(root);
      final subscript = spans.firstWhere(
        (span) =>
            span.text == null &&
            span.toPlainText() == '2' &&
            span.style?.fontFeatures?.any(
                  (feature) =>
                      feature.feature == 'subs' && feature.value == 1,
                ) ==
                true,
      );
      final superscript = spans.firstWhere(
        (span) =>
            span.text == null &&
            span.toPlainText() == '3' &&
            span.style?.fontFeatures?.any(
                  (feature) =>
                      feature.feature == 'sups' && feature.value == 1,
                ) ==
                true,
      );
      final subscriptText =
          spans.firstWhere((span) => span.text == '2');
      expect(subscript.style?.fontSize, lessThan(root.style?.fontSize ?? 16));
      expect(superscript.style?.fontSize, lessThan(root.style?.fontSize ?? 16));
      expect(subscriptText.style?.backgroundColor, const Color(0x6665C9A5));
      expect(root.toPlainText(), contains('Water H2O and x3'));
      expect(find.byType(SelectableText), findsWidgets);
    } finally {
      await archive.close();
    }
  });

  testWidgets('renders ruby annotations without polluting selectable text',
      (tester) async {
    final bytes = _fixture(
      additionalParagraphMarkup: '''
        <p>Ruby：<ruby>漢字<rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby>。</p>
        <p>分段：<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>。</p>
      ''',
    );
    final book = FrameBook.fromJson({
      'id': 'chapter-ruby-annotation-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/ruby.epub',
      'fileName': 'ruby.epub',
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
      final rubyBase = chapter.document.descendants
          .whereType<XmlText>()
          .firstWhere((node) => node.value == '漢字');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: FrameEpubChapterView(
                chapter: chapter,
                resourceLoader: loader,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rubySelectable = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .firstWhere(
            (widget) =>
                widget.textSpan?.toPlainText().contains('Ruby：漢字') ?? false,
          );
      final renderedText = rubySelectable.textSpan!;
      expect(
        renderedText.toPlainText(includePlaceholders: false),
        contains('Ruby：漢字。'),
      );
      expect(
        renderedText.toPlainText(includePlaceholders: false),
        isNot(contains('かんじ')),
      );
      expect(find.text('（'), findsNothing);
      expect(find.text('）'), findsNothing);

      final annotations = <FrameEpubRubyAnnotation>[];
      void collect(InlineSpan span) {
        if (span is! TextSpan) return;
        for (final child in span.children ?? const <InlineSpan>[]) {
          if (child is WidgetSpan &&
              child.child is FrameEpubRubyAnnotation) {
            annotations.add(child.child as FrameEpubRubyAnnotation);
          } else {
            collect(child);
          }
        }
      }

      collect(renderedText);
      expect(annotations, hasLength(1));
      expect(annotations.single.annotation.toPlainText(), 'かんじ');
      expect(
        annotations.single.placeholderDimensions.alignment,
        PlaceholderAlignment.aboveBaseline,
      );

      final selection = FrameEpubTextSelectionMapper.map(
        selection: const TextSelection(baseOffset: 0, extentOffset: 3),
        displayedText: '漢字\uFFFC',
        sources: [
          FrameEpubTextRangeSource(
            start: 0,
            end: 2,
            node: rubyBase,
            sourceOffsets: const [0, 1, 2],
          ),
        ],
      );
      expect(selection?.startNode, same(rubyBase));
      expect(selection?.startOffset, 0);
      expect(selection?.endNode, same(rubyBase));
      expect(selection?.endOffset, 2);
      expect(selection?.quote, '漢字');
    } finally {
      await archive.close();
    }
  });

  testWidgets('supports ruby alignment, nested annotation styles and under-position',
      (tester) async {
    final bytes = _fixture(
      additionalParagraphMarkup: '''
        <p><ruby style="ruby-align: start">
          <rb>漢字</rb>
          <rt><span style="color: purple; font-weight: bold">かんじ</span></rt>
        </ruby></p>
        <p><ruby style="ruby-position: under">
          <rb>東</rb><rt>ひがし</rt>
        </ruby></p>
        <p><ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby></p>
      ''',
    );
    final book = FrameBook.fromJson({
      'id': 'chapter-ruby-layout-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/ruby-layout.epub',
      'fileName': 'ruby-layout.epub',
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

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: FrameEpubChapterView(
                chapter: chapter,
                resourceLoader: loader,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rubyWidgets = <FrameEpubRubyAnnotation>[];
      void collect(InlineSpan span) {
        if (span is! TextSpan) return;
        for (final child in span.children ?? const <InlineSpan>[]) {
          if (child is WidgetSpan &&
              child.child is FrameEpubRubyAnnotation) {
            rubyWidgets.add(child.child as FrameEpubRubyAnnotation);
          } else {
            collect(child);
          }
        }
      }

      for (final selectable
          in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
        final root = selectable.textSpan;
        if (root != null) collect(root);
      }
      expect(rubyWidgets, hasLength(4));

      final aligned = rubyWidgets.first;
      expect(aligned.rubyAlign, 'start');
      final alignedAnnotation = aligned.annotation as TextSpan;
      final nested = alignedAnnotation.children!.single as TextSpan;
      expect(nested.toPlainText(), 'かんじ');
      expect(nested.style?.color, const Color(0xFF800080));
      expect(nested.style?.fontWeight, FontWeight.bold);

      final under = rubyWidgets[1];
      expect(under.rubyPosition, 'under');
      expect(
        under.placeholderDimensions.alignment,
        PlaceholderAlignment.belowBaseline,
      );
      expect(under.verticalOffset, greaterThan(0));

      final segmented = rubyWidgets.skip(2).toList();
      expect(segmented.map((item) => item.annotation.toPlainText()).toList(),
          ['かん', 'じ']);
      expect(segmented.first.rubyAlign, 'space-around');
      expect(segmented.first.rubyPosition, 'alternate');
      expect(tester.takeException(), isNull);
    } finally {
      await archive.close();
    }
  });

  testWidgets('preserves EPUB ordered and unordered list markers',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bytes = _fixture(
      additionalParagraphMarkup: '''
        <ol style="list-style-type: upper-alpha" start="26">
          <li>字母編號甲</li><li>字母編號乙</li>
        </ol>
        <ol style="list-style-type: lower-roman" start="4">
          <li>羅馬編號</li>
        </ol>
        <ol reversed>
          <li>倒序編號二</li><li>倒序編號一</li>
        </ol>
        <ol><li value="7">指定起點</li><li>接續編號</li></ol>
        <ol type="A" start="28"><li>HTML 型別編號</li></ol>
        <ol style="list-style-type: decimal-leading-zero" start="3">
          <li>補零編號</li>
        </ol>
        <ul style="list-style-type: square"><li>方形項目</li></ul>
      ''',
    );
    final book = FrameBook.fromJson({
      'id': 'chapter-list-marker-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/list-markers.epub',
      'fileName': 'list-markers.epub',
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

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: FrameEpubChapterView(
              chapter: chapter,
              resourceLoader: loader,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Z.'), findsOneWidget);
      expect(find.text('AA.'), findsOneWidget);
      expect(find.text('iv.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('7.'), findsOneWidget);
      expect(find.text('8.'), findsOneWidget);
      expect(find.text('AB.'), findsOneWidget);
      expect(find.text('03.'), findsOneWidget);
      expect(find.text('▪'), findsOneWidget);
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

  testWidgets('restores a highlight range across inline XHTML text nodes',
      (tester) async {
    final bytes = _fixture();
    final book = FrameBook.fromJson({
      'id': 'chapter-cross-inline-annotation-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/cross-inline.epub',
      'fileName': 'cross-inline.epub',
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
      final nodes = chapter.document.descendants.whereType<XmlText>();
      final startNode =
          nodes.firstWhere((node) => node.value == '這是一段 ');
      final middleNode = nodes.firstWhere((node) => node.value == 'EPUB');
      final endNode = nodes.firstWhere((node) => node.value == ' 文字。');
      final cfi = FrameEpubCfi.createRange(
        book: epub,
        spineIndex: 0,
        startNode: startNode,
        startOffset: 0,
        endNode: endNode,
        endOffset: endNode.value.length,
      )!;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: FrameEpubChapterView(
                chapter: chapter,
                resourceLoader: loader,
                annotations: [
                  FrameReaderAnnotation(
                    id: 'cross-inline-highlight',
                    bookId: book.id,
                    type: 'highlight',
                    cfi: cfi,
                    quote: '${startNode.value}${middleNode.value}${endNode.value}',
                    color: 'rose',
                    createdAt: 30,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rendered = <TextSpan>[];
      void collect(InlineSpan span) {
        if (span is! TextSpan) return;
        rendered.add(span);
        for (final child in span.children ?? const <InlineSpan>[]) {
          collect(child);
        }
      }

      for (final selectable
          in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
        final span = selectable.textSpan;
        if (span != null) collect(span);
      }

      final expectedColor = const Color(0x66E88EAF);
      for (final text in [
        startNode.value,
        middleNode.value,
        endNode.value,
      ]) {
        final span = rendered.firstWhere((candidate) => candidate.text == text);
        expect(span.style?.backgroundColor, expectedColor);
      }
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


  testWidgets(
      'does not snap back when a live anchor changes after turning a page',
      (tester) async {
    final longText = List.filled(
      80,
      '用來測試 EPUB 分頁位置穩定性的長篇內容。每次翻頁後，閱讀位置會更新，但不應將閱讀器拉回第一頁。',
    ).join();
    final bytes = _fixture(additionalParagraphMarkup: '<p>$longText</p>');
    final book = FrameBook.fromJson({
      'id': 'chapter-pagination-anchor-stability-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/anchor-stability.epub',
      'fileName': 'anchor-stability.epub',
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
      final initialAnchor = chapter.document.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'h1');
      final laterAnchor = chapter.document.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.getAttribute('id') == 'inside');
      final laterPoint = FrameEpubCfi.firstTextPoint(laterAnchor);
      expect(laterPoint, isNotNull);

      tester.view.physicalSize = const Size(320, 220);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Widget buildReader({
        required XmlElement anchor,
        FrameEpubCfiPoint? textPoint,
        double? scrollFraction,
        int restoreRevision = 0,
      }) =>
          MaterialApp(
            home: Scaffold(
              body: FrameEpubChapterView(
                chapter: chapter,
                resourceLoader: loader,
                paginated: true,
                pageController: pageController,
                initialAnchor: anchor,
                initialTextNode: textPoint?.node,
                initialTextOffset: textPoint?.offset,
                initialScrollFraction: scrollFraction,
                restoreRevision: restoreRevision,
              ),
            ),
          );

      await tester.pumpWidget(buildReader(anchor: initialAnchor));
      await tester.pumpAndSettle();
      expect(pageController.hasClients, isTrue);
      expect(pageController.position.maxScrollExtent, greaterThan(0));

      final nextPage = pageController.nextPage(
        duration: const Duration(milliseconds: 1),
        curve: Curves.linear,
      );
      await tester.pumpAndSettle();
      await nextPage;
      expect(pageController.page, 1);

      // A live CFI update changes the anchor prop, but does not represent a
      // navigation request and must not jump to the old measured page.
      await tester.pumpWidget(buildReader(anchor: laterAnchor));
      await tester.pumpAndSettle();
      expect(pageController.page, 1);

      // An explicit navigation increments restoreRevision; the target page is
      // re-measured from the new anchor and is expected to move forward.
      await tester.pumpWidget(
        buildReader(
          anchor: laterAnchor,
          textPoint: laterPoint,
          scrollFraction: 1,
          restoreRevision: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(pageController.page, greaterThan(1));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      pageController.dispose();
      await archive.close();
    }
  });

  testWidgets(
      'restores a CFI inside a later inline text node on its measured page',
      (tester) async {
    final prefix = List.filled(100, '前段文字跨頁定位測試。').join();
    final targetText = '這是需要精確恢復的行內目標文字。';
    final bytes = _fixture(
      additionalParagraphMarkup:
          '<p>$prefix<em>前置行內文字</em><strong id="target-inline">$targetText</strong></p>',
    );
    final book = FrameBook.fromJson({
      'id': 'chapter-inline-cfi-restore-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/inline-cfi-restore.epub',
      'fileName': 'inline-cfi-restore.epub',
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
      final targetElement = chapter.document.descendants
          .whereType<XmlElement>()
          .firstWhere(
            (element) => element.getAttribute('id') == 'target-inline',
          );
      final targetTextNode =
          targetElement.children.whereType<XmlText>().single;
      expect(targetTextNode.value, targetText);

      tester.view.physicalSize = const Size(320, 220);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrameEpubChapterView(
              chapter: chapter,
              resourceLoader: loader,
              paginated: true,
              pageController: pageController,
              initialTextNode: targetTextNode,
              initialTextOffset: 4,
              initialScrollFraction: 0,
              restoreRevision: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(pageController.hasClients, isTrue);
      expect(
        pageController.page,
        greaterThan(0),
        reason: 'An inline CFI later in the chapter must not fall back to page zero.',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      pageController.dispose();
      await archive.close();
    }
  });

  testWidgets('restores the current CFI when the viewport grows taller',
      (tester) async {
    final longText = List.filled(
      360,
      '視窗尺寸變更後，閱讀器必須保留目前文字節點與 UTF-16 位移，再依照新頁高重新分頁。',
    ).join();
    final bytes = _fixture(additionalParagraphMarkup: '<p>$longText</p>');
    final book = FrameBook.fromJson({
      'id': 'chapter-pagination-height-growth-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/height-growth.epub',
      'fileName': 'height-growth.epub',
      'format': 'EPUB',
      'shelf': 'books',
      'size': bytes.length,
    });
    final archive = await FrameZipArchive.open(
      source: _MemoryFileSource(bytes),
      book: book,
    );
    final pageController = PageController();
    final reportedPositions = <String>[];
    try {
      final epub = await const FrameEpubParser().parse(archive);
      final loader = FrameEpubResourceLoader(archive: archive, book: epub);
      final chapter = await loader.loadChapter(epub.spine.single);

      Widget buildReader({
        required PageController controller,
        FrameEpubCfiLocation? restorePoint,
      }) =>
          MaterialApp(
            home: Scaffold(
              body: FrameEpubChapterView(
                chapter: chapter,
                resourceLoader: loader,
                paginated: true,
                pageController: controller,
                initialTextNode: restorePoint?.node is XmlText
                    ? restorePoint!.node as XmlText
                    : null,
                initialTextOffset:
                    restorePoint?.node is XmlText ? restorePoint!.offset : null,
                initialScrollFraction: restorePoint == null ? null : 0,
                restoreRevision: restorePoint == null ? 0 : 1,
                onReadingPosition: (cfi, _) => reportedPositions.add(cfi),
              ),
            ),
          );

      tester.view.physicalSize = const Size(420, 260);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildReader(controller: pageController));
      await tester.pumpAndSettle();
      expect(pageController.hasClients, isTrue);
      expect(pageController.position.maxScrollExtent, greaterThan(0));

      pageController.jumpToPage(4);
      await tester.pumpAndSettle();
      expect(reportedPositions, isNotEmpty);
      final savedCfi = reportedPositions.last;
      final savedPoint = FrameEpubCfi.resolve(
        book: epub,
        document: chapter.document,
        cfi: savedCfi,
      );
      expect(savedPoint?.node, isA<XmlText>());

      tester.view.physicalSize = const Size(420, 420);
      await tester.pumpAndSettle();

      expect(find.byType(PageView), findsOneWidget);
      expect(tester.takeException(), isNull);
      final restoredPage = pageController.page!.round();

      // A fresh reader given the same CFI is the reference for where that
      // exact text node and offset belongs under the enlarged viewport.
      final referenceController = PageController();
      await tester.pumpWidget(
        buildReader(
          controller: referenceController,
          restorePoint: savedPoint,
        ),
      );
      await tester.pumpAndSettle();
      expect(referenceController.page!.round(), restoredPage);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      referenceController.dispose();
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      pageController.dispose();
      await archive.close();
    }
  });

  testWidgets('restores the current CFI after font size and line height change',
      (tester) async {
    final longText = List.filled(
      420,
      '字級與行距調整會改變每頁能容納的文字量，但不能讓正在閱讀的位置倒退到章節開頭。',
    ).join();
    final bytes = _fixture(additionalParagraphMarkup: '<p>$longText</p>');
    final book = FrameBook.fromJson({
      'id': 'chapter-pagination-typography-restore-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/typography-restore.epub',
      'fileName': 'typography-restore.epub',
      'format': 'EPUB',
      'shelf': 'books',
      'size': bytes.length,
    });
    final archive = await FrameZipArchive.open(
      source: _MemoryFileSource(bytes),
      book: book,
    );
    final pageController = PageController();
    final reportedPositions = <String>[];
    try {
      final epub = await const FrameEpubParser().parse(archive);
      final loader = FrameEpubResourceLoader(archive: archive, book: epub);
      final chapter = await loader.loadChapter(epub.spine.single);

      Widget buildReader({
        required PageController controller,
        required double fontSize,
        required double lineHeight,
        FrameEpubCfiLocation? restorePoint,
      }) =>
          MaterialApp(
            home: Scaffold(
              body: FrameEpubChapterView(
                chapter: chapter,
                resourceLoader: loader,
                paginated: true,
                pageController: controller,
                fontSize: fontSize,
                lineHeight: lineHeight,
                initialTextNode: restorePoint?.node is XmlText
                    ? restorePoint!.node as XmlText
                    : null,
                initialTextOffset:
                    restorePoint?.node is XmlText ? restorePoint!.offset : null,
                initialScrollFraction: restorePoint == null ? null : 0,
                restoreRevision: restorePoint == null ? 0 : 1,
                onReadingPosition: (cfi, _) => reportedPositions.add(cfi),
              ),
            ),
          );

      tester.view.physicalSize = const Size(420, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildReader(
          controller: pageController,
          fontSize: 16,
          lineHeight: 1.65,
        ),
      );
      await tester.pumpAndSettle();
      expect(pageController.hasClients, isTrue);
      expect(pageController.position.maxScrollExtent, greaterThan(0));

      pageController.jumpToPage(5);
      await tester.pumpAndSettle();
      expect(reportedPositions, isNotEmpty);
      final savedCfi = reportedPositions.last;
      final savedPoint = FrameEpubCfi.resolve(
        book: epub,
        document: chapter.document,
        cfi: savedCfi,
      );
      expect(savedPoint?.node, isA<XmlText>());

      await tester.pumpWidget(
        buildReader(
          controller: pageController,
          fontSize: 26,
          lineHeight: 1.95,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PageView), findsOneWidget);
      expect(tester.takeException(), isNull);
      final restoredPage = pageController.page!.round();

      // Verify the live reader lands on the same page as a fresh CFI restore
      // measured with the new typography, not merely on any non-zero page.
      final referenceController = PageController();
      await tester.pumpWidget(
        buildReader(
          controller: referenceController,
          fontSize: 26,
          lineHeight: 1.95,
          restorePoint: savedPoint,
        ),
      );
      await tester.pumpAndSettle();
      expect(referenceController.page!.round(), restoredPage);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      referenceController.dispose();
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      pageController.dispose();
      await archive.close();
    }
  });

  testWidgets(
      're-measures page width when a two-page spread collapses to one page',
      (tester) async {
    final longText = List.filled(
      180,
      '切換雙頁與單頁版面時，正文應重新依照目前頁寬分頁，不能沿用舊欄寬。',
    ).join();
    final bytes = _fixture(additionalParagraphMarkup: '<p>$longText</p>');
    final book = FrameBook.fromJson({
      'id': 'chapter-spread-collapse-pagination-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/spread-collapse.epub',
      'fileName': 'spread-collapse.epub',
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

      tester.view.physicalSize = const Size(820, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrameEpubChapterView(
              chapter: chapter,
              resourceLoader: loader,
              paginated: true,
              doublePageSpread: true,
              pageController: pageController,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(pageController.hasClients, isTrue);
      final spreadTextWidth = tester.getSize(
        find.byType(SelectableText).first,
      ).width;
      expect(spreadTextWidth, lessThan(400));

      // 759px falls below the renderer's 760px two-page threshold.
      // The single-page text column must be measured at the wider page size.
      tester.view.physicalSize = const Size(759, 420);
      await tester.pumpAndSettle();

      final singlePageTextWidth = tester.getSize(
        find.byType(SelectableText).first,
      ).width;
      expect(
        singlePageTextWidth,
        greaterThan(500),
        reason: 'Single-page layout must not retain the narrower spread width.',
      );
      expect(tester.takeException(), isNull);

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

  testWidgets(
      'paginates a long first-line-indented EPUB paragraph without losing text',
      (tester) async {
    final longText = List.filled(
      260,
      '首行縮排不應阻止長章節文字按頁高切割，也不能遺失或重複任何文字。',
    ).join();
    final bytes = _fixture(
      additionalParagraphMarkup:
          '<p style="text-indent: 2em">$longText</p>',
    );
    final book = FrameBook.fromJson({
      'id': 'chapter-indented-long-paragraph-pagination-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/indented-long-paragraph.epub',
      'fileName': 'indented-long-paragraph.epub',
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

      tester.view.physicalSize = const Size(420, 280);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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

      expect(pageController.hasClients, isTrue);
      expect(
        pageController.position.maxScrollExtent,
        greaterThan(0),
        reason: 'A long paragraph with text-indent must span reader pages.',
      );

      final pageCount =
          (pageController.position.maxScrollExtent /
                  pageController.position.viewportDimension)
              .round() +
          1;
      expect(pageCount, greaterThan(1));
      final pageViewRect = tester.getRect(find.byType(PageView));
      final pageText = <String>[];
      for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
        pageController.jumpToPage(pageIndex);
        await tester.pumpAndSettle();

        final visiblePieces = <String>[];
        for (final element in find.byType(SelectableText).evaluate()) {
          final selectable = element.widget as SelectableText;
          if (!tester.getRect(find.byWidget(selectable)).overlaps(pageViewRect)) {
            continue;
          }
          visiblePieces.add(
            selectable.textSpan?.toPlainText(
                  includeSemanticsLabels: false,
                  includePlaceholders: true,
                ) ??
                selectable.data ??
                '',
          );
        }
        pageText.add(visiblePieces.join());
      }

      final displayedText =
          pageText.join().replaceAll('\uFFFC', '');
      expect(displayedText, contains(longText));
      expect(displayedText.split(longText).length - 1, 1);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      pageController.dispose();
      await archive.close();
    }
  });


}
