import 'dart:convert';

class WebDavProfile {
  const WebDavProfile({
    this.id = 'primary',
    this.name = 'WebDAV',
    required this.baseUrl,
    required this.username,
    required this.booksRoot,
    required this.comicsRoot,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String username;
  final String booksRoot;
  final String comicsRoot;

  String rootFor(String library) {
    if (library == 'books') return booksRoot;
    if (library == 'comics') return comicsRoot;
    throw ArgumentError.value(library, 'library', '不支援的書庫分類。');
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'username': username,
        'booksRoot': booksRoot,
        'comicsRoot': comicsRoot,
      };

  factory WebDavProfile.fromJson(Map<String, dynamic> json) {
    return WebDavProfile(
      id: 'primary',
      name: 'WebDAV',
      baseUrl: json['baseUrl']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      booksRoot: json['booksRoot']?.toString() ?? '/',
      comicsRoot: json['comicsRoot']?.toString() ?? '/',
    );
  }

  String encode() => jsonEncode(toJson());

  static WebDavProfile decode(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('WebDAV 設定內容格式錯誤。');
    }
    return WebDavProfile.fromJson(decoded);
  }
}

class WebDavEntry {
  const WebDavEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
    required this.contentType,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final String modified;
  final String contentType;

  bool get isEpub => !isDirectory && name.toLowerCase().endsWith('.epub');
  bool get isCbz => !isDirectory && name.toLowerCase().endsWith('.cbz');
}

class WebDavFileRange {
  const WebDavFileRange({
    required this.bytes,
    required this.start,
    required this.end,
    required this.totalSize,
    required this.redirected,
  });

  final List<int> bytes;
  final int start;
  final int end;
  final int totalSize;
  final bool redirected;
}

class WebDavFileMetadata {
  const WebDavFileMetadata({
    required this.size,
    required this.contentType,
    required this.etag,
    required this.lastModified,
  });

  final int size;
  final String contentType;
  final String etag;
  final String lastModified;
}
