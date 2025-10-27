import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'core/app_state.dart';
import 'core/service_locator.dart';

class GlobalToolBar extends StatefulWidget {
  final VoidCallback? onNewTextBox;
  final VoidCallback? onNewImageBox;
  final VoidCallback? onNewAudioBox;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onMediaPlay;
  final VoidCallback? onMediaStop;
  final VoidCallback? onContinuousMediaPlay;
  final VoidCallback? onMediaMove;
  final VoidCallback? onMediaDelete;
  final VoidCallback? onMediaFavorite;
  const GlobalToolBar({
    super.key,
    this.onNewTextBox,
    this.onNewImageBox,
    this.onNewAudioBox,
    this.onUndo,
    this.onRedo,
    this.onMediaPlay,
    this.onMediaStop,
    this.onContinuousMediaPlay,
    this.onMediaMove,
    this.onMediaDelete,
    this.onMediaFavorite,
  });

  @override
  _GlobalToolBarState createState() => _GlobalToolBarState();
}

class _GlobalToolBarState extends State<GlobalToolBar> {
  late final AppThemeState _themeState;

  @override
  void initState() {
    super.initState();
    _themeState = getService<AppThemeState>();
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
              onTap: widget.onNewTextBox,
              onDoubleTap: widget.onNewImageBox,
              onLongPress: () {
                if (widget.onNewAudioBox != null) {
                  widget.onNewAudioBox!();
                }
              },
              child: const Icon(
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
              onTap: () {
                if (widget.onMediaPlay != null) widget.onMediaPlay!();
              },
              onDoubleTap: () {
                if (widget.onContinuousMediaPlay != null) widget.onContinuousMediaPlay!();
              },
              onLongPress: () {
                if (widget.onMediaStop != null) widget.onMediaStop!();
              },
              child: const Icon(
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
              child: const Icon(
                Icons.settings,
                color: Colors.green,
                size: 31.2,
              ),
            ),
            IconButton(
              tooltip: _themeState.isDarkMode ? '切换到浅色' : '切换到深色',
              icon: Icon(
                _themeState.isDarkMode ? Icons.dark_mode : Icons.light_mode,
                size: 28,
              ),
              onPressed: () {
                setState(() {
                  _themeState.toggleThemeMode();
                });
              },
            ),
          ],
        ),
      ),
    );
  }
}