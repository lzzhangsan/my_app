import 'dart:async';
import 'dart:math' show pi;

import 'package:flutter/material.dart';

import '../models/video_view_params.dart';
import 'video_seven_stroke.dart';

class ImageInteractiveSurface extends StatefulWidget {
  const ImageInteractiveSurface({
    super.key,
    required this.child,
    required this.initial,
    this.editable = true,
    this.singleFingerPanEnabled = false,
    this.onChanged,
    this.onTripleTapReset,
    this.useScreenSizeForNormalization = false,
    this.readonlyTranslateYOffset = 0,
    this.persistNonce = 0,
  });

  final Widget child;
  final VideoViewParams initial;
  final bool editable;
  final bool singleFingerPanEnabled;
  final ValueChanged<VideoViewParams>? onChanged;
  final VoidCallback? onTripleTapReset;
  final bool useScreenSizeForNormalization;
  final double readonlyTranslateYOffset;

  /// 父组件递增此值时，立即取消 debounce 并将当前矩阵写入 [onChanged]（用于「固定取景」或退出前落库）。
  final int persistNonce;

  @override
  State<ImageInteractiveSurface> createState() =>
      _ImageInteractiveSurfaceState();
}

class _ImageInteractiveSurfaceState extends State<ImageInteractiveSurface> {
  /// 须为「全向无限」边界，否则 InteractiveViewer 仍会夹紧平移，getTranslation 与归一化模型不一致，退出再进会漂移。
  static const EdgeInsets _editableBoundaryMargin = EdgeInsets.all(double.infinity);
  final TransformationController _tc = TransformationController();
  Timer? _debounce;
  int _quarterTurns = 0;
  bool _appliedInitial = false;
  bool _hasUserInteracted = false;

  double _lastViewportW = 1;
  double _lastViewportH = 1;
  /// 与 [_buildRotatedContent] 使用的 render 基准一致（视口或整屏）。
  double _renderBasisW = 1;
  double _renderBasisH = 1;
  /// [InteractiveViewer] 子控件外框（旋转 90°/270° 时为 vh×vw），平移归一化必须相对此框而非裸 vw×vh。
  double _ivPanBasisW = 1;
  double _ivPanBasisH = 1;
  double _lastAppliedBasisW = 1;
  double _lastAppliedBasisH = 1;
  bool _reapplyScheduled = false;
  double _interactionStartScale = 1.0;
  double _interactionStartTxNorm = 0.0;
  double _interactionStartTyNorm = 0.0;

  final Set<int> _activePointers = {};
  final List<Offset> _strokePoints = [];
  DateTime? _lastTapAt;
  int _tapCount = 0;
  DateTime? _singlePointerDownAt;
  Offset? _singlePointerDownPos;
  bool _singlePointerMovedTooFar = false;

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
      final current = _currentViewParams();
      if (widget.editable && _hasUserInteracted && current == widget.initial) {
        return;
      }
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
    if (widget.persistNonce != oldWidget.persistNonce) {
      _debounce?.cancel();
      if (widget.editable && _hasUserInteracted) {
        _emitChanged(force: true);
      }
    }
    // fitWidth 静态图：FutureBuilder 先占位再换 GestureDetector+LayoutBuilder，若仅在首帧应用矩阵会与「未操作」的恒等路径不一致。
    if (oldWidget.child.runtimeType != widget.child.runtimeType &&
        (!widget.editable || !_hasUserInteracted) &&
        _lastViewportW > 1 &&
        _lastViewportH > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.editable && _hasUserInteracted) return;
        _applyInitial(_lastViewportW, _lastViewportH);
      });
    }
  }

  void _onMatrixChanged() {
    if (!widget.editable || !mounted) return;
    if (!_hasUserInteracted) return;
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () {
      if (mounted) _emitChanged();
    });
  }

  void _emitChanged({bool force = false}) {
    if (!force && !_hasUserInteracted) return;
    final m = _tc.value;
    final t = m.getTranslation();
    final s = m.getMaxScaleOnAxis().clamp(1.0, 6.0);
    final centeredBase = _centeredBaseTranslation(
      basisW: _ivPanBasisW,
      basisH: _ivPanBasisH,
      scale: s,
      quarterTurns: 0,
    );
    final extents = _panHalfExtents(
      basisW: _ivPanBasisW,
      basisH: _ivPanBasisH,
      scale: s,
      quarterTurns: 0,
    );
    final tx = _normFromTranslation(
      translation: t.x,
      centeredBase: centeredBase.dx,
      extent: extents.maxX,
    );
    final ty = _normFromTranslation(
      translation: t.y,
      centeredBase: centeredBase.dy,
      extent: extents.maxY,
    );
    final current = VideoViewParams(
      scale: s,
      txNorm: tx,
      tyNorm: ty,
      quarterTurns: _quarterTurns,
      basisW: _ivPanBasisW >= 1 ? _ivPanBasisW : null,
      basisH: _ivPanBasisH >= 1 ? _ivPanBasisH : null,
    );
    if (!force && current == widget.initial) return;
    widget.onChanged?.call(current);
  }

  void _applyInitial(double vw, double vh) {
    var p = widget.initial.remappedToViewport(_ivPanBasisW, _ivPanBasisH);
    if (p.isLikelyIdentityTransform) {
      p = const VideoViewParams();
    }
    _lastAppliedBasisW = _ivPanBasisW;
    _lastAppliedBasisH = _ivPanBasisH;
    _setMatrixForView(scale: p.scale, txNorm: p.txNorm, tyNorm: p.tyNorm);
  }

  VideoViewParams _currentViewParams() {
    final m = _tc.value;
    final t = m.getTranslation();
    final s = m.getMaxScaleOnAxis().clamp(1.0, 6.0).toDouble();
    final centeredBase = _centeredBaseTranslation(
      basisW: _ivPanBasisW,
      basisH: _ivPanBasisH,
      scale: s,
      quarterTurns: 0,
    );
    final extents = _panHalfExtents(
      basisW: _ivPanBasisW,
      basisH: _ivPanBasisH,
      scale: s,
      quarterTurns: 0,
    );
    final txNorm = _normFromTranslation(
      translation: t.x,
      centeredBase: centeredBase.dx,
      extent: extents.maxX,
    );
    final tyNorm = _normFromTranslation(
      translation: t.y,
      centeredBase: centeredBase.dy,
      extent: extents.maxY,
    );
    return VideoViewParams(
      scale: s,
      txNorm: txNorm,
      tyNorm: tyNorm,
      quarterTurns: _quarterTurns,
      basisW: _ivPanBasisW >= 1 ? _ivPanBasisW : null,
      basisH: _ivPanBasisH >= 1 ? _ivPanBasisH : null,
    );
  }

  void _setMatrixForView({
    required double scale,
    required double txNorm,
    required double tyNorm,
  }) {
    final resolvedScale = scale.clamp(1.0, 6.0).toDouble();
    final centeredBase = _centeredBaseTranslation(
      basisW: _ivPanBasisW,
      basisH: _ivPanBasisH,
      scale: resolvedScale,
      quarterTurns: 0,
    );
    final extents = _panHalfExtents(
      basisW: _ivPanBasisW,
      basisH: _ivPanBasisH,
      scale: resolvedScale,
      quarterTurns: 0,
    );
    _tc.value = Matrix4.identity()
      ..translate(
        _translationFromNorm(
          norm: txNorm,
          centeredBase: centeredBase.dx,
          extent: extents.maxX,
        ),
        _translationFromNorm(
          norm: tyNorm,
          centeredBase: centeredBase.dy,
          extent: extents.maxY,
        ),
      )
      ..scale(resolvedScale);
  }

  double _normFromTranslation({
    required double translation,
    required double centeredBase,
    required double extent,
  }) {
    if (extent <= 1e-6) return 0.0;
    return (-(translation - centeredBase) / extent).clamp(-1.0, 1.0);
  }

  double _translationFromNorm({
    required double norm,
    required double centeredBase,
    required double extent,
  }) {
    if (extent <= 1e-6) return centeredBase;
    return centeredBase - norm.clamp(-1.0, 1.0) * extent;
  }

  Offset _centeredBaseTranslation({
    required double basisW,
    required double basisH,
    required double scale,
    required int quarterTurns,
  }) {
    final sideways = quarterTurns % 2 == 1;
    final childW = sideways ? basisH : basisW;
    final childH = sideways ? basisW : basisH;
    return Offset((basisW - childW * scale) / 2, (basisH - childH * scale) / 2);
  }

  ({double maxX, double maxY}) _panHalfExtents({
    required double basisW,
    required double basisH,
    required double scale,
    required int quarterTurns,
  }) {
    final sideways = quarterTurns % 2 == 1;
    final childW = sideways ? basisH : basisW;
    final childH = sideways ? basisW : basisH;
    final scaledW = childW * scale;
    final scaledH = childH * scale;
    return (
      maxX: ((scaledW - basisW) / 2).clamp(0.0, double.infinity),
      maxY: ((scaledH - basisH) / 2).clamp(0.0, double.infinity),
    );
  }

  void _resetToDefaultView() {
    if (!widget.editable) return;
    setState(() {
      _quarterTurns = 0;
      _tc.value = Matrix4.identity();
      _hasUserInteracted = true;
    });
    _emitChanged(force: true);
    widget.onTripleTapReset?.call();
  }

  double _scaleNow() {
    try {
      return _tc.value.getMaxScaleOnAxis();
    } catch (_) {
      return 1.0;
    }
  }

  Matrix4 _centeredScaleMatrix(double scale) {
    final params = _currentViewParams();
    final s = scale.clamp(1.0, 6.0).toDouble();
    final ivBox = _ivPanBox(_renderBasisW, _renderBasisH, _quarterTurns);
    final centeredBase = _centeredBaseTranslation(
      basisW: ivBox.w,
      basisH: ivBox.h,
      scale: s,
      quarterTurns: 0,
    );
    final extents = _panHalfExtents(
      basisW: ivBox.w,
      basisH: ivBox.h,
      scale: s,
      quarterTurns: 0,
    );
    return Matrix4.identity()
      ..translate(
        _translationFromNorm(
          norm: params.txNorm,
          centeredBase: centeredBase.dx,
          extent: extents.maxX,
        ),
        _translationFromNorm(
          norm: params.tyNorm,
          centeredBase: centeredBase.dy,
          extent: extents.maxY,
        ),
      )
      ..scale(s);
  }

  void _onPointerDown(PointerDownEvent e) {
    if (widget.editable) _hasUserInteracted = true;
    if (_activePointers.isEmpty) {
      _singlePointerDownAt = DateTime.now();
      _singlePointerDownPos = e.localPosition;
      _singlePointerMovedTooFar = false;
    } else {
      _singlePointerDownAt = null;
      _singlePointerDownPos = null;
      _singlePointerMovedTooFar = true;
      _tapCount = 0;
    }
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
    final downPos = _singlePointerDownPos;
    if (downPos != null && (e.localPosition - downPos).distance > 24.0) {
      _singlePointerMovedTooFar = true;
    }
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
    if (!widget.singleFingerPanEnabled &&
        soloStroke &&
        _strokePoints.length >= 8) {
      final rot = detectSevenStrokeRotation(List.from(_strokePoints));
      if (rot != null) {
        final preservedScale = _tc.value.getMaxScaleOnAxis().clamp(1.0, 6.0);
        setState(() {
          _quarterTurns =
              rot ? (_quarterTurns + 1) % 4 : (_quarterTurns - 1) % 4;
          if (_quarterTurns < 0) _quarterTurns += 4;
          _tc.value = _centeredScaleMatrix(preservedScale);
        });
        _emitChanged(force: true);
      }
    }
    final downAt = _singlePointerDownAt;
    if (soloStroke && !_singlePointerMovedTooFar && downAt != null) {
      final now = DateTime.now();
      if (_lastTapAt == null ||
          now.difference(_lastTapAt!) > const Duration(milliseconds: 700)) {
        _tapCount = 1;
      } else {
        _tapCount += 1;
      }
      _lastTapAt = now;
      if (_tapCount >= 3) {
        _tapCount = 0;
        _resetToDefaultView();
      }
    }
    _singlePointerDownAt = null;
    _singlePointerDownPos = null;
    _singlePointerMovedTooFar = false;
    _strokePoints.clear();
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _activePointers.remove(e.pointer);
    _strokePoints.clear();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (widget.editable && _hasUserInteracted) {
      _emitChanged(force: true);
    }
    _tc.removeListener(_onMatrixChanged);
    _tc.dispose();
    super.dispose();
  }

  /// [InteractiveViewer] 子控件最外层尺寸；90°/270° 时为 vh×vw，与 [_buildRotatedContent] 一致。
  ({double w, double h}) _ivPanBox(double rbW, double rbH, int q) {
    final qq = q % 4;
    if (qq == 1 || qq == 3) {
      return (w: rbH, h: rbW);
    }
    return (w: rbW, h: rbH);
  }

  Widget _buildRotatedContent(double basisW, double basisH, int q) {
    final inner = SizedBox(width: basisW, height: basisH, child: widget.child);
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
        width: basisH,
        height: basisW,
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
        final renderBasisW =
            widget.useScreenSizeForNormalization ? screenSize.width : vw;
        final renderBasisH =
            widget.useScreenSizeForNormalization ? screenSize.height : vh;
        _renderBasisW = renderBasisW;
        _renderBasisH = renderBasisH;
        final panBox = _ivPanBox(renderBasisW, renderBasisH, _quarterTurns);
        _ivPanBasisW = panBox.w;
        _ivPanBasisH = panBox.h;

        if (!_appliedInitial && vw > 1 && vh > 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _appliedInitial) return;
            _applyInitial(vw, vh);
            setState(() => _appliedInitial = true);
          });
        }
        final basisChanged =
            (_ivPanBasisW - _lastAppliedBasisW).abs() > 0.5 ||
                (_ivPanBasisH - _lastAppliedBasisH).abs() > 0.5;
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
        final sideways = q == 1 || q == 3;
        final requiredPointerCount = widget.singleFingerPanEnabled ? 1 : 2;
        final panOk = widget.editable &&
            _activePointers.length >= requiredPointerCount &&
            (scale > 1.01 || sideways);

        // 勿设 alignment：非 null 时 RenderTransform 会做 T(枢轴)*M*T(-枢轴)，
        // 而 _emitChanged 仍读控制器内裸矩阵的 getTranslation，二者不一致会存错 tx/ty，重进预览左/上偏。
        final viewer = InteractiveViewer(
          transformationController: _tc,
          minScale: 1.0,
          maxScale: 6.0,
          panEnabled: panOk,
          scaleEnabled: widget.editable,
          boundaryMargin:
              widget.editable ? _editableBoundaryMargin : EdgeInsets.zero,
          constrained: true,
          clipBehavior: sideways ? Clip.none : Clip.hardEdge,
          onInteractionStart: (_) {
            if (!widget.editable) return;
            _hasUserInteracted = true;
            final params = _currentViewParams();
            _interactionStartScale = params.scale;
            _interactionStartTxNorm = params.txNorm;
            _interactionStartTyNorm = params.tyNorm;
          },
          onInteractionUpdate: (details) {
            if (!widget.editable || _activePointers.length < 2) return;
            _setMatrixForView(
              scale: _interactionStartScale * details.scale,
              txNorm: _interactionStartTxNorm,
              tyNorm: _interactionStartTyNorm,
            );
          },
          onInteractionEnd: (_) {
            if (widget.editable) _emitChanged();
          },
          child: _buildRotatedContent(renderBasisW, renderBasisH, q),
        );

        if (!widget.editable) {
          return viewer;
        }

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: viewer,
        );
      },
    );
  }
}
