import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/frame_api_client.dart';
import '../core/frame_api_factory.dart';
import '../core/frame_app_config.dart';

class FrameAuthGate extends StatefulWidget {
  const FrameAuthGate({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  State<FrameAuthGate> createState() => _FrameAuthGateState();
}

class _FrameAuthGateState extends State<FrameAuthGate> {
  late final Uri _baseUri;
  late final FrameApiClient _api;
  bool _checking = true;
  bool _authenticated = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _baseUri = FrameAppConfig.apiBaseUri;
    _api = createFrameApiClient(baseUri: _baseUri);
    unawaited(_checkSession());
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<bool> _checkSession() async {
    if (mounted) {
      setState(() {
        _checking = true;
        _error = null;
      });
    }
    try {
      final session = await _api.getJson('/api/auth/session');
      if (session['authenticated'] != true ||
          session['accessEnabled'] != true) {
        throw const FrameApiException(
          message: 'Cloudflare Access 尚未確認登入狀態。',
        );
      }
      if (mounted) {
        setState(() {
          _authenticated = true;
          _checking = false;
          _error = null;
        });
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          _authenticated = false;
          _checking = false;
          _error = error.toString();
        });
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) return const _AuthLoadingScreen();
    if (_authenticated) return widget.child;

    if (kIsWeb) {
      return _AccessWebNotice(
        error: _error,
        onRetry: _checkSession,
      );
    }
    return _NativeAccessLoginScreen(
      baseUri: _baseUri,
      onRetry: _checkSession,
    );
  }
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF12101A),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFC5ADFF)),
            SizedBox(height: 18),
            Text(
              '正在確認 Cloudflare Access 登入狀態……',
              style: TextStyle(color: Color(0xFFAAA2B8)),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccessWebNotice extends StatelessWidget {
  const _AccessWebNotice({
    required this.error,
    required this.onRetry,
  });

  final String? error;
  final Future<bool> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12101A),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _FrameWordmark(),
                const SizedBox(height: 30),
                const Text(
                  '需要 Cloudflare Access 登入',
                  style: TextStyle(
                    color: Color(0xFFF4F0FA),
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  error ?? '請先完成目前網域的 Access 驗證。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFAAA2B8),
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: () => onRetry(),
                  child: const Text('重新確認'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NativeAccessLoginScreen extends StatefulWidget {
  const _NativeAccessLoginScreen({
    required this.baseUri,
    required this.onRetry,
  });

  final Uri baseUri;
  final Future<bool> Function() onRetry;

  @override
  State<_NativeAccessLoginScreen> createState() =>
      _NativeAccessLoginScreenState();
}

class _NativeAccessLoginScreenState extends State<_NativeAccessLoginScreen> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _checking = false;
  String? _webError;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF12101A))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageFinished: _onPageFinished,
          onWebResourceError: (error) {
            if (!error.isForMainFrame || !mounted) return;
            setState(() => _webError = error.description);
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null ||
                (uri.scheme != 'https' && uri.scheme != 'http')) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
    unawaited(_loadAccessPage());
  }

  Future<void> _loadAccessPage() async {
    try {
      await _controller.loadRequest(widget.baseUri);
    } catch (error) {
      if (mounted) setState(() => _webError = error.toString());
    }
  }

  void _onPageFinished(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host != widget.baseUri.host) return;
    if (uri.path.startsWith('/cdn-cgi/access/')) return;
    unawaited(_tryComplete());
  }

  Future<void> _tryComplete() async {
    if (_checking || !mounted) return;
    setState(() {
      _checking = true;
      _webError = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final success = await widget.onRetry();
    if (!mounted) return;
    setState(() {
      _checking = false;
      if (!success) {
        _webError =
            '尚未取得有效的 Access 工作階段。請在上方頁面完成登入，然後再按一次確認。';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12101A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1825),
        title: const _FrameWordmark(),
        actions: [
          TextButton.icon(
            onPressed: _checking ? null : _tryComplete,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('確認登入'),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 14, 18, 12),
            child: Text(
              '請在下方頁面完成 Cloudflare Access 驗證。登入成功後，FRAME Ebook 會使用同一個 Access 工作階段連接現有書庫與閱讀資料。',
              style: TextStyle(
                color: Color(0xFFAAA2B8),
                fontSize: 12,
                height: 1.55,
              ),
            ),
          ),
          if (_progress < 100 && _progress > 0)
            LinearProgressIndicator(
              value: _progress / 100,
              color: const Color(0xFF9875EC),
              backgroundColor: const Color(0xFF262131),
            ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: const Color(0xFF1B1825),
                border: Border.all(color: const Color(0xFF393247)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: WebViewWidget(controller: _controller),
            ),
          ),
          if (_webError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Text(
                _webError!,
                style: const TextStyle(
                  color: Color(0xFFFFA5A5),
                  fontSize: 11,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _controller.reload(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新載入登入頁'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _checking ? null : _tryComplete,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(_checking ? '確認中……' : '我已完成登入'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FrameWordmark extends StatelessWidget {
  const _FrameWordmark();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFA485EF), Color(0xFF61469F)],
            ),
            borderRadius: BorderRadius.all(Radius.circular(9)),
          ),
          child: SizedBox(
            width: 34,
            height: 34,
            child: Center(
              child: Text(
                'F',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'Georgia',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: 11),
        Text(
          'FRAME READER',
          style: TextStyle(
            color: Color(0xFFC5ADFF),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.0,
          ),
        ),
      ],
    );
  }
}
