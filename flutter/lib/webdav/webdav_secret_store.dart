import 'webdav_secret_store_stub.dart'
    if (dart.library.io) 'webdav_secret_store_io.dart'
    if (dart.library.js_interop) 'webdav_secret_store_web.dart' as platform;

abstract interface class WebDavSecretStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

WebDavSecretStore createWebDavSecretStore() => platform.createWebDavSecretStore();
