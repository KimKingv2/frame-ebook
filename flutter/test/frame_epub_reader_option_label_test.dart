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

  testWidgets('dropdown selected value and popup options stay visible',
      (tester) async {
    const foreground = Color(0xFFE9E2F4);
    const disabledForeground = Color(0xFF777777);
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
        home: Scaffold(
          body: Center(
            child: DropdownButton<String>(
              value: 'standard',
              dropdownColor: Color(0xFF211C2C),
              style: const TextStyle(
                color: disabledForeground,
                fontFamily: 'Georgia',
                fontSize: 13,
              ),
              items: const [
                DropdownMenuItem<String>(
                  value: 'small',
                  child: FrameEpubReaderOptionLabel(
                    label: '偏小',
                    color: foreground,
                    fontSize: 11,
                  ),
                ),
                DropdownMenuItem<String>(
                  value: 'standard',
                  child: FrameEpubReaderOptionLabel(
                    label: '標準',
                    color: foreground,
                    fontSize: 11,
                  ),
                ),
                DropdownMenuItem<String>(
                  value: 'large',
                  child: FrameEpubReaderOptionLabel(
                    label: '稍大',
                    color: foreground,
                    fontSize: 11,
                  ),
                ),
              ],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    final selected = tester.widget<Text>(find.text('標準'));
    expect(selected.style?.color, foreground);
    expect(selected.style?.fontFamily, 'NotoSansTC');
    expect(tester.getSize(find.text('標準')).height, greaterThan(0));

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();

    final popupOption = tester.widget<Text>(find.text('稍大'));
    expect(popupOption.style?.color, foreground);
    expect(popupOption.style?.fontFamily, 'NotoSansTC');
    expect(tester.getSize(find.text('稍大')).height, greaterThan(0));
  });
  });
}
