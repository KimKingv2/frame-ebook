import 'package:material_ui/material_ui.dart';

import 'frame_legacy_page_stub.dart'
    if (dart.library.io) 'frame_legacy_page_native.dart'
    if (dart.library.js_interop) 'frame_legacy_page_web.dart' as platform;

Widget buildFrameLegacyPage({
  required Uri uri,
  required String title,
  bool showToolbar = true,
}) =>
    platform.buildFrameLegacyPage(uri: uri, title: title, showToolbar: showToolbar);
