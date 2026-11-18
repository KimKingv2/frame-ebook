import 'package:shared_preferences/shared_preferences.dart';

import 'local_openlist_client.dart';

class LocalOpenListSettingsStore {
  LocalOpenListSettingsStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _baseUrlKey = 'frame-reader-local-openlist-base-url';
  final SharedPreferencesAsync _preferences;

  Future<String?> loadBaseUrl() async {
    final saved = await _preferences.getString(_baseUrlKey);
    if (saved == null || saved.trim().isEmpty) return null;
    try {
      return LocalOpenListClient.normalizeLocalOpenListUrl(saved);
    } on FormatException {
      return null;
    }
  }

  Future<void> saveBaseUrl(String value) async {
    final normalized = LocalOpenListClient.normalizeLocalOpenListUrl(value);
    await _preferences.setString(_baseUrlKey, normalized);
  }

  Future<void> clearBaseUrl() => _preferences.remove(_baseUrlKey);
}
