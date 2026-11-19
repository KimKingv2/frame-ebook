import 'dart:convert';

import 'package:xml/xml.dart';

import 'frame_zip_archive.dart';

class FrameEpubParserException implements Exception {
  const FrameEpubParserException(this.message);
  final String message;
  @override
  String toString() => 'FrameEpubParserException: $message';
}

enum FrameEpubLayout { reflowable, prePaginated }

enum FrameEpubPageProgressionDirection {
  defaultDirection,
  leftToRight,
  rightToLeft,
}

class FrameEpubMetadata {
  const FrameEpubMetadata({
    required this.title,
    required this.creators,
    required this.language,
    required this.publisher,
    required this.publicationDate,
    required this.identifier,
    required this.subjects,
    required this.description,
  });

  final String title;
  final List<String> creators;
  final String language;
  final String publisher;
  final String publicationDate;
  final String identifier;
  final List<String> subjects;
  final String description;
  String get author => creators.join(', ');
}

class FrameEpubResourceReference {
  const FrameEpubResourceReference({
    required this.originalHref,
    required this.path,
    required this.fragment,
    required this.query,
    required this.isExternal,
  });

  final String originalHref;
  final String? path;
  final String fragment;
  final String query;
  final bool isExternal;
  bool get isInternal => !isExternal && path != null;

  String get href {
    if (isExternal) return originalHref;
    final suffix = [
      if (query.isNotEmpty) '?$query',
      if (fragment.isNotEmpty) '#$fragment',
    ].join();
    return (path ?? '') + suffix;
  }
}

class FrameEpubManifestItem {
  FrameEpubManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.reference,
    required Set<String> properties,
    required this.fallback,
  }) : properties = Set.unmodifiable(properties);

  final String id;
  final String href;
  final String mediaType;
  final FrameEpubResourceReference reference;
  final Set<String> properties;
  final String fallback;
  String? get path => reference.path;
  bool get isExternal => reference.isExternal;
  bool get isNavigationDocument => properties.contains('nav');
  bool get isCoverImage => properties.contains('cover-image');
}

class FrameEpubSpineItem {
  const FrameEpubSpineItem({
    required this.idref,
    required this.item,
    required this.linear,
    this.itemrefId = '',
  });

  final String itemrefId;
  final String idref;
  final FrameEpubManifestItem item;
  final bool linear;
}

class FrameEpubTocEntry {
  FrameEpubTocEntry({
    required this.label,
    required this.reference,
    required List<FrameEpubTocEntry> children,
  }) : children = List.unmodifiable(children);

  final String label;
  final FrameEpubResourceReference? reference;
  final List<FrameEpubTocEntry> children;
  String? get path => reference?.path;
  String get fragment => reference?.fragment ?? '';
  bool get isExternal => reference?.isExternal ?? false;
}

class FrameEpubBook {
  FrameEpubBook({
    required this.packagePath,
    required this.version,
    required this.uniqueIdentifierId,
    required this.metadata,
    required Map<String, FrameEpubManifestItem> manifest,
    required List<FrameEpubSpineItem> spine,
    required List<FrameEpubTocEntry> toc,
    required this.navigationPath,
    required this.coverImage,
    required this.layout,
    required this.pageProgressionDirection,
    required this.spread,
    required this.orientation,
    required this.flow,
    required List<String> warnings,
  })  : manifest = Map.unmodifiable(manifest),
        spine = List.unmodifiable(spine),
        toc = List.unmodifiable(toc),
        warnings = List.unmodifiable(warnings);

  final String packagePath;
  final String version;
  final String uniqueIdentifierId;
  final FrameEpubMetadata metadata;
  final Map<String, FrameEpubManifestItem> manifest;
  final List<FrameEpubSpineItem> spine;
  final List<FrameEpubTocEntry> toc;
  final String? navigationPath;
  final FrameEpubManifestItem? coverImage;
  final FrameEpubLayout layout;
  final FrameEpubPageProgressionDirection pageProgressionDirection;
  final String spread;
  final String orientation;
  final String flow;
  final List<String> warnings;
  bool get isFixedLayout => layout == FrameEpubLayout.prePaginated;
}

/// Parses EPUB 2 and EPUB 3 package metadata using bounded ZIP entry reads.
///
/// The archive stays backed by FrameZipArchive's HTTP Range reader. Only the
/// small XML control documents are materialized; chapters and media remain
/// independent resources and are never collected as a complete archive.
class FrameEpubParser {
  const FrameEpubParser({
    this.maxContainerBytes = 1024 * 1024,
    this.maxPackageBytes = 8 * 1024 * 1024,
    this.maxNavigationBytes = 8 * 1024 * 1024,
  });

  final int maxContainerBytes;
  final int maxPackageBytes;
  final int maxNavigationBytes;

  Future<FrameEpubBook> parse(FrameZipArchive archive) async {
    final warnings = <String>[];

    final mimetype = archive.file('mimetype');
    if (mimetype != null) {
      final value = utf8.decode(
        await archive.readBytes(mimetype, maxBytes: 128),
        allowMalformed: false,
      ).trim();
      if (value != 'application/epub+zip') {
        throw const FrameEpubParserException('EPUB 的 mimetype 內容不正確。');
      }
    }

    final containerEntry = archive.file('META-INF/container.xml');
    if (containerEntry == null) {
      throw const FrameEpubParserException(
        'EPUB 缺少 META-INF/container.xml。',
      );
    }
    final container = await _readXml(
      archive,
      containerEntry,
      maxBytes: maxContainerBytes,
      description: 'container.xml',
    );
    final rootfiles = _descendants(container.rootElement, 'rootfile');
    if (rootfiles.isEmpty) {
      throw const FrameEpubParserException(
        'container.xml 沒有宣告 OPF rootfile。',
      );
    }

    XmlElement? selectedRootfile;
    for (final candidate in rootfiles) {
      if (_attribute(candidate, 'media-type') ==
          'application/oebps-package+xml') {
        selectedRootfile = candidate;
        break;
      }
    }
    selectedRootfile ??= rootfiles.first;
    final rootfileHref = _attribute(selectedRootfile, 'full-path') ?? '';
    if (rootfileHref.trim().isEmpty) {
      throw const FrameEpubParserException(
        'container.xml 的 OPF rootfile 缺少 full-path。',
      );
    }

    final packageReference = resolveHref(rootfileHref, baseFilePath: '');
    if (!packageReference.isInternal || packageReference.path == null) {
      throw const FrameEpubParserException(
        'EPUB 的 OPF rootfile 必須位於壓縮檔內。',
      );
    }
    final packagePath = packageReference.path!;
    final packageEntry = archive.file(packagePath);
    if (packageEntry == null) {
      throw FrameEpubParserException('找不到 OPF 套件文件：$packagePath');
    }

    final packageDocument = await _readXml(
      archive,
      packageEntry,
      maxBytes: maxPackageBytes,
      description: 'OPF package',
    );
    final packageElement = packageDocument.rootElement;
    if (packageElement.name.local != 'package') {
      throw const FrameEpubParserException('OPF 文件根節點不是 package。');
    }

    final metadataElement = _firstChild(packageElement, 'metadata');
    final manifestElement = _firstChild(packageElement, 'manifest');
    final spineElement = _firstChild(packageElement, 'spine');
    if (metadataElement == null ||
        manifestElement == null ||
        spineElement == null) {
      throw const FrameEpubParserException(
        'OPF 缺少 metadata、manifest 或 spine。',
      );
    }

    final uniqueIdentifierId =
        _attribute(packageElement, 'unique-identifier') ?? '';
    final metadata = _parseMetadata(metadataElement, uniqueIdentifierId);
    final manifest = _parseManifest(
      manifestElement,
      packagePath: packagePath,
    );
    if (manifest.isEmpty) {
      throw const FrameEpubParserException('OPF manifest 沒有任何資源。');
    }
    final spine = _parseSpine(spineElement, manifest);
    if (spine.isEmpty) {
      throw const FrameEpubParserException('OPF spine 沒有有效的閱讀章節。');
    }

    FrameEpubManifestItem? navigationItem;
    for (final item in manifest.values) {
      if (item.isNavigationDocument) {
        navigationItem = item;
        break;
      }
    }

    var toc = <FrameEpubTocEntry>[];
    String? navigationPath;
    final navPath = navigationItem?.path;
    if (navPath != null && archive.file(navPath) != null) {
      navigationPath = navPath;
      try {
        final navigationEntry = archive.file(navPath)!;
        final navigationDocument = await _readXml(
          archive,
          navigationEntry,
          maxBytes: maxNavigationBytes,
          description: 'EPUB 3 navigation document',
        );
        toc = _parseEpub3Toc(navigationDocument, navPath, warnings);
      } on Object catch (error) {
        warnings.add('EPUB 3 導覽文件無法解析：$error');
      }
    }

    if (toc.isEmpty) {
      final ncxItem = _findNcxItem(spineElement, manifest);
      final ncxPath = ncxItem?.path;
      if (ncxPath != null && archive.file(ncxPath) != null) {
        navigationPath ??= ncxPath;
        try {
          final ncxEntry = archive.file(ncxPath)!;
          final ncxDocument = await _readXml(
            archive,
            ncxEntry,
            maxBytes: maxNavigationBytes,
            description: 'EPUB 2 NCX navigation document',
          );
          toc = _parseNcxToc(ncxDocument, ncxPath, warnings);
        } on Object catch (error) {
          warnings.add('EPUB 2 NCX 目錄無法解析：$error');
        }
      }
    }

    final coverImage = _findCoverImage(metadataElement, manifest);
    final layoutValue =
        _globalMetaValue(metadataElement, 'rendition:layout').toLowerCase();
    final directionValue =
        (_attribute(spineElement, 'page-progression-direction') ?? '')
            .toLowerCase();

    return FrameEpubBook(
      packagePath: packagePath,
      version: _attribute(packageElement, 'version') ?? '',
      uniqueIdentifierId: uniqueIdentifierId,
      metadata: metadata,
      manifest: manifest,
      spine: spine,
      toc: toc,
      navigationPath: navigationPath,
      coverImage: coverImage,
      layout: layoutValue == 'pre-paginated'
          ? FrameEpubLayout.prePaginated
          : FrameEpubLayout.reflowable,
      pageProgressionDirection: switch (directionValue) {
        'ltr' => FrameEpubPageProgressionDirection.leftToRight,
        'rtl' => FrameEpubPageProgressionDirection.rightToLeft,
        _ => FrameEpubPageProgressionDirection.defaultDirection,
      },
      spread: _globalMetaValue(metadataElement, 'rendition:spread'),
      orientation:
          _globalMetaValue(metadataElement, 'rendition:orientation'),
      flow: _globalMetaValue(metadataElement, 'rendition:flow'),
      warnings: warnings,
    );
  }

  /// Resolves an EPUB URI against an archive file without permitting traversal.
  ///
  /// Absolute URI references are returned as external references and are never
  /// fetched by this parser. Internal paths are decoded and normalized inside
  /// the archive root. A fragment-only href targets the current file.
  static FrameEpubResourceReference resolveHref(
    String href, {
    required String baseFilePath,
  }) {
    final value = href.trim();
    if (value.isEmpty) {
      throw const FrameEpubParserException('EPUB 資源 href 不可為空白。');
    }

    late final Uri uri;
    try {
      uri = Uri.parse(value);
    } on FormatException catch (error) {
      throw FrameEpubParserException('EPUB 資源 URI 格式錯誤：$error');
    }

    if (uri.hasScheme || uri.hasAuthority) {
      return FrameEpubResourceReference(
        originalHref: value,
        path: null,
        fragment: uri.fragment,
        query: uri.query,
        isExternal: true,
      );
    }

    final rawPath = uri.path;
    final segments = <String>[];
    final isArchiveAbsolute = rawPath.startsWith('/');
    if (rawPath.isEmpty) {
      if (baseFilePath.isEmpty) {
        throw const FrameEpubParserException(
          'EPUB rootfile 缺少實際資源路徑。',
        );
      }
      segments.addAll(baseFilePath.split('/'));
    } else if (!isArchiveAbsolute && baseFilePath.isNotEmpty) {
      segments.addAll(baseFilePath.split('/')..removeLast());
    }

    for (final rawSegment in rawPath.split('/')) {
      if (rawSegment.isEmpty) continue;
      late final String segment;
      try {
        segment = Uri.decodeComponent(rawSegment);
      } on FormatException catch (error) {
        throw FrameEpubParserException('EPUB 路徑編碼錯誤：$error');
      }
      if (segment.contains('/') ||
          segment.contains(r'\') ||
          segment.contains('\u0000') ||
          segment.contains('\n') ||
          segment.contains('\r')) {
        throw const FrameEpubParserException('EPUB 資源路徑包含不安全字元。');
      }
      if (segment == '.') continue;
      if (segment == '..') {
        if (segments.isEmpty) {
          throw const FrameEpubParserException(
            'EPUB 資源路徑試圖離開壓縮檔根目錄。',
          );
        }
        segments.removeLast();
      } else {
        segments.add(segment);
      }
    }

    if (segments.isEmpty) {
      throw const FrameEpubParserException('EPUB 資源路徑解析後為空。');
    }

    return FrameEpubResourceReference(
      originalHref: value,
      path: segments.join('/'),
      fragment: uri.fragment,
      query: uri.query,
      isExternal: false,
    );
  }
}

Future<XmlDocument> _readXml(
  FrameZipArchive archive,
  FrameZipArchiveEntry entry, {
  required int maxBytes,
  required String description,
}) async {
  try {
    final bytes = await archive.readBytes(entry, maxBytes: maxBytes);
    var source = utf8.decode(bytes, allowMalformed: false);
    if (source.startsWith('\uFEFF')) {
      source = source.substring(1);
    }
    return XmlDocument.parse(source);
  } on Object catch (error) {
    throw FrameEpubParserException('$description 無法讀取或解析：$error');
  }
}

FrameEpubMetadata _parseMetadata(
  XmlElement element,
  String uniqueIdentifierId,
) {
  final titles = _directTexts(element, 'title');
  final creators = _directTexts(element, 'creator');
  final languages = _directTexts(element, 'language');
  final publishers = _directTexts(element, 'publisher');
  final dates = _directTexts(element, 'date');
  final subjects = _directTexts(element, 'subject');
  final descriptions = _directTexts(element, 'description');

  var identifier = '';
  final identifiers = _children(element, 'identifier');
  for (final candidate in identifiers) {
    if (_attribute(candidate, 'id') == uniqueIdentifierId &&
        uniqueIdentifierId.isNotEmpty) {
      identifier = candidate.innerText.trim();
      break;
    }
  }
  if (identifier.isEmpty && identifiers.isNotEmpty) {
    identifier = identifiers.first.innerText.trim();
  }

  return FrameEpubMetadata(
    title: titles.isEmpty ? '' : titles.first,
    creators: List.unmodifiable(creators),
    language: languages.isEmpty ? '' : languages.first,
    publisher: publishers.isEmpty ? '' : publishers.first,
    publicationDate: dates.isEmpty ? '' : dates.first,
    identifier: identifier,
    subjects: List.unmodifiable(subjects),
    description: descriptions.isEmpty ? '' : descriptions.first,
  );
}

Map<String, FrameEpubManifestItem> _parseManifest(
  XmlElement manifestElement, {
  required String packagePath,
}) {
  final result = <String, FrameEpubManifestItem>{};
  for (final element in _children(manifestElement, 'item')) {
    final id = _attribute(element, 'id') ?? '';
    final href = _attribute(element, 'href') ?? '';
    final mediaType = _attribute(element, 'media-type') ?? '';
    if (id.isEmpty || href.isEmpty || mediaType.isEmpty) continue;
    if (result.containsKey(id)) {
      throw FrameEpubParserException('OPF manifest 出現重複的 id：$id');
    }

    final reference = FrameEpubParser.resolveHref(
      href,
      baseFilePath: packagePath,
    );
    result[id] = FrameEpubManifestItem(
      id: id,
      href: href,
      mediaType: mediaType,
      reference: reference,
      properties: _tokens(_attribute(element, 'properties') ?? ''),
      fallback: _attribute(element, 'fallback') ?? '',
    );
  }
  return result;
}

List<FrameEpubSpineItem> _parseSpine(
  XmlElement spineElement,
  Map<String, FrameEpubManifestItem> manifest,
) {
  final result = <FrameEpubSpineItem>[];
  for (final itemref in _children(spineElement, 'itemref')) {
    final idref = _attribute(itemref, 'idref') ?? '';
    final item = manifest[idref];
    if (item == null) continue;
    final linearValue = (_attribute(itemref, 'linear') ?? 'yes').toLowerCase();
    result.add(
      FrameEpubSpineItem(
        idref: idref,
        item: item,
        linear: linearValue != 'no',
        itemrefId: _attribute(itemref, 'id') ?? '',
      ),
    );
  }
  return result;
}

FrameEpubManifestItem? _findCoverImage(
  XmlElement metadataElement,
  Map<String, FrameEpubManifestItem> manifest,
) {
  for (final item in manifest.values) {
    if (item.isCoverImage) return item;
  }

  for (final meta in _children(metadataElement, 'meta')) {
    if (_attribute(meta, 'name') == 'cover') {
      final coverId = _attribute(meta, 'content') ?? '';
      if (coverId.isNotEmpty) return manifest[coverId];
    }
  }
  return null;
}

FrameEpubManifestItem? _findNcxItem(
  XmlElement spineElement,
  Map<String, FrameEpubManifestItem> manifest,
) {
  final tocId = _attribute(spineElement, 'toc') ?? '';
  if (tocId.isNotEmpty && manifest.containsKey(tocId)) {
    return manifest[tocId];
  }
  for (final item in manifest.values) {
    if (item.mediaType == 'application/x-dtbncx+xml') return item;
  }
  return null;
}

List<FrameEpubTocEntry> _parseEpub3Toc(
  XmlDocument document,
  String navigationPath,
  List<String> warnings,
) {
  for (final nav in document.descendants.whereType<XmlElement>()) {
    if (nav.name.local != 'nav') continue;
    if (!_tokens(_attribute(nav, 'type') ?? '').contains('toc')) continue;
    final list = _firstChild(nav, 'ol');
    if (list == null) continue;
    return _parseNavList(list, navigationPath, warnings);
  }
  return [];
}

List<FrameEpubTocEntry> _parseNavList(
  XmlElement list,
  String navigationPath,
  List<String> warnings,
) {
  final result = <FrameEpubTocEntry>[];
  for (final item in _children(list, 'li')) {
    XmlElement? labelElement;
    for (final child in item.children.whereType<XmlElement>()) {
      if (child.name.local == 'a' || child.name.local == 'span') {
        labelElement = child;
        break;
      }
      if (child.name.local == 'ol') break;
    }

    final label = labelElement?.innerText.trim() ?? '';
    final href = labelElement == null ? null : _attribute(labelElement, 'href');
    FrameEpubResourceReference? reference;
    if (href != null && href.isNotEmpty) {
      try {
        reference = FrameEpubParser.resolveHref(
          href,
          baseFilePath: navigationPath,
        );
      } on FrameEpubParserException catch (error) {
        warnings.add('略過不安全的 EPUB 目錄連結：' + error.message);
      }
    }

    final nestedList = _firstChild(item, 'ol');
    final children = nestedList == null
        ? <FrameEpubTocEntry>[]
        : _parseNavList(nestedList, navigationPath, warnings);
    if (label.isNotEmpty || reference != null || children.isNotEmpty) {
      result.add(
        FrameEpubTocEntry(
          label: label,
          reference: reference,
          children: children,
        ),
      );
    }
  }
  return result;
}

List<FrameEpubTocEntry> _parseNcxToc(
  XmlDocument document,
  String ncxPath,
  List<String> warnings,
) {
  XmlElement? navMap;
  for (final element in document.descendants.whereType<XmlElement>()) {
    if (element.name.local == 'navMap') {
      navMap = element;
      break;
    }
  }
  if (navMap == null) return [];
  return _parseNcxPoints(navMap, ncxPath, warnings);
}

List<FrameEpubTocEntry> _parseNcxPoints(
  XmlElement parent,
  String ncxPath,
  List<String> warnings,
) {
  final result = <FrameEpubTocEntry>[];
  for (final point in _children(parent, 'navPoint')) {
    final navLabel = _firstChild(point, 'navLabel');
    final textElement =
        navLabel == null ? null : _firstDescendant(navLabel, 'text');
    final content = _firstChild(point, 'content');
    final src = content == null ? null : _attribute(content, 'src');
    FrameEpubResourceReference? reference;
    if (src != null && src.isNotEmpty) {
      try {
        reference = FrameEpubParser.resolveHref(
          src,
          baseFilePath: ncxPath,
        );
      } on FrameEpubParserException catch (error) {
        warnings.add('略過不安全的 NCX 目錄連結：' + error.message);
      }
    }

    final label = textElement?.innerText.trim() ?? '';
    final children = _parseNcxPoints(point, ncxPath, warnings);
    if (label.isNotEmpty || reference != null || children.isNotEmpty) {
      result.add(
        FrameEpubTocEntry(
          label: label,
          reference: reference,
          children: children,
        ),
      );
    }
  }
  return result;
}

String _globalMetaValue(XmlElement metadata, String property) {
  for (final meta in _children(metadata, 'meta')) {
    if (_attribute(meta, 'property') == property &&
        (_attribute(meta, 'refines') ?? '').isEmpty) {
      final value = meta.innerText.trim();
      if (value.isNotEmpty) return value;
    }
  }
  return '';
}

List<String> _directTexts(XmlElement parent, String localName) =>
    _children(parent, localName)
        .map((element) => element.innerText.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);

List<XmlElement> _children(XmlElement parent, String localName) =>
    parent.children
        .whereType<XmlElement>()
        .where((element) => element.name.local == localName)
        .toList(growable: false);

List<XmlElement> _descendants(XmlElement parent, String localName) =>
    parent.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == localName)
        .toList(growable: false);

XmlElement? _firstChild(XmlElement parent, String localName) {
  for (final child in parent.children.whereType<XmlElement>()) {
    if (child.name.local == localName) return child;
  }
  return null;
}

XmlElement? _firstDescendant(XmlElement parent, String localName) {
  for (final child in parent.descendants.whereType<XmlElement>()) {
    if (child.name.local == localName) return child;
  }
  return null;
}

String? _attribute(XmlElement element, String localName) {
  for (final attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value;
  }
  return null;
}

Set<String> _tokens(String value) => value
    .split(RegExp(r'\s+'))
    .map((token) => token.trim())
    .where((token) => token.isNotEmpty)
    .toSet();
