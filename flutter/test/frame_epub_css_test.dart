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

    test('keeps unsupported selectors from matching arbitrary elements', () {
      final cascade = FrameEpubCssCascade.fromStylesheets([
        'p:unsupported-state { color: red; }',
      ]);
      final element = XmlDocument.parse('<p>text</p>').rootElement;

      expect(cascade.resolve(element)['color'], isNot('red'));
    });
  });
}
