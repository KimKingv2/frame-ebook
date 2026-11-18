import 'package:flutter/foundation.dart';

class FrameAppConfig {
  FrameAppConfig._();

  static const String _configuredBaseUrl =
      String.fromEnvironment('FRAME_EBOOK_API_BASE_URL');

  static Uri get apiBaseUri {
    if (kIsWeb) {
      final current = Uri.base;
      return Uri(
        scheme: current.scheme,
        host: current.host,
        port: current.hasPort ? current.port : null,
        path: '/',
      );
    }

    final value = _configuredBaseUrl.trim().isEmpty
        ? 'https://frame-ebook.pages.dev/'
        : _configuredBaseUrl.trim();
    final parsed = Uri.tryParse(value);
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.host.isEmpty ||
        (parsed.scheme != 'https' && parsed.scheme != 'http') ||
        parsed.userInfo.isNotEmpty ||
        parsed.query.isNotEmpty ||
        parsed.fragment.isNotEmpty) {
      throw const FormatException(
        'FRAME_EBOOK_API_BASE_URL 必須是沒有帳密、查詢參數或片段的 HTTP／HTTPS 網址。',
      );
    }
    return Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: '/',
    );
  }
}
