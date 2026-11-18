import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'webdav_secret_store.dart';

WebDavSecretStore createWebDavSecretStore() => _NativeWebDavSecretStore();

class _NativeWebDavSecretStore implements WebDavSecretStore {
  // Use the legacy macOS Keychain so signed self-use builds do not require
  // Keychain Sharing entitlements or a provisioning profile.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
