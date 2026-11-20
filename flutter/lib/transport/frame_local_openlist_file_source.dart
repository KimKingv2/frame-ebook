import 'dart:math' as math;

import '../cloud/local_openlist_client.dart';
import 'frame_file_source.dart';

/// Opens local OpenList EPUBs through bounded Range reads.
///
/// OpenList credentials and its short-lived token remain inside the shared
/// in-memory [LocalOpenListClient]. The returned raw URL is used only for
/// Range requests; no Access cookie or OpenList token is sent to that URL.
class FrameLocalOpenListFileSource implements FrameFileSource {
  FrameLocalOpenListFileSource({required this.client});

  static const int maxRangeChunkBytes = 1024 * 1024;

  final LocalOpenListClient client;

  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    if (request.cancellation?.isCancelled == true) {
      throw StateError('檔案讀取已取消。');
    }
    if (!client.isAuthenticated) {
      throw const LocalOpenListException(
        '本地 OpenList 登入已失效，請返回「檔案瀏覽」重新登入。',
      );
    }

    final book = request.book;
    if (book.provider != 'local') {
      throw const FormatException('本地 OpenList 閱讀來源只接受 local 書籍。');
    }
    if (!const {'books', 'comics'}.contains(book.library)) {
      throw const FormatException('本地 OpenList 書籍分類無效。');
    }

    final rootPath = LocalOpenListClient.normalizePath(book.rootPath);
    final path = LocalOpenListClient.normalizePath(book.path);
    final withinRoot = path == rootPath ||
        path.startsWith(rootPath == '/' ? '/' : '$rootPath/');
    if (!withinRoot) {
      throw const FormatException('本地 OpenList 書籍路徑超出目前書庫根目錄。');
    }
    if (book.format.toUpperCase() != 'EPUB' ||
        !path.toLowerCase().endsWith('.epub')) {
      throw const FormatException('Flutter 本地閱讀預覽目前只支援 EPUB。');
    }
    if (book.size <= 0) {
      throw const FormatException('書庫索引沒有提供有效檔案大小，請重新掃描書庫。');
    }

    final file = await client.getFileInfo(path);
    if (request.cancellation?.isCancelled == true) {
      throw StateError('檔案讀取已取消。');
    }
    if (file.size <= 0 || file.size != book.size) {
      throw const LocalOpenListException(
        '本地 OpenList 檔案大小與書庫索引不一致，請重新掃描書庫。',
      );
    }

    final requestedRange = request.range;
    if (requestedRange == null) {
      throw const FormatException('本地 EPUB 閱讀必須使用 HTTP Range，已拒絕完整檔案讀取。');
    }

    late final int start;
    late final int end;
    if (requestedRange.suffixLength != null) {
      final length = math.min(requestedRange.suffixLength!, file.size).toInt();
      start = file.size - length;
      end = file.size - 1;
    } else {
      start = requestedRange.start ?? 0;
      if (start < 0 || start >= file.size) {
        throw RangeError('本地 OpenList Range 起點超出檔案大小。');
      }
      end = math.min(requestedRange.end ?? file.size - 1, file.size - 1)
          .toInt();
      if (end < start) {
        throw const FormatException('本地 OpenList Range 範圍無效。');
      }
    }

    var closed = false;

    Stream<List<int>> streamRange() async* {
      var offset = start;
      while (offset <= end) {
        if (closed || request.cancellation?.isCancelled == true) {
          throw StateError('檔案讀取已取消。');
        }
        final length = math.min(maxRangeChunkBytes, end - offset + 1).toInt();
        final result = await client.readRange(
          path,
          start: offset,
          length: length,
        );
        if (closed || request.cancellation?.isCancelled == true) {
          throw StateError('檔案讀取已取消。');
        }
        if (result.start != offset ||
            result.end != offset + length - 1 ||
            result.totalSize != file.size ||
            result.bytes.length != length) {
          throw const LocalOpenListException(
            '本地 OpenList Range 回應與要求不一致，已停止讀取。',
          );
        }
        yield result.bytes;
        offset += length;
      }
    }

    final length = end - start + 1;
    return FrameFileResponse(
      statusCode: 206,
      headers: {
        'accept-ranges': 'bytes',
        'content-length': length.toString(),
        'content-range': 'bytes $start-$end/${file.size}',
        'content-type': 'application/epub+zip',
      },
      requestedRange: requestedRange,
      stream: streamRange(),
      onClose: () {
        closed = true;
        request.cancellation?.cancel();
      },
    );
  }
}
