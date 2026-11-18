import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

Widget buildFrameLegacyPage({
  required Uri uri,
  required String title,
}) =>
    _WebLegacyPage(uri: uri, title: title);

class _WebLegacyPage extends StatelessWidget {
  const _WebLegacyPage({required this.uri, required this.title});

  final Uri uri;
  final String title;

  Future<void> _open(BuildContext context) async {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('無法開啟原版 FRAME Reader 頁面。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12101A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1825),
        title: Text(title),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.open_in_new_rounded,
                  color: Color(0xFFC5ADFF),
                  size: 38,
                ),
                const SizedBox(height: 18),
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFF4F0FA),
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '此功能正在移植。為保留 main 版完整操作與資料相容，目前先開啟同網域原版頁面；書架與 Flutter 導覽仍留在這個分頁。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFAAA2B8),
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () => _open(context),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('在新分頁開啟'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
