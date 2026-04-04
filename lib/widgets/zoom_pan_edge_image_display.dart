import 'dart:io';

import 'package:flutter/material.dart';

/// 先线性放大到 [maxScale]，再沿矩形区域「靠边」巡游（顺时针或逆时针），
/// 在总时长 [totalDuration] 结束时调用 [onAnimationComplete]（用于自动连播）。
class ZoomPanEdgeImageDisplay extends StatefulWidget {
  const ZoomPanEdgeImageDisplay({
    super.key,
    required this.imageFile,
    required this.totalDuration,
    required this.maxScale,
    this.clockwise = true,
    this.onAnimationComplete,
  });

  final File imageFile;
  final Duration totalDuration;
  final double maxScale;
  final bool clockwise;
  final VoidCallback? onAnimationComplete;

  @override
  State<ZoomPanEdgeImageDisplay> createState() =>
      _ZoomPanEdgeImageDisplayState();
}

class _ZoomPanEdgeImageDisplayState extends State<ZoomPanEdgeImageDisplay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 总时长中用于缩放阶段的比例，其余为靠边平移巡游
  static const double _zoomPhaseEnd = 0.28;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.totalDuration,
    );
    _controller.forward().then((_) {
      if (!mounted) return;
      widget.onAnimationComplete?.call();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 在给定缩放与视口下，相对中心的可平移半幅（与 Ken Burns 思路一致）
  static double _maxPanX(double viewW, double scale) {
    if (scale <= 1.001) return 0;
    return (viewW * (scale - 1)) / (2 * scale);
  }

  static double _maxPanY(double viewH, double scale) {
    if (scale <= 1.001) return 0;
    return (viewH * (scale - 1)) / (2 * scale);
  }

  /// [panT] ∈ [0,1]，沿闭合路径插值；顺时针：中→右上→右下→左下→左上→中
  static Offset _panOffset(
    double panT,
    double mx,
    double my,
    bool clockwise,
  ) {
    final List<Offset> pts = clockwise
        ? <Offset>[
            Offset.zero,
            Offset(mx, -my),
            Offset(mx, my),
            Offset(-mx, my),
            Offset(-mx, -my),
            Offset.zero,
          ]
        : <Offset>[
            Offset.zero,
            Offset(-mx, -my),
            Offset(-mx, my),
            Offset(mx, my),
            Offset(mx, -my),
            Offset.zero,
          ];

    final double pos = panT * (pts.length - 1);
    final int i = pos.floor().clamp(0, pts.length - 2);
    final double f = pos - i;
    return Offset.lerp(pts[i], pts[i + 1], f)!;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final double t = _controller.value;
            final double maxS = widget.maxScale.clamp(1.01, 8.0);
            double scale;
            double panT;
            if (t < _zoomPhaseEnd) {
              final double u = t / _zoomPhaseEnd;
              scale = 1.0 + (maxS - 1.0) * u;
              panT = 0;
            } else {
              scale = maxS;
              panT = (t - _zoomPhaseEnd) / (1.0 - _zoomPhaseEnd);
            }
            final double mx = _maxPanX(w, scale);
            final double my = _maxPanY(h, scale);
            final Offset offset = panT > 0
                ? _panOffset(panT, mx, my, widget.clockwise)
                : Offset.zero;

            return ClipRect(
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.center,
                child: Transform.translate(
                  offset: offset,
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: Image.file(
                      widget.imageFile,
                      fit: BoxFit.fitWidth,
                      alignment: Alignment.center,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
