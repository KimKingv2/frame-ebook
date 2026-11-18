import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/core/frame_api_client.dart';
import 'package:frame_ebook/core/frame_api_scope.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/library/frame_bookshelf_screen.dart';
import 'package:material_ui/material_ui.dart';

class _FakeFrameApi implements FrameApiClient {
  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      {'ok': true, 'items': <dynamic>[]};

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      {'ok': true};

  @override
  Future<Uint8List> getBytes(String path) async => Uint8List(0);

  @override
  void close() {}
}

void main() {
  testWidgets('shows the main-branch FRAME bookshelf empty states', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      FrameApiScope(
        api: _FakeFrameApi(),
        child: const MaterialApp(home: FrameBookshelfScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('FRAME  READER'), findsOneWidget);
    expect(find.text('我的書架'), findsOneWidget);
    expect(find.text('兩種收藏，各自成架'), findsOneWidget);
    expect(find.text('電子書架尚未收藏作品'), findsOneWidget);
    expect(find.text('漫畫書架尚未收藏作品'), findsOneWidget);
  });

  test('groups volumes by provider, library, root and folder, matching main', () {
    final first = _book(
      id: 'one',
      path: '/books/Series/01.epub',
      fileName: '01.epub',
    );
    final second = _book(
      id: 'two',
      path: '/books/Series/02.epub',
      fileName: '02.epub',
    );
    final otherProvider = _book(
      id: 'three',
      provider: 'worker',
      path: '/books/Series/03.epub',
      fileName: '03.epub',
    );

    final groups = groupFrameBooks([first, second, otherProvider]);
    expect(groups, hasLength(2));
    expect(groups.first.members, hasLength(2));
    expect(groups.last.members, hasLength(1));
  });
}

FrameBook _book({
  required String id,
  required String path,
  required String fileName,
  String provider = 'vps',
}) {
  return FrameBook(
    id: id,
    provider: provider,
    library: 'books',
    rootPath: '/books',
    path: path,
    fileName: fileName,
    title: fileName,
    author: '',
    format: 'EPUB',
    shelf: 'books',
    size: 1000,
    lastModified: 0,
    lastOpenedAt: 0,
    addedAt: 0,
    pageCount: 0,
    language: '',
    publisher: '',
    publishedAt: '',
    identifier: '',
    subjects: const [],
    description: '',
    progress: const {},
    manualTitle: false,
    manualAuthor: false,
    coverHash: '',
    coverStatus: '',
    folderPath: '/books/Series',
    folderTitle: 'Series',
    comicMetadata: const {},
    raw: const {},
  );
}
