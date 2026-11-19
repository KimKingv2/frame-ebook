import 'package:xml/xml.dart';

import 'frame_epub_parser.dart';

class FrameEpubCfiLocation {
  const FrameEpubCfiLocation({
    required this.spineIndex,
    required this.node,
    required this.offset,
  });

  final int spineIndex;
  final XmlNode node;
  final int offset;

  XmlElement? get anchorElement => FrameEpubCfi.closestBlockElement(node);
}

class FrameEpubCfiPoint {
  const FrameEpubCfiPoint({required this.node, required this.offset});
  final XmlText node;
  final int offset;
}

class FrameEpubCfiRange {
  const FrameEpubCfiRange({required this.start, required this.end});
  final FrameEpubCfiLocation start;
  final FrameEpubCfiLocation end;
}

/// Publication-level EPUB CFI support for reading progress.
///
/// Point CFIs and legacy Foliate range CFIs are accepted. Range CFIs restore
/// from their leading edge, matching the legacy Reading Room behavior.
class FrameEpubCfi {
  FrameEpubCfi._();

  static const _blockTags = <String>{
    'address', 'article', 'aside', 'blockquote', 'body', 'dd', 'div', 'dl', 'dt',
    'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'header', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section', 'table', 'ul',
  };

  static String? create({
    required FrameEpubBook book,
    required int spineIndex,
    required XmlText textNode,
    required int offset,
  }) {
    if (spineIndex < 0 || spineIndex >= book.spine.length ||
        textNode.parent == null) {
      return null;
    }
    final root = _documentRoot(textNode);
    if (root == null) return null;
    final localPath = _pathForNode(root, textNode, offset);
    if (localPath == null || localPath.isEmpty) return null;

    final packageStep = StringBuffer('/6/')
      ..write((spineIndex + 1) * 2);
    final itemrefId = book.spine[spineIndex].itemrefId.trim();
    if (itemrefId.isNotEmpty) {
      packageStep
        ..write('[')
        ..write(_escape(itemrefId))
        ..write(']');
    }
    return 'epubcfi(' + packageStep.toString() + '!' + localPath + ')';
  }

  /// Creates a standards-compatible EPUB CFI range for a text selection.
  ///
  /// The generated structure matches Foliate's legacy Reading Room format:
  /// epubcfi(package!common-path,start-relative-path,end-relative-path).
  /// A selection must stay inside one XHTML spine item and follow document
  /// order. The original text nodes remain in memory only for this session.
  static String? createRange({
    required FrameEpubBook book,
    required int spineIndex,
    required XmlText startNode,
    required int startOffset,
    required XmlText endNode,
    required int endOffset,
  }) {
    if (startOffset < 0 ||
        startOffset > startNode.value.length ||
        endOffset < 0 ||
        endOffset > endNode.value.length ||
        startNode.parent == null ||
        endNode.parent == null) {
      return null;
    }

    final startRoot = _documentRoot(startNode);
    final endRoot = _documentRoot(endNode);
    if (startRoot == null || !identical(startRoot, endRoot)) return null;

    final texts = startRoot.descendants.whereType<XmlText>().toList();
    final startIndex = texts.indexWhere((node) => identical(node, startNode));
    final endIndex = texts.indexWhere((node) => identical(node, endNode));
    if (startIndex < 0 ||
        endIndex < startIndex ||
        (startIndex == endIndex && startOffset >= endOffset)) {
      return null;
    }

    final startCfi = create(
      book: book,
      spineIndex: spineIndex,
      textNode: startNode,
      offset: startOffset,
    );
    final endCfi = create(
      book: book,
      spineIndex: spineIndex,
      textNode: endNode,
      offset: endOffset,
    );
    if (startCfi == null || endCfi == null) return null;

    final start = _parse(startCfi);
    final end = _parse(endCfi);
    if (start == null ||
        end == null ||
        start.packageSteps.length != end.packageSteps.length ||
        !_samePath(start.packageSteps, end.packageSteps)) {
      return null;
    }

    final startSteps = start.localSteps;
    final endSteps = end.localSteps;
    var commonLength = 0;
    final limit = startSteps.length < endSteps.length
        ? startSteps.length
        : endSteps.length;
    while (commonLength < limit) {
      final a = startSteps[commonLength];
      final b = endSteps[commonLength];
      if (a.index != b.index ||
          a.offset != null ||
          b.offset != null ||
          a.id != b.id) {
        break;
      }
      commonLength++;
    }

    final parent = startSteps.take(commonLength).toList(growable: false);
    final relativeStart =
        startSteps.skip(commonLength).toList(growable: false);
    final relativeEnd = endSteps.skip(commonLength).toList(growable: false);
    if (relativeStart.isEmpty || relativeEnd.isEmpty) return null;

    final packagePath = _serializeSteps(start.packageSteps);
    final parentPath = _serializeSteps(parent);
    final startPath = _serializeSteps(relativeStart);
    final endPath = _serializeSteps(relativeEnd);
    return 'epubcfi($packagePath!$parentPath,$startPath,$endPath)';
  }

  /// Creates a page-level CFI for fixed-layout content that has no text node,
  /// such as a comic page represented by a single image.
  static String? createElement({
    required FrameEpubBook book,
    required int spineIndex,
    required XmlElement element,
  }) {
    if (spineIndex < 0 ||
        spineIndex >= book.spine.length ||
        element.parent == null) {
      return null;
    }
    final root = _documentRoot(element);
    if (root == null) return null;
    final localPath = _pathForNode(root, element, 0);
    if (localPath == null || localPath.isEmpty) return null;

    final packageStep = StringBuffer('/6/')
      ..write((spineIndex + 1) * 2);
    final itemrefId = book.spine[spineIndex].itemrefId.trim();
    if (itemrefId.isNotEmpty) {
      packageStep
        ..write('[')
        ..write(_escape(itemrefId))
        ..write(']');
    }
    return 'epubcfi(' + packageStep.toString() + '!' + localPath + ')';
  }

  static int? spineIndexFromCfi(FrameEpubBook book, String? source) {
    final parsed = _parse(source);
    if (parsed == null || parsed.packageSteps.length < 2 ||
        parsed.packageSteps.first.index != 6) {
      return null;
    }
    final itemref = parsed.packageSteps[1];
    if (itemref.index <= 0 || itemref.index.isOdd) return null;

    final id = itemref.id;
    if (id != null && id.isNotEmpty) {
      final byId = book.spine.indexWhere((item) => item.itemrefId == id);
      if (byId >= 0) return byId;
    }
    final index = itemref.index ~/ 2 - 1;
    return index >= 0 && index < book.spine.length ? index : null;
  }

  static FrameEpubCfiLocation? resolve({
    required FrameEpubBook book,
    required XmlDocument document,
    required String cfi,
  }) {
    final parsed = _parse(cfi);
    if (parsed == null) return null;
    final spineIndex = spineIndexFromCfi(book, cfi);
    if (spineIndex == null) return null;
    return _resolveLocalSteps(
      document: document,
      spineIndex: spineIndex,
      steps: parsed.localSteps,
    );
  }

  /// Resolves both endpoints of a range CFI. Point CFIs return null.
  static FrameEpubCfiRange? resolveRange({
    required FrameEpubBook book,
    required XmlDocument document,
    required String cfi,
  }) {
    final parsed = _parse(cfi);
    final endSteps = parsed?.rangeEndSteps;
    if (parsed == null || endSteps == null) return null;
    final spineIndex = spineIndexFromCfi(book, cfi);
    if (spineIndex == null) return null;
    final start = _resolveLocalSteps(
      document: document,
      spineIndex: spineIndex,
      steps: parsed.localSteps,
    );
    final end = _resolveLocalSteps(
      document: document,
      spineIndex: spineIndex,
      steps: endSteps,
    );
    if (start == null || end == null) return null;
    if (start.node is! XmlText || end.node is! XmlText) return null;
    return FrameEpubCfiRange(start: start, end: end);
  }

  static FrameEpubCfiLocation? _resolveLocalSteps({
    required XmlDocument document,
    required int spineIndex,
    required List<_ParsedCfiStep> steps,
  }) {
    if (steps.isEmpty) return null;
    XmlNode current = document.rootElement;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final children = _indexedChildren(current);
      if (step.index < 0 || step.index >= children.length) return null;
      final target = children[step.index];

      if (target is XmlElement) {
        if (step.id != null && _elementId(target) != step.id) {
          final corrected = _findElementById(document, step.id!);
          if (corrected != null) {
            current = corrected;
            continue;
          }
        }
        current = target;
        continue;
      }

      if (target is _CfiTextRun) {
        final point = _textPointAt(target, step.offset ?? 0);
        if (point == null || i != steps.length - 1) return null;
        return FrameEpubCfiLocation(
          spineIndex: spineIndex,
          node: point.node,
          offset: point.offset,
        );
      }

      if (target is _CfiVirtualText) {
        final point = _virtualTextPoint(current, target);
        if (point != null && i == steps.length - 1) {
          return FrameEpubCfiLocation(
            spineIndex: spineIndex,
            node: point.node,
            offset: point.offset,
          );
        }
        if (i != steps.length - 1) return null;
      }
      if (i == steps.length - 1) {
        return FrameEpubCfiLocation(
          spineIndex: spineIndex,
          node: current,
          offset: 0,
        );
      }
    }

    return FrameEpubCfiLocation(
      spineIndex: spineIndex,
      node: current,
      offset: 0,
    );
  }

  static bool _samePath(
    List<_ParsedCfiStep> first,
    List<_ParsedCfiStep> second,
  ) {
    if (first.length != second.length) return false;
    for (var i = 0; i < first.length; i++) {
      final a = first[i];
      final b = second[i];
      if (a.index != b.index || a.id != b.id || a.offset != b.offset) {
        return false;
      }
    }
    return true;
  }

  static String _serializeSteps(List<_ParsedCfiStep> steps) {
    final output = StringBuffer();
    for (final step in steps) {
      output
        ..write('/')
        ..write(step.index);
      if (step.id != null && step.id!.isNotEmpty) {
        output
          ..write('[')
          ..write(_escape(step.id!))
          ..write(']');
      }
      if (step.offset != null) {
        output
          ..write(':')
          ..write(step.offset);
      }
    }
    return output.toString();
  }

  static double textFraction(
    XmlDocument document,
    XmlNode node,
    int offset,
  ) {
    final texts = document.descendants.whereType<XmlText>().toList();
    final total = texts.fold<int>(0, (sum, item) => sum + item.value.length);
    if (total <= 0) return 0;
    var before = 0;
    for (final text in texts) {
      if (identical(text, node)) {
        before += offset.clamp(0, text.value.length).toInt();
        return (before / total).clamp(0.0, 1.0);
      }
      before += text.value.length;
    }
    if (node is XmlElement) {
      for (final text in node.descendants.whereType<XmlText>()) {
        return textFraction(document, text, 0);
      }
    }
    return (before / total).clamp(0.0, 1.0);
  }

  static XmlElement? anchorForFragment(
    XmlDocument document,
    String fragment,
  ) {
    if (fragment.isEmpty) return null;
    final decoded = Uri.decodeComponent(fragment);
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (_elementId(element) == decoded) return closestBlockElement(element);
    }
    return null;
  }

  static XmlElement? closestBlockElement(XmlNode node) {
    XmlNode? current = node is XmlElement ? node : node.parent;
    while (current is XmlElement) {
      if (_blockTags.contains(current.name.local.toLowerCase())) {
        return current;
      }
      current = current.parent;
    }
    return null;
  }

  static FrameEpubCfiPoint? firstTextPoint(XmlElement element) {
    for (final node in element.descendants.whereType<XmlText>()) {
      final match = RegExp(r'\S').firstMatch(node.value);
      if (match != null) {
        return FrameEpubCfiPoint(node: node, offset: match.start);
      }
    }
    return null;
  }

  static String? _pathForNode(
    XmlElement root,
    XmlNode target,
    int requestedOffset,
  ) {
    final steps = <String>[];
    XmlNode current = target;
    var offset = requestedOffset;

    while (!identical(current, root)) {
      final parent = current.parent;
      if (parent == null) return null;
      final indexed = _indexedChildren(parent);
      final index = indexed.indexWhere((item) {
        if (item is _CfiTextRun) return item.nodes.contains(current);
        return identical(item, current);
      });
      if (index < 0) return null;

      final item = indexed[index];
      final id = item is XmlElement ? _elementId(item) : null;
      var step = '/$index';
      if (id != null && id.isNotEmpty) step += '[' + _escape(id) + ']';

      if (item is _CfiTextRun) {
        var chunkOffset = 0;
        for (final text in item.nodes) {
          if (identical(text, current)) {
            chunkOffset += offset;
            break;
          }
          chunkOffset += text.value.length;
        }
        final position = chunkOffset.clamp(0, item.text.length).toInt();
        final before = item.text.substring(
          (position - 12).clamp(0, item.text.length),
          position,
        );
        final after = item.text.substring(
          position,
          (position + 12).clamp(0, item.text.length),
        );
        step += ':' + position.toString() + '[' +
            _escape(before) + ',' + _escape(after) + ']';
      }
      steps.add(step);
      current = parent;
      offset = 0;
    }
    return steps.reversed.join();
  }

  static XmlElement? _documentRoot(XmlNode node) {
    XmlNode? current = node;
    while (current?.parent != null) {
      current = current!.parent;
    }
    return current is XmlDocument ? current.rootElement : null;
  }

  /// Builds the CFI child sequence. Adjacent XML text nodes are one CFI text
  /// chunk; empty chunks and the virtual first/last chunks are preserved.
  static List<Object> _indexedChildren(XmlNode parent) {
    final nodes = <Object>[];
    for (final child in parent.children) {
      if (child is XmlText) {
        if (nodes.isEmpty || nodes.last is XmlElement) {
          nodes.add(_CfiTextRun([child]));
        } else if (nodes.last is _CfiTextRun) {
          (nodes.last as _CfiTextRun).nodes.add(child);
        }
      } else if (child is XmlElement) {
        if (nodes.isNotEmpty && nodes.last is XmlElement) {
          nodes.add(_CfiTextRun(const []));
        }
        nodes.add(child);
      }
    }

    if (nodes.isNotEmpty && nodes.first is XmlElement) {
      nodes.insert(0, const _CfiVirtualText.first());
    }
    if (nodes.isNotEmpty && nodes.last is XmlElement) {
      nodes.add(const _CfiVirtualText.last());
    }
    nodes
      ..insert(0, const _CfiBefore())
      ..add(const _CfiAfter());
    return nodes;
  }

  static FrameEpubCfiPoint? _textPointAt(_CfiTextRun run, int offset) {
    if (run.nodes.isEmpty) return null;
    final target = offset.clamp(0, run.text.length).toInt();
    var total = 0;
    for (var i = 0; i < run.nodes.length; i++) {
      final node = run.nodes[i];
      final end = total + node.value.length;
      if (target < end || (target == end && i == run.nodes.length - 1)) {
        return FrameEpubCfiPoint(
          node: node,
          offset: (target - total).clamp(0, node.value.length).toInt(),
        );
      }
      total = end;
    }
    final last = run.nodes.last;
    return FrameEpubCfiPoint(node: last, offset: last.value.length);
  }

  static FrameEpubCfiPoint? _virtualTextPoint(
    XmlNode parent,
    _CfiVirtualText virtual,
  ) {
    final texts = parent.descendants.whereType<XmlText>();
    if (virtual.isFirst) {
      for (final node in texts) {
        if (node.value.isNotEmpty) {
          return FrameEpubCfiPoint(node: node, offset: 0);
        }
      }
    } else {
      final nodes = texts.toList();
      if (nodes.isNotEmpty) {
        final node = nodes.last;
        return FrameEpubCfiPoint(node: node, offset: node.value.length);
      }
    }
    return null;
  }

  static XmlElement? _findElementById(XmlDocument document, String id) {
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (_elementId(element) == id) return element;
    }
    return null;
  }

  static String? _elementId(XmlElement element) {
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() == 'id') return attribute.value;
    }
    return null;
  }

  static String _escape(String value) => value.replaceAllMapped(
        RegExp(r'[\^\[\](),;=]'),
        (match) => '^' + match.group(0)!,
      );

  static String _unescape(String value) {
    final output = StringBuffer();
    var escaped = false;
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      if (escaped) {
        output.write(character);
        escaped = false;
      } else if (character == '^') {
        escaped = true;
      } else {
        output.write(character);
      }
    }
    if (escaped) output.write('^');
    return output.toString();
  }

  static _ParsedCfi? _parse(String? source) {
    if (source == null) return null;
    var value = source.trim();
    if (!value.startsWith('epubcfi(') || !value.endsWith(')')) return null;
    value = value.substring(8, value.length - 1);
    if (value.isEmpty) return null;

    final rangeParts = _splitOutside(value, ',');
    if (rangeParts.length != 1 && rangeParts.length != 3) return null;
    final base = rangeParts.first;
    final indirections = _splitOutside(base, '!');
    if (indirections.length < 2) return null;
    final packageSteps = _parseSteps(indirections.first);
    final parentSteps = _parseSteps(indirections.last);
    if (packageSteps == null ||
        parentSteps == null ||
        packageSteps.length < 2) {
      return null;
    }

    if (rangeParts.length == 1) {
      if (parentSteps.isEmpty) return null;
      return _ParsedCfi(
        packageSteps: packageSteps,
        localSteps: parentSteps,
      );
    }

    final relativeStart = _parseSteps(rangeParts[1]);
    final relativeEnd = _parseSteps(rangeParts[2]);
    if (relativeStart == null ||
        relativeEnd == null ||
        relativeStart.isEmpty ||
        relativeEnd.isEmpty) {
      return null;
    }
    return _ParsedCfi(
      packageSteps: packageSteps,
      localSteps: [...parentSteps, ...relativeStart],
      rangeEndSteps: [...parentSteps, ...relativeEnd],
    );
  }

  static List<_ParsedCfiStep>? _parseSteps(String value) {
    final steps = <_ParsedCfiStep>[];
    var index = 0;
    while (index < value.length) {
      if (value[index] != '/') return null;
      index++;
      final start = index;
      while (index < value.length && _isDigit(value.codeUnitAt(index))) {
        index++;
      }
      if (start == index) return null;
      final number = int.tryParse(value.substring(start, index));
      if (number == null) return null;

      String? id;
      if (index < value.length && value[index] == '[') {
        final assertion = _readAssertion(value, index);
        if (assertion == null) return null;
        id = _unescape(assertion.value.split(';').first);
        index = assertion.nextIndex;
      }

      int? offset;
      if (index < value.length && value[index] == ':') {
        index++;
        final offsetStart = index;
        while (index < value.length && _isDigit(value.codeUnitAt(index))) {
          index++;
        }
        if (offsetStart == index) return null;
        offset = int.tryParse(value.substring(offsetStart, index));
        if (offset == null) return null;
        if (index < value.length && value[index] == '[') {
          final assertion = _readAssertion(value, index);
          if (assertion == null) return null;
          index = assertion.nextIndex;
        }
      }
      steps.add(_ParsedCfiStep(index: number, id: id, offset: offset));
    }
    return steps;
  }

  static _CfiAssertion? _readAssertion(String value, int start) {
    final content = StringBuffer();
    var escaped = false;
    for (var index = start + 1; index < value.length; index++) {
      final character = value[index];
      if (escaped) {
        content
          ..write('^')
          ..write(character);
        escaped = false;
      } else if (character == '^') {
        escaped = true;
      } else if (character == ']') {
        return _CfiAssertion(content.toString(), index + 1);
      } else {
        content.write(character);
      }
    }
    return null;
  }

  static List<String> _splitOutside(String value, String delimiter) {
    final result = <String>[];
    var start = 0;
    var bracketDepth = 0;
    var escaped = false;
    for (var index = 0; index < value.length; index++) {
      final character = value[index];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (character == '^') {
        escaped = true;
        continue;
      }
      if (character == '[') bracketDepth++;
      if (character == ']' && bracketDepth > 0) bracketDepth--;
      if (character == delimiter && bracketDepth == 0) {
        result.add(value.substring(start, index));
        start = index + 1;
      }
    }
    result.add(value.substring(start));
    return result;
  }

  static bool _isDigit(int codeUnit) =>
      codeUnit >= 0x30 && codeUnit <= 0x39;
}

class _ParsedCfi {
  const _ParsedCfi({
    required this.packageSteps,
    required this.localSteps,
    this.rangeEndSteps,
  });
  final List<_ParsedCfiStep> packageSteps;
  final List<_ParsedCfiStep> localSteps;
  final List<_ParsedCfiStep>? rangeEndSteps;
}

class _ParsedCfiStep {
  const _ParsedCfiStep({required this.index, this.id, this.offset});
  final int index;
  final String? id;
  final int? offset;
}

class _CfiAssertion {
  const _CfiAssertion(this.value, this.nextIndex);
  final String value;
  final int nextIndex;
}

class _CfiTextRun {
  _CfiTextRun(this.nodes);
  final List<XmlText> nodes;
  String get text => nodes.map((node) => node.value).join();
}

class _CfiVirtualText {
  const _CfiVirtualText.first() : isFirst = true;
  const _CfiVirtualText.last() : isFirst = false;
  final bool isFirst;
}

class _CfiBefore {
  const _CfiBefore();
}

class _CfiAfter {
  const _CfiAfter();
}
