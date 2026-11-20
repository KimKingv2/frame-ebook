import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/reader/frame_epub_text_paginator.dart';

void main() {
  test('splits long rich text only at rendered line boundaries', () {
    final text = TextSpan(
      style: const TextStyle(fontSize: 18, height: 1.6),
      children: [
        TextSpan(text: '這是一段很長的中文內容，'),
        TextSpan(
          text: '其中包含粗體文字以及',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        TextSpan(text: List.filled(40, '更多一般文字。').join()),
      ],
    );
    const textScaler = TextScaler.noScaling;
    final plainText = text.toPlainText(includeSemanticsLabels: false);
    final ranges = FrameEpubTextPaginator.paginate(
      text: text,
      maxWidth: 120,
      maxHeight: 70,
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.start,
      textScaler: textScaler,
    );

    expect(ranges.length, greaterThan(1));
    expect(ranges.first.start, 0);
    expect(ranges.last.end, plainText.length);
    for (var index = 1; index < ranges.length; index++) {
      expect(ranges[index].start, ranges[index - 1].end);
    }
    expect(
      ranges.map((range) => plainText.substring(range.start, range.end)).join(),
      plainText,
    );
  });

  test('keeps inline widget placeholders in one intact fragment', () {
    final text = TextSpan(
      style: const TextStyle(fontSize: 18),
      children: [
        TextSpan(text: 'Before image '),
        WidgetSpan(child: SizedBox(width: 24, height: 24)),
        TextSpan(text: List.filled(40, ' after image ').join()),
      ],
    );
    final plainText = text.toPlainText(
      includeSemanticsLabels: false,
      includePlaceholders: true,
    );

    final ranges = FrameEpubTextPaginator.paginate(
      text: text,
      maxWidth: 100,
      maxHeight: 40,
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.start,
      textScaler: TextScaler.noScaling,
    );

    expect(ranges, [TextRange(start: 0, end: plainText.length)]);
  });

  test('keeps a short paragraph in one fragment', () {
    const text = TextSpan(
      style: TextStyle(fontSize: 16),
      text: 'Short paragraph.',
    );
    final ranges = FrameEpubTextPaginator.paginate(
      text: text,
      maxWidth: 300,
      maxHeight: 200,
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.start,
      textScaler: TextScaler.noScaling,
    );

    expect(ranges, [const TextRange(start: 0, end: 16)]);
  });
}
