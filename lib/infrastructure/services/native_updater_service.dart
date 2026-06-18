import 'dart:io';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Thin wrapper around the native updater channel.
///
/// Provides Device Owner detection and APK installation via the Android
/// PackageInstaller (silent when Device Owner, otherwise a system prompt).
class NativeUpdaterService {
  static const _channel = MethodChannel('io.github.micw.openphotoframe/updater');
  static final _log = Logger('NativeUpdaterService');

  static bool get isSupported => Platform.isAndroid;

  /// Whether this app is the Device Owner (enables silent install).
  static Future<bool> isDeviceOwner() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isDeviceOwner') ?? false;
    } catch (e) {
      _log.warning('isDeviceOwner failed', e);
      return false;
    }
  }

  /// The device's supported ABIs, most preferred first (e.g. arm64-v8a).
  static Future<List<String>> getSupportedAbis() async {
    if (!isSupported) return const [];
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getSupportedAbis');
      return result?.map((e) => '$e').toList() ?? const [];
    } catch (e) {
      _log.warning('getSupportedAbis failed', e);
      return const [];
    }
  }

  /// Installs the APK at [path]. Silent when Device Owner, otherwise the
  /// system shows its install confirmation dialog.
  static Future<bool> installApk(String path) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': path}) ??
          false;
    } catch (e) {
      _log.warning('installApk failed', e);
      return false;
    }
  }
}
