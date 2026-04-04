import 'dart:io';

import 'package:flutter/material.dart';

import 'image_layout_utils.dart';

/// 横向铺满、纵向等比例；留白为模糊底。巡游时平移在外、缩放在内，保证比例不变且不露出大片黑底。
class ZoomPanEdgeImageDisplay extends StatefulWidget {
  const ZoomPanEdgeImageDisplay({
    super.key,
    required this.imageFile,
    required this.totalDuration,
    required this.maxScale,
    this.clockwise = true,
    this.loop = false,
    this.onAnimationComplete,
  });

  final File imageFile;
  final Duration totalDuration;
  final double maxScale;
  final bool clockwise;
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

  static const double _zoomPhaseEnd = 0.28;

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
            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: [
                  blurredCoverBackground(widget.imageFile),
                  AnimatedBuilder(
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
                      final lim = panHalfExtentAfterScale(
                        dw: dw,
                        dh: dh,
                        vw: vw,
                        vh: vh,
                        scale: scale,
                      );
                      final double mx = lim.maxX;
                      final double my = lim.maxY;
                      final Offset raw = panT > 0
                          ? _panOffset(
                              panT,
                              mx,
                              my,
                              widget.clockwise,
                            )
                          : Offset.zero;
                      final Offset offset = Offset(
                        raw.dx.clamp(-mx, mx),
                        raw.dy.clamp(-my, my),
                      );

                      // 先 scale 再 translate：平移量表示屏幕像素，不被 scale 再乘一遍
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
