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

/// 由 **外向内** 的矩形螺旋折线（沿可平移矩形嵌套边界一圈圈缩向中心）。
/// [clockwise] 为每一层矩形上的走向（俯视）。
List<Offset> buildRectangularSpiralPathOuterToInner(
  double mx,
  double my,
  bool clockwise,
) {
  if (mx <= 1e-9 && my <= 1e-9) {
    return [Offset.zero];
  }
  if (mx <= 1e-9) {
    return _linePathOuterToInnerVertical(my, clockwise);
  }
  if (my <= 1e-9) {
    return _linePathOuterToInnerHorizontal(mx, clockwise);
  }

  final path = <Offset>[];
  double left = -mx;
  double right = mx;
  double top = -my;
  double bottom = my;
  // inset = min(2mx,2my)/d：d 越小 → inset 越大 → 嵌套层数越少 → 路径越短 → 同总时长下游得越慢。
  // 默认略放大层距，几何路径更短，配合设置里的 panPathCoverage 再控舒缓度。
  const double insetDivisor = 2.5;
  final double inset = math.min(2 * mx, 2 * my) / insetDivisor;
  const int samplesPerEdge = 16;

  void addSegment(Offset a, Offset b) {
    for (int s = 0; s <= samplesPerEdge; s++) {
      final t = s / samplesPerEdge;
      final p = Offset.lerp(a, b, t)!;
      if (path.isEmpty || (path.last - p).distance > 1e-4) {
        path.add(p);
      }
    }
  }

  while (right - left > inset * 0.75 && bottom - top > inset * 0.75) {
    final tl = Offset(left, top);
    final tr = Offset(right, top);
    final br = Offset(right, bottom);
    final bl = Offset(left, bottom);

    if (clockwise) {
      addSegment(tl, tr);
      addSegment(tr, br);
      addSegment(br, bl);
      addSegment(bl, tl);
    } else {
      addSegment(tl, bl);
      addSegment(bl, br);
      addSegment(br, tr);
      addSegment(tr, tl);
    }

    left += inset;
    right -= inset;
    top += inset;
    bottom -= inset;
  }

  if (path.isEmpty || path.last.distance > 1e-3) {
    path.add(Offset.zero);
  }
  return path;
}

/// 与 [buildRectangularSpiralPathOuterToInner] 几何相同，但顺序为 **由内向外**（起点在中心附近），
/// 适合「先居中放大再向外扫」；能沿矩形边界扫到角部，比椭圆螺旋更易覆盖整幅可平移区域。
List<Offset> buildRectangularSpiralPathInnerToOuter(
  double mx,
  double my,
  bool clockwise,
) {
  final outerToInner = buildRectangularSpiralPathOuterToInner(mx, my, clockwise);
  return outerToInner.reversed.toList();
}

/// 先由内向外再沿同一路径由外回中心，首尾相接（去重连接点）。
/// 总弧长约为单程约 2 倍，巡游时间不变时平均线速度约减半，转向更顺。
List<Offset> buildRectangularSpiralRoundTripPath(
  double mx,
  double my,
  bool clockwise,
) {
  final outward = buildRectangularSpiralPathInnerToOuter(mx, my, clockwise);
  final inward = buildRectangularSpiralPathOuterToInner(mx, my, clockwise);
  if (outward.isEmpty) {
    return inward;
  }
  if (inward.isEmpty) {
    return outward;
  }
  final merged = <Offset>[...outward];
  final firstIn = inward.first;
  if ((merged.last - firstIn).distance < 1e-2) {
    merged.addAll(inward.skip(1));
  } else {
    merged.addAll(inward);
  }
  return merged;
}

List<Offset> _linePathOuterToInnerVertical(double my, bool clockwise) {
  final path = <Offset>[];
  for (int i = 0; i <= 32; i++) {
    final u = i / 32;
    final y = -my + 2 * my * u;
    path.add(Offset(0, clockwise ? y : -y));
  }
  if (path.last.distance > 1e-3) {
    path.add(Offset.zero);
  }
  return path;
}

List<Offset> _linePathOuterToInnerHorizontal(double mx, bool clockwise) {
  final path = <Offset>[];
  for (int i = 0; i <= 32; i++) {
    final u = i / 32;
    final x = -mx + 2 * mx * u;
    path.add(Offset(clockwise ? x : -x, 0));
  }
  if (path.last.distance > 1e-3) {
    path.add(Offset.zero);
  }
  return path;
}

/// 沿折线路径按弧长比例 [u]∈[0,1] 插值；[pathPhaseShift]∈[0,1) 将起点沿路径平移。
Offset sampleOffsetAlongPath(
  List<Offset> path,
  double u, {
  double pathPhaseShift = 0,
}) {
  if (path.isEmpty) {
    return Offset.zero;
  }
  if (path.length == 1) {
    return path.first;
  }
  u = ((u + pathPhaseShift) % 1.0 + 1.0) % 1.0;

  final segLens = <double>[];
  double total = 0;
  for (int i = 0; i < path.length - 1; i++) {
    final d = (path[i + 1] - path[i]).distance;
    segLens.add(d);
    total += d;
  }
  if (total < 1e-9) {
    return path.first;
  }

  double dist = u * total;
  for (int i = 0; i < path.length - 1; i++) {
    final len = segLens[i];
    if (dist <= len + 1e-6) {
      final f = len < 1e-9 ? 0.0 : (dist / len).clamp(0.0, 1.0);
      return Offset.lerp(path[i], path[i + 1], f)!;
    }
    dist -= len;
  }
  return path.last;
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
