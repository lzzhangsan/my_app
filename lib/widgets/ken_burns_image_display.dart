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
/// 最小倍率（1×）时不额外平移，保持横向铺满、纵向等比居中；倍率越高，越将该点移向视口中心，
/// 最大倍率时该点落在屏幕正中。平移量与 `(scale-1)/(maxScale-1)` 成比例，缩回 1× 时不留单侧空白。
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
  /// 「从原图放大到最大」阶段为 [0, _zoomInEnd]；其时间前 10% 内显示中心点标记。
  static const double _zoomInMarkerShowFraction = 0.1;

  double get _nx => (widget.zoomCenterX ?? 0.5).clamp(0.0, 1.0);
  double get _ny => (widget.zoomCenterY ?? 0.5).clamp(0.0, 1.0);

  /// 数据库中已保存过中心点（与默认几何中心区分）。
  bool get _hasCustomZoomCenter =>
      widget.zoomCenterX != null && widget.zoomCenterY != null;

  /// 渐进放大：最小倍率时显示；从原图→最大倍率过程的前 10% 时间内也显示，其余放大过程隐藏。
  bool _zoomCenterMarkerVisible(double tAnim, double s) {
    if (!_hasCustomZoomCenter) return false;
    final inZoomInLead =
        tAnim < _zoomInEnd * _zoomInMarkerShowFraction;
    final atMinScale = s <= 1.001;
    return inZoomInLead || atMinScale;
  }

  /// 将 (nx,ny) 移到 [SizedBox] 中心所需的平移；[blend] 为 0～1，与缩放进度同步，0 表示不平移。
  Offset _centerPointOffset(double dw, double dh, double blend) {
    final b = blend.clamp(0.0, 1.0);
    return Offset(
      dw * (0.5 - _nx) * b,
      dh * (0.5 - _ny) * b,
    );
  }

  /// 与当前 scale 同步：1× 时为 0，[maxScale] 时为 1，缩小时与放大对称回退。
  static double _translateBlendForScale(double s, double maxScale) {
    if (maxScale <= 1.0 + 1e-9) return 0.0;
    return ((s - 1.0) / (maxScale - 1.0)).clamp(0.0, 1.0);
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
              children: [
                letterboxFillLayer(widget.imageFile, widget.letterboxFill),
                // 与 FitWidth 一致：用 Align 在整页内居中 dw×dh 内容。仅依赖 Stack.alignment
                // 在「Positioned.fill 底 + 非定位子」组合下可能不可靠，导致渐进放大时整块图贴顶。
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.center,
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        final s =
                            _scaleForT(_controller.value, widget.maxScale);
                        final blend =
                            _translateBlendForScale(s, widget.maxScale);
                        return Transform.scale(
                          scale: s,
                          alignment: Alignment.center,
                          child: Transform.translate(
                            offset: _centerPointOffset(dw, dh, blend),
                            child: RepaintBoundary(
                              child: SizedBox(
                                width: dw,
                                height: dh,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    GestureDetector(
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
                                    if (_hasCustomZoomCenter)
                                      ZoomCenterMarker(
                                        nx: _nx,
                                        ny: _ny,
                                        width: dw,
                                        height: dh,
                                        visible: _zoomCenterMarkerVisible(
                                          _controller.value,
                                          s,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
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
