import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'package:chewie/chewie.dart';
import 'package:flutter/services.dart';
import '../models/video_view_params.dart';
import '../services/logger.dart';
import 'video_interactive_surface.dart';

// Use an Expando to associate the StatefulWidget instance with its State safely
// without adding mutable fields to the immutable widget class.
final Expando<_VideoPlayerWidgetState> _widgetStateExpando =
    Expando<_VideoPlayerWidgetState>();

class VideoPlayerWidget extends StatefulWidget {
  final File file;
  final bool looping;
  final bool forceManualLoop;
  final VoidCallback? onVideoEnd;
  final VoidCallback? onVideoError;
  final BoxFit fit;

  /// 非 null 时在文档栏套用媒体页已保存的缩放/平移/旋转（只读）。
  final VideoViewParams? viewParams;

  /// 顺序模式断点续播：初始化后 seek 到此（通常为「上次退出位置 − 5 秒」）。
  final Duration? initialSeekPosition;

  /// 为 true 时：若整段时长不足 5 秒则触发 [onSequentialResumeTooShort]，不开始播放。
  final bool sequentialResumeActive;

  /// 见 [sequentialResumeActive]。
  final VoidCallback? onSequentialResumeTooShort;

  /// 顺序模式定时回写进度（毫秒），供退出/杀进程后续播。
  final void Function(int positionMs, int durationMs)? onProgressForResumeSave;

  /// 文档编辑页媒体栏：为 true 时强制静音（与全屏预览、背景视频音量无关）。
  final bool documentMediaBarMuted;

  final bool defaultVerticalFillWhenPristine;

  VideoPlayerWidget({
    required this.file,
    this.looping = false,
    this.forceManualLoop = false,
    this.onVideoEnd,
    this.onVideoError,
    this.fit = BoxFit.contain,
    this.viewParams,
    this.initialSeekPosition,
    this.sequentialResumeActive = false,
    this.onSequentialResumeTooShort,
    this.onProgressForResumeSave,
    this.documentMediaBarMuted = false,
    this.defaultVerticalFillWhenPristine = false,
    super.key,
  });

  @override
  _VideoPlayerWidgetState createState() => _VideoPlayerWidgetState();

  // Provide controller access via the Expando-registered state. This keeps the
  // widget immutable while still allowing external callers to get the
  // underlying VideoPlayerController if the state exists.
  VideoPlayerController? get controller =>
      _widgetStateExpando[this]?._controller;
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late VideoPlayerController _controller;
  ChewieController? _chewieController;
  bool _isEnded = false;
  bool _hasError = false;
  Timer? _progressTimer;
  Timer? _resumeSaveTimer;
  /// 顺序续播：总长不足 5 秒，已通知外层切下一条。
  bool _skipResumeShort = false;

  @override
  void initState() {
    super.initState();
    // Register this state for the widget so external code can access the
    // controller through the widget.controller getter.
    _widgetStateExpando[widget] = this;
    _initializeController();
  }

  void _initializeController() {
    if (!widget.file.existsSync()) {
      _handleError('视频文件不存在');
      return;
    }

    _controller = VideoPlayerController.file(widget.file);
    Logger.d('[播放器] 初始化controller: ${widget.file.path}');

    _controller
        .initialize()
        .then((_) async {
          if (!mounted) return;

          final Duration dur = _controller.value.duration;
          if (widget.sequentialResumeActive &&
              dur < const Duration(seconds: 5)) {
            _controller.removeListener(_videoListener);
            await _controller.pause();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onSequentialResumeTooShort?.call();
            });
            if (mounted) {
              setState(() => _skipResumeShort = true);
            }
            return;
          }

          if (widget.initialSeekPosition != null &&
              widget.initialSeekPosition! > Duration.zero) {
            var t = widget.initialSeekPosition!;
            if (dur > Duration.zero && t >= dur) {
              t = dur - const Duration(milliseconds: 50);
            }
            if (t < Duration.zero) t = Duration.zero;
            await _controller.seekTo(t);
            if (!mounted) return;
          }

          // 文档编辑区嵌入：有 VideoControlsOverlay 外部底栏，不显示 Chewie 自带控制层。
          final bool embedInDocumentEditor = widget.viewParams != null;

          _chewieController = ChewieController(
            videoPlayerController: _controller,
            autoPlay: true,
            looping: widget.looping,
            allowFullScreen: true,
            allowMuting: true,
            showControls: !embedInDocumentEditor,
            showControlsOnInitialize: !embedInDocumentEditor,
            customControls:
                embedInDocumentEditor
                    ? null
                    : const MaterialControls(hideBottomBar: true),
            deviceOrientationsAfterFullScreen: [DeviceOrientation.portraitUp],
            materialProgressColors: ChewieProgressColors(
              playedColor: Colors.red,
              handleColor: Colors.red,
              // Replace deprecated withOpacity usage with alpha-based color to avoid deprecation warnings
              backgroundColor: Colors.white.withAlpha((0.3 * 255).round()),
              bufferedColor: Colors.white.withAlpha((0.5 * 255).round()),
            ),
            errorBuilder: (context, errorMessage) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '视频播放失败\n$errorMessage',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        _controller.initialize().then((_) {
                          if (mounted) setState(() {});
                        });
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
              );
            },
          );

          setState(() {});
          // HLS remux 偶发「卡在第一帧，拖一下才动」：先轻量 seek 再播，踢开 demuxer。
          if (widget.initialSeekPosition == null ||
              widget.initialSeekPosition! <= Duration.zero) {
            try {
              await _controller.seekTo(const Duration(milliseconds: 1));
            } catch (_) {}
          }
          await _controller.play();
          _controller.setLooping(widget.looping);
          unawaited(_applyDocumentBarVolume());
          unawaited(_unstickFrozenFirstFrame());

          Logger.i(
            '[播放器] 初始化成功, isInitialized: ${_controller.value.isInitialized}, isPlaying: ${_controller.value.isPlaying}',
          );

          _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (
            _,
          ) {
            if (mounted) setState(() {});
          });

          if (widget.onProgressForResumeSave != null) {
            _resumeSaveTimer?.cancel();
            _resumeSaveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
              if (!mounted) return;
              final v = _controller.value;
              if (!v.isInitialized || v.duration <= Duration.zero) return;
              widget.onProgressForResumeSave!(
                v.position.inMilliseconds,
                v.duration.inMilliseconds,
              );
            });
          }
        })
        .catchError((error) {
          _handleError(error.toString());
        });

    _controller.addListener(_videoListener);
  }

  Future<void> _applyDocumentBarVolume() async {
    if (!_controller.value.isInitialized) return;
    await _controller.setVolume(
      widget.documentMediaBarMuted ? 0.0 : 1.0,
    );
  }

  /// 部分 HLS remux 文件会卡在首帧直到拖动；若播放中位置长期为 0，再踢一次。
  Future<void> _unstickFrozenFirstFrame() async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || _hasError || _skipResumeShort) return;
    final v = _controller.value;
    if (!v.isInitialized || v.duration <= const Duration(seconds: 1)) return;
    if (v.position > const Duration(milliseconds: 80)) return;
    try {
      await _controller.seekTo(const Duration(milliseconds: 40));
      if (!mounted) return;
      await _controller.play();
    } catch (_) {}
  }

  void _videoListener() {
    if (!mounted) return;

    final v = _controller.value;
    final Duration dur = v.duration;
    final Duration pos = v.position;

    // 同一文件再次进入播放（顺序/随机循环一轮）时 position 会回到开头，必须允许再次触发 onVideoEnd
    if (v.isInitialized && dur > Duration.zero) {
      // 未进入片尾区则视为新一轮播放，可再次触发结束回调
      if (pos < dur - const Duration(milliseconds: 200)) {
        _isEnded = false;
      }
    }

    if (v.hasError && !_hasError) {
      _handleError(v.errorDescription ?? '未知错误');
      return;
    }

    // 必须在 duration 已加载且 >0 后才判定结束；否则 duration==0 时 0>=0 会误触发 onVideoEnd，打乱自动切下一条。
    // 部分机型片尾 position 永远略小于 duration，故用片尾容差。
    if (!v.isInitialized ||
        widget.looping ||
        _isEnded ||
        dur <= Duration.zero) {
      return;
    }

    // 片尾容差：略大于 position 抖动；短片段用比例下限，长视频用时长约 6%（封顶）避免永远判不到「已结束」
    final int durMs = dur.inMilliseconds;
    final int slackMs =
        durMs < 500
            ? (durMs / 5).round().clamp(50, 120)
            : (durMs * 0.06).round().clamp(120, 450);
    final Duration slack = Duration(milliseconds: slackMs);
    final bool reachedEnd = pos >= dur - slack;

    if (reachedEnd) {
      _isEnded = true;
      widget.onVideoEnd?.call();
      if (widget.forceManualLoop) {
        _controller.seekTo(Duration.zero).then((_) {
          _controller.play();
          _isEnded = false;
        });
      }
    }
  }

  void _handleError(String error) {
    Logger.e('视频播放错误: ${widget.file.path}', error);
    _hasError = true;
    if (mounted) setState(() {});
    widget.onVideoError?.call();
  }

  @override
  void dispose() {
    Logger.d('销毁视频播放器: ${widget.file.path}');
    _resumeSaveTimer?.cancel();
    _progressTimer?.cancel();
    if (!_skipResumeShort &&
        widget.onProgressForResumeSave != null &&
        _controller.value.isInitialized &&
        _controller.value.duration > Duration.zero) {
      widget.onProgressForResumeSave!(
        _controller.value.position.inMilliseconds,
        _controller.value.duration.inMilliseconds,
      );
    }
    _chewieController?.dispose();
    _controller.removeListener(_videoListener);
    _controller.pause();
    _controller.dispose();
    // Expando entries are automatically removed when objects are GC'd, no explicit removal needed
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final fileOrLoopChanged =
        oldWidget.file.path != widget.file.path ||
        oldWidget.looping != widget.looping ||
        oldWidget.forceManualLoop != widget.forceManualLoop ||
        oldWidget.initialSeekPosition != widget.initialSeekPosition ||
        oldWidget.sequentialResumeActive != widget.sequentialResumeActive;
    if (fileOrLoopChanged) {
      Logger.d('视频播放器更新: ${oldWidget.file.path} -> ${widget.file.path}');
      _resumeSaveTimer?.cancel();
      _progressTimer?.cancel();
      _chewieController?.dispose();
      _controller.pause();
      _controller.dispose();
      _isEnded = false;
      _hasError = false;
      _skipResumeShort = false;
      _initializeController();
    } else if (oldWidget.documentMediaBarMuted != widget.documentMediaBarMuted) {
      unawaited(_applyDocumentBarVolume());
    } else if (oldWidget.viewParams != widget.viewParams) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.file.existsSync()) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 48),
            SizedBox(height: 16),
            Text('视频文件不存在', style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }

    if (_skipResumeShort) {
      return const SizedBox.shrink();
    }

    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            const Text('视频无法播放', style: TextStyle(color: Colors.white)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                _hasError = false;
                _initializeController();
                if (mounted) setState(() {});
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (!_controller.value.isInitialized || _chewieController == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final vp = widget.viewParams;
    if (vp != null) {
      final bool pristine =
          vp.isLikelyIdentityTransform &&
          vp.basisW == null &&
          vp.basisH == null &&
          vp.anchorXNorm == null &&
          vp.anchorYNorm == null;
      return LayoutBuilder(
        builder: (context, c) {
          final viewportW = c.maxWidth;
          final viewportH = c.maxHeight;
          var effective = vp;
          if (widget.defaultVerticalFillWhenPristine &&
              pristine &&
              viewportW > 1 &&
              viewportH > 1) {
            final q = vp.quarterTurns % 4;
            if (q == 0) {
              final videoSize = _controller.value.size;
              final vw = videoSize.width;
              final vh = videoSize.height;
              if (vw > 1 && vh > 1) {
                final containScale = math.min(viewportW / vw, viewportH / vh);
                final baseDisplayHeight = vh * containScale;
                if (baseDisplayHeight > 1) {
                  final targetScale =
                      (viewportH / baseDisplayHeight).clamp(1.0, 6.0);
                  final basisW = q == 1 || q == 3 ? viewportH : viewportW;
                  final basisH = q == 1 || q == 3 ? viewportW : viewportH;
                  effective = VideoViewParams(
                    scale: targetScale,
                    txNorm: 0.0,
                    tyNorm: 0.0,
                    quarterTurns: q,
                    basisW: basisW,
                    basisH: basisH,
                  );
                }
              }
            }
          }
          return Center(
            child: Container(
              color: Colors.transparent,
              child: SizedBox.expand(
                child: ChewieFullscreenHost(
                  controller: _chewieController!,
                  child: VideoInteractiveSurface(
                    key: ValueKey('${widget.file.path}_${effective.hashCode}'),
                    videoController: _controller,
                    videoChild: const PlayerWithControls(),
                    initial: effective,
                    editable: false,
                    useScreenSizeForNormalization: false,
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    return Center(
      child: Container(
        color: Colors.transparent,
        child: SizedBox.expand(
          child: FittedBox(
            fit: widget.fit,
            alignment: Alignment.center,
            child: SizedBox(
              width: _controller.value.size.width,
              height: _controller.value.size.height,
              child: Chewie(controller: _chewieController!),
            ),
          ),
        ),
      ),
    );
  }
}
