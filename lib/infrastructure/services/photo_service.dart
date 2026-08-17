import 'dart:io';
import 'dart:convert';
import 'smb_native_client.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../domain/interfaces/config_provider.dart';
import '../../domain/interfaces/playlist_strategy.dart';
import '../../domain/interfaces/sync_provider.dart';
import '../../domain/interfaces/storage_provider.dart';
import '../../domain/interfaces/photo_repository.dart';
import '../../domain/models/photo_entry.dart';

/// Factory function type that creates a SyncProvider from current config
typedef SyncProviderFactory = SyncProvider Function();

enum SyncStatusKind {
  success,
  cancelled,
  error,
}

class SyncStatus {
  const SyncStatus.success({this.summary})
    : kind = SyncStatusKind.success,
      error = null;

  const SyncStatus.cancelled()
    : kind = SyncStatusKind.cancelled,
      error = null,
      summary = null;

  const SyncStatus.error(this.error) : kind = SyncStatusKind.error, summary = null;

  final SyncStatusKind kind;
  final Object? error;
  final String? summary;
}
class PhotoService extends ChangeNotifier {
  final SyncProviderFactory _syncProviderFactory;
  final PlaylistStrategy _playlistStrategy;
  final PhotoRepository _repository;
  final ConfigProvider _configProvider;
  final StorageProvider _storageProvider;
  final _log = Logger('PhotoService');

  bool _isInitialized = false;
  bool _syncLoopRunning = false;
  
  // Sync state management
  bool _isSyncing = false;
  bool _cancelRequested = false;
  Completer<void>? _currentSyncCompleter;
  SyncProgress? _syncProgress;
  SyncStatus? _syncStatus;
  
  // History management
  final List<PhotoEntry> _history = [];
  int _historyIndex = -1;

  // Global sampling / queue fields for SMB mode
  List<Map<String, dynamic>> _smbList = []; // Loaded from smb_list.json
  final List<Map<String, dynamic>> _playingList = []; // playing_list (max 200/extended)
  final Set<String> _historyList = {}; // history_list (global deduplication pool)
  int _playingIndex = -1; // Current index in _playingList
  bool _isPreloading = false;
  bool _smbNetworkError = false; // Flag to indicate network interruption
  String? _localDirPath;
  
  // Directory change subscription
  StreamSubscription? _directoryChangeSubscription;

  PhotoService({
    required SyncProviderFactory syncProviderFactory,
    required PlaylistStrategy playlistStrategy,
    required PhotoRepository repository,
    required ConfigProvider configProvider,
    required StorageProvider storageProvider,
  })  : _syncProviderFactory = syncProviderFactory,
        _playlistStrategy = playlistStrategy,
        _repository = repository,
        _configProvider = configProvider,
        _storageProvider = storageProvider;

  Stream<void> get onPhotosChanged => _repository.onPhotosChanged;
  
  /// Returns true if a sync is currently in progress
  bool get isSyncing => _isSyncing;
  SyncProgress? get syncProgress => _syncProgress;
  SyncStatus? get syncStatus => _syncStatus;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _log.info("Initializing PhotoService...");
    
    // Load local directory path
    final localDir = await _storageProvider.getPhotoDirectory();
    _localDirPath = localDir.path;

    // Load SMB list and initialize playing list if active source is SMB
    if (_configProvider.activeSourceType == 'smb') {
      await _loadSmbList();
      await _initializePlayingList();
    }

    // 1. Initialize Repository (Load local photos)
    await _repository.initialize();
    
    // 2. Listen for directory changes
    _directoryChangeSubscription = _storageProvider.onDirectoryChanged.listen((_) {
      _onDirectoryChanged();
    });
    
    // 3. Start Sync in Background
    _startBackgroundSync();
    
    _isInitialized = true;
  }

  void _updateSyncState({
    bool? isSyncing,
    SyncProgress? progress,
    bool clearProgress = false,
    SyncStatus? status,
    bool clearStatus = false,
  }) {
    var changed = false;

    if (isSyncing != null && _isSyncing != isSyncing) {
      _isSyncing = isSyncing;
      changed = true;
    }

    if (clearProgress) {
      if (_syncProgress != null) {
        _syncProgress = null;
        changed = true;
      }
    } else if (progress != null) {
      _syncProgress = progress;
      changed = true;
    }

    if (clearStatus) {
      if (_syncStatus != null) {
        _syncStatus = null;
        changed = true;
      }
    } else if (status != null && _syncStatus != status) {
      _syncStatus = status;
      changed = true;
    }

    if (changed) {
      notifyListeners();
    }
  }
  
  /// Called when the photo directory changes (e.g., user selected different folder)
  Future<void> _onDirectoryChanged() async {
    _log.info("Photo directory changed, reinitializing...");
    
    final localDir = await _storageProvider.getPhotoDirectory();
    _localDirPath = localDir.path;

    // 1. Reset slideshow state (history is no longer valid)
    _resetState();
    
    if (_configProvider.activeSourceType == 'smb') {
      await _loadSmbList();
      await _initializePlayingList();
    }

    // 2. Reinitialize repository with new directory
    await _repository.reinitialize();
    
    _log.info("Directory change complete");
  }
  
  /// Resets slideshow state (history, current position)
  void _resetState() {
    _history.clear();
    _historyIndex = -1;
    _playingList.clear();
    _playingIndex = -1;
    _historyList.clear();
    _log.info("Slideshow state reset");
  }

  void _startBackgroundSync() {
    if (_syncLoopRunning) return;
    _syncLoopRunning = true;

    unawaited(() async {
      while (_syncLoopRunning) {
      // Read current config values (they might change via settings)
        final intervalMinutes = _configProvider.syncIntervalMinutes;

        // If interval is 0, sync is disabled
        if (intervalMinutes <= 0) {
          _log.info("Auto-sync is disabled. Checking again in 1 minute...");
          await Future.delayed(const Duration(minutes: 1));
          continue;
        }

        // Skip if a sync is already running (e.g., manual sync from settings)
        if (_isSyncing) {
          _log.info("Sync already in progress, skipping scheduled sync");
          await Future.delayed(Duration(minutes: intervalMinutes));
          continue;
        }

        try {
          await _executeSync();
        } catch (e, stackTrace) {
          _log.warning("Scheduled sync failed, will retry on next interval", e, stackTrace);
        }

        // Wait for configured interval before next sync
        await Future.delayed(Duration(minutes: intervalMinutes));
      }
    }());
  }
  
  /// Triggers a manual sync. If a sync is already running, it will be cancelled first.
  /// Returns a Future that completes when the new sync is done.
  Future<void> triggerSync() async {
    _log.info("Manual sync triggered");
    
    // If a sync is already running, request cancellation and wait for it
    if (_isSyncing) {
      _log.info("Cancelling current sync...");
      _cancelRequested = true;
      
      // Wait for the current sync to finish
      if (_currentSyncCompleter != null) {
        await _currentSyncCompleter!.future;
      }
    }
    
    // Now execute the new sync
    await _executeSync();
  }
  
  /// Internal method that actually executes the sync
  Future<void> _executeSync() async {
    // Skip sync if storage is read-only (external user folder)
    if (_storageProvider.isReadOnly) {
      _log.info("Storage is read-only (local folder mode), skipping sync");
      return;
    }
    
    if (_isSyncing) return; // Double-check
    
    _cancelRequested = false;
    _currentSyncCompleter = Completer<void>();
    _updateSyncState(
      isSyncing: true,
      clearProgress: true,
      clearStatus: true,
    );
    
    final deleteOrphaned = _configProvider.deleteOrphanedFiles;
    
    try {
      // Create a fresh SyncProvider with current config settings
      final syncProvider = _syncProviderFactory();
      _log.info("Starting sync (delete orphaned: $deleteOrphaned)");
      await syncProvider.sync(
        deleteOrphanedFiles: deleteOrphaned,
        onProgress: (progress) {
          _updateSyncState(progress: progress);
        },
      );
      
      // Save timestamp of successful sync
      _configProvider.lastSuccessfulSync = DateTime.now();
      await _configProvider.save();
      
      _log.info("Sync completed successfully");
      var imageCount = 0;
      var videoCount = 0;
      try {
        final localDir = await _storageProvider.getPhotoDirectory();
        if (await localDir.exists()) {
          final files = localDir.listSync(recursive: true, followLinks: false).whereType<File>();
          for (final file in files) {
            final path = file.path.toLowerCase();
            if (path.endsWith(".jpg") || path.endsWith(".jpeg") || path.endsWith(".png") || path.endsWith(".webp")) {
              imageCount++;
            } else if (path.endsWith(".mp4") || path.endsWith(".webm") || path.endsWith(".mkv") || path.endsWith(".mov") || path.endsWith(".m4v")) {
              videoCount++;
}
          }
        }
      } catch (e) {
        _log.warning("Failed to count synced files", e);
      }
      final summary = "Synced successfully!\nAvailable locally: $imageCount images, $videoCount videos";
      _updateSyncState(status: SyncStatus.success(summary: summary));
      // Repository watcher will pick up changes automatically
    } catch (e, stackTrace) {
      if (_cancelRequested) {
        _log.info("Sync was cancelled");
        _updateSyncState(status: const SyncStatus.cancelled());
      } else {
        _log.warning("Sync failed", e, stackTrace);
        _updateSyncState(status: SyncStatus.error(e));
        rethrow;
      }
    } finally {
      _cancelRequested = false;
      _currentSyncCompleter?.complete();
      _currentSyncCompleter = null;
      _updateSyncState(isSyncing: false, clearProgress: true);
    }
  }

  Future<void> _loadSmbList() async {
    try {
      final dir = await _storageProvider.getPhotoDirectory();
      final listFile = File('${dir.parent.path}${Platform.pathSeparator}smb_list.json');
      if (await listFile.exists()) {
        final content = await listFile.readAsString();
        final decoded = jsonDecode(content) as List<dynamic>;
        _smbList = decoded.map((item) => Map<String, dynamic>.from(item as Map)).toList();
        _log.info('Loaded SMB_List: ${_smbList.length} items');
      } else {
        _smbList = [];
        _log.info('No smb_list.json found');
      }
    } catch (e) {
      _log.warning('Error loading SMB_List', e);
      _smbList = [];
    }
  }

  Future<void> _initializePlayingList() async {
    _log.info('Initializing playing list...');
    _playingList.clear();
    _playingIndex = -1;

    if (_smbList.isEmpty) {
      await _loadSmbList();
    }

    if (_smbList.isEmpty) {
      _log.warning('SMB_List is empty, cannot initialize playing list.');
      return;
    }

    // Filter out history_list
    var available = _smbList.where((item) => !_historyList.contains(item['relativePath'])).toList();

    // If available is empty, clear history and restart
    if (available.isEmpty) {
      _log.info('All items in SMB_List have been played. Clearing history_list for a new cycle.');
      _historyList.clear();
      available = List.from(_smbList);
    }

    // Shuffle and pick up to 200
    available.shuffle();
    final count = available.length < 200 ? available.length : 200;
    _playingList.addAll(available.take(count));

    // Mark these as in history list
    for (final item in _playingList) {
      _historyList.add(item['relativePath'] as String);
    }

    _log.info('Initialized playing_list with ${_playingList.length} items. history_list size: ${_historyList.length}');
    
    // Trigger background preload of the playing_list items
    _triggerBackgroundPreload();
  }

  Future<void> _preloadItem(Map<String, dynamic> item) async {
    final relativePath = item['relativePath'] as String;
    final remotePath = item['remotePath'] as String;
    final size = item['size'] as int?;

    try {
      final localDir = await _storageProvider.getPhotoDirectory();
      final localFile = File('${localDir.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}');
      
      // Check if it's already downloaded and matches size
      if (await localFile.exists() && (size == null || await localFile.length() == size)) {
        return; // Already cached
      }

      await localFile.parent.create(recursive: true);
      final partFile = File('${localFile.path}.part');
      if (await partFile.exists()) {
        await partFile.delete();
      }

      final configMap = _configProvider.getSourceConfig('smb');
      final client = SmbNativeClient();
      await client.downloadFile(
        config: configMap,
        remotePath: remotePath,
        localPath: partFile.path,
      );

      if (await localFile.exists()) {
        await localFile.delete();
      }
      await partFile.rename(localFile.path);
      
      if (item['modifiedAt'] != null) {
        final modTime = DateTime.parse(item['modifiedAt'] as String);
        await localFile.setLastModified(modTime);
      }
      _log.info('Preloaded: $relativePath');
    } catch (e) {
      _log.warning('Failed to preload $relativePath', e);
      rethrow;
    }
  }

  void _triggerBackgroundPreload() {
    if (_isPreloading) return;
    _isPreloading = true;

    unawaited(() async {
      _log.info('Starting background preload task...');
      while (_isPreloading) {
        if (_configProvider.activeSourceType != 'smb' || _playingList.isEmpty) {
          _isPreloading = false;
          break;
        }

        // We want to preload the next 5 items from the current playing index
        int start = _playingIndex + 1;
        if (start < 0) start = 0;

        bool workDone = false;
        // Preload up to 5 items ahead of the current position
        for (int i = start; i < start + 5 && i < _playingList.length; i++) {
          final item = _playingList[i];
          try {
            final relativePath = item['relativePath'] as String;
            final localDir = await _storageProvider.getPhotoDirectory();
            final localFile = File('${localDir.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}');
            final size = item['size'] as int?;

            if (!await localFile.exists() || (size != null && await localFile.length() != size)) {
              await _preloadItem(item);
              _smbNetworkError = false; // Reset error flag upon successful download
              workDone = true;
              // Brief delay to avoid CPU/IO starvation
              await Future.delayed(const Duration(milliseconds: 100));
            }
          } catch (e) {
            _log.warning('Preload error at index $i, setting network error flag', e);
            _smbNetworkError = true;
            // Network error occurred. Sleep longer before retrying to prevent rapid failure loops
            await Future.delayed(const Duration(seconds: 10));
            break;
          }
        }

        if (!workDone) {
          // No immediate preload needed, sleep for a bit
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }());
  }

  Future<void> _checkAndTriggerPreloadAndCleanup() async {
    final triggerThreshold = (_playingList.length * 0.75).round() - 1; // 149 for 200
    
    if (_playingIndex == triggerThreshold) {
      _log.info('Reached 75% of playing_list ($_playingIndex). Triggering batch preload...');
      
      unawaited(() async {
        try {
          if (_smbList.isEmpty) {
            await _loadSmbList();
          }

          // 1. Filter out history_list
          var available = _smbList.where((item) => !_historyList.contains(item['relativePath'])).toList();

          // 2. If available is empty, clear history and restart
          if (available.isEmpty) {
            _log.info('All items in SMB_List have been played. Clearing history_list for a new cycle.');
            _historyList.clear();
            available = List.from(_smbList);
          }

          // 3. Shuffle and pick 100
          available.shuffle();
          final appendCount = available.length < 100 ? available.length : 100;
          final appendItems = available.take(appendCount).toList();

          // 4. Append to playing_list
          _playingList.addAll(appendItems);

          // 5. Add to history_list
          for (final item in appendItems) {
            _historyList.add(item['relativePath'] as String);
          }

          _log.info('Appended $appendCount items to playing_list. New total length: ${_playingList.length}');
          
          // 6. Safe Delete: Eliminate physical cache of played files (0 to 100)
          final localDir = await _storageProvider.getPhotoDirectory();
          int deleteCount = 0;
          for (int i = 0; i < 100 && i < _playingList.length; i++) {
            final itemToDelete = _playingList[i];
            final relPath = itemToDelete['relativePath'] as String;
            final fileToDelete = File('${localDir.path}${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}');
            if (await fileToDelete.exists()) {
              try {
                await fileToDelete.delete();
                deleteCount++;
              } catch (e) {
                _log.warning('Failed to delete physical file for $relPath', e);
              }
            }
          }
          _log.info('Successfully evicted $deleteCount played cached files from local storage.');

        } catch (e, stack) {
          _log.warning('Error in background batch preload/cleanup', e, stack);
        }
      }());
    }
  }

  PhotoEntry? _getDownloadedFallbackPhoto() {
    if (_localDirPath == null || _playingList.isEmpty) return null;
    
    final availableCached = <Map<String, dynamic>>[];
    final startIdx = _playingList.length > 100 ? _playingList.length - 100 : 0;
    
    for (int i = _playingList.length - 1; i >= startIdx; i--) {
      final item = _playingList[i];
      final relPath = item['relativePath'] as String;
      final file = File('$_localDirPath${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}');
      if (file.existsSync() && file.lengthSync() > 0) {
        availableCached.add(item);
        if (availableCached.length >= 50) break;
      }
    }

    if (availableCached.isEmpty) {
      for (final item in _playingList) {
        final relPath = item['relativePath'] as String;
        final file = File('$_localDirPath${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}');
        if (file.existsSync() && file.lengthSync() > 0) {
          availableCached.add(item);
        }
      }
    }

    if (availableCached.isNotEmpty) {
      final randomIndex = DateTime.now().millisecondsSinceEpoch % availableCached.length;
      final item = availableCached[randomIndex];
      _log.info('Fallback loop picked: ${item['relativePath']}');
      
      final relPath = item['relativePath'] as String;
      final file = File('$_localDirPath${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}');
      return PhotoEntry(
        file: file,
        date: item['modifiedAt'] != null ? DateTime.parse(item['modifiedAt'] as String) : DateTime.now(),
        sizeBytes: item['size'] as int? ?? 0,
        mediaType: relPath.toLowerCase().endsWith('.mp4') || relPath.toLowerCase().endsWith('.mov')
            ? MediaType.video
            : MediaType.image,
      );
    }
    return null;
  }

  PhotoEntry? nextPhoto() {
    if (_configProvider.activeSourceType == 'smb') {
      if (_playingList.isEmpty) {
        _initializePlayingList();
        return _getDownloadedFallbackPhoto();
      }

      _playingIndex++;
      
      if (_playingIndex >= _playingList.length) {
        _playingIndex = _playingList.length > 50 ? _playingList.length - 50 : 0;
        final fallback = _getDownloadedFallbackPhoto();
        if (fallback != null) return fallback;
      }

      final item = _playingList[_playingIndex];
      final relPath = item['relativePath'] as String;
      final file = File('$_localDirPath${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}');

      if (file.existsSync() && file.lengthSync() > 0) {
        _checkAndTriggerPreloadAndCleanup();
        
        return PhotoEntry(
          file: file,
          date: item['modifiedAt'] != null ? DateTime.parse(item['modifiedAt'] as String) : DateTime.now(),
          sizeBytes: item['size'] as int? ?? 0,
          mediaType: relPath.toLowerCase().endsWith('.mp4') || relPath.toLowerCase().endsWith('.mov')
              ? MediaType.video
              : MediaType.image,
        );
      } else {
        _log.warning('Photo at playing index $_playingIndex is not physically downloaded yet: $relPath');
        final fallback = _getDownloadedFallbackPhoto();
        if (fallback != null) {
          return fallback;
        }
      }
    }

    // Default non-SMB modes
    if (_historyIndex < _history.length - 1) {
      _historyIndex++;
      return _history[_historyIndex];
    }

    final photos = _repository.photos;
    final photo = _playlistStrategy.nextPhoto(photos);
    
    if (photo != null) {
      photo.lastShown = DateTime.now();
      _history.add(photo);
      _historyIndex++;
      
      if (_history.length > 50) {
        _history.removeAt(0);
        _historyIndex--;
      }
    }
    return photo;
  }

  PhotoEntry? previousPhoto() {
    if (_configProvider.activeSourceType == 'smb') {
      if (_playingList.isEmpty || _playingIndex <= 0) {
        return _playingList.isNotEmpty ? _getDownloadedFallbackPhoto() : null;
      }
      _playingIndex--;
      final item = _playingList[_playingIndex];
      final relPath = item['relativePath'] as String;
      final file = File('$_localDirPath${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}');
      if (file.existsSync() && file.lengthSync() > 0) {
        return PhotoEntry(
          file: file,
          date: item['modifiedAt'] != null ? DateTime.parse(item['modifiedAt'] as String) : DateTime.now(),
          sizeBytes: item['size'] as int? ?? 0,
          mediaType: relPath.toLowerCase().endsWith('.mp4') || relPath.toLowerCase().endsWith('.mov')
              ? MediaType.video
              : MediaType.image,
        );
      }
      return _getDownloadedFallbackPhoto();
    }

    if (_historyIndex > 0) {
      _historyIndex--;
      return _history[_historyIndex];
    }
    return _history.isNotEmpty ? _history[_historyIndex] : null;
  }
  
  /// Check if a photo is still in the current photo list
  bool containsPhoto(PhotoEntry photo) {
    if (_configProvider.activeSourceType == 'smb') {
      return _playingList.any((item) {
        final relPath = item['relativePath'] as String;
        return photo.file.path.endsWith(relPath.replaceAll('/', Platform.pathSeparator));
      });
    }
    return _repository.photos.any((p) => p.file.path == photo.file.path);
  }
  
  @override
  void dispose() {
    _syncLoopRunning = false;
    _directoryChangeSubscription?.cancel();
    _repository.dispose();
    super.dispose();
  }
}


