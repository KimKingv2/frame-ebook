import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import 'frame_epub_parser.dart';
import 'frame_epub_resource_loader.dart';

typedef FrameEpubFontRegistrar = Future<void> Function(
  String family,
  List<Uint8List> fonts,
);

class FrameEpubFontStylesheet {
  const FrameEpubFontStylesheet({
    required this.path,
    required this.css,
  });

  final String path;
  final String css;
}

class FrameEpubFontFace {
  FrameEpubFontFace({
    required this.family,
    required List<String> sources,
    required this.stylesheetPath,
    required this.weight,
    required this.style,
  }) : sources = List.unmodifiable(sources);

  final String family;
  final List<String> sources;
  final String stylesheetPath;
  final String weight;
  final String style;
}

class _ResolvedEpubFontFace {
  const _ResolvedEpubFontFace({
    required this.family,
    required this.weight,
    required this.style,
    required this.resource,
  });

  final String family;
  final int weight;
  final String style;
  final FrameEpubResource resource;
}

class FrameEpubFontLoadResult {
  FrameEpubFontLoadResult({
    required Map<String, String> familyAliases,
    required List<String> warnings,
  })  : familyAliases = Map.unmodifiable(familyAliases),
        warnings = List.unmodifiable(warnings);

  /// Face keys map a CSS family + weight + style to an isolated runtime family.
  final Map<String, String> familyAliases;
  final List<String> warnings;

  /// Selects the closest registered face using CSS-style weight matching.
  String? aliasFor({
    required String family,
    String weight = '400',
    String style = 'normal',
  }) =>
      resolveAlias(
        familyAliases,
        family: family,
        weight: weight,
        style: style,
      );

  static String? resolveAlias(
    Map<String, String> aliases, {
    required String family,
    String weight = '400',
    String style = 'normal',
  }) {
    final familyKey = family.trim().toLowerCase();
    if (familyKey.isEmpty) return null;
    final targetWeight =
        FrameEpubEmbeddedFontLoader.normalizeWeight(weight);
    final targetStyle = FrameEpubEmbeddedFontLoader.normalizeStyle(style);
    final exact = aliases[
        FrameEpubEmbeddedFontLoader.fontFaceAliasKey(
          familyKey,
          targetWeight.toString(),
          targetStyle,
        )];
    if (exact != null) return exact;

    final candidates = <({String alias, int weight, String style})>[];
    for (final entry in aliases.entries) {
      final parts = entry.key.split('\u0000');
      if (parts.length != 3 || parts[0] != familyKey) continue;
      final candidateWeight = int.tryParse(parts[1]);
      if (candidateWeight == null) continue;
      candidates.add((
        alias: entry.value,
        weight: candidateWeight,
        style: parts[2],
      ));
    }
    if (candidates.isEmpty) return null;

    candidates.sort((left, right) {
      final leftStylePenalty = left.style == targetStyle ? 0 : 1;
      final rightStylePenalty = right.style == targetStyle ? 0 : 1;
      final styleOrder = leftStylePenalty.compareTo(rightStylePenalty);
      if (styleOrder != 0) return styleOrder;

      return _cssWeightMatchRank(left.weight, targetWeight).compareTo(
        _cssWeightMatchRank(right.weight, targetWeight),
      );
    });
    return candidates.first.alias;
  }

  static int _cssWeightMatchRank(int candidate, int target) {
    if (target < 400) {
      return candidate <= target
          ? target - candidate
          : 1000 + candidate - target;
    }
    if (target <= 500) {
      if (candidate >= target && candidate <= 500) {
        return candidate - target;
      }
      if (candidate < target) return 1000 + target - candidate;
      return 2000 + candidate - 500;
    }
    return candidate >= target
        ? candidate - target
        : 1000 + target - candidate;
  }
}

/// Loads embedded TrueType/OpenType fonts for the shared Flutter renderer.
///
/// Font bytes are read from individual EPUB ZIP entries, decoded in memory,
/// and handed directly to Flutter's runtime FontLoader. No font is written to
/// disk. WOFF/WOFF2 and external/local() sources are intentionally skipped so
/// Web, Android and macOS have the same deterministic format support.
class FrameEpubEmbeddedFontLoader {
  FrameEpubEmbeddedFontLoader({FrameEpubFontRegistrar? registrar})
      : _registrar = registrar ?? _registerWithFlutter;

  static const idpfObfuscationAlgorithm =
      'http://www.idpf.org/2008/embedding';
  static const adobeObfuscationAlgorithm =
      'http://ns.adobe.com/pdf/enc#RC';

  static const _maxFontBytes = 8 * 1024 * 1024;
  static const _maxTotalFontBytes = 24 * 1024 * 1024;
  static const _maxFamiliesPerBook = 16;
  static const _maxFacesPerFamily = 8;
  static const _maxRegisteredFamilies = 64;
  static const _maxRegisteredFontBytes = 64 * 1024 * 1024;
  static const _maxEncryptionXmlBytes = 1024 * 1024;

  // Flutter has no API to unload a runtime font family. Keep strict
  // isolate-lifetime caps and never retain the original font byte buffers here.
  static final Set<String> _registeredFamilies = {};
  static int _registeredFontBytes = 0;
  static final Map<String, String> _familyAliasesByDescriptor = {};
  static final Map<String, Future<void>> _pendingRegistrations = {};

  final FrameEpubFontRegistrar _registrar;

  Future<FrameEpubFontLoadResult> load({
    required FrameEpubBook book,
    required FrameEpubResourceLoader resourceLoader,
    required Iterable<FrameEpubFontStylesheet> stylesheets,
  }) async {
    final warnings = <String>[];
    final faces = <FrameEpubFontFace>[
      for (final sheet in stylesheets)
        ...parseFontFaces(sheet.css, stylesheetPath: sheet.path),
    ];
    if (faces.isEmpty) {
      return FrameEpubFontLoadResult(
        familyAliases: const {},
        warnings: warnings,
      );
    }

    final resolvedFaces = <String, _ResolvedEpubFontFace>{};
    final faceCountsByFamily = <String, int>{};

    for (final face in faces) {
      final familyKey = face.family.toLowerCase();
      if (_isGenericFamily(familyKey)) continue;
      final faceWeight = normalizeFaceWeight(face.weight);
      if (faceWeight == null) {
        warnings.add('略過 EPUB 字型「' + face.family +
            '」：不支援可變字重範圍或無效的 font-weight 描述。');
        continue;
      }
      final faceStyle = normalizeStyle(face.style);
      final faceKey = fontFaceAliasKey(
        familyKey,
        faceWeight.toString(),
        faceStyle,
      );
      if (resolvedFaces.containsKey(faceKey)) {
        // The first matching @font-face descriptor wins, matching CSS source
        // order and keeping each style/weight bound to one binary resource.
        continue;
      }
      if (!faceCountsByFamily.containsKey(familyKey) &&
          faceCountsByFamily.length >= _maxFamiliesPerBook) {
        warnings.add('EPUB 字族超過 $_maxFamiliesPerBook 組，上限以外的字族已略過。');
        continue;
      }
      final faceCount = faceCountsByFamily[familyKey] ?? 0;
      if (faceCount >= _maxFacesPerFamily) {
        warnings.add('EPUB 字型「' + face.family + '」超過每個字族的字型數量上限。');
        continue;
      }

      FrameEpubResource? selected;
      for (final href in face.sources) {
        try {
          final reference = resourceLoader.resolve(
            href,
            fromPath: face.stylesheetPath,
          );
          final resource = reference.resource;
          if (!reference.isInternal ||
              resource == null ||
              resource.kind != FrameEpubResourceKind.font ||
              !_isSupportedFontPath(resource.path)) {
            continue;
          }
          selected = resource;
          break;
        } on Object {
          // One invalid source does not prevent trying the next src() entry.
        }
      }

      if (selected == null) {
        warnings.add('略過 EPUB 字型「' + face.family +
            '」：沒有可用的內嵌 TTF／OTF 資源。');
        continue;
      }
      resolvedFaces[faceKey] = _ResolvedEpubFontFace(
        family: familyKey,
        weight: faceWeight,
        style: faceStyle,
        resource: selected,
      );
      faceCountsByFamily[familyKey] = faceCount + 1;
    }

    if (resolvedFaces.isEmpty) {
      return FrameEpubFontLoadResult(
        familyAliases: const {},
        warnings: warnings,
      );
    }

    final descriptors = <String, String>{
      for (final entry in resolvedFaces.entries)
        entry.key: _familyDescriptor(
          book,
          entry.value.family,
          entry.value.weight,
          entry.value.style,
          entry.value.resource,
        ),
    };
    final needsFontReads = resolvedFaces.entries.any((entry) {
      final alias = _familyAliasesByDescriptor[descriptors[entry.key]];
      return alias == null || !_registeredFamilies.contains(alias);
    });
    final encryption = needsFontReads
        ? await _readEncryptionAlgorithms(resourceLoader, warnings)
        : const <String, String>{};

    final aliases = <String, String>{};
    var totalReadBytes = 0;
    for (final entry in resolvedFaces.entries) {
      final faceKey = entry.key;
      final face = entry.value;
      final resource = face.resource;
      final descriptor = descriptors[faceKey]!;
      final knownAlias = _familyAliasesByDescriptor[descriptor];
      if (knownAlias != null && _registeredFamilies.contains(knownAlias)) {
        aliases[faceKey] = knownAlias;
        continue;
      }

      if (resource.size <= 0 || resource.size > _maxFontBytes) {
        warnings.add('略過超出單一字型讀取上限的資源：' + resource.path);
        continue;
      }
      if (resource.size > _maxTotalFontBytes - totalReadBytes) {
        warnings.add('EPUB 字型總讀取量超過 24 MiB 上限，後續字型已略過。');
        break;
      }

      try {
        var bytes = await resourceLoader.readBytes(
          resource,
          maxBytes: _maxFontBytes,
        );
        totalReadBytes += bytes.length;
        final algorithm = encryption[resource.path];
        if (algorithm != null) {
          if (algorithm == idpfObfuscationAlgorithm) {
            bytes = deobfuscateIdpf(bytes, book.metadata.identifier);
          } else if (algorithm == adobeObfuscationAlgorithm) {
            bytes = deobfuscateAdobe(bytes, book.metadata.identifier);
          } else {
            warnings.add('略過使用不支援混淆演算法的字型：' + resource.path);
            continue;
          }
        }
        if (!hasSupportedSfntHeader(bytes)) {
          warnings.add('字型格式無法由三平台共用載入器辨識：' + resource.path);
          continue;
        }

        final fingerprint = sha1.convert(bytes).toString();
        final alias = _runtimeFamilyName(
          book,
          face.family,
          face.weight,
          face.style,
          fingerprint,
        );
        if (_registeredFamilies.contains(alias)) {
          aliases[faceKey] = alias;
          _familyAliasesByDescriptor[descriptor] = alias;
          continue;
        }
        if (_registeredFamilies.length >= _maxRegisteredFamilies) {
          warnings.add('本次執行階段的 EPUB 字型註冊數量已達上限，改用系統備用字型。');
          break;
        }

        await _registerOnce(alias, [bytes]);
        aliases[faceKey] = alias;
        _familyAliasesByDescriptor[descriptor] = alias;
      } on Object catch (error) {
        warnings.add('EPUB 字型「' + face.family + '」註冊失敗，已改用備用字型：' +
            error.toString());
      }
    }

    return FrameEpubFontLoadResult(
      familyAliases: aliases,
      warnings: warnings,
    );
  }
  static List<FrameEpubFontFace> parseFontFaces(
    String css, {
    String stylesheetPath = '',
  }) {
    final faces = <FrameEpubFontFace>[];
    var index = 0;
    while (index < css.length) {
      if (_startsComment(css, index)) {
        index = _skipComment(css, index);
        continue;
      }
      final code = css.codeUnitAt(index);
      if (code == 0x22 || code == 0x27) {
        index = _skipQuoted(css, index);
        continue;
      }
      if (!_matchesIgnoreCase(css, index, '@font-face') ||
          _isIdentifierCharacter(_charAt(css, index + 10))) {
        index++;
        continue;
      }

      var cursor = index + 10;
      while (cursor < css.length) {
        if (_startsComment(css, cursor)) {
          cursor = _skipComment(css, cursor);
        } else if (_isWhitespace(_charAt(css, cursor))) {
          cursor++;
        } else {
          break;
        }
      }
      if (cursor >= css.length || css.codeUnitAt(cursor) != 0x7B) {
        index = cursor;
        continue;
      }

      final end = _findClosingBrace(css, cursor);
      if (end == null) break;
      final declarations = _parseDeclarations(css.substring(cursor + 1, end));
      final family = _unquote(declarations['font-family'] ?? '').trim();
      final sources = _extractUrls(declarations['src'] ?? '');
      if (family.isNotEmpty && sources.isNotEmpty) {
        faces.add(
          FrameEpubFontFace(
            family: family,
            sources: sources,
            stylesheetPath: stylesheetPath,
            weight: declarations['font-weight'] ?? 'normal',
            style: declarations['font-style'] ?? 'normal',
          ),
        );
      }
      index = end + 1;
    }
    return List.unmodifiable(faces);
  }

  /// Reverses the IDPF algorithm: SHA-1 of the identifier with XML whitespace
  /// removed, XORed over the first 1040 bytes.
  static Uint8List deobfuscateIdpf(
    Uint8List source,
    String uniqueIdentifier,
  ) {
    final normalized = uniqueIdentifier.replaceAll(
      RegExp(r'[\u0020\u0009\u000D\u000A]'),
      '',
    );
    if (normalized.isEmpty) {
      throw const FormatException(
        'EPUB 缺少 IDPF 字型混淆所需的 unique identifier。',
      );
    }
    final key = sha1.convert(utf8.encode(normalized)).bytes;
    return _xorPrefix(source, key, 1040);
  }

  /// Reverses Adobe's legacy algorithm using the 16 bytes of the UUID and the
  /// first 1024 bytes of the embedded font.
  static Uint8List deobfuscateAdobe(
    Uint8List source,
    String uniqueIdentifier,
  ) {
    var value = uniqueIdentifier.trim();
    value = value.replaceFirst(
      RegExp(r'^urn:uuid:', caseSensitive: false),
      '',
    );
    value = value.replaceAll(RegExp(r'[\s{}-]'), '');
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(value)) {
      throw const FormatException(
        'EPUB Adobe 字型混淆需要有效的 UUID unique identifier。',
      );
    }
    final key = <int>[
      for (var index = 0; index < value.length; index += 2)
        int.parse(value.substring(index, index + 2), radix: 16),
    ];
    return _xorPrefix(source, key, 1024);
  }

  static bool hasSupportedSfntHeader(Uint8List bytes) {
    if (bytes.length < 12) return false;
    return _hasSignature(bytes, [0x00, 0x01, 0x00, 0x00]) ||
        _hasSignature(bytes, [0x4F, 0x54, 0x54, 0x4F]) ||
        _hasSignature(bytes, [0x74, 0x72, 0x75, 0x65]) ||
        _hasSignature(bytes, [0x74, 0x79, 0x70, 0x31]);
  }

  static Uint8List _xorPrefix(
    Uint8List source,
    List<int> key,
    int limit,
  ) {
    if (key.isEmpty) {
      throw const FormatException('字型混淆金鑰不可為空。');
    }
    final output = Uint8List.fromList(source);
    final length = output.length < limit ? output.length : limit;
    for (var index = 0; index < length; index++) {
      output[index] ^= key[index % key.length];
    }
    return output;
  }

  static bool _hasSignature(Uint8List bytes, List<int> signature) {
    if (bytes.length < signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  static bool _isSupportedFontPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.ttf') || lower.endsWith('.otf');
  }

  static bool _isGenericFamily(String family) => const {
        'serif',
        'sans-serif',
        'monospace',
        'cursive',
        'fantasy',
        'system-ui',
      }.contains(family.trim().toLowerCase());

  static String fontFaceAliasKey(
    String family,
    String weight,
    String style,
  ) =>
      family.trim().toLowerCase() +
      '\u0000' +
      normalizeWeight(weight).toString() +
      '\u0000' +
      normalizeStyle(style);

  static int normalizeWeight(String value) {
    return normalizeFaceWeight(value) ?? 400;
  }

  /// Returns a static CSS face weight rounded to Flutter's 100-step scale.
  /// Variable-font ranges such as "100 900" are not registered as static faces.
  static int? normalizeFaceWeight(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'normal') return 400;
    if (normalized == 'bold' || normalized == 'bolder') return 700;
    final numeric = double.tryParse(normalized);
    if (numeric == null || !numeric.isFinite || numeric < 1 || numeric > 1000) {
      return null;
    }
    return (numeric / 100).round().clamp(1, 9).toInt() * 100;
  }

  static String normalizeStyle(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'italic' || normalized.startsWith('oblique')
        ? 'italic'
        : 'normal';
  }

  static String _familyDescriptor(
    FrameEpubBook book,
    String family,
    int weight,
    String style,
    FrameEpubResource resource,
  ) {
    final material = [
      book.metadata.identifier,
      book.packagePath,
      family,
      weight.toString(),
      style,
      resource.path + ':' + resource.size.toString() + ':' +
          (resource.crc32?.toString() ?? 'unknown'),
    ].join('\u0000');
    return sha1.convert(utf8.encode(material)).toString();
  }

  static String _runtimeFamilyName(
    FrameEpubBook book,
    String family,
    int weight,
    String style,
    String contentFingerprint,
  ) {
    final material = book.metadata.identifier +
        '\u0000' +
        book.packagePath +
        '\u0000' +
        family +
        '\u0000' +
        weight.toString() +
        '\u0000' +
        style +
        '\u0000' +
        contentFingerprint;
    return 'FrameEpub_' +
        sha1.convert(utf8.encode(material)).toString().substring(0, 20);
  }

  static Future<void> _registerWithFlutter(
    String family,
    List<Uint8List> fonts,
  ) async {
    final loader = FontLoader(family);
    for (final bytes in fonts) {
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  Future<void> _registerOnce(String family, List<Uint8List> fonts) async {
    if (_registeredFamilies.contains(family)) return;
    final existing = _pendingRegistrations[family];
    if (existing != null) {
      await existing;
      return;
    }

    final byteCount = fonts.fold<int>(
      0,
      (total, font) => total + font.length,
    );
    if (byteCount > _maxRegisteredFontBytes - _registeredFontBytes) {
      throw StateError('執行階段 EPUB 字型總記憶體上限已達 64 MiB。');
    }

    // Reserve before awaiting registration so concurrent chapter loads cannot
    // collectively exceed the isolate-wide memory budget.
    _registeredFontBytes += byteCount;
    final pending = _registrar(family, fonts);
    _pendingRegistrations[family] = pending;
    try {
      await pending;
      _registeredFamilies.add(family);
    } on Object {
      _registeredFontBytes -= byteCount;
      rethrow;
    } finally {
      if (identical(_pendingRegistrations[family], pending)) {
        _pendingRegistrations.remove(family);
      }
    }
  }

  static Future<Map<String, String>> _readEncryptionAlgorithms(
    FrameEpubResourceLoader loader,
    List<String> warnings,
  ) async {
    final entry = loader.archive.file('META-INF/encryption.xml');
    if (entry == null) return const {};
    try {
      final resource = loader.resource(entry.path);
      if (resource == null) return const {};
      final bytes = await loader.readBytes(
        resource,
        maxBytes: _maxEncryptionXmlBytes,
      );
      final document = XmlDocument.parse(
        utf8.decode(bytes, allowMalformed: false),
      );
      final algorithms = <String, String>{};
      for (final encrypted in document.descendants.whereType<XmlElement>().where(
            (element) => element.name.local == 'EncryptedData',
          )) {
        final method = _firstElement(encrypted, 'EncryptionMethod');
        final reference = _firstElement(encrypted, 'CipherReference');
        final algorithm = _attribute(method, 'Algorithm');
        final uri = _attribute(reference, 'URI');
        if (algorithm == null || uri == null || uri.trim().isEmpty) continue;
        final resolved = FrameEpubParser.resolveHref(
          uri,
          baseFilePath: '',
        );
        final path = resolved.path;
        if (!resolved.isInternal || path == null) continue;
        algorithms[path] = algorithm;
      }
      return algorithms;
    } on Object catch (error) {
      warnings.add(
        'EPUB encryption.xml 無法解析，已略過混淆字型：' + error.toString(),
      );
      return const {};
    }
  }

  static XmlElement? _firstElement(XmlElement parent, String name) {
    for (final element in parent.descendants.whereType<XmlElement>()) {
      if (element.name.local == name) return element;
    }
    return null;
  }

  static String? _attribute(XmlElement? element, String name) {
    if (element == null) return null;
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() == name.toLowerCase()) {
        return attribute.value;
      }
    }
    return null;
  }

  static bool _matchesIgnoreCase(String value, int offset, String token) {
    if (offset < 0 || offset + token.length > value.length) return false;
    return value.substring(offset, offset + token.length).toLowerCase() ==
        token.toLowerCase();
  }

  static String? _charAt(String value, int index) =>
      index < 0 || index >= value.length ? null : value[index];

  static bool _isWhitespace(String? value) =>
      value != null && RegExp(r'\s').hasMatch(value);

  static bool _isIdentifierCharacter(String? value) =>
      value != null && RegExp(r'[a-zA-Z0-9_-]').hasMatch(value);

  static bool _startsComment(String value, int index) =>
      index + 1 < value.length &&
      value.codeUnitAt(index) == 0x2F &&
      value.codeUnitAt(index + 1) == 0x2A;

  static int _skipComment(String value, int index) {
    final end = value.indexOf('*/', index + 2);
    return end < 0 ? value.length : end + 2;
  }

  static int _skipQuoted(String value, int index) {
    final quote = value.codeUnitAt(index);
    var cursor = index + 1;
    while (cursor < value.length) {
      final code = value.codeUnitAt(cursor);
      if (code == 0x5C) {
        cursor += 2;
      } else if (code == quote) {
        return cursor + 1;
      } else {
        cursor++;
      }
    }
    return value.length;
  }

  static int? _findClosingBrace(String value, int opening) {
    var depth = 1;
    var cursor = opening + 1;
    while (cursor < value.length) {
      if (_startsComment(value, cursor)) {
        cursor = _skipComment(value, cursor);
        continue;
      }
      final code = value.codeUnitAt(cursor);
      if (code == 0x22 || code == 0x27) {
        cursor = _skipQuoted(value, cursor);
      } else if (code == 0x7B) {
        depth++;
        cursor++;
      } else if (code == 0x7D) {
        depth--;
        if (depth == 0) return cursor;
        cursor++;
      } else {
        cursor++;
      }
    }
    return null;
  }

  static Map<String, String> _parseDeclarations(String value) {
    final result = <String, String>{};
    var start = 0;
    var cursor = 0;
    var parentheses = 0;
    while (cursor <= value.length) {
      if (cursor == value.length ||
          (value.codeUnitAt(cursor) == 0x3B && parentheses == 0)) {
        final declaration = value.substring(start, cursor).trim();
        final colon = declaration.indexOf(':');
        if (colon > 0) {
          final name = declaration.substring(0, colon).trim().toLowerCase();
          final content = declaration.substring(colon + 1).trim();
          if (name.isNotEmpty && content.isNotEmpty) result[name] = content;
        }
        start = cursor + 1;
        cursor++;
        continue;
      }
      if (_startsComment(value, cursor)) {
        cursor = _skipComment(value, cursor);
        continue;
      }
      final code = value.codeUnitAt(cursor);
      if (code == 0x22 || code == 0x27) {
        cursor = _skipQuoted(value, cursor);
      } else {
        if (code == 0x28) parentheses++;
        if (code == 0x29 && parentheses > 0) parentheses--;
        cursor++;
      }
    }
    return result;
  }

  static List<String> _extractUrls(String value) {
    final result = <String>[];
    var cursor = 0;
    while (cursor < value.length) {
      if (_startsComment(value, cursor)) {
        cursor = _skipComment(value, cursor);
        continue;
      }
      final code = value.codeUnitAt(cursor);
      if (code == 0x22 || code == 0x27) {
        cursor = _skipQuoted(value, cursor);
        continue;
      }
      if (!_matchesIgnoreCase(value, cursor, 'url') ||
          _isIdentifierCharacter(_charAt(value, cursor - 1)) ||
          _isIdentifierCharacter(_charAt(value, cursor + 3))) {
        cursor++;
        continue;
      }

      var open = cursor + 3;
      while (open < value.length && _isWhitespace(_charAt(value, open))) {
        open++;
      }
      if (open >= value.length || value.codeUnitAt(open) != 0x28) {
        cursor += 3;
        continue;
      }
      var end = open + 1;
      while (end < value.length && _isWhitespace(_charAt(value, end))) {
        end++;
      }

      String content;
      if (end < value.length &&
          (value.codeUnitAt(end) == 0x22 || value.codeUnitAt(end) == 0x27)) {
        final afterQuote = _skipQuoted(value, end);
        content = value.substring(end + 1, afterQuote - 1).trim();
        end = afterQuote;
        while (end < value.length && _isWhitespace(_charAt(value, end))) {
          end++;
        }
        if (end < value.length && value.codeUnitAt(end) == 0x29) end++;
      } else {
        final close = value.indexOf(')', end);
        if (close < 0) break;
        content = value.substring(end, close).trim();
        end = close + 1;
      }
      if (content.isNotEmpty) result.add(content);
      cursor = end;
    }
    return List.unmodifiable(result);
  }

  static String _unquote(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= 2 &&
        ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
            (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
      return trimmed.substring(1, trimmed.length - 1).trim();
    }
    return trimmed;
  }
}
