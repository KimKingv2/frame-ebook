import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xml/xml.dart';

import 'frame_epub_css.dart';
import 'frame_epub_resource_loader.dart';

/// Shared Flutter renderer for one parsed EPUB chapter.
///
/// This is a reader-oriented XHTML/CSS subset, not a browser engine. It uses
/// the same Dart widget tree on Web, Android and macOS and never creates a
/// WebView or fetches external document resources.
class FrameEpubChapterView extends StatefulWidget {
  const FrameEpubChapterView({
    required this.chapter,
    required this.resourceLoader,
    this.fixedLayout = false,
    this.backgroundColor = const Color(0xFF171420),
    this.textColor = const Color(0xFFECE7F4),
    this.linkColor = const Color(0xFFBFA4FF),
    this.fontFamily = 'NotoSansTC',
    this.fontSize = 18,
    this.lineHeight = 1.75,
    this.contentMaxWidth = 760,
    this.horizontalPadding = 26,
    this.maxImageBytes = 16 * 1024 * 1024,
    this.onInternalLink,
    this.onExternalLink,
    super.key,
  })  : assert(fontSize >= 8 && fontSize <= 64),
        assert(lineHeight >= 1 && lineHeight <= 3),
        assert(contentMaxWidth >= 280);

  final FrameEpubChapterDocument chapter;
  final FrameEpubResourceLoader resourceLoader;
  final bool fixedLayout;
  final Color backgroundColor;
  final Color textColor;
  final Color linkColor;
  final String fontFamily;
  final double fontSize;
  final double lineHeight;
  final double contentMaxWidth;
  final double horizontalPadding;
  final int maxImageBytes;
  final ValueChanged<String>? onInternalLink;
  final ValueChanged<Uri>? onExternalLink;

  @override
  State<FrameEpubChapterView> createState() => _FrameEpubChapterViewState();
}

class _EpubStylesheetBundle {
  const _EpubStylesheetBundle(this.cascade, this.warnings);
  final FrameEpubCssCascade cascade;
  final List<String> warnings;
}

class _FrameEpubChapterViewState extends State<FrameEpubChapterView> {
  late Future<_EpubStylesheetBundle> _stylesFuture;
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _stylesFuture = _loadStylesheets();
  }

  @override
  void didUpdateWidget(covariant FrameEpubChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chapter, widget.chapter) ||
        !identical(oldWidget.resourceLoader, widget.resourceLoader)) {
      _stylesFuture = _loadStylesheets();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  Future<_EpubStylesheetBundle> _loadStylesheets() async {
    final stylesheets = <String>[];
    final warnings = <String>[];
    final visited = <String>{};
    final loader = widget.resourceLoader;

    Future<void> appendStylesheet(String path) async {
      final graph = await loader.loadStylesheetGraph(path);
      warnings.addAll(graph.warnings);

      Future<void> appendNode(String currentPath) async {
        if (!visited.add(currentPath)) return;
        final sheet = graph.stylesheets[currentPath];
        if (sheet == null) return;
        for (final imported in sheet.imports) {
          final importedPath = imported.reference.path;
          if (importedPath != null &&
              imported.reference.resource?.kind ==
                  FrameEpubResourceKind.stylesheet) {
            await appendNode(importedPath);
          }
        }
        stylesheets.add(sheet.css);
      }

      await appendNode(path);
    }

    for (final element
        in widget.chapter.document.descendants.whereType<XmlElement>()) {
      final tag = element.name.local.toLowerCase();
      if (tag == 'style') {
        stylesheets.add(element.innerText);
        continue;
      }
      if (tag != 'link') continue;
      final rel = (_attribute(element, 'rel') ?? '')
          .split(RegExp(r'\s+'))
          .map((item) => item.toLowerCase())
          .toSet();
      if (!rel.contains('stylesheet')) continue;
      final media = (_attribute(element, 'media') ?? '').toLowerCase();
      if (media == 'print' || media == 'speech') continue;
      final href = _attribute(element, 'href');
      if (href == null || href.trim().isEmpty) continue;
      final reference = loader.resolve(
        href,
        fromPath: widget.chapter.resource.path,
      );
      final path = reference.path;
      if (!reference.isInternal ||
          path == null ||
          reference.resource?.kind != FrameEpubResourceKind.stylesheet) {
        warnings.add('略過無法載入的 EPUB 樣式表：$href');
        continue;
      }
      try {
        await appendStylesheet(path);
      } on Object catch (error) {
        warnings.add('EPUB 樣式表載入失敗：$path：$error');
      }
    }

    return _EpubStylesheetBundle(
      FrameEpubCssCascade.fromStylesheets(stylesheets),
      List.unmodifiable(warnings),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_EpubStylesheetBundle>(
      future: _stylesFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _message('無法載入 EPUB 樣式：${snapshot.error}');
        }
        if (!snapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFC5ADFF)),
          );
        }

        _disposeRecognizers();
        final body = _bodyElement(widget.chapter.document);
        if (body == null) return _message('EPUB 章節沒有可顯示的 body 內容。');

        final baseStyle = <String, String>{
          'display': 'block',
          'font-family': widget.fontFamily,
          'font-size': '${widget.fontSize}px',
          'line-height': '${widget.lineHeight}',
          'color': _colorToCss(widget.textColor),
          'white-space': 'normal',
          'visibility': 'visible',
        };
        final bodyStyle =
            _computedStyle(body, snapshot.data!.cascade, baseStyle);

        if (widget.fixedLayout) {
          return ColoredBox(
            color: widget.backgroundColor,
            child: LayoutBuilder(
              builder: (context, constraints) => InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                boundaryMargin: const EdgeInsets.all(24),
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth,
                        maxHeight: constraints.maxHeight,
                      ),
                      child: _buildFlow(
                        body,
                        bodyStyle,
                        snapshot.data!.cascade,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return ColoredBox(
          color: widget.backgroundColor,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.contentMaxWidth),
              child: ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.horizontalPadding,
                  vertical: 30,
                ),
                children: _flowChildren(
                  body,
                  bodyStyle,
                  snapshot.data!.cascade,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _message(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFFFC1C1),
              height: 1.6,
            ),
          ),
        ),
      );

  Widget _buildFlow(
    XmlElement element,
    Map<String, String> style,
    FrameEpubCssCascade cascade,
  ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: _flowChildren(element, style, cascade),
      );

  List<Widget> _flowChildren(
    XmlElement parent,
    Map<String, String> parentStyle,
    FrameEpubCssCascade cascade,
  ) {
    final widgets = <Widget>[];
    final inlineSpans = <InlineSpan>[];

    void flushInline() {
      if (inlineSpans.isEmpty) return;
      final spans = List<InlineSpan>.unmodifiable(inlineSpans);
      inlineSpans.clear();
      widgets.add(Text.rich(
        TextSpan(style: _textStyle(parentStyle), children: spans),
        textAlign: _textAlign(parentStyle['text-align']),
        textDirection: _textDirection(parentStyle['direction']),
        softWrap: true,
      ));
    }

    for (final child in parent.children) {
      if (child is XmlText) {
        var text = child.value;
        final whiteSpace = parentStyle['white-space'];
        if (whiteSpace != 'pre' && whiteSpace != 'pre-wrap') {
          text = text.replaceAll(RegExp(r'[\t\r\n ]+'), ' ');
          if (text.trim().isEmpty && inlineSpans.isEmpty) continue;
        }
        if (text.isNotEmpty) {
          inlineSpans.add(TextSpan(
            text: _transformText(text, parentStyle['text-transform']),
          ));
        }
        continue;
      }
      if (child is! XmlElement) continue;
      final tag = child.name.local.toLowerCase();
      final childStyle = _computedStyle(child, cascade, parentStyle);
      if (childStyle['display'] == 'none' ||
          childStyle['visibility'] == 'hidden' ||
          _isNonVisualTag(tag)) {
        continue;
      }
      if (tag == 'br') {
        inlineSpans.add(const TextSpan(text: '\n'));
      } else if (_isBlockElement(tag, childStyle) ||
          (widget.fixedLayout && tag == 'img')) {
        flushInline();
        widgets.add(_buildBlock(child, childStyle, cascade));
      } else {
        inlineSpans.add(_inlineSpan(child, childStyle, cascade));
      }
    }
    flushInline();
    return widgets;
  }

  Widget _buildBlock(
    XmlElement element,
    Map<String, String> style,
    FrameEpubCssCascade cascade,
  ) {
    final tag = element.name.local.toLowerCase();
    Widget child;
    if (tag == 'hr') {
      child = const Divider(color: Color(0x664D455B), height: 24);
    } else if (tag == 'ul' || tag == 'ol') {
      child = _buildList(element, style, cascade);
    } else if (tag == 'img') {
      child = _buildImage(element, style, block: true);
    } else if (tag == 'pre') {
      child = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF211D2B),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          element.innerText,
          style: _textStyle(style).copyWith(
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      );
    } else if (tag == 'blockquote') {
      child = Container(
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: Color(0xFF8065B8), width: 3),
          ),
        ),
        padding: const EdgeInsets.only(left: 16),
        child: _buildFlow(element, style, cascade),
      );
    } else {
      child = _buildFlow(element, style, cascade);
    }

    final padding = _boxInsets(style, 'padding', widget.fontSize);
    final margin = _boxInsets(style, 'margin', widget.fontSize);
    final background = _cssColor(style['background-color']) ??
        _backgroundFromShorthand(style['background']);
    if (padding != EdgeInsets.zero) {
      child = Padding(padding: padding, child: child);
    }
    if (background != null) {
      child = DecoratedBox(
        decoration: BoxDecoration(color: background),
        child: child,
      );
    }
    if (margin != EdgeInsets.zero) {
      child = Padding(padding: margin, child: child);
    }
    return child;
  }

  Widget _buildList(
    XmlElement list,
    Map<String, String> style,
    FrameEpubCssCascade cascade,
  ) {
    final ordered = list.name.local.toLowerCase() == 'ol';
    final items = list.children.whereType<XmlElement>().where(
          (element) => element.name.local.toLowerCase() == 'li',
        );
    final widgets = <Widget>[];
    var index = 0;
    for (final item in items) {
      index++;
      final itemStyle = _computedStyle(item, cascade, style);
      final marker = ordered ? '$index.' : _listMarker(style['list-style-type']);
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: Text(marker, style: _textStyle(itemStyle)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _flowChildren(item, itemStyle, cascade),
              ),
            ),
          ],
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  InlineSpan _inlineSpan(
    XmlElement element,
    Map<String, String> style,
    FrameEpubCssCascade cascade,
  ) {
    final tag = element.name.local.toLowerCase();
    if (_isNonVisualTag(tag) || style['display'] == 'none') {
      return const TextSpan();
    }
    if (tag == 'br') return const TextSpan(text: '\n');
    if (tag == 'img') {
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _buildImage(element, style),
      );
    }
    if (tag == 'svg' || tag == 'math') {
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _unsupportedInlineObject(tag),
      );
    }

    final children = <InlineSpan>[];
    for (final child in element.children) {
      if (child is XmlText) {
        children.add(TextSpan(
          text: _transformText(child.value, style['text-transform']),
        ));
      } else if (child is XmlElement) {
        final childTag = child.name.local.toLowerCase();
        final childStyle = _computedStyle(child, cascade, style);
        if (_isNonVisualTag(childTag) ||
            childStyle['display'] == 'none' ||
            childStyle['visibility'] == 'hidden') {
          continue;
        }
        children.add(_inlineSpan(child, childStyle, cascade));
      }
    }

    GestureRecognizer? recognizer;
    if (tag == 'a') {
      final href = _attribute(element, 'href') ?? '';
      if (href.isNotEmpty) {
        final reference = widget.resourceLoader.resolve(
          href,
          fromPath: widget.chapter.resource.path,
        );
        if (reference.isInternal && widget.onInternalLink != null) {
          final tap = TapGestureRecognizer()
            ..onTap = () => widget.onInternalLink!(href);
          _recognizers.add(tap);
          recognizer = tap;
        } else if (reference.isExternal && widget.onExternalLink != null) {
          final uri = Uri.tryParse(href);
          if (uri != null) {
            final tap = TapGestureRecognizer()
              ..onTap = () => widget.onExternalLink!(uri);
            _recognizers.add(tap);
            recognizer = tap;
          }
        }
      }
    }

    var textStyle = _textStyle(style);
    if (tag == 'a') {
      textStyle = textStyle.copyWith(
        color: widget.linkColor,
        decoration: TextDecoration.underline,
      );
    } else if (tag == 'mark') {
      textStyle = textStyle.copyWith(
        backgroundColor: const Color(0x66D8B45B),
      );
    }
    return TextSpan(
      style: textStyle,
      recognizer: recognizer,
      children: children,
    );
  }

  Widget _buildImage(
    XmlElement element,
    Map<String, String> style, {
    bool block = false,
  }) {
    final source = _attribute(element, 'src');
    final alt = _attribute(element, 'alt') ?? 'EPUB 圖片';
    if (source == null || source.trim().isEmpty) return _imagePlaceholder(alt);
    final reference = widget.resourceLoader.resolve(
      source,
      fromPath: widget.chapter.resource.path,
    );
    final resource = reference.resource;
    if (!reference.isInternal ||
        resource == null ||
        resource.kind != FrameEpubResourceKind.image) {
      return _imagePlaceholder(alt);
    }
    if (resource.size > widget.maxImageBytes) {
      return _imagePlaceholder('$alt（超過圖片讀取上限）');
    }

    return _FrameEpubImage(
      loader: widget.resourceLoader,
      resource: resource,
      maxBytes: widget.maxImageBytes,
      fit: widget.fixedLayout ? BoxFit.contain : BoxFit.scaleDown,
      maxWidth: _cssDimension(style['width'], widget.fontSize) ??
          (block ? double.infinity : 320),
      maxHeight: _cssDimension(style['height'], widget.fontSize) ??
          (widget.fixedLayout ? double.infinity : 680),
      alt: alt,
    );
  }

  Widget _imagePlaceholder(String label) => Container(
        constraints: const BoxConstraints(
          minWidth: 48,
          minHeight: 42,
          maxWidth: 240,
          maxHeight: 90,
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF211D2B),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFAAA2B8),
            fontSize: 11,
          ),
        ),
      );

  Widget _unsupportedInlineObject(String tag) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF211D2B),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          tag == 'svg' ? 'SVG 圖形暫未支援' : '數學公式暫未支援',
          style: const TextStyle(color: Color(0xFFAAA2B8), fontSize: 11),
        ),
      );

  Map<String, String> _computedStyle(
    XmlElement element,
    FrameEpubCssCascade cascade,
    Map<String, String> parent,
  ) {
    final style = Map<String, String>.from(
      cascade.resolve(
        element,
        parentStyle: parent,
        inlineStyle: _attribute(element, 'style'),
      ),
    );
    final parentSize = _length(parent['font-size'], widget.fontSize);
    final size = _cssFontSize(
      style['font-size'],
      parentSize,
      widget.fontSize,
    );
    style['font-size'] = '${size}px';
    return style;
  }

  TextStyle _textStyle(Map<String, String> style) {
    final size = _length(style['font-size'], widget.fontSize);
    return TextStyle(
      color: _cssColor(style['color']) ?? widget.textColor,
      fontFamily: _fontFamily(style['font-family'], widget.fontFamily),
      fontSize: size,
      fontWeight: _fontWeight(style['font-weight']),
      fontStyle: style['font-style'] == 'italic' ||
              style['font-style'] == 'oblique'
          ? FontStyle.italic
          : FontStyle.normal,
      decoration: _textDecoration(style['text-decoration']),
      height: _lineHeight(style['line-height'], size),
      letterSpacing: _cssDimension(style['letter-spacing'], size),
    );
  }

  static bool _isNonVisualTag(String tag) => const {
        'head',
        'title',
        'meta',
        'link',
        'style',
        'script',
        'noscript',
        'template',
        'iframe',
        'object',
        'embed',
      }.contains(tag);

  static bool _isBlockElement(String tag, Map<String, String> style) {
    if (style['display'] == 'block' ||
        style['display'] == 'list-item' ||
        style['display'] == 'table' ||
        style['display'] == 'flex') {
      return true;
    }
    return const {
      'address',
      'article',
      'aside',
      'blockquote',
      'div',
      'dl',
      'dt',
      'dd',
      'figure',
      'figcaption',
      'footer',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'header',
      'hr',
      'li',
      'main',
      'nav',
      'ol',
      'p',
      'pre',
      'section',
      'table',
      'ul',
    }.contains(tag);
  }

  static XmlElement? _bodyElement(XmlDocument document) {
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (element.name.local.toLowerCase() == 'body') return element;
    }
    return document.rootElement;
  }

  static String? _attribute(XmlElement element, String name) {
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() == name.toLowerCase()) {
        return attribute.value;
      }
    }
    return null;
  }

  static String _listMarker(String? value) {
    switch (value?.toLowerCase()) {
      case 'circle':
        return '○';
      case 'square':
        return '▪';
      case 'none':
        return '';
      default:
        return '•';
    }
  }

  static String _transformText(String value, String? transform) {
    switch (transform?.toLowerCase()) {
      case 'uppercase':
        return value.toUpperCase();
      case 'lowercase':
        return value.toLowerCase();
      default:
        return value;
    }
  }

  static TextAlign _textAlign(String? value) {
    switch (value?.toLowerCase()) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      case 'justify':
        return TextAlign.justify;
      case 'start':
        return TextAlign.start;
      case 'end':
        return TextAlign.end;
      default:
        return TextAlign.left;
    }
  }

  static TextDirection _textDirection(String? value) =>
      value?.toLowerCase() == 'rtl' ? TextDirection.rtl : TextDirection.ltr;

  static FontWeight _fontWeight(String? value) {
    switch (value?.toLowerCase()) {
      case 'bold':
      case 'bolder':
      case '600':
      case '700':
      case '800':
      case '900':
        return FontWeight.bold;
      case '100':
        return FontWeight.w100;
      case '200':
        return FontWeight.w200;
      case '300':
        return FontWeight.w300;
      case '500':
        return FontWeight.w500;
      default:
        return FontWeight.normal;
    }
  }

  static TextDecoration _textDecoration(String? value) {
    final tokens = (value ?? 'none').toLowerCase().split(RegExp(r'\s+'));
    final decorations = <TextDecoration>[
      if (tokens.contains('underline')) TextDecoration.underline,
      if (tokens.contains('line-through')) TextDecoration.lineThrough,
      if (tokens.contains('overline')) TextDecoration.overline,
    ];
    return decorations.isEmpty
        ? TextDecoration.none
        : TextDecoration.combine(decorations);
  }

  static String _fontFamily(String? value, String fallback) {
    if (value == null || value.trim().isEmpty) return fallback;
    final first = value
        .split(',')
        .first
        .trim()
        .replaceAll('"', '')
        .replaceAll("'", '');
    if (const {'serif', 'sans-serif', 'monospace', 'cursive', 'fantasy'}
        .contains(first.toLowerCase())) {
      return first.toLowerCase() == 'monospace' ? 'monospace' : fallback;
    }
    if (const {'NotoSansTC', 'NotoSansSCFallback'}.contains(first)) {
      return first;
    }
    return fallback;
  }

  static double _cssFontSize(String? value, double parent, double root) {
    if (value == null || value.isEmpty) return parent;
    switch (value.toLowerCase().trim()) {
      case 'xx-small':
        return root * .65;
      case 'x-small':
        return root * .75;
      case 'small':
        return root * .85;
      case 'medium':
        return root;
      case 'large':
        return root * 1.15;
      case 'x-large':
        return root * 1.3;
      case 'xx-large':
        return root * 1.5;
      case 'smaller':
        return parent * .8;
      case 'larger':
        return parent * 1.2;
    }
    return _cssDimension(value, parent) ?? parent;
  }

  static double _length(String? value, double fallback) =>
      _cssDimension(value, fallback) ?? fallback;

  static double? _cssDimension(String? source, double reference) {
    if (source == null) return null;
    final value = source.trim().toLowerCase();
    if (value == '0') return 0;
    final match =
        RegExp(r'^([+-]?(?:\d+\.?\d*|\.\d+))(px|pt|em|rem|%)?$')
            .firstMatch(value);
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!);
    if (number == null) return null;
    switch (match.group(2)) {
      case 'pt':
        return number * 96 / 72;
      case 'em':
      case 'rem':
        return reference * number;
      case '%':
        return reference * number / 100;
      default:
        return number;
    }
  }

  static double _lineHeight(String? value, double fontSize) {
    if (value == null || value.isEmpty || value == 'normal') return 1.5;
    final number = double.tryParse(value);
    if (number != null) return number.clamp(0.8, 3.5);
    final pixels = _cssDimension(value, fontSize);
    if (pixels == null || fontSize <= 0) return 1.5;
    return (pixels / fontSize).clamp(0.8, 3.5);
  }

  static EdgeInsets _boxInsets(
    Map<String, String> style,
    String prefix,
    double fontSize,
  ) {
    final values = (style[prefix] ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((item) => item.isNotEmpty)
        .toList();

    String pick(int side) {
      final suffix = ['top', 'right', 'bottom', 'left'][side];
      final exact = style['$prefix-$suffix'];
      if (exact != null) return exact;
      final logical = side == 0
          ? style['$prefix-block-start']
          : side == 2
              ? style['$prefix-block-end']
              : side == 1
                  ? style['$prefix-inline-end']
                  : style['$prefix-inline-start'];
      if (logical != null) return logical;
      if (values.isEmpty) return '0';
      if (values.length == 1) return values[0];
      if (values.length == 2) return values[side.isEven ? 0 : 1];
      if (values.length == 3) return values[side == 0 ? 0 : side == 2 ? 2 : 1];
      return values[side];
    }

    double sideValue(int index) =>
        _cssDimension(pick(index), fontSize) ?? 0;
    return EdgeInsets.fromLTRB(
      sideValue(3),
      sideValue(0),
      sideValue(1),
      sideValue(2),
    );
  }

  static Color? _backgroundFromShorthand(String? value) {
    if (value == null) return null;
    for (final token in value.split(RegExp(r'\s+'))) {
      final color = _cssColor(token);
      if (color != null) return color;
    }
    return null;
  }

  static Color? _cssColor(String? source) {
    if (source == null) return null;
    final value = source.trim().toLowerCase();
    const named = {
      'transparent': Color(0x00000000),
      'black': Color(0xFF000000),
      'white': Color(0xFFFFFFFF),
      'red': Color(0xFFFF0000),
      'green': Color(0xFF008000),
      'blue': Color(0xFF0000FF),
      'yellow': Color(0xFFFFFF00),
      'gray': Color(0xFF808080),
      'grey': Color(0xFF808080),
      'purple': Color(0xFF800080),
      'orange': Color(0xFFFFA500),
      'navy': Color(0xFF000080),
    };
    if (named.containsKey(value)) return named[value];
    if (value.startsWith('#')) {
      var hex = value.substring(1);
      if (hex.length == 3 || hex.length == 4) {
        hex = hex.split('').map((char) => '$char$char').join();
      }
      if (hex.length == 6) {
        final rgb = int.tryParse(hex, radix: 16);
        return rgb == null ? null : Color(0xFF000000 | rgb);
      }
      if (hex.length == 8) {
        final rgba = int.tryParse(hex, radix: 16);
        if (rgba == null) return null;
        return Color(((rgba & 0xff) << 24) | (rgba >> 8));
      }
    }
    final rgb = RegExp(r'^rgba?\(([^)]+)\)$').firstMatch(value);
    if (rgb == null) return null;
    final parts = rgb.group(1)!.split(',').map((part) => part.trim()).toList();
    if (parts.length < 3) return null;

    int channel(String part) {
      if (part.endsWith('%')) {
        return ((double.tryParse(part.substring(0, part.length - 1)) ?? 0) *
                2.55)
            .round()
            .clamp(0, 255);
      }
      return (double.tryParse(part) ?? 0).round().clamp(0, 255);
    }

    final red = channel(parts[0]);
    final green = channel(parts[1]);
    final blue = channel(parts[2]);
    final alpha = parts.length > 3
        ? ((double.tryParse(parts[3]) ?? 1) * 255).round().clamp(0, 255)
        : 255;
    return Color((alpha << 24) | (red << 16) | (green << 8) | blue);
  }

  static String _colorToCss(Color color) =>
      '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';
}

class _FrameEpubImage extends StatefulWidget {
  const _FrameEpubImage({
    required this.loader,
    required this.resource,
    required this.maxBytes,
    required this.fit,
    required this.maxWidth,
    required this.maxHeight,
    required this.alt,
  });

  final FrameEpubResourceLoader loader;
  final FrameEpubResource resource;
  final int maxBytes;
  final BoxFit fit;
  final double maxWidth;
  final double maxHeight;
  final String alt;

  @override
  State<_FrameEpubImage> createState() => _FrameEpubImageState();
}

class _FrameEpubImageState extends State<_FrameEpubImage> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant _FrameEpubImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.resource, widget.resource) ||
        !identical(oldWidget.loader, widget.loader)) {
      _bytes = _load();
    }
  }

  Future<Uint8List> _load() => widget.loader.readBytes(
        widget.resource,
        maxBytes: widget.maxBytes,
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return SizedBox(
            width: widget.maxWidth.isFinite ? widget.maxWidth : 48,
            height: 80,
            child: Center(
              child: snapshot.hasError
                  ? const Icon(
                      Icons.broken_image_outlined,
                      color: Color(0xFF8F829F),
                    )
                  : const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : widget.maxWidth;
            final cacheWidth = (availableWidth.isFinite
                    ? availableWidth * dpr
                    : 1600)
                .round()
                .clamp(96, 2048)
                .toInt();
            final image = Image.memory(
              snapshot.data!,
              fit: widget.fit,
              cacheWidth: cacheWidth,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.broken_image_outlined,
                color: Color(0xFF8F829F),
              ),
              semanticLabel: widget.alt,
            );
            if (widget.maxWidth.isInfinite && widget.maxHeight.isInfinite) {
              return SizedBox.expand(child: image);
            }
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.maxWidth,
                maxHeight: widget.maxHeight,
              ),
              child: image,
            );
          },
        );
      },
    );
  }
}
