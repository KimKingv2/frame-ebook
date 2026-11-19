import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'frame_epub_parser.dart';
import 'frame_zip_archive.dart';

enum FrameEpubResourceKind {
  document,
  stylesheet,
  image,
  svg,
  font,
  audio,
  video,
  other,
}

enum FrameEpubCssReferenceKind { import, url }

class FrameEpubResource {
  const FrameEpubResource._({
    required this.path,
    required this.mediaType,
    required this.size,
    required this.manifestItem,
    required this._entry,
  });

  final String path;
  final String mediaType;
  final int size;
  final FrameEpubManifestItem? manifestItem;
  final FrameZipArchiveEntry _entry;

  FrameEpubResourceKind get kind => _resourceKind(mediaType, path);
}

class FrameEpubResolvedReference {
  const FrameEpubResolvedReference({
    required this.originalHref,
    required this.path,
    required this.fragment,
    required this.query,
    required this.isExternal,
    required this.resource,
  });

  final String originalHref;
  final String? path;
  final String fragment;
  final String query;
  final bool isExternal;
  final FrameEpubResource? resource;

  bool get exists => isExternal || resource != null;
  bool get isInternal => !isExternal && path != null;
  bool get isMissing => isInternal && resource == null;
}

class FrameEpubDocumentReference {
  const FrameEpubDocumentReference({
    required this.elementName,
    required this.attributeName,
    required this.kind,
    required this.reference,
  });

  final String elementName;
  final String attributeName;
  final FrameEpubResourceKind kind;
  final FrameEpubResolvedReference reference;
}

class FrameEpubCssReference {
  const FrameEpubCssReference({
    required this.href,
    required this.kind,
  });

  final String href;
  final FrameEpubCssReferenceKind kind;
}

class FrameEpubResolvedCssReference {
  const FrameEpubResolvedCssReference({
    required this.reference,
    required this.kind,
  });

  final FrameEpubResolvedReference reference;
  final FrameEpubCssReferenceKind kind;
}

class FrameEpubChapterDocument {
  FrameEpubChapterDocument({
    required this.resource,
    required this.xhtml,
    required this.document,
    required List<FrameEpubDocumentReference> references,
    required List<String> warnings,
  })  : references = List.unmodifiable(references),
        warnings = List.unmodifiable(warnings);

  final FrameEpubResource resource;
  final String xhtml;
  final XmlDocument document;
  final List<FrameEpubDocumentReference> references;
  final List<String> warnings;

  Iterable<FrameEpubDocumentReference> get stylesheets => references.where(
        (reference) =>
            reference.kind == FrameEpubResourceKind.stylesheet &&
            reference.reference.resource != null,
      );

  Iterable<FrameEpubDocumentReference> get images => references.where(
        (reference) =>
            (reference.kind == FrameEpubResourceKind.image ||
                reference.kind == FrameEpubResourceKind.svg) &&
            reference.reference.resource != null,
      );

  Iterable<FrameEpubDocumentReference> get hyperlinks => references.where(
        (reference) => reference.attributeName == 'href' &&
            reference.elementName == 'a',
      );
}

class FrameEpubStylesheetDocument {
  FrameEpubStylesheetDocument({
    required this.resource,
    required this.css,
    required List<FrameEpubResolvedCssReference> references,
  }) : references = List.unmodifiable(references);

  final FrameEpubResource resource;
  final String css;
  final List<FrameEpubResolvedCssReference> references;

  Iterable<FrameEpubResolvedCssReference> get imports => references.where(
        (reference) => reference.kind == FrameEpubCssReferenceKind.import,
      );

  Iterable<FrameEpubResolvedCssReference> get urls => references.where(
        (reference) => reference.kind == FrameEpubCssReferenceKind.url,
      );
}

class FrameEpubStylesheetGraph {
  FrameEpubStylesheetGraph({
    required Map<String, FrameEpubStylesheetDocument> stylesheets,
    required List<String> warnings,
  })  : stylesheets = Map.unmodifiable(stylesheets),
        warnings = List.unmodifiable(warnings);

  final Map<String, FrameEpubStylesheetDocument> stylesheets;
  final List<String> warnings;
}

/// Resolves and loads EPUB documents and their embedded resources.
///
/// All archive access stays behind FrameZipArchive. XML/XHTML, CSS, images and
/// fonts are read as individual entries with independent size limits. This
/// loader does not fetch external network URLs or create persistent caches.
class FrameEpubResourceLoader {
  FrameEpubResourceLoader({
    required this.archive,
    required this.book,
    this.maxXhtmlBytes = 16 * 1024 * 1024,
    this.maxStylesheetBytes = 4 * 1024 * 1024,
    this.maxImageBytes = 64 * 1024 * 1024,
    this.maxSvgBytes = 8 * 1024 * 1024,
    this.maxTotalStylesheetBytes = 16 * 1024 * 1024,
    this.maxFontBytes = 32 * 1024 * 1024,
    this.maxOtherResourceBytes = 16 * 1024 * 1024,
  }) {
    for (final entry in archive.files) {
      final item = _manifestByPath[entry.path];
      _resources[entry.path] = FrameEpubResource._(
        path: entry.path,
        mediaType: item?.mediaType ?? _mediaTypeForPath(entry.path),
        size: entry.size,
        manifestItem: item,
        _entry: entry,
      );
    }
  }

  final FrameZipArchive archive;
  final FrameEpubBook book;
  final int maxXhtmlBytes;
  final int maxStylesheetBytes;
  final int maxImageBytes;
  final int maxSvgBytes;
  final int maxTotalStylesheetBytes;
  final int maxFontBytes;
  final int maxOtherResourceBytes;

  final Map<String, FrameEpubResource> _resources = {};
  late final Map<String, FrameEpubManifestItem> _manifestByPath = {
    for (final item in book.manifest.values)
      if (item.path != null && !item.isExternal) item.path!: item,
  };

  List<FrameEpubResource> get resources =>
      List.unmodifiable(_resources.values);

  FrameEpubResource? resource(String path) => _resources[path];

  FrameEpubResolvedReference resolve(
    String href, {
    required String fromPath,
  }) {
    final resolved = FrameEpubParser.resolveHref(
      href,
      baseFilePath: fromPath,
    );
    return FrameEpubResolvedReference(
      originalHref: resolved.originalHref,
      path: resolved.path,
      fragment: resolved.fragment,
      query: resolved.query,
      isExternal: resolved.isExternal,
      resource: resolved.path == null ? null : _resources[resolved.path],
    );
  }

  Future<Uint8List> readBytes(
    FrameEpubResource resource, {
    int? maxBytes,
  }) {
    _ensureResource(resource);
    final limit = maxBytes ?? _defaultLimit(resource.kind);
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'maxBytes', '必須大於 0。');
    }
    return archive.readBytes(resource._entry, maxBytes: limit);
  }

  Stream<Uint8List> openRead(FrameEpubResource resource) {
    _ensureResource(resource);
    return archive.openRead(resource._entry);
  }

  Future<String> readText(
    FrameEpubResource resource, {
    int? maxBytes,
  }) async {
    _ensureResource(resource);
    if (resource.kind == FrameEpubResourceKind.image ||
        resource.kind == FrameEpubResourceKind.font ||
        resource.kind == FrameEpubResourceKind.audio ||
        resource.kind == FrameEpubResourceKind.video) {
      throw ArgumentError('二進位 EPUB 資源不可當作文字讀取。');
    }
    final bytes = await readBytes(
      resource,
      maxBytes: maxBytes ?? _defaultLimit(resource.kind),
    );
    return _decodeEpubText(bytes);
  }

  Future<FrameEpubChapterDocument> loadChapter(
    FrameEpubSpineItem spineItem,
  ) async {
    final path = spineItem.item.path;
    if (path == null) {
      throw const FrameEpubResourceException(
        '閱讀章節指向外部 URI，無法載入成 EPUB 章節。',
      );
    }
    final chapter = _resources[path];
    if (chapter == null) {
      throw FrameEpubResourceException('找不到 EPUB 章節：$path');
    }
    if (chapter.kind != FrameEpubResourceKind.document) {
      throw FrameEpubResourceException('EPUB spine 項目不是 XHTML 文件：$path');
    }

    final xhtml = await readText(chapter, maxBytes: maxXhtmlBytes);
    late final XmlDocument document;
    try {
      document = XmlDocument.parse(xhtml);
    } on XmlException catch (error) {
      throw FrameEpubResourceException('XHTML 文件格式錯誤：$path：$error');
    }

    final references = <FrameEpubDocumentReference>[];
    final warnings = <String>[];
    for (final element in document.descendants.whereType<XmlElement>()) {
      final name = element.name.local.toLowerCase();
      for (final attribute in element.attributes) {
        final attributeName = attribute.name.local.toLowerCase();
        if (attributeName == 'style') {
          for (final cssReference in extractCssReferences(attribute.value)) {
            final target = resolve(
              cssReference.href,
              fromPath: chapter.path,
            );
            references.add(
              FrameEpubDocumentReference(
                elementName: name,
                attributeName: 'style',
                kind: target.resource?.kind ?? FrameEpubResourceKind.other,
                reference: target,
              ),
            );
            if (target.isMissing) {
              warnings.add('找不到 XHTML inline style 資源：' +
                  (target.path ?? cssReference.href));
            }
          }
          continue;
        }

        if (name == 'link' && attributeName == 'href') {
          final rel = element.attributes
              .where((item) => item.name.local.toLowerCase() == 'rel')
              .map((item) => item.value)
              .firstOrNull ?? '';
          if (!_tokens(rel).contains('stylesheet')) continue;
        }
        final role = _documentAttributeRole(name, attributeName);
        if (role == null) continue;
        final target = resolve(attribute.value, fromPath: chapter.path);
        references.add(
          FrameEpubDocumentReference(
            elementName: name,
            attributeName: attributeName,
            kind: target.resource?.kind ?? role,
            reference: target,
          ),
        );
        if (target.isMissing) {
          warnings.add('找不到 XHTML 資源：' +
              (target.path ?? attribute.value));
        }
      }

      if (name == 'style') {
        for (final cssReference in extractCssReferences(element.innerText)) {
          final target = resolve(
            cssReference.href,
            fromPath: chapter.path,
          );
          references.add(
            FrameEpubDocumentReference(
              elementName: name,
              attributeName: 'text',
              kind: target.resource?.kind ?? FrameEpubResourceKind.other,
              reference: target,
            ),
          );
          if (target.isMissing) {
            warnings.add('找不到 XHTML style 資源：' +
                (target.path ?? cssReference.href));
          }
        }
      }
    }

    return FrameEpubChapterDocument(
      resource: chapter,
      xhtml: xhtml,
      document: document,
      references: references,
      warnings: warnings,
    );
  }

  Future<FrameEpubStylesheetGraph> loadStylesheetGraph(
    String entryPath, {
    int maxDepth = 8,
    int maxStylesheets = 128,
  }) async {
    if (maxDepth < 0 || maxStylesheets <= 0) {
      throw ArgumentError('CSS 解析上限無效。');
    }

    final loaded = <String, FrameEpubStylesheetDocument>{};
    final warnings = <String>[];
    var totalStylesheetBytes = 0;
    final queue = <(String, int)>[(entryPath, 0)];
    final scheduled = <String>{entryPath};

    while (queue.isNotEmpty) {
      final (path, depth) = queue.removeAt(0);
      if (loaded.containsKey(path)) continue;
      if (depth > maxDepth) {
        warnings.add('CSS @import 巢狀深度超過上限，略過：$path');
        continue;
      }
      if (loaded.length >= maxStylesheets) {
        warnings.add('CSS 文件數量超過上限，略過：$path');
        break;
      }

      final stylesheet = _resources[path];
      if (stylesheet == null) {
        warnings.add('找不到 CSS 文件：$path');
        continue;
      }
      if (stylesheet.kind != FrameEpubResourceKind.stylesheet) {
        warnings.add('資源不是 CSS 文件：$path');
        continue;
      }

      if (stylesheet.size > maxTotalStylesheetBytes - totalStylesheetBytes) {
        warnings.add('CSS 總讀取量超過上限，略過：' + path);
        continue;
      }
      final css = await readText(
        stylesheet,
        maxBytes: maxStylesheetBytes,
      );
      totalStylesheetBytes += stylesheet.size;
      final references = <FrameEpubResolvedCssReference>[];
      for (final reference in extractCssReferences(css)) {
        final resolved = resolve(reference.href, fromPath: path);
        references.add(
          FrameEpubResolvedCssReference(
            reference: resolved,
            kind: reference.kind,
          ),
        );
        if (resolved.isMissing) {
          warnings.add('CSS 資源不存在：' +
              (resolved.path ?? reference.href));
        }

        if (reference.kind == FrameEpubCssReferenceKind.import &&
            resolved.resource?.kind == FrameEpubResourceKind.stylesheet &&
            !scheduled.contains(resolved.path)) {
          if (scheduled.length >= maxStylesheets) {
            warnings.add('CSS 文件數量超過上限，略過匯入：' + resolved.path!);
          } else {
            scheduled.add(resolved.path!);
            queue.add((resolved.path!, depth + 1));
          }
        }
      }

      loaded[path] = FrameEpubStylesheetDocument(
        resource: stylesheet,
        css: css,
        references: references,
      );
    }

    return FrameEpubStylesheetGraph(
      stylesheets: loaded,
      warnings: warnings,
    );
  }

  static List<FrameEpubCssReference> extractCssReferences(String css) {
    final references = <FrameEpubCssReference>[];
    var index = 0;

    while (index < css.length) {
      if (_startsComment(css, index)) {
        index = _skipComment(css, index);
        continue;
      }

      final codeUnit = css.codeUnitAt(index);
      if (codeUnit == 0x22 || codeUnit == 0x27) {
        index = _skipQuoted(css, index);
        continue;
      }

      if (codeUnit == 0x40 &&
          _matchesAsciiIgnoreCase(css, index + 1, 'import') &&
          !_isCssIdentifierCharacter(_charAt(css, index + 7))) {
        final parsed = _readImport(css, index + 7);
        if (parsed != null) {
          references.add(
            FrameEpubCssReference(
              href: parsed.$1,
              kind: FrameEpubCssReferenceKind.import,
            ),
          );
          index = parsed.$2;
          continue;
        }
      }

      if (_matchesAsciiIgnoreCase(css, index, 'url') &&
          !_isCssIdentifierCharacter(_charAt(css, index - 1)) &&
          !_isCssIdentifierCharacter(_charAt(css, index + 3))) {
        final parsed = _readUrlFunction(css, index + 3);
        if (parsed != null) {
          references.add(
            FrameEpubCssReference(
              href: parsed.$1,
              kind: FrameEpubCssReferenceKind.url,
            ),
          );
          index = parsed.$2;
          continue;
        }
      }

      index++;
    }

    return List.unmodifiable(references);
  }

  void _ensureResource(FrameEpubResource resource) {
    if (!identical(_resources[resource.path], resource)) {
      throw ArgumentError.value(
        resource,
        'resource',
        '資源不屬於目前的 EPUB。',
      );
    }
  }

  int _defaultLimit(FrameEpubResourceKind kind) => switch (kind) {
        FrameEpubResourceKind.document => maxXhtmlBytes,
        FrameEpubResourceKind.stylesheet => maxStylesheetBytes,
        FrameEpubResourceKind.image => maxImageBytes,
        FrameEpubResourceKind.svg => maxSvgBytes,
        FrameEpubResourceKind.font => maxFontBytes,
        _ => maxOtherResourceBytes,
      };
}

class FrameEpubResourceException implements Exception {
  const FrameEpubResourceException(this.message);
  final String message;
  @override
  String toString() => 'FrameEpubResourceException: $message';
}

FrameEpubResourceKind _resourceKind(String mediaType, String path) {
  final type = mediaType.toLowerCase().split(';').first.trim();
  if (type == 'application/xhtml+xml' ||
      type == 'text/html' ||
      type == 'application/xml' ||
      type == 'text/xml') {
    return FrameEpubResourceKind.document;
  }
  if (type == 'text/css' || path.toLowerCase().endsWith('.css')) {
    return FrameEpubResourceKind.stylesheet;
  }
  if (type == 'image/svg+xml' || path.toLowerCase().endsWith('.svg')) {
    return FrameEpubResourceKind.svg;
  }
  if (type.startsWith('image/')) return FrameEpubResourceKind.image;
  final lowerPath = path.toLowerCase();
  if (type.startsWith('font/') ||
      type.contains('font') ||
      type == 'application/vnd.ms-opentype' ||
      type == 'application/font-sfnt' ||
      lowerPath.endsWith('.woff') ||
      lowerPath.endsWith('.woff2') ||
      lowerPath.endsWith('.ttf') ||
      lowerPath.endsWith('.otf') ||
      lowerPath.endsWith('.eot')) {
    return FrameEpubResourceKind.font;
  }
  if (type.startsWith('audio/')) return FrameEpubResourceKind.audio;
  if (type.startsWith('video/')) return FrameEpubResourceKind.video;
  return FrameEpubResourceKind.other;
}

FrameEpubResourceKind? _documentAttributeRole(
  String element,
  String attribute,
) {
  if (element == 'a' && attribute == 'href') return FrameEpubResourceKind.other;
  if (element == 'link' && attribute == 'href') {
    return FrameEpubResourceKind.stylesheet;
  }
  if ((element == 'img' && attribute == 'src') ||
      (element == 'image' &&
          (attribute == 'href' || attribute == 'src'))) {
    return FrameEpubResourceKind.image;
  }
  if ((element == 'use' || element == 'a' || element == 'area') &&
      attribute == 'href') {
    return FrameEpubResourceKind.other;
  }
  if ((element == 'audio' || element == 'source' || element == 'track') &&
      attribute == 'src') {
    return FrameEpubResourceKind.audio;
  }
  if (element == 'video' && attribute == 'src') {
    return FrameEpubResourceKind.video;
  }
  if (element == 'video' && attribute == 'poster') {
    return FrameEpubResourceKind.image;
  }
  if (element == 'object' && attribute == 'data') {
    return FrameEpubResourceKind.other;
  }
  return null;
}

String _mediaTypeForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.xhtml') || lower.endsWith('.html')) {
    return 'application/xhtml+xml';
  }
  if (lower.endsWith('.css')) return 'text/css';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.woff')) return 'font/woff';
  if (lower.endsWith('.woff2')) return 'font/woff2';
  if (lower.endsWith('.otf')) return 'font/otf';
  if (lower.endsWith('.ttf')) return 'font/ttf';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  return 'application/octet-stream';
}

String _decodeEpubText(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    final units = <int>[];
    for (var index = 2; index + 1 < bytes.length; index += 2) {
      units.add(bytes[index] | (bytes[index + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
  if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    final units = <int>[];
    for (var index = 2; index + 1 < bytes.length; index += 2) {
      units.add((bytes[index] << 8) | bytes[index + 1]);
    }
    return String.fromCharCodes(units);
  }
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    start = 3;
  }
  return utf8.decode(Uint8List.sublistView(bytes, start), allowMalformed: false);
}

bool _startsComment(String value, int index) =>
    index + 1 < value.length &&
    value.codeUnitAt(index) == 0x2f &&
    value.codeUnitAt(index + 1) == 0x2a;

int _skipComment(String value, int index) {
  final end = value.indexOf('*/', index + 2);
  return end < 0 ? value.length : end + 2;
}

int _skipQuoted(String value, int index) {
  final quote = value.codeUnitAt(index);
  index++;
  while (index < value.length) {
    final unit = value.codeUnitAt(index);
    if (unit == 0x5c) {
      index += 2;
    } else if (unit == quote) {
      return index + 1;
    } else {
      index++;
    }
  }
  return value.length;
}

(String, int)? _readImport(String css, int index) {
  index = _skipCssWhitespaceAndComments(css, index);
  if (index >= css.length) return null;
  final quote = css.codeUnitAt(index);
  if (quote == 0x22 || quote == 0x27) {
    final parsed = _readCssString(css, index);
    if (parsed == null || parsed.$1.isEmpty) return null;
    return (parsed.$1, parsed.$2);
  }
  if (_matchesAsciiIgnoreCase(css, index, 'url') &&
      !_isCssIdentifierCharacter(_charAt(css, index - 1)) &&
      !_isCssIdentifierCharacter(_charAt(css, index + 3))) {
    return _readUrlFunction(css, index + 3);
  }
  return null;
}

(String, int)? _readUrlFunction(String css, int index) {
  index = _skipCssWhitespaceAndComments(css, index);
  if (index >= css.length || css.codeUnitAt(index) != 0x28) return null;
  index = _skipCssWhitespaceAndComments(css, index + 1);
  if (index >= css.length) return null;

  final quote = css.codeUnitAt(index);
  String rawValue;
  if (quote == 0x22 || quote == 0x27) {
    final parsed = _readCssString(css, index);
    if (parsed == null) return null;
    rawValue = parsed.$1;
    index = parsed.$2;
    index = _skipCssWhitespaceAndComments(css, index);
    if (index >= css.length || css.codeUnitAt(index) != 0x29) return null;
    return (_decodeCssEscapes(rawValue.trim()), index + 1);
  }

  final start = index;
  var escaped = false;
  while (index < css.length) {
    final unit = css.codeUnitAt(index);
    if (escaped) {
      escaped = false;
    } else if (unit == 0x5c) {
      escaped = true;
    } else if (unit == 0x29) {
      rawValue = css.substring(start, index).trim();
      return (_decodeCssEscapes(rawValue), index + 1);
    }
    index++;
  }
  return null;
}

(String, int)? _readCssString(String css, int index) {
  if (index >= css.length) return null;
  final quote = css.codeUnitAt(index);
  if (quote != 0x22 && quote != 0x27) return null;
  final start = index + 1;
  index++;
  while (index < css.length) {
    final unit = css.codeUnitAt(index);
    if (unit == 0x5c) {
      index += 2;
      continue;
    }
    if (unit == quote) {
      return (css.substring(start, index), index + 1);
    }
    index++;
  }
  return null;
}

int _skipCssWhitespaceAndComments(String css, int index) {
  while (index < css.length) {
    final unit = css.codeUnitAt(index);
    if (unit == 0x20 || unit == 0x09 || unit == 0x0a ||
        unit == 0x0c || unit == 0x0d) {
      index++;
    } else if (_startsComment(css, index)) {
      index = _skipComment(css, index);
    } else {
      break;
    }
  }
  return index;
}

String _decodeCssEscapes(String value) {
  final output = StringBuffer();
  var index = 0;
  while (index < value.length) {
    if (value.codeUnitAt(index) != 0x5c || index + 1 >= value.length) {
      output.write(value[index]);
      index++;
      continue;
    }

    index++;
    final first = value.codeUnitAt(index);
    if (first == 0x0a || first == 0x0d || first == 0x0c) {
      if (first == 0x0d &&
          index + 1 < value.length &&
          value.codeUnitAt(index + 1) == 0x0a) {
        index++;
      }
      index++;
      continue;
    }

    final hexStart = index;
    while (index < value.length &&
        index - hexStart < 6 &&
        _isHexDigit(value.codeUnitAt(index))) {
      index++;
    }
    if (index > hexStart) {
      final codePoint = int.parse(value.substring(hexStart, index), radix: 16);
      output.writeCharCode(
        codePoint == 0 || codePoint > 0x10ffff ? 0xfffd : codePoint,
      );
      if (index < value.length) {
        final next = value.codeUnitAt(index);
        if (next == 0x20 || next == 0x09 || next == 0x0a ||
            next == 0x0c || next == 0x0d) {
          index++;
        }
      }
    } else {
      output.write(value[index]);
      index++;
    }
  }
  return output.toString();
}

bool _matchesAsciiIgnoreCase(String value, int offset, String needle) {
  if (offset < 0 || offset + needle.length > value.length) return false;
  return value.substring(offset, offset + needle.length).toLowerCase() ==
      needle.toLowerCase();
}

bool _isCssIdentifierCharacter(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5a) ||
    (unit >= 0x61 && unit <= 0x7a) ||
    unit == 0x2d ||
    unit == 0x5f;

int _charAt(String value, int index) =>
    index < 0 || index >= value.length ? -1 : value.codeUnitAt(index);

bool _isHexDigit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x46) ||
    (unit >= 0x61 && unit <= 0x66);
