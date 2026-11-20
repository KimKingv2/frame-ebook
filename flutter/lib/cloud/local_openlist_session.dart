import 'local_openlist_client.dart';

/// Holds the authenticated local OpenList client only for the lifetime of the
/// running app. The access token is never serialized or written to preferences.
class FrameLocalOpenListSession {
  LocalOpenListClient? _client;

  LocalOpenListClient? get client => _client;

  bool get isAuthenticated => _client?.isAuthenticated ?? false;

  void replaceClient(LocalOpenListClient client) {
    if (identical(_client, client)) return;
    _client?.close();
    _client = client;
  }

  void logout() {
    _client?.logout();
  }

  void dispose() {
    _client?.close();
    _client = null;
  }
}
