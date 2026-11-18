import 'package:material_ui/material_ui.dart';

import 'frame_reader_engine_handle.dart';
import 'frame_reader_engine_stub.dart'
    if (dart.library.js_interop) 'frame_reader_engine_web.dart' as platform;

export 'frame_reader_engine_handle.dart';

Widget buildFrameReaderEngine({
  required Uri uri,
  required String title,
  required FrameReaderEngineHandle handle,
}) =>
    platform.buildFrameReaderEngine(
      uri: uri,
      title: title,
      handle: handle,
    );
