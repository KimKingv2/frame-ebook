import 'package:material_ui/material_ui.dart';

import 'frame_reader_engine_stub.dart'
    if (dart.library.js_interop) 'frame_reader_engine_web.dart' as platform;

class FrameReaderEngineHandle {
  void Function(String command)? _sender;

  void attach(void Function(String command)? sender) => _sender = sender;

  void send(String command) => _sender?.call(command);
}

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
