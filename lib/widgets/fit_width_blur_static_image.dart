import 'dart:io';

import 'package:flutter/material.dart';

import 'image_layout_utils.dart';

/// 横向填满、纵向等比例居中；留白处由 [letterboxFill] 控制（默认纯白）。
class FitWidthBlurStaticImage extends StatefulWidget {
  const FitWidthBlurStaticImage({
    super.key,
    required this.file,
    this.letterboxFill = ImageLetterboxFill.white,
  });

  final File file;
  final ImageLetterboxFill letterboxFill;

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
            final cacheW = (vw * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 8192);
            final disp = fitWidthDisplaySize(pixelSize, vw);
            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  letterboxFillLayer(widget.file, widget.letterboxFill),
                  Center(
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: disp.width,
                        height: disp.height,
                        child: Image.file(
                          widget.file,
                          fit: BoxFit.fill,
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
