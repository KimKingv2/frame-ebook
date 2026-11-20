import 'package:material_ui/material_ui.dart';

enum FrameEpubNoteEditorAction { save, delete }

typedef FrameEpubNoteEditorResult = ({
  FrameEpubNoteEditorAction action,
  String? text,
});

class FrameEpubNoteEditorDialog extends StatefulWidget {
  const FrameEpubNoteEditorDialog({
    required this.quote,
    required this.initialText,
    required this.isEditing,
    super.key,
  });

  final String quote;
  final String initialText;
  final bool isEditing;

  @override
  State<FrameEpubNoteEditorDialog> createState() =>
      _FrameEpubNoteEditorDialogState();
}

class _FrameEpubNoteEditorDialogState
    extends State<FrameEpubNoteEditorDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xFF211C2B),
        title: Text(
          widget.isEditing ? '編輯閱讀筆記' : '新增閱讀筆記',
          style: const TextStyle(
            color: Color(0xFFEDE7F7),
            fontSize: 17,
          ),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.quote.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x332B2635),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      widget.quote,
                      style: const TextStyle(
                        color: Color(0xFFB7ADC7),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 4,
                maxLines: 9,
                maxLength: 20000,
                style: const TextStyle(
                  color: Color(0xFFEDE7F7),
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: '記下你的想法、解讀或補充資料……',
                  hintStyle: const TextStyle(color: Color(0xFFB7ADC7)),
                  filled: true,
                  fillColor: const Color(0x332B2635),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (widget.isEditing)
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE88EAF),
              ),
              onPressed: () => Navigator.of(context).pop((
                action: FrameEpubNoteEditorAction.delete,
                text: null,
              )),
              child: const Text('刪除筆記'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop((
              action: FrameEpubNoteEditorAction.save,
              text: _controller.text,
            )),
            child: const Text('保存筆記'),
          ),
        ],
      );
}
