enum WebDavFolderSyncMode {
  all,
  selectedFolders,
}

/// How the WebDAV target is authenticated.
enum WebDavAuthMode {
  /// A Nextcloud public share link (`https://host/s/TOKEN`); no password.
  publicShare,

  /// A plain WebDAV URL with username/password (also covers a Nextcloud
  /// account's personal WebDAV endpoint).
  userPassword,
}

/// A folder remembered from the last successful remote scan, including its
/// image count, so the folder picker can render (with counts) while offline.
class CachedWebDavFolder {
  const CachedWebDavFolder({
    required this.path,
    this.fileCount = 0,
  });

  final String path;
  final int fileCount;

  /// Parses one cache entry. Supports the legacy format where entries were
  /// bare path strings (before counts were stored).
  factory CachedWebDavFolder.fromEntry(Object? entry) {
    if (entry is Map) {
      return CachedWebDavFolder(
        path: '${entry['path'] ?? ''}',
        fileCount: (entry['count'] as num?)?.toInt() ?? 0,
      );
    }
    return CachedWebDavFolder(path: '$entry');
  }

  Map<String, dynamic> toMap() => {
    'path': WebDavSourceConfig.normalizeFolderPath(path),
    'count': fileCount,
  };
}

class WebDavSourceConfig {
  const WebDavSourceConfig({
    this.url = '',
    this.authMode = WebDavAuthMode.publicShare,
    this.username = '',
    this.password = '',
    this.allowInvalidCertificate = false,
    this.folderSyncMode = WebDavFolderSyncMode.all,
    this.selectedFolders = const <String>[],
    this.cachedFolders = const <CachedWebDavFolder>[],
  });

  final String url;
  final WebDavAuthMode authMode;
  final String username;
  final String password;

  /// Accept self-signed / otherwise invalid TLS certificates for this WebDAV
  /// server. Opt-in, for self-hosted servers on trusted networks.
  final bool allowInvalidCertificate;
  final WebDavFolderSyncMode folderSyncMode;
  final List<String> selectedFolders;

  /// The full available folder tree (with image counts) from the last
  /// successful load. Lets the folder picker render offline (no connection).
  final List<CachedWebDavFolder> cachedFolders;

  factory WebDavSourceConfig.fromMap(Map<String, dynamic> config) {
    List<String> parseFolderList(Object? raw) => switch (raw) {
      List<dynamic>() => raw.map((entry) => '$entry').toList(),
      _ => const <String>[],
    };

    final rawCached = config['cached_folders'];
    final cachedFolders = switch (rawCached) {
      List<dynamic>() => rawCached.map(CachedWebDavFolder.fromEntry).toList(),
      _ => const <CachedWebDavFolder>[],
    };

    return WebDavSourceConfig(
      url: (config['url'] as String? ?? '').trim(),
      authMode: (config['auth_mode'] as String?) == 'user_password'
          ? WebDavAuthMode.userPassword
          : WebDavAuthMode.publicShare,
      username: (config['username'] as String? ?? '').trim(),
      password: config['password'] as String? ?? '',
      allowInvalidCertificate: config['allow_invalid_certificate'] as bool? ?? false,
      folderSyncMode: (config['folder_sync_mode'] as String?) == 'selected'
          ? WebDavFolderSyncMode.selectedFolders
          : WebDavFolderSyncMode.all,
      selectedFolders: parseFolderList(config['selected_folders']),
      cachedFolders: cachedFolders,
    );
  }

  /// Splits inline `user:pass@host` credentials out of a WebDAV URL, returning
  /// the cleaned URL plus any extracted username/password (null when absent).
  static ({String url, String? username, String? password}) splitInlineCredentials(
    String input,
  ) {
    final trimmed = input.trim();
    try {
      final uri = Uri.parse(trimmed);
      if (uri.userInfo.isEmpty) {
        return (url: trimmed, username: null, password: null);
      }
      final separator = uri.userInfo.indexOf(':');
      final rawUser = separator == -1 ? uri.userInfo : uri.userInfo.substring(0, separator);
      final rawPass = separator == -1 ? '' : uri.userInfo.substring(separator + 1);
      return (
        url: uri.replace(userInfo: '').toString(),
        username: Uri.decodeComponent(rawUser),
        password: Uri.decodeComponent(rawPass),
      );
    } catch (_) {
      return (url: trimmed, username: null, password: null);
    }
  }

  bool get syncAllFolders => folderSyncMode == WebDavFolderSyncMode.all;

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

  WebDavSourceConfig copyWith({
    String? url,
    WebDavAuthMode? authMode,
    String? username,
    String? password,
    bool? allowInvalidCertificate,
    WebDavFolderSyncMode? folderSyncMode,
    List<String>? selectedFolders,
    List<CachedWebDavFolder>? cachedFolders,
  }) {
    return WebDavSourceConfig(
      url: url ?? this.url,
      authMode: authMode ?? this.authMode,
      username: username ?? this.username,
      password: password ?? this.password,
      allowInvalidCertificate:
          allowInvalidCertificate ?? this.allowInvalidCertificate,
      folderSyncMode: folderSyncMode ?? this.folderSyncMode,
      selectedFolders: selectedFolders ?? this.selectedFolders,
      cachedFolders: cachedFolders ?? this.cachedFolders,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'auth_mode': switch (authMode) {
        WebDavAuthMode.publicShare => 'public_share',
        WebDavAuthMode.userPassword => 'user_password',
      },
      'username': username,
      'password': password,
      'allow_invalid_certificate': allowInvalidCertificate,
      'folder_sync_mode': switch (folderSyncMode) {
        WebDavFolderSyncMode.all => 'all',
        WebDavFolderSyncMode.selectedFolders => 'selected',
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