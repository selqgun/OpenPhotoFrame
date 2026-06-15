enum NextcloudFolderSyncMode {
  all,
  selectedFolders,
}

/// A folder remembered from the last successful remote scan, including its
/// image count, so the folder picker can render (with counts) while offline.
class CachedNextcloudFolder {
  const CachedNextcloudFolder({
    required this.path,
    this.fileCount = 0,
  });

  final String path;
  final int fileCount;

  /// Parses one cache entry. Supports the legacy format where entries were
  /// bare path strings (before counts were stored).
  factory CachedNextcloudFolder.fromEntry(Object? entry) {
    if (entry is Map) {
      return CachedNextcloudFolder(
        path: '${entry['path'] ?? ''}',
        fileCount: (entry['count'] as num?)?.toInt() ?? 0,
      );
    }
    return CachedNextcloudFolder(path: '$entry');
  }

  Map<String, dynamic> toMap() => {
    'path': NextcloudSourceConfig.normalizeFolderPath(path),
    'count': fileCount,
  };
}

class NextcloudSourceConfig {
  const NextcloudSourceConfig({
    this.url = '',
    this.folderSyncMode = NextcloudFolderSyncMode.all,
    this.selectedFolders = const <String>[],
    this.cachedFolders = const <CachedNextcloudFolder>[],
  });

  final String url;
  final NextcloudFolderSyncMode folderSyncMode;
  final List<String> selectedFolders;

  /// The full available folder tree (with image counts) from the last
  /// successful load. Lets the folder picker render offline (no connection).
  final List<CachedNextcloudFolder> cachedFolders;

  factory NextcloudSourceConfig.fromMap(Map<String, dynamic> config) {
    List<String> parseFolderList(Object? raw) => switch (raw) {
      List<dynamic>() => raw.map((entry) => '$entry').toList(),
      _ => const <String>[],
    };

    final rawCached = config['cached_folders'];
    final cachedFolders = switch (rawCached) {
      List<dynamic>() => rawCached.map(CachedNextcloudFolder.fromEntry).toList(),
      _ => const <CachedNextcloudFolder>[],
    };

    return NextcloudSourceConfig(
      url: (config['url'] as String? ?? '').trim(),
      folderSyncMode: (config['folder_sync_mode'] as String?) == 'selected'
          ? NextcloudFolderSyncMode.selectedFolders
          : NextcloudFolderSyncMode.all,
      selectedFolders: parseFolderList(config['selected_folders']),
      cachedFolders: cachedFolders,
    );
  }

  bool get syncAllFolders => folderSyncMode == NextcloudFolderSyncMode.all;

  Set<String> get normalizedSelectedFolders {
    final normalizedFolders = selectedFolders
        .map(normalizeFolderPath)
        .toSet();
    final includesRoot = selectedFolders.any(
      (folder) => normalizeFolderPath(folder).isEmpty,
    );
    if (!includesRoot) {
      normalizedFolders.remove('');
    }
    return normalizedFolders;
  }

  bool includesDirectory(String directoryPath) {
    if (syncAllFolders) {
      return true;
    }

    return normalizedSelectedFolders.contains(normalizeFolderPath(directoryPath));
  }

  bool includesRelativeFile(String relativePath) {
    return includesDirectory(parentDirectoryOf(relativePath));
  }

  NextcloudSourceConfig copyWith({
    String? url,
    NextcloudFolderSyncMode? folderSyncMode,
    List<String>? selectedFolders,
    List<CachedNextcloudFolder>? cachedFolders,
  }) {
    return NextcloudSourceConfig(
      url: url ?? this.url,
      folderSyncMode: folderSyncMode ?? this.folderSyncMode,
      selectedFolders: selectedFolders ?? this.selectedFolders,
      cachedFolders: cachedFolders ?? this.cachedFolders,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'folder_sync_mode': switch (folderSyncMode) {
        NextcloudFolderSyncMode.all => 'all',
        NextcloudFolderSyncMode.selectedFolders => 'selected',
      },
      'selected_folders': normalizedSelectedFolders.toList()..sort(),
      'cached_folders': cachedFolders.map((folder) => folder.toMap()).toList(),
    };
  }

  static String normalizeFolderPath(String path) {
    var normalized = path.trim().replaceAll('\\', '/');
    if (normalized.isEmpty || normalized == '/') {
      return '';
    }

    while (normalized.contains('//')) {
      normalized = normalized.replaceAll('//', '/');
    }

    if (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static String parentDirectoryOf(String relativePath) {
    final normalized = normalizeFolderPath(relativePath);
    final separatorIndex = normalized.lastIndexOf('/');
    if (separatorIndex == -1) {
      return '';
    }
    return normalized.substring(0, separatorIndex);
  }
}