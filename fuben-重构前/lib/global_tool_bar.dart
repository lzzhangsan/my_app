import 'package:flutter/material.dart';

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
              onTap: () {
                if (widget.onMediaPlay != null) widget.onMediaPlay!();
              },
              onDoubleTap: () {
                if (widget.onContinuousMediaPlay != null) widget.onContinuousMediaPlay!();
              },
              onLongPress: () {
                if (widget.onMediaStop != null) widget.onMediaStop!();
              },
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