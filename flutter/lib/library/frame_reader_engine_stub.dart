import 'package:material_ui/material_ui.dart';

import '../legacy/frame_legacy_page.dart';
import 'frame_reader_engine_handle.dart';

Widget buildFrameReaderEngine({
  required Uri uri,
  required String title,
  required FrameReaderEngineHandle handle,
}) =>
    buildFrameLegacyPage(
      uri: uri,
      title: title,
      showToolbar: false,
    );
