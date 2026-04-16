import 'dart:async';
import 'dart:math' show pi;

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
    this.onSingleFingerSwipeUp,
    this.onSingleFingerSwipeDown,
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
  final VoidCallback? onSingleFingerSwipeUp;
  final VoidCallback? onSingleFingerSwipeDown;
  final bool useScreenSizeForNormalization;

  /// 父组件递增此值时，立即将当前矩阵写入 [onChanged]。
  final int persistNonce;

  @override
  State<VideoInteractiveSurface> createState() =>
      _VideoInteractiveSurfaceState();
}

class _VideoInteractiveSurfaceState extends State<VideoInteractiveSurface> {
  static const EdgeInsets _editableBoundaryMargin = EdgeInsets.all(
    double.infinity,
  );
  final TransformationController _tc = TransformationController();
  Timer? _debounce;
  int _quarterTurns = 0;
  bool _appliedInitial = false;
  bool _hasUserInteracted = false;

  double _lastViewportW = 1;
  double _lastViewportH = 1;
  double _renderBasisW = 1;
  double _renderBasisH = 1;
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
      anchorXNorm: _anchorNormFromTranslation(t.x, _ivPanBasisW),
      anchorYNorm: _anchorNormFromTranslation(t.y, _ivPanBasisH),
    );
    if (!force && current == widget.initial) return;
    widget.onChanged?.call(current);
  }

  void _applyInitial(double vw, double vh) {
    var p = widget.initial.remappedToViewport(_ivPanBasisW, _ivPanBasisH);
    if (p.isLikelyIdentityTransform &&
        p.anchorXNorm == null &&
        p.anchorYNorm == null) {
      p = const VideoViewParams();
    }
    _lastAppliedBasisW = _ivPanBasisW;
    _lastAppliedBasisH = _ivPanBasisH;
    _setMatrixForParams(p);
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
      anchorXNorm: _anchorNormFromTranslation(t.x, _ivPanBasisW),
      anchorYNorm: _anchorNormFromTranslation(t.y, _ivPanBasisH),
    );
  }

  void _setMatrixForParams(VideoViewParams params) {
    final hasAnchor = params.anchorXNorm != null && params.anchorYNorm != null;
    if (hasAnchor) {
      _setMatrixForAnchor(
        scale: params.scale,
        anchorXNorm: params.anchorXNorm!,
        anchorYNorm: params.anchorYNorm!,
      );
      return;
    }
    _setMatrixForView(
      scale: params.scale,
      txNorm: params.txNorm,
      tyNorm: params.tyNorm,
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
    _tc.value =
        Matrix4.identity()
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

  void _setMatrixForAnchor({
    required double scale,
    required double anchorXNorm,
    required double anchorYNorm,
  }) {
    final resolvedScale = scale.clamp(1.0, 6.0).toDouble();
    _tc.value =
        Matrix4.identity()
          ..translate(anchorXNorm * _ivPanBasisW, anchorYNorm * _ivPanBasisH)
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

  double? _anchorNormFromTranslation(double translation, double basis) {
    if (basis <= 1e-6) return null;
    return translation / basis;
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
    if (params.anchorXNorm != null && params.anchorYNorm != null) {
      return Matrix4.identity()
        ..translate(
          params.anchorXNorm! * _ivPanBasisW,
          params.anchorYNorm! * _ivPanBasisH,
        )
        ..scale(s);
    }
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
    var handledSwipePreset = false;
    if (soloStroke && _singlePointerDownPos != null && _strokePoints.length >= 2) {
      final start = _singlePointerDownPos!;
      final end = _strokePoints.last;
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final absDx = dx.abs();
      final absDy = dy.abs();
      if (absDy >= 90 && absDy >= absDx * 1.35) {
        if (dy <= -90) {
          widget.onSingleFingerSwipeUp?.call();
          handledSwipePreset = true;
          _tapCount = 0;
          _lastTapAt = null;
        } else if (dy >= 90) {
          widget.onSingleFingerSwipeDown?.call();
          handledSwipePreset = true;
          _tapCount = 0;
          _lastTapAt = null;
        }
      }
    }
    final downAt = _singlePointerDownAt;
    if (!handledSwipePreset &&
        soloStroke &&
        !_singlePointerMovedTooFar &&
        downAt != null) {
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

  ({double w, double h}) _ivPanBox(double rbW, double rbH, int q) {
    final qq = q % 4;
    if (qq == 1 || qq == 3) {
      return (w: rbH, h: rbW);
    }
    return (w: rbW, h: rbH);
  }

  /// 与 [ImageInteractiveSurface._buildRotatedContent] 同构；视频在 basisW×basisH 内 contain 放置。
  Widget _buildRotatedVideoContent(double basisW, double basisH, int q) {
    final sz = widget.videoController.value.size;
    final videoW = sz.width;
    final videoH = sz.height;
    final inner = SizedBox(
      width: basisW,
      height: basisH,
      child: Center(
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.center,
          child: SizedBox(
            width: videoW,
            height: videoH,
            child: widget.videoChild,
          ),
        ),
      ),
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
    if (!widget.videoController.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final size = widget.videoController.value.size;
    if (size.width <= 0 || size.height <= 0) {
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
        final panOk =
            widget.editable &&
            _activePointers.length >= requiredPointerCount &&
            (scale > 1.01 || sideways);

        // 勿设 alignment，与 [ImageInteractiveSurface] 相同原因（裸矩阵读写须与 Transform 一致）。
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
          child: _buildRotatedVideoContent(renderBasisW, renderBasisH, q),
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
