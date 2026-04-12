import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 上次访问高亮：与列表「整行」圆角描边重合；黄 → 天蓝渐变 + 外发光；中间不铺色。
///
/// [child] 须为 [ListTile] + `Divider(height: [_dividerHeight])` 的 [Column]。
/// 竖直方向按 Material [Divider] 的规则：分隔线在 `Divider` 高度内居中，故描边整体
/// 上移半格分隔高度，使上下边与两条灰线对齐。
class DirectoryLastVisitedFrame extends StatelessWidget {
  const DirectoryLastVisitedFrame({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  static const double _stroke = 8.0 / 3.0;
  static const double _radius = 10.0;
  /// 须与目录页列表项 `Divider(height: …)` 一致。
  static const double _dividerHeight = 5.0;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    return CustomPaint(
      foregroundPainter: _DirectoryRowBorderPainter(
        stroke: _stroke,
        borderRadius: _radius,
        dividerHalfHeight: _dividerHeight / 2.0,
      ),
      child: child,
    );
  }
}

/// 圆角矩形描边（渐变）+ 外发光，画在子组件之上，仅盖住边缘若干像素。
class _DirectoryRowBorderPainter extends CustomPainter {
  _DirectoryRowBorderPainter({
    required this.stroke,
    required this.borderRadius,
    required this.dividerHalfHeight,
  });

  final double stroke;
  final double borderRadius;
  /// [Divider] 高度的一半：灰线在区块竖直中心，与子组件顶边相差此值。
  final double dividerHalfHeight;

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

    final halfStroke = stroke / 2;
    canvas.save();
    // 上移半格 Divider：顶边对齐上一行分隔线中心，底边对齐本行分隔线中心
    canvas.translate(0, -dividerHalfHeight);

    final rect = Rect.fromLTWH(
      halfStroke,
      0,
      size.width - stroke,
      size.height,
    );
    if (rect.width <= 0 || rect.height <= 0) {
      canvas.restore();
      return;
    }

    final r = math.min(
      borderRadius,
      math.min(rect.width, rect.height) / 2 - 0.001,
    ).clamp(0.0, borderRadius);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(r));

    final shaderRect = Rect.fromLTWH(0, -dividerHalfHeight, size.width, size.height);

    // 外发光（沿描边向外）
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke + 5
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFFFFF176).withValues(alpha: 0.22),
          const Color(0xFF80DEEA).withValues(alpha: 0.28),
        ],
      ).createShader(shaderRect)
      ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 5);
    canvas.drawRRect(rr, glowPaint);

    // 清晰渐变描边
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..isAntiAlias = true
      ..shader = _borderGradient.createShader(shaderRect);
    canvas.drawRRect(rr, linePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DirectoryRowBorderPainter oldDelegate) {
    return oldDelegate.stroke != stroke ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.dividerHalfHeight != dividerHalfHeight;
  }
}
