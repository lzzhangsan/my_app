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
  
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return '${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.videoPlayerWidget == null) {
      return SizedBox.shrink();
    }

    final VideoPlayerController? controller = widget.videoPlayerWidget!.controller;
    
    if (controller == null) {
      return SizedBox.shrink();
    }
    
    if (!controller.value.isInitialized) {
      return SizedBox.shrink();
    }

    return Positioned(
      bottom: 20,
      left: 20,
      right: 20,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _formatDuration(controller.value.position),
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
            SizedBox(width: 8),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white.withOpacity(0.3),
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withOpacity(0.2),
                  trackHeight: 4,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: controller.value.position.inMilliseconds.toDouble(),
                  min: 0,
                  max: controller.value.duration.inMilliseconds.toDouble(),
                  onChangeStart: (value) {
                    widget.videoPlayerWidget!.isDragging = true;
                  },
                  onChanged: (value) {
                    final Duration position = Duration(milliseconds: value.round());
                    controller.seekTo(position);
                  },
                  onChangeEnd: (value) {
                    widget.videoPlayerWidget!.isDragging = false;
                  },
                ),
              ),
            ),
            SizedBox(width: 8),
            Text(
              _formatDuration(controller.value.duration),
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}