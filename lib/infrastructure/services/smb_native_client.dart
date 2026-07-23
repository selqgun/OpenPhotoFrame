import 'package:flutter/services.dart';

class SmbRemoteEntry {
  const SmbRemoteEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;

  factory SmbRemoteEntry.fromMap(Map<dynamic, dynamic> map) {
    return SmbRemoteEntry(
      path: map['path'] as String? ?? '',
      name: map['name'] as String? ?? '',
      isDirectory: map['isDirectory'] as bool? ?? false,
      size: (map['size'] as num?)?.toInt(),
      modifiedAt: map['modifiedAt'] != null
          ? DateTime.tryParse(map['modifiedAt'] as String)
          : null,
    );
  }
}

class SmbConnectionException implements Exception {
  const SmbConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SmbNativeClient {
  static const MethodChannel _channel = MethodChannel(
    'io.github.micw.openphotoframe/smb',
  );

  Future<void> testConnection(Map<String, dynamic> config) async {
    try {
      await _channel.invokeMethod<void>('testConnection', config);
    } on PlatformException catch (error) {
      throw SmbConnectionException(error.message ?? error.code);
    }
  }

  Future<List<SmbRemoteEntry>> listDirectory({
    required Map<String, dynamic> config,
    required String path,
  }) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('listDirectory', {
        ...config,
        'path': path,
      });
      return (result ?? const <dynamic>[])
          .map((item) => SmbRemoteEntry.fromMap(item as Map<dynamic, dynamic>))
          .toList(growable: false);
    } on PlatformException catch (error) {
      throw SmbConnectionException(error.message ?? error.code);
    }
  }

  Future<void> downloadFile({
    required Map<String, dynamic> config,
    required String remotePath,
    required String localPath,
  }) async {
    try {
      await _channel.invokeMethod<void>('downloadFile', {
        ...config,
        'remotePath': remotePath,
        'localPath': localPath,
      });
    } on PlatformException catch (error) {
      throw SmbConnectionException(error.message ?? error.code);
    }
  }
}
