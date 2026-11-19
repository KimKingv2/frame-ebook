import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Adds keyboard and touch page-turn behavior to the shared EPUB reader.
///
/// Reflowable chapters move by approximately one viewport. At chapter edges,
/// the callback loads the adjacent spine item. Fixed-layout EPUBs navigate
/// between spine items and keep zoomed image panning available.
class FrameEpubPageTurnSurface extends StatefulWidget {
  const FrameEpubPageTurnSurface({
    required this.controller,
    required this.child,
    this.pageController,
    this.paginated = false,
    this.onPreviousChapter,
    this.onNextChapter,
    this.fixedLayout = false,
    this.isRightToLeft = false,
    this.selectionActive = false,
    this.pageZoomed = false,
    super.key,
  });

  final ScrollController controller;
  final PageController? pageController;
  final bool paginated;
  final Widget child;
  final Future<void> Function()? onPreviousChapter;
  final Future<void> Function()? onNextChapter;
  final bool fixedLayout;
  final bool isRightToLeft;
  final bool selectionActive;
  final bool pageZoomed;

  @override
  State<FrameEpubPageTurnSurface> createState() =>
      _FrameEpubPageTurnSurfaceState();
}

class _TouchStart {
  const _TouchStart({
    required this.pointer,
    required this.position,
    required this.timeStamp,
  });

  final int pointer;
  final Offset position;
  final Duration timeStamp;
}

class _FrameEpubPageTurnSurfaceState extends State<FrameEpubPageTurnSurface> {
  static const _tapDuration = Duration(milliseconds: 300);
  static const _swipeDuration = Duration(milliseconds: 500);
  static const _tapSlop = 18.0;
  static const _swipeDistance = 64.0;
  static const _edgeFraction = 0.22;

  bool _isTurning = false;
  final Set<int> _activeTouchPointers = {};
  _TouchStart? _touchStart;
  bool _multiTouchSequence = false;

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

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;

    if (_activeTouchPointers.isNotEmpty) {
      _multiTouchSequence = true;
      _touchStart = null;
    } else {
      _multiTouchSequence = false;
      _touchStart = _TouchStart(
        pointer: event.pointer,
        position: event.localPosition,
        timeStamp: event.timeStamp,
      );
    }
    _activeTouchPointers.add(event.pointer);
  }

  void _handlePointerUp(PointerUpEvent event, Size surfaceSize) {
    if (!_activeTouchPointers.remove(event.pointer)) return;

    final start = _touchStart;
    final isMultiTouch = _multiTouchSequence || _activeTouchPointers.isNotEmpty;
    if (_activeTouchPointers.isEmpty) {
      _touchStart = null;
      _multiTouchSequence = false;
    }
    if (isMultiTouch ||
        start == null ||
        start.pointer != event.pointer ||
        widget.selectionActive ||
        widget.pageZoomed ||
        surfaceSize.width <= 0) {
      return;
    }

    final elapsed = event.timeStamp - start.timeStamp;
    if (elapsed.isNegative) return;
    final delta = event.localPosition - start.position;
    final dx = delta.dx;
    final dy = delta.dy;

    final horizontalSwipe = elapsed <= _swipeDuration &&
        dx.abs() >= _swipeDistance &&
        dx.abs() >= dy.abs() * 1.25;
    if (horizontalSwipe) {
      final forward = widget.isRightToLeft ? dx > 0 : dx < 0;
      unawaited(_turnPage(forward: forward));
      return;
    }

    final isTap = elapsed <= _tapDuration && delta.distance <= _tapSlop;
    if (!isTap) return;

    final edgeWidth = surfaceSize.width * _edgeFraction;
    final onLeadingEdge = start.position.dx <= edgeWidth;
    final onTrailingEdge =
        start.position.dx >= surfaceSize.width - edgeWidth;
    if (!onLeadingEdge && !onTrailingEdge) return;

    final forward = widget.isRightToLeft ? onLeadingEdge : onTrailingEdge;
    unawaited(_turnPage(forward: forward));
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (!_activeTouchPointers.remove(event.pointer)) return;
    _touchStart = null;
    if (_activeTouchPointers.isEmpty) _multiTouchSequence = false;
  }

  Future<void> _turnPage({required bool forward}) async {
    if (_isTurning || !mounted) return;
    _isTurning = true;
    try {
      if (widget.fixedLayout) {
        await _turnAdjacentChapter(forward: forward);
        return;
      }
      if (widget.paginated) {
        final pageController = widget.pageController;
        if (pageController == null || !pageController.hasClients) return;
        final position = pageController.position;
        if (!position.hasContentDimensions ||
            !position.viewportDimension.isFinite ||
            position.viewportDimension <= 0) {
          return;
        }
        final current = (pageController.page ?? 0).round();
        final lastPage =
            (position.maxScrollExtent / position.viewportDimension).round();
        final boundary = forward ? current >= lastPage : current <= 0;
        if (boundary) {
          await _turnAdjacentChapter(forward: forward);
          return;
        }
        await pageController.animateToPage(
          current + (forward ? 1 : -1),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
        return;
      }

      final controller = widget.controller;
      if (!controller.hasClients) return;

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
    final callback =
        forward ? widget.onNextChapter : widget.onPreviousChapter;
    if (callback != null) await callback();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _handlePointerDown,
            onPointerUp: (event) => _handlePointerUp(event, size),
            onPointerCancel: _handlePointerCancel,
            child: Focus(
              autofocus: true,
              onKeyEvent: _handleKeyEvent,
              child: widget.child,
            ),
          );
        },
      );
}
