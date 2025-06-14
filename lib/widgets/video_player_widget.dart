import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:async';

class VideoPlayerWidget extends StatefulWidget {
  final File file;
  final bool looping;
  final VoidCallback? onVideoEnd;
  final VoidCallback? onVideoError;
  final BoxFit fit;

  VideoPlayerWidget({
    required this.file,
    this.looping = false,
    this.onVideoEnd,
    this.onVideoError,
    this.fit = BoxFit.contain,
    super.key,
  });

  @override
  _VideoPlayerWidgetState createState() => _VideoPlayerWidgetState();

  VideoPlayerController? get controller => _state?._controller;

  _VideoPlayerWidgetState? _state;
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late VideoPlayerController _controller;
  bool _isEnded = false;
  bool _hasError = false;
  Timer? _progressTimer;
  Size? _screenSize;

  @override
  void initState() {
    super.initState();
    widget._state = this;
    _initializeController();
  }

  void _initializeController() {
    _controller = VideoPlayerController.file(widget.file);
    
    debugPrint('开始初始化视频: ${widget.file.path}');
    
    _controller.initialize().then((_) {
      if (mounted) {
        setState(() {});
        _controller.play();
        _controller.setLooping(widget.looping);
        
        // 打印视频信息
        debugPrint('视频初始化成功: ${widget.file.path}');
        debugPrint('视频尺寸: ${_controller.value.size.width}x${_controller.value.size.height}');
        debugPrint('视频宽高比: ${_controller.value.aspectRatio}');
        debugPrint('视频时长: ${_controller.value.duration}');
        
        _progressTimer = Timer.periodic(Duration(milliseconds: 100), (_) {
          if (mounted) {
            setState(() {});
          }
        });
      }
    }).catchError((error) {
      debugPrint('视频初始化错误: ${widget.file.path}, 错误: $error');
      _hasError = true;
      if (mounted) {
        setState(() {});
      }
      if (widget.onVideoError != null) {
        widget.onVideoError!();
      }
    });
    
    _controller.addListener(() {
      if (_controller.value.hasError && !_hasError) {
        debugPrint('视频播放错误: ${widget.file.path}, 错误: ${_controller.value.errorDescription}');
        _hasError = true;
        if (widget.onVideoError != null) {
          widget.onVideoError!();
        }
        return;
      }
      
      if (_controller.value.isInitialized && 
          _controller.value.position >= _controller.value.duration &&
          !_isEnded &&
          !widget.looping) {
        _isEnded = true;
        if (widget.onVideoEnd != null) {
          widget.onVideoEnd!();
        }
      }
    });
  }

  @override
  void dispose() {
    debugPrint('销毁视频播放器: ${widget.file.path}');
    _progressTimer?.cancel();
    _controller.pause();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path ||
        oldWidget.looping != widget.looping) {
      debugPrint('视频播放器更新: ${oldWidget.file.path} -> ${widget.file.path}');
      _progressTimer?.cancel();
      _controller.pause();
      _controller.dispose();
      _isEnded = false;
      _hasError = false;
      _initializeController();
    }
  }

  @override
  Widget build(BuildContext context) {
    _screenSize = MediaQuery.of(context).size;
    
    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, color: Colors.red, size: 48),
            SizedBox(height: 16),
            Text('视频无法播放', style: TextStyle(color: Colors.white))
          ],
        ),
      );
    }
    
    if (_controller.value.isInitialized) {
      // 打印布局信息
      debugPrint('视频布局信息: ${widget.file.path}');
      debugPrint('屏幕尺寸: ${_screenSize?.width}x${_screenSize?.height}');
      debugPrint('视频尺寸: ${_controller.value.size.width}x${_controller.value.size.height}');
      debugPrint('视频宽高比: ${_controller.value.aspectRatio}');
      debugPrint('BoxFit设置: ${widget.fit}');
      // 新增：横向铺满屏幕，纵向等比缩放，超出部分裁剪，纵向居中
      return LayoutBuilder(
        builder: (context, constraints) {
          final screenWidth = constraints.maxWidth;
          final videoAspect = _controller.value.aspectRatio;
          final videoHeight = screenWidth / videoAspect;
          return Center(
            child: ClipRect(
              child: SizedBox(
                width: screenWidth,
                height: videoHeight,
                child: AspectRatio(
                  aspectRatio: videoAspect,
                  child: VideoPlayer(_controller),
                ),
              ),
            ),
          );
        },
      );
    } else {
      return Center(child: CircularProgressIndicator());
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}