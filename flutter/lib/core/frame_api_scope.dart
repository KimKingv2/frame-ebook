import 'package:material_ui/material_ui.dart';

import 'frame_api_client.dart';

class FrameApiScope extends InheritedWidget {
  const FrameApiScope({
    required this.api,
    required super.child,
    super.key,
  });

  final FrameApiClient api;

  static FrameApiClient of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<FrameApiScope>();
    if (scope == null) throw StateError('FrameApiScope 尚未建立。');
    return scope.api;
  }

  @override
  bool updateShouldNotify(FrameApiScope oldWidget) =>
      !identical(api, oldWidget.api);
}
