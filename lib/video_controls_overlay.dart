import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'video_player_widget.dart';

class VideoControlsOverlay extends StatefulWidget {
  final VideoPlayerWidget? videoPlayerWidget;
  
  const VideoControlsOverlay({
    Key? key,
    this.videoPlayerWidget,
  }) : super(key: key);

  @override
  _VideoControlsOverlayState createState() => _VideoControlsOverlayState();
}

class _VideoControlsOverlayState extends State<VideoControlsOverlay> {
  Timer? _updateTimer;
  
  @override
  void initState() {
    super.initState();
    _startUpdateTimer();
  }
  
  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }
  
  void _startUpdateTimer() {
    _updateTimer = Timer.periodic(Duration(milliseconds: 100), (timer) {
      if (mounted) {
        setState(() {});
      }
    });
  }
  
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return '${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds';
  }

  @override
  Widget build(BuildContext context) {
    // 只有当存在视频播放器组件时才显示控制条
    if (widget.videoPlayerWidget == null) {
      return SizedBox.shrink();
    }
    
    final VideoPlayerController? controller = widget.videoPlayerWidget!.controller;
    
    // 只有当控制器存在且已初始化时才显示控制条
    if (controller == null || !controller.value.isInitialized) {
      return SizedBox.shrink();
    }
    
    // 检查视频是否已播放完毕或暂停状态
    if (controller.value.position >= controller.value.duration && 
        controller.value.duration > Duration.zero) {
      return SizedBox.shrink();
    }
    
    // 如果视频没有在播放且不在拖拽状态，也不显示控制条
    if (!controller.value.isPlaying && !widget.videoPlayerWidget!.isDragging) {
      return SizedBox.shrink();
    }
    
    final Duration position = controller.value.position;
    final Duration duration = controller.value.duration;

    return Positioned(
      bottom: 100,
      left: 30,
      right: 30,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _formatDuration(position),
              style: TextStyle(color: Colors.white, fontSize: 10),
            ),
            SizedBox(width: 6),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white.withOpacity(0.3),
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withOpacity(0.2),
                  trackHeight: 3,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 4),
                  overlayShape: RoundSliderOverlayShape(overlayRadius: 8),
                ),
                child: Slider(
                  value: position.inMilliseconds.toDouble(),
                  min: 0,
                  max: duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0,
                  onChangeStart: (value) {
                    widget.videoPlayerWidget!.isDragging = true;
                  },
                  onChanged: (value) {
                    final Duration newPosition = Duration(milliseconds: value.round());
                    controller.seekTo(newPosition);
                  },
                  onChangeEnd: (value) {
                    widget.videoPlayerWidget!.isDragging = false;
                  },
                ),
              ),
            ),
            SizedBox(width: 6),
            Text(
              _formatDuration(duration),
              style: TextStyle(color: Colors.white, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}