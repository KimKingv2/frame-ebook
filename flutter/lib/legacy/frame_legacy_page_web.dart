import 'dart:ui_web' as ui_web;

import 'package:material_ui/material_ui.dart';
import 'package:web/web.dart' as web;

final Map<String, web.HTMLIFrameElement> _legacyFrames =
    <String, web.HTMLIFrameElement>{};
int _nextLegacyFrameId = 0;

Widget buildFrameLegacyPage({
  required Uri uri,
  required String title,
}) =>
    _WebLegacyPage(uri: uri, title: title);

class _WebLegacyPage extends StatefulWidget {
  const _WebLegacyPage({required this.uri, required this.title});

  final Uri uri;
  final String title;

  @override
  State<_WebLegacyPage> createState() => _WebLegacyPageState();
}

class _WebLegacyPageState extends State<_WebLegacyPage> {
  late final String _viewType;
  late final web.HTMLIFrameElement _iframe;

  @override
  void initState() {
    super.initState();
    _viewType = 'frame-ebook-legacy-${_nextLegacyFrameId++}';
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
      ..display = 'block';
    _legacyFrames[_viewType] = _iframe;
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _legacyFrames[_viewType] ?? web.HTMLDivElement(),
    );
  }

  @override
  void didUpdateWidget(covariant _WebLegacyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) {
      _iframe.src = widget.uri.toString();
    }
    if (oldWidget.title != widget.title) {
      _iframe.title = widget.title;
    }
  }

  void _reload() {
    _iframe.src = widget.uri.toString();
  }

  @override
  void dispose() {
    _legacyFrames.remove(_viewType);
    _iframe.src = 'about:blank';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12101A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1825),
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: '重新載入',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: HtmlElementView(viewType: _viewType),
    );
  }
}
