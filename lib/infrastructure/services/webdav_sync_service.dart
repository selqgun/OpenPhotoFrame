import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import '../../domain/interfaces/sync_provider.dart';
import '../../domain/interfaces/storage_provider.dart';
import 'webdav_remote_client.dart';
import 'webdav_source_config.dart';

class WebDavSyncException implements Exception {
  const WebDavSyncException(
    this.code, {
    this.statusCode,
    this.cause,
    this.details,
  });

  final WebDavSyncErrorCode code;
  final int? statusCode;
  final Object? cause;
  final String? details;

  @override
  String toString() => switch (code) {
    WebDavSyncErrorCode.invalidShareLink =>
      'The Nextcloud share link is no longer valid.',
    WebDavSyncErrorCode.shareInaccessible =>
      'The Nextcloud share is no longer accessible.',
    WebDavSyncErrorCode.connectionTimeout =>
      'Connection to Nextcloud timed out.',
    WebDavSyncErrorCode.connectionFailed =>
      'Could not connect to Nextcloud. Check internet connection and share link.',
    WebDavSyncErrorCode.downloadStalled =>
      'Download timed out after 15 minutes without receiving data.',
    WebDavSyncErrorCode.invalidUrlEmpty => 'URL is empty.',
    WebDavSyncErrorCode.invalidUrlScheme =>
      'Invalid URL scheme. Use http or https.',
    WebDavSyncErrorCode.invalidUrlNoHost =>
      'Invalid URL. Host is missing.',
    WebDavSyncErrorCode.invalidUrlFormat =>
      'Invalid URL format: ${details ?? cause}',
    WebDavSyncErrorCode.unknown =>
      'Nextcloud sync failed: ${details ?? cause}',
  };
}

enum WebDavSyncErrorCode {
  invalidShareLink,
  shareInaccessible,
  connectionTimeout,
  connectionFailed,
  downloadStalled,
  invalidUrlEmpty,
  invalidUrlScheme,
  invalidUrlNoHost,
  invalidUrlFormat,
  unknown,
}

class WebDavFolder {
  const WebDavFolder({
    required this.path,
    required this.depth,
    this.fileCount = 0,
  });

  /// Rebuilds a folder from a (relative) path, deriving the tree depth.
  /// Used to restore the cached folder tree without a server connection.
  factory WebDavFolder.fromPath(String path, {int fileCount = 0}) {
    final normalized = WebDavSourceConfig.normalizeFolderPath(path);
    return WebDavFolder(
      path: normalized,
      depth: normalized.isEmpty ? 0 : normalized.split('/').length,
      fileCount: fileCount,
    );
  }

  final String path;
  final int depth;

  /// Number of image files directly in this folder (excludes subfolders).
  final int fileCount;

  String get name {
    if (path.isEmpty) {
      return '';
    }
    final separatorIndex = path.lastIndexOf('/');
    if (separatorIndex == -1) {
      return path;
    }
    return path.substring(separatorIndex + 1);
  }
}

class WebDavSyncService implements SyncProvider {
  static const Duration _downloadIdleTimeout = Duration(minutes: 15);

  final String webDavUrl;
  final String user;
  final String password;
  final String remotePath;
  final StorageProvider _storageProvider;
  final WebDavRemoteClientFactory _clientFactory;
  final WebDavSourceConfig _sourceConfig;
  final _log = Logger('WebDavSyncService');

  WebDavSyncService({
    required this.webDavUrl,
    required this.user,
    required this.password,
    required StorageProvider storageProvider,
    this.remotePath = '/',
    WebDavRemoteClientFactory clientFactory = createWebDavRemoteClientImpl,
    WebDavSourceConfig sourceConfig = const WebDavSourceConfig(),
  })  : _storageProvider = storageProvider,
        _clientFactory = clientFactory,
        _sourceConfig = sourceConfig;

  /// Factory for Public Share Links
  /// Link format: https://cloud.example.com/s/TOKEN
  factory WebDavSyncService.fromPublicLink(
    String link,
    StorageProvider storageProvider, {
    WebDavRemoteClientFactory clientFactory = createWebDavRemoteClientImpl,
    WebDavSourceConfig? sourceConfig,
  }) {
    final share = NextcloudPublicShare.fromPublicLink(link);

    return WebDavSyncService(
      webDavUrl: share.webDavUrl,
      user: share.user,
      password: share.password,
      storageProvider: storageProvider,
      clientFactory: clientFactory,
      sourceConfig: (sourceConfig ?? const WebDavSourceConfig()).copyWith(
        url: link,
      ),
    );
  }

  /// Builds a service from a stored config, handling both auth modes
  /// (Nextcloud public share link or a plain WebDAV URL with username/password).
  factory WebDavSyncService.fromConfig(
    WebDavSourceConfig config,
    StorageProvider storageProvider, {
    WebDavRemoteClientFactory clientFactory = createWebDavRemoteClientImpl,
  }) {
    final target = resolveTarget(config);
    return WebDavSyncService(
      webDavUrl: target.webDavUrl,
      user: target.user,
      password: target.password,
      storageProvider: storageProvider,
      clientFactory: clientFactory,
      sourceConfig: config,
    );
  }

  /// Resolves the effective WebDAV endpoint and credentials for [config].
  static ({String webDavUrl, String user, String password}) resolveTarget(
    WebDavSourceConfig config,
  ) {
    if (config.authMode == WebDavAuthMode.userPassword) {
      return (
        webDavUrl: config.url,
        user: config.username,
        password: config.password,
      );
    }
    final share = NextcloudPublicShare.fromPublicLink(config.url);
    return (
      webDavUrl: share.webDavUrl,
      user: share.user,
      password: share.password,
    );
  }

  @override
  String get id => 'nextcloud_public';

  static String describeError(Object error) {
    if (error is WebDavSyncException) {
      return error.toString();
    }

    if (error is TimeoutException) {
      return const WebDavSyncException(
        WebDavSyncErrorCode.downloadStalled,
      ).toString();
    }

    if (error is SocketException) {
      return const WebDavSyncException(
        WebDavSyncErrorCode.connectionFailed,
      ).toString();
    }

    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 401 || statusCode == 404) {
        return const WebDavSyncException(
          WebDavSyncErrorCode.invalidShareLink,
        ).toString();
      }
      if (statusCode == 403) {
        return const WebDavSyncException(
          WebDavSyncErrorCode.shareInaccessible,
        ).toString();
      }

      if (error.type == DioExceptionType.connectionTimeout) {
        return const WebDavSyncException(
          WebDavSyncErrorCode.connectionTimeout,
        ).toString();
      }
      if (error.type == DioExceptionType.connectionError) {
        return const WebDavSyncException(
          WebDavSyncErrorCode.connectionFailed,
        ).toString();
      }
      if (error.type == DioExceptionType.receiveTimeout) {
        return const WebDavSyncException(
          WebDavSyncErrorCode.downloadStalled,
        ).toString();
      }
    }

    return WebDavSyncException(
      WebDavSyncErrorCode.unknown,
      cause: error,
      details: error.toString(),
    ).toString();
  }

  static WebDavSyncException normalizeError(Object error) {
    if (error is WebDavSyncException) {
      return error;
    }

    final statusCode = error is DioException ? error.response?.statusCode : null;
    if (error is TimeoutException) {
      return WebDavSyncException(
        WebDavSyncErrorCode.downloadStalled,
        statusCode: statusCode,
        cause: error,
      );
    }

    if (error is SocketException) {
      return WebDavSyncException(
        WebDavSyncErrorCode.connectionFailed,
        statusCode: statusCode,
        cause: error,
      );
    }

    if (error is DioException) {
      if (statusCode == 401 || statusCode == 404) {
        return WebDavSyncException(
          WebDavSyncErrorCode.invalidShareLink,
          statusCode: statusCode,
          cause: error,
        );
      }
      if (statusCode == 403) {
        return WebDavSyncException(
          WebDavSyncErrorCode.shareInaccessible,
          statusCode: statusCode,
          cause: error,
        );
      }
      if (error.type == DioExceptionType.connectionTimeout) {
        return WebDavSyncException(
          WebDavSyncErrorCode.connectionTimeout,
          statusCode: statusCode,
          cause: error,
        );
      }
      if (error.type == DioExceptionType.connectionError) {
        return WebDavSyncException(
          WebDavSyncErrorCode.connectionFailed,
          statusCode: statusCode,
          cause: error,
        );
      }
      if (error.type == DioExceptionType.receiveTimeout) {
        return WebDavSyncException(
          WebDavSyncErrorCode.downloadStalled,
          statusCode: statusCode,
          cause: error,
        );
      }
    }

    return WebDavSyncException(
      WebDavSyncErrorCode.unknown,
      statusCode: statusCode,
      cause: error,
      details: error.toString(),
    );
  }

  /// Tests the connection to the WebDAV server.
  /// Returns null on success, or an error message on failure.
  static Future<WebDavSyncException?> testConnection(
    WebDavSourceConfig config, {
    WebDavRemoteClientFactory clientFactory = createWebDavRemoteClientImpl,
  }) async {
    final log = Logger('WebDavSyncService');

    if (config.url.isEmpty) {
      return const WebDavSyncException(WebDavSyncErrorCode.invalidUrlEmpty);
    }

    try {
      final uri = Uri.parse(config.url);

      if (uri.scheme != 'http' && uri.scheme != 'https') {
        return const WebDavSyncException(WebDavSyncErrorCode.invalidUrlScheme);
      }

      if (uri.host.isEmpty) {
        return const WebDavSyncException(WebDavSyncErrorCode.invalidUrlNoHost);
      }
      final target = resolveTarget(config);

      log.info("Testing connection to ${target.webDavUrl}");

      final client = clientFactory(
        webDavUrl: target.webDavUrl,
        user: target.user,
        password: target.password,
      );

      // Try to read root directory - this validates the connection
      await client.readDir('/');

      log.info("Connection test successful");
      return null; // Success

    } on FormatException catch (e) {
      return WebDavSyncException(
        WebDavSyncErrorCode.invalidUrlFormat,
        cause: e,
        details: e.message,
      );
    } catch (e, stackTrace) {
      final normalizedError = normalizeError(e);
      log.warning("Connection test failed", normalizedError, stackTrace);
      return normalizedError;
    }
  }

  static Future<List<WebDavFolder>> listAvailableFolders(
    WebDavSourceConfig config, {
    WebDavRemoteClientFactory clientFactory = createWebDavRemoteClientImpl,
  }) async {
    try {
      final target = resolveTarget(config);
      final client = clientFactory(
        webDavUrl: target.webDavUrl,
        user: target.user,
        password: target.password,
      );

      final folders = await _collectRemoteFolders(
        client,
        remoteDirectoryPath: '/',
        relativeDirectoryPath: '',
      );
      folders.sort((left, right) => left.path.compareTo(right.path));
      return folders;
    } catch (e) {
      throw normalizeError(e);
    }
  }

  @override
  Future<void> sync({
    bool deleteOrphanedFiles = false,
    SyncProgressCallback? onProgress,
  }) async {
    _log.info("Starting Sync from $webDavUrl (deleteOrphaned: $deleteOrphanedFiles)");

    final client = _clientFactory(
      webDavUrl: webDavUrl,
      user: user,
      password: password,
    );

    try {
      final localDir = await _storageProvider.getPhotoDirectory();
      _log.info("Syncing to local directory: ${localDir.path}");

      _log.info("Listing remote files...");
      final remoteFiles = await _collectRemoteImages(
        client,
        remoteDirectoryPath: remotePath,
        relativeDirectoryPath: '',
      );
      remoteFiles.sort((left, right) => left.relativePath.compareTo(right.relativePath));

      final pendingDownloads = <_RemoteImage>[];
      for (final remoteFile in remoteFiles) {
        final localFile = File('${localDir.path}/${remoteFile.relativePath}');
        if (!await localFile.exists()) {
          pendingDownloads.add(remoteFile);
        }
      }

      // Group pending downloads by their (selected) folder so we can report a
      // per-folder x/y breakdown. Order follows the sorted download order.
      final folderOrder = <String>[];
      final folderTotals = <String, int>{};
      for (final remoteFile in pendingDownloads) {
        final folder = WebDavSourceConfig.parentDirectoryOf(
          remoteFile.relativePath,
        );
        if (!folderTotals.containsKey(folder)) {
          folderOrder.add(folder);
        }
        folderTotals[folder] = (folderTotals[folder] ?? 0) + 1;
      }
      final folderCompleted = {for (final folder in folderOrder) folder: 0};

      List<SyncFolderProgress> folderSnapshot() => [
        for (final folder in folderOrder)
          SyncFolderProgress(
            folderPath: folder,
            completedFiles: folderCompleted[folder]!,
            totalFiles: folderTotals[folder]!,
          ),
      ];

      if (pendingDownloads.isNotEmpty) {
        onProgress?.call(
          SyncProgress(
            completedFiles: 0,
            totalFiles: pendingDownloads.length,
            currentFileLabel: pendingDownloads.first.relativePath,
            folders: folderSnapshot(),
          ),
        );
      }

      final remoteRelativePaths = remoteFiles
          .map((remoteFile) => remoteFile.relativePath)
          .toSet();

      for (var index = 0; index < pendingDownloads.length; index++) {
        final remoteFile = pendingDownloads[index];
        final localFile = File('${localDir.path}/${remoteFile.relativePath}');
        final folder = WebDavSourceConfig.parentDirectoryOf(
          remoteFile.relativePath,
        );

        onProgress?.call(
          SyncProgress(
            completedFiles: index,
            totalFiles: pendingDownloads.length,
            currentFileLabel: remoteFile.relativePath,
            folders: folderSnapshot(),
          ),
        );

        _log.info(
          'Downloading ${index + 1}/${pendingDownloads.length}...',
        );

        await localFile.parent.create(recursive: true);
        final partFile = File('${localFile.path}.part');
        await partFile.parent.create(recursive: true);
        await client.downloadFile(
          remoteFile.remotePath,
          partFile.path,
          idleTimeout: _downloadIdleTimeout,
        );

        if (remoteFile.modifiedAt != null) {
          try {
            await partFile.setLastModified(remoteFile.modifiedAt!);
          } catch (e) {
            _log.warning(
              'Could not set modification time for ${remoteFile.relativePath}: $e',
            );
          }
        }

        await partFile.rename(localFile.path);
        folderCompleted[folder] = (folderCompleted[folder] ?? 0) + 1;

        onProgress?.call(
          SyncProgress(
            completedFiles: index + 1,
            totalFiles: pendingDownloads.length,
            currentFileLabel: remoteFile.relativePath,
            folders: folderSnapshot(),
          ),
        );
      }
      
      if (deleteOrphanedFiles) {
        await _deleteOrphanedLocalFiles(
          localDirectory: localDir,
          remoteRelativePaths: remoteRelativePaths,
        );
      }
      
      _log.info("Sync completed.");

    } catch (e, stackTrace) {
      final normalizedError = normalizeError(e);
      _log.severe("Sync failed", normalizedError, stackTrace);
      throw normalizedError;
    }
  }

  static bool _isImage(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') || 
           lower.endsWith('.jpeg') || 
           lower.endsWith('.png') || 
           lower.endsWith('.webp');
  }

  Future<List<_RemoteImage>> _collectRemoteImages(
    WebDavRemoteClient client, {
    required String remoteDirectoryPath,
    required String relativeDirectoryPath,
  }) async {
    final entries = await client.readDir(remoteDirectoryPath);
    final images = <_RemoteImage>[];

    for (final entry in entries) {
      final entryRelativePath = _joinRelativePath(relativeDirectoryPath, entry.name);
      if (entry.isDirectory) {
        images.addAll(
          await _collectRemoteImages(
            client,
            remoteDirectoryPath: entry.path,
            relativeDirectoryPath: entryRelativePath,
          ),
        );
        continue;
      }

      if (!_isImage(entry.name) || !_sourceConfig.includesRelativeFile(entryRelativePath)) {
        continue;
      }

      images.add(
        _RemoteImage(
          remotePath: entry.path,
          relativePath: entryRelativePath,
          modifiedAt: entry.modifiedAt,
        ),
      );
    }

    return images;
  }

  Future<void> _deleteOrphanedLocalFiles({
    required Directory localDirectory,
    required Set<String> remoteRelativePaths,
  }) async {
    _log.info('Checking for orphaned local files...');
    final localEntities = await localDirectory.list(recursive: true, followLinks: false).toList();

    for (final entity in localEntities.whereType<File>()) {
      final relativePath = _relativePathFromLocalFile(localDirectory, entity);
      if (!_isImage(relativePath) || relativePath.endsWith('.part')) {
        continue;
      }

      if (remoteRelativePaths.contains(relativePath)) {
        continue;
      }

      _log.info('Deleting orphaned file: $relativePath');
      try {
        await entity.delete();
      } catch (e) {
        _log.warning('Failed to delete orphaned file $relativePath: $e');
      }
    }

    final directories = localEntities.whereType<Directory>().toList()
      ..sort((left, right) => right.path.length.compareTo(left.path.length));
    for (final directory in directories) {
      if (directory.path == localDirectory.path || !await directory.exists()) {
        continue;
      }

      if (await directory.list(followLinks: false).isEmpty) {
        await directory.delete();
      }
    }
  }

  /// Lists the folder named by [relativeDirectoryPath] and all its descendants,
  /// counting the image files directly contained in each. The PROPFIND response
  /// already carries the file entries, so the counts come for free (no extra
  /// requests beyond the directory listing we do anyway).
  static Future<List<WebDavFolder>> _collectRemoteFolders(
    WebDavRemoteClient client, {
    required String remoteDirectoryPath,
    required String relativeDirectoryPath,
  }) async {
    final entries = await client.readDir(remoteDirectoryPath);

    var imageCount = 0;
    final subDirectories = <WebDavRemoteEntry>[];
    for (final entry in entries) {
      if (entry.isDirectory) {
        subDirectories.add(entry);
      } else if (_isImage(entry.name)) {
        imageCount++;
      }
    }

    final folders = <WebDavFolder>[
      WebDavFolder.fromPath(relativeDirectoryPath, fileCount: imageCount),
    ];

    for (final entry in subDirectories) {
      folders.addAll(
        await _collectRemoteFolders(
          client,
          remoteDirectoryPath: entry.path,
          relativeDirectoryPath: _joinRelativePath(
            relativeDirectoryPath,
            entry.name,
          ),
        ),
      );
    }

    return folders;
  }

  static String _joinRelativePath(String directoryPath, String name) {
    final normalizedDirectory = WebDavSourceConfig.normalizeFolderPath(directoryPath);
    if (normalizedDirectory.isEmpty) {
      return name;
    }
    return '$normalizedDirectory/$name';
  }

  static String _relativePathFromLocalFile(Directory baseDirectory, File file) {
    var relativePath = file.path.substring(baseDirectory.path.length);
    if (relativePath.startsWith(Platform.pathSeparator)) {
      relativePath = relativePath.substring(1);
    }
    return relativePath.replaceAll('\\', '/');
  }
}

class _RemoteImage {
  const _RemoteImage({
    required this.remotePath,
    required this.relativePath,
    this.modifiedAt,
  });

  final String remotePath;
  final String relativePath;
  final DateTime? modifiedAt;
}
