import 'package:flutter/widgets.dart';
import 'package:xml/xml.dart';

/// A bounded, local renderer for common Presentation MathML constructs.
///
/// This intentionally supports a useful subset rather than attempting to be
/// a browser-complete MathML implementation. It never evaluates annotation
/// content, loads external resources, or interprets markup as HTML.
class FrameEpubMathMl extends StatelessWidget {
  const FrameEpubMathMl({
    required this.element,
    required this.textStyle,
    super.key,
  });

  final XmlElement element;
  final TextStyle textStyle;

  static const int _maxNodes = 512;
  static const int _maxDepth = 32;

  @override
  Widget build(BuildContext context) {
    if (!_withinBudget(element)) {
      return _unsupportedFormula();
    }

    final label = element.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
    final display = _attribute(element, 'display')?.toLowerCase() == 'block';
    final content = _buildNode(element, textStyle, 0);

    return Semantics(
      label: label.isEmpty ? '數學公式' : '數學公式：$label',
      image: true,
      child: display
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: content,
              ),
            )
          : content,
    );
  }

  bool _withinBudget(XmlElement root) {
    var count = 0;
    var exceeded = false;

    void visit(XmlNode node, int depth) {
      if (exceeded) return;
      count++;
      if (count > _maxNodes || depth > _maxDepth) {
        exceeded = true;
        return;
      }
      if (node is XmlElement) {
        for (final child in node.children) {
          visit(child, depth + 1);
          if (exceeded) return;
        }
      }
    }

    visit(root, 0);
    return !exceeded;
  }

  Widget _unsupportedFormula() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0x142F2940),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: const Color(0x66514A60)),
        ),
        child: Text(
          '數學公式過於複雜，暫時無法顯示',
          style: textStyle.copyWith(fontSize: (textStyle.fontSize ?? 16) * 0.75),
        ),
      );

  Widget _buildNode(XmlElement node, TextStyle inherited, int depth) {
    if (depth > _maxDepth) return const SizedBox.shrink();

    final tag = node.name.local.toLowerCase();
    final style = _nodeStyle(node, inherited);
    final children = node.children.whereType<XmlElement>().toList(growable: false);

    switch (tag) {
      case 'annotation':
      case 'annotation-xml':
      case 'mprescripts':
      case 'none':
        return const SizedBox.shrink();

      case 'mi':
        return _token(node.innerText, style, defaultItalic: true);
      case 'mn':
      case 'mo':
      case 'mtext':
      case 'ms':
        return _token(node.innerText, style);
      case 'mspace':
        return _space(node, style);

      case 'mfrac':
        if (children.length < 2) return _children(node, style, depth);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Center(
                    child: _buildNode(children[0], style, depth + 1),
                  ),
                ),
                Container(
                  height: _fractionLineThickness(node, style),
                  color: style.color ?? const Color(0xFF26222D),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Center(
                    child: _buildNode(children[1], style, depth + 1),
                  ),
                ),
              ],
            ),
          ),
        );

      case 'msqrt':
        return _radical(
          node,
          children,
          style,
          depth,
        );
      case 'mroot':
        return _radical(
          node,
          children,
          style,
          depth,
          hasIndex: true,
        );

      case 'msup':
      case 'msub':
      case 'msubsup':
        return _scripts(node, children, style, depth, tag);

      case 'mover':
      case 'munder':
      case 'munderover':
        return _limits(node, children, style, depth, tag);

      case 'mfenced':
        return _fenced(node, children, style, depth);

      case 'mtable':
        return _mathTable(node, children, style, depth);
      case 'mtr':
      case 'mlabeledtr':
        return _mathRow(children, style, depth);
      case 'mtd':
        return _children(node, style, depth);

      case 'menclose':
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            border: Border.all(
              color: style.color ?? const Color(0xFF51495E),
              width: 1,
            ),
          ),
          child: _children(node, style, depth),
        );

      case 'mphantom':
        return Opacity(
          opacity: 0,
          child: _children(node, style, depth),
        );

      case 'math':
      case 'mrow':
      case 'mstyle':
      case 'semantics':
      case 'merror':
      case 'mpadded':
        return _children(node, style, depth);

      default:
        // Unknown presentation elements remain readable through their
        // children rather than dropping the entire formula.
        return _children(node, style, depth);
    }
  }

  Widget _children(XmlElement node, TextStyle style, int depth) {
    final widgets = <Widget>[];
    for (final child in node.children) {
      if (child is XmlElement) {
        final tag = child.name.local.toLowerCase();
        if (tag == 'annotation' || tag == 'annotation-xml') continue;
        widgets.add(_buildNode(child, style, depth + 1));
      } else if (child is XmlText) {
        final text = child.value;
        if (text.trim().isNotEmpty) {
          widgets.add(_token(text.trim(), style));
        }
      }
    }
    if (widgets.isEmpty) return const SizedBox.shrink();
    if (widgets.length == 1) return widgets.single;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: widgets,
    );
  }

  Widget _token(
    String raw,
    TextStyle style, {
    bool defaultItalic = false,
  }) {
    final value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (value.isEmpty) return const SizedBox.shrink();
    return Text(
      value,
      softWrap: false,
      style: defaultItalic && style.fontStyle == FontStyle.normal
          ? style.copyWith(fontStyle: FontStyle.italic)
          : style,
    );
  }

  Widget _scripts(
    XmlElement node,
    List<XmlElement> children,
    TextStyle style,
    int depth,
    String tag,
  ) {
    if (children.isEmpty) return _children(node, style, depth);
    final base = _buildNode(children[0], style, depth + 1);
    final hasSub = tag == 'msub' || tag == 'msubsup';
    final hasSup = tag == 'msup' || tag == 'msubsup';
    final subIndex = 1;
    final supIndex = tag == 'msubsup' ? 2 : 1;
    final scriptStyle = style.copyWith(
      fontSize: (style.fontSize ?? 16) * 0.68,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        base,
        if ((hasSup && children.length > supIndex) ||
            (hasSub && children.length > subIndex))
          Padding(
            padding: const EdgeInsets.only(left: 1),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasSup && children.length > supIndex)
                  Transform.translate(
                    offset: Offset(0, (style.fontSize ?? 16) * 0.10),
                    child: _buildNode(
                      children[supIndex],
                      scriptStyle,
                      depth + 1,
                    ),
                  ),
                if (hasSub && children.length > subIndex)
                  Transform.translate(
                    offset: Offset(0, -(style.fontSize ?? 16) * 0.10),
                    child: _buildNode(
                      children[subIndex],
                      scriptStyle,
                      depth + 1,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _limits(
    XmlElement node,
    List<XmlElement> children,
    TextStyle style,
    int depth,
    String tag,
  ) {
    if (children.isEmpty) return _children(node, style, depth);
    final small = style.copyWith(fontSize: (style.fontSize ?? 16) * 0.68);
    final base = _buildNode(children[0], style, depth + 1);
    final underIndex = 1;
    final overIndex = tag == 'munderover' ? 2 : 1;
    final hasUnder = tag == 'munder' || tag == 'munderover';
    final hasOver = tag == 'mover' || tag == 'munderover';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasOver && children.length > overIndex)
          _buildNode(children[overIndex], small, depth + 1),
        base,
        if (hasUnder && children.length > underIndex)
          _buildNode(children[underIndex], small, depth + 1),
      ],
    );
  }

  Widget _radical(
    XmlElement node,
    List<XmlElement> children,
    TextStyle style,
    int depth, {
    bool hasIndex = false,
  }) {
    if (children.isEmpty) return _children(node, style, depth);
    final radicandIndex = hasIndex ? 0 : 0;
    final index = hasIndex && children.length > 1 ? children[1] : null;
    final radicand = _buildNode(
      children[radicandIndex],
      style,
      depth + 1,
    );
    final radicalStyle = style.copyWith(
      fontSize: (style.fontSize ?? 16) * 1.55,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (index != null)
          Padding(
            padding: const EdgeInsets.only(right: 1, bottom: 5),
            child: _buildNode(
              index,
              style.copyWith(fontSize: (style.fontSize ?? 16) * 0.58),
              depth + 1,
            ),
          ),
        Text('√', style: radicalStyle),
        Container(
          padding: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: style.color ?? const Color(0xFF26222D),
                width: 1,
              ),
            ),
          ),
          child: radicand,
        ),
      ],
    );
  }

  Widget _fenced(
    XmlElement node,
    List<XmlElement> children,
    TextStyle style,
    int depth,
  ) {
    final open = _attribute(node, 'open') ?? '(';
    final close = _attribute(node, 'close') ?? ')';
    final separators = _attribute(node, 'separators') ?? ',';
    final widgets = <Widget>[];
    for (var index = 0; index < children.length; index++) {
      if (index > 0) {
        final separator = separators.isEmpty
            ? ','
            : separators[(index - 1).clamp(0, separators.length - 1)];
        widgets.add(_token(separator, style));
      }
      widgets.add(_buildNode(children[index], style, depth + 1));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _token(open, style),
        ...widgets,
        _token(close, style),
      ],
    );
  }

  Widget _mathTable(
    XmlElement node,
    List<XmlElement> children,
    TextStyle style,
    int depth,
  ) {
    final rows = children.where((element) {
      final tag = element.name.local.toLowerCase();
      return tag == 'mtr' || tag == 'mlabeledtr';
    }).toList(growable: false);
    if (rows.isEmpty) return _children(node, style, depth);
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        for (final row in rows)
          TableRow(
            children: [
              for (final cell in row.children.whereType<XmlElement>())
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  child: _buildNode(cell, style, depth + 1),
                ),
            ],
          ),
      ],
    );
  }

  Widget _mathRow(
    List<XmlElement> children,
    TextStyle style,
    int depth,
  ) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final child in children)
            _buildNode(child, style, depth + 1),
        ],
      );

  Widget _space(XmlElement node, TextStyle style) {
    final raw = _attribute(node, 'width') ?? '0.5em';
    final fontSize = style.fontSize ?? 16;
    final match = RegExp(r'^(-?[0-9]*\.?[0-9]+)\s*(em|ex|px|pt)?$')
        .firstMatch(raw.trim());
    if (match == null) return const SizedBox(width: 4);
    final value = double.tryParse(match.group(1) ?? '') ?? 0;
    final unit = match.group(2) ?? 'em';
    final factor = switch (unit) {
      'px' => 1.0,
      'pt' => 96 / 72,
      'ex' => 0.5,
      _ => fontSize,
    };
    return SizedBox(width: (value * factor).clamp(0, fontSize * 8).toDouble());
  }

  double _fractionLineThickness(XmlElement node, TextStyle style) {
    final raw = _attribute(node, 'linethickness')?.trim().toLowerCase();
    if (raw == '0' || raw == '0px') return 0;
    if (raw == 'thin') return 0.65;
    if (raw == 'thick') return 1.8;
    final parsed = double.tryParse(raw ?? '');
    if (parsed == null || !parsed.isFinite) return 1;
    return (parsed * (style.fontSize ?? 16)).clamp(0.4, 3).toDouble();
  }

  TextStyle _nodeStyle(XmlElement node, TextStyle parent) {
    final tag = node.name.local.toLowerCase();
    final variant = (_attribute(node, 'mathvariant') ?? '').toLowerCase();
    final size = _mathSize(_attribute(node, 'mathsize'), parent.fontSize ?? 16);
    var result = parent.copyWith(fontSize: size);

    if (tag == 'mi' && variant.isEmpty) {
      result = result.copyWith(fontStyle: FontStyle.italic);
    }
    switch (variant) {
      case 'normal':
        result = result.copyWith(fontStyle: FontStyle.normal);
        break;
      case 'bold':
        result = result.copyWith(fontWeight: FontWeight.bold);
        break;
      case 'italic':
        result = result.copyWith(fontStyle: FontStyle.italic);
        break;
      case 'bold-italic':
        result = result.copyWith(
          fontWeight: FontWeight.bold,
          fontStyle: FontStyle.italic,
        );
        break;
      case 'double-struck':
      case 'fraktur':
      case 'script':
        // Flutter's bundled text fonts provide a useful fallback even when a
        // specialized mathematical alphabet is unavailable on the device.
        result = result.copyWith(
          fontStyle: FontStyle.normal,
          fontWeight: FontWeight.normal,
        );
        break;
    }
    return result;
  }

  double _mathSize(String? raw, double parentSize) {
    if (raw == null || raw.trim().isEmpty) return parentSize;
    final value = raw.trim().toLowerCase();
    switch (value) {
      case 'small':
        return parentSize * 0.8;
      case 'big':
        return parentSize * 1.2;
      case 'normal':
        return parentSize;
    }
    final match = RegExp(r'^([0-9]*\.?[0-9]+)(%|em|px|pt)?$')
        .firstMatch(value);
    if (match == null) return parentSize;
    final number = double.tryParse(match.group(1) ?? '') ?? parentSize;
    final unit = match.group(2) ?? 'em';
    final resolved = switch (unit) {
      '%' => parentSize * number / 100,
      'px' => number,
      'pt' => number * 96 / 72,
      _ => parentSize * number,
    };
    if (!resolved.isFinite) return parentSize;
    return resolved.clamp(parentSize * 0.45, parentSize * 2.5).toDouble();
  }

  String? _attribute(XmlElement element, String name) {
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() == name.toLowerCase()) {
        return attribute.value;
      }
    }
    return null;
  }
}
