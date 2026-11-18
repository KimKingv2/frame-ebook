enum FrameCloudProvider { vps, worker, mobile, local }

extension FrameCloudProviderValue on FrameCloudProvider {
  String get apiValue => name;

  String get label {
    switch (this) {
      case FrameCloudProvider.vps:
        return 'VPS Alist';
      case FrameCloudProvider.worker:
        return 'OpenList Worker';
      case FrameCloudProvider.mobile:
        return 'Mobile Device Alist';
      case FrameCloudProvider.local:
        return '本地 OpenList';
    }
  }

  bool get isServerSide => this != FrameCloudProvider.local;

  static FrameCloudProvider fromValue(String? value) {
    return FrameCloudProvider.values.firstWhere(
      (provider) => provider.name == value,
      orElse: () => FrameCloudProvider.vps,
    );
  }
}

enum FrameCloudLibrary { books, comics }

extension FrameCloudLibraryValue on FrameCloudLibrary {
  String get apiValue => name;

  String get label => this == FrameCloudLibrary.books ? '電子書' : '漫畫';

  String get formatLabel =>
      this == FrameCloudLibrary.books ? 'EPUB' : 'EPUB / CBZ';

  static FrameCloudLibrary fromValue(String? value) =>
      value == 'comics' ? FrameCloudLibrary.comics : FrameCloudLibrary.books;
}

class FrameCloudProviderStatus {
  const FrameCloudProviderStatus({
    required this.provider,
    required this.label,
    required this.configured,
  });

  final FrameCloudProvider provider;
  final String label;
  final bool configured;

  factory FrameCloudProviderStatus.fromJson(
    FrameCloudProvider provider,
    Map<String, dynamic> json,
  ) {
    return FrameCloudProviderStatus(
      provider: provider,
      label: json['label']?.toString() ?? provider.label,
      configured: json['configured'] == true,
    );
  }
}

class FrameCloudSession {
  const FrameCloudSession({
    required this.authenticated,
    required this.accessEnabled,
    required this.providers,
    required this.suggestedRoots,
    required this.databaseConfigured,
    required this.cloudReaderDataConfigured,
    required this.cloudAnnotationsConfigured,
  });

  final bool authenticated;
  final bool accessEnabled;
  final Map<FrameCloudProvider, FrameCloudProviderStatus> providers;
  final Map<FrameCloudLibrary, String> suggestedRoots;
  final bool databaseConfigured;
  final bool cloudReaderDataConfigured;
  final bool cloudAnnotationsConfigured;

  factory FrameCloudSession.fromJson(Map<String, dynamic> json) {
    final rawProfiles = json['openListProfiles'];
    final profiles = rawProfiles is Map
        ? Map<String, dynamic>.from(rawProfiles)
        : <String, dynamic>{};
    final providers = <FrameCloudProvider, FrameCloudProviderStatus>{};
    for (final provider in [
      FrameCloudProvider.vps,
      FrameCloudProvider.worker,
      FrameCloudProvider.mobile,
    ]) {
      final raw = profiles[provider.apiValue];
      final value = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      providers[provider] = FrameCloudProviderStatus.fromJson(provider, value);
    }
    final rawRoots = json['rootPaths'];
    final roots = rawRoots is Map
        ? Map<String, dynamic>.from(rawRoots)
        : <String, dynamic>{};
    return FrameCloudSession(
      authenticated: json['authenticated'] == true,
      accessEnabled: json['accessEnabled'] == true,
      providers: providers,
      suggestedRoots: {
        FrameCloudLibrary.books: _safeRoot(
          roots['books']?.toString(),
          FrameCloudDefaults.booksRoot,
        ),
        FrameCloudLibrary.comics: _safeRoot(
          roots['comics']?.toString(),
          FrameCloudDefaults.comicsRoot,
        ),
      },
      databaseConfigured: json['databaseConfigured'] == true,
      cloudReaderDataConfigured: json['cloudReaderDataConfigured'] == true,
      cloudAnnotationsConfigured: json['cloudAnnotationsConfigured'] == true,
    );
  }
}

class FrameCloudDefaults {
  FrameCloudDefaults._();

  static const booksRoot =
      '/中國移動雲盤/Kim King/04 Boooooks/01 Books 歸檔';
  static const comicsRoot = '/中國移動雲盤/Kim King/11 Comic';
}

class FrameCloudPreferences {
  const FrameCloudPreferences({
    required this.activeProvider,
    required this.activeLibrary,
    required this.roots,
    required this.goalMinutes,
  });

  final FrameCloudProvider activeProvider;
  final FrameCloudLibrary activeLibrary;
  final Map<FrameCloudProvider, Map<FrameCloudLibrary, String>> roots;
  final int goalMinutes;

  factory FrameCloudPreferences.fromJson(Map<String, dynamic> json) {
    final activeProvider =
        FrameCloudProviderValue.fromValue(json['activeProvider']?.toString());
    final activeLibrary =
        FrameCloudLibraryValue.fromValue(json['activeLibrary']?.toString());
    final rawRoots = json['roots'];
    final rootsMap =
        rawRoots is Map ? Map<String, dynamic>.from(rawRoots) : <String, dynamic>{};
    final parsedRoots =
        <FrameCloudProvider, Map<FrameCloudLibrary, String>>{};
    for (final provider in [
      FrameCloudProvider.vps,
      FrameCloudProvider.worker,
      FrameCloudProvider.mobile,
    ]) {
      final source = rootsMap[provider.apiValue];
      if (source is! Map) continue;
      final pair = Map<String, dynamic>.from(source);
      final parsed = <FrameCloudLibrary, String>{};
      for (final library in FrameCloudLibrary.values) {
        final path = pair[library.apiValue]?.toString();
        if (path != null && normalizeFrameCloudPath(path) != null) {
          parsed[library] = normalizeFrameCloudPath(path)!;
        }
      }
      if (parsed.isNotEmpty) parsedRoots[provider] = parsed;
    }
    return FrameCloudPreferences(
      activeProvider: activeProvider,
      activeLibrary: activeLibrary,
      roots: parsedRoots,
      goalMinutes: _safeInt(json['goalMinutes'], 30).clamp(5, 240).toInt(),
    );
  }

  String rootFor(
    FrameCloudLibrary library, {
    FrameCloudSession? session,
  }) {
    final preferred = roots[activeProvider]?[library];
    if (preferred != null) return preferred;
    for (final provider in [
      FrameCloudProvider.vps,
      FrameCloudProvider.worker,
      FrameCloudProvider.mobile,
    ]) {
      final value = roots[provider]?[library];
      if (value != null) return value;
    }
    return session?.suggestedRoots[library] ??
        (library == FrameCloudLibrary.books
            ? FrameCloudDefaults.booksRoot
            : FrameCloudDefaults.comicsRoot);
  }

  Map<String, dynamic> toJson() => {
        'activeProvider': activeProvider.apiValue,
        'activeLibrary': activeLibrary.apiValue,
        'roots': {
          for (final entry in roots.entries)
            entry.key.apiValue: {
              for (final root in entry.value.entries)
                root.key.apiValue: root.value,
            },
        },
        'goalMinutes': goalMinutes,
      };
}

class FrameCloudEntry {
  const FrameCloudEntry({
    required this.name,
    required this.path,
    required this.parentPath,
    required this.isDirectory,
    required this.format,
    required this.size,
    required this.modified,
    required this.coverHash,
    required this.coverType,
    required this.coverStatus,
    required this.coverError,
  });

  final String name;
  final String path;
  final String parentPath;
  final bool isDirectory;
  final String format;
  final int size;
  final String? modified;
  final String? coverHash;
  final String? coverType;
  final String coverStatus;
  final String? coverError;

  bool get isSupportedBook => !isDirectory &&
      (format == 'EPUB' || (format == 'CBZ' && path.toLowerCase().endsWith('.cbz')));

  factory FrameCloudEntry.fromJson(Map<String, dynamic> json) {
    return FrameCloudEntry(
      name: json['name']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      parentPath: json['parentPath']?.toString() ?? '',
      isDirectory: json['isDir'] == true,
      format: json['format']?.toString().toUpperCase() ?? '',
      size: _safeInt(json['size'], 0).clamp(0, 9007199254740991).toInt(),
      modified: json['modified']?.toString(),
      coverHash: json['coverHash']?.toString(),
      coverType: json['coverType']?.toString(),
      coverStatus: json['coverStatus']?.toString() ?? 'pending',
      coverError: json['coverError']?.toString(),
    );
  }
}

class FrameCloudDirectoryPage {
  const FrameCloudDirectoryPage({
    required this.provider,
    required this.library,
    required this.rootPath,
    required this.path,
    required this.page,
    required this.perPage,
    required this.total,
    required this.indexed,
    required this.scanSummary,
    required this.items,
  });

  final FrameCloudProvider provider;
  final FrameCloudLibrary library;
  final String rootPath;
  final String path;
  final int page;
  final int perPage;
  final int total;
  final bool indexed;
  final Map<String, dynamic>? scanSummary;
  final List<FrameCloudEntry> items;

  int get pageCount => total == 0 ? 1 : ((total + perPage - 1) ~/ perPage);

  factory FrameCloudDirectoryPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final rawSummary = json['scanState'];
    return FrameCloudDirectoryPage(
      provider: FrameCloudProviderValue.fromValue(json['provider']?.toString()),
      library: FrameCloudLibraryValue.fromValue(json['library']?.toString()),
      rootPath: json['rootPath']?.toString() ?? '/',
      path: json['path']?.toString() ?? '/',
      page: _safeInt(json['page'], 1).clamp(1, 100000).toInt(),
      perPage: _safeInt(json['perPage'], 80).clamp(1, 100).toInt(),
      total: _safeInt(json['total'], 0).clamp(0, 9007199254740991).toInt(),
      indexed: json['indexed'] == true,
      scanSummary: rawSummary is Map
          ? Map<String, dynamic>.from(rawSummary)
          : null,
      items: rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((value) =>
                  FrameCloudEntry.fromJson(Map<String, dynamic>.from(value)))
              .where((value) => value.name.isNotEmpty && value.path.isNotEmpty)
              .toList(growable: false)
          : const [],
    );
  }
}

class FrameCloudScanState {
  FrameCloudScanState({
    required this.version,
    required this.provider,
    required this.library,
    required this.rootPath,
    required this.scanId,
    required this.pendingFolders,
    required this.currentFolder,
    required this.page,
    required this.seenFolders,
    required this.scannedCount,
    required this.indexedCount,
    required this.skippedCount,
    required this.failedCount,
    required this.visitedFolderCount,
    required this.coverReadyCount,
    required this.coverMissingCount,
    required this.coverFailedCount,
    required this.metadataProcessedCount,
    required this.metadataFailedCount,
    required this.pausedByUser,
    required this.resumeOnNextOpen,
    required this.completed,
    required this.errors,
    this.createdAt,
    this.updatedAt,
    this.raw = const {},
  });

  final int version;
  final FrameCloudProvider provider;
  final FrameCloudLibrary library;
  final String rootPath;
  final String scanId;
  final List<String> pendingFolders;
  final String? currentFolder;
  final int page;
  final List<String> seenFolders;
  final int scannedCount;
  final int indexedCount;
  final int skippedCount;
  final int failedCount;
  final int visitedFolderCount;
  final int coverReadyCount;
  final int coverMissingCount;
  final int coverFailedCount;
  final int metadataProcessedCount;
  final int metadataFailedCount;
  final bool pausedByUser;
  final bool resumeOnNextOpen;
  final bool completed;
  final List<Map<String, dynamic>> errors;
  final String? createdAt;
  final String? updatedAt;
  final Map<String, dynamic> raw;

  factory FrameCloudScanState.fromJson(Map<String, dynamic> json) {
    final pending = json['pendingFolders'];
    final seen = json['seenFolders'];
    final errors = json['errors'];
    return FrameCloudScanState(
      version: _safeInt(json['version'], 1),
      provider: FrameCloudProviderValue.fromValue(json['provider']?.toString()),
      library: FrameCloudLibraryValue.fromValue(json['library']?.toString()),
      rootPath: json['rootPath']?.toString() ?? '/',
      scanId: json['scanId']?.toString() ?? '',
      pendingFolders: pending is List
          ? pending.map((value) => value.toString()).toList(growable: true)
          : <String>[],
      currentFolder: json['currentFolder']?.toString(),
      page: _safeInt(json['page'], 1).clamp(1, 100000).toInt(),
      seenFolders: seen is List
          ? seen.map((value) => value.toString()).toList(growable: true)
          : <String>[],
      scannedCount: _safeInt(json['scannedCount'], 0).clamp(0, 9007199254740991).toInt(),
      indexedCount: _safeInt(json['indexedCount'], 0).clamp(0, 9007199254740991).toInt(),
      skippedCount: _safeInt(json['skippedCount'], 0).clamp(0, 9007199254740991).toInt(),
      failedCount: _safeInt(json['failedCount'], 0).clamp(0, 9007199254740991).toInt(),
      visitedFolderCount: _safeInt(json['visitedFolderCount'], 0).clamp(0, 9007199254740991).toInt(),
      coverReadyCount: _safeInt(json['coverReadyCount'], 0).clamp(0, 9007199254740991).toInt(),
      coverMissingCount: _safeInt(json['coverMissingCount'], 0).clamp(0, 9007199254740991).toInt(),
      coverFailedCount: _safeInt(json['coverFailedCount'], 0).clamp(0, 9007199254740991).toInt(),
      metadataProcessedCount: _safeInt(json['metadataProcessedCount'], 0).clamp(0, 9007199254740991).toInt(),
      metadataFailedCount: _safeInt(json['metadataFailedCount'], 0).clamp(0, 9007199254740991).toInt(),
      pausedByUser: json['pausedByUser'] == true,
      resumeOnNextOpen: json['resumeOnNextOpen'] == true,
      completed: json['completed'] == true,
      errors: errors is List
          ? errors
              .whereType<Map>()
              .map((value) => Map<String, dynamic>.from(value))
              .toList(growable: true)
          : <Map<String, dynamic>>[],
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
      raw: Map<String, dynamic>.from(json),
    );
  }

  Map<String, dynamic> toJson() => {
        ...raw,
        'version': version,
        'provider': provider.apiValue,
        'library': library.apiValue,
        'rootPath': rootPath,
        'scanId': scanId,
        'pendingFolders': pendingFolders,
        'currentFolder': currentFolder,
        'page': page,
        'seenFolders': seenFolders,
        'scannedCount': scannedCount,
        'indexedCount': indexedCount,
        'skippedCount': skippedCount,
        'failedCount': failedCount,
        'visitedFolderCount': visitedFolderCount,
        'coverReadyCount': coverReadyCount,
        'coverMissingCount': coverMissingCount,
        'coverFailedCount': coverFailedCount,
        'metadataProcessedCount': metadataProcessedCount,
        'metadataFailedCount': metadataFailedCount,
        'pausedByUser': pausedByUser,
        'resumeOnNextOpen': resumeOnNextOpen,
        'errors': errors,
        'completed': completed,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  FrameCloudScanState copyWith({
    List<String>? pendingFolders,
    String? currentFolder,
    bool clearCurrentFolder = false,
    int? page,
    List<String>? seenFolders,
    int? scannedCount,
    int? indexedCount,
    int? skippedCount,
    int? failedCount,
    int? visitedFolderCount,
    int? coverReadyCount,
    int? coverMissingCount,
    int? coverFailedCount,
    int? metadataProcessedCount,
    int? metadataFailedCount,
    bool? pausedByUser,
    bool? resumeOnNextOpen,
    bool? completed,
    List<Map<String, dynamic>>? errors,
    String? updatedAt,
  }) {
    return FrameCloudScanState(
      version: version,
      provider: provider,
      library: library,
      rootPath: rootPath,
      scanId: scanId,
      pendingFolders: pendingFolders ?? this.pendingFolders,
      currentFolder:
          clearCurrentFolder ? null : (currentFolder ?? this.currentFolder),
      page: page ?? this.page,
      seenFolders: seenFolders ?? this.seenFolders,
      scannedCount: scannedCount ?? this.scannedCount,
      indexedCount: indexedCount ?? this.indexedCount,
      skippedCount: skippedCount ?? this.skippedCount,
      failedCount: failedCount ?? this.failedCount,
      visitedFolderCount: visitedFolderCount ?? this.visitedFolderCount,
      coverReadyCount: coverReadyCount ?? this.coverReadyCount,
      coverMissingCount: coverMissingCount ?? this.coverMissingCount,
      coverFailedCount: coverFailedCount ?? this.coverFailedCount,
      metadataProcessedCount:
          metadataProcessedCount ?? this.metadataProcessedCount,
      metadataFailedCount: metadataFailedCount ?? this.metadataFailedCount,
      pausedByUser: pausedByUser ?? this.pausedByUser,
      resumeOnNextOpen: resumeOnNextOpen ?? this.resumeOnNextOpen,
      completed: completed ?? this.completed,
      errors: errors ?? this.errors,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      raw: raw,
    );
  }

  static FrameCloudScanState initial({
    required FrameCloudProvider provider,
    required FrameCloudLibrary library,
    required String rootPath,
    required String scanId,
  }) {
    return FrameCloudScanState(
      version: 1,
      provider: provider,
      library: library,
      rootPath: rootPath,
      scanId: scanId,
      pendingFolders: [rootPath],
      currentFolder: null,
      page: 1,
      seenFolders: [rootPath],
      scannedCount: 0,
      indexedCount: 0,
      skippedCount: 0,
      failedCount: 0,
      visitedFolderCount: 0,
      coverReadyCount: 0,
      coverMissingCount: 0,
      coverFailedCount: 0,
      metadataProcessedCount: 0,
      metadataFailedCount: 0,
      pausedByUser: false,
      resumeOnNextOpen: false,
      completed: false,
      errors: [],
      createdAt: DateTime.now().toIso8601String(),
    );
  }
}

class FrameCloudCoverQueue {
  const FrameCloudCoverQueue({
    required this.total,
    required this.items,
  });

  final int total;
  final List<FrameCloudEntry> items;
}

String? normalizeFrameCloudPath(String value) {
  final input = value.trim().replaceAll('\\', '/');
  if (input.isEmpty || !input.startsWith('/') || input.contains('\u0000')) {
    return null;
  }
  final parts = input.split('/');
  if (parts.any((part) => part == '.' || part == '..')) return null;
  final clean = parts.where((part) => part.isNotEmpty).join('/');
  return clean.isEmpty ? '/' : '/$clean';
}

bool frameCloudPathIsWithinRoot(String path, String root) {
  final normalizedPath = normalizeFrameCloudPath(path);
  final normalizedRoot = normalizeFrameCloudPath(root);
  if (normalizedPath == null || normalizedRoot == null) return false;
  if (normalizedRoot == '/') return true;
  return normalizedPath == normalizedRoot ||
      normalizedPath.startsWith('$normalizedRoot/');
}

String _safeRoot(String? input, String fallback) =>
    normalizeFrameCloudPath(input ?? '') ?? fallback;

int _safeInt(dynamic input, int fallback) {
  if (input is int) return input;
  if (input is num && input.isFinite) return input.round();
  return int.tryParse(input?.toString() ?? '') ?? fallback;
}
