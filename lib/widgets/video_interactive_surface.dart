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
    this.useScreenSizeForNormalization = false,
  });

  final VideoPlayerController videoController;
  /// 通常为 [Chewie]（可外包 [Theme]）。
  final Widget videoChild;
  final VideoViewParams initial;
  final bool editable;
  final ValueChanged<VideoViewParams>? onChanged;
  /// 为 true 时，平移归一化按整屏尺寸计算，减少不同页面容器高度差导致的复现偏移。
  final bool useScreenSizeForNormalization;

  @override
  State<VideoInteractiveSurface> createState() =>
      _VideoInteractiveSurfaceState();
}

class _VideoInteractiveSurfaceState extends State<VideoInteractiveSurface> {
  final TransformationController _tc = TransformationController();
  Timer? _debounce;
  int _quarterTurns = 0;
  bool _appliedInitial = false;
  bool _hasUserInteracted = false;

  double _lastViewportW = 1;
  double _lastViewportH = 1;
  double _lastNormBasisW = 1;
  double _lastNormBasisH = 1;
  double _lastAppliedBasisW = 1;
  double _lastAppliedBasisH = 1;
  bool _reapplyScheduled = false;

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
      _hasUserInteracted = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyInitial(_lastViewportW, _lastViewportH);
        setState(() => _appliedInitial = true);
      });
    }
  }

  void _onMatrixChanged() {
    if (!widget.editable || !mounted) return;
    if (!_hasUserInteracted) return;
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _emitChanged();
    });
  }

  void _emitChanged({bool force = false}) {
    if (!force && !_hasUserInteracted) return;
    final m = _tc.value;
    final t = m.getTranslation();
    final s = m.getMaxScaleOnAxis().clamp(1.0, 6.0);
    final bw = _lastNormBasisW;
    final bh = _lastNormBasisH;
    final tx = bw > 1e-6 ? t.x / bw : 0.0;
    final ty = bh > 1e-6 ? t.y / bh : 0.0;
    final current = VideoViewParams(
      scale: s,
      txNorm: tx,
      tyNorm: ty,
      quarterTurns: _quarterTurns,
    );
    if (current == widget.initial) return;
    widget.onChanged?.call(current);
  }

  void _applyInitial(double vw, double vh) {
    final p = widget.initial;
    final bw = _lastNormBasisW;
    final bh = _lastNormBasisH;
    _lastAppliedBasisW = bw;
    _lastAppliedBasisH = bh;
    _tc.value = Matrix4.identity()
      ..translate(p.txNorm * bw, p.tyNorm * bh)
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
    if (widget.editable) _hasUserInteracted = true;
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
    // 单指轨迹用于「7」形旋转识别；放大后仍需有效，故不再限制 scale。
    if (_activePointers.length == 1) {
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
    if (soloStroke && _strokePoints.length >= 8) {
      final rot = detectSevenStrokeRotation(List.from(_strokePoints));
      if (rot != null) {
        // 只更新 quarterTurns；[InteractiveViewer] 的缩放/平移保留在 [_tc] 中。
        setState(() {
          _quarterTurns = rot
              ? (_quarterTurns + 1) % 4
              : (_quarterTurns - 1) % 4;
          if (_quarterTurns < 0) _quarterTurns += 4;
        });
        _emitChanged(force: true);
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
        final view = View.of(context);
        final screenSize = Size(
          view.physicalSize.width / view.devicePixelRatio,
          view.physicalSize.height / view.devicePixelRatio,
        );
        _lastNormBasisW = widget.useScreenSizeForNormalization
            ? screenSize.width
            : vw;
        _lastNormBasisH = widget.useScreenSizeForNormalization
            ? screenSize.height
            : vh;

        if (!_appliedInitial && vw > 1 && vh > 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _appliedInitial) return;
            _applyInitial(vw, vh);
            setState(() => _appliedInitial = true);
          });
        }
        final basisChanged =
            (_lastNormBasisW - _lastAppliedBasisW).abs() > 0.5 ||
            (_lastNormBasisH - _lastAppliedBasisH).abs() > 0.5;
        if (_appliedInitial &&
            !_hasUserInteracted &&
            basisChanged &&
            !_reapplyScheduled) {
          _reapplyScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _reapplyScheduled = false;
            if (!mounted || _hasUserInteracted) return;
            _applyInitial(_lastViewportW, _lastViewportH);
          });
        }

        final scale = _scaleNow();
        // 防误触：单指只用于页面左右切换；仅双指接触时允许平移当前画面。
        final panOk =
            widget.editable &&
            _activePointers.length >= 2 &&
            scale > 1.01;

        final iv = InteractiveViewer(
          transformationController: _tc,
          minScale: 1.0,
          maxScale: 6.0,
          panEnabled: panOk,
          scaleEnabled: widget.editable,
          boundaryMargin: EdgeInsets.zero,
          constrained: true,
          clipBehavior: Clip.hardEdge,
          onInteractionStart: (_) {
            if (widget.editable) _hasUserInteracted = true;
          },
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
