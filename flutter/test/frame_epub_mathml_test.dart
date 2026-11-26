import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_mathml.dart';
import 'package:xml/xml.dart';

Widget _host(String markup) {
  final document = XmlDocument.parse(markup);
  final formula = document.rootElement;
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: FrameEpubMathMl(
          element: formula,
          textStyle: const TextStyle(
            color: Color(0xFF26222D),
            fontSize: 20,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders fractions, roots and subscript/superscript tokens',
      (tester) async {
    await tester.pumpWidget(_host('''
      <math xmlns="http://www.w3.org/1998/Math/MathML">
        <mrow>
          <msubsup>
            <mi>x</mi><mi>i</mi><mn>2</mn>
          </msubsup>
          <mo>=</mo>
          <mfrac>
            <mn>1</mn>
            <msqrt><mn>2</mn></msqrt>
          </mfrac>
        </mrow>
      </math>
    '''));

    expect(find.text('x'), findsOneWidget);
    expect(find.text('i'), findsOneWidget);
    expect(find.text('2'), findsNWidgets(2));
    expect(find.text('='), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('√'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders fenced groups, limits and a small MathML table',
      (tester) async {
    await tester.pumpWidget(_host('''
      <math xmlns="http://www.w3.org/1998/Math/MathML">
        <mrow>
          <mfenced open="[" close="]" separators=";">
            <mi>a</mi><mi>b</mi>
          </mfenced>
          <mover><mi>x</mi><mo>¯</mo></mover>
          <munder><mo>∑</mo><mi>i</mi></munder>
          <mtable>
            <mtr><mtd><mn>1</mn></mtd><mtd><mn>2</mn></mtd></mtr>
            <mtr><mtd><mn>3</mn></mtd><mtd><mn>4</mn></mtd></mtr>
          </mtable>
        </mrow>
      </math>
    '''));

    for (final value in ['[', ']', ';', 'a', 'b', 'x', '¯', '∑', 'i', '1', '2', '3', '4']) {
      expect(find.text(value), findsWidgets, reason: 'Missing MathML token: $value');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not render annotation payloads or linked markup',
      (tester) async {
    await tester.pumpWidget(_host('''
      <math xmlns="http://www.w3.org/1998/Math/MathML">
        <semantics>
          <mrow><mi>x</mi><mo>+</mo><mn>1</mn></mrow>
          <annotation encoding="application/x-tex">SHOULD_NOT_RENDER</annotation>
          <annotation-xml encoding="application/xhtml+xml">
            <img src="https://example.invalid/tracker.png"/>
          </annotation-xml>
        </semantics>
      </math>
    '''));

    expect(find.text('x'), findsOneWidget);
    expect(find.text('+'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('SHOULD_NOT_RENDER'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses a readable fallback when the MathML tree exceeds its budget',
      (tester) async {
    final tokens = List<String>.filled(520, '<mi>x</mi>').join();
    await tester.pumpWidget(_host('''
      <math xmlns="http://www.w3.org/1998/Math/MathML"><mrow>$tokens</mrow></math>
    '''));

    expect(find.text('數學公式過於複雜，暫時無法顯示'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
