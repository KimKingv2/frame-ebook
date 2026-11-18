import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

Widget buildFrameLegacyPage({
  required Uri uri,
  required String title,
}) =>
    _NativeLegacyPage(uri: uri, title: title);

class _NativeLegacyPage extends StatefulWidget {
  const _NativeLegacyPage({required this.uri, required this.title});

  final Uri uri;
  final String title;

  @override
  State<_NativeLegacyPage> createState() => _NativeLegacyPageState();
}

class _NativeLegacyPageState extends State<_NativeLegacyPage> {
  late final WebViewController _controller;
  int _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF12101A))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame && mounted) {
              setState(() => _error = error.description);
            }
          },
        ),
      );
    unawaited(_controller.loadRequest(widget.uri));
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
            onPressed: () => _controller.reload(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress < 100)
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress / 100,
              color: const Color(0xFF9875EC),
              backgroundColor: const Color(0xFF262131),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFFFA5A5)),
              ),
            ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
