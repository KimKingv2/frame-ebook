import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'transport/frame_transport.dart';
import 'transport/transport_factory.dart';
import 'transport/transport_result.dart';

void main() => runApp(const FrameEbookTransportLab());

class FrameEbookTransportLab extends StatelessWidget {
  const FrameEbookTransportLab({super.key});

  @override
  Widget build(BuildContext context) {
    const violet = Color(0xFF9B7BFF);
    return MaterialApp(
      title: 'FRAME Ebook · Transport Lab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: violet,
          brightness: Brightness.dark,
          surface: const Color(0xFF1B1825),
        ),
        scaffoldBackgroundColor: const Color(0xFF111019),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF211D2D),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF393247)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: violet, width: 1.4),
          ),
        ),
      ),
      home: const TransportLabScreen(),
    );
  }
}

class TransportLabScreen extends StatefulWidget {
  const TransportLabScreen({super.key});

  @override
  State<TransportLabScreen> createState() => _TransportLabScreenState();
}

class _TransportLabScreenState extends State<TransportLabScreen> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final FrameTransport _transport;
  TransportResult? _result;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _transport = createFrameTransport();
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _transport.close();
    super.dispose();
  }

  Future<void> _runProbe() async {
    FocusScope.of(context).unfocus();
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty) {
      setState(() {
        _error = '請輸入有效的 HTTP／HTTPS 檔案網址，網址內不可嵌入帳號密碼。';
        _result = null;
      });
      return;
    }

    if ((_username.text.isEmpty && _password.text.isNotEmpty) ||
        (_username.text.isNotEmpty && _password.text.isEmpty)) {
      setState(() {
        _error = 'Basic Auth 請同時填寫帳號與密碼，或兩欄都留空。';
        _result = null;
      });
      return;
    }

    final headers = <String, String>{};
    if (_username.text.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('${_username.text}:${_password.text}'))}';
    }

    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });

    try {
      final result = await _transport
          .probeRange(
            uri: uri,
            headers: headers,
            start: 0,
            end: 1023,
            maxBodyBytes: 4096,
            timeout: const Duration(seconds: 25),
          )
          .timeout(const Duration(seconds: 35));
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.toLowerCase().contains('failed to fetch')) {
      return '瀏覽器無法完成讀取。常見原因是 302 最終網域未開放 CORS、'
          'Authorization 預檢未通過，或本機網路存取遭瀏覽器阻擋。';
    }
    return message;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FRAME  EBOOK'),
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Center(
              child: Text(
                '302 / RANGE LAB',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: const Color(0xFFB7A6E8),
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: width > 760 ? 700 : width,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            children: [
              const Text(
                '直連測試',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                '確認檔案來源能否完成 302 跳轉，並在最終位址回傳 HTTP 206 Range。',
                style: TextStyle(color: Color(0xFFB6B0C4), height: 1.55),
              ),
              const SizedBox(height: 24),
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _FieldLabel('檔案 URL'),
                    TextField(
                      controller: _url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        hintText: 'https://example.com/path/book.epub',
                      ),
                    ),
                    const SizedBox(height: 16),
                    const _FieldLabel('Basic Auth 帳號（選填）'),
                    TextField(
                      controller: _username,
                      autocorrect: false,
                      decoration: const InputDecoration(hintText: 'WebDAV 帳號'),
                    ),
                    const SizedBox(height: 16),
                    const _FieldLabel('Basic Auth 密碼（選填）'),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(hintText: '僅在本次測試記憶體中使用'),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _busy ? null : _runProbe,
                      icon: _busy
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.network_check_rounded),
                      label: Text(_busy ? '正在測試……' : '執行 1 KB Range 測試'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: const Color(0xFF8061D9),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '只請求 bytes=0-1023，最多讀取 4 KB 回應資料；不下載完整書檔、不建立暫存檔、不保存帳密。',
                      style: TextStyle(
                        color: Color(0xFF9992A8),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                _Panel(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline, color: Color(0xFFFF9B9B)),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_error!, style: const TextStyle(height: 1.5))),
                    ],
                  ),
                ),
              ],
              if (_result != null) ...[
                const SizedBox(height: 16),
                _ResultPanel(result: _result!),
              ],
              const SizedBox(height: 24),
              Text(
                '測試判讀',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 10),
              const _LegendRow(
                icon: Icons.check_circle_outline,
                color: Color(0xFF82D6AE),
                title: 'HTTP 206',
                detail: '伺服器接受 Range，仍需確認 Content-Range 範圍正確。',
              ),
              const _LegendRow(
                icon: Icons.warning_amber_rounded,
                color: Color(0xFFFFC66D),
                title: 'HTTP 200',
                detail: '伺服器可能忽略 Range，不能視為成功的分段讀取。',
              ),
              const _LegendRow(
                icon: Icons.info_outline,
                color: Color(0xFFB9A5F6),
                title: 'Web 與原生差異',
                detail: 'Web 由瀏覽器跟隨 302，最終網域必須允許 CORS；'
                    'macOS／Android 由原生 HTTP 層逐跳處理。',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1825),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF383146)),
      ),
      child: child,
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFD4CDE1),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.result});

  final TransportResult result;

  @override
  Widget build(BuildContext context) {
    final partial = result.statusCode == 206;
    final tint = partial ? const Color(0xFF82D6AE) : const Color(0xFFFFC66D);
    final finalUri = result.finalUri?.toString() ??
        (result.browserManagedRedirect ? '由瀏覽器管理，無法讀取最終 URL' : '未知');

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                partial ? Icons.check_circle : Icons.warning_amber_rounded,
                color: tint,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  partial ? '收到 HTTP 206' : 'HTTP ${result.statusCode}',
                  style: TextStyle(
                    color: tint,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${result.duration.inMilliseconds} ms',
                style: const TextStyle(color: Color(0xFFAAA2B9)),
              ),
            ],
          ),
          const Divider(height: 26, color: Color(0xFF393247)),
          _ResultRow('302 次數', result.redirectCount?.toString() ?? '瀏覽器管理'),
          _ResultRow('最終位址', finalUri),
          _ResultRow('Content-Range', result.contentRange ?? '未讀取到'),
          _ResultRow('Accept-Ranges', result.acceptRanges ?? '未提供'),
          _ResultRow('Content-Length', result.contentLength ?? '未提供'),
          _ResultRow('已讀入記憶體', '${result.bytesRead} bytes'),
          _ResultRow('回應是否截斷', result.bodyTruncated ? '是' : '否'),
          if (result.browserManagedRedirect &&
              result.contentRange == null &&
              partial) ...[
            const SizedBox(height: 10),
            const Text(
              '瀏覽器沒有暴露 Content-Range。可在來源 CORS 設定中加入 '
              'Access-Control-Expose-Headers: Content-Range, Accept-Ranges。',
              style: TextStyle(
                color: Color(0xFFFFC66D),
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFFAAA2B9), fontSize: 12),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Color(0xFFAAA2B9),
                    fontSize: 12,
                    height: 1.45,
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
