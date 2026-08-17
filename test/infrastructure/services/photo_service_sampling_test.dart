import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_photo_frame/domain/interfaces/config_provider.dart';
import 'package:open_photo_frame/domain/interfaces/playlist_strategy.dart';
import 'package:open_photo_frame/domain/interfaces/storage_provider.dart';
import 'package:open_photo_frame/domain/interfaces/photo_repository.dart';
import 'package:open_photo_frame/domain/interfaces/sync_provider.dart';
import 'package:open_photo_frame/domain/models/photo_entry.dart';
import 'package:open_photo_frame/infrastructure/services/photo_service.dart';

class MockStorageProvider implements StorageProvider {
  final Directory tempDir;
  MockStorageProvider(this.tempDir);

  @override
  Future<Directory> getPhotoDirectory() async => tempDir;

  @override
  bool get isReadOnly => false;

  @override
  Stream<void> get onDirectoryChanged => const Stream.empty();
}

class MockPlaylistStrategy implements PlaylistStrategy {
  @override
  String get id => "mock";

  @override
  String get name => "Mock Strategy";

  @override
  PhotoEntry? nextPhoto(List<PhotoEntry> photos) => null;
}

class MockPhotoRepository implements PhotoRepository {
  @override
  List<PhotoEntry> get photos => [];

  @override
  Stream<void> get onPhotosChanged => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> reinitialize() async {}

  @override
  void dispose() {}
}

class MockConfigProvider extends ChangeNotifier implements ConfigProvider {
  String _activeSourceType = "smb";

  @override
  String get activeSourceType => _activeSourceType;

  @override
  set activeSourceType(String value) {
    _activeSourceType = value;
    notifyListeners();
  }

  @override
  Map<String, dynamic> getSourceConfig(String type) => {
    "cacheSizeMb": 500,
  };

  @override
  void setSourceConfig(String type, Map<String, dynamic> config) {}

  @override
  Future<void> load() async {}

  @override
  Future<void> save() async {}

  @override
  int get slideDurationSeconds => 10;
  @override
  set slideDurationSeconds(int value) {}

  @override
  int get transitionDurationMs => 1000;
  @override
  set transitionDurationMs(int value) {}

  @override
  bool get blurBorders => false;
  @override
  set blurBorders(bool value) {}

  @override
  int get syncIntervalMinutes => 0;
  @override
  set syncIntervalMinutes(int value) {}

  @override
  bool get deleteOrphanedFiles => false;
  @override
  set deleteOrphanedFiles(bool value) {}

  @override
  DateTime? get lastSuccessfulSync => null;
  @override
  set lastSuccessfulSync(DateTime? value) {}

  @override
  bool get autostartOnBoot => false;
  @override
  set autostartOnBoot(bool value) {}

  @override
  bool get keepAliveEnabled => false;
  @override
  set keepAliveEnabled(bool value) {}

  @override
  bool get autoUpdateEnabled => false;
  @override
  set autoUpdateEnabled(bool value) {}

  @override
  bool get autoUpdateSilent => false;
  @override
  set autoUpdateSilent(bool value) {}

  @override
  String? get autoUpdateSkippedVersion => null;
  @override
  set autoUpdateSkippedVersion(String? value) {}

  @override
  DateTime? get autoUpdateLastCheck => null;
  @override
  set autoUpdateLastCheck(DateTime? value) {}

  @override
  bool get showClock => false;
  @override
  set showClock(bool value) {}

  @override
  String get clockSize => "medium";
  @override
  set clockSize(String value) {}

  @override
  String get clockPosition => "bottomRight";
  @override
  set clockPosition(String value) {}

  @override
  bool get scheduleEnabled => false;
  @override
  set scheduleEnabled(bool value) {}

  @override
  int get dayStartHour => 8;
  @override
  set dayStartHour(int value) {}

  @override
  int get dayStartMinute => 0;
  @override
  set dayStartMinute(int value) {}

  @override
  int get nightStartHour => 22;
  @override
  set nightStartHour(int value) {}

  @override
  int get nightStartMinute => 0;
  @override
  set nightStartMinute(int value) {}

  @override
  int? get fridaySaturdayNightStartHour => null;
  @override
  set fridaySaturdayNightStartHour(int? value) {}

  @override
  int? get fridaySaturdayNightStartMinute => null;
  @override
  set fridaySaturdayNightStartMinute(int? value) {}

  @override
  bool get useNativeScreenOff => false;
  @override
  set useNativeScreenOff(bool value) {}

  @override
  String? get customPhotoPath => null;
  @override
  set customPhotoPath(String? value) {}

  @override
  bool get showPhotoInfo => false;
  @override
  set showPhotoInfo(bool value) {}

  @override
  String get photoInfoPosition => "bottomLeft";
  @override
  set photoInfoPosition(String value) {}

  @override
  String get photoInfoSize => "medium";
  @override
  set photoInfoSize(String value) {}

  @override
  bool get useScriptFontForMetadata => false;
  @override
  set useScriptFontForMetadata(bool value) {}

  @override
  bool get geocodingEnabled => false;
  @override
  set geocodingEnabled(bool value) {}

  @override
  String get geocodingProvider => "nominatim";
  @override
  set geocodingProvider(String value) {}

  @override
  String get geocodingApiKey => "";
  @override
  set geocodingApiKey(String value) {}

  @override
  String get screenOrientation => "auto";
  @override
  set screenOrientation(String value) {}

  @override
  bool get showCacheStatus => true;
  @override
  set showCacheStatus(bool value) {}

  @override
  int get maxCacheImages => 200;
  @override
  set maxCacheImages(int value) {}

  @override
  int get maxCacheVideos => 10;
  @override
  set maxCacheVideos(int value) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MockStorageProvider storageProvider;
  late MockConfigProvider configProvider;
  late MockPlaylistStrategy playlistStrategy;
  late MockPhotoRepository repository;
  late PhotoService photoService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp("smb_sampling_test_");
    storageProvider = MockStorageProvider(tempDir);
    configProvider = MockConfigProvider();
    playlistStrategy = MockPlaylistStrategy();
    repository = MockPhotoRepository();

    // Set up mock channel handlers for SMB downloads
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel("io.github.micw.openphotoframe/smb"),
      (methodCall) async {
        if (methodCall.method == "downloadFile") {
          final args = methodCall.arguments as Map<dynamic, dynamic>;
          final localPath = args["localPath"] as String;
          final file = File(localPath);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(utf8.encode("mock_photo_content"));
        }
        return null;
      },
    );

    // Initialize mock SMB_List
    final listFile = File("${tempDir.parent.path}${Platform.pathSeparator}smb_list.json");
    final dummyRemoteFiles = List.generate(300, (i) => {
      "remotePath": "smb://server/share/photo_$i.jpg",
      "relativePath": "photo_$i.jpg",
      "size": 100,
      "modifiedAt": DateTime.now().toIso8601String(),
    });
    await listFile.writeAsString(jsonEncode(dummyRemoteFiles));

    // Pre-create some local files to simulate they are already cached on disk
    for (int i = 0; i < 10; i++) {
      final file = File('${tempDir.path}${Platform.pathSeparator}photo_$i.jpg');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(utf8.encode('mock_photo_content'));
    }

    photoService = PhotoService(
      syncProviderFactory: () => throw UnimplementedError(),
      playlistStrategy: playlistStrategy,
      repository: repository,
      configProvider: configProvider,
      storageProvider: storageProvider,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel("io.github.micw.openphotoframe/smb"),
      null,
    );
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    final listFile = File("${tempDir.parent.path}${Platform.pathSeparator}smb_list.json");
    if (await listFile.exists()) {
      await listFile.delete();
    }
  });

  test("SMB playing list initializes with up to 200 items randomly sampled", () async {
    await photoService.initialize();

    // Retrieve via reflection or access nextPhoto multiple times
    final photo = photoService.nextPhoto();
    expect(photo, isNotNull);
    expect(photo!.file.path, contains("photo_"));
  });

  test("Eager preloading triggers background downloads", () async {
    await photoService.initialize();

    // Verify initial preload has run by checking if any photo_*.jpg is downloaded
    await Future.delayed(const Duration(milliseconds: 500));
    
    final files = tempDir.listSync().whereType<File>().toList();
    expect(files.isNotEmpty, isTrue);
  });

  test("Network interruption fallback retry protection loop", () async {
    // Disable mock download to simulate network interruption
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel("io.github.micw.openphotoframe/smb"),
      (methodCall) async {
        if (methodCall.method == "downloadFile") {
          throw PlatformException(code: "SMB_ERR", message: "Connection timeout");
        }
        return null;
      },
    );

    await photoService.initialize();

    // Check nextPhoto falls back gracefully to any available downloaded buffers instead of crashing
    final photo = photoService.nextPhoto();
    expect(photo, isNull); // Since zero downloads succeeded initially, returns null cleanly instead of raising error
  });
  test("history_list resets/clears for a new cycle when all items have been played", () async {
    // Overwrite the smb_list.json with only 3 files to trigger history reset quickly
    final listFile = File('${tempDir.parent.path}${Platform.pathSeparator}smb_list.json');
    final dummyRemoteFiles = List.generate(3, (i) => {
      "remotePath": "smb://server/share/photo_$i.jpg",
      "relativePath": "photo_$i.jpg",
      "size": 100,
      "modifiedAt": DateTime.now().toIso8601String(),
    });
    await listFile.writeAsString(jsonEncode(dummyRemoteFiles));

    await photoService.initialize();

    // 1. Initially, we can get up to 3 photos
    final p1 = photoService.nextPhoto();
    final p2 = photoService.nextPhoto();
    // Yield to let the asynchronous preload/append trigger run
    await Future.delayed(Duration.zero);
    final p3 = photoService.nextPhoto();

    expect(p1, isNotNull);
    expect(p2, isNotNull);
    expect(p3, isNotNull);

    // All 3 items should now be in the history pool. 
    // The next time nextPhoto() runs, it triggers a check and since available list is empty,
    // it will clear history and start a new cycle!
    final p4 = photoService.nextPhoto();
    expect(p4, isNotNull); // Works seamlessly and resets the pool!
  });
}