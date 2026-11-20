import 'dart:typed_data';

import 'package:public_file_saver/public_file_saver.dart';

typedef FrameStatsSaveBytes = Future<bool?> Function({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
});

class FrameStatsExportService {
  FrameStatsExportService({FrameStatsSaveBytes? saveBytes})
      : _saveBytes = saveBytes ?? _saveWithSystemDialog;

  final FrameStatsSaveBytes _saveBytes;

  Future<bool> save({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', '匯出內容不可為空。');
    }
    if (fileName.trim().isEmpty ||
        fileName.contains('/') ||
        fileName.contains('\\')) {
      throw ArgumentError.value(fileName, 'fileName', '匯出檔名無效。');
    }
    if (!const {'application/json', 'text/csv'}.contains(mimeType)) {
      throw ArgumentError.value(mimeType, 'mimeType', '不支援的統計匯出格式。');
    }
    return await _saveBytes(
          bytes: bytes,
          fileName: fileName,
          mimeType: mimeType,
        ) ??
        false;
  }

  static Future<bool?> _saveWithSystemDialog({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    final result = await PublicFileSaver().save(
      useDialog: true,
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
    );
    return result?.isSuccess == true;
  }
}
