import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/main.dart';

void main() {
  testWidgets('renders the FRAME Ebook transport lab', (tester) async {
    await tester.pumpWidget(const FrameEbookTransportLab());

    expect(find.text('直連測試'), findsOneWidget);
    expect(find.text('302 / RANGE LAB'), findsOneWidget);
    expect(find.text('執行 1 KB Range 測試'), findsOneWidget);
  });
}
