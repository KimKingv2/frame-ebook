import 'package:material_ui/material_ui.dart';

import '../core/frame_app_config.dart';
import '../legacy/frame_legacy_page.dart';

/// Uses the original full Cloud Manager while its scanner is being ported to
/// Dart. This keeps the complete provider, local OpenList, resumable scan,
/// cover retry and log workflows available within the Flutter app on every
/// target without creating a second implementation of the scan contract.
class FrameCloudManagerScreen extends StatelessWidget {
  const FrameCloudManagerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uri = FrameAppConfig.apiBaseUri.replace(
      path: '/cloud/',
      queryParameters: const {'manager': '1'},
    );
    return buildFrameLegacyPage(
      uri: uri,
      title: '連接與掃描',
    );
  }
}
