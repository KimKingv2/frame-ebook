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
      throw FrameApiException(
        message: result['error']?.toString() ?? '作品資訊保存失敗。',
      );
    }
  }

  Future<void> resetOpfMetadata(FrameBook book) async {
    final result = await api.postJson('/api/reading/state', {
      'book': book.descriptor(),
      'state': {
        'metadata': {
          'title': book.raw['bookTitle']?.toString() ?? '',
          'author': book.raw['bookCreator']?.toString() ?? '',
          'shelf': book.shelf == 'comics' ? 'comics' : 'books',
          'manualTitle': false,
          'manualAuthor': false,
          'language': book.language,
          'pageCount': book.pageCount,
        },
      },
    });
    if (result['ok'] != true) {
      throw FrameApiException(
        message: result['error']?.toString() ?? '恢復書籍內部資訊失敗。',
      );
    }
  }

  Future<List<Map<String, dynamic>>> searchBangumi(String keyword) async {
    final response = await api.postJson(
      '/api/comics/bangumi/search',
      {'keyword': keyword},
    );
    if (response['error'] != null) {
      throw FrameApiException(message: response['error'].toString());
    }
    final rawItems = response['items'];
    if (rawItems is! List) return const [];
    return rawItems
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<Map<String, dynamic>> linkBangumi(
    FrameBook book,
    int subjectId,
  ) async {
    final response = await api.postJson('/api/comics/bangumi/link', {
      'book': book.descriptor(),
      'subjectId': subjectId,
    });
    if (response['ok'] != true) {
      throw FrameApiException(
        message: response['error']?.toString() ?? '保存 Bangumi 作品資料失敗。',
      );
    }
    return response;
  }

  Future<List<Map<String, dynamic>>> loadLegacyLinkCandidates(
    FrameBook book,
  ) async {
    final query = Uri(
      path: '/api/reading/link',
      queryParameters: {
        'book_id': book.id,
        'provider': book.provider,
        'library': book.library,
        'root_path': book.rootPath,
        'path': book.path,
      },
    );
    final response = await api.getJson(query.toString());
    if (response['error'] != null) {
      throw FrameApiException(message: response['error'].toString());
    }
    final rawCandidates = response['candidates'];
    if (rawCandidates is! List) return const [];
    return rawCandidates
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<Map<String, dynamic>> linkLegacyBook(
    FrameBook target,
    String oldBookId,
  ) async {
    final response = await api.postJson('/api/reading/link', {
      'book': target.descriptor(),
      'oldBookId': oldBookId,
    });
    if (response['ok'] != true) {
      throw FrameApiException(
        message: response['error']?.toString() ?? '關聯舊書籍資料失敗。',
      );
    }
    return response;
  }
}
