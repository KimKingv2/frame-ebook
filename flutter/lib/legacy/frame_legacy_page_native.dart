import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

Widget buildFrameLegacyPage({
  required Uri uri,
  required String title,
  bool showToolbar = true,
}) =>
    _NativeLegacyPage(uri: uri, title: title, showToolbar: showToolbar);

class _NativeLegacyPage extends StatefulWidget {
  const _NativeLegacyPage({
    required this.uri,
    required this.title,
    required this.showToolbar,
  });

  final Uri uri;
  final String title;
  final bool showToolbar;

  @override
  State<_NativeLegacyPage> createState() => _NativeLegacyPageState();
}

class _NativeLegacyPageState extends State<_NativeLegacyPage> {
  WebViewController? _controller;
  MethodChannel? _androidChannel;
  int _progress = 0;
  String? _error;
  String _status = '正在準備閱讀室……';

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (_isAndroid) return;
    unawaited(_initializeMacWebView());
  }

  Future<void> _initializeMacWebView() async {
    final controller = WebViewController();
    _controller = controller;
    try {
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(const Color(0xFF12101A));
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _progress = 0;
              _error = null;
              _status = '正在載入閱讀室……';
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() {
              _progress = 100;
              _error = null;
              _status = '閱讀室頁面已載入，正在準備書籍內容……';
            });
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false || !mounted) return;
            final failedUri = Uri.tryParse(error.url ?? '');
            final location = failedUri == null || failedUri.host.isEmpty
                ? ''
                : ' · ${failedUri.host}${failedUri.path}';
            setState(() {
              _error =
                  '${error.description}（錯誤碼 ${error.errorCode}$location）';
              _status = '閱讀室載入失敗';
            });
          },
          onNavigationRequest: (request) {
            final target = Uri.tryParse(request.url);
            return target != null && target.scheme == 'https'
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      );
      if (!mounted) return;
      await controller.loadRequest(widget.uri);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '無法開啟閱讀室：$error';
        _status = '閱讀室載入失敗';
      });
    }
  }

  void _onAndroidViewCreated(int viewId) {
    final channel = MethodChannel('frame_ebook/native_reader/$viewId');
    _androidChannel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'progress':
          final value = call.arguments;
          if (value is int) setState(() => _progress = value.clamp(0, 100));
          break;
        case 'status':
          setState(() => _status = call.arguments?.toString() ?? '');
          break;
        case 'error':
          setState(() {
            _error = call.arguments?.toString() ?? '閱讀室載入失敗。';
            _status = '閱讀室載入失敗';
          });
          break;
      }
    });
  }

  Future<void> _reload() async {
    if (_isAndroid) {
      try {
        await _androidChannel?.invokeMethod<void>('reload');
      } catch (error) {
        if (mounted) setState(() => _error = '重新載入失敗：$error');
      }
      return;
    }
    final controller = _controller;
    if (controller == null) {
      await _initializeMacWebView();
      return;
    }
    if (mounted) {
      setState(() {
        _progress = 0;
        _error = null;
        _status = '正在重新載入閱讀室……';
      });
    }
    try {
      await controller.loadRequest(widget.uri);
    } catch (error) {
      if (mounted) setState(() => _error = '重新載入失敗：$error');
    }
  }

  @override
  void dispose() {
    _androidChannel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12101A),
      appBar: widget.showToolbar
          ? AppBar(
              backgroundColor: const Color(0xFF1B1825),
              title: Text(widget.title),
              actions: [
                IconButton(
                  tooltip: '重新載入',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            )
          : null,
      body: Column(
        children: [
          if (widget.showToolbar && _progress < 100)
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress / 100,
              color: const Color(0xFF9875EC),
              backgroundColor: const Color(0xFF262131),
            ),
          if (_error != null)
            Container(
              width: double.infinity,
              color: const Color(0xFF301F2A),
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFFFFB7B7),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          if (widget.showToolbar && _isAndroid && _error == null)
            Container(
              width: double.infinity,
              color: const Color(0xFF171420),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: Text(
                _status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFAAA2B8),
                  fontSize: 10,
                ),
              ),
            ),
          Expanded(
            child: _isAndroid
                ? AndroidView(
                    viewType: 'frame_ebook/native_reader',
                    creationParams: {'url': widget.uri.toString()},
                    creationParamsCodec: const StandardMessageCodec(),
                    onPlatformViewCreated: _onAndroidViewCreated,
                  )
                : (_controller == null
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFFC5ADFF),
                        ),
                      )
                    : WebViewWidget(controller: _controller!)),
          ),
        ],
      ),
    );
  }
}
