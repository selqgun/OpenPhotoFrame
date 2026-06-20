import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

class NextcloudPublicShare {
  const NextcloudPublicShare({
    required this.webDavUrl,
    required this.user,
    this.password = '',
  });

  final String webDavUrl;
  final String user;
  final String password;

  factory NextcloudPublicShare.fromPublicLink(String link) {
    if (link.isEmpty) {
      throw ArgumentError('Nextcloud public link cannot be empty');
    }

    final uri = Uri.parse(link);
    if (uri.pathSegments.isEmpty) {
      throw ArgumentError('Invalid Nextcloud public link: no path segments');
    }

    final token = uri.pathSegments.last;
    final baseUrl = '${uri.scheme}://${uri.host}/public.php/webdav';

    return NextcloudPublicShare(
      webDavUrl: baseUrl,
      user: token,
    );
  }
}

class WebDavRemoteEntry {
  const WebDavRemoteEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.modifiedAt,
    this.sizeBytes,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final DateTime? modifiedAt;
  final int? sizeBytes;
}

abstract class WebDavRemoteClient {
  Future<List<WebDavRemoteEntry>> readDir(String path);

  Future<void> downloadFile(
    String remotePath,
    String localPath, {
    void Function(int count, int total)? onProgress,
    Duration? idleTimeout,
  });
}

typedef WebDavRemoteClientFactory = WebDavRemoteClient Function({
  required String webDavUrl,
  required String user,
  required String password,
  bool allowInvalidCertificate,
});

WebDavRemoteClient createWebDavRemoteClientImpl({
  required String webDavUrl,
  required String user,
  required String password,
  bool allowInvalidCertificate = false,
}) {
  return WebDavRemoteClientImpl(
    webDavUrl: webDavUrl,
    user: user,
    password: password,
    allowInvalidCertificate: allowInvalidCertificate,
  );
}

class WebDavRemoteClientImpl implements WebDavRemoteClient {
  static const Duration _defaultConnectTimeout = Duration(minutes: 2);

  WebDavRemoteClientImpl({
    required String webDavUrl,
    required String user,
    required String password,
    bool allowInvalidCertificate = false,
  }) : _client = webdav.newClient(
          webDavUrl,
          user: user,
          password: password,
          debug: false,
        ) {
    if (allowInvalidCertificate) {
      // Opt-in: trust self-signed/invalid TLS certs for this WebDAV server.
      // Scoped to this client only; the GitHub updater stays strict.
      _client.c.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()
          ..badCertificateCallback = (cert, host, port) => true,
      );
    }
  }

  final webdav.Client _client;

  @override
  Future<List<WebDavRemoteEntry>> readDir(String path) async {
    _client.setConnectTimeout(_defaultConnectTimeout.inMilliseconds);
    final entries = await _client.readDir(path);
    return entries
        .map(
          (entry) => WebDavRemoteEntry(
            path: entry.path ?? '',
            name: entry.name ?? '',
            isDirectory: entry.isDir == true,
            modifiedAt: entry.mTime,
            sizeBytes: entry.size,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath, {
    void Function(int count, int total)? onProgress,
    Duration? idleTimeout,
  }) async {
    _client.setConnectTimeout(_defaultConnectTimeout.inMilliseconds);
    _client.setReceiveTimeout(0);

    final cancelToken = CancelToken();
    Timer? idleTimer;

    void restartIdleTimer() {
      final timeout = idleTimeout;
      if (timeout == null) {
        return;
      }

      idleTimer?.cancel();
      idleTimer = Timer(timeout, () {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel(
            'Download stalled for ${timeout.inMinutes} minutes while fetching $remotePath',
          );
        }
      });
    }

    restartIdleTimer();

    try {
      await _client.read2File(
        remotePath,
        localPath,
        cancelToken: cancelToken,
        onProgress: (count, total) {
          restartIdleTimer();
          onProgress?.call(count, total);
        },
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        throw TimeoutException(
          idleTimeout == null
              ? 'Download was cancelled'
              : 'Download stalled for more than ${idleTimeout.inMinutes} minutes',
          idleTimeout,
        );
      }
      rethrow;
    } finally {
      idleTimer?.cancel();
    }
  }
}