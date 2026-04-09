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
  });

  final Widget child;
  final VideoViewParams initial;
  final bool editable;
  final bool singleFingerPanEnabled;
  final ValueChanged<VideoViewParams>? onChanged;
  final VoidCallback? onTripleTapReset;
  final bool useScreenSizeForNormalization;
  final double readonlyTranslateYOffset;

  @override
  State<ImageInteractiveSurface> createState() =>
      _ImageInteractiveSurfaceState();
}

class _ImageInteractiveSurfaceState extends State<ImageInteractiveSurface> {
  static const EdgeInsets _editableBoundaryMargin = EdgeInsets.all(100000);
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
    final extents = _panHalfExtents(
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: s,
      quarterTurns: _quarterTurns,
    );
    final tx =
        extents.maxX > 1e-6 ? (t.x / extents.maxX).clamp(-1.0, 1.0) : 0.0;
    final ty =
        extents.maxY > 1e-6 ? (t.y / extents.maxY).clamp(-1.0, 1.0) : 0.0;
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
    final scale = p.scale.clamp(1.0, 6.0).toDouble();
    final extents = _panHalfExtents(
      basisW: _lastNormBasisW,
      basisH: _lastNormBasisH,
      scale: scale,
      quarterTurns: _quarterTurns,
    );
    _lastAppliedBasisW = _lastNormBasisW;
    _lastAppliedBasisH = _lastNormBasisH;
    _tc.value =
        Matrix4.identity()
          ..translate(
            p.txNorm.clamp(-1.0, 1.0) * extents.maxX,
            p.tyNorm.clamp(-1.0, 1.0) * extents.maxY,
          )
          ..scale(scale);
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
    final s = scale.clamp(1.0, 6.0).toDouble();
    final tx = (_lastViewportW * (1 - s)) / 2;
    final ty = (_lastViewportH * (1 - s)) / 2;
    return Matrix4.identity()
      ..translate(tx, ty)
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
    _tc.removeListener(_onMatrixChanged);
    _tc.dispose();
    super.dispose();
  }

  Widget _buildRotatedContent(double vw, double vh, int q) {
    final inner = SizedBox(width: vw, height: vh, child: widget.child);
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
        final q = _quarterTurns % 4;
        final sideways = q == 1 || q == 3;
        final requiredPointerCount = widget.singleFingerPanEnabled ? 1 : 2;
        final panOk =
            widget.editable &&
            _activePointers.length >= requiredPointerCount &&
            (scale > 1.01 || sideways);

        final iv = InteractiveViewer(
          transformationController: _tc,
          alignment: Alignment.center,
          minScale: 1.0,
          maxScale: 6.0,
          panEnabled: panOk,
          scaleEnabled: widget.editable,
          boundaryMargin:
              widget.editable ? _editableBoundaryMargin : EdgeInsets.zero,
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
