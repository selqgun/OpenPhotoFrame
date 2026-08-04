import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../domain/interfaces/config_provider.dart';
import '../../domain/interfaces/storage_provider.dart';
import '../../infrastructure/services/smb_source_config.dart';

/// An overlay widget displaying cache usage (used size, percentage, image & video count).
class CacheStatusOverlay extends StatefulWidget {
  final StorageProvider storageProvider;
  final ConfigProvider configProvider;
  final String position; // 'topLeft', 'topRight', 'bottomLeft', 'bottomRight'

  const CacheStatusOverlay({
    super.key,
    required this.storageProvider,
    required this.configProvider,
    this.position = 'topLeft',
  });

  @override
  State<CacheStatusOverlay> createState() => _CacheStatusOverlayState();
}

class _CacheStatusOverlayState extends State<CacheStatusOverlay> {
  Timer? _refreshTimer;
  int _usedBytes = 0;
  int _imageCount = 0;
  int _videoCount = 0;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _scanCache();
    // Refresh cache statistics every 10 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _scanCache();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  bool _isImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.heic');
  }

  bool _isVideo(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v');
  }

  Future<void> _scanCache() async {
    if (_isScanning) return;
    _isScanning = true;

    try {
      final dir = await widget.storageProvider.getPhotoDirectory();
      if (!await dir.exists()) {
        if (mounted) {
          setState(() {
            _usedBytes = 0;
            _imageCount = 0;
            _videoCount = 0;
          });
        }
        _isScanning = false;
        return;
      }

      int bytes = 0;
      int imgCount = 0;
      int vidCount = 0;

      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final path = entity.path;
          if (path.endsWith('.part')) continue; // Skip incomplete downloads

          if (_isImage(path)) {
            imgCount++;
            bytes += await entity.length();
          } else if (_isVideo(path)) {
            vidCount++;
            bytes += await entity.length();
          }
        }
      }

      if (mounted) {
        setState(() {
          _usedBytes = bytes;
          _imageCount = imgCount;
          _videoCount = vidCount;
        });
      }
    } catch (_) {
      // Ignore transient IO errors during scan
    } finally {
      _isScanning = false;
    }
  }

  int get _maxCacheMb {
    final smbMap = widget.configProvider.getSourceConfig('smb');
    final smbConfig = SmbSourceConfig.fromMap(smbMap);
    return smbConfig.cacheSizeMb > 0 ? smbConfig.cacheSizeMb : 1024;
  }

  Alignment get _alignment {
    switch (widget.position) {
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'bottomRight':
        return Alignment.bottomRight;
      case 'topRight':
        return Alignment.topRight;
      case 'topLeft':
      default:
        return Alignment.topLeft;
    }
  }

  EdgeInsets get _padding {
    const base = 20.0;
    switch (widget.position) {
      case 'bottomLeft':
        return const EdgeInsets.only(left: base, bottom: base);
      case 'bottomRight':
        return const EdgeInsets.only(right: base, bottom: base);
      case 'topRight':
        return const EdgeInsets.only(right: base, top: base);
      case 'topLeft':
      default:
        return const EdgeInsets.only(left: base, top: base);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double usedMb = _usedBytes / (1024 * 1024);
    final int maxMb = _maxCacheMb;
    final double percentage = (maxMb > 0 ? (usedMb / maxMb) * 100 : 0.0).clamp(0.0, 100.0);

    return Align(
      alignment: _alignment,
      child: Padding(
        padding: _padding,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12, width: 0.8),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sd_storage_outlined, color: Colors.white70, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    '${usedMb.toStringAsFixed(1)} MB / $maxMb MB (${percentage.toStringAsFixed(1)}%)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.image_outlined, color: Colors.white60, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    '$_imageCount / ${widget.configProvider.maxCacheImages}',
                    style: const TextStyle(color: Colors.white90, fontSize: 11),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.videocam_outlined, color: Colors.white60, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    '$_videoCount / ${widget.configProvider.maxCacheVideos}',
                    style: const TextStyle(color: Colors.white90, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
