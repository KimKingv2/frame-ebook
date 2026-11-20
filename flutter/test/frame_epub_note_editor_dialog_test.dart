import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_note_editor_dialog.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('editing a note offers a delete action with quote context',
      (tester) async {
    Future<FrameEpubNoteEditorResult?>? resultFuture;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                resultFuture = showDialog<FrameEpubNoteEditorResult>(
                  context: context,
                  builder: (_) => const FrameEpubNoteEditorDialog(
                    quote: '這是原文引用。',
                    initialText: '既有筆記',
                    isEditing: true,
                  ),
                );
              },
              child: const Text('開啟'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('開啟'));
    await tester.pumpAndSettle();

    expect(find.text('編輯閱讀筆記'), findsOneWidget);
    expect(find.text('這是原文引用。'), findsOneWidget);
    expect(find.text('刪除筆記'), findsOneWidget);

    await tester.tap(find.text('刪除筆記'));
    await tester.pumpAndSettle();

    final result = await resultFuture!;
    expect(result?.action, FrameEpubNoteEditorAction.delete);
    expect(result?.text, isNull);
  });

  testWidgets('creating a note hides delete and returns entered text',
      (tester) async {
    Future<FrameEpubNoteEditorResult?>? resultFuture;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                resultFuture = showDialog<FrameEpubNoteEditorResult>(
                  context: context,
                  builder: (_) => const FrameEpubNoteEditorDialog(
                    quote: '新選取的文字。',
                    initialText: '',
                    isEditing: false,
                  ),
                );
              },
              child: const Text('開啟'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('開啟'));
    await tester.pumpAndSettle();

    expect(find.text('新增閱讀筆記'), findsOneWidget);
    expect(find.text('刪除筆記'), findsNothing);
    await tester.enterText(find.byType(TextField), '  新筆記內容  ');
    await tester.tap(find.text('保存筆記'));
    await tester.pumpAndSettle();

    final result = await resultFuture!;
    expect(result?.action, FrameEpubNoteEditorAction.save);
    expect(result?.text, '  新筆記內容  ');
  });
}
