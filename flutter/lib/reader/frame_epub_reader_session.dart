import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import '../library/frame_book.dart';
import '../library/frame_reader_repository.dart';
import '../transport/frame_file_source.dart';
import 'frame_epub_cfi.dart';
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
/// resource loader, CFI restoration and existing Reading Room repository.
/// CFI generation is supplied by the XHTML renderer and validated here before
/// it is persisted through [saveReadingPosition].
class FrameEpubReaderSession extends ChangeNotifier {
  FrameEpubReaderSession({
    required this.book,
    required this.fileSource,
    required this.repository,
    this.parser = const FrameEpubParser(),
    this.chapterPreloadDelay = const Duration(milliseconds: 650),
  });

  final FrameBook book;
  final FrameFileSource fileSource;
  final FrameReaderRepository repository;
  final FrameEpubParser parser;
  final Duration chapterPreloadDelay;

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

  String? _initialCfi;
  String? get initialCfi => _initialCfi;

  FrameEpubCfiLocation? _restoredCfiLocation;
  XmlElement? get initialAnchor => _restoredCfiLocation?.anchorElement;

  double? get initialScrollFraction {
    final location = _restoredCfiLocation;
    final chapter = _chapter;
    if (location == null || chapter == null) return null;
    return FrameEpubCfi.textFraction(
      chapter.document,
      location.node,
      location.offset,
    );
  }

  bool _chapterLoading = false;
  bool get isChapterLoading => _chapterLoading;

  String? _error;
  String? get error => _error;

  String? _warning;
  String? get warning => _warning;

  bool _started = false;
  bool _closed = false;
  int _navigationRevision = 0;
  Future<void> _progressSaveQueue = Future<void>.value();
  Timer? _chapterPreloadTimer;
  int _annotationMutationRevision = 0;
  int _annotationRefreshRequest = 0;

  List<FrameEpubTocEntry> get toc => _epub?.toc ?? const [];

  bool get isFixedLayout => _epub?.isFixedLayout ?? false;

  /// Spine indexes that participate in the publication's normal reading
  /// order. Non-linear auxiliary pages remain directly navigable.
  List<int> get linearSpineIndices {
    final spine = _epub?.spine;
    if (spine == null) return const [];
    return List<int>.unmodifiable([
      for (var index = 0; index < spine.length; index++)
        if (spine[index].linear) index,
    ]);
  }

  /// Reading order for the active reader surface.
  ///
  /// A non-linear item opened directly from the TOC or a hyperlink is included
  /// for as long as it is the active page, so long-strip scroll restoration
  /// can still represent that page without making it part of normal reading.
  List<int> get readingOrderSpineIndices {
    final spine = _epub?.spine;
    if (spine == null) return const [];
    final indices = linearSpineIndices.toList();
    final activeIndex = _currentSpineIndex;
    if (activeIndex == null ||
        activeIndex < 0 ||
        activeIndex >= spine.length ||
        spine[activeIndex].linear) {
      return List<int>.unmodifiable(indices);
    }

    final insertionIndex = indices.indexWhere(
      (candidate) => candidate > activeIndex,
    );
    if (insertionIndex < 0) {
      indices.add(activeIndex);
    } else {
      indices.insert(insertionIndex, activeIndex);
    }
    return List<int>.unmodifiable(indices);
  }

  /// Resolves a spine index by its relative position in normal reading order.
  /// This also works when the active page was opened directly and is nonlinear.
  int? spineIndexAtReadingOrderOffset(int spineIndex, int offset) {
    final indices = readingOrderSpineIndices;
    final currentPosition = indices.indexOf(spineIndex);
    if (currentPosition < 0) return null;
    final targetPosition = currentPosition + offset;
    if (targetPosition < 0 || targetPosition >= indices.length) return null;
    return indices[targetPosition];
  }

  /// Whole-book page progress for fixed-layout publications.
  ///
  /// Only linear pages contribute to the total. A directly opened non-linear
  /// page is positioned between its surrounding linear pages without adding
  /// an extra page to the publication's progress denominator.
  int get fixedLayoutReadingProgressPercent {
    final activeIndex = _currentSpineIndex;
    final linearIndices = linearSpineIndices;
    if (activeIndex == null) return 0;
    if (linearIndices.isEmpty) return 100;

    final activePosition = linearIndices.indexOf(activeIndex);
    final completedPages = activePosition >= 0
        ? activePosition + 1
        : linearIndices.where((index) => index < activeIndex).length;
    return ((completedPages * 100) / linearIndices.length)
        .round()
        .clamp(0, 100)
        .toInt();
  }

  bool get canGoPrevious {
    final index = _currentSpineIndex;
    return index != null && _previousLinearSpineIndex(index) != null;
  }

  bool get canGoNext {
    final index = _currentSpineIndex;
    return index != null && _nextLinearSpineIndex(index) != null;
  }

  /// Chapter-based estimate only. Fine-grained progress is supplied later by
  /// the renderer through [saveReadingPosition].
  int get chapterProgressPercent {
    final index = _currentSpineIndex;
    final spine = _epub?.spine;
    if (index == null || spine == null || spine.isEmpty) return 0;

    var linearCount = 0;
    var completedLinearItems = 0;
    for (var spineIndex = 0; spineIndex < spine.length; spineIndex++) {
      if (!spine[spineIndex].linear) continue;
      linearCount++;
      if (spineIndex < index) completedLinearItems++;
    }
    final total = linearCount == 0 ? spine.length : linearCount;
    final completed = linearCount == 0 ? index : completedLinearItems;
    return ((completed * 100) ~/ total).clamp(0, 99).toInt();
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
      if (_closed) return;
      try {
        _annotations = await repository.loadAnnotations(book);
      } on Object catch (error) {
        _warning = '筆記與書籤暫時無法載入：$error';
      }

      if (_closed) return;
      final archive = await FrameZipArchive.open(
        source: fileSource,
        book: book,
      );
      if (_closed) {
        await archive.close();
        return;
      }
      _archive = archive;
      final epub = await parser.parse(archive);
      if (_closed) return;
      _epub = epub;
      final loader = FrameEpubResourceLoader(
        archive: archive,
        book: epub,
      );
      _loader = loader;

      final savedIndex = _asInteger(_readerState.progress['index']);
      final savedCfi = _readerState.progress['cfi']?.toString().trim() ?? '';
      final cfiIndex = savedCfi.isEmpty
          ? null
          : FrameEpubCfi.spineIndexFromCfi(epub, savedCfi);
      final firstLinearIndex = epub.spine.indexWhere((item) => item.linear);
      final defaultIndex = firstLinearIndex >= 0 ? firstLinearIndex : 0;
      final initialIndex = cfiIndex ??
          (savedIndex == null
              ? defaultIndex
              : savedIndex.clamp(0, epub.spine.length - 1).toInt());
      final chapter = await loader.loadChapter(epub.spine[initialIndex]);

      if (_closed) return;
      if (cfiIndex == initialIndex && savedCfi.isNotEmpty) {
        _restoredCfiLocation = FrameEpubCfi.resolve(
          book: epub,
          document: chapter.document,
          cfi: savedCfi,
        );
        if (_restoredCfiLocation != null) {
          _initialCfi = savedCfi;
        } else {
          _warning = '上次的 EPUB 精確閱讀位置無法解析，已退回章節位置。';
        }
      }
      _currentSpineIndex = initialIndex;
      _chapter = chapter;
      _currentFragment = '';
      _status = FrameEpubReaderStatus.ready;
      notifyListeners();
      _scheduleNextChapterPreload();
    } on Object catch (error) {
      final archive = _archive;
      final loader = _loader;
      _archive = null;
      _loader = null;
      loader?.dispose();
      if (archive != null) await archive.close();
      if (_closed) return;
      _status = FrameEpubReaderStatus.error;
      _error = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<bool> goToSpineIndex(int index) =>
      _loadSpineIndex(index, fragment: '', saveProgress: true);

  /// Navigates to an existing EPUB CFI, including a legacy range CFI.
  /// The same Range-backed loader is used when the annotation belongs to a
  /// different spine item; no archive is extracted or written to disk.
  Future<bool> goToCfi(String cfi) async {
    final epub = _epub;
    if (_status != FrameEpubReaderStatus.ready || epub == null || _closed) {
      return false;
    }
    final spineIndex = FrameEpubCfi.spineIndexFromCfi(epub, cfi);
    if (spineIndex == null) return false;

    if (_currentSpineIndex != spineIndex) {
      final loaded = await _loadSpineIndex(
        spineIndex,
        fragment: '',
        saveProgress: false,
      );
      if (!loaded) return false;
    }

    final chapter = _chapter;
    if (chapter == null) return false;
    final location = FrameEpubCfi.resolve(
      book: epub,
      document: chapter.document,
      cfi: cfi,
    );
    if (location == null || location.spineIndex != spineIndex) return false;

    _currentFragment = '';
    _initialCfi = cfi;
    _restoredCfiLocation = location;
    notifyListeners();

    final count = epub.spine.length;
    final fraction = FrameEpubCfi.textFraction(
      chapter.document,
      location.node,
      location.offset,
    );
    final percent = (((spineIndex + fraction) / count) * 100)
        .round()
        .clamp(0, 100)
        .toInt();
    await _queueProgressSave(
      index: spineIndex,
      label: currentChapterLabel,
      percent: percent,
      cfi: cfi,
    );
    return true;
  }

  Future<bool> goToPreviousChapter() {
    final index = _currentSpineIndex;
    if (index == null) return Future.value(false);
    final target = _previousLinearSpineIndex(index);
    if (target == null) return Future.value(false);
    return goToSpineIndex(target);
  }

  Future<bool> goToNextChapter() {
    final index = _currentSpineIndex;
    if (index == null) return Future.value(false);
    final target = _nextLinearSpineIndex(index);
    if (target == null) return Future.value(false);
    return goToSpineIndex(target);
  }

  int? _previousLinearSpineIndex(int index) {
    final spine = _epub?.spine;
    if (spine == null) return null;
    for (var candidate = index - 1; candidate >= 0; candidate--) {
      if (spine[candidate].linear) return candidate;
    }
    return null;
  }

  int? _nextLinearSpineIndex(int index) {
    final spine = _epub?.spine;
    if (spine == null) return null;
    for (var candidate = index + 1; candidate < spine.length; candidate++) {
      if (spine[candidate].linear) return candidate;
    }
    return null;
  }

  /// Returns whether a TOC entry points to a document in the reading order.
  ///
  /// Navigation documents may contain links to indexes, auxiliary pages or
  /// other XHTML resources that are present in the archive but omitted from
  /// the spine. Those entries must not be presented as readable chapters.
  bool canNavigateTocEntry(FrameEpubTocEntry entry) {
    final reference = entry.reference;
    return reference != null &&
        !reference.isExternal &&
        reference.path != null &&
        _spineIndexForArchivePath(reference.path!) != null;
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

  String _normalizeArchivePathForLookup(String path) {
    final decoded = <String>[];
    for (final rawSegment in path.replaceAll('\\', '/').split('/')) {
      if (rawSegment.isEmpty || rawSegment == '.') continue;
      String segment;
      try {
        segment = Uri.decodeComponent(rawSegment);
      } on FormatException {
        segment = rawSegment;
      }
      if (segment == '..') {
        if (decoded.isNotEmpty) decoded.removeLast();
      } else {
        decoded.add(segment);
      }
    }
    return decoded.join('/');
  }

  int? _spineIndexForArchivePath(String path) {
    final spine = _epub?.spine;
    if (spine == null) return null;

    final exactIndex = spine.indexWhere((item) => item.item.path == path);
    if (exactIndex >= 0) return exactIndex;

    final target = _normalizeArchivePathForLookup(path).toLowerCase();
    int? match;
    for (var index = 0; index < spine.length; index++) {
      final itemPath = spine[index].item.path;
      if (itemPath == null ||
          _normalizeArchivePathForLookup(itemPath).toLowerCase() != target) {
        continue;
      }
      if (match != null) return null;
      match = index;
    }
    return match;
  }

  Future<bool> _goToArchivePath(
    String path, {
    required String fragment,
  }) async {
    final index = _spineIndexForArchivePath(path);
    if (index == null) return false;
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

    _chapterPreloadTimer?.cancel();
    _chapterPreloadTimer = null;
    final revision = ++_navigationRevision;
    _chapterLoading = true;
    _error = null;
    notifyListeners();

    late final FrameEpubChapterDocument chapter;
    try {
      chapter = await loader.loadChapter(epub.spine[index]);
    } on Object catch (error) {
      if (_closed) return false;
      if (revision != _navigationRevision) return true;
      _chapterLoading = false;
      _error = '無法載入章節：$error';
      notifyListeners();
      return false;
    }

    if (_closed) return false;
    // A newer click has taken over navigation. Treat this older request as
    // handled so it cannot show a false "no readable chapter" message.
    if (revision != _navigationRevision) return true;
    _currentSpineIndex = index;
    _currentFragment = fragment;
    _initialCfi = null;
    _restoredCfiLocation = null;
    _chapter = chapter;
    _chapterLoading = false;
    notifyListeners();
    _scheduleNextChapterPreload();

    if (saveProgress) {
      unawaited(
        _saveNavigationProgress(
          index: index,
          label: currentChapterLabel,
          percent: isFixedLayout
              ? fixedLayoutReadingProgressPercent
              : chapterProgressPercent,
        ),
      );
    }
    return true;
  }

  Future<void> _saveNavigationProgress({
    required int index,
    required String label,
    required int percent,
  }) async {
    try {
      await _queueProgressSave(
        index: index,
        label: label,
        percent: percent,
        cfi: '',
      );
    } on Object {
      // The session warning already exposes the failed cloud sync.
    }
  }

  void _scheduleNextChapterPreload() {
    _chapterPreloadTimer?.cancel();
    _chapterPreloadTimer = null;

    final epub = _epub;
    final loader = _loader;
    final index = _currentSpineIndex;
    if (_closed || epub == null || loader == null || index == null) {
      return;
    }

    final nextIndex = _nextLinearSpineIndex(index);
    if (nextIndex == null) return;
    final nextChapter = epub.spine[nextIndex];
    if (nextChapter.item.path == null) return;
    final revision = _navigationRevision;
    _chapterPreloadTimer = Timer(chapterPreloadDelay, () {
      _chapterPreloadTimer = null;
      if (_closed ||
          _navigationRevision != revision ||
          _currentSpineIndex != index ||
          !identical(_loader, loader)) {
        return;
      }
      unawaited(loader.preloadChapter(nextChapter));
    });
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
    final epub = _epub;
    final index = _currentSpineIndex;
    if (epub == null ||
        index == null ||
        FrameEpubCfi.spineIndexFromCfi(epub, cfi) != index) {
      throw ArgumentError('閱讀位置 CFI 與目前 EPUB 章節不一致。');
    }
    await _queueProgressSave(
      index: index,
      label: currentChapterLabel,
      percent: percent.clamp(0, 100).toInt(),
      cfi: cfi,
    );
  }

  Future<void> _queueProgressSave({
    required int index,
    required String label,
    required int percent,
    required String cfi,
  }) {
    final nextSave = _progressSaveQueue
        .catchError((Object _) {})
        .then((_) => _saveProgress(
              index: index,
              label: label,
              percent: percent,
              cfi: cfi,
            ));
    _progressSaveQueue = nextSave;
    return nextSave;
  }

  Future<void> _saveProgress({
    required int index,
    required String label,
    required int percent,
    required String cfi,
  }) async {
    try {
      final readerState = await repository.saveState(
        book,
        progress: {
          'percent': percent,
          'label': label,
          'cfi': cfi,
          'index': index,
        },
        lastOpenedAt: DateTime.now().millisecondsSinceEpoch,
      );
      if (_closed) return;
      _readerState = readerState;
      _warning = null;
      notifyListeners();
    } on Object catch (error) {
      if (_closed) return;
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
    _annotationMutationRevision++;
    notifyListeners();
    return saved;
  }

  Future<void> deleteAnnotation(String annotationId) async {
    await repository.deleteAnnotation(book, annotationId);
    _annotations = _annotations
        .where((item) => item.id != annotationId)
        .toList(growable: false);
    _annotationMutationRevision++;
    notifyListeners();
  }

  /// Reloads this book's annotations from the existing D1-backed API.
  ///
  /// A response is discarded when a newer refresh or a local annotation
  /// mutation has happened while the request was in flight.
  Future<void> refreshAnnotations() async {
    if (_closed) return;
    final mutationRevision = _annotationMutationRevision;
    final request = ++_annotationRefreshRequest;
    final refreshed = await repository.loadAnnotations(book);
    if (_closed ||
        request != _annotationRefreshRequest ||
        mutationRevision != _annotationMutationRevision) {
      return;
    }
    _annotations = refreshed;
    notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _navigationRevision++;
    _chapterPreloadTimer?.cancel();
    _chapterPreloadTimer = null;
    _status = FrameEpubReaderStatus.closed;
    _chapterLoading = false;
    final archive = _archive;
    final loader = _loader;
    _archive = null;
    _loader = null;
    _chapter = null;
    loader?.dispose();
    if (archive != null) await archive.close();
    notifyListeners();
  }

  @override
  void dispose() {
    if (!_closed) {
      _closed = true;
      _navigationRevision++;
      _chapterPreloadTimer?.cancel();
      _chapterPreloadTimer = null;
      final archive = _archive;
      final loader = _loader;
      _archive = null;
      _loader = null;
      loader?.dispose();
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
