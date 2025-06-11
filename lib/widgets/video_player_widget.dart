import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:async';

class VideoPlayerWidget extends StatefulWidget {
  final File file;
  final bool looping;
  final VoidCallback? onVideoEnd;
  final VoidCallback? onVideoError;

  VideoPlayerWidget({
    required this.file,
    this.looping = false,
    this.onVideoEnd,
    this.onVideoError,
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

  @override
  void initState() {
    super.initState();
    widget._state = this;
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
          if (mounted) {
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
        ? Stack(
            alignment: Alignment.bottomCenter,
            children: [
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _controller.value.size.width,
                    height: _controller.value.size.height,
                    child: VideoPlayer(_controller),
                  ),
                ),
              ),
              Container(
                color: Colors.black.withOpacity(0.5),
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _formatDuration(_controller.value.position),
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    SizedBox(width: 8),
                    SizedBox(
                      width: 200,
                      height: 4,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white.withOpacity(0.3),
                          thumbColor: Colors.white,
                          overlayColor: Colors.white.withOpacity(0.2),
                          trackHeight: 4,
                          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 4),
                          overlayShape: RoundSliderOverlayShape(overlayRadius: 8),
                        ),
                        child: Slider(
                          value: _controller.value.position.inMilliseconds.toDouble(),
                          min: 0,
                          max: _controller.value.duration.inMilliseconds.toDouble(),
                          onChanged: (value) {
                            final Duration position = Duration(milliseconds: value.round());
                            _controller.seekTo(position);
                          },
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    Text(
                      _formatDuration(_controller.value.duration),
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          )
        : Center(child: CircularProgressIndicator());
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
} 