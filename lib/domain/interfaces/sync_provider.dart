class SyncProgress {
  const SyncProgress({
    required this.completedFiles,
    required this.totalFiles,
    this.currentFileLabel,
    this.folders = const <SyncFolderProgress>[],
  });

  final int completedFiles;
  final int totalFiles;
  final String? currentFileLabel;

  /// Per-folder breakdown of the pending downloads (one entry per folder that
  /// has files to download in this sync run). Empty when nothing is pending.
  final List<SyncFolderProgress> folders;

  double? get fraction {
    if (totalFiles <= 0) {
      return null;
    }

    return completedFiles.clamp(0, totalFiles) / totalFiles;
  }

  String get counterLabel {
    if (totalFiles <= 0) {
      return '0 / 0';
    }

    final currentIndex = completedFiles >= totalFiles
        ? totalFiles
        : completedFiles + 1;
    return '$currentIndex / $totalFiles';
  }
}

/// Download progress for a single folder within a sync run.
class SyncFolderProgress {
  const SyncFolderProgress({
    required this.folderPath,
    required this.completedFiles,
    required this.totalFiles,
  });

  /// Relative folder path (empty string for the share root).
  final String folderPath;
  final int completedFiles;
  final int totalFiles;

  double? get fraction {
    if (totalFiles <= 0) {
      return null;
    }

    return completedFiles.clamp(0, totalFiles) / totalFiles;
  }

  String get counterLabel => '$completedFiles / $totalFiles';
}

typedef SyncProgressCallback = void Function(SyncProgress progress);

abstract class SyncProvider {
  /// Starts the synchronization process.
  /// If [deleteOrphanedFiles] is true, local files not present on the server will be deleted.
  Future<void> sync({
    bool deleteOrphanedFiles = false,
    SyncProgressCallback? onProgress,
  });
  
  /// Returns a unique identifier for this provider (e.g. "nextcloud")
  String get id;
}
