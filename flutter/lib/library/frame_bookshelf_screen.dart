import 'package:material_ui/material_ui.dart';

import '../core/frame_app_config.dart';
import '../legacy/frame_legacy_page.dart';

/// The Flutter shell uses the exact same-origin Reader homepage as the web
/// application. This keeps cover rendering, folder stacks, responsive sizing,
/// sorting and home interactions on one shared implementation.
class FrameBookshelfScreen extends StatelessWidget {
  const FrameBookshelfScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uri = FrameAppConfig.apiBaseUri.replace(path: '/');
    return buildFrameLegacyPage(
      uri: uri,
      title: 'FRAME Reader',
      showToolbar: false,
    );
  }
}
