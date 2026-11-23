import 'package:material_ui/material_ui.dart';

import 'frame_epub_reader_page_navigation_button.dart';

/// Page-turn controls and progress meters styled to the legacy Reading Room.
class FrameEpubReaderProgressPanel extends StatelessWidget {
  const FrameEpubReaderProgressPanel({
    required this.chapterProgressPercent,
    required this.bookProgressPercent,
    required this.canGoPrevious,
    required this.canGoNext,
    required this.onPrevious,
    required this.onNext,
    super.key,
  });

  final int? chapterProgressPercent;
  final int bookProgressPercent;
  final bool canGoPrevious;
  final bool canGoNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  Widget _progressRow({
    required String rowKey,
    required String trackKey,
    required String label,
    required int percent,
    required bool isBook,
  }) {
    final value = percent.clamp(0, 100).toInt();
    final trackHeight = isBook ? 3.0 : 4.0;
    final gradient = isBook
        ? const LinearGradient(
            colors: [Color(0xFF665187), Color(0xFF8D73B8)],
          )
        : const LinearGradient(
            colors: [Color(0xFF8B6BD0), Color(0xFFC2A7FF)],
          );

    return Column(
      key: ValueKey(rowKey),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                key: ValueKey('$rowKey-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFA69BB6),
                  fontSize: 9,
                  height: 1.25,
                  letterSpacing: .2,
                ),
              ),
            ),
            Text(
              '$value%',
              key: ValueKey('$rowKey-percent'),
              style: const TextStyle(
                color: Color(0xFFD5C6F7),
                fontSize: 9,
                height: 1.25,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Semantics(
          label: label,
          value: '$value%',
          child: SizedBox(
            key: ValueKey(trackKey),
            width: double.infinity,
            height: trackHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0x24AB97CA)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: value / 100,
                      child: DecoratedBox(
                        decoration: BoxDecoration(gradient: gradient),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _progressPanel({required bool compact}) => Padding(
        key: const ValueKey('reader-progress-panel-padding'),
        padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
        child: Column(
          key: const ValueKey('reader-progress-panel'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (chapterProgressPercent != null)
              _progressRow(
                rowKey: 'reader-progress-chapter-row',
                trackKey: 'reader-progress-chapter-track',
                label: '本章進度',
                percent: chapterProgressPercent!,
                isBook: false,
              ),
            if (chapterProgressPercent != null) const SizedBox(height: 8),
            _progressRow(
              rowKey: 'reader-progress-book-row',
              trackKey: 'reader-progress-book-track',
              label: '全書進度',
              percent: bookProgressPercent,
              isBook: true,
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width <= 720;

    Widget pageButton({required bool previous}) =>
        FrameEpubReaderPageNavigationButton(
          previous: previous,
          enabled: previous ? canGoPrevious : canGoNext,
          onPressed: previous ? onPrevious : onNext,
        );

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
          child: compact
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(child: pageButton(previous: true)),
                        const SizedBox(width: 8),
                        Expanded(child: pageButton(previous: false)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _progressPanel(compact: true),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: pageButton(previous: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 220,
                        maxWidth: 300,
                      ),
                      child: _progressPanel(compact: false),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: pageButton(previous: false),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
