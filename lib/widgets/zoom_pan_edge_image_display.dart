import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'image_layout_utils.dart';

/// 横向铺满、纵向等比例。
///
/// **逻辑**：总时长内 **20%** 放大 → **60%** 边沿巡游 → **20%** 缩回 1× 且平移回中心（恢复横向铺满、纵向等比例居中）。
/// 放大结束时画面居中；巡游段让视窗中心沿 **矩形嵌套螺旋** 先 **由内向外** 再 **由外回中心**，
/// 单程弧长约翻倍，同总时长下平均速度约减半，往返衔接更顺；比椭圆更易扫到四角。
/// 巡游时间与弧长比例线性对应，全程匀速；总墙时等于 [totalDuration]（不设隐藏倍率）。
/// [panPathCoverage]：巡游段内沿折线前进的比例（0.1～1），越小越舒缓，未走完亦可。
/// 巡游结束缩放不低于 vh/dh（横图时），使清晰层竖向盖住整屏。
/// 底层填充由 [letterboxFill] 控制（原固定黑底改为可配置）。
class ZoomPanEdgeImageDisplay extends StatefulWidget {
  const ZoomPanEdgeImageDisplay({
    super.key,
    required this.imageFile,
    required this.totalDuration,
    required this.maxScale,
    this.clockwise = true,
    this.panPathCoverage = 0.28,
    this.loop = false,
    this.onAnimationComplete,
    this.letterboxFill = ImageLetterboxFill.transparent,

    /// 为 true 时在 vw×vh 内整图 contain（与外层 90°/270° 旋转配合）。
    this.fitContainInViewport = false,
  });

  final File imageFile;
  final Duration totalDuration;
  final double maxScale;
  final bool clockwise;

  /// 单段动画巡游段中沿路径前进比例；越小同时间内位移越慢、越不必扫完整幅。
  final double panPathCoverage;
  final bool loop;
  final VoidCallback? onAnimationComplete;
  final ImageLetterboxFill letterboxFill;
  final bool fitContainInViewport;

  @override
  State<ZoomPanEdgeImageDisplay> createState() =>
      _ZoomPanEdgeImageDisplayState();
}

class _ZoomPanEdgeImageDisplayState extends State<ZoomPanEdgeImageDisplay>
    with SingleTickerProviderStateMixin {
  late Future<Size> _sizeFuture;
  late final AnimationController _controller;

  /// 循环播放时每次 +1，用于路径起点相位偏移，减轻重复感。
  int _spiralLoop = 0;

  List<Offset>? _rectPathCache;
  double? _cacheMx;
  double? _cacheMy;
  bool? _cacheCw;

  /// 放大起 / 巡游 / 缩回收尾 占归一化时间 [0,1] 的比例。
  static const double _zoomInEnd = 0.20;
  static const double _roamEnd = 0.80;

  static double _scaleAt({required double t, required double zoomEndScale}) {
    if (t < _zoomInEnd) {
      final u = Curves.easeInOut.transform(t / _zoomInEnd);
      return 1.0 + (zoomEndScale - 1.0) * u;
    }
    if (t < _roamEnd) {
      return zoomEndScale;
    }
    final uOut = Curves.easeInOut.transform((t - _roamEnd) / (1.0 - _roamEnd));
    return zoomEndScale + (1.0 - zoomEndScale) * uOut;
  }

  List<Offset> _rectPathFor(double mx, double my, bool cw) {
    if (_rectPathCache != null &&
        _cacheMx != null &&
        _cacheMy != null &&
        _cacheCw != null &&
        (_cacheMx! - mx).abs() < 1e-4 &&
        (_cacheMy! - my).abs() < 1e-4 &&
        _cacheCw == cw) {
      return _rectPathCache!;
    }
    _cacheMx = mx;
    _cacheMy = my;
    _cacheCw = cw;
    _rectPathCache = buildRectangularSpiralRoundTripPath(mx, my, cw);
    return _rectPathCache!;
  }

  @override
  void initState() {
    super.initState();
    _sizeFuture = measureImageFileSize(widget.imageFile);
    _controller = AnimationController(
      vsync: this,
      duration: widget.totalDuration,
    );
    _controller.addStatusListener(_onStatus);
    _controller.forward();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (widget.loop) {
      setState(() {
        _spiralLoop++;
      });
      _controller.reset();
      _controller.forward();
    } else {
      widget.onAnimationComplete?.call();
    }
  }

  @override
  void didUpdateWidget(ZoomPanEdgeImageDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageFile.path != widget.imageFile.path) {
      _sizeFuture = measureImageFileSize(widget.imageFile);
      _spiralLoop = 0;
      _rectPathCache = null;
      _cacheMx = null;
      _cacheMy = null;
      _cacheCw = null;
    }
    if (oldWidget.totalDuration != widget.totalDuration) {
      _controller.duration = widget.totalDuration;
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size>(
      future: _sizeFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ColoredBox(
            color: Colors.grey.shade900,
            child: Center(
              child: Text(
                '无法读取图片',
                style: TextStyle(color: Colors.grey.shade400),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final pixelSize = snapshot.data!;
        return LayoutBuilder(
          builder: (context, constraints) {
            final vw = constraints.maxWidth;
            final vh = constraints.maxHeight;
            final disp =
                widget.fitContainInViewport
                    ? containDisplaySize(pixelSize, vw, vh)
                    : fitWidthDisplaySize(pixelSize, vw);
            final double dw = disp.width;
            final double dh = disp.height;
            final double maxS = widget.maxScale.clamp(1.01, 10.0);
            notifyImageDisplayLayoutReady(context);
            // 横图 dh<vh 时需至少放大到 vh/dh，竖向才能被清晰图完全盖住（巡游时不再露模糊）
            final double coverFloor =
                widget.fitContainInViewport
                    ? 1.0
                    : (dh < vh - 0.5 ? (vh / dh).clamp(1.0, 10.0) : 1.0);
            final double zoomEndScale = math.max(maxS, coverFloor);

            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: [
                  letterboxFillLayer(widget.imageFile, widget.letterboxFill),
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      final double t = _controller.value;
                      final double scale = _scaleAt(
                        t: t,
                        zoomEndScale: zoomEndScale,
                      );
                      final limAtEnd = panHalfExtentAfterScale(
                        dw: dw,
                        dh: dh,
                        vw: vw,
                        vh: vh,
                        scale: zoomEndScale,
                      );
                      final double mxE = limAtEnd.maxX;
                      final double myE = limAtEnd.maxY;
                      final spiralPath = _rectPathFor(
                        mxE,
                        myE,
                        widget.clockwise,
                      );
                      final double cov = widget.panPathCoverage.clamp(
                        0.05,
                        1.0,
                      );
                      final double phase = (_spiralLoop % 4) / 4.0;

                      Offset offset;
                      if (t < _zoomInEnd) {
                        offset = Offset.zero;
                      } else if (t < _roamEnd) {
                        final double panSegT =
                            (t - _zoomInEnd) / (_roamEnd - _zoomInEnd);
                        final double pathU = (panSegT.clamp(0.0, 1.0) * cov)
                            .clamp(0.0, 1.0);
                        final Offset raw = sampleOffsetAlongPath(
                          spiralPath,
                          pathU,
                          pathPhaseShift: phase,
                        );
                        offset = Offset(
                          raw.dx.clamp(-mxE, mxE),
                          raw.dy.clamp(-myE, myE),
                        );
                      } else {
                        final uOut = Curves.easeInOut.transform(
                          (t - _roamEnd) / (1.0 - _roamEnd),
                        );
                        final pathUEnd = cov.clamp(0.0, 1.0);
                        final Offset offsetEnd = sampleOffsetAlongPath(
                          spiralPath,
                          pathUEnd,
                          pathPhaseShift: phase,
                        );
                        final Offset clampedEnd = Offset(
                          offsetEnd.dx.clamp(-mxE, mxE),
                          offsetEnd.dy.clamp(-myE, myE),
                        );
                        offset = Offset.lerp(clampedEnd, Offset.zero, uOut)!;
                        final limNow = panHalfExtentAfterScale(
                          dw: dw,
                          dh: dh,
                          vw: vw,
                          vh: vh,
                          scale: scale,
                        );
                        offset = Offset(
                          offset.dx.clamp(-limNow.maxX, limNow.maxX),
                          offset.dy.clamp(-limNow.maxY, limNow.maxY),
                        );
                      }

                      return Transform.translate(
                        offset: offset,
                        child: Transform.scale(
                          scale: scale,
                          alignment: Alignment.center,
                          child: child,
                        ),
                      );
                    },
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: dw,
                        height: dh,
                        child: Image.file(
                          widget.imageFile,
                          fit:
                              widget.fitContainInViewport
                                  ? BoxFit.contain
                                  : BoxFit.fitWidth,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.none,
                          cacheWidth: (vw *
                                  MediaQuery.devicePixelRatioOf(context) *
                                  zoomEndScale.clamp(1.0, 3.0))
                              .round()
                              .clamp(1, 8192),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
