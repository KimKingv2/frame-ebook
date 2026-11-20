import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xml/xml.dart';
import 'package:frame_ebook/core/frame_api_client.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/library/frame_reader_repository.dart';
import 'package:frame_ebook/reader/frame_epub_cfi.dart';
import 'package:frame_ebook/reader/frame_epub_chapter_view.dart';
import 'package:frame_ebook/reader/frame_epub_parser.dart';
import 'package:frame_ebook/reader/frame_epub_reader_session.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';

class _ZipItem {
  const _ZipItem(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}

class _MemoryFrameFileSource implements FrameFileSource {
  _MemoryFrameFileSource(this.bytes);

  final Uint8List bytes;
  final List<(int, int)> requests = [];

  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    final range = request.range;
    if (range == null) {
      throw StateError('EPUB must be read through explicit byte ranges.');
    }
    final start = range.suffixLength == null
        ? range.start!
        : bytes.length - range.suffixLength!;
    final requestedEnd = range.end ?? bytes.length - 1;
    final end = requestedEnd < bytes.length ? requestedEnd : bytes.length - 1;
    if (start < 0 || end < start) throw RangeError('Invalid fixture range.');
    requests.add((start, end));
    final body = Uint8List.sublistView(bytes, start, end + 1);
    return FrameFileResponse(
      statusCode: 206,
      headers: {
        'content-type': 'application/epub+zip',
        'content-length': body.length.toString(),
        'content-range':
            'bytes $start-$end/' + bytes.length.toString(),
        'accept-ranges': 'bytes',
      },
      stream: Stream<List<int>>.value(body),
      onClose: () {},
      requestedRange: range,
    );
  }
}

class _FakeApi implements FrameApiClient {
  _FakeApi({
    Map<String, dynamic>? state,
    List<dynamic>? annotations,
  })  : state = state ?? {},
        annotations = annotations ?? [];

  Map<String, dynamic> state;
  List<dynamic> annotations;
  Future<Map<String, dynamic>> Function()? annotationsLoader;
  Map<String, dynamic>? postedState;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (Uri.parse(path).path == '/api/reading/state') {
      return {'state': state};
    }
    if (Uri.parse(path).path == '/api/reading/annotations') {
      final loader = annotationsLoader;
      if (loader != null) return await loader();
      return {'annotations': annotations};
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path == '/api/reading/state') {
      postedState = Map<String, dynamic>.from(body['state'] as Map);
      state = postedState!;
      return {'state': state};
    }
    throw StateError('Unexpected POST $path');
  }

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      {'ok': true};

  @override
  Future<Uint8List> getBytes(String path) async => Uint8List(0);

  @override
  void close() {}
}

FrameBook _book(int size) => FrameBook.fromJson({
      'id': 'epub-session-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/session.epub',
      'fileName': 'session.epub',
      'title': 'Session test',
      'author': 'FRAME',
      'format': 'EPUB',
      'shelf': 'books',
      'size': size,
    });

Uint8List _zipFixture({
  bool fixedLayout = false,
}) {
  const container = '''
<container>
  <rootfiles>
    <rootfile full-path="OPS/book.opf"
      media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';
  final fixedMeta = fixedLayout
      ? '<meta property="rendition:layout">pre-paginated</meta>'
      : '';
  final package = '''
<package xmlns="http://www.idpf.org/2007/opf"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         version="3.0" unique-identifier="uid">
  <metadata>
    <dc:identifier id="uid">urn:uuid:session-test</dc:identifier>
    <dc:title>Session test</dc:title>
    <dc:language>zh-TW</dc:language>
    $fixedMeta
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"
      properties="nav"/>
    <item id="one" href="Text/chapter-one.xhtml"
      media-type="application/xhtml+xml"/>
    <item id="two" href="Text/chapter-two.xhtml"
      media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref id="ref-one" idref="one"/>
    <itemref id="ref-two" idref="two"/>
  </spine>
</package>
''';
  const navigation = '''
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <body>
    <nav epub:type="toc">
      <ol>
        <li><a href="Text/chapter-one.xhtml#start">第一章</a></li>
        <li><a href="Text/chapter-two.xhtml#part-two">第二章</a></li>
      </ol>
    </nav>
  </body>
</html>
''';
  const chapterOne = '''
<html xmlns="http://www.w3.org/1999/xhtml">
  <body><h1 id="start">第一章</h1><p>章節一內容。</p></body>
</html>
''';
  const chapterTwo = '''
<html xmlns="http://www.w3.org/1999/xhtml">
  <body><h1 id="part-two">第二章</h1><p>章節二內容。</p></body>
</html>
''';

  final items = [
    _ZipItem('mimetype', utf8.encode('application/epub+zip')),
    _ZipItem('META-INF/container.xml', utf8.encode(container)),
    _ZipItem('OPS/book.opf', utf8.encode(package)),
    _ZipItem('OPS/nav.xhtml', utf8.encode(navigation)),
    _ZipItem('OPS/Text/chapter-one.xhtml', utf8.encode(chapterOne)),
    _ZipItem('OPS/Text/chapter-two.xhtml', utf8.encode(chapterTwo)),
    // Keep the archive larger than its ZIP tail metadata window so the test
    // can prove that opening never requests the complete small fixture.
    _ZipItem('OPS/unused-padding.bin', List<int>.filled(100000, 0x5a)),
  ];
  return _buildZip(items);
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
  test('bookmark lookup matches only the exact CFI and bookmark type', () {
    const annotations = [
      FrameReaderAnnotation(
        id: 'bookmark-one',
        bookId: 'book-one',
        type: 'bookmark',
        cfi: 'epubcfi(/6/2!/4/2:3)',
      ),
      FrameReaderAnnotation(
        id: 'highlight-one',
        bookId: 'book-one',
        type: 'highlight',
        cfi: 'epubcfi(/6/2!/4/2:3)',
      ),
      FrameReaderAnnotation(
        id: 'bookmark-other',
        bookId: 'book-one',
        type: 'bookmark',
        cfi: 'epubcfi(/6/2!/4/2:8)',
      ),
    ];

    expect(
      findFrameBookmarkAtCfi(annotations, 'epubcfi(/6/2!/4/2:3)')?.id,
      'bookmark-one',
    );
    expect(
      findFrameBookmarkAtCfi(annotations, 'epubcfi(/6/2!/4/2:8)')?.id,
      'bookmark-other',
    );
    expect(findFrameBookmarkAtCfi(annotations, 'epubcfi(/6/2!/4/2:4)'), isNull);
    expect(findFrameBookmarkAtCfi(annotations, '  '), isNull);
  });
  group('FrameEpubReaderSession', () {
    test('opens through bounded ranges and restores the saved spine index',
        () async {
      final fixture = _zipFixture();
      final source = _MemoryFrameFileSource(fixture);
      final api = _FakeApi(
        state: {
          'progress': {
            'percent': 50,
            'label': '第二章',
            'index': 1,
            'cfi': 'epubcfi(/6/4)',
          },
          'appearance': {'theme': 'sepia'},
        },
      );
      final session = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: source,
        repository: FrameReaderRepository(api),
      );

      await session.open();
      expect(session.status, FrameEpubReaderStatus.ready);
      expect(session.epub?.metadata.title, 'Session test');
      expect(session.currentSpineIndex, 1);
      expect(
        session.currentChapter?.resource.path,
        'OPS/Text/chapter-two.xhtml',
      );
      expect(session.readerState.appearance['theme'], 'sepia');
      expect(source.requests, isNotEmpty);
      expect(
        source.requests.any((range) => range.$2 - range.$1 + 1 == fixture.length),
        isFalse,
      );
      await session.close();
    });

    test('refreshes bookmarks and notes from the existing annotations API',
        () async {
      final fixture = _zipFixture();
      final api = _FakeApi();
      final session = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: _MemoryFrameFileSource(fixture),
        repository: FrameReaderRepository(api),
      );

      await session.open();
      expect(session.annotations, isEmpty);

      api.annotations = [
        {
          'id': 'remote-bookmark',
          'bookId': 'epub-session-test',
          'type': 'bookmark',
          'cfi': 'epubcfi(/6/2!/4/2:3)',
          'color': 'violet',
          'createdAt': 10,
        },
        {
          'id': 'remote-note',
          'bookId': 'epub-session-test',
          'type': 'note',
          'cfi': 'epubcfi(/6/2!/4/2:8)',
          'quote': '遠端摘錄',
          'text': '另一台裝置新增的筆記',
          'color': 'violet',
          'createdAt': 11,
        },
      ];

      await session.refreshAnnotations();

      expect(
        session.annotations.map((item) => item.id),
        containsAll(['remote-bookmark', 'remote-note']),
      );
      expect(
        session.annotations
            .firstWhere((item) => item.id == 'remote-note')
            .quote,
        '遠端摘錄',
      );
      await session.close();
    });

    test('discards a pending refresh after a local annotation deletion',
        () async {
      final fixture = _zipFixture();
      final api = _FakeApi(
        annotations: [
          {
            'id': 'local-note',
            'bookId': 'epub-session-test',
            'type': 'note',
            'cfi': 'epubcfi(/6/2!/4/2:3)',
            'quote': '原文',
            'text': '舊筆記',
            'color': 'violet',
            'createdAt': 10,
          },
        ],
      );
      final session = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: _MemoryFrameFileSource(fixture),
        repository: FrameReaderRepository(api),
      );
      await session.open();
      expect(session.annotations, hasLength(1));

      final pendingResponse = Completer<Map<String, dynamic>>();
      api.annotationsLoader = () => pendingResponse.future;
      final refresh = session.refreshAnnotations();
      await Future<void>.delayed(Duration.zero);

      await session.deleteAnnotation('local-note');
      pendingResponse.complete({
        'annotations': [
          {
            'id': 'local-note',
            'bookId': 'epub-session-test',
            'type': 'note',
            'cfi': 'epubcfi(/6/2!/4/2:3)',
            'quote': '原文',
            'text': '舊筆記',
            'color': 'violet',
            'createdAt': 10,
          },
          {
            'id': 'stale-remote-note',
            'bookId': 'epub-session-test',
            'type': 'note',
            'cfi': 'epubcfi(/6/2!/4/2:8)',
            'quote': '另一段',
            'text': '過期回應',
            'color': 'violet',
            'createdAt': 11,
          },
        ],
      });
      await refresh;

      expect(session.annotations, isEmpty);
      await session.close();
    });

    test('keeps the newest overlapping annotation refresh response',
        () async {
      final fixture = _zipFixture();
      final api = _FakeApi();
      final session = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: _MemoryFrameFileSource(fixture),
        repository: FrameReaderRepository(api),
      );
      await session.open();

      final olderResponse = Completer<Map<String, dynamic>>();
      final newerResponse = Completer<Map<String, dynamic>>();
      var requestIndex = 0;
      api.annotationsLoader = () {
        requestIndex++;
        return requestIndex == 1
            ? olderResponse.future
            : newerResponse.future;
      };

      final olderRefresh = session.refreshAnnotations();
      await Future<void>.delayed(Duration.zero);
      final newerRefresh = session.refreshAnnotations();
      await Future<void>.delayed(Duration.zero);

      newerResponse.complete({
        'annotations': [
          {
            'id': 'newest-note',
            'bookId': 'epub-session-test',
            'type': 'note',
            'cfi': 'epubcfi(/6/2!/4/2:8)',
            'quote': '新引文',
            'text': '最新結果',
            'color': 'violet',
            'createdAt': 20,
          },
        ],
      });
      await newerRefresh;

      olderResponse.complete({
        'annotations': [
          {
            'id': 'older-note',
            'bookId': 'epub-session-test',
            'type': 'note',
            'cfi': 'epubcfi(/6/2!/4/2:3)',
            'quote': '舊引文',
            'text': '較舊結果',
            'color': 'violet',
            'createdAt': 10,
          },
        ],
      });
      await olderRefresh;

      expect(session.annotations.map((item) => item.id), ['newest-note']);
      await session.close();
    });

    test('TOC navigation loads the target chapter and saves compatible progress',
        () async {
      final fixture = _zipFixture();
      final source = _MemoryFrameFileSource(fixture);
      final api = _FakeApi();
      final session = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: source,
        repository: FrameReaderRepository(api),
      );

      await session.open();
      expect(session.toc, hasLength(2));
      expect(await session.goToTocEntry(session.toc[1]), isTrue);
      expect(session.currentSpineIndex, 1);
      expect(session.currentFragment, 'part-two');
      expect(
        session.currentChapter?.resource.path,
        'OPS/Text/chapter-two.xhtml',
      );

      final progress = api.postedState!['progress'] as Map;
      expect(progress['index'], 1);
      expect(progress['label'], '第二章');
      expect(progress['percent'], 50);
      expect(progress['cfi'], '');
      await session.close();
    });

    test('restores a saved CFI before falling back to the chapter index',
        () async {
      final fixture = _zipFixture();
      final source = _MemoryFrameFileSource(fixture);
      final initialApi = _FakeApi();
      final initialSession = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: source,
        repository: FrameReaderRepository(initialApi),
      );

      await initialSession.open();
      expect(await initialSession.goToTocEntry(initialSession.toc[1]), isTrue);
      final heading = initialSession.currentChapter!.document.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'h1');
      final textNode = heading.descendants.whereType<XmlText>().first;
      final cfi = FrameEpubCfi.create(
        book: initialSession.epub!,
        spineIndex: 1,
        textNode: textNode,
        offset: 2,
      );
      expect(cfi, isNotNull);
      await initialSession.close();

      final restoredApi = _FakeApi(
        state: {
          'progress': {
            'percent': 48,
            'label': '第二章',
            'index': 0,
            'cfi': cfi,
          },
        },
      );
      final restoredSession = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: _MemoryFrameFileSource(fixture),
        repository: FrameReaderRepository(restoredApi),
      );

      await restoredSession.open();
      expect(restoredSession.currentSpineIndex, 1);
      expect(restoredSession.initialCfi, cfi);
      expect(restoredSession.initialAnchor?.name.local, 'h1');
      expect(restoredSession.initialScrollFraction, isNotNull);
      expect(restoredSession.initialScrollFraction, greaterThan(0));
      await restoredSession.close();
    });

    test('jumps to a saved annotation CFI in another spine item', () async {
      final fixture = _zipFixture();
      final api = _FakeApi();
      final session = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: _MemoryFrameFileSource(fixture),
        repository: FrameReaderRepository(api),
      );

      await session.open();
      expect(await session.goToSpineIndex(1), isTrue);
      final chapter = session.currentChapter!;
      final paragraph = chapter.document.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'p');
      final textNode = paragraph.descendants.whereType<XmlText>().first;
      final targetCfi = FrameEpubCfi.create(
        book: session.epub!,
        spineIndex: 1,
        textNode: textNode,
        offset: 2,
      )!;
      expect(await session.goToSpineIndex(0), isTrue);

      expect(await session.goToCfi(targetCfi), isTrue);
      expect(session.currentSpineIndex, 1);
      expect(session.initialCfi, targetCfi);
      expect(session.initialAnchor?.name.local, 'p');
      final savedProgress = api.postedState!['progress'] as Map;
      expect(savedProgress['cfi'], targetCfi);
      expect(savedProgress['index'], 1);

      await session.close();
    });

    testWidgets(
        'restores a chapter-two annotation only in its own spine item',
        (tester) async {
      final fixture = _zipFixture();
      final session = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: _MemoryFrameFileSource(fixture),
        repository: FrameReaderRepository(_FakeApi()),
      );

      await session.open();
      expect(session.currentSpineIndex, 0);
      expect(await session.goToSpineIndex(1), isTrue);

      final chapterTwo = session.currentChapter!;
      final targetNode = chapterTwo.document.descendants
          .whereType<XmlText>()
          .firstWhere((node) => node.value == '章節二內容。');
      final targetCfi = FrameEpubCfi.createRange(
        book: session.epub!,
        spineIndex: 1,
        startNode: targetNode,
        startOffset: 0,
        endNode: targetNode,
        endOffset: targetNode.value.length,
      )!;

      final annotation = FrameReaderAnnotation(
        id: 'chapter-two-highlight',
        bookId: session.book.id,
        type: 'highlight',
        cfi: targetCfi,
        quote: targetNode.value,
        color: 'mint',
        createdAt: 20,
      );
      final annotations = [annotation];

      Widget chapterView() {
        final index = session.currentSpineIndex!;
        return MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: FrameEpubChapterView(
                key: ValueKey(index),
                chapter: session.currentChapter!,
                resourceLoader: session.resourceLoader!,
                annotations: annotations,
                spineIndex: index,
              ),
            ),
          ),
        );
      }

      List<TextSpan> renderedSpans(WidgetTester tester) {
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
        return spans;
      }

      try {
        expect(await session.goToSpineIndex(0), isTrue);
        await tester.pumpWidget(chapterView());
        await tester.pumpAndSettle();

        expect(find.textContaining('章節一內容。'), findsOneWidget);
        expect(
          renderedSpans(tester).where(
            (span) =>
                span.style?.backgroundColor != null ||
                span.style?.decoration != null,
          ),
          isEmpty,
        );

        expect(await session.goToSpineIndex(1), isTrue);
        await tester.pumpWidget(chapterView());
        await tester.pumpAndSettle();

        final restored = renderedSpans(tester).firstWhere(
          (span) => span.text == '章節二內容。',
        );
        expect(
          restored.style?.backgroundColor,
          const Color(0x6665C9A5),
        );
      } finally {
        await session.close();
      }
    });

    test('does not fetch external links or route them into the archive',
        () async {
      final fixture = _zipFixture();
      final source = _MemoryFrameFileSource(fixture);
      final session = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: source,
        repository: FrameReaderRepository(_FakeApi()),
      );

      await session.open();
      expect(
        await session.goToHref('https://example.com/remote.xhtml'),
        isFalse,
      );
      expect(session.currentSpineIndex, 0);
      await session.close();
    });

    test('uses EPUB rendition metadata for fixed-layout comics', () async {
      final fixture = _zipFixture(fixedLayout: true);
      final session = FrameEpubReaderSession(
        book: _book(fixture.length),
        fileSource: _MemoryFrameFileSource(fixture),
        repository: FrameReaderRepository(_FakeApi()),
      );

      await session.open();
      expect(session.isFixedLayout, isTrue);
      expect(session.epub?.layout, FrameEpubLayout.prePaginated);
      await session.close();
    });
  });
}
