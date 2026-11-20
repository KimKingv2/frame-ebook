import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/cloud/frame_cloud_archive_processor.dart';
import 'package:frame_ebook/cloud/frame_cloud_models.dart';
import 'package:frame_ebook/cloud/frame_cloud_repository.dart';
import 'package:frame_ebook/core/frame_api_client.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';

class _MemoryFileSource implements FrameFileSource {
  _MemoryFileSource(this.bytes);

  final Uint8List bytes;
  final List<(int, int)> requests = [];

  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    final range = request.range;
    if (range == null || range.start == null) {
      throw StateError('Archive reads must be explicit bounded ranges.');
    }
    final start = range.start!;
    final requestedEnd = range.end ?? bytes.length - 1;
    final end = requestedEnd < bytes.length ? requestedEnd : bytes.length - 1;
    if (start < 0 || end < start) throw RangeError('Invalid archive range.');
    requests.add((start, end));
    final body = Uint8List.sublistView(bytes, start, end + 1);
    return FrameFileResponse(
      statusCode: 206,
      headers: {
        'Content-Length': body.length.toString(),
        'Content-Range': 'bytes $start-$end/${bytes.length}',
        'Accept-Ranges': 'bytes',
      },
      stream: Stream<List<int>>.value(body),
      onClose: () {},
      requestedRange: range,
    );
  }
}

class _ArchiveApi implements FrameApiClient {
  _ArchiveApi();

  int queueReads = 0;
  Map<String, dynamic>? metadataBody;
  Map<String, String>? uploadHeaders;
  String? uploadContentType;
  Uint8List? uploadBytes;
  Map<String, dynamic>? savedState;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/api/cloud/covers?')) {
      queueReads++;
      if (queueReads == 1) {
        return {
          'ok': true,
          'total': 1,
          'items': [
            {
              'name': 'Range Test.epub',
              'path': '/Books/Range Test.epub',
              'parentPath': '/Books',
              'isDir': false,
              'format': 'EPUB',
              'size': _fixtureSize,
              'modified': '2026-11-20T00:00:00Z',
              'coverStatus': 'pending',
            },
          ],
        };
      }
      return {'ok': true, 'total': 0, 'items': <dynamic>[]};
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path == '/api/cloud/index/metadata') {
      metadataBody = Map<String, dynamic>.from(body);
      return {'ok': true, 'updated': (body['entries'] as List).length};
    }
    if (path == '/api/cloud/index/state') {
      savedState = Map<String, dynamic>.from(body['state'] as Map);
      return {'ok': true};
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async {
    uploadBytes = Uint8List.fromList(body);
    uploadContentType = contentType;
    uploadHeaders = Map<String, String>.from(headers);
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      {'ok': true};

  @override
  Future<Uint8List> getBytes(String path) async => Uint8List(0);

  @override
  void close() {}
}

const _container = '''
<?xml version="1.0" encoding="UTF-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const _package = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         version="3.0" unique-identifier="book-id">
  <metadata>
    <dc:identifier id="book-id">urn:uuid:range-test</dc:identifier>
    <dc:title>Range-backed 封面測試</dc:title>
    <dc:creator>FRAME Studio</dc:creator>
    <dc:language>zh-TW</dc:language>
    <dc:publisher>FRAME Press</dc:publisher>
    <dc:date>2026-11-20</dc:date>
    <dc:subject>測試</dc:subject>
    <dc:description>OPF 元資料必須經由 Range 讀取。</dc:description>
  </metadata>
  <manifest>
    <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="chapter"/></spine>
</package>
''';

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
const _fixtureSize = 72000;

Uint8List _zipFixture() {
  final items = <(String, Uint8List)>[
    ('mimetype', Uint8List.fromList(utf8.encode('application/epub+zip'))),
    ('META-INF/container.xml', Uint8List.fromList(utf8.encode(_container))),
    ('OPS/package.opf', Uint8List.fromList(utf8.encode(_package))),
    ('OPS/chapter.xhtml', Uint8List.fromList(utf8.encode('<html><body>test</body></html>'))),
    ('OPS/images/cover.png', base64Decode(_onePixelPng)),
    ('padding.bin', Uint8List(70000)),
  ];
  final output = <int>[];
  final central = <int>[];

  for (final item in items) {
    final name = utf8.encode(item.$1);
    final plain = item.$2;
    final crc = _crc32(plain);
    final localOffset = output.length;

    _write32(output, 0x04034b50);
    _write16(output, 20);
    _write16(output, 0x0800);
    _write16(output, 0);
    _write16(output, 0);
    _write16(output, 0);
    _write32(output, crc);
    _write32(output, plain.length);
    _write32(output, plain.length);
    _write16(output, name.length);
    _write16(output, 0);
    output
      ..addAll(name)
      ..addAll(plain);

    _write32(central, 0x02014b50);
    _write16(central, 0x0314);
    _write16(central, 20);
    _write16(central, 0x0800);
    _write16(central, 0);
    _write16(central, 0);
    _write16(central, 0);
    _write32(central, crc);
    _write32(central, plain.length);
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
  test('reads EPUB OPF and cover through bounded ranges, then uploads a PNG thumbnail', () async {
    final archiveBytes = _zipFixture();
    expect(archiveBytes.length, _fixtureSize);
    final source = _MemoryFileSource(archiveBytes);
    final api = _ArchiveApi();
    final repository = FrameCloudRepository(api);
    final state = FrameCloudScanState.initial(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.books,
      rootPath: '/Books',
      scanId: 'scan_1234567890',
    );
    final processor = FrameCloudArchiveProcessor(
      repository: repository,
      fileSourceFactory: (_) => source,
    );

    final result = await processor.processPendingBatch(
      provider: FrameCloudProvider.vps,
      library: FrameCloudLibrary.books,
      rootPath: '/Books',
      scanState: state,
    );

    expect(result.processed, 1);
    expect(result.uploaded, 1);
    expect(result.missing, 0);
    expect(result.failed, 0);
    expect(result.metadataProcessed, 1);
    expect(result.pending, 0);

    final entry = (api.metadataBody!['entries'] as List).single as Map;
    final metadata = entry['metadata'] as Map;
    expect(metadata['title'], 'Range-backed 封面測試');
    expect(metadata['creators'], ['FRAME Studio']);
    expect(metadata['language'], 'zh-TW');
    expect(api.uploadContentType, 'image/png');
    expect(api.uploadBytes, isNotNull);
    expect(api.uploadBytes!.length, lessThanOrEqualTo(2 * 1024 * 1024));
    expect(
      api.uploadHeaders!['X-Cover-Hash'],
      sha256.convert(api.uploadBytes!).toString(),
    );
    expect(result.state?.coverReadyCount, 1);
    expect(result.state?.metadataProcessedCount, 1);
    expect(api.savedState?['coverReadyCount'], 1);
    expect(
      source.requests.any((range) => range.$2 - range.$1 + 1 == archiveBytes.length),
      isFalse,
      reason: 'The processor must never fetch the complete original EPUB.',
    );
  });
}
