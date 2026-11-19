import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/reader/frame_zip_archive.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';

class _ZipItem {
  const _ZipItem(this.name, this.bytes, {this.deflate = false});

  final String name;
  final List<int> bytes;
  final bool deflate;
}

class _RangeRecord {
  const _RangeRecord(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;
}

class _MemoryFrameFileSource implements FrameFileSource {
  _MemoryFrameFileSource(this.bytes);

  final Uint8List bytes;
  final List<_RangeRecord> requests = [];

  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    final range = request.range;
    if (range == null) {
      throw StateError('ZIP archive reads must use explicit byte ranges.');
    }

    final suffix = range.suffixLength;
    final start = suffix == null ? range.start! : bytes.length - suffix;
    final requestedEnd = range.end ?? bytes.length - 1;
    final end = requestedEnd < bytes.length ? requestedEnd : bytes.length - 1;
    if (start < 0 || end < start) {
      throw RangeError('Invalid fixture range.');
    }

    requests.add(_RangeRecord(start, end));
    final body = Uint8List.sublistView(bytes, start, end + 1);
    return FrameFileResponse(
      statusCode: 206,
      headers: {
        'Content-Type': 'application/zip',
        'Content-Length': body.length.toString(),
        'Content-Range': 'bytes ' +
            start.toString() +
            '-' +
            end.toString() +
            '/' +
            bytes.length.toString(),
        'Accept-Ranges': 'bytes',
      },
      stream: Stream<List<int>>.value(body),
      onClose: () {},
      requestedRange: range,
    );
  }
}

FrameBook _book(int size) {
  return FrameBook.fromJson({
    'id': 'cbz-1',
    'provider': 'vps',
    'library': 'comics',
    'rootPath': '/Comics',
    'path': '/Comics/Volume01.cbz',
    'fileName': 'Volume01.cbz',
    'title': 'Volume 01',
    'author': '',
    'format': 'CBZ',
    'shelf': 'comics',
    'size': size,
  });
}

Uint8List _zipFixture(List<_ZipItem> items) {
  final output = <int>[];
  final central = <int>[];

  for (final item in items) {
    final name = utf8.encode(item.name);
    final plain = Uint8List.fromList(item.bytes);
    final compressed = item.deflate
        ? ZLibEncoder(raw: true).convert(plain)
        : plain;
    final method = item.deflate ? 8 : 0;
    final crc = _crc32(plain);
    final localOffset = output.length;

    _write32(output, 0x04034b50);
    _write16(output, 20);
    _write16(output, 0x0800);
    _write16(output, method);
    _write16(output, 0);
    _write16(output, 0);
    _write32(output, crc);
    _write32(output, compressed.length);
    _write32(output, plain.length);
    _write16(output, name.length);
    _write16(output, 0);
    output.addAll(name);
    output.addAll(compressed);

    _write32(central, 0x02014b50);
    _write16(central, 0x0314);
    _write16(central, 20);
    _write16(central, 0x0800);
    _write16(central, method);
    _write16(central, 0);
    _write16(central, 0);
    _write32(central, crc);
    _write32(central, compressed.length);
    _write32(central, plain.length);
    _write16(central, name.length);
    _write16(central, 0);
    _write16(central, 0);
    _write16(central, 0);
    _write16(central, 0);
    _write32(central, 0);
    _write32(central, localOffset);
    central.addAll(name);
  }

  final centralOffset = output.length;
  output.addAll(central);
  _write32(output, 0x06054b50);
  _write16(output, 0);
  _write16(output, 0);
  _write16(output, items.length);
  _write16(output, items.length);
  _write32(output, central.length);
  _write32(output, centralOffset);
  _write16(output, 0);

  return Uint8List.fromList(output);
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

void _write16(List<int> output, int value) {
  output
    ..add(value & 0xff)
    ..add((value >> 8) & 0xff);
}

void _write32(List<int> output, int value) {
  output
    ..add(value & 0xff)
    ..add((value >> 8) & 0xff)
    ..add((value >> 16) & 0xff)
    ..add((value >> 24) & 0xff);
}

void main() {
  group('FrameZipArchive', () {
    late Uint8List fixture;
    late _MemoryFrameFileSource source;
    late FrameZipArchive archive;

    setUp(() async {
      fixture = _zipFixture([
        _ZipItem('mimetype', 'application/epub+zip'.codeUnits),
        _ZipItem(
          'OEBPS/chapter.xhtml',
          '<html><body>FRAME EPUB range reader</body></html>'.codeUnits,
          deflate: true,
        ),
        const _ZipItem(
          'OEBPS/images/page-001.jpg',
          [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 5, 0xff, 0xd9],
        ),
        const _ZipItem('../unsafe.txt', [1, 2, 3]),
        _ZipItem('bulk/padding.bin', List<int>.filled(70000, 0x5a)),
      ]);
      source = _MemoryFrameFileSource(fixture);
      archive = await FrameZipArchive.open(
        source: source,
        book: _book(fixture.length),
      );
    });

    tearDown(() async {
      await archive.close();
    });

    test('indexes safe files through bounded ranges, not a full download', () {
      expect(
        archive.files.map((entry) => entry.path),
        containsAll([
          'mimetype',
          'OEBPS/chapter.xhtml',
          'OEBPS/images/page-001.jpg',
          'bulk/padding.bin',
        ]),
      );
      expect(
        archive.files.map((entry) => entry.path),
        isNot(contains('../unsafe.txt')),
      );
      expect(source.requests, isNotEmpty);
      expect(
        source.requests.any((range) => range.length == fixture.length),
        isFalse,
      );
    });

    test('streams a deflated EPUB XHTML entry and verifies its CRC', () async {
      final entry = archive.file('OEBPS/chapter.xhtml');
      expect(entry, isNotNull);

      final chunks = await archive.openRead(entry!).toList();
      final bytes = chunks.expand((chunk) => chunk).toList();

      expect(
        utf8.decode(bytes),
        '<html><body>FRAME EPUB range reader</body></html>',
      );
    });

    test('reads one CBZ page entry without materializing the archive', () async {
      final entry = archive.file('OEBPS/images/page-001.jpg');
      expect(entry, isNotNull);

      final bytes = await archive.readBytes(entry!, maxBytes: 1024);

      expect(bytes, [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 5, 0xff, 0xd9]);
      expect(
        source.requests.any((range) => range.length == fixture.length),
        isFalse,
      );
    });

    test('rejects unsafe paths', () async {
      final unsafe = archive.entries.firstWhere(
        (entry) => !entry.isSafePath,
      );
      expect(
        () => archive.openRead(unsafe),
        throwsA(isA<FrameZipArchiveException>()),
      );
      expect(archive.file(unsafe.path), isNull);
    });

    test('applies a decoded per-entry limit', () async {
      final entry = archive.file('OEBPS/chapter.xhtml')!;

      await expectLater(
        archive.readBytes(entry, maxBytes: 4),
        throwsA(isA<FrameZipArchiveException>()),
      );
    });
  });

  test('requires a known indexed archive size', () async {
    final fixture = _zipFixture([
      const _ZipItem('page.jpg', [1, 2, 3]),
    ]);
    final source = _MemoryFrameFileSource(fixture);

    await expectLater(
      FrameZipArchive.open(
        source: source,
        book: _book(0),
      ),
      throwsA(isA<FrameZipArchiveException>()),
    );
    expect(source.requests, isEmpty);
  });
}
