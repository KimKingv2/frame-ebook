import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

typedef FrameStatsSaveFile = Future<Uri?> Function({
  required Uint8List bytes,
  required String fileName,
});

class FrameStatsExportService {
  FrameStatsExportService({FrameStatsSaveFile? saveFile})
      : _saveFile = saveFile ?? _saveWithSystemDialog;

  final FrameStatsSaveFile _saveFile;

  Future<bool> save({
    required Uint8List bytes,
    required String fileName,
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', '匯出內容不可為空。');
    }
    if (fileName.trim().isEmpty ||
        fileName.contains('/') ||
        fileName.contains('\\') ||
        !(fileName.endsWith('.json') || fileName.endsWith('.csv'))) {
      throw ArgumentError.value(fileName, 'fileName', '匯出檔名無效。');
    }
    return await _saveFile(bytes: bytes, fileName: fileName) != null;
  }

  static Future<Uri?> _saveWithSystemDialog({
    required Uint8List bytes,
    required String fileName,
  }) {
    return FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
    );
  }
}
