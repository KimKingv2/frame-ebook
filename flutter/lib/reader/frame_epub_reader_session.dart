import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/frame_book.dart';
import '../library/frame_reader_repository.dart';
import '../transport/frame_file_source.dart';
import 'frame_epub_parser.dart';
import 'frame_epub_resource_loader.dart';
import 'frame_zip_archive.dart';

enum FrameEpubReaderStatus {
  idle,
  opening,
  ready,
  error,
  closed,
}

/// A shared, platform-neutral reading session for one cloud EPUB.
///
/// The session owns the Range-backed archive and coordinates the EPUB parser,
/// resource loader and existing Reading Room repository. It deliberately
/// does not render XHTML or invent a synthetic CFI: a future renderer can
/// report a real EPUB CFI through [saveReadingPosition].
class FrameEpubReaderSession extends ChangeNotifier {
  FrameEpubReaderSession({
    required this.book,
    required this.fileSource,
    required this.repository,
    this.parser = const FrameEpubParser(),
  });

  final FrameBook book;
  final FrameFileSource fileSource;
  final FrameReaderRepository repository;
  final FrameEpubParser parser;

  FrameEpubReaderStatus _status = FrameEpubReaderStatus.idle;
  FrameEpubReaderStatus get status => _status;

  FrameEpubBook? _epub;
  FrameEpubBook? get epub => _epub;

  FrameZipArchive? _archive;
  FrameZipArchive? get archive => _archive;

  FrameEpubResourceLoader? _loader;
  FrameEpubResourceLoader? get resourceLoader => _loader;

  FrameEpubChapterDocument? _chapter;
  FrameEpubChapterDocument? get currentChapter => _chapter;

  FrameReaderState _readerState = FrameReaderState.empty();
  FrameReaderState get readerState => _readerState;

  List<FrameReaderAnnotation> _annotations = const [];
  List<FrameReaderAnnotation> get annotations =>
      List.unmodifiable(_annotations);

  int? _currentSpineIndex;
  int? get currentSpineIndex => _currentSpineIndex;

  String _currentFragment = '';
  String get currentFragment => _currentFragment;

  bool _chapterLoading = false;
  bool get isChapterLoading => _chapterLoading;

  String? _error;
  String? get error => _error;

  String? _warning;
  String? get warning => _warning;

  bool _started = false;
  bool _closed = false;
  int _navigationRevision = 0;

  List<FrameEpubTocEntry> get toc => _epub?.toc ?? const [];

  bool get isFixedLayout => _epub?.isFixedLayout ?? false;

  bool get canGoPrevious =>
      _currentSpineIndex != null && _currentSpineIndex! > 0;

  bool get canGoNext {
    final index = _currentSpineIndex;
    final count = _epub?.spine.length ?? 0;
    return index != null && index + 1 < count;
  }

  /// Chapter-based estimate only. Fine-grained progress is supplied later by
  /// the renderer through [saveReadingPosition].
  int get chapterProgressPercent {
    final index = _currentSpineIndex;
    final count = _epub?.spine.length ?? 0;
    if (index == null || count <= 0) return 0;
    return ((index * 100) ~/ count).clamp(0, 99);
  }

  String get currentChapterLabel {
    final index = _currentSpineIndex;
    final epub = _epub;
    if (index == null || epub == null || index < 0 || index >= epub.spine.length) {
      return '';
    }
    final path = epub.spine[index].item.path;
    final tocLabel = _findTocLabel(epub.toc, path);
    if (tocLabel.isNotEmpty) return tocLabel;
    final href = epub.spine[index].item.href;
    final name = href.split('/').last;
    try {
      return Uri.decodeComponent(name);
    } on FormatException {
      return name;
    }
  }

  /// Opens the original archive using bounded Range requests and restores the
  /// last saved spine index. Existing CFI data is left intact until the
  /// renderer can restore and emit a standards-compliant location.
  Future<void> open() async {
    if (_started || _closed) {
      throw StateError('EPUB 閱讀工作階段只能開啟一次。');
    }
    _started = true;
    _status = FrameEpubReaderStatus.opening;
    _error = null;
    _warning = null;
    notifyListeners();

    try {
      _readerState = await repository.loadState(book);
      try {
        _annotations = await repository.loadAnnotations(book);
      } on Object catch (error) {
        _warning = '筆記與書籤暫時無法載入：$error';
      }

      final archive = await FrameZipArchive.open(
        source: fileSource,
        book: book,
      );
      _archive = archive;
      final epub = await parser.parse(archive);
      _epub = epub;
      final loader = FrameEpubResourceLoader(
        archive: archive,
        book: epub,
      );
      _loader = loader;

      final savedIndex = _asInteger(_readerState.progress['index']);
      final initialIndex = savedIndex == null
          ? 0
          : savedIndex.clamp(0, epub.spine.length - 1).toInt();
      final chapter = await loader.loadChapter(epub.spine[initialIndex]);

      if (_closed) return;
      _currentSpineIndex = initialIndex;
      _chapter = chapter;
      _currentFragment = '';
      _status = FrameEpubReaderStatus.ready;
      notifyListeners();
    } on Object catch (error) {
      if (_closed) return;
      _status = FrameEpubReaderStatus.error;
      _error = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<bool> goToSpineIndex(int index) =>
      _loadSpineIndex(index, fragment: '', saveProgress: true);

  Future<bool> goToPreviousChapter() {
    final index = _currentSpineIndex;
    if (index == null || index <= 0) return Future.value(false);
    return goToSpineIndex(index - 1);
  }

  Future<bool> goToNextChapter() {
    final index = _currentSpineIndex;
    final count = _epub?.spine.length ?? 0;
    if (index == null || index + 1 >= count) return Future.value(false);
    return goToSpineIndex(index + 1);
  }

  Future<bool> goToTocEntry(FrameEpubTocEntry entry) {
    final reference = entry.reference;
    if (reference == null || reference.isExternal || reference.path == null) {
      return Future.value(false);
    }
    return _goToArchivePath(
      reference.path!,
      fragment: reference.fragment,
    );
  }

  /// Resolves a chapter hyperlink relative to [basePath], defaulting to the
  /// currently displayed XHTML document. External URLs are never fetched.
  Future<bool> goToHref(
    String href, {
    String? basePath,
  }) {
    final chapterPath = basePath ?? _chapter?.resource.path;
    if (chapterPath == null) return Future.value(false);
    final reference = FrameEpubParser.resolveHref(
      href,
      baseFilePath: chapterPath,
    );
    if (!reference.isInternal || reference.path == null) {
      return Future.value(false);
    }
    return _goToArchivePath(
      reference.path!,
      fragment: reference.fragment,
    );
  }

  Future<bool> _goToArchivePath(
    String path, {
    required String fragment,
  }) async {
    final spine = _epub?.spine;
    if (spine == null) return false;
    final index = spine.indexWhere((item) => item.item.path == path);
    if (index < 0) return false;
    return _loadSpineIndex(
      index,
      fragment: fragment,
      saveProgress: true,
    );
  }

  Future<bool> _loadSpineIndex(
    int index, {
    required String fragment,
    required bool saveProgress,
  }) async {
    final epub = _epub;
    final loader = _loader;
    if (_status != FrameEpubReaderStatus.ready ||
        epub == null ||
        loader == null ||
        index < 0 ||
        index >= epub.spine.length) {
      return false;
    }

    final revision = ++_navigationRevision;
    _chapterLoading = true;
    _error = null;
    notifyListeners();

    try {
      final chapter = await loader.loadChapter(epub.spine[index]);
      if (_closed || revision != _navigationRevision) return false;
      _currentSpineIndex = index;
      _currentFragment = fragment;
      _chapter = chapter;
      _chapterLoading = false;
      notifyListeners();

      if (saveProgress) {
        await _saveProgress(
          percent: chapterProgressPercent,
          cfi: '',
        );
      }
      return true;
    } on Object catch (error) {
      if (!_closed && revision == _navigationRevision) {
        _chapterLoading = false;
        _error = '無法載入章節：$error';
        notifyListeners();
      }
      return false;
    }
  }

  /// Saves a real renderer position without changing the existing D1 schema.
  ///
  /// The CFI value is passed through unchanged. Callers must provide a valid
  /// EPUB CFI; this session intentionally does not synthesize one from a
  /// chapter number or DOM node.
  Future<void> saveReadingPosition({
    required int percent,
    required String cfi,
  }) async {
    if (_status != FrameEpubReaderStatus.ready || _currentSpineIndex == null) {
      throw StateError('EPUB 閱讀工作階段尚未就緒。');
    }
    await _saveProgress(
      percent: percent.clamp(0, 100),
      cfi: cfi,
    );
  }

  Future<void> _saveProgress({
    required int percent,
    required String cfi,
  }) async {
    final index = _currentSpineIndex;
    if (index == null) return;
    try {
      _readerState = await repository.saveState(
        book,
        progress: {
          'percent': percent,
          'label': currentChapterLabel,
          'cfi': cfi,
          'index': index,
        },
        lastOpenedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _warning = null;
      notifyListeners();
    } on Object catch (error) {
      _warning = '閱讀進度尚未同步至雲端：$error';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> saveAppearance(Map<String, dynamic> appearance) async {
    _readerState = await repository.saveState(
      book,
      appearance: appearance,
    );
    notifyListeners();
  }

  Future<FrameReaderAnnotation> saveAnnotation(
    FrameReaderAnnotation annotation,
  ) async {
    final saved = await repository.saveAnnotation(book, annotation);
    _annotations = [
      ..._annotations.where((item) => item.id != saved.id),
      saved,
    ];
    notifyListeners();
    return saved;
  }

  Future<void> deleteAnnotation(String annotationId) async {
    await repository.deleteAnnotation(book, annotationId);
    _annotations = _annotations
        .where((item) => item.id != annotationId)
        .toList(growable: false);
    notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _navigationRevision++;
    _status = FrameEpubReaderStatus.closed;
    _chapterLoading = false;
    final archive = _archive;
    _archive = null;
    _loader = null;
    _chapter = null;
    if (archive != null) await archive.close();
    notifyListeners();
  }

  @override
  void dispose() {
    if (!_closed) {
      _closed = true;
      _navigationRevision++;
      final archive = _archive;
      _archive = null;
      if (archive != null) unawaited(archive.close());
    }
    super.dispose();
  }
}

int? _asInteger(dynamic value) {
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}

String _findTocLabel(List<FrameEpubTocEntry> entries, String? path) {
  if (path == null) return '';
  for (final entry in entries) {
    if (entry.reference?.path == path && entry.label.trim().isNotEmpty) {
      return entry.label.trim();
    }
    final nested = _findTocLabel(entry.children, path);
    if (nested.isNotEmpty) return nested;
  }
  return '';
}
