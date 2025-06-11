import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'widgets/video_player_widget.dart';

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
  void didUpdateWidget(VideoControlsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当视频播放器组件发生变化时，重新启动定时器
    if (widget.videoPlayerWidget != oldWidget.videoPlayerWidget) {
      _updateTimer?.cancel();
      _startUpdateTimer();
      // 强制立即更新状态
      if (mounted) {
        setState(() {});
      }
    }
  }
  
  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }
  
  void _startUpdateTimer() {
    // 取消现有定时器
    _updateTimer?.cancel();
    
    // 创建新定时器，更高频率更新
    _updateTimer = Timer.periodic(Duration(milliseconds: 30), (timer) {
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
    
    // 控制器不存在时不显示
    if (controller == null) {
      return SizedBox.shrink();
    }
    
    // 获取当前位置和总时长
    final Duration position = controller.value.isInitialized ? controller.value.position : Duration.zero;
    final Duration duration = controller.value.isInitialized ? controller.value.duration : Duration(seconds: 1);
    
    // 视频播放完毕时隐藏（但保留缓冲和错误状态的显示）
    if (controller.value.isInitialized && 
        !controller.value.hasError && 
        position >= duration && 
        duration > Duration.zero) {
      return SizedBox.shrink();
    }

    return Positioned(
      bottom: 0, // 紧贴屏幕最下沿
      left: 0,
      right: 0,
      child: Container(
        height: 40, // 稍微增加高度以便操作
        // 移除背景色，只保留关键控制元素
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withOpacity(0.3),
            ],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 播放/暂停按钮
            Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(
                  (controller.value.isInitialized && controller.value.isPlaying) ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 18,
                ),
                padding: EdgeInsets.all(4),
                constraints: BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: controller.value.isInitialized ? () {
                  setState(() {
                    if (controller.value.isPlaying) {
                      controller.pause();
                    } else {
                      controller.play();
                    }
                  });
                } : null,
              ),
            ),
            SizedBox(width: 8),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _formatDuration(position),
                style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
              ),
            ),
            Expanded(
              child: Slider(
                value: duration.inMilliseconds > 0 ? position.inMilliseconds.toDouble().clamp(0.0, duration.inMilliseconds.toDouble()) : 0.0,
                min: 0.0,
                max: duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0,
                activeColor: Colors.white,
                inactiveColor: Colors.white.withOpacity(0.3),
                thumbColor: Colors.white,
                onChanged: controller.value.isInitialized ? (value) {
                  final newPosition = Duration(milliseconds: value.toInt());
                  controller.seekTo(newPosition);
                  setState(() {}); // 强制更新UI
                } : null,
              ),
            ),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _formatDuration(duration),
                style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}