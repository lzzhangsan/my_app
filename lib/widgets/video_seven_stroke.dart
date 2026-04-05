import 'package:flutter/material.dart';

/// 检测「7」形手势：先大致水平再大致向下。
/// 返回 `true` 表示顺时针旋转 90°（向右），`false` 表示逆时针 90°（向左），`null` 表示未识别。
bool? detectSevenStrokeRotation(List<Offset> points) {
  if (points.length < 8) return null;
  final start = points.first;
  final end = points.last;
  double maxD = 0;
  var cornerIdx = 0;
  for (var i = 1; i < points.length - 1; i++) {
    final d = _pointToSegmentDistance(points[i], start, end);
    if (d > maxD) {
      maxD = d;
      cornerIdx = i;
    }
  }
  if (maxD < 26) return null;
  final corner = points[cornerIdx];
  final v1 = corner - start;
  final v2 = end - corner;
  if (v1.distance < 44 || v2.distance < 44) return null;
  // 第一段：以水平为主
  if (v1.dy.abs() > v1.dx.abs() * 0.58) return null;
  // 第二段：向下
  if (v2.dy < 12) return null;
  if (v2.dy.abs() < v2.dx.abs() * 0.45) return null;
  if (v1.dx > 8) return true;
  if (v1.dx < -8) return false;
  return null;
}

double _pointToSegmentDistance(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final ap = p - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 < 1e-9) return (p - a).distance;
  var t = (ap.dx * ab.dx + ap.dy * ab.dy) / len2;
  t = t.clamp(0.0, 1.0);
  final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
  return (p - proj).distance;
}
