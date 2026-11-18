import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/library/frame_bookshelf_screen.dart';

void main() {
  test('Flutter bookshelf uses the exact same-origin Reader homepage', () {
    final uri = frameBookshelfUri();
    expect(uri.path, '/');
    expect(uri.query, isEmpty);
    expect(uri.fragment, isEmpty);
    expect(uri.scheme, anyOf('https', 'http'));
    expect(uri.host, isNotEmpty);
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
