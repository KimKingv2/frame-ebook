import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Adds consistent keyboard page-turn behavior to the shared EPUB reader.
///
/// Reflowable chapters move by approximately one viewport. At chapter edges,
/// the callback loads the adjacent spine item. Fixed-layout EPUBs have no
/// scrolling viewport, so each key press advances directly to the next page.
class FrameEpubPageTurnSurface extends StatefulWidget {
  const FrameEpubPageTurnSurface({
    required this.controller,
    required this.child,
    this.onPreviousChapter,
    this.onNextChapter,
    super.key,
  });

  final ScrollController controller;
  final Widget child;
  final Future<void> Function()? onPreviousChapter;
  final Future<void> Function()? onNextChapter;

  @override
  State<FrameEpubPageTurnSurface> createState() =>
      _FrameEpubPageTurnSurfaceState();
}

class _FrameEpubPageTurnSurfaceState extends State<FrameEpubPageTurnSurface> {
  bool _isTurning = false;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final backward = key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.backspace ||
        (key == LogicalKeyboardKey.space &&
            HardwareKeyboard.instance.isShiftPressed);
    final forward = key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight ||
        (key == LogicalKeyboardKey.space &&
            !HardwareKeyboard.instance.isShiftPressed);

    if (!backward && !forward) return KeyEventResult.ignored;
    unawaited(_turnPage(forward: forward));
    return KeyEventResult.handled;
  }

  Future<void> _turnPage({required bool forward}) async {
    if (_isTurning || !mounted) return;
    _isTurning = true;
    try {
      final controller = widget.controller;
      if (!controller.hasClients) {
        await _turnAdjacentChapter(forward: forward);
        return;
      }

      final position = controller.position;
      if (!position.hasContentDimensions ||
          !position.viewportDimension.isFinite ||
          position.viewportDimension <= 0) {
        return;
      }

      final current = position.pixels;
      final boundary = forward
          ? current >= position.maxScrollExtent - 1
          : current <= position.minScrollExtent + 1;
      if (boundary) {
        await _turnAdjacentChapter(forward: forward);
        return;
      }

      final delta = position.viewportDimension * 0.86;
      final target = (current + (forward ? delta : -delta))
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      await controller.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } finally {
      _isTurning = false;
    }
  }

  Future<void> _turnAdjacentChapter({required bool forward}) async {
    final callback = forward
        ? widget.onNextChapter
        : widget.onPreviousChapter;
    if (callback != null) await callback();
  }

  @override
  Widget build(BuildContext context) => Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: widget.child,
      );
}
