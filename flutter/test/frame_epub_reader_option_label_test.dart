import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:frame_ebook/reader/frame_epub_reader_option_label.dart';

void main() {
  testWidgets('appearance option text has an explicit visible font and color',
      (tester) async {
    const foreground = Color(0xFFE9E2F4);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          textTheme: const TextTheme(
            labelLarge: TextStyle(
              color: Colors.transparent,
              fontFamily: 'Georgia',
            ),
          ),
        ),
        home: const Scaffold(
          body: Center(
            child: OutlinedButton(
              onPressed: null,
              child: FrameEpubReaderOptionLabel(
                label: '標準',
                color: foreground,
                fontSize: 11,
              ),
            ),
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('標準'));
    expect(label.style?.color, foreground);
    expect(label.style?.fontFamily, 'NotoSansTC');
    expect(label.style?.fontSize, 11);
  });
}
