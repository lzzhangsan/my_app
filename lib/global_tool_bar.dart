import 'package:flutter/material.dart';
import 'dart:async';

class GlobalToolBar extends StatefulWidget {
  final VoidCallback? onNewTextBox;
  final VoidCallback? onNewImageBox;
  final VoidCallback? onNewAudioBox;
  final VoidCallback? onNewCanvas; // 新增：新建画布回调
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onMediaPlay;
  final VoidCallback? onMediaStop;
  final VoidCallback? onContinuousMediaPlay;
  final VoidCallback? onMediaMove;
  final VoidCallback? onMediaDelete;
  final VoidCallback? onMediaFavorite;
  /// 红色播放键三连击：打开媒体播放设置（停留时间、展现方式、随机/顺序）
  final VoidCallback? onMediaSettings;
  const GlobalToolBar({
    super.key,
    this.onNewTextBox,
    this.onNewImageBox,
    this.onNewAudioBox,
    this.onNewCanvas, // 新增：新建画布回调
    this.onUndo,
    this.onRedo,
    this.onMediaPlay,
    this.onMediaStop,
    this.onContinuousMediaPlay,
    this.onMediaMove,
    this.onMediaDelete,
    this.onMediaFavorite,
    this.onMediaSettings,
  });

  @override
  _GlobalToolBarState createState() => _GlobalToolBarState();
}

class _GlobalToolBarState extends State<GlobalToolBar> {
  int _tapCount = 0;
  Timer? _tapTimer;
  int _playTapCount = 0;
  Timer? _playTapSettleTimer;
  /// 播放键：最后一次点击后等待此时长再判定 1/2/3 击，避免三击过程中先触发单击、双击。
  static const Duration _playMultiTapWindow = Duration(milliseconds: 420);
  static const Duration _tapTimeout = Duration(milliseconds: 600); // 左侧新建键三连击检测时间窗口

  void _handleAddButtonTap() {
    _tapCount++;
    
    // 取消之前的定时器
    _tapTimer?.cancel();
    
    if (_tapCount == 1) {
      // 第一次点击，开始计时
      _tapTimer = Timer(_tapTimeout, () {
        // 超时，执行单击操作
        if (widget.onNewTextBox != null) {
          widget.onNewTextBox!();
        }
        _tapCount = 0;
      });
    } else if (_tapCount == 2) {
      // 第二次点击，继续等待可能的第三次点击
      _tapTimer = Timer(_tapTimeout, () {
        // 超时，执行双击操作
        if (widget.onNewImageBox != null) {
          widget.onNewImageBox!();
        }
        _tapCount = 0;
      });
    } else if (_tapCount >= 3) {
      // 三连击：改为新建语音框（保持操作风格统一）
      _tapTimer?.cancel();
      if (widget.onNewAudioBox != null) {
        widget.onNewAudioBox!();
      }
      _tapCount = 0;
    }
  }

  void _handlePlayButtonTap() {
    _playTapCount++;
    _playTapSettleTimer?.cancel();
    _playTapSettleTimer = Timer(_playMultiTapWindow, () {
      final c = _playTapCount;
      _playTapCount = 0;
      if (c >= 3) {
        widget.onMediaSettings?.call();
      } else if (c == 2) {
        widget.onContinuousMediaPlay?.call();
      } else if (c == 1) {
        widget.onMediaPlay?.call();
      }
    });
  }

  void _handlePlayButtonLongPress() {
    _playTapSettleTimer?.cancel();
    _playTapCount = 0;
    widget.onMediaStop?.call();
  }

  void _handleAddButtonLongPress() {
    // 取消点击计时器
    _tapTimer?.cancel();
    _tapCount = 0;
    // 长按：改为新建画布
    if (widget.onNewCanvas != null) {
      widget.onNewCanvas!();
    }
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    _playTapSettleTimer?.cancel();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5.0),
      child: BottomAppBar(
        color: Colors.transparent,
        elevation: 0,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            GestureDetector(
              onTap: _handleAddButtonTap,
              onLongPress: _handleAddButtonLongPress,
              child: Icon(
                Icons.note_add,
                color: Colors.blueAccent,
                size: 31.2,
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.undo,
                color: widget.onUndo != null ? Colors.black : Colors.grey,
                size: 31.2,
              ),
              onPressed: widget.onUndo,
              tooltip: '撤销',
            ),
            IconButton(
              icon: Icon(
                Icons.redo,
                color: widget.onRedo != null ? Colors.black : Colors.grey,
                size: 31.2,
              ),
              onPressed: widget.onRedo,
              tooltip: '重做',
            ),
            GestureDetector(
              onTap: _handlePlayButtonTap,
              onLongPress: _handlePlayButtonLongPress,
              child: Icon(
                Icons.play_circle_filled,
                color: Colors.redAccent,
                size: 31.2,
              ),
            ),
            GestureDetector(
              onTap: () {
                if (widget.onMediaFavorite != null) widget.onMediaFavorite!();
              },
              onDoubleTap: () {
                if (widget.onMediaDelete != null) widget.onMediaDelete!();
              },
              onLongPress: () {
                if (widget.onMediaMove != null) widget.onMediaMove!();
              },
              child: Icon(
                Icons.settings,
                color: Colors.green,
                size: 31.2,
              ),
            ),

          ],
        ),
      ),
    );
  }
}