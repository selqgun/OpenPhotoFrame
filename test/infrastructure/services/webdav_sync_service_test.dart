import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:open_photo_frame/domain/interfaces/storage_provider.dart';
import 'package:open_photo_frame/infrastructure/services/webdav_remote_client.dart';
import 'package:open_photo_frame/infrastructure/services/webdav_source_config.dart';
import 'package:open_photo_frame/infrastructure/services/webdav_sync_service.dart';

class FakeStorageProvider implements StorageProvider {
  FakeStorageProvider(this.directory);

  final Directory directory;

  @override
  Future<Directory> getPhotoDirectory() async => directory;

  @override
  bool get isReadOnly => false;

  @override
  Stream<void> get onDirectoryChanged => const Stream.empty();
}

class FakeWebDavRemoteClient implements WebDavRemoteClient {
  FakeWebDavRemoteClient({
    Map<String, List<WebDavRemoteEntry>> directories = const {},
    Map<String, List<int>> fileContents = const {},
    this.readDirError,
  })  : _directories = directories,
        _fileContents = fileContents;

  final Map<String, List<WebDavRemoteEntry>> _directories;
  final Map<String, List<int>> _fileContents;
  final Object? readDirError;
  final List<String> readDirCalls = [];
  final List<String> downloadedPaths = [];

  @override
  Future<List<WebDavRemoteEntry>> readDir(String path) async {
    readDirCalls.add(path);
    if (readDirError != null) {
      throw readDirError!;
    }
    return List<WebDavRemoteEntry>.from(_directories[path] ?? const []);
  }

  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath, {
    void Function(int count, int total)? onProgress,
    Duration? idleTimeout,
  }) async {
    downloadedPaths.add(remotePath);
    final file = File(localPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      _fileContents[remotePath] ?? utf8.encode('download:$remotePath'),
    );
  }
}

void main() {
  group('WebDavSourceConfig', () {
    test('normalizes root and nested folders', () {
      final config = WebDavSourceConfig.fromMap({
        'url': 'https://cloud.example.com/s/abc',
        'folder_sync_mode': 'selected',
        'selected_folders': ['/', 'albums//summer/'],
      });

      expect(config.syncAllFolders, isFalse);
      expect(config.normalizedSelectedFolders, {'', 'albums/summer'});
      expect(config.includesDirectory(''), isTrue);
      expect(config.includesDirectory('albums/summer'), isTrue);
      expect(config.includesDirectory('albums'), isFalse);
      expect(config.includesRelativeFile('albums/summer/photo.jpg'), isTrue);
      expect(config.includesRelativeFile('albums/photo.jpg'), isFalse);
    });

    test('splitInlineCredentials extracts user:pass@host', () {
      final split = WebDavSourceConfig.splitInlineCredentials(
        'https://alice:s3cr%40t@cloud.example.com/dav/',
      );
      expect(split.url, 'https://cloud.example.com/dav/');
      expect(split.username, 'alice');
      expect(split.password, 's3cr@t'); // %40 decoded
    });

    test('splitInlineCredentials leaves plain URLs untouched', () {
      final split = WebDavSourceConfig.splitInlineCredentials(
        'https://cloud.example.com/dav/',
      );
      expect(split.url, 'https://cloud.example.com/dav/');
      expect(split.username, isNull);
      expect(split.password, isNull);
    });

    test('resolveTarget uses url + credentials in userPassword mode', () {
      const config = WebDavSourceConfig(
        url: 'https://cloud.example.com/remote.php/dav/files/bob/',
        authMode: WebDavAuthMode.userPassword,
        username: 'bob',
        password: 'pw',
      );
      final target = WebDavSyncService.resolveTarget(config);
      expect(target.webDavUrl, 'https://cloud.example.com/remote.php/dav/files/bob/');
      expect(target.user, 'bob');
      expect(target.password, 'pw');
    });

    test('resolveTarget derives webdav endpoint from a public share link', () {
      const config = WebDavSourceConfig(
        url: 'https://cloud.example.com/s/abc123',
      );
      final target = WebDavSyncService.resolveTarget(config);
      expect(target.webDavUrl, 'https://cloud.example.com/public.php/webdav');
      expect(target.user, 'abc123');
      expect(target.password, '');
    });
  });

  group('WebDavSyncService', () {
    late Directory tempDir;
    late FakeStorageProvider storageProvider;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nextcloud_sync_test_');
      storageProvider = FakeStorageProvider(tempDir);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('fromPublicLink extracts webdav url and token', () {
      final service = WebDavSyncService.fromPublicLink(
        'https://cloud.example.com/s/abc123',
        storageProvider,
        clientFactory: ({
          required String webDavUrl,
          required String user,
          required String password,
        }) {
          return FakeWebDavRemoteClient();
        },
      );

      expect(service.webDavUrl, 'https://cloud.example.com/public.php/webdav');
      expect(service.user, 'abc123');
      expect(service.password, '');
    });

    test('testConnection lists the root directory', () async {
      final client = FakeWebDavRemoteClient(
        directories: {
          '/': const [
            WebDavRemoteEntry(
              path: '/folder/',
              name: 'folder',
              isDirectory: true,
            ),
          ],
        },
      );

      final error = await WebDavSyncService.testConnection(
        const WebDavSourceConfig(url: 'https://cloud.example.com/s/abc123'),
        clientFactory: ({
          required String webDavUrl,
          required String user,
          required String password,
        }) {
          expect(webDavUrl, 'https://cloud.example.com/public.php/webdav');
          expect(user, 'abc123');
          expect(password, '');
          return client;
        },
      );

      expect(error, isNull);
      expect(client.readDirCalls, ['/']);
    });

    test('listAvailableFolders returns root and nested folders', () async {
      final client = FakeWebDavRemoteClient(
        directories: {
          '/': const [
            WebDavRemoteEntry(
              path: '/albums/',
              name: 'albums',
              isDirectory: true,
            ),
            WebDavRemoteEntry(
              path: '/cover.jpg',
              name: 'cover.jpg',
              isDirectory: false,
            ),
          ],
          '/albums/': const [
            WebDavRemoteEntry(
              path: '/albums/summer/',
              name: 'summer',
              isDirectory: true,
            ),
          ],
          '/albums/summer/': const [],
        },
      );

      final folders = await WebDavSyncService.listAvailableFolders(
        const WebDavSourceConfig(url: 'https://cloud.example.com/s/abc123'),
        clientFactory: ({
          required String webDavUrl,
          required String user,
          required String password,
        }) => client,
      );

      expect(folders.map((folder) => folder.path), ['', 'albums', 'albums/summer']);
      expect(folders.map((folder) => folder.depth), [0, 1, 2]);
    });

    test('sync downloads root and nested images with relative paths', () async {
      final modifiedAt = DateTime(2026, 5, 18, 12, 0);
      final client = FakeWebDavRemoteClient(
        directories: {
          '/': [
            WebDavRemoteEntry(
              path: '/root.jpg',
              name: 'root.jpg',
              isDirectory: false,
              modifiedAt: modifiedAt,
            ),
            const WebDavRemoteEntry(
              path: '/albums/',
              name: 'albums',
              isDirectory: true,
            ),
          ],
          '/albums/': const [
            WebDavRemoteEntry(
              path: '/albums/nested.png',
              name: 'nested.png',
              isDirectory: false,
            ),
            WebDavRemoteEntry(
              path: '/albums/notes.txt',
              name: 'notes.txt',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = WebDavSyncService.fromPublicLink(
        'https://cloud.example.com/s/abc123',
        storageProvider,
        clientFactory: ({
          required String webDavUrl,
          required String user,
          required String password,
        }) => client,
      );

      await service.sync();

      final rootFile = File('${tempDir.path}/root.jpg');
      final nestedFile = File('${tempDir.path}/albums/nested.png');
      expect(await rootFile.exists(), isTrue);
      expect(await nestedFile.exists(), isTrue);
      expect(File('${tempDir.path}/albums/notes.txt').existsSync(), isFalse);
        expect(
          client.downloadedPaths,
          unorderedEquals(['/root.jpg', '/albums/nested.png']),
        );
      expect(await rootFile.lastModified(), modifiedAt);
    });

      test('sync logs download progress counts for pending files only', () async {
        final existingFile = File('${tempDir.path}/already-here.jpg');
        await existingFile.writeAsString('existing');

        final client = FakeWebDavRemoteClient(
          directories: {
            '/': const [
              WebDavRemoteEntry(
                path: '/already-here.jpg',
                name: 'already-here.jpg',
                isDirectory: false,
              ),
              WebDavRemoteEntry(
                path: '/first.jpg',
                name: 'first.jpg',
                isDirectory: false,
              ),
              WebDavRemoteEntry(
                path: '/second.jpg',
                name: 'second.jpg',
                isDirectory: false,
              ),
            ],
          },
        );

        final service = WebDavSyncService.fromPublicLink(
          'https://cloud.example.com/s/abc123',
          storageProvider,
          clientFactory: ({
            required String webDavUrl,
            required String user,
            required String password,
          }) => client,
        );

        final recordedMessages = <String>[];
        Logger.root.level = Level.ALL;
        final subscription = Logger.root.onRecord.listen((record) {
          if (record.loggerName == 'WebDavSyncService') {
            recordedMessages.add(record.message);
          }
        });

        try {
          await service.sync();
        } finally {
          await subscription.cancel();
        }

        expect(client.downloadedPaths, ['/first.jpg', '/second.jpg']);
        expect(
          recordedMessages,
          containsAllInOrder([
            'Downloading 1/2...',
            'Downloading 2/2...',
          ]),
        );
      });

    test('sync only downloads images from selected folders', () async {
      final client = FakeWebDavRemoteClient(
        directories: {
          '/': const [
            WebDavRemoteEntry(
              path: '/root.jpg',
              name: 'root.jpg',
              isDirectory: false,
            ),
            WebDavRemoteEntry(
              path: '/albums/',
              name: 'albums',
              isDirectory: true,
            ),
          ],
          '/albums/': const [
            WebDavRemoteEntry(
              path: '/albums/pick-me.jpg',
              name: 'pick-me.jpg',
              isDirectory: false,
            ),
            WebDavRemoteEntry(
              path: '/albums/sub/',
              name: 'sub',
              isDirectory: true,
            ),
          ],
          '/albums/sub/': const [
            WebDavRemoteEntry(
              path: '/albums/sub/skip-me.jpg',
              name: 'skip-me.jpg',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = WebDavSyncService.fromPublicLink(
        'https://cloud.example.com/s/abc123',
        storageProvider,
        clientFactory: ({
          required String webDavUrl,
          required String user,
          required String password,
        }) => client,
        sourceConfig: const WebDavSourceConfig(
          url: 'https://cloud.example.com/s/abc123',
          folderSyncMode: WebDavFolderSyncMode.selectedFolders,
          selectedFolders: ['albums'],
        ),
      );

      await service.sync();

      expect(File('${tempDir.path}/root.jpg').existsSync(), isFalse);
      expect(File('${tempDir.path}/albums/pick-me.jpg').existsSync(), isTrue);
      expect(File('${tempDir.path}/albums/sub/skip-me.jpg').existsSync(), isFalse);
      expect(client.downloadedPaths, ['/albums/pick-me.jpg']);
    });

    test('sync deletes orphaned files using relative paths', () async {
      final orphanFile = File('${tempDir.path}/albums/orphan.jpg');
      await orphanFile.parent.create(recursive: true);
      await orphanFile.writeAsString('orphan');
      final keepFile = File('${tempDir.path}/albums/keep.jpg');
      await keepFile.writeAsString('old');
      final orphanRootFile = File('${tempDir.path}/root.jpg');
      await orphanRootFile.writeAsString('orphan-root');

      final client = FakeWebDavRemoteClient(
        directories: {
          '/': const [
            WebDavRemoteEntry(
              path: '/albums/',
              name: 'albums',
              isDirectory: true,
            ),
          ],
          '/albums/': const [
            WebDavRemoteEntry(
              path: '/albums/keep.jpg',
              name: 'keep.jpg',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = WebDavSyncService.fromPublicLink(
        'https://cloud.example.com/s/abc123',
        storageProvider,
        clientFactory: ({
          required String webDavUrl,
          required String user,
          required String password,
        }) => client,
      );

      await service.sync(deleteOrphanedFiles: true);

      expect(keepFile.existsSync(), isTrue);
      expect(orphanFile.existsSync(), isFalse);
      expect(orphanRootFile.existsSync(), isFalse);
    });
  });
}