import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import '../../domain/interfaces/storage_provider.dart';
import '../../domain/interfaces/sync_provider.dart';
import 'smb_native_client.dart';
import 'smb_source_config.dart';

class SmbSyncService implements SyncProvider {
  SmbSyncService({
    required SmbSourceConfig sourceConfig,
    required StorageProvider storageProvider,
    SmbNativeClient? client,
  }) : _sourceConfig = sourceConfig,
       _storageProvider = storageProvider,
       _client = client ?? SmbNativeClient();

  final SmbSourceConfig _sourceConfig;
  final StorageProvider _storageProvider;
  final SmbNativeClient _client;
  final _log = Logger('SmbSyncService');

  @override
  String get id => 'smb';

  @override
  Future<void> sync({
    bool deleteOrphanedFiles = false,
    SyncProgressCallback? onProgress,
  }) async {
    final localDirectory = await _storageProvider.getPhotoDirectory();
    if (!await localDirectory.exists()) {
      await localDirectory.create(recursive: true);
    }

    final configMap = _sourceConfig.toMap();
    await _client.testConnection(configMap);

    final remoteFiles = await _collectRemoteFiles(
      configMap: configMap,
      remoteDirectoryPath: _sourceConfig.normalizedPath,
      relativeDirectoryPath: '',
    );

    remoteFiles.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    final remoteRelativePaths = remoteFiles.map((item) => item.relativePath).toSet();

    var completed = 0;
    onProgress?.call(SyncProgress(completedFiles: 0, totalFiles: remoteFiles.length));

    for (final remoteFile in remoteFiles) {
      final localFile = File('${localDirectory.path}${Platform.pathSeparator}${remoteFile.relativePath.replaceAll('/', Platform.pathSeparator)}');
      await localFile.parent.create(recursive: true);

      final shouldDownload = !await localFile.exists() ||
          (remoteFile.size != null && await localFile.length() != remoteFile.size) ||
          (remoteFile.modifiedAt != null && (await localFile.lastModified()).isBefore(remoteFile.modifiedAt!));

      if (shouldDownload) {
        final partFile = File('${localFile.path}.part');
        if (await partFile.exists()) {
          await partFile.delete();
        }
        await _client.downloadFile(
          config: configMap,
          remotePath: remoteFile.remotePath,
          localPath: partFile.path,
        );
        if (await localFile.exists()) {
          await localFile.delete();
        }
        await partFile.rename(localFile.path);
        if (remoteFile.modifiedAt != null) {
          await localFile.setLastModified(remoteFile.modifiedAt!);
        }
      }

      completed++;
      onProgress?.call(
        SyncProgress(
          completedFiles: completed,
          totalFiles: remoteFiles.length,
          currentFileLabel: remoteFile.relativePath,
        ),
      );
    }

    if (deleteOrphanedFiles) {
      await _deleteOrphanedLocalFiles(
        localDirectory: localDirectory,
        remoteRelativePaths: remoteRelativePaths,
      );
    }

    await _enforceCacheLimit(localDirectory, _sourceConfig.cacheSizeMb * 1024 * 1024);
  }

  Future<List<_RemoteMedia>> _collectRemoteFiles({
    required Map<String, dynamic> configMap,
    required String remoteDirectoryPath,
    required String relativeDirectoryPath,
  }) async {
    final entries = await _client.listDirectory(
      config: configMap,
      path: remoteDirectoryPath,
    );
    final files = <_RemoteMedia>[];

    for (final entry in entries) {
      final entryRelativePath = _joinRelativePath(relativeDirectoryPath, entry.name);
      if (entry.isDirectory) {
        files.addAll(
          await _collectRemoteFiles(
            configMap: configMap,
            remoteDirectoryPath: entry.path,
            relativeDirectoryPath: entryRelativePath,
          ),
        );
        continue;
      }

      if (!_isSupportedMedia(entry.name) || entry.name.toLowerCase().endsWith('.part')) {
        continue;
      }

      files.add(
        _RemoteMedia(
          remotePath: entry.path,
          relativePath: entryRelativePath,
          size: entry.size,
          modifiedAt: entry.modifiedAt,
        ),
      );
    }

    return files;
  }

  Future<void> _deleteOrphanedLocalFiles({
    required Directory localDirectory,
    required Set<String> remoteRelativePaths,
  }) async {
    final entities = await localDirectory.list(recursive: true, followLinks: false).toList();
    for (final file in entities.whereType<File>()) {
      final relativePath = _relativePathFromLocalFile(localDirectory, file);
      if (!_isSupportedMedia(relativePath) || relativePath.endsWith('.part')) {
        continue;
      }
      if (!remoteRelativePaths.contains(relativePath)) {
        await file.delete();
      }
    }
  }

  Future<void> _enforceCacheLimit(Directory localDirectory, int maxBytes) async {
    if (maxBytes <= 0) {
      return;
    }
    final files = <File>[];
    await for (final entity in localDirectory.list(recursive: true, followLinks: false)) {
      if (entity is File && _isSupportedMedia(entity.path) && !entity.path.endsWith('.part')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    var totalBytes = 0;
    final lengths = <String, int>{};
    for (final file in files) {
      final length = await file.length();
      lengths[file.path] = length;
      totalBytes += length;
    }
    for (final file in files) {
      if (totalBytes <= maxBytes) {
        break;
      }
      final length = lengths[file.path] ?? 0;
      try {
        await file.delete();
        totalBytes -= length;
        _log.info('Evicted cached media: ${file.path}');
      } catch (error) {
        _log.warning('Failed to evict cached media ${file.path}', error);
      }
    }
  }

  bool _isSupportedMedia(String path) => _isImage(path) || _isVideo(path);

  bool _isImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp');
  }

  bool _isVideo(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v');
  }

  String _joinRelativePath(String directoryPath, String name) {
    if (directoryPath.isEmpty) {
      return name;
    }
    return '$directoryPath/$name';
  }

  String _relativePathFromLocalFile(Directory baseDirectory, File file) {
    var relativePath = file.path.substring(baseDirectory.path.length);
    if (relativePath.startsWith(Platform.pathSeparator)) {
      relativePath = relativePath.substring(1);
    }
    return relativePath.replaceAll('\\', '/');
  }
}

class _RemoteMedia {
  const _RemoteMedia({
    required this.remotePath,
    required this.relativePath,
    this.size,
    this.modifiedAt,
  });

  final String remotePath;
  final String relativePath;
  final int? size;
  final DateTime? modifiedAt;
}
