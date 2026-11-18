import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'webdav_models.dart';
import 'webdav_secret_store.dart';

class WebDavRepository {
  WebDavRepository({
    SharedPreferencesAsync? preferences,
    WebDavSecretStore? secrets,
  })  : _preferences = preferences ?? SharedPreferencesAsync(),
        _secrets = secrets ?? createWebDavSecretStore();

  static const _profileKey = 'frame-ebook.webdav-profile.v1';
  static const _passwordKey = 'frame-ebook.webdav-password.primary';

  final SharedPreferencesAsync _preferences;
  final WebDavSecretStore _secrets;

  Future<WebDavProfile?> loadProfile() async {
    final raw = await _preferences.getString(_profileKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return WebDavProfile.decode(raw);
    } on FormatException {
      throw const FormatException('已保存的 WebDAV 設定無法解析，請重新設定來源。');
    }
  }

  Future<String?> loadPassword() => _secrets.read(_passwordKey);

  Future<void> saveProfile({
    required WebDavProfile profile,
    required String password,
  }) async {
    final cleanPassword = password;
    if (cleanPassword.isEmpty) {
      throw ArgumentError('WebDAV 密碼不可為空。');
    }
    await _secrets.write(_passwordKey, cleanPassword);
    await _preferences.setString(_profileKey, profile.encode());
  }

  Future<void> deleteProfile() async {
    await _preferences.remove(_profileKey);
    await _secrets.delete(_passwordKey);
  }

  Future<bool> hasSavedProfile() async =>
      (await _preferences.getString(_profileKey))?.isNotEmpty ?? false;

  Future<String> exportNonSecretProfile() async {
    final profile = await loadProfile();
    if (profile == null) return '{}';
    return jsonEncode(profile.toJson());
  }
}
