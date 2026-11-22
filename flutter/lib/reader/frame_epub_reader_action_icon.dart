import 'package:flutter/material.dart';

/// The four icon paths used by the legacy Reading Room action row.
enum FrameEpubReaderActionIcon {
  bookmark,
  sidebar,
  appearance,
  fullscreenEnter,
  fullscreenExit,
}

/// Paints the exact 24px SVG paths used by the legacy HTML reader.
///
/// A small SVG path reader is kept local so the Web, macOS and Android
/// previews all share the same geometry without introducing a renderer
/// dependency or shipping a second icon set.
class FrameEpubReaderActionGlyph extends StatelessWidget {
  const FrameEpubReaderActionGlyph({
    required this.icon,
    required this.color,
    super.key,
  });

  final FrameEpubReaderActionIcon icon;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 24,
        height: 24,
        child: CustomPaint(
          painter: _FrameEpubReaderActionGlyphPainter(
            icon: icon,
            color: color,
          ),
        ),
      );
}

class _FrameEpubReaderActionGlyphPainter extends CustomPainter {
  const _FrameEpubReaderActionGlyphPainter({
    required this.icon,
    required this.color,
  });

  final FrameEpubReaderActionIcon icon;
  final Color color;

  static const _bookmark = <String>[
    'M17 3H7c-1.1 0-2 .9-2 2v16l5-2.18V18.6L7 20V5h10v6h2V5c0-1.1-.9-2-2-2z',
    'M19 13h-2v3h-3v2h3v3h2v-3h3v-2h-3z',
  ];

  static const _sidebar = <String>[
    'M21 4c-1.1-.35-2.3-.5-3.5-.5-2.1 0-4.1.4-5.5 1.5-1.4-1.1-3.4-1.5-5.5-1.5C5.3 3.5 4.1 3.65 3 4v15.5c1.1-.35 2.4-.5 3.5-.5 2.2 0 4.2.6 5.5 1.7 1.3-1.1 3.3-1.7 5.5-1.7 1.2 0 2.4.15 3.5.5V4zM10 18.1c-1.2-.7-2.8-1.1-4.5-1.1-.5 0-1 .03-1.5.1V5.6c.5-.07 1-.1 1.5-.1 1.7 0 3.3.4 4.5 1.1v11.5zm10 0c-.5-.07-1-.1-1.5-.1-1.7 0-3.3.4-4.5 1.1V6.6c1.2-.7 2.8-1.1 4.5-1.1.5 0 1 .03 1.5.1v12.5z',
  ];

  static const _appearance = <String>[
    'M2 5v3h1V6h3v12H4v1h6v-1H8V6h3v2h1V5H2zm12 4v2h1v-1h2v7h-1v1h5v-1h-1v-7h2V9h-8z',
  ];

  static const _fullscreenEnter = <String>[
    'M3 3h6v2H5v4H3V3zm12 0h6v6h-2V5h-4V3zM3 15h2v4h4v2H3v-6zm16 4v-4h2v6h-6v-2h4z',
  ];

  static const _fullscreenExit = <String>[
    'M5 16h3v3h2v-5H5v2zm3-8H5v2h5V5H8v3zm6 11h2v-3h3v-2h-5v5zm2-11V5h-2v5h5V8h-3z',
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paths = switch (icon) {
      FrameEpubReaderActionIcon.bookmark => _bookmark,
      FrameEpubReaderActionIcon.sidebar => _sidebar,
      FrameEpubReaderActionIcon.appearance => _appearance,
      FrameEpubReaderActionIcon.fullscreenEnter => _fullscreenEnter,
      FrameEpubReaderActionIcon.fullscreenExit => _fullscreenExit,
    };
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    for (final pathData in paths) {
      canvas.drawPath(_parseSvgPath(pathData), paint);
    }
    canvas.restore();
  }

  static Path _parseSvgPath(String data) {
    final tokens = RegExp(
      r'[MmLlHhVvCcZz]|[-+]?(?:\\d*\\.\\d+|\\d+\\.?\\d*)(?:[eE][-+]?\\d+)?',
    ).allMatches(data).map((match) => match.group(0)!).toList();
    final path = Path();
    var index = 0;
    var command = '';
    var current = Offset.zero;
    var subpathStart = Offset.zero;

    bool isCommand(String token) =>
        token.length == 1 && 'MmLlHhVvCcZz'.contains(token);

    double nextNumber() => double.parse(tokens[index++]);

    while (index < tokens.length) {
      final token = tokens[index];
      if (isCommand(token)) {
        command = token;
        index++;
        if (command == 'Z' || command == 'z') {
          path.close();
          current = subpathStart;
          command = '';
        }
        continue;
      }

      switch (command) {
        case 'M':
        case 'm':
          final relative = command == 'm';
          final x = nextNumber();
          final y = nextNumber();
          current = relative
              ? current + Offset(x, y)
              : Offset(x, y);
          path.moveTo(current.dx, current.dy);
          subpathStart = current;
          command = relative ? 'l' : 'L';
        case 'L':
        case 'l':
          final relative = command == 'l';
          final x = nextNumber();
          final y = nextNumber();
          current = relative
              ? current + Offset(x, y)
              : Offset(x, y);
          path.lineTo(current.dx, current.dy);
        case 'H':
        case 'h':
          final relative = command == 'h';
          final x = nextNumber();
          current = Offset(relative ? current.dx + x : x, current.dy);
          path.lineTo(current.dx, current.dy);
        case 'V':
        case 'v':
          final relative = command == 'v';
          final y = nextNumber();
          current = Offset(current.dx, relative ? current.dy + y : y);
          path.lineTo(current.dx, current.dy);
        case 'C':
        case 'c':
          final relative = command == 'c';
          final x1 = nextNumber();
          final y1 = nextNumber();
          final x2 = nextNumber();
          final y2 = nextNumber();
          final x = nextNumber();
          final y = nextNumber();
          final control1 = relative ? current + Offset(x1, y1) : Offset(x1, y1);
          final control2 = relative ? current + Offset(x2, y2) : Offset(x2, y2);
          final end = relative ? current + Offset(x, y) : Offset(x, y);
          path.cubicTo(
            control1.dx,
            control1.dy,
            control2.dx,
            control2.dy,
            end.dx,
            end.dy,
          );
          current = end;
        default:
          throw FormatException('Unsupported SVG path command: $command');
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(
    covariant _FrameEpubReaderActionGlyphPainter oldDelegate,
  ) =>
      oldDelegate.icon != icon || oldDelegate.color != color;
}
