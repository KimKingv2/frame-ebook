import 'package:material_ui/material_ui.dart';

import '../cloud/local_openlist_session.dart';
import 'frame_api_client.dart';

class FrameApiScope extends InheritedWidget {
  const FrameApiScope({
    required this.api,
    this.localOpenListSession,
    required super.child,
    super.key,
  });

  final FrameApiClient api;
  final FrameLocalOpenListSession? localOpenListSession;

  static FrameApiClient of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<FrameApiScope>();
    if (scope == null) throw StateError('FrameApiScope 尚未建立。');
    return scope.api;
  }

  static FrameLocalOpenListSession? localSessionOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<FrameApiScope>();
    return scope?.localOpenListSession;
  }

  @override
  bool updateShouldNotify(FrameApiScope oldWidget) =>
      !identical(api, oldWidget.api) ||
      !identical(localOpenListSession, oldWidget.localOpenListSession);
}
