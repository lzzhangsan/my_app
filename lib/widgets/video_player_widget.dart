import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:async';
import 'package:chewie/chewie.dart';
import 'package:flutter/services.dart';
import '../services/logger.dart';

// Use an Expando to associate the StatefulWidget instance with its State safely
// without adding mutable fields to the immutable widget class.
final Expando<_VideoPlayerWidgetState> _widgetStateExpando = Expando<_VideoPlayerWidgetState>();

class VideoPlayerWidget extends StatefulWidget {
  final File file;
  final bool looping;
  final bool forceManualLoop;
  final VoidCallback? onVideoEnd;
  final VoidCallback? onVideoError;
  final BoxFit fit;

  VideoPlayerWidget({
    required this.file,
    this.looping = false,
    this.forceManualLoop = false,
    this.onVideoEnd,
    this.onVideoError,
    this.fit = BoxFit.contain,
    super.key,
  });

  @override
  _VideoPlayerWidgetState createState() => _VideoPlayerWidgetState();

  // Provide controller access via the Expando-registered state. This keeps the
  // widget immutable while still allowing external callers to get the
  // underlying VideoPlayerController if the state exists.
  VideoPlayerController? get controller => _widgetStateExpando[this]?._controller;
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late VideoPlayerController _controller;
  ChewieController? _chewieController;
  bool _isEnded = false;
  bool _hasError = false;
  Timer? _progressTimer;

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

    _controller.initialize().then((_) {
      if (!mounted) return;
      
      _chewieController = ChewieController(
        videoPlayerController: _controller,
        autoPlay: true,
        looping: widget.looping,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
        showControlsOnInitialize: true,
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
                const Icon(Icons.error_outline, color: Colors.red, size: 48),
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
      _controller.play();
      _controller.setLooping(widget.looping);
      
      Logger.i('[播放器] 初始化成功, isInitialized: ${_controller.value.isInitialized}, isPlaying: ${_controller.value.isPlaying}');

      _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });
    }).catchError((error) {
      _handleError(error.toString());
    });

    _controller.addListener(_videoListener);
  }

  void _videoListener() {
    if (!mounted) return;
    
    Logger.d('[播放器] 状态监听 isInitialized: ${_controller.value.isInitialized}, isPlaying: ${_controller.value.isPlaying}, position: ${_controller.value.position}');

    if (_controller.value.hasError && !_hasError) {
      _handleError(_controller.value.errorDescription ?? '未知错误');
      return;
    }
    
    if (_controller.value.isInitialized && 
        _controller.value.position >= _controller.value.duration &&
        !_isEnded &&
        !widget.looping) {
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
    _progressTimer?.cancel();
    _chewieController?.dispose();
    _controller.pause();
    _controller.dispose();
    // Expando entries are automatically removed when objects are GC'd, no explicit removal needed
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path ||
        oldWidget.looping != widget.looping ||
        oldWidget.forceManualLoop != widget.forceManualLoop) {
      Logger.d('视频播放器更新: ${oldWidget.file.path} -> ${widget.file.path}');
      _progressTimer?.cancel();
      _chewieController?.dispose();
      _controller.pause();
      _controller.dispose();
      _isEnded = false;
      _hasError = false;
      _initializeController();
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
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    return Center(
      child: Container(
        color: Colors.transparent, // 将黑色背景改为透明
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