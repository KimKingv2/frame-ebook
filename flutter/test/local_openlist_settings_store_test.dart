import 'package:flutter_test/flutter_test.dart';

import 'package:frame_ebook/cloud/local_openlist_settings_store.dart';

class _MemoryPreferences implements LocalOpenListSettingsPreferences {
  final Map<String, Object> values = {};

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

void main() {
  test('stores only whether local OpenList is selected', () async {
    final settings = LocalOpenListSettingsStore(
      preferences: _MemoryPreferences(),
    );

    expect(await settings.loadLocalSelected(), isFalse);

    await settings.saveLocalSelected(true);
    expect(await settings.loadLocalSelected(), isTrue);

    await settings.saveLocalSelected(false);
    expect(await settings.loadLocalSelected(), isFalse);
  });

  test('keeps the local OpenList base URL independent from selection state', () async {
    final settings = LocalOpenListSettingsStore(
      preferences: _MemoryPreferences(),
    );

    await settings.saveBaseUrl('http://192.168.31.185:5244');
    await settings.saveLocalSelected(true);

    expect(await settings.loadBaseUrl(), 'http://192.168.31.185:5244');

    await settings.saveLocalSelected(false);
    expect(await settings.loadBaseUrl(), 'http://192.168.31.185:5244');
  });
}
