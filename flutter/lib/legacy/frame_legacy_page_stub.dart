import 'package:material_ui/material_ui.dart';

Widget buildFrameLegacyPage({
  required Uri uri,
  required String title,
}) =>
    Scaffold(
      body: Center(child: Text('目前平台無法開啟$title')),
    );
