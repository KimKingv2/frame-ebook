/// Maps the shared Legacy Reading Room appearance fields to Flutter
/// rendering preferences. Legacy fields always win; preview-only duplicates
/// are fallback values for settings saved by earlier preview builds.
class FrameEpubAppearancePreferences {
  const FrameEpubAppearancePreferences._();

  static const List<double> lineHeightOptions = <double>[
    1.45,
    1.65,
    1.85,
    2.0,
  ];

  static double lineHeight(Map<String, dynamic> appearance) {
    final raw = appearance['lineHeight'] ??
        appearance['frameFlutterLineHeight'];
    final parsed = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '');
    if (parsed == null || !parsed.isFinite) return 1.65;

    return lineHeightOptions.reduce(
      (closest, candidate) =>
          (candidate - parsed).abs() < (closest - parsed).abs()
              ? candidate
              : closest,
    );
  }

  static String theme(Map<String, dynamic> appearance) {
    final legacy = appearance['theme']?.toString();
    switch (legacy) {
      case 'paper':
      case 'light':
        return 'light';
      case 'sepia':
        return 'sepia';
      case 'night':
      case 'dark':
        return 'dark';
    }

    final preview = appearance['frameFlutterTheme']?.toString();
    return const {'light', 'sepia', 'dark'}.contains(preview)
        ? preview!
        : 'light';
  }

  static String readingMode(Map<String, dynamic> appearance) {
    final legacy = appearance['readingMode']?.toString();
    if (legacy == 'paginated' || legacy == 'scrolled') return legacy!;

    return appearance['frameFlutterLayoutMode'] == 'continuous'
        ? 'scrolled'
        : 'paginated';
  }

  static String pageLayout(Map<String, dynamic> appearance) {
    final legacy = appearance['pageLayout']?.toString();
    if (legacy == '1' || legacy == '2') return legacy!;

    return switch (appearance['frameFlutterLayoutMode']) {
      'paginated' => '1',
      'doublePage' => '2',
      _ => '2',
    };
  }

  static String layoutMode(Map<String, dynamic> appearance) {
    if (readingMode(appearance) == 'scrolled') return 'continuous';
    return pageLayout(appearance) == '2' ? 'doublePage' : 'paginated';
  }
}
