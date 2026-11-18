class FrameBook {
  const FrameBook({
    required this.id,
    required this.provider,
    required this.library,
    required this.rootPath,
    required this.path,
    required this.fileName,
    required this.title,
    required this.author,
    required this.format,
    required this.shelf,
    required this.size,
    required this.lastModified,
    required this.lastOpenedAt,
    required this.addedAt,
    required this.pageCount,
    required this.language,
    required this.publisher,
    required this.publishedAt,
    required this.identifier,
    required this.subjects,
    required this.description,
    required this.progress,
    required this.manualTitle,
    required this.manualAuthor,
    required this.coverHash,
    required this.coverStatus,
    required this.folderPath,
    required this.folderTitle,
    required this.comicMetadata,
    required this.raw,
  });

  final String id;
  final String provider;
  final String library;
  final String rootPath;
  final String path;
  final String fileName;
  final String title;
  final String author;
  final String format;
  final String shelf;
  final int size;
  final int lastModified;
  final int lastOpenedAt;
  final int addedAt;
  final int pageCount;
  final String language;
  final String publisher;
  final String publishedAt;
  final String identifier;
  final List<String> subjects;
  final String description;
  final Map<String, dynamic> progress;
  final bool manualTitle;
  final bool manualAuthor;
  final String coverHash;
  final String coverStatus;
  final String folderPath;
  final String folderTitle;
  final Map<String, dynamic> comicMetadata;
  final Map<String, dynamic> raw;

  bool get isComic => format.toUpperCase() == 'CBZ' || shelf == 'comics';
  int get progressPercent =>
      (num.tryParse(progress['percent']?.toString() ?? '') ?? 0)
          .round()
          .clamp(0, 100)
          .toInt();

  String get progressLabel =>
      progress['label']?.toString() ?? (progressPercent > 0 ? '閱讀中' : '尚未開始');

  String get bookKey => [provider, library, rootPath, path].join('\n');

  factory FrameBook.fromJson(Map<String, dynamic> json) {
    final source = _map(json['cloudSource']);
    final progress = _map(json['progress']);
    final comic = _map(json['comicMetadata']);
    return FrameBook(
      id: _string(json['id']),
      provider: _string(source['provider'] ?? json['provider']),
      library: _string(source['library'] ?? json['library'] ?? json['shelf']),
      rootPath: _string(source['rootPath'] ?? json['rootPath']),
      path: _string(source['path'] ?? json['path']),
      fileName: _string(json['fileName'] ?? json['name']),
      title: _string(json['title']),
      author: _string(json['author']),
      format: _string(json['format']).toUpperCase(),
      shelf: _string(json['shelf']),
      size: _integer(json['size']),
      lastModified: _dateValue(json['lastModified'] ?? json['modifiedAt']),
      lastOpenedAt: _integer(json['lastOpenedAt']),
      addedAt: _integer(json['addedAt']),
      pageCount: _integer(json['pageCount']),
      language: _string(json['language']),
      publisher: _string(json['publisher']),
      publishedAt: _string(json['publishedAt']),
      identifier: _string(json['identifier']),
      subjects: (json['subjects'] is List)
          ? (json['subjects'] as List).map((item) => item.toString()).toList()
          : const [],
      description: _string(json['description']),
      progress: progress,
      manualTitle: json['manualTitle'] == true,
      manualAuthor: json['manualAuthor'] == true,
      coverHash: _string(json['cloudCoverHash']),
      coverStatus: _string(json['cloudCoverStatus']),
      folderPath: _string(source['folderPath']),
      folderTitle: _string(json['folderTitle']),
      comicMetadata: comic,
      raw: Map<String, dynamic>.from(json),
    );
  }

  Map<String, dynamic> descriptor() => {
        'id': id,
        'provider': provider,
        'library': library,
        'rootPath': rootPath,
        'path': path,
      };

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static String _string(dynamic value) => value?.toString() ?? '';

  static int _integer(dynamic value) {
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int _dateValue(dynamic value) {
    if (value is num) return value.round();
    if (value is String) {
      final numeric = int.tryParse(value);
      if (numeric != null) return numeric;
      return DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0;
    }
    return 0;
  }
}

class FrameShelfEntry {
  FrameShelfEntry(this.first) : members = [first];

  final FrameBook first;
  final List<FrameBook> members;

  bool get isFolder => members.length > 0 && first.folderPath.isNotEmpty;
  bool get isComic => first.isComic;
  int get lastOpenedAt =>
      members.fold<int>(0, (value, item) => item.lastOpenedAt > value ? item.lastOpenedAt : value);
  int get volumeCount => members.length;
  int get totalSize => members.fold<int>(0, (sum, item) => sum + item.size);
  int get progressPercent => first.progressPercent;
  String get progressLabel => first.progressLabel;
  String get provider => first.provider;
  String get library => first.library;
  String get rootPath => first.rootPath;
  String get folderPath => first.folderPath;
  String get key => first.folderPath.isEmpty
      ? first.bookKey
      : [first.provider, first.library, first.rootPath, first.folderPath].join('\n');

  String get title {
    if (!isFolder) return first.title.isNotEmpty ? first.title : first.fileName;
    final bangumiTitle = first.comicMetadata['nameCn'] ??
        first.comicMetadata['name'];
    if (bangumiTitle != null && bangumiTitle.toString().isNotEmpty) {
      return bangumiTitle.toString();
    }
    if (first.folderTitle.isNotEmpty) return first.folderTitle;
    final parts = first.folderPath.split('/').where((part) => part.isNotEmpty);
    return parts.isNotEmpty ? parts.last : first.title;
  }

  String get author => first.author;
  String get format => first.format;
  String get coverHash => first.coverHash;
  String get coverStatus => first.coverStatus;

  List<String> get searchText {
    final metadata = first.comicMetadata;
    final tags = (metadata['tags'] is List)
        ? (metadata['tags'] as List).map((tag) {
            if (tag is Map) return tag['name']?.toString() ?? '';
            return tag.toString();
          }).join(' ')
        : '';
    final membersText =
        members.map((item) => '${item.fileName} ${item.title} ${item.format}').join(' ');
    return [
      title,
      author,
      first.fileName,
      first.format,
      membersText,
      metadata['name']?.toString() ?? '',
      metadata['nameCn']?.toString() ?? '',
      metadata['author']?.toString() ?? '',
      tags,
    ];
  }

  void add(FrameBook book) => members.add(book);

  List<FrameBook> sortedMembers() {
    final result = [...members];
    result.sort((a, b) {
      final byName = a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
      if (byName != 0) return byName;
      return a.path.compareTo(b.path);
    });
    return result;
  }

  List<String> get coverHashes => members
      .where((item) =>
          item.coverStatus == 'ready' &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(item.coverHash))
      .map((item) => item.coverHash)
      .toSet()
      .take(8)
      .toList();
}

List<FrameShelfEntry> groupFrameBooks(List<FrameBook> books) {
  final groups = <String, FrameShelfEntry>{};
  final output = <FrameShelfEntry>[];
  for (final book in books) {
    if (book.folderPath.isEmpty) {
      output.add(FrameShelfEntry(book));
      continue;
    }
    final key = [book.provider, book.library, book.rootPath, book.folderPath].join('\n');
    final group = groups[key];
    if (group == null) {
      final created = FrameShelfEntry(book);
      groups[key] = created;
      output.add(created);
    } else {
      group.add(book);
    }
  }
  return output;
}
