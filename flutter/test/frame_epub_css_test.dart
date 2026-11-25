import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_css.dart';
import 'package:xml/xml.dart';

void main() {
  group('FrameEpubCssCascade', () {
    test('applies selector specificity and descendant/child combinators', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        '''
        p { color: red; }
        .chapter p { color: blue; }
        article > p.lead:first-child { color: #123456; font-size: 22px; }
        ''',
      ]);
      final document = XmlDocument.parse('''
        <html>
          <body>
            <article class="chapter">
              <p class="lead">first</p>
              <section><p id="nested">nested</p></section>
            </article>
          </body>
        </html>
      ''');
      final paragraphs =
          document.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p').toList();

      final first = cascade.resolve(paragraphs[0]);
      final nested = cascade.resolve(paragraphs[1]);

      expect(first['color'], '#123456');
      expect(first['font-size'], '22px');
      expect(nested['color'], 'blue');
    });

    test('inherits typography and allows inline declarations to override rules', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        'body { color: #445566; font-size: 20px; line-height: 1.6; }'
        'p { color: red; }',
      ]);
      final document = XmlDocument.parse(
        '<html><body><p style="color: purple; letter-spacing: 1px">text</p></body></html>',
      );
      final body = document.descendants.whereType<XmlElement>().firstWhere(
            (element) => element.name.local == 'body',
          );
      final paragraph = document.descendants.whereType<XmlElement>().firstWhere(
            (element) => element.name.local == 'p',
          );
      final bodyStyle = cascade.resolve(body);
      final paragraphStyle = cascade.resolve(
        paragraph,
        parentStyle: bodyStyle,
        inlineStyle: paragraph.getAttribute('style'),
      );

      expect(paragraphStyle['color'], 'purple');
      expect(paragraphStyle['font-size'], '20px');
      expect(paragraphStyle['line-height'], '1.6');
      expect(paragraphStyle['letter-spacing'], '1px');
    });

    test('inherits overflow-wrap and word-break rules', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        'body { overflow-wrap: anywhere; word-break: break-all; }',
        'p { overflow-wrap: break-word; }',
      ]);
      final document = XmlDocument.parse(
        '<body><p><span>long-token</span></p></body>',
      );
      final body = document.rootElement;
      final paragraph = body.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'p');
      final span = paragraph.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'span');

      final bodyStyle = cascade.resolve(body);
      final paragraphStyle = cascade.resolve(
        paragraph,
        parentStyle: bodyStyle,
      );
      final spanStyle = cascade.resolve(
        span,
        parentStyle: paragraphStyle,
      );

      expect(paragraphStyle['overflow-wrap'], 'break-word');
      expect(spanStyle['overflow-wrap'], 'break-word');
      expect(spanStyle['word-break'], 'break-all');
    });

    test('important declarations outrank non-important inline styles', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        '#target { color: blue !important; }',
        'p { color: green; }',
      ]);
      final element = XmlDocument.parse(
        '<p id="target" style="color: red">text</p>',
      ).rootElement;

      final style = cascade.resolve(
        element,
        inlineStyle: element.getAttribute('style'),
      );

      expect(style['color'], 'blue');
    });

    test('supports attributes, nth-child and media filtering', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        '''
        p[data-kind="caption"] { font-style: italic; }
        li:nth-child(2) { color: purple; }
        @media print { p { color: red; } }
        @media screen { p { text-align: center; } }
        ''',
      ]);
      final document = XmlDocument.parse('''
        <root>
          <p data-kind="caption">caption</p>
          <ul><li>one</li><li>two</li></ul>
        </root>
      ''');
      final elements = document.descendants.whereType<XmlElement>().toList();
      final paragraph = elements.firstWhere((e) => e.name.local == 'p');
      final secondItem =
          elements.where((e) => e.name.local == 'li').last;

      final paragraphStyle = cascade.resolve(paragraph);
      final itemStyle = cascade.resolve(secondItem);

      expect(paragraphStyle['font-style'], 'italic');
      expect(paragraphStyle['text-align'], 'center');
      expect(paragraphStyle['color'], isNot('red'));
      expect(itemStyle['color'], 'purple');
    });

    test('applies semantic superscript and subscript defaults and inheritance',
        () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        'body { font-size: 20px; }',
        'sup { color: purple; }',
      ]);
      final document = XmlDocument.parse(
        '<body><p>H<sub>2</sub>O and x<sup><span>3</span></sup></p></body>',
      );
      final body = document.rootElement;
      final paragraph = body.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'p');
      final subscript = paragraph.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'sub');
      final superscript = paragraph.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'sup');
      final nestedSpan = superscript.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == 'span');

      final bodyStyle = cascade.resolve(body);
      final paragraphStyle =
          cascade.resolve(paragraph, parentStyle: bodyStyle);
      final subscriptStyle =
          cascade.resolve(subscript, parentStyle: paragraphStyle);
      final superscriptStyle =
          cascade.resolve(superscript, parentStyle: paragraphStyle);
      final nestedStyle =
          cascade.resolve(nestedSpan, parentStyle: superscriptStyle);

      expect(subscriptStyle['font-variant-position'], 'sub');
      expect(superscriptStyle['font-variant-position'], 'super');
      expect(subscriptStyle['font-size'], 'smaller');
      expect(superscriptStyle['font-size'], 'smaller');
      expect(nestedStyle['font-variant-position'], 'super');
      expect(superscriptStyle['color'], 'purple');
    });

    test('uses a compact default font size for ruby annotations', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        'rt { color: purple; }',
      ]);
      final document = XmlDocument.parse(
        '<ruby>漢字<rt>かんじ</rt></ruby>',
      );
      final ruby = document.rootElement;
      final rt = ruby.children.whereType<XmlElement>().firstWhere(
            (element) => element.name.local == 'rt',
          );

      final rubyStyle = cascade.resolve(ruby);
      final annotationStyle = cascade.resolve(rt, parentStyle: rubyStyle);

      expect(annotationStyle['font-size'], '50%');
      expect(annotationStyle['line-height'], 'normal');
      expect(annotationStyle['color'], 'purple');
    });

    test('inherits ruby layout properties and applies ruby defaults', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        'body { ruby-align: start; ruby-position: under; ruby-overhang: none; }',
      ]);
      final document = XmlDocument.parse(
        '<body><ruby><rb>漢字</rb><rt>かんじ</rt></ruby></body>',
      );
      final body = document.rootElement;
      final ruby = body.children.whereType<XmlElement>().first;
      final rt = ruby.descendants.whereType<XmlElement>().firstWhere(
            (element) => element.name.local == 'rt',
          );

      final bodyStyle = cascade.resolve(body);
      final rubyStyle = cascade.resolve(ruby, parentStyle: bodyStyle);
      final annotationStyle = cascade.resolve(rt, parentStyle: rubyStyle);

      expect(rubyStyle['ruby-align'], 'start');
      expect(rubyStyle['ruby-position'], 'under');
      expect(rubyStyle['ruby-overhang'], 'none');
      expect(annotationStyle['ruby-align'], 'start');
      expect(annotationStyle['ruby-position'], 'under');
      expect(annotationStyle['ruby-overhang'], 'none');
    });

    test('inherits list-style-type from the parent list', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        'ol { list-style-type: upper-alpha; }',
      ]);
      final document = XmlDocument.parse(
        '<ol><li><p>item</p></li></ol>',
      );
      final list = document.rootElement;
      final item = list.children.whereType<XmlElement>().first;
      final paragraph = item.descendants.whereType<XmlElement>().first;

      final listStyle = cascade.resolve(list);
      final itemStyle = cascade.resolve(item, parentStyle: listStyle);
      final paragraphStyle = cascade.resolve(
        paragraph,
        parentStyle: itemStyle,
      );

      expect(listStyle['list-style-type'], 'upper-alpha');
      expect(itemStyle['list-style-type'], 'upper-alpha');
      expect(paragraphStyle['list-style-type'], 'upper-alpha');
    });

    test('keeps unsupported selectors from matching arbitrary elements', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        'p:unsupported-state { color: red; }',
      ]);
      final element = XmlDocument.parse('<p>text</p>').rootElement;

      expect(cascade.resolve(element)['color'], isNot('red'));
    });
  });
}
