import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frame_ebook/cloud/local_openlist_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores only whether local OpenList is selected', () async {
    final settings = LocalOpenListSettingsStore();

    expect(await settings.loadLocalSelected(), isFalse);

    await settings.saveLocalSelected(true);
    expect(await settings.loadLocalSelected(), isTrue);

    await settings.saveLocalSelected(false);
    expect(await settings.loadLocalSelected(), isFalse);
  });

  test('keeps the local OpenList base URL independent from selection state', () async {
    final settings = LocalOpenListSettingsStore();

    await settings.saveBaseUrl('http://192.168.31.185:5244');
    await settings.saveLocalSelected(true);

    expect(await settings.loadBaseUrl(), 'http://192.168.31.185:5244');

    await settings.saveLocalSelected(false);
    expect(await settings.loadBaseUrl(), 'http://192.168.31.185:5244');
  });
}
