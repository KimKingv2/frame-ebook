import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/frame_api_client.dart';
import '../core/frame_api_factory.dart';
import '../core/frame_api_scope.dart';
import '../core/frame_app_config.dart';
import '../core/frame_webview_api_client.dart';

class FrameAuthGate extends StatefulWidget {
  const FrameAuthGate({required this.child, super.key});
  final Widget child;

  @override
  State<FrameAuthGate> createState() => _FrameAuthGateState();
}

class _FrameAuthGateState extends State<FrameAuthGate> {
  late final Uri _baseUri;
  late final FrameApiClient _api;
  WebViewController? _webController;

  bool _checking = true;
  bool _sessionCheckInProgress = false;
  bool _authenticated = false;
  bool _pageReady = false;
  bool _nativeProbeStarted = false;
  int _progress = 0;
  String? _error;
  String? _webError;

  @override
  void initState() {
    super.initState();
    _baseUri = FrameAppConfig.apiBaseUri;
    if (kIsWeb) {
      _api = createFrameApiClient(baseUri: _baseUri);
      unawaited(_checkSession());
      return;
    }

    final controller = WebViewController();
    _webController = controller;
    _api = FrameWebViewApiClient(baseUri: _baseUri, controller: controller);
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF12101A))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _progress = 0;
                _webError = null;
              });
            }
          },
          onPageFinished: _onPageFinished,
          onWebResourceError: (error) {
            if (error.isForMainFrame != true || !mounted) return;
            setState(() {
              _webError = '${error.description}（錯誤碼 ${error.errorCode}）';
              _pageReady = true;
              _checking = false;
            });
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri != null && uri.scheme == 'https'
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadNativeEntry());
    });
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _loadNativeEntry() async {
    try {
      await _webController?.loadRequest(_baseUri);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _pageReady = true;
        _webError = '無法載入 FRAME Ebook：$error';
      });
    }
  }

  void _onPageFinished(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return;
    if (mounted) {
      setState(() {
        _progress = 100;
        _pageReady = true;
        _checking = false;
      });
    }
    if (uri.origin != _baseUri.origin ||
        uri.path.startsWith('/cdn-cgi/access/')) {
      return;
    }
    // Probe only after the protected site returns from Access. Do not probe
    // on every pageFinished event while Cloudflare is still navigating.
    if (!_nativeProbeStarted && mounted) {
      _nativeProbeStarted = true;
      unawaited(_checkSession());
    }
  }

  Future<bool> _checkSession() async {
    if (_sessionCheckInProgress) return false;
    _sessionCheckInProgress = true;
    if (mounted) {
      setState(() {
        _checking = true;
        _error = null;
      });
    }
    try {
      if (!kIsWeb) {
        final url = await _webController?.currentUrl();
        final uri = url == null ? null : Uri.tryParse(url);
        if (uri == null ||
            uri.origin != _baseUri.origin ||
            uri.path.startsWith('/cdn-cgi/access/')) {
          throw const FrameApiException(
            message: '請先在上方頁面完成 Cloudflare Access 驗證，等頁面返回 FRAME Ebook 後再確認。',
          );
        }
      }
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
          _webError = null;
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
    } finally {
      _sessionCheckInProgress = false;
    }
  }

  Future<void> _retryLogin() async {
    final controller = _webController;
    if (controller == null || _checking || _sessionCheckInProgress) return;
    setState(() {
      _nativeProbeStarted = false;
      _error = null;
      _webError = null;
      _pageReady = false;
      _progress = 0;
    });
    try {
      // Start a fresh GET instead of reloading a possible Access POST response.
      await controller.loadRequest(_baseUri);
    } catch (error) {
      if (mounted) {
        setState(() {
          _pageReady = true;
          _webError = '重新載入登入頁失敗：$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      if (_checking) return const _AuthLoadingScreen();
      if (_authenticated) return FrameApiScope(api: _api, child: widget.child);
      return _AccessWebNotice(error: _error, onRetry: _checkSession);
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Offstage(
            offstage: _authenticated,
            child: SizedBox.expand(
              child: WebViewWidget(controller: _webController!),
            ),
          ),
        ),
        if (_authenticated)
          Positioned.fill(
            child: FrameApiScope(api: _api, child: widget.child),
          )
        else
          Positioned.fill(
            child: _NativeAccessOverlay(
              progress: _progress,
              checking: _checking,
              pageReady: _pageReady,
              error: _error,
              webError: _webError,
              onRetryLogin: _retryLogin,
              onConfirm: _checkSession,
            ),
          ),
      ],
    );
  }
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
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

class _AccessWebNotice extends StatelessWidget {
  const _AccessWebNotice({required this.error, required this.onRetry});
  final String? error;
  final Future<bool> Function() onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
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

class _NativeAccessOverlay extends StatelessWidget {
  const _NativeAccessOverlay({
    required this.progress,
    required this.checking,
    required this.pageReady,
    required this.error,
    required this.webError,
    required this.onRetryLogin,
    required this.onConfirm,
  });

  final int progress;
  final bool checking;
  final bool pageReady;
  final String? error;
  final String? webError;
  final Future<void> Function() onRetryLogin;
  final Future<bool> Function() onConfirm;

  @override
  Widget build(BuildContext context) {
    final message = webError ?? error;
    return SafeArea(
      child: Column(
        children: [
          Container(
            height: 58,
            color: const Color(0xFF1B1825),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: const Row(
              children: [
                _FrameWordmark(),
                Spacer(),
                Text(
                  '安全登入',
                  style: TextStyle(color: Color(0xFFAAA2B8), fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: const Color(0xFF12101A),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            child: const Text(
              '請在下方頁面完成 Cloudflare Access 驗證。登入完成並返回 FRAME Ebook 後，App 會直接使用同一個 WebView 工作階段連接書庫。',
              style: TextStyle(
                color: Color(0xFFAAA2B8),
                fontSize: 12,
                height: 1.55,
              ),
            ),
          ),
          if (progress < 100)
            LinearProgressIndicator(
              value: progress == 0 ? null : progress / 100,
              color: const Color(0xFF9875EC),
              backgroundColor: const Color(0xFF262131),
            ),
          const Expanded(child: SizedBox.expand()),
          if (checking || !pageReady)
            Container(
              width: double.infinity,
              color: const Color(0xEE1B1825),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              child: Row(
                children: [
                  const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    checking
                        ? '正在確認 Cloudflare Access 工作階段…'
                        : '正在載入登入頁…',
                    style: const TextStyle(
                      color: Color(0xFFAAA2B8),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          if (message != null)
            Container(
              width: double.infinity,
              color: const Color(0xEE301F2A),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Text(
                message,
                style: const TextStyle(
                  color: Color(0xFFFFB7B7),
                  fontSize: 11,
                  height: 1.45,
                ),
              ),
            ),
          Container(
            color: const Color(0xFF1B1825),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: checking ? null : onRetryLogin,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新載入登入頁'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: checking ? null : onConfirm,
                    icon: checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(checking ? '確認中…' : '我已完成登入'),
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
  Widget build(BuildContext context) => const Row(
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
              letterSpacing: 2,
            ),
          ),
        ],
      );
}
