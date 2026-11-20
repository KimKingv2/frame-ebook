import 'package:shared_preferences/shared_preferences.dart';

import 'local_openlist_client.dart';

abstract interface class LocalOpenListSettingsPreferences {
  Future<String?> getString(String key);
  Future<bool?> getBool(String key);
  Future<void> setString(String key, String value);
  Future<void> setBool(String key, bool value);
  Future<void> remove(String key);
}

class _SharedPreferencesAsyncAdapter
    implements LocalOpenListSettingsPreferences {
  _SharedPreferencesAsyncAdapter(this.preferences);

  final SharedPreferencesAsync preferences;

  @override
  Future<String?> getString(String key) => preferences.getString(key);

  @override
  Future<bool?> getBool(String key) => preferences.getBool(key);

  @override
  Future<void> setString(String key, String value) =>
      preferences.setString(key, value);

  @override
  Future<void> setBool(String key, bool value) =>
      preferences.setBool(key, value);

  @override
  Future<void> remove(String key) => preferences.remove(key);
}

class LocalOpenListSettingsStore {
  LocalOpenListSettingsStore({
    LocalOpenListSettingsPreferences? preferences,
  }) : _preferences = preferences ??
            _SharedPreferencesAsyncAdapter(SharedPreferencesAsync());

  static const _baseUrlKey = 'frame-reader-local-openlist-base-url';
  static const _localSelectedKey = 'frame-reader-local-openlist-selected';
  final LocalOpenListSettingsPreferences _preferences;

  Future<bool> loadLocalSelected() async =>
      await _preferences.getBool(_localSelectedKey) ?? false;

  Future<void> saveLocalSelected(bool selected) async {
    if (selected) {
      await _preferences.setBool(_localSelectedKey, true);
    } else {
      await _preferences.remove(_localSelectedKey);
    }
  }

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
