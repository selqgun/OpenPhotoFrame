import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/interfaces/config_provider.dart';
import 'native_updater_service.dart';

/// A release available on GitHub.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.downloadUrl,
    required this.assetName,
    this.releaseNotes,
  });

  /// Semantic version without leading 'v' (e.g. "1.11.0").
  final String version;
  final String tag;
  final String downloadUrl;
  final String assetName;
  final String? releaseNotes;
}

typedef UpdatePromptCallback = void Function(UpdateInfo info);

/// Opt-in self-update against GitHub releases.
///
/// Checks at most once per [_checkInterval], compares against the installed
/// version, and either installs silently (Device Owner + opt-in) or asks the
/// UI to prompt the user. Not included in Play Store builds.
class UpdateService extends ChangeNotifier {
  UpdateService({
    required ConfigProvider configProvider,
    Dio? dio,
  })  : _config = configProvider,
        _dio = dio ?? Dio();

  static const _owner = 'micw';
  static const _repo = 'OpenPhotoFrame';
  static const _checkInterval = Duration(hours: 8);

  final ConfigProvider _config;
  final Dio _dio;
  final _log = Logger('UpdateService');

  Timer? _timer;
  bool _busy = false;

  /// Invoked when a (non-silent) update should be presented to the user.
  UpdatePromptCallback? onUpdateAvailable;

  double? _downloadProgress;
  double? get downloadProgress => _downloadProgress;

  bool _installing = false;
  bool get isInstalling => _installing;

  void start() {
    if (!Platform.isAndroid) return;
    _timer?.cancel();
    _timer = Timer.periodic(_checkInterval, (_) => _maybeCheck());
    unawaited(_maybeCheck(initial: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _maybeCheck({bool initial = false}) async {
    if (!_config.autoUpdateEnabled) return;
    // Respect the 8h window across app restarts: skip the startup check if we
    // already checked recently.
    if (initial) {
      final last = _config.autoUpdateLastCheck;
      if (last != null && DateTime.now().difference(last) < _checkInterval) {
        return;
      }
    }
    await checkForUpdate();
  }

  /// Checks GitHub for a newer release. Returns the update if a newer one is
  /// available (and not skipped), else null. Triggers the silent install or the
  /// prompt callback as configured.
  Future<UpdateInfo?> checkForUpdate({bool manual = false}) async {
    if (!Platform.isAndroid) return null;
    if (!manual && !_config.autoUpdateEnabled) return null;
    if (_busy) return null;
    _busy = true;
    try {
      final info = await _fetchLatest();
      _config.autoUpdateLastCheck = DateTime.now();
      await _config.save();
      if (info == null) return null;

      final pkg = await PackageInfo.fromPlatform();
      if (_compareVersions(info.version, pkg.version) <= 0) {
        _log.info(
          'No newer release (current ${pkg.version}, latest ${info.version})',
        );
        return null;
      }
      if (!manual && _config.autoUpdateSkippedVersion == info.version) {
        _log.info('Update ${info.version} was skipped by user');
        return null;
      }

      if (_config.autoUpdateSilent && await NativeUpdaterService.isDeviceOwner()) {
        _log.info('Silently updating to ${info.version}');
        await downloadAndInstall(info);
      } else {
        onUpdateAvailable?.call(info);
      }
      return info;
    } catch (e, st) {
      _log.warning('Update check failed', e, st);
      return null;
    } finally {
      _busy = false;
    }
  }

  Future<UpdateInfo?> _fetchLatest() async {
    final res = await _dio.get(
      'https://api.github.com/repos/$_owner/$_repo/releases/latest',
      options: Options(
        responseType: ResponseType.json,
        headers: {'Accept': 'application/vnd.github+json'},
      ),
    );

    final data = res.data as Map<String, dynamic>;
    final tag = '${data['tag_name'] ?? ''}';
    if (tag.isEmpty) return null;
    final version = tag.startsWith('v') ? tag.substring(1) : tag;

    final assets = (data['assets'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final abis = await NativeUpdaterService.getSupportedAbis();
    final asset = _pickAsset(assets, abis);
    if (asset == null) {
      _log.warning('No installable APK asset found in latest release');
      return null;
    }

    return UpdateInfo(
      version: version,
      tag: tag,
      downloadUrl: '${asset['browser_download_url']}',
      assetName: '${asset['name']}',
      releaseNotes: data['body'] as String?,
    );
  }

  /// Picks the APK asset matching the device ABI, falling back to a universal
  /// APK (no ABI tag) and finally the first APK.
  Map<String, dynamic>? _pickAsset(
    List<Map<String, dynamic>> assets,
    List<String> abis,
  ) {
    final apks = assets
        .where((a) => '${a['name']}'.toLowerCase().endsWith('.apk'))
        .toList();
    if (apks.isEmpty) return null;

    for (final abi in abis) {
      for (final apk in apks) {
        if ('${apk['name']}'.toLowerCase().contains(abi.toLowerCase())) {
          return apk;
        }
      }
    }
    for (final apk in apks) {
      final name = '${apk['name']}'.toLowerCase();
      if (!name.contains('arm') && !name.contains('x86')) return apk;
    }
    return apks.first;
  }

  /// Compares two dotted versions. Returns >0 if [a] is newer than [b].
  int _compareVersions(String a, String b) {
    List<int> parse(String v) => v
        .split(RegExp(r'[+\- ]'))
        .first
        .split('.')
        .map((part) => int.tryParse(part.trim()) ?? 0)
        .toList();

    final pa = parse(a);
    final pb = parse(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// Remembers [info] as skipped so it is not prompted again.
  Future<void> skip(UpdateInfo info) async {
    _config.autoUpdateSkippedVersion = info.version;
    await _config.save();
  }

  /// Downloads the APK and triggers installation (silent or prompted).
  Future<bool> downloadAndInstall(UpdateInfo info) async {
    if (_installing) return false;
    _installing = true;
    _downloadProgress = 0;
    notifyListeners();
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${info.assetName}');
      await _dio.download(
        info.downloadUrl,
        file.path,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            _downloadProgress = received / total;
            notifyListeners();
          }
        },
      );
      _downloadProgress = null;
      notifyListeners();
      return await NativeUpdaterService.installApk(file.path);
    } catch (e, st) {
      _log.warning('Download/install failed', e, st);
      return false;
    } finally {
      _installing = false;
      _downloadProgress = null;
      notifyListeners();
    }
  }
}
