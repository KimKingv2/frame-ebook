import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/core/frame_api_client.dart';
import 'package:frame_ebook/library/frame_book.dart';
import 'package:frame_ebook/library/frame_reader_repository.dart';
import 'package:frame_ebook/reader/frame_epub_reader_preview_screen.dart';
import 'package:frame_ebook/transport/frame_file_source.dart';
import 'package:material_ui/material_ui.dart';

class _PreviewApi implements FrameApiClient {
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    switch (Uri.parse(path).path) {
      case '/api/reading/state':
        return {'state': <String, dynamic>{}};
      case '/api/reading/annotations':
        return {'annotations': <dynamic>[]};
      default:
        throw StateError('Unexpected GET $path');
    }
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      {'ok': true, 'state': body['state']};

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async =>
      {'ok': true};

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

class _FailingFileSource implements FrameFileSource {
  @override
  Future<FrameFileResponse> open(FrameFileRequest request) async {
    throw StateError('test source is offline');
  }
}

FrameBook _testBook({String format = 'EPUB'}) => FrameBook.fromJson({
      'id': 'flutter-reader-preview-test',
      'provider': 'vps',
      'library': 'books',
      'rootPath': '/Books',
      'path': '/Books/preview.epub',
      'fileName': 'preview.epub',
      'title': 'Preview test book',
      'author': 'FRAME',
      'format': format,
      'shelf': 'books',
      'size': 1024,
    });

void main() {
  testWidgets('shows a recoverable error when the EPUB source fails',
      (tester) async {
    final repository = FrameReaderRepository(_PreviewApi());

    await tester.pumpWidget(
      MaterialApp(
        home: FrameEpubReaderPreviewScreen(
          book: _testBook(),
          fileSource: _FailingFileSource(),
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Preview test book'), findsOneWidget);
    expect(find.text('無法開啟 Flutter EPUB 預覽'), findsOneWidget);
    expect(find.textContaining('test source is offline'), findsOneWidget);
    expect(find.text('返回舊版閱讀室'), findsOneWidget);
  });

  testWidgets('uses the full-width desktop reader toolbar and workspace',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: FrameEpubReaderPreviewScreen(
          book: _testBook(),
          fileSource: _FailingFileSource(),
          repository: FrameReaderRepository(_PreviewApi()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-desktop-toolbar')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-workspace-root')), findsOneWidget);
    expect(find.text('FRAME READER'), findsNothing);
    expect(find.text('NOW READING'), findsOneWidget);
    expect(find.text('Preview test book'), findsOneWidget);
    final frame = tester.widget<Container>(
      find.byKey(const ValueKey('reader-rounded-frame')),
    );
    final decoration = frame.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(14));
    expect(
      find.byKey(const ValueKey('reader-rounded-content-clip')),
      findsOneWidget,
    );

    final workspace = tester.getRect(
      find.byKey(const ValueKey('reader-workspace-root')),
    );
    expect(workspace.left, 0);
    expect(workspace.width, 1440);
  });

  testWidgets('restores the true immersive reading-only layout with rounded page',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: FrameEpubReaderPreviewScreen(
          book: _testBook(),
          fileSource: _FailingFileSource(),
          repository: FrameReaderRepository(_PreviewApi()),
          initialImmersiveForTest: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-immersive-layout')), findsNothing);
    expect(find.byKey(const ValueKey('reader-workspace-root')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-desktop-toolbar')), findsNothing);
    expect(find.byKey(const ValueKey('reader-body-surface')), findsOneWidget);

    final safeArea = tester.widget<SafeArea>(find.byType(SafeArea).first);
    expect(safeArea.top, isFalse);
    expect(safeArea.bottom, isFalse);
    expect(safeArea.left, isFalse);
    expect(safeArea.right, isFalse);

    final frame = tester.widget<Container>(
      find.byKey(const ValueKey('reader-rounded-frame')),
    );
    final decoration = frame.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(14));
    expect(
      find.byKey(const ValueKey('reader-rounded-content-clip')),
      findsOneWidget,
    );
    final clip = tester.widget<ClipRRect>(
      find.byKey(const ValueKey('reader-rounded-content-clip')),
    );
    expect(clip.borderRadius, BorderRadius.circular(8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the reader body mounted while toggling immersive mode',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final screenKey = GlobalKey();
    Widget buildReader(bool immersive) => MaterialApp(
          home: FrameEpubReaderPreviewScreen(
            key: screenKey,
            book: _testBook(),
            fileSource: _FailingFileSource(),
            repository: FrameReaderRepository(_PreviewApi()),
            initialImmersiveForTest: immersive,
          ),
        );

    await tester.pumpWidget(buildReader(false));
    await tester.pumpAndSettle();
    final bodyBefore = tester.element(
      find.byKey(const ValueKey('reader-body-surface')),
    );

    await tester.pumpWidget(buildReader(true));
    await tester.pumpAndSettle();
    final bodyAfter = tester.element(
      find.byKey(const ValueKey('reader-body-surface')),
    );

    expect(identical(bodyBefore, bodyAfter), isTrue);
    expect(find.byKey(const ValueKey('reader-workspace-root')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-immersive-layout')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejects non-EPUB files before opening a cloud source',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FrameEpubReaderPreviewScreen(
          book: _testBook(format: 'CBZ'),
          fileSource: _FailingFileSource(),
          repository: FrameReaderRepository(_PreviewApi()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('無法開啟 Flutter EPUB 預覽'), findsOneWidget);
    expect(find.textContaining('只接受 EPUB'), findsOneWidget);
  });
}
