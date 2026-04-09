import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/video_view_params.dart';
import 'video_seven_stroke.dart';

class VideoInteractiveSurface extends StatefulWidget {
  const VideoInteractiveSurface({
    super.key,
    required this.videoController,
    required this.videoChild,
    required this.initial,
    this.editable = true,
    this.singleFingerPanEnabled = false,
    this.onChanged,
    this.onTripleTapReset,
    this.useScreenSizeForNormalization = false,
    this.persistNonce = 0,
  });

  final VideoPlayerController videoController;
  final Widget videoChild;
  final VideoViewParams initial;
  final bool editable;
  final bool singleFingerPanEnabled;
  final ValueChanged<VideoViewParams>? onChanged;
  final VoidCallback? onTripleTapReset;
  final bool useScreenSizeForNormalization;

  /// 父组件递增此值时，立即将当前矩阵写入 [onChanged]。
  final int persistNonce;

  @override
  State<VideoInteractiveSurface> createState() =>
      _VideoInteractiveSurfaceState();
}

class _VideoInteractiveSurfaceState extends State<VideoInteractiveSurface> {
  static const EdgeInsets _editableBoundaryMargin = EdgeInsets.all(double.infinity);
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
  void didUpdateWidget(covariant VideoInteractiveSurface oldWidget) {
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
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: s,
      quarterTurns: _quarterTurns,
    );
    final extents = _panHalfExtents(
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: s,
      quarterTurns: _quarterTurns,
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
    );
    if (!force && current == widget.initial) return;
    widget.onChanged?.call(current);
  }

  void _applyInitial(double vw, double vh) {
    final p = widget.initial;
    _lastAppliedBasisW = _lastNormBasisW;
    _lastAppliedBasisH = _lastNormBasisH;
    _setMatrixForView(scale: p.scale, txNorm: p.txNorm, tyNorm: p.tyNorm);
  }

  VideoViewParams _currentViewParams() {
    final m = _tc.value;
    final t = m.getTranslation();
    final s = m.getMaxScaleOnAxis().clamp(1.0, 6.0).toDouble();
    final centeredBase = _centeredBaseTranslation(
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: s,
      quarterTurns: _quarterTurns,
    );
    final extents = _panHalfExtents(
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: s,
      quarterTurns: _quarterTurns,
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
    );
  }

  void _setMatrixForView({
    required double scale,
    required double txNorm,
    required double tyNorm,
  }) {
    final resolvedScale = scale.clamp(1.0, 6.0).toDouble();
    final centeredBase = _centeredBaseTranslation(
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: resolvedScale,
      quarterTurns: _quarterTurns,
    );
    final extents = _panHalfExtents(
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: resolvedScale,
      quarterTurns: _quarterTurns,
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
    final centeredBase = _centeredBaseTranslation(
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: s,
      quarterTurns: _quarterTurns,
    );
    final extents = _panHalfExtents(
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: s,
      quarterTurns: _quarterTurns,
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
        setState(() {
          _quarterTurns =
              rot ? (_quarterTurns + 1) % 4 : (_quarterTurns - 1) % 4;
          if (_quarterTurns < 0) _quarterTurns += 4;
          _tc.value = _centeredScaleMatrix(_tc.value.getMaxScaleOnAxis());
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
        _lastNormBasisW =
            widget.useScreenSizeForNormalization ? screenSize.width : vw;
        _lastNormBasisH =
            widget.useScreenSizeForNormalization ? screenSize.height : vh;

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
        final requiredPointerCount = widget.singleFingerPanEnabled ? 1 : 2;
        final panOk = widget.editable &&
            _activePointers.length >= requiredPointerCount &&
            scale > 1.01;

        // 勿设 alignment，与 [ImageInteractiveSurface] 相同原因（裸矩阵读写须与 Transform 一致）。
        final iv = InteractiveViewer(
          transformationController: _tc,
          minScale: 1.0,
          maxScale: 6.0,
          panEnabled: panOk,
          scaleEnabled: widget.editable,
          boundaryMargin:
              widget.editable ? _editableBoundaryMargin : EdgeInsets.zero,
          constrained: true,
          clipBehavior: Clip.hardEdge,
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
          child: RotatedBox(
            quarterTurns: _quarterTurns,
            child: SizedBox(width: w, height: h, child: widget.videoChild),
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
