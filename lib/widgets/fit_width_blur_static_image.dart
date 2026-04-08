import 'dart:io';

import 'package:flutter/material.dart';

import 'image_layout_utils.dart';

/// 横向填满、纵向等比例居中；留白处由 [letterboxFill] 控制（默认透明）。
class FitWidthBlurStaticImage extends StatefulWidget {
  const FitWidthBlurStaticImage({
    super.key,
    required this.file,
    this.letterboxFill = ImageLetterboxFill.transparent,
    this.fitContainInViewport = false,
    this.zoomCenterX,
    this.zoomCenterY,
  });

  final File file;
  final ImageLetterboxFill letterboxFill;
  final bool fitContainInViewport;
  /// 已保存的渐进放大中心横坐标（与 [zoomCenterY] 同时非 null 时在图上显示标记）。
  final double? zoomCenterX;
  /// 已保存的渐进放大中心纵坐标。
  final double? zoomCenterY;

  @override
  State<FitWidthBlurStaticImage> createState() =>
      _FitWidthBlurStaticImageState();
}

class _FitWidthBlurStaticImageState extends State<FitWidthBlurStaticImage> {
  late Future<Size> _sizeFuture;

  @override
  void initState() {
    super.initState();
    _sizeFuture = measureImageFileSize(widget.file);
  }

  @override
  void didUpdateWidget(FitWidthBlurStaticImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _sizeFuture = measureImageFileSize(widget.file);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size>(
      future: _sizeFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text(
              '无法读取图片',
              style: TextStyle(color: Colors.grey.shade700),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final pixelSize = snapshot.data!;
        return LayoutBuilder(
          builder: (context, constraints) {
            final vw = constraints.maxWidth;
            final vh = constraints.maxHeight;
            final cacheW = (vw * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 8192);
            final disp = widget.fitContainInViewport
                ? containDisplaySize(pixelSize, vw, vh)
                : fitWidthDisplaySize(pixelSize, vw);
            final showCenterMarker = widget.zoomCenterX != null &&
                widget.zoomCenterY != null;
            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                // 默认 topStart 会把「仅包住图片」的 Center 贴到左上角，横图会纵向顶格。
                alignment: Alignment.center,
                children: [
                  letterboxFillLayer(widget.file, widget.letterboxFill),
                  Center(
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: disp.width,
                        height: disp.height,
                        child: showCenterMarker
                            ? Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Image.file(
                                    widget.file,
                                    fit: widget.fitContainInViewport
                                        ? BoxFit.contain
                                        : BoxFit.fill,
                                    filterQuality: FilterQuality.medium,
                                    cacheWidth: cacheW,
                                  ),
                                  ZoomCenterMarker(
                                    nx: widget.zoomCenterX!.clamp(0.0, 1.0),
                                    ny: widget.zoomCenterY!.clamp(0.0, 1.0),
                                    width: disp.width,
                                    height: disp.height,
                                  ),
                                ],
                              )
                            : Image.file(
                                widget.file,
                                fit: widget.fitContainInViewport
                                    ? BoxFit.contain
                                    : BoxFit.fill,
                                filterQuality: FilterQuality.medium,
                                cacheWidth: cacheW,
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
