import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'image_layout_utils.dart';

/// 横向铺满、纵向等比例。
///
/// **逻辑**：先把图缩放到目标倍数（视窗大小不变，相当于「手持放大后的照片」）；
/// 放大结束时画面居中；再在可平移范围内，让视窗中心沿 **矩形嵌套螺旋** 先 **由内向外** 再 **由外回中心**，
/// 单程弧长约翻倍，同总时长下平均速度约减半，往返衔接更顺；比椭圆更易扫到四角。
/// 巡游时间与弧长比例线性对应，全程匀速；总墙时等于 [totalDuration]（不设隐藏倍率）。
/// [panPathCoverage]：巡游段内沿折线前进的比例（0.1～1），越小越舒缓，未走完亦可。
/// 巡游结束缩放不低于 vh/dh（横图时），使清晰层竖向盖住整屏，巡游时可隐藏模糊底。
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
  });

  final File imageFile;
  final Duration totalDuration;
  final double maxScale;
  final bool clockwise;
  /// 单段动画巡游段中沿路径前进比例；越小同时间内位移越慢、越不必扫完整幅。
  final double panPathCoverage;
  final bool loop;
  final VoidCallback? onAnimationComplete;

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

  /// 动画前段仅放大，占 [totalDuration] 的 30%；后段巡游占 70%。
  static const double _zoomPhaseEnd = 0.30;

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

  /// 模糊底仅在「清晰层尚未竖向铺满」时显示；巡游阶段通常已抬升缩放可隐藏。
  static double _blurOpacity({
    required double t,
    required double scale,
    required double dh,
    required double vh,
  }) {
    if (scale * dh >= vh - 0.5) {
      return 0;
    }
    return 1;
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
            final disp = fitWidthDisplaySize(pixelSize, vw);
            final double dw = disp.width;
            final double dh = disp.height;
            final double maxS = widget.maxScale.clamp(1.01, 8.0);
            // 横图 dh<vh 时需至少放大到 vh/dh，竖向才能被清晰图完全盖住（巡游时不再露模糊）
            final double coverFloor =
                dh < vh - 0.5 ? (vh / dh).clamp(1.0, 8.0) : 1.0;
            final double zoomEndScale = math.max(maxS, coverFloor);

            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final double t = _controller.value;
                      double scale;
                      if (t < _zoomPhaseEnd) {
                        final double u = Curves.easeInOut
                            .transform(t / _zoomPhaseEnd);
                        scale = 1.0 + (zoomEndScale - 1.0) * u;
                      } else {
                        scale = zoomEndScale;
                      }
                      final op = _blurOpacity(
                        t: t,
                        scale: scale,
                        dh: dh,
                        vh: vh,
                      );
                      return Opacity(
                        opacity: op,
                        child: blurredCoverBackground(widget.imageFile),
                      );
                    },
                  ),
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      final double t = _controller.value;
                      double scale;
                      double panT;
                      if (t < _zoomPhaseEnd) {
                        final double u = Curves.easeInOut
                            .transform(t / _zoomPhaseEnd);
                        scale = 1.0 + (zoomEndScale - 1.0) * u;
                        panT = 0;
                      } else {
                        scale = zoomEndScale;
                        panT = (t - _zoomPhaseEnd) / (1.0 - _zoomPhaseEnd);
                      }
                      final lim = panHalfExtentAfterScale(
                        dw: dw,
                        dh: dh,
                        vw: vw,
                        vh: vh,
                        scale: scale,
                      );
                      final double mx = lim.maxX;
                      final double my = lim.maxY;
                      final spiralPath =
                          _rectPathFor(mx, my, widget.clockwise);
                      final double cov =
                          widget.panPathCoverage.clamp(0.05, 1.0);
                      final double pathU =
                          (panT.clamp(0.0, 1.0) * cov).clamp(0.0, 1.0);
                      // 巡游段：弧长比例匀速（缩放段仍用 easeInOut）
                      final Offset raw = panT > 0
                          ? sampleOffsetAlongPath(
                              spiralPath,
                              pathU,
                              pathPhaseShift: (_spiralLoop % 4) / 4.0,
                            )
                          : Offset.zero;
                      final Offset offset = Offset(
                        raw.dx.clamp(-mx, mx),
                        raw.dy.clamp(-my, my),
                      );

                      return Transform.translate(
                        offset: offset,
                        child: Transform.scale(
                          scale: scale,
                          alignment: Alignment.center,
                          child: child,
                        ),
                      );
                    },
                    child: SizedBox(
                      width: dw,
                      height: dh,
                      child: Image.file(
                        widget.imageFile,
                        fit: BoxFit.fitWidth,
                        alignment: Alignment.center,
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
