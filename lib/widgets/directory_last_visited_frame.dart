import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 上次访问高亮：黄 → 天蓝渐变描边 + 仅向外柔光；中间不铺色，由 [child] 填满，不遮挡标题。
///
/// 框宽取 [屏幕宽度 × 0.9 + 约 4mm] 与当前行宽的较小者并水平居中；高度在满行基础上减去约 4mm 并垂直居中。
class DirectoryLastVisitedFrame extends StatelessWidget {
  const DirectoryLastVisitedFrame({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  static const double _stroke = 8.0 / 3.0;
  static const double _radius = 12.0;
  /// 相对屏幕逻辑宽度；实际绘制宽度不超过当前列表行宽。
  static const double _frameWidthOfScreen = 0.9;
  /// 垂直占满行高，避免与图标、拖柄上下「交错」。
  static const double _frameHeightFactor = 1.0;
  /// 将毫米近似为逻辑像素（按当前屏宽与常见可内容区宽度推算，约 4mm 级调整）。
  static double _mmToLogicalPixels(BuildContext context, double mm) {
    if (mm <= 0) return 0;
    final w = MediaQuery.sizeOf(context).width;
    const assumedContentWidthMm = 68.0;
    return mm * w / assumedContentWidthMm;
  }

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    final screenW = MediaQuery.sizeOf(context).width;
    final delta4mm = _mmToLogicalPixels(context, 4.0);
    final desiredFrameW = screenW * _frameWidthOfScreen + delta4mm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 5),
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GlowRingPainter(
                  stroke: _stroke,
                  borderRadius: _radius,
                  desiredFrameWidth: desiredFrameW,
                  heightFactor: _frameHeightFactor,
                  heightSubtractLogical: delta4mm,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GradientRingPainter(
                  stroke: _stroke,
                  borderRadius: _radius,
                  desiredFrameWidth: desiredFrameW,
                  heightFactor: _frameHeightFactor,
                  heightSubtractLogical: delta4mm,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(_stroke),
            child: child,
          ),
        ],
      ),
    );
  }
}

Rect _frameOuterRect(
  Size canvasSize,
  double desiredFrameWidth,
  double heightFactor,
  double heightSubtractLogical,
) {
  if (canvasSize.width <= 0 || canvasSize.height <= 0) {
    return Rect.zero;
  }
  final fw = math.min(desiredFrameWidth, canvasSize.width);
  final rawH =
      canvasSize.height * heightFactor.clamp(0.0, 1.0) - heightSubtractLogical;
  const minOuterH = 8.0;
  final fh = rawH.clamp(minOuterH, canvasSize.height);
  final left = (canvasSize.width - fw) / 2;
  final top = (canvasSize.height - fh) / 2;
  return Rect.fromLTWH(left, top, fw, fh);
}

Path _buildRingPath(
  Size canvasSize,
  double stroke,
  double borderRadius,
  double desiredFrameWidth,
  double heightFactor,
  double heightSubtractLogical,
) {
  final outerRect = _frameOuterRect(
    canvasSize,
    desiredFrameWidth,
    heightFactor,
    heightSubtractLogical,
  );
  if (outerRect.width <= 0 || outerRect.height <= 0) {
    return Path();
  }
  final cornerR = borderRadius.clamp(0.0, outerRect.shortestSide / 2);
  final outer = RRect.fromRectAndRadius(outerRect, Radius.circular(cornerR));
  final innerR = (cornerR - stroke).clamp(0.0, cornerR);
  final innerW = (outerRect.width - 2 * stroke).clamp(0.0, double.infinity);
  final innerH = (outerRect.height - 2 * stroke).clamp(0.0, double.infinity);
  final inner = RRect.fromRectAndRadius(
    Rect.fromLTWH(
      outerRect.left + stroke,
      outerRect.top + stroke,
      innerW,
      innerH,
    ),
    Radius.circular(innerR),
  );
  return Path()
    ..addRRect(outer)
    ..addRRect(inner)
    ..fillType = PathFillType.evenOdd;
}

/// 沿环形的柔光，[BlurStyle.outer] 尽量不把光渗进内容区。
class _GlowRingPainter extends CustomPainter {
  _GlowRingPainter({
    required this.stroke,
    required this.borderRadius,
    required this.desiredFrameWidth,
    required this.heightFactor,
    required this.heightSubtractLogical,
  });

  final double stroke;
  final double borderRadius;
  final double desiredFrameWidth;
  final double heightFactor;
  final double heightSubtractLogical;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = _frameOuterRect(
      size,
      desiredFrameWidth,
      heightFactor,
      heightSubtractLogical,
    );
    final path = _buildRingPath(
      size,
      stroke,
      borderRadius,
      desiredFrameWidth,
      heightFactor,
      heightSubtractLogical,
    );
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFFFFF176).withValues(alpha: 0.32),
          const Color(0xFF80DEEA).withValues(alpha: 0.38),
        ],
      ).createShader(rect.inflate(stroke))
      ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 6);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _GlowRingPainter oldDelegate) {
    return oldDelegate.stroke != stroke ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.desiredFrameWidth != desiredFrameWidth ||
        oldDelegate.heightFactor != heightFactor ||
        oldDelegate.heightSubtractLogical != heightSubtractLogical;
  }
}

/// 黄 → 天蓝 渐变线框（环形填充）。
class _GradientRingPainter extends CustomPainter {
  _GradientRingPainter({
    required this.stroke,
    required this.borderRadius,
    required this.desiredFrameWidth,
    required this.heightFactor,
    required this.heightSubtractLogical,
  });

  final double stroke;
  final double borderRadius;
  final double desiredFrameWidth;
  final double heightFactor;
  final double heightSubtractLogical;

  static final _borderGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: const [
      Color(0xFFFFEA00),
      Color(0xFFFFF59D),
      Color(0xFF4DD0E1),
      Color(0xFF00BCD4),
    ],
    stops: const [0.0, 0.28, 0.72, 1.0],
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = _frameOuterRect(
      size,
      desiredFrameWidth,
      heightFactor,
      heightSubtractLogical,
    );
    final path = _buildRingPath(
      size,
      stroke,
      borderRadius,
      desiredFrameWidth,
      heightFactor,
      heightSubtractLogical,
    );
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true
      ..shader = _borderGradient.createShader(rect.inflate(stroke));
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _GradientRingPainter oldDelegate) {
    return oldDelegate.stroke != stroke ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.desiredFrameWidth != desiredFrameWidth ||
        oldDelegate.heightFactor != heightFactor ||
        oldDelegate.heightSubtractLogical != heightSubtractLogical;
  }
}
