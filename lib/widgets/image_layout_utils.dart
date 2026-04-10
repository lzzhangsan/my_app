import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

class ImageDisplayLayoutReadyNotification extends Notification {
  ImageDisplayLayoutReadyNotification();
}

void notifyImageDisplayLayoutReady(BuildContext context) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    ImageDisplayLayoutReadyNotification().dispatch(context);
  });
}

/// 读取图片像素尺寸。
Future<Size> measureImageFileSize(File file) async {
  final completer = Completer<Size>();
  final provider = FileImage(file);
  final stream = provider.resolve(const ImageConfiguration());
  late final ImageStreamListener listener;

  listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      if (!completer.isCompleted) {
        completer.complete(
          Size(info.image.width.toDouble(), info.image.height.toDouble()),
        );
      }
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
      stream.removeListener(listener);
    },
  );

  stream.addListener(listener);
  return completer.future.timeout(
    const Duration(seconds: 8),
    onTimeout: () {
      stream.removeListener(listener);
      throw TimeoutException('measureImageFileSize timeout for ${file.path}');
    },
  );
}

/// 横向填满视口宽度、纵向按原图比例（与 BoxFit.fitWidth 一致）。
Size fitWidthDisplaySize(Size imageSize, double viewportW) {
  final h = viewportW * imageSize.height / imageSize.width;
  return Size(viewportW, h);
}

/// 整图纳入视口、等比缩放（与 BoxFit.contain 一致）；用于 90°/270° 外层再旋转时避免先被纵向裁切。
Size containDisplaySize(Size imageSize, double viewportW, double viewportH) {
  if (imageSize.width <= 0 || imageSize.height <= 0) {
    return Size(viewportW, viewportH);
  }
  final s = math.min(viewportW / imageSize.width, viewportH / imageSize.height);
  return Size(imageSize.width * s, imageSize.height * s);
}

/// BoxFit.cover：整屏均被图片盖住，宽与高均 ≥ 视口对应边（一边贴齐、一边超出可裁切）。
Size coverDisplaySize(Size imageSize, double viewportW, double viewportH) {
  final s = math.max(viewportW / imageSize.width, viewportH / imageSize.height);
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
  final outerToInner = buildRectangularSpiralPathOuterToInner(
    mx,
    my,
    clockwise,
  );
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

/// 竖向未铺满时，屏幕上下（或左右）留白区域的填充方式（媒体栏与预览共用设置）。
enum ImageLetterboxFill {
  /// 浅灰纯色底（非纯白，避免与白色图标对比度不足）；色值见 [kLetterboxSolidNeutral]。
  white,

  /// 透出底层背景（如页面 Scaffold 底色）。
  transparent,

  /// 旧版：同图放大铺满 + 暗化叠层，层次较强。
  softCover,

  /// 同图强模糊；个别机型若出现发灰可改用「纯白」。
  blurHeavy,
}

/// [ImageLetterboxFill.white] 使用的浅灰纯色（与纯白色图标区分更明显）。
const Color kLetterboxSolidNeutral = Color(0xFFE0E0E0);

/// 作为 [Stack] 子组件使用的全屏底图层（已含 [Positioned.fill]）。
///
/// [ImageLetterboxFill.softCover] 不使用 [ImageFilter] 高斯模糊，仅用 cover + 压暗，
/// 以避免部分 Android 正式版上 `ImageFiltered` 与变换叠加时的发灰问题。
/// [ImageLetterboxFill.blurHeavy] 则使用高斯模糊，供需要柔和底图的用户自选。
Widget letterboxFillLayer(File file, ImageLetterboxFill fill) {
  switch (fill) {
    case ImageLetterboxFill.white:
      return const Positioned.fill(
        child: ColoredBox(color: kLetterboxSolidNeutral),
      );
    case ImageLetterboxFill.transparent:
      return const Positioned.fill(child: ColoredBox(color: Color(0x00000000)));
    case ImageLetterboxFill.softCover:
      return Positioned.fill(
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform.scale(
                scale: 1.06,
                child: Image.file(
                  file,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  alignment: Alignment.center,
                  filterQuality: FilterQuality.low,
                ),
              ),
              const ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.22)),
            ],
          ),
        ),
      );
    case ImageLetterboxFill.blurHeavy:
      return Positioned.fill(
        child: ClipRect(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
            child: Transform.scale(
              scale: 1.08,
              alignment: Alignment.center,
              child: Image.file(
                file,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                alignment: Alignment.center,
                filterQuality: FilterQuality.low,
              ),
            ),
          ),
        ),
      );
  }
}

/// 已保存的渐进放大中心点：小黄点半透明（全屏预览/渐进放大用，较小不抢眼）。
BoxDecoration zoomCenterMarkerDotDecoration() {
  return BoxDecoration(
    shape: BoxShape.circle,
    color: const Color(0xFFFFD54F).withOpacity(0.52),
    boxShadow: [
      BoxShadow(color: Colors.black.withOpacity(0.22), blurRadius: 2),
    ],
  );
}

/// 网格缩略图用：约为 [zoomCenterMarkerDotDecoration] 圆点直径的两倍，略提高不透明度并加白边，便于一眼区分。
BoxDecoration zoomCenterMarkerThumbnailDotDecoration() {
  return BoxDecoration(
    shape: BoxShape.circle,
    color: const Color(0xFFFFC107).withOpacity(0.82),
    border: Border.all(color: Colors.white.withOpacity(0.95), width: 1.0),
    boxShadow: [
      BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 3),
    ],
  );
}

/// 已保存的渐进放大中心点在图片显示矩形内的标记（与 [SizedBox] 内 `Image` 同坐标系，叠在图上）。
///
/// 仅当数据库中 [ken_burns_center_x/y] 均非 null 时由调用方决定是否构建；默认未设中心则不显示。
/// [visible]：渐进放大模式下在 scale>1 时应为 false，以免遮挡画面。
class ZoomCenterMarker extends StatelessWidget {
  const ZoomCenterMarker({
    super.key,
    required this.nx,
    required this.ny,
    required this.width,
    required this.height,
    this.visible = true,
    this.radius = 2.5,
  });

  /// 归一化横坐标 0～1。
  final double nx;

  /// 归一化纵坐标 0～1。
  final double ny;
  final double width;
  final double height;

  /// 为 false 时不绘制（仍占位无：返回 [SizedBox.shrink]）。
  final bool visible;

  /// 圆点半径（逻辑像素），默认约为初版一半大小。
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Positioned(
      left: width * nx - radius,
      top: height * ny - radius,
      child: IgnorePointer(
        child: Container(
          width: radius * 2,
          height: radius * 2,
          decoration: zoomCenterMarkerDotDecoration(),
        ),
      ),
    );
  }
}

/// 缩略图 [BoxFit.cover] 且居中裁切时，将归一化中心点映射到格子内的位置后叠放小黄点。
class ZoomCenterMarkerCoverOverlay extends StatelessWidget {
  const ZoomCenterMarkerCoverOverlay({
    super.key,
    required this.file,
    required this.nx,
    required this.ny,

    /// 略缩图格子内约为全屏标记的两倍半径，更易辨认。
    this.radius = 2.5,
  });

  final File file;
  final double nx;
  final double ny;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tw = constraints.maxWidth;
        final th = constraints.maxHeight;
        if (tw <= 0 || th <= 0) return const SizedBox.shrink();
        return FutureBuilder<Size>(
          future: measureImageFileSize(file),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox.shrink();
            final iw = snapshot.data!.width;
            final ih = snapshot.data!.height;
            if (iw <= 0 || ih <= 0) return const SizedBox.shrink();
            final scale = math.max(tw / iw, th / ih);
            final sw = iw * scale;
            final sh = ih * scale;
            final ox = (tw - sw) / 2;
            final oy = (th - sh) / 2;
            final cx = nx.clamp(0.0, 1.0);
            final cy = ny.clamp(0.0, 1.0);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: ox + cx * sw - radius,
                  top: oy + cy * sh - radius,
                  child: IgnorePointer(
                    child: Container(
                      width: radius * 2,
                      height: radius * 2,
                      decoration: zoomCenterMarkerThumbnailDotDecoration(),
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
