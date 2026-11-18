import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:material_ui/material_ui.dart';
import 'package:web/web.dart' as web;

import 'frame_reader_engine.dart';

final Map<String, web.HTMLIFrameElement> _readerFrames =
    <String, web.HTMLIFrameElement>{};
int _nextReaderFrameId = 0;

Widget buildFrameReaderEngine({
  required Uri uri,
  required String title,
  required FrameReaderEngineHandle handle,
}) =>
    _WebFrameReaderEngine(
      uri: uri,
      title: title,
      handle: handle,
    );

class _WebFrameReaderEngine extends StatefulWidget {
  const _WebFrameReaderEngine({
    required this.uri,
    required this.title,
    required this.handle,
  });

  final Uri uri;
  final String title;
  final FrameReaderEngineHandle handle;

  @override
  State<_WebFrameReaderEngine> createState() => _WebFrameReaderEngineState();
}

class _WebFrameReaderEngineState extends State<_WebFrameReaderEngine> {
  late final String _viewType;
  late final web.HTMLIFrameElement _iframe;

  @override
  void initState() {
    super.initState();
    _viewType = 'frame-ebook-reader-engine-${_nextReaderFrameId++}';
    _iframe = web.HTMLIFrameElement()
      ..src = widget.uri.toString()
      ..title = widget.title
      ..allow = 'fullscreen; clipboard-read; clipboard-write'
      ..allowFullscreen = true
      ..referrerPolicy = 'same-origin';
    _iframe.style
      ..border = '0'
      ..width = '100%'
      ..height = '100%'
      ..display = 'block'
      ..backgroundColor = '#12101a';
    _readerFrames[_viewType] = _iframe;
    widget.handle.attach(_sendCommand);
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _readerFrames[_viewType] ?? web.HTMLDivElement(),
    );
  }

  void _sendCommand(String command) {
    if (command == 'reload') {
      _iframe.src = widget.uri.toString();
      return;
    }

    final target = _iframe.contentWindow;
    if (target == null) return;
    final message = jsonEncode({
      'channel': 'frame-ebook-reader',
      'command': command,
    });
    target.postMessage(message.toJS, web.window.location.origin);
  }

  @override
  void didUpdateWidget(covariant _WebFrameReaderEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) {
      _iframe.src = widget.uri.toString();
    }
    if (oldWidget.title != widget.title) {
      _iframe.title = widget.title;
    }
    if (!identical(oldWidget.handle, widget.handle)) {
      oldWidget.handle.attach(null);
      widget.handle.attach(_sendCommand);
    }
  }

  @override
  void dispose() {
    widget.handle.attach(null);
    _readerFrames.remove(_viewType);
    _iframe.src = 'about:blank';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
