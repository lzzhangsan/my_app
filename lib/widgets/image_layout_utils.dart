import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 读取图片像素尺寸。
Future<Size> measureImageFileSize(File file) async {
  final bytes = await file.readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final w = frame.image.width.toDouble();
  final h = frame.image.height.toDouble();
  frame.image.dispose();
  codec.dispose();
  return Size(w, h);
}

/// 横向填满视口宽度、纵向按原图比例（与 BoxFit.fitWidth 一致）。
Size fitWidthDisplaySize(Size imageSize, double viewportW) {
  final h = viewportW * imageSize.height / imageSize.width;
  return Size(viewportW, h);
}

/// BoxFit.cover：整屏均被图片盖住，宽与高均 ≥ 视口对应边（一边贴齐、一边超出可裁切）。
Size coverDisplaySize(Size imageSize, double viewportW, double viewportH) {
  final s = math.max(
    viewportW / imageSize.width,
    viewportH / imageSize.height,
  );
  return Size(imageSize.width * s, imageSize.height * s);
}

/// 缩放 [scale]（相对居中）后，相对视口可平移的半幅。
/// [dw],[dh] 为未缩放时（cover 或 fitWidth）下的显示宽高；[vw],[vh] 为视口。
({double maxX, double maxY}) panHalfExtentAfterScale({
  required double dw,
  required double dh,
  required double vw,
  required double vh,
  required double scale,
}) {
  final sw = dw * scale;
  final sh = dh * scale;
  return (
    maxX: math.max(0.0, (sw - vw) / 2),
    maxY: math.max(0.0, (sh - vh) / 2),
  );
}

/// 全屏模糊填充层（同图 cover），用于填补 fitWidth 上下留白，避免纯色条。
Widget blurredCoverBackground(File file) {
  return Positioned.fill(
    child: ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
      child: Transform.scale(
        scale: 1.05,
        child: Image.file(
          file,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          alignment: Alignment.center,
        ),
      ),
    ),
  );
}
