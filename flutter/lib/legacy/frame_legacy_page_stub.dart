import 'package:material_ui/material_ui.dart';

Widget buildFrameLegacyPage({
  required Uri uri,
  required String title,
  bool showToolbar = true,
}) =>
    Scaffold(
      appBar: showToolbar ? AppBar(title: Text(title)) : null,
      body: Center(child: Text('目前平台無法開啟$title')),
    );
