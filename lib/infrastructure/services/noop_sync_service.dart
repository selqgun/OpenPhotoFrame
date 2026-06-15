import 'package:logging/logging.dart';
import '../../domain/interfaces/sync_provider.dart';

class NoOpSyncService implements SyncProvider {
  final _log = Logger('NoOpSyncService');

  @override
  String get id => 'noop';

  @override
  Future<void> sync({
    bool deleteOrphanedFiles = false,
    SyncProgressCallback? onProgress,
  }) async {
    _log.info("No sync source configured. Skipping sync.");
  }
}
