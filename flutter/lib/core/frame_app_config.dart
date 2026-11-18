import 'package:flutter/foundation.dart';

class FrameAppConfig {
  FrameAppConfig._();

  static const String _configuredBaseUrl =
      String.fromEnvironment('FRAME_EBOOK_API_BASE_URL');

  static Uri get apiBaseUri {
    if (kIsWeb) {
      final configured = _configuredBaseUrl.trim();
      // Uri.base includes the page's query string and fragment. Those belong
      // to the browser URL (for example a cache-busting ?v=... parameter),
      // not the API origin, so normalize the implicit value to origin first.
      final current = configured.isEmpty
          ? Uri.parse(Uri.base.origin)
          : Uri.tryParse(configured);
      if (current == null ||
          !current.hasAuthority ||
          current.host.isEmpty ||
          (current.scheme != 'https' && current.scheme != 'http') ||
          current.userInfo.isNotEmpty ||
          current.query.isNotEmpty ||
          current.fragment.isNotEmpty) {
        throw const FormatException('FRAME_EBOOK_API_BASE_URL 格式不正確。');
      }
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
