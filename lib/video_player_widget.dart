// lib/video_player_widget.dart
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:async';

class VideoPlayerWidget extends StatefulWidget {
  final File file;
  final bool looping;
  final VoidCallback? onVideoEnd;
  final VoidCallback? onVideoError;
  
  // 用于存储State引用
  _VideoPlayerWidgetState? _state;

  VideoPlayerWidget({
    required this.file,
    this.looping = false,
    this.onVideoEnd,
    this.onVideoError,
    Key? key,
  }) : super(key: key);

  @override
  _VideoPlayerWidgetState createState() {
    _state = _VideoPlayerWidgetState();
    return _state!;
  }
  
  // 提供访问State的方法
  VideoPlayerController? get controller {
    return _state?._controller;
  }
  
  bool get isDragging {
    return _state?._isDragging ?? false;
  }
  
  set isDragging(bool value) {
    _state?.isDragging = value;
  }
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late VideoPlayerController _controller;
  bool _isEnded = false;
  bool _hasError = false;
  Timer? _progressTimer;
  bool _isDragging = false; // 添加拖拽状态标志

  // 内部setter方法
  set isDragging(bool value) {
    if (_isDragging != value) {
      setState(() {
        _isDragging = value;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  void _initializeController() {
    _controller = VideoPlayerController.file(widget.file);
    
    _controller.initialize().then((_) {
      if (mounted) {
        setState(() {});
        _controller.play();
        _controller.setLooping(widget.looping);
        
        _progressTimer = Timer.periodic(Duration(milliseconds: 100), (_) {
          if (mounted && !_isDragging) { // 只有在不拖拽时才更新UI
            setState(() {});
          }
        });
      }
    }).catchError((error) {
      print('视频初始化错误: $error');
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
        print('视频播放错误: ${_controller.value.errorDescription}');
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
    
    return _controller.value.isInitialized
        ? SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller.value.size.width,
                height: _controller.value.size.height,
                child: VideoPlayer(_controller),
              ),
            ),
          )
        : Center(child: CircularProgressIndicator());
  }


}
