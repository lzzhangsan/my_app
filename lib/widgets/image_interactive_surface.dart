import 'dart:async';
import 'dart:math' show pi;

import 'package:flutter/material.dart';

import '../models/video_view_params.dart';
import 'video_seven_stroke.dart';

/// 媒体页图片：双指缩放、单指平移（放大后）、「7」形旋转；与 [VideoInteractiveSurface] 一致写入 `video_view_*`。
class ImageInteractiveSurface extends StatefulWidget {
  const ImageInteractiveSurface({
    super.key,
    required this.child,
    required this.initial,
    this.editable = true,
    this.onChanged,
    this.useScreenSizeForNormalization = false,
    this.readonlyTranslateYOffset = 0,
  });

  final Widget child;
  final VideoViewParams initial;
  final bool editable;
  final ValueChanged<VideoViewParams>? onChanged;
  /// 为 true 时，平移归一化按整屏尺寸计算，减少不同页面容器高度差导致的复现偏移。
  final bool useScreenSizeForNormalization;
  /// 仅用于只读展示时的额外纵向像素补偿（>0 向下）。
  final double readonlyTranslateYOffset;

  @override
  State<ImageInteractiveSurface> createState() =>
      _ImageInteractiveSurfaceState();
}

class _ImageInteractiveSurfaceState extends State<ImageInteractiveSurface> {
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
  void didUpdateWidget(covariant ImageInteractiveSurface oldWidget) {
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
      ..translate(p.txNorm * bw, p.tyNorm * bh + widget.readonlyTranslateYOffset)
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
        // 与 [VideoInteractiveSurface] 一致：旋转保留当前缩放；平移在旋转后视口坐标系中不再可靠，重置以免卡在边界外。
        final preservedScale =
            _tc.value.getMaxScaleOnAxis().clamp(1.0, 6.0);
        setState(() {
          _quarterTurns = rot
              ? (_quarterTurns + 1) % 4
              : (_quarterTurns - 1) % 4;
          if (_quarterTurns < 0) _quarterTurns += 4;
          _tc.value = Matrix4.identity()..scale(preservedScale);
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

  /// 内层始终以「竖屏视口」vw×vh 排版；90°/270° 时用 vh×vw 的外框作为 [InteractiveViewer] 子尺寸，
  /// 使其可平移范围与旋转后的画幅一致（避免只能看到中间一条）。
  Widget _buildRotatedContent(double vw, double vh, int q) {
    final inner = SizedBox(
      width: vw,
      height: vh,
      child: widget.child,
    );
    Widget rotated;
    if (q == 0) {
      rotated = inner;
    } else {
      rotated = Transform.rotate(
        angle: q * pi / 2,
        alignment: Alignment.center,
        filterQuality: FilterQuality.low,
        child: inner,
      );
    }
    if (q == 1 || q == 3) {
      return SizedBox(
        width: vh,
        height: vw,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [rotated],
        ),
      );
    }
    return rotated;
  }

  @override
  Widget build(BuildContext context) {
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
        final q = _quarterTurns % 4;
        // 90°/270° 时轴对齐包围盒为 vh×vw，大于竖屏视口宽度，必须在未缩放时也允许平移才能看到左右裁切区。
        final sideways = q == 1 || q == 3;
        final panOk = widget.editable && (scale > 1.01 || sideways);

        final iv = InteractiveViewer(
          transformationController: _tc,
          minScale: 1.0,
          maxScale: 6.0,
          panEnabled: panOk,
          scaleEnabled: widget.editable,
          boundaryMargin: widget.editable
              ? const EdgeInsets.all(double.infinity)
              : EdgeInsets.zero,
          constrained: widget.editable ? false : true,
          clipBehavior: sideways ? Clip.none : Clip.hardEdge,
          onInteractionStart: (_) {
            if (widget.editable) _hasUserInteracted = true;
          },
          onInteractionEnd: (_) {
            if (widget.editable) _emitChanged();
          },
          child: _buildRotatedContent(vw, vh, q),
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
