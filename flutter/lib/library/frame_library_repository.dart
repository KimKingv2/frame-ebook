import 'dart:typed_data';

import '../core/frame_api_client.dart';
import 'frame_book.dart';

class FrameLibraryRepository {
  FrameLibraryRepository(this.api);

  final FrameApiClient api;

  Future<List<FrameBook>> loadBookshelf() async {
    final response = await api.getJson('/api/reading/bookshelf');
    final rawItems = response['items'];
    if (rawItems is! List) {
      throw const FrameApiException(message: '雲端書架回應缺少 items 清單。');
    }
    final books = <FrameBook>[];
    for (final item in rawItems) {
      if (item is Map) {
        final book = FrameBook.fromJson(Map<String, dynamic>.from(item));
        if (book.id.isNotEmpty && book.path.isNotEmpty) books.add(book);
      }
    }
    return books;
  }

  Future<Uint8List> loadCover(String hash) {
    if (!RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(hash)) {
      throw const FormatException('封面 SHA-256 格式不正確。');
    }
    return api.getBytes('/api/cloud/covers?hash=$hash');
  }

  Future<void> updateMetadata({
    required FrameBook book,
    required String title,
    required String author,
    required String shelf,
  }) async {
    final result = await api.postJson('/api/reading/state', {
      'book': book.descriptor(),
      'state': {
        'metadata': {
          'title': title,
          'author': author,
          'shelf': book.format == 'CBZ' ? 'comics' : shelf,
          'manualTitle': true,
          'manualAuthor': true,
          'language': book.language,
          'pageCount': book.pageCount,
        },
      },
    });
    if (result['ok'] != true) {
      throw const FrameApiException(message: '作品資訊保存失敗。');
    }
  }

  Future<void> resetOpfMetadata(FrameBook book) async {
    final result = await api.postJson('/api/reading/state', {
      'book': book.descriptor(),
      'state': {
        'metadata': {
          'title': book.raw['bookTitle']?.toString() ?? '',
          'author': book.raw['bookCreator']?.toString() ?? '',
          'shelf': book.library,
          'manualTitle': false,
          'manualAuthor': false,
          'language': book.language,
          'pageCount': book.pageCount,
        },
      },
    });
    if (result['ok'] != true) {
      throw const FrameApiException(message: '恢復書籍內部資訊失敗。');
    }
  }
}
