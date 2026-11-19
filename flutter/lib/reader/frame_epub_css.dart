import 'package:xml/xml.dart';

/// A bounded CSS cascade for EPUB XHTML.
///
/// This is deliberately a reader-oriented subset rather than a browser CSS
/// engine. It supports selector lists, element/class/id/attribute selectors,
/// descendant and child combinators, the common inheritance properties and
/// declarations used by book typography. Unsupported at-rules and pseudo
/// classes are ignored instead of being interpreted unpredictably.
class FrameEpubCssCascade {
  FrameEpubCssCascade._(this.rules);

  factory FrameEpubCssCascade.fromStylesheets(Iterable<String> stylesheets) {
    final rules = <_CssRule>[];
    var order = 0;
    for (final css in stylesheets) {
      final parsed = _parseStylesheet(css, startOrder: order);
      rules.addAll(parsed.rules);
      order = parsed.nextOrder;
    }
    return FrameEpubCssCascade._(List.unmodifiable(rules));
  }

  final List<_CssRule> rules;

  static const inheritedProperties = {
    'color',
    'font-family',
    'font-size',
    'font-style',
    'font-variant',
    'font-weight',
    'letter-spacing',
    'line-height',
    'text-align',
    'text-indent',
    'text-transform',
    'visibility',
    'white-space',
    'word-spacing',
    'direction',
  };

  /// Resolves a computed declaration map for [element].
  ///
  /// [parentStyle] must be the computed style of the element's parent.
  /// Inline declarations are applied after author styles with inline
  /// specificity. The returned map is immutable.
  Map<String, String> resolve(
    XmlElement element, {
    Map<String, String> parentStyle = const {},
    String? inlineStyle,
  }) {
    final values = <String, _CssCandidate>{};
    final defaults = _defaultDeclarations(element.name.local.toLowerCase());

    for (final property in inheritedProperties) {
      final inherited = parentStyle[property];
      if (inherited != null) {
        values[property] = _CssCandidate(
          value: inherited,
          important: false,
          specificity: const _CssSpecificity(0, 0, 0),
          order: -2,
        );
      }
    }

    for (final entry in defaults.entries) {
      values[entry.key] = _CssCandidate(
        value: entry.value,
        important: false,
        specificity: const _CssSpecificity(0, 0, 0),
        order: -1,
      );
    }

    for (final rule in rules) {
      for (final selector in rule.selectors) {
        if (!selector.matches(element)) continue;
        for (final declaration in rule.declarations) {
          final candidate = _CssCandidate(
            value: declaration.value,
            important: declaration.important,
            specificity: selector.specificity,
            order: declaration.order,
          );
          final current = values[declaration.property];
          if (current == null || candidate.compareTo(current) >= 0) {
            values[declaration.property] = candidate;
          }
        }
      }
    }

    if (inlineStyle != null && inlineStyle.trim().isNotEmpty) {
      final declarations = _parseDeclarations(inlineStyle, 1 << 30);
      for (final declaration in declarations) {
        final candidate = _CssCandidate(
          value: declaration.value,
          important: declaration.important,
          specificity: const _CssSpecificity(1, 0, 0),
          order: declaration.order,
        );
        final current = values[declaration.property];
        if (current == null || candidate.compareTo(current) >= 0) {
          values[declaration.property] = candidate;
        }
      }
    }

    return Map.unmodifiable({
      for (final entry in values.entries) entry.key: entry.value.value,
    });
  }

  static Map<String, String> _defaultDeclarations(String tag) {
    const block = {
      'address',
      'article',
      'aside',
      'blockquote',
      'body',
      'dd',
      'div',
      'dl',
      'dt',
      'figcaption',
      'figure',
      'footer',
      'form',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'header',
      'hr',
      'main',
      'nav',
      'ol',
      'p',
      'pre',
      'section',
      'table',
      'ul',
    };
    final result = <String, String>{
      'display': block.contains(tag) ? 'block' : 'inline',
      'visibility': 'visible',
    };
    switch (tag) {
      case 'h1':
        result.addAll({
          'font-size': '2em',
          'font-weight': 'bold',
          'margin-block-start': '0.67em',
          'margin-block-end': '0.67em',
        });
      case 'h2':
        result.addAll({
          'font-size': '1.5em',
          'font-weight': 'bold',
          'margin-block-start': '0.83em',
          'margin-block-end': '0.83em',
        });
      case 'h3':
        result.addAll({
          'font-size': '1.17em',
          'font-weight': 'bold',
          'margin-block-start': '1em',
          'margin-block-end': '1em',
        });
      case 'h4':
      case 'h5':
      case 'h6':
        result.addAll({
          'font-size': '1em',
          'font-weight': 'bold',
          'margin-block-start': '1.33em',
          'margin-block-end': '1.33em',
        });
      case 'p':
        result.addAll({
          'margin-block-start': '1em',
          'margin-block-end': '1em',
        });
      case 'blockquote':
        result.addAll({
          'margin-block-start': '1em',
          'margin-block-end': '1em',
          'margin-inline-start': '40px',
          'margin-inline-end': '40px',
        });
      case 'pre':
        result.addAll({
          'white-space': 'pre',
          'font-family': 'monospace',
        });
      case 'strong':
      case 'b':
        result['font-weight'] = 'bold';
      case 'em':
      case 'i':
        result['font-style'] = 'italic';
      case 'a':
        result['text-decoration'] = 'underline';
      case 'ul':
      case 'ol':
        result.addAll({
          'margin-block-start': '1em',
          'margin-block-end': '1em',
          'padding-inline-start': '40px',
        });
    }
    return result;
  }
}

class _CssSpecificity implements Comparable<_CssSpecificity> {
  const _CssSpecificity(this.ids, this.classes, this.elements);

  final int ids;
  final int classes;
  final int elements;

  @override
  int compareTo(_CssSpecificity other) {
    final byIds = ids.compareTo(other.ids);
    if (byIds != 0) return byIds;
    final byClasses = classes.compareTo(other.classes);
    if (byClasses != 0) return byClasses;
    return elements.compareTo(other.elements);
  }
}

class _CssCandidate implements Comparable<_CssCandidate> {
  const _CssCandidate({
    required this.value,
    required this.important,
    required this.specificity,
    required this.order,
  });

  final String value;
  final bool important;
  final _CssSpecificity specificity;
  final int order;

  @override
  int compareTo(_CssCandidate other) {
    final byImportance = (important ? 1 : 0).compareTo(
      other.important ? 1 : 0,
    );
    if (byImportance != 0) return byImportance;
    final bySpecificity = specificity.compareTo(other.specificity);
    if (bySpecificity != 0) return bySpecificity;
    return order.compareTo(other.order);
  }
}

class _CssDeclaration {
  const _CssDeclaration({
    required this.property,
    required this.value,
    required this.important,
    required this.order,
  });

  final String property;
  final String value;
  final bool important;
  final int order;
}

class _CssRule {
  const _CssRule(this.selectors, this.declarations);

  final List<_CssSelector> selectors;
  final List<_CssDeclaration> declarations;
}

class _ParsedStylesheet {
  const _ParsedStylesheet(this.rules, this.nextOrder);

  final List<_CssRule> rules;
  final int nextOrder;
}

class _CssSelector {
  const _CssSelector(this.compounds, this.combinators, this.specificity);

  final List<String> compounds;
  final List<String> combinators;
  final _CssSpecificity specificity;

  bool matches(XmlElement element) =>
      _matchesAt(element, compounds.length - 1);

  bool _matchesAt(XmlElement? element, int index) {
    if (element == null || index < 0) return false;
    if (!_matchesCompound(element, compounds[index])) return false;
    if (index == 0) return true;

    final relation = combinators[index - 1];
    if (relation == '>') {
      return _matchesAt(_parentElement(element), index - 1);
    }

    var ancestor = _parentElement(element);
    while (ancestor != null) {
      if (_matchesAt(ancestor, index - 1)) return true;
      ancestor = _parentElement(ancestor);
    }
    return false;
  }
}

XmlElement? _parentElement(XmlElement element) {
  final parent = element.parent;
  return parent is XmlElement ? parent : null;
}

bool _matchesCompound(XmlElement element, String compound) {
  var index = 0;
  final tagMatch = RegExp(
    r'^(?:([a-zA-Z_][\w-]*|\*)\|)?([a-zA-Z_][\w-]*|\*)',
  ).matchAsPrefix(compound);
  if (tagMatch != null) {
    final tag = tagMatch.group(2)!;
    if (tag != '*' && element.name.local.toLowerCase() != tag.toLowerCase()) {
      return false;
    }
    index = tagMatch.end;
  }

  while (index < compound.length) {
    final char = compound[index];
    if (char == '#' || char == '.') {
      final start = index + 1;
      var end = start;
      while (end < compound.length && _isSelectorName(compound[end])) {
        end++;
      }
      if (end == start) return false;
      final value = compound.substring(start, end);
      if (char == '#') {
        if (_localAttribute(element, 'id') != value) return false;
      } else {
        final classes = (_localAttribute(element, 'class') ?? '')
            .split(RegExp(r'\s+'))
            .where((item) => item.isNotEmpty);
        if (!classes.contains(value)) return false;
      }
      index = end;
      continue;
    }

    if (char == '[') {
      final end = _findClosing(compound, index, '[', ']');
      if (end < 0) return false;
      if (!_matchesAttribute(element, compound.substring(index + 1, end))) {
        return false;
      }
      index = end + 1;
      continue;
    }

    if (char == ':') {
      final start = index + 1;
      var nameEnd = start;
      while (nameEnd < compound.length &&
          _isSelectorName(compound[nameEnd])) {
        nameEnd++;
      }
      if (nameEnd == start) return false;
      final pseudo = compound.substring(start, nameEnd).toLowerCase();
      var argument = '';
      var end = nameEnd;
      if (end < compound.length && compound[end] == '(') {
        final close = _findClosing(compound, end, '(', ')');
        if (close < 0) return false;
        argument = compound.substring(end + 1, close).trim();
        end = close + 1;
      }
      if (!_matchesPseudo(element, pseudo, argument)) return false;
      index = end;
      continue;
    }

    // Unknown syntax is not a match. Failing closed is safer than applying a
    // style to more elements than the author selected.
    return false;
  }
  return true;
}

bool _matchesAttribute(XmlElement element, String expression) {
  final match = RegExp(
    r"""^\s*([\w:|-]+)\s*(?:(~=|\|=|\^=|\$=|\*=|=)\s*(?:"([^"]*)"|'([^']*)'|([^\s]+))\s*)?$""",
  ).firstMatch(expression);
  if (match == null) return false;
  final name = match.group(1)!.split(RegExp(r'[:|]')).last;
  final actual = _localAttribute(element, name);
  if (actual == null) return false;
  final operator = match.group(2);
  if (operator == null) return true;
  final expected = match.group(3) ?? match.group(4) ?? match.group(5) ?? '';
  switch (operator) {
    case '=':
      return actual == expected;
    case '~=':
      return actual.split(RegExp(r'\s+')).contains(expected);
    case '|=':
      return actual == expected || actual.startsWith('$expected-');
    case '^=':
      return actual.startsWith(expected);
    case r'$=':
      return actual.endsWith(expected);
    case '*=':
      return actual.contains(expected);
  }
  return false;
}

bool _matchesPseudo(XmlElement element, String pseudo, String argument) {
  final parent = _parentElement(element);
  if (pseudo == 'root') return parent == null;
  if (pseudo == 'first-child') {
    if (parent == null) return true;
    final siblings = _elementSiblings(element, parent);
    return siblings.isNotEmpty && identical(siblings.first, element);
  }
  if (pseudo == 'last-child') {
    if (parent == null) return true;
    final siblings = _elementSiblings(element, parent);
    return siblings.isNotEmpty && identical(siblings.last, element);
  }
  if (pseudo == 'only-child') {
    return parent == null || _elementSiblings(element, parent).length == 1;
  }
  if (pseudo == 'nth-child') {
    final siblings = parent == null ? [element] : _elementSiblings(element, parent);
    final index = siblings.indexOf(element) + 1;
    return _matchesNth(index, argument);
  }
  if (pseudo == 'not') {
    return !_matchesCompound(element, argument);
  }
  return false;
}

List<XmlElement> _elementSiblings(XmlElement element, XmlElement parent) =>
    parent.children.whereType<XmlElement>().toList(growable: false);

bool _matchesNth(int index, String expression) {
  final value = expression.replaceAll(' ', '').toLowerCase();
  if (value == 'odd') return index.isOdd;
  if (value == 'even') return index.isEven;
  final number = int.tryParse(value);
  if (number != null) return index == number;
  final match = RegExp(r'^([+-]?\d*)n([+-]\d+)?$').firstMatch(value);
  if (match == null) return false;
  final aText = match.group(1)!;
  final a = aText.isEmpty || aText == '+'
      ? 1
      : (aText == '-' ? -1 : int.tryParse(aText) ?? 0);
  final b = int.tryParse(match.group(2) ?? '') ?? 0;
  if (a == 0) return index == b;
  final difference = index - b;
  return difference % a == 0 && difference ~/ a >= 0;
}

String? _localAttribute(XmlElement element, String name) {
  for (final attribute in element.attributes) {
    if (attribute.name.local.toLowerCase() == name.toLowerCase()) {
      return attribute.value;
    }
  }
  return null;
}

bool _isSelectorName(String char) =>
    RegExp(r'[a-zA-Z0-9_-]').hasMatch(char);

int _findClosing(String value, int start, String open, String close) {
  var depth = 0;
  String? quote;
  for (var index = start; index < value.length; index++) {
    final char = value[index];
    if (quote != null) {
      if (char == r'\') {
        index++;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == open) {
      depth++;
    } else if (char == close) {
      depth--;
      if (depth == 0) return index;
    }
  }
  return -1;
}

_ParsedStylesheet _parseStylesheet(String css, {required int startOrder}) {
  final clean = _removeCssComments(css);
  final rules = <_CssRule>[];
  var index = 0;
  var order = startOrder;

  while (index < clean.length) {
    index = _skipWhitespace(clean, index);
    if (index >= clean.length) break;
    final boundary = _findTopLevelBoundary(clean, index);
    if (boundary < 0) break;
    final prelude = clean.substring(index, boundary).trim();
    if (clean[boundary] == ';') {
      index = boundary + 1;
      continue;
    }
    final close = _findClosing(clean, boundary, '{', '}');
    if (close < 0) break;
    final body = clean.substring(boundary + 1, close);
    index = close + 1;

    if (prelude.startsWith('@')) {
      final media = RegExp(r'^@media\s+(.+)$', caseSensitive: false)
          .firstMatch(prelude);
      if (media != null) {
        final condition = media.group(1)!.toLowerCase();
        // The reader lays out screen content. Print-only and speech-only rules
        // do not contribute to the screen cascade. Other media queries remain
        // applicable as a conservative baseline until viewport evaluation is
        // implemented.
        if (!condition.contains('print') && !condition.contains('speech')) {
          final nested = _parseStylesheet(body, startOrder: order);
          rules.addAll(nested.rules);
          order = nested.nextOrder;
        }
      }
      continue;
    }

    final declarations = _parseDeclarations(body, order);
    order += declarations.length;
    if (declarations.isEmpty) continue;

    final selectors = <_CssSelector>[];
    for (final selectorText in _splitCssList(prelude)) {
      final selector = _parseSelector(selectorText);
      if (selector != null) selectors.add(selector);
    }
    if (selectors.isNotEmpty) {
      rules.add(_CssRule(List.unmodifiable(selectors), declarations));
    }
  }

  return _ParsedStylesheet(List.unmodifiable(rules), order);
}

int _findTopLevelBoundary(String css, int start) {
  String? quote;
  var parentheses = 0;
  var brackets = 0;
  for (var index = start; index < css.length; index++) {
    final char = css[index];
    if (quote != null) {
      if (char == r'\') {
        index++;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '(') {
      parentheses++;
    } else if (char == ')') {
      parentheses = (parentheses - 1).clamp(0, 100000);
    } else if (char == '[') {
      brackets++;
    } else if (char == ']') {
      brackets = (brackets - 1).clamp(0, 100000);
    } else if (parentheses == 0 && brackets == 0 &&
        (char == '{' || char == ';')) {
      return index;
    }
  }
  return -1;
}

String _removeCssComments(String css) {
  final output = StringBuffer();
  var index = 0;
  String? quote;
  while (index < css.length) {
    final char = css[index];
    if (quote != null) {
      output.write(char);
      if (char == r'\') {
        index++;
        if (index < css.length) output.write(css[index]);
      } else if (char == quote) {
        quote = null;
      }
      index++;
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      output.write(char);
      index++;
      continue;
    }
    if (char == '/' && index + 1 < css.length && css[index + 1] == '*') {
      final end = css.indexOf('*/', index + 2);
      if (end < 0) break;
      index = end + 2;
      output.write(' ');
      continue;
    }
    output.write(char);
    index++;
  }
  return output.toString();
}

int _skipWhitespace(String value, int index) {
  while (index < value.length && value.codeUnitAt(index) <= 0x20) {
    index++;
  }
  return index;
}

List<_CssDeclaration> _parseDeclarations(String css, int startOrder) {
  final declarations = <_CssDeclaration>[];
  var order = startOrder;
  for (final raw in _splitCssList(css, separator: ';')) {
    final colon = _findDeclarationColon(raw);
    if (colon < 0) continue;
    final property = raw.substring(0, colon).trim().toLowerCase();
    var value = raw.substring(colon + 1).trim();
    if (property.isEmpty || value.isEmpty ||
        property.startsWith('--') || property.startsWith('@')) {
      continue;
    }
    var important = false;
    final importantMatch =
        RegExp(r'\s*!important\s*$', caseSensitive: false).firstMatch(value);
    if (importantMatch != null) {
      important = true;
      value = value.substring(0, importantMatch.start).trim();
    }
    if (value.isEmpty) continue;
    declarations.add(_CssDeclaration(
      property: property,
      value: value,
      important: important,
      order: order++,
    ));
  }
  return List.unmodifiable(declarations);
}

int _findDeclarationColon(String value) {
  String? quote;
  var parentheses = 0;
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (quote != null) {
      if (char == r'\') {
        index++;
      } else if (char == quote) {
        quote = null;
      }
    } else if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '(') {
      parentheses++;
    } else if (char == ')') {
      parentheses = (parentheses - 1).clamp(0, 100000);
    } else if (char == ':' && parentheses == 0) {
      return index;
    }
  }
  return -1;
}

List<String> _splitCssList(String value, {String separator = ','}) {
  final result = <String>[];
  var start = 0;
  var parentheses = 0;
  var brackets = 0;
  String? quote;
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (quote != null) {
      if (char == r'\') {
        index++;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '(') {
      parentheses++;
    } else if (char == ')') {
      parentheses = (parentheses - 1).clamp(0, 100000);
    } else if (char == '[') {
      brackets++;
    } else if (char == ']') {
      brackets = (brackets - 1).clamp(0, 100000);
    } else if (char == separator && parentheses == 0 && brackets == 0) {
      final item = value.substring(start, index).trim();
      if (item.isNotEmpty) result.add(item);
      start = index + 1;
    }
  }
  final tail = value.substring(start).trim();
  if (tail.isNotEmpty) result.add(tail);
  return result;
}

_CssSelector? _parseSelector(String source) {
  final compounds = <String>[];
  final combinators = <String>[];
  final current = StringBuffer();
  var pendingSpace = false;
  var brackets = 0;
  var parentheses = 0;
  String? quote;

  void flush() {
    final value = current.toString().trim();
    if (value.isNotEmpty) compounds.add(value);
    current.clear();
  }

  for (var index = 0; index < source.length; index++) {
    final char = source[index];
    if (quote != null) {
      current.write(char);
      if (char == r'\') {
        if (index + 1 < source.length) current.write(source[++index]);
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      current.write(char);
      continue;
    }
    if (char == '[') brackets++;
    if (char == ']') brackets--;
    if (char == '(') parentheses++;
    if (char == ')') parentheses--;
    if (brackets == 0 && parentheses == 0) {
      if (char == '>') {
        flush();
        pendingSpace = false;
        if (compounds.isEmpty || combinators.length >= compounds.length) {
          return null;
        }
        combinators.add('>');
        continue;
      }
      if (char.trim().isEmpty) {
        if (current.isNotEmpty) {
          flush();
          pendingSpace = true;
        }
        continue;
      }
    }
    if (pendingSpace) {
      if (compounds.isNotEmpty && combinators.length < compounds.length) {
        combinators.add(' ');
      }
      pendingSpace = false;
    }
    current.write(char);
  }
  flush();

  if (compounds.isEmpty || combinators.length != compounds.length - 1) {
    return null;
  }

  var ids = 0;
  var classes = 0;
  var elements = 0;
  for (final compound in compounds) {
    final specificity = _compoundSpecificity(compound);
    ids += specificity.$1;
    classes += specificity.$2;
    elements += specificity.$3;
  }

  return _CssSelector(
    List.unmodifiable(compounds),
    List.unmodifiable(combinators),
    _CssSpecificity(ids, classes, elements),
  );
}

(int, int, int) _compoundSpecificity(String compound) {
  var ids = 0;
  var classes = 0;
  var elements = 0;
  final withoutAttribute = compound.replaceAllMapped(
    RegExp(r'\[[^\]]*\]'),
    (_) {
      classes++;
      return '';
    },
  );
  final withoutPseudo = withoutAttribute.replaceAllMapped(
    RegExp(r':[\w-]+(?:\([^)]*\))?'),
    (match) {
      final pseudo = match.group(0)!;
      if (pseudo.startsWith(':not(')) {
        final nested = _compoundSpecificity(
          pseudo.substring(5, pseudo.length - 1),
        );
        ids += nested.$1;
        classes += nested.$2;
        elements += nested.$3;
      } else {
        classes++;
      }
      return '';
    },
  );
  ids += RegExp(r'#[\w-]+').allMatches(withoutPseudo).length;
  classes += RegExp(r'\.[\w-]+').allMatches(withoutPseudo).length;
  final tag = RegExp(
    r'^(?:[a-zA-Z_][\w-]*\|)?([a-zA-Z_][\w-]*)',
  ).firstMatch(withoutPseudo);
  if (tag != null && tag.group(1) != '*') elements++;
  return (ids, classes, elements);
}
