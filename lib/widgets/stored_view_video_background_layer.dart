import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/service_locator.dart';
import '../models/video_view_params.dart';
import '../services/database_service.dart';
import '../utils/background_video_volume_prefs.dart';
import 'video_interactive_surface.dart';

/// 背景视频层：套用 [getVideoViewParamsForMediaFilePath]，只读 [VideoInteractiveSurface]，循环播放。
///
/// [pauseWhenRouteNotCurrent]：为 true 时，当前 [ModalRoute] 被上层路由盖住（如从目录 push 文档）则暂停，返回后自动恢复。
/// [pauseWhenNotifier]：为 true 时暂停（如文档内右下角浮层正在展示图/视频），为 false 时恢复。
class StoredViewVideoBackgroundLayer extends StatefulWidget {
  const StoredViewVideoBackgroundLayer({
    super.key,
    required this.file,
    this.useScreenSizeForNormalization = false,
    this.pauseWhenRouteNotCurrent = false,
    this.pauseWhenNotifier,
  });

  final File file;
  final bool useScreenSizeForNormalization;
  final bool pauseWhenRouteNotCurrent;
  final ValueListenable<bool>? pauseWhenNotifier;

  @override
  State<StoredViewVideoBackgroundLayer> createState() =>
      _StoredViewVideoBackgroundLayerState();
}

class _StoredViewVideoBackgroundLayerState
    extends State<StoredViewVideoBackgroundLayer> {
  VideoPlayerController? _controller;
  Future<VideoViewParams>? _paramsFuture;
  Object? _initError;

  void _onPauseSignalsChanged() {
    if (!mounted) return;
    _applyPlaybackPolicy();
  }

  @override
  void initState() {
    super.initState();
    _paramsFuture = _loadParams();
    _initController();
    widget.pauseWhenNotifier?.addListener(_onPauseSignalsChanged);
  }

  @override
  void didUpdateWidget(covariant StoredViewVideoBackgroundLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pauseWhenNotifier != widget.pauseWhenNotifier) {
      oldWidget.pauseWhenNotifier?.removeListener(_onPauseSignalsChanged);
      widget.pauseWhenNotifier?.addListener(_onPauseSignalsChanged);
    }
    if (oldWidget.file.path != widget.file.path) {
      _controller?.dispose();
      _controller = null;
      _paramsFuture = _loadParams();
      _initController();
    } else {
      _applyPlaybackPolicy();
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
      final memVol = BackgroundVideoVolumePrefs.tryMemoryVolumeForPath(
        widget.file.path,
      );
      final double vol =
          memVol ?? await BackgroundVideoVolumePrefs.volumeForPath(widget.file.path);
      await c.setVolume(vol);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _initError = null;
      });
      _applyPlaybackPolicy();
    } catch (e) {
      if (mounted) {
        setState(() {
          _initError = e;
        });
      }
    }
  }

  void _applyPlaybackPolicy() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    var shouldPause = false;
    if (widget.pauseWhenRouteNotCurrent) {
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        shouldPause = true;
      }
    }
    if (widget.pauseWhenNotifier?.value == true) {
      shouldPause = true;
    }

    if (shouldPause) {
      if (c.value.isPlaying) {
        c.pause();
      }
    } else {
      if (!c.value.isPlaying) {
        if (c.value.position <= const Duration(milliseconds: 1)) {
          final dur = c.value.duration;
          final kickMs = dur.inMilliseconds > 4000 ? 1000 : 1;
          c.seekTo(Duration(milliseconds: kickMs)).whenComplete(() {
            if (mounted && _controller == c) c.play();
          });
        } else {
          c.play();
        }
      }
    }
  }

  @override
  void dispose() {
    widget.pauseWhenNotifier?.removeListener(_onPauseSignalsChanged);
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
