import 'package:xml/xml.dart';

import 'frame_epub_resource_loader.dart';

/// Plain-text content extracted from an EPUB footnote or endnote target.
class FrameEpubFootnote {
  const FrameEpubFootnote({
    required this.title,
    required this.content,
  });

  final String title;
  final String content;
}

/// Resolves EPUB 3 semantic note links without navigating the reading view.
///
/// Only XHTML documents and fragments inside the current EPUB archive are
/// considered. External links are never fetched.
class FrameEpubFootnoteResolver {
  FrameEpubFootnoteResolver._();

  static const int maxContentLength = 12000;

  static bool isFootnoteReference(XmlElement element) {
    final type = _tokens(element, 'type');
    final role = _tokens(element, 'role');
    final classes = _tokens(element, 'class');
    return type.contains('noteref') ||
        type.contains('doc-noteref') ||
        role.contains('doc-noteref') ||
        role.contains('noteref') ||
        classes.contains('noteref') ||
        classes.contains('footnote-ref') ||
        classes.contains('endnote-ref');
  }

  static bool isFootnoteTarget(XmlElement element) {
    final type = _tokens(element, 'type');
    final role = _tokens(element, 'role');
    final classes = _tokens(element, 'class');
    return _isFootnoteToken(type) ||
        _isFootnoteToken(role) ||
        _isFootnoteToken(classes);
  }

  static Future<FrameEpubFootnote?> resolve({
    required XmlElement anchor,
    required FrameEpubChapterDocument chapter,
    required FrameEpubResourceLoader resourceLoader,
  }) async {
    final href = _attribute(anchor, 'href');
    if (href == null || href.trim().isEmpty) return null;

    final reference = resourceLoader.resolve(
      href,
      fromPath: chapter.resource.path,
    );
    if (!reference.isInternal ||
        reference.fragment == null ||
        reference.fragment!.isEmpty) {
      return null;
    }

    final targetPath = reference.path ?? chapter.resource.path;
    XmlDocument targetDocument = chapter.document;
    if (targetPath != chapter.resource.path) {
      // A cross-document lookup is only attempted for an explicitly marked
      // noteref. Ordinary links keep their existing navigation behavior.
      if (!isFootnoteReference(anchor)) return null;
      final resource = resourceLoader.resource(targetPath);
      if (resource == null ||
          resource.kind != FrameEpubResourceKind.document) {
        return null;
      }
      try {
        final xhtml = await resourceLoader.readText(resource);
        targetDocument = XmlDocument.parse(xhtml);
      } on Object {
        return null;
      }
    }

    String fragment;
    try {
      fragment = Uri.decodeComponent(reference.fragment!);
    } on FormatException {
      fragment = reference.fragment!;
    }

    XmlElement? target;
    for (final element in targetDocument.descendants.whereType<XmlElement>()) {
      final id = _attribute(element, 'id') ?? _attribute(element, 'name');
      if (id == fragment) {
        target = element;
        break;
      }
    }
    if (target == null) return null;
    return fromTarget(anchor: anchor, target: target);
  }

  /// Converts a target element into a readable note when either the link or
  /// the target uses EPUB/DPUB semantic note roles.
  static FrameEpubFootnote? fromTarget({
    required XmlElement anchor,
    required XmlElement target,
  }) {
    final explicitReference = isFootnoteReference(anchor);
    final targetType = _targetType(target);
    if (!explicitReference && targetType == null) return null;

    final content = _extractText(target);
    if (content.isEmpty) return null;

    return FrameEpubFootnote(
      title: targetType == 'endnote' ? '尾註' : '註腳',
      content: content.length > maxContentLength
          ? content.substring(0, maxContentLength)
          : content,
    );
  }

  static String? _targetType(XmlElement element) {
    final type = _tokens(element, 'type');
    final role = _tokens(element, 'role');
    final classes = _tokens(element, 'class');
    if (type.contains('endnote') ||
        type.contains('doc-endnote') ||
        type.contains('endnotes') ||
        role.contains('doc-endnote') ||
        role.contains('endnote') ||
        classes.contains('endnote') ||
        classes.contains('endnotes')) {
      return 'endnote';
    }
    if (_isFootnoteToken(type) ||
        _isFootnoteToken(role) ||
        classes.contains('footnote') ||
        classes.contains('footnotes')) {
      return 'footnote';
    }
    return null;
  }

  static bool _isFootnoteToken(Set<String> tokens) =>
      tokens.contains('footnote') ||
      tokens.contains('doc-footnote') ||
      tokens.contains('endnote') ||
      tokens.contains('doc-endnote') ||
      tokens.contains('footnotes') ||
      tokens.contains('endnotes');

  static Set<String> _tokens(XmlElement element, String name) {
    final result = <String>{};
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() != name.toLowerCase()) continue;
      result.addAll(
        attribute.value
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .where((token) => token.isNotEmpty),
      );
    }
    return result;
  }

  static String? _attribute(XmlElement element, String name) {
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() == name.toLowerCase()) {
        return attribute.value;
      }
    }
    return null;
  }

  static String _extractText(XmlElement target) {
    final output = StringBuffer();
    const blockTags = {
      'address',
      'article',
      'blockquote',
      'dd',
      'div',
      'dl',
      'dt',
      'figcaption',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'li',
      'ol',
      'p',
      'pre',
      'section',
      'table',
      'tr',
      'ul',
    };

    void lineBreak() {
      final current = output.toString();
      if (current.isNotEmpty && !current.endsWith('\n')) output.write('\n');
    }

    void visit(XmlNode node) {
      if (node is XmlText) {
        output.write(node.value);
        return;
      }
      if (node is! XmlElement) return;

      final tag = node.name.local.toLowerCase();
      final role = _tokens(node, 'role');
      final rel = _tokens(node, 'rel');
      if (tag == 'script' ||
          tag == 'style' ||
          role.contains('doc-backlink') ||
          role.contains('backlink') ||
          rel.contains('back')) {
        return;
      }

      final block = blockTags.contains(tag);
      if (block) lineBreak();
      if (tag == 'br') {
        lineBreak();
      } else {
        for (final child in node.children) {
          visit(child);
        }
      }
      if (block) lineBreak();
    }

    visit(target);
    final lines = output
        .toString()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[\t \u00A0]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.join('\n').trim();
  }
}
