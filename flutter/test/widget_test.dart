import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/library/frame_book.dart';

void main() {
  test('groups volumes by provider, library, root and folder', () {
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
    expect(groups.first.isFolder, isTrue);
  });

  test('sorts folder volumes naturally by filename', () {
    final one = _book(
      id: 'one',
      path: '/books/Series/1.epub',
      fileName: '第1卷.epub',
    );
    final two = _book(
      id: 'two',
      path: '/books/Series/2.epub',
      fileName: '第2卷.epub',
    );
    final ten = _book(
      id: 'ten',
      path: '/books/Series/10.epub',
      fileName: '第10卷.epub',
    );

    final entry = groupFrameBooks([ten, one, two]).single;
    expect(
      entry.sortedMembers().map((book) => book.fileName).toList(),
      ['第1卷.epub', '第2卷.epub', '第10卷.epub'],
    );
  });

  test('keeps same folder paths separate across library roots', () {
    final first = _book(
      id: 'one',
      path: '/books/Series/01.epub',
      fileName: '01.epub',
      rootPath: '/books',
    );
    final second = _book(
      id: 'two',
      path: '/other/Series/02.epub',
      fileName: '02.epub',
      rootPath: '/other',
    );

    expect(groupFrameBooks([first, second]), hasLength(2));
  });
}

FrameBook _book({
  required String id,
  required String path,
  required String fileName,
  String provider = 'vps',
  String rootPath = '/books',
}) {
  return FrameBook(
    id: id,
    provider: provider,
    library: 'books',
    rootPath: rootPath,
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
    folderPath: '$rootPath/Series',
    folderTitle: 'Series',
    comicMetadata: const {},
    raw: const {},
  );
}
