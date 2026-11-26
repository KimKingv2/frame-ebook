/// EPUB 3.3 global rendition:spread processing for fixed-layout books.
class FrameEpubSpreadPolicy {
  FrameEpubSpreadPolicy._();

  /// Whether the publication's metadata permits a synthetic spread in the
  /// current device/window orientation.
  ///
  /// A missing or unrecognized value follows the EPUB "auto" default. The
  /// legacy "portrait" value is deprecated and treated as "both" by EPUB
  /// Reading Systems 3.3.
  static bool allowsSyntheticSpread({
    required String? renditionSpread,
    required bool isLandscape,
  }) {
    switch (renditionSpread?.trim().toLowerCase()) {
      case 'none':
        return false;
      case 'landscape':
        return isLandscape;
      case 'both':
      case 'portrait':
      case 'auto':
      case null:
      case '':
      default:
        return true;
    }
  }
}
