import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'image_layout_utils.dart';

/// 初次：横向铺满屏幕宽度、纵向等比例居中；上下留白由 [letterboxFill] 控制。
/// 仅使用等比缩放（Transform.scale），图片用 BoxFit.fitWidth，不拉伸变形。
/// 总时长内：前半放大至 [maxScale]，后半缩回 1×，各占 50%。
/// [loop] 为 true 时（手动模式）动画结束自动从头循环。
///
/// [zoomCenterX]、[zoomCenterY] 为相对图片显示区域左上角的归一化坐标 0～1（默认 0.5 即几何中心）。
/// 实现上先将该点平移到视口中心，再绕中心缩放，使最大倍率时该点始终在屏幕正中，便于细看。
/// 开启 [enableDoubleTapToSetZoomCenter] 且提供 [onZoomCenterSet] 时，双击图片可将该点存为新中心（由上层写入数据库）。
class KenBurnsImageDisplay extends StatefulWidget {
  const KenBurnsImageDisplay({
    super.key,
    required this.imageFile,
    required this.animationDuration,
    this.maxScale = 3.0,
    this.loop = false,
    this.onAnimationComplete,
    this.letterboxFill = ImageLetterboxFill.transparent,
    this.zoomCenterX,
    this.zoomCenterY,
    this.enableDoubleTapToSetZoomCenter = false,
    this.onZoomCenterSet,
  });

  final File imageFile;
  final Duration animationDuration;
  final double maxScale;
  final bool loop;
  final VoidCallback? onAnimationComplete;
  final ImageLetterboxFill letterboxFill;
  /// 缩放锚点横坐标 0～1，null 表示 0.5。
  final double? zoomCenterX;
  /// 缩放锚点纵坐标 0～1，null 表示 0.5。
  final double? zoomCenterY;
  final bool enableDoubleTapToSetZoomCenter;
  final Future<void> Function(double nx, double ny)? onZoomCenterSet;

  @override
  State<KenBurnsImageDisplay> createState() => _KenBurnsImageDisplayState();
}

class _KenBurnsImageDisplayState extends State<KenBurnsImageDisplay>
    with SingleTickerProviderStateMixin {
  late Future<Size> _sizeFuture;
  late AnimationController _controller;

  static const double _zoomInEnd = 0.5;

  double get _nx => (widget.zoomCenterX ?? 0.5).clamp(0.0, 1.0);
  double get _ny => (widget.zoomCenterY ?? 0.5).clamp(0.0, 1.0);

  /// 将归一化点 (nx,ny) 平移到 [SizedBox] 中心后再绕中心缩放，避免「锚点固定在一侧」导致角点跑出视野。
  Offset _centerPointOffset(double dw, double dh) {
    return Offset(dw * (0.5 - _nx), dh * (0.5 - _ny));
  }

  @override
  void initState() {
    super.initState();
    _sizeFuture = measureImageFileSize(widget.imageFile);
    _controller = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );
    _controller.addStatusListener(_onStatus);
    _controller.forward();
  }

  double _scaleForT(double t, double maxScale) {
    if (t < _zoomInEnd) {
      final u = Curves.easeInOut.transform(t / _zoomInEnd);
      return 1.0 + (maxScale - 1.0) * u;
    }
    final u = Curves.easeInOut.transform((t - _zoomInEnd) / (1.0 - _zoomInEnd));
    return maxScale + (1.0 - maxScale) * u;
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
  void didUpdateWidget(KenBurnsImageDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageFile.path != widget.imageFile.path) {
      _sizeFuture = measureImageFileSize(widget.imageFile);
    }
    if (oldWidget.animationDuration != widget.animationDuration) {
      _controller.duration = widget.animationDuration;
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  void _handleDoubleTapDown(TapDownDetails details, double dw, double dh) {
    if (!widget.enableDoubleTapToSetZoomCenter ||
        widget.onZoomCenterSet == null) {
      return;
    }
    final lp = details.localPosition;
    final nx = (lp.dx / dw).clamp(0.0, 1.0);
    final ny = (lp.dy / dh).clamp(0.0, 1.0);
    unawaited(widget.onZoomCenterSet!(nx, ny));
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
            final cacheW = (vw *
                    MediaQuery.devicePixelRatioOf(context) *
                    widget.maxScale.clamp(1.0, 3.0))
                .round()
                .clamp(1, 8192);
            final disp = fitWidthDisplaySize(pixelSize, vw);
            final dw = disp.width;
            final dh = disp.height;
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                letterboxFillLayer(widget.imageFile, widget.letterboxFill),
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final s = _scaleForT(_controller.value, widget.maxScale);
                    return Transform.scale(
                      scale: s,
                      alignment: Alignment.center,
                      child: Transform.translate(
                        offset: _centerPointOffset(dw, dh),
                        child: child,
                      ),
                    );
                  },
                  child: RepaintBoundary(
                    child: SizedBox(
                      width: dw,
                      height: dh,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTapDown: (d) {
                          _handleDoubleTapDown(d, dw, dh);
                        },
                        child: Image.file(
                          widget.imageFile,
                          fit: BoxFit.fitWidth,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.none,
                          cacheWidth: cacheW,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
