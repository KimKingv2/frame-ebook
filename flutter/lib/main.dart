import 'package:flutter/widgets.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';
import 'package:material_ui/material_ui.dart';

import 'auth/frame_auth_gate.dart';
import 'library/frame_bookshelf_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FullScreen.ensureInitialized();
  runApp(const FrameEbookApp());
}

class FrameEbookApp extends StatelessWidget {
  const FrameEbookApp({super.key});

  @override
  Widget build(BuildContext context) {
    const violet = Color(0xFFC5ADFF);
    return MaterialApp(
      title: 'FRAME Reader · My Library',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'NotoSansTC',
        // The bundled Noto subset keeps the Web payload manageable. Use
        // installed Traditional Chinese fonts for glyphs outside that subset.
        fontFamilyFallback: const [
          // Both fallback families are bundled. Flutter Web's CanvasKit
          // renderer cannot rely on arbitrary host OS fonts for missing CJK glyphs.
          'NotoSansSCFallback',
          'PingFang TC',
          'Heiti TC',
          'Microsoft JhengHei',
          'Noto Sans CJK TC',
          'sans-serif',
        ],
        colorScheme: ColorScheme.fromSeed(
          seedColor: violet,
          brightness: Brightness.dark,
          surface: const Color(0xFF1B1825),
        ),
        scaffoldBackgroundColor: const Color(0xFF12101A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF12101A),
          foregroundColor: Color(0xFFF4F0FA),
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF211D2D),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0x33393A47)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0x55393247)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: violet, width: 1.3),
          ),
        ),
      ),
      home: const FrameAuthGate(child: FrameBookshelfScreen()),
    );
  }
}
