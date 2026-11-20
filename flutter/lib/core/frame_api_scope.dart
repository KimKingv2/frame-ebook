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

  /// Copies the nearest API scope into a route created by the Navigator.
  ///
  /// Navigator routes are inserted above the current route subtree, so an
  /// InheritedWidget that only wraps the current route is not inherited by a
  /// newly pushed route unless it is explicitly re-provided.
  static Widget inherit({
    required BuildContext context,
    required Widget child,
  }) {
    final scope = context.dependOnInheritedWidgetOfExactType<FrameApiScope>();
    if (scope == null) {
      throw StateError('FrameApiScope 尚未建立，無法開啟需要雲端 API 的頁面。');
    }
    return FrameApiScope(
      api: scope.api,
      localOpenListSession: scope.localOpenListSession,
      child: child,
    );
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
