import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/service_locator.dart';
import '../models/video_view_params.dart';
import '../services/database_service.dart';
import 'video_interactive_surface.dart';

/// 背景视频层：套用 [getVideoViewParamsForMediaFilePath]，只读 [VideoInteractiveSurface]，循环播放。
class StoredViewVideoBackgroundLayer extends StatefulWidget {
  const StoredViewVideoBackgroundLayer({
    super.key,
    required this.file,
    this.useScreenSizeForNormalization = false,
  });

  final File file;
  final bool useScreenSizeForNormalization;

  @override
  State<StoredViewVideoBackgroundLayer> createState() =>
      _StoredViewVideoBackgroundLayerState();
}

class _StoredViewVideoBackgroundLayerState
    extends State<StoredViewVideoBackgroundLayer> {
  VideoPlayerController? _controller;
  Future<VideoViewParams>? _paramsFuture;
  Object? _initError;

  @override
  void initState() {
    super.initState();
    _paramsFuture = _loadParams();
    _initController();
  }

  @override
  void didUpdateWidget(covariant StoredViewVideoBackgroundLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _controller?.dispose();
      _controller = null;
      _paramsFuture = _loadParams();
      _initController();
    }
  }

  Future<VideoViewParams> _loadParams() {
    return getService<DatabaseService>().getVideoViewParamsForMediaFilePath(
      widget.file.path,
    );
  }

  Future<void> _initController() async {
    try {
      final c = VideoPlayerController.file(widget.file);
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _initError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _initError = e;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_initError != null) {
      return const Center(
        child: Icon(Icons.videocam_off, color: Colors.white54, size: 48),
      );
    }
    if (c == null || !c.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }
    return FutureBuilder<VideoViewParams>(
      future: _paramsFuture,
      builder: (context, snapshot) {
        final p = snapshot.data ?? const VideoViewParams();
        return VideoInteractiveSurface(
          key: ValueKey('svvl_${widget.file.path}_${p.hashCode}'),
          videoController: c,
          videoChild: Center(
            child: AspectRatio(
              aspectRatio:
                  c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9,
              child: VideoPlayer(c),
            ),
          ),
          initial: p,
          editable: false,
          useScreenSizeForNormalization: widget.useScreenSizeForNormalization,
        );
      },
    );
  }
}
