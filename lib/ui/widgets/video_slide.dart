import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../domain/models/photo_entry.dart';

class VideoSlide extends StatefulWidget {
  final PhotoEntry media;
  final VoidCallback? onPlaybackCompleted;

  const VideoSlide({
    super.key,
    required this.media,
    this.onPlaybackCompleted,
  });

  @override
  State<VideoSlide> createState() => _VideoSlideState();
}

class _VideoSlideState extends State<VideoSlide> {
  VideoPlayerController? _controller;
  VoidCallback? _listener;
  bool _completionNotified = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant VideoSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.file.path != widget.media.file.path) {
      _disposeController();
      _initialize();
    }
  }

  Future<void> _initialize() async {
    final controller = VideoPlayerController.file(widget.media.file);
    _controller = controller;
    _listener = () {
      final value = controller.value;
      if (!value.isInitialized || _completionNotified) return;
      final position = value.position;
      final duration = value.duration;
      if (duration > Duration.zero && position >= duration - const Duration(milliseconds: 250)) {
        _completionNotified = true;
        widget.onPlaybackCompleted?.call();
      }
      if (mounted) {
        setState(() {});
      }
    };
    controller.addListener(_listener!);

    try {
      await controller.initialize();
      await controller.setLooping(false);
      await controller.play();
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _disposeController() {
    final controller = _controller;
    final listener = _listener;
    _controller = null;
    _listener = null;
    _completionNotified = false;
    if (controller != null && listener != null) {
      controller.removeListener(listener);
    }
    unawaited(controller?.dispose());
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      );
    }

    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}
