import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/video_view_params.dart';
import 'video_seven_stroke.dart';

/// 媒体页：双指缩放、单指平移（放大后）、「7」形旋转；文档栏：只读套用 [initial]。
class VideoInteractiveSurface extends StatefulWidget {
  const VideoInteractiveSurface({
    super.key,
    required this.videoController,
    required this.videoChild,
    required this.initial,
    this.editable = true,
    this.onChanged,
  });

  final VideoPlayerController videoController;
  /// 通常为 [Chewie]（可外包 [Theme]）。
  final Widget videoChild;
  final VideoViewParams initial;
  final bool editable;
  final ValueChanged<VideoViewParams>? onChanged;

  @override
  State<VideoInteractiveSurface> createState() =>
      _VideoInteractiveSurfaceState();
}

class _VideoInteractiveSurfaceState extends State<VideoInteractiveSurface> {
  final TransformationController _tc = TransformationController();
  Timer? _debounce;
  int _quarterTurns = 0;
  bool _appliedInitial = false;

  double _lastViewportW = 1;
  double _lastViewportH = 1;

  final Set<int> _activePointers = {};
  final List<Offset> _strokePoints = [];

  @override
  void initState() {
    super.initState();
    _quarterTurns = widget.initial.quarterTurns % 4;
    if (_quarterTurns < 0) _quarterTurns += 4;
    _tc.addListener(_onMatrixChanged);
  }

  @override
  void didUpdateWidget(covariant VideoInteractiveSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initial != widget.initial) {
      _quarterTurns = widget.initial.quarterTurns % 4;
      if (_quarterTurns < 0) _quarterTurns += 4;
      _appliedInitial = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyInitial(_lastViewportW, _lastViewportH);
        setState(() => _appliedInitial = true);
      });
    }
  }

  void _onMatrixChanged() {
    if (!widget.editable || !mounted) return;
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _emitChanged();
    });
  }

  void _emitChanged() {
    final m = _tc.value;
    final t = m.getTranslation();
    final s = m.getMaxScaleOnAxis().clamp(1.0, 6.0);
    final vw = _lastViewportW;
    final vh = _lastViewportH;
    final tx = vw > 1e-6 ? t.x / vw : 0.0;
    final ty = vh > 1e-6 ? t.y / vh : 0.0;
    widget.onChanged?.call(VideoViewParams(
      scale: s,
      txNorm: tx,
      tyNorm: ty,
      quarterTurns: _quarterTurns,
    ));
  }

  void _applyInitial(double vw, double vh) {
    final p = widget.initial;
    _tc.value = Matrix4.identity()
      ..translate(p.txNorm * vw, p.tyNorm * vh)
      ..scale(p.scale.clamp(1.0, 6.0));
  }

  double _scaleNow() {
    try {
      return _tc.value.getMaxScaleOnAxis();
    } catch (_) {
      return 1.0;
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    _activePointers.add(e.pointer);
    if (_activePointers.length == 1 && widget.editable) {
      _strokePoints
        ..clear()
        ..add(e.localPosition);
    } else {
      _strokePoints.clear();
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!widget.editable) return;
    if (_activePointers.length == 1 && _scaleNow() <= 1.02) {
      _strokePoints.add(e.localPosition);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final soloStroke = _activePointers.length == 1;
    _activePointers.remove(e.pointer);
    if (!widget.editable) {
      _strokePoints.clear();
      return;
    }
    if (soloStroke &&
        _scaleNow() <= 1.02 &&
        _strokePoints.length >= 8) {
      final rot = detectSevenStrokeRotation(List.from(_strokePoints));
      if (rot != null) {
        setState(() {
          _quarterTurns = rot
              ? (_quarterTurns + 1) % 4
              : (_quarterTurns - 1) % 4;
          if (_quarterTurns < 0) _quarterTurns += 4;
          _tc.value = Matrix4.identity();
        });
        _emitChanged();
      }
    }
    _strokePoints.clear();
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _activePointers.remove(e.pointer);
    _strokePoints.clear();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tc.removeListener(_onMatrixChanged);
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.videoController.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final size = widget.videoController.value.size;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, c) {
        final vw = c.maxWidth;
        final vh = c.maxHeight;
        _lastViewportW = vw;
        _lastViewportH = vh;

        if (!_appliedInitial && vw > 1 && vh > 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _appliedInitial) return;
            _applyInitial(vw, vh);
            setState(() => _appliedInitial = true);
          });
        }

        final scale = _scaleNow();
        final panOk = widget.editable && scale > 1.01;

        final iv = InteractiveViewer(
          transformationController: _tc,
          minScale: 1.0,
          maxScale: 6.0,
          panEnabled: panOk,
          scaleEnabled: widget.editable,
          clipBehavior: Clip.hardEdge,
          onInteractionEnd: (_) {
            if (widget.editable) _emitChanged();
          },
          child: RotatedBox(
            quarterTurns: _quarterTurns,
            child: SizedBox(
              width: w,
              height: h,
              child: widget.videoChild,
            ),
          ),
        );

        if (!widget.editable) {
          return iv;
        }

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: iv,
        );
      },
    );
  }
}
