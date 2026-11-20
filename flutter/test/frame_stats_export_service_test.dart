import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/stats/frame_stats_export_service.dart';

void main() {
  test('saves statistics bytes through the injected system-dialog adapter', () async {
    Uint8List? receivedBytes;
    String? receivedName;
    String? receivedMime;

    final exporter = FrameStatsExportService(
      saveBytes: ({
        required Uint8List bytes,
        required String fileName,
        required String mimeType,
      }) async {
        receivedBytes = bytes;
        receivedName = fileName;
        receivedMime = mimeType;
        return true;
      },
    );
    final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x41, 0x42]);

    final saved = await exporter.save(
      bytes: bytes,
      fileName: 'frame-ebook-reading-2026-11-01-2026-11-20.csv',
      mimeType: 'text/csv',
    );

    expect(saved, isTrue);
    expect(receivedBytes, bytes);
    expect(receivedName, 'frame-ebook-reading-2026-11-01-2026-11-20.csv');
    expect(receivedMime, 'text/csv');
  });

  test('reports user cancellation without claiming a successful save', () async {
    final exporter = FrameStatsExportService(
      saveBytes: ({
        required Uint8List bytes,
        required String fileName,
        required String mimeType,
      }) async =>
          null,
    );

    final saved = await exporter.save(
      bytes: Uint8List.fromList([1, 2, 3]),
      fileName: 'reading.json',
      mimeType: 'application/json',
    );

    expect(saved, isFalse);
  });

  test('rejects empty content, unsafe names and unsupported export types', () async {
    final exporter = FrameStatsExportService(
      saveBytes: ({
        required Uint8List bytes,
        required String fileName,
        required String mimeType,
      }) async =>
          true,
    );

    await expectLater(
      exporter.save(
        bytes: Uint8List(0),
        fileName: 'reading.json',
        mimeType: 'application/json',
      ),
      throwsArgumentError,
    );
    await expectLater(
      exporter.save(
        bytes: Uint8List.fromList([1]),
        fileName: '../reading.json',
        mimeType: 'application/json',
      ),
      throwsArgumentError,
    );
    await expectLater(
      exporter.save(
        bytes: Uint8List.fromList([1]),
        fileName: 'reading.txt',
        mimeType: 'text/plain',
      ),
      throwsArgumentError,
    );
  });
}
