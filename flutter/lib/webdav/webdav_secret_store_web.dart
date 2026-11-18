import 'webdav_secret_store.dart';

final Map<String, String> _sessionSecrets = <String, String>{};

WebDavSecretStore createWebDavSecretStore() => _WebSessionSecretStore();

class _WebSessionSecretStore implements WebDavSecretStore {
  @override
  Future<void> write(String key, String value) async {
    _sessionSecrets[key] = value;
  }

  @override
  Future<String?> read(String key) async => _sessionSecrets[key];

  @override
  Future<void> delete(String key) async {
    _sessionSecrets.remove(key);
  }
}
