import 'dart:ui' show Offset;

/// 视频与图片在媒体预览/文档栏中的视窗变换（持久化到 `media_items` 的 `video_view_*` 列；图片主要使用 `video_view_rot`）。
/// 平移为相对当前视口宽高的归一化量；[basisW]/[basisH] 记录编码该归一化时使用的视口逻辑尺寸，用于冷启动后视口变化时重映射。
class VideoViewParams {
  const VideoViewParams({
    this.scale = 1.0,
    this.txNorm = 0.0,
    this.tyNorm = 0.0,
    this.quarterTurns = 0,
    this.basisW,
    this.basisH,
    this.anchorXNorm,
    this.anchorYNorm,
  });

  /// 缩放倍数，≥1。
  final double scale;

  /// 水平平移归一化（约 -1～1）。
  final double txNorm;

  /// 垂直平移归一化。
  final double tyNorm;

  /// 顺时针四分之一圈数 0～3（与 [RotatedBox] 一致）。
  final int quarterTurns;

  /// 保存 [txNorm]/[tyNorm] 时 InteractiveViewer 所用的逻辑视口宽；null 表示旧数据，按当前视口直接解码。
  final double? basisW;

  /// 保存时所用逻辑视口高。
  final double? basisH;

  /// 变换后内容左上角相对当前逻辑视口宽度的归一化位置。
  final double? anchorXNorm;

  /// 变换后内容左上角相对当前逻辑视口高度的归一化位置。
  final double? anchorYNorm;

  static VideoViewParams fromMediaMap(Map<String, dynamic> map) {
    final s = map['video_view_scale'];
    final tx = map['video_view_tx'];
    final ty = map['video_view_ty'];
    final r = map['video_view_rot'];
    final bw = map['video_view_basis_w'];
    final bh = map['video_view_basis_h'];
    final ax = map['video_view_anchor_x'];
    final ay = map['video_view_anchor_y'];
    if (s == null && tx == null && ty == null && r == null) {
      return const VideoViewParams();
    }
    int rot = 0;
    if (r is int) {
      rot = r % 4;
      if (rot < 0) rot += 4;
    } else if (r is num) {
      rot = r.toInt() % 4;
      if (rot < 0) rot += 4;
    }
    double? obw;
    double? obh;
    if (bw is num && bh is num) {
      obw = bw.toDouble();
      obh = bh.toDouble();
      if (obw < 1 || obh < 1) {
        obw = null;
        obh = null;
      }
    }
    return VideoViewParams(
      scale: (s is num) ? s.toDouble().clamp(1.0, 16.0) : 1.0,
      txNorm: (tx is num) ? tx.toDouble() : 0.0,
      tyNorm: (ty is num) ? ty.toDouble() : 0.0,
      quarterTurns: rot,
      basisW: obw,
      basisH: obh,
      anchorXNorm: ax is num ? ax.toDouble() : null,
      anchorYNorm: ay is num ? ay.toDouble() : null,
    );
  }

  Map<String, dynamic> toDbUpdateMap() {
    return {
      'video_view_scale': scale,
      'video_view_tx': txNorm,
      'video_view_ty': tyNorm,
      'video_view_rot': quarterTurns % 4,
      if (basisW != null && basisH != null && basisW! >= 1 && basisH! >= 1)
        'video_view_basis_w': basisW,
      if (basisW != null && basisH != null && basisW! >= 1 && basisH! >= 1)
        'video_view_basis_h': basisH,
      if (anchorXNorm != null) 'video_view_anchor_x': anchorXNorm,
      if (anchorYNorm != null) 'video_view_anchor_y': anchorYNorm,
    };
  }

  /// 供磁盘 JSON 暂存（键名短，减小体积）。
  Map<String, dynamic> toJsonStaging() {
    return {
      's': scale,
      'tx': txNorm,
      'ty': tyNorm,
      'r': quarterTurns % 4,
      if (basisW != null) 'bw': basisW,
      if (basisH != null) 'bh': basisH,
      if (anchorXNorm != null) 'ax': anchorXNorm,
      if (anchorYNorm != null) 'ay': anchorYNorm,
    };
  }

  static VideoViewParams fromJsonStaging(Map<String, dynamic> m) {
    int rot = 0;
    final r = m['r'];
    if (r is int) {
      rot = r % 4;
      if (rot < 0) rot += 4;
    } else if (r is num) {
      rot = r.toInt() % 4;
      if (rot < 0) rot += 4;
    }
    double? bw;
    double? bh;
    final rawBw = m['bw'];
    final rawBh = m['bh'];
    final rawAx = m['ax'];
    final rawAy = m['ay'];
    if (rawBw is num && rawBh is num) {
      bw = rawBw.toDouble();
      bh = rawBh.toDouble();
      if (bw < 1 || bh < 1) {
        bw = null;
        bh = null;
      }
    }
    return VideoViewParams(
      scale:
          (m['s'] is num) ? (m['s'] as num).toDouble().clamp(1.0, 16.0) : 1.0,
      txNorm: (m['tx'] is num) ? (m['tx'] as num).toDouble() : 0.0,
      tyNorm: (m['ty'] is num) ? (m['ty'] as num).toDouble() : 0.0,
      quarterTurns: rot,
      basisW: bw,
      basisH: bh,
      anchorXNorm: rawAx is num ? rawAx.toDouble() : null,
      anchorYNorm: rawAy is num ? rawAy.toDouble() : null,
    );
  }

  /// 将按 [basisW]/[basisH] 编码的归一化量，换算到当前视口 [newW]×[newH] 下应使用的归一化量（与 [ImageInteractiveSurface] 几何一致）。
  VideoViewParams remappedToViewport(double newW, double newH) {
    final ow = basisW;
    final oh = basisH;
    // 旧库无 basis 时无法做视口重映射，保持与此前行为一致。
    if (ow == null || oh == null) {
      return this;
    }
    if (anchorXNorm != null && anchorYNorm != null) {
      return VideoViewParams(
        scale: scale,
        txNorm: txNorm,
        tyNorm: tyNorm,
        quarterTurns: quarterTurns,
        basisW: newW,
        basisH: newH,
        anchorXNorm: anchorXNorm,
        anchorYNorm: anchorYNorm,
      );
    }
    // 轻微视口抖动（状态栏、安全区、整像素取整）不应触发线性重映射，否则易放大舍入误差。
    if ((ow - newW).abs() < 2.0 && (oh - newH).abs() < 2.0) {
      return VideoViewParams(
        scale: scale,
        txNorm: txNorm,
        tyNorm: tyNorm,
        quarterTurns: quarterTurns,
        basisW: newW,
        basisH: newH,
        anchorXNorm: anchorXNorm,
        anchorYNorm: anchorYNorm,
      );
    }
    // basis 为 IV 子控件外框（含 90°/270° 时的 vh×vw）；归一化编解码在表面层用 quarterTurns:0，此处须一致。
    final oldC = _centeredBaseTranslation(ow, oh, scale, 0);
    final oldE = _panHalfExtents(ow, oh, scale, 0);
    final tcx = _translationFromNorm(txNorm, oldC.dx, oldE.maxX);
    final tcy = _translationFromNorm(tyNorm, oldC.dy, oldE.maxY);
    final scaleX = newW / ow;
    final scaleY = newH / oh;
    final ntcx = tcx * scaleX;
    final ntcy = tcy * scaleY;
    final newC = _centeredBaseTranslation(newW, newH, scale, 0);
    final newE = _panHalfExtents(newW, newH, scale, 0);
    final ntx = newE.maxX > 1e-6 ? -(ntcx - newC.dx) / newE.maxX : 0.0;
    final nty = newE.maxY > 1e-6 ? -(ntcy - newC.dy) / newE.maxY : 0.0;
    return VideoViewParams(
      scale: scale,
      txNorm: ntx.clamp(-1.0, 1.0),
      tyNorm: nty.clamp(-1.0, 1.0),
      quarterTurns: quarterTurns,
      basisW: newW,
      basisH: newH,
      anchorXNorm: anchorXNorm,
      anchorYNorm: anchorYNorm,
    );
  }

  bool get isDefault =>
      (scale - 1.0).abs() < 1e-6 &&
      txNorm.abs() < 1e-6 &&
      tyNorm.abs() < 1e-6 &&
      (quarterTurns % 4) == 0;

  /// 与「未缩放、未平移、未旋转」视觉等价（放宽容差），冷启动时走严格恒等矩阵，避免浮点/remap 产生可见偏移。
  bool get isLikelyIdentityTransform =>
      (scale - 1.0).abs() < 1e-3 &&
      txNorm.abs() < 1e-3 &&
      tyNorm.abs() < 1e-3 &&
      (quarterTurns % 4) == 0;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VideoViewParams &&
        (scale - other.scale).abs() < 1e-6 &&
        (txNorm - other.txNorm).abs() < 1e-6 &&
        (tyNorm - other.tyNorm).abs() < 1e-6 &&
        (quarterTurns % 4) == (other.quarterTurns % 4) &&
        _sameOpt(basisW, other.basisW) &&
        _sameOpt(basisH, other.basisH) &&
        _sameOpt(anchorXNorm, other.anchorXNorm) &&
        _sameOpt(anchorYNorm, other.anchorYNorm);
  }

  static bool _sameOpt(double? a, double? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return (a - b).abs() < 1e-3;
  }

  @override
  int get hashCode => Object.hash(
    scale,
    txNorm,
    tyNorm,
    quarterTurns % 4,
    basisW != null ? (basisW! * 1000).round() : 0,
    basisH != null ? (basisH! * 1000).round() : 0,
    anchorXNorm != null ? (anchorXNorm! * 1000).round() : 0,
    anchorYNorm != null ? (anchorYNorm! * 1000).round() : 0,
  );
}

Offset _centeredBaseTranslation(
  double basisW,
  double basisH,
  double scale,
  int quarterTurns,
) {
  final sideways = quarterTurns % 2 == 1;
  final childW = sideways ? basisH : basisW;
  final childH = sideways ? basisW : basisH;
  return Offset((basisW - childW * scale) / 2, (basisH - childH * scale) / 2);
}

({double maxX, double maxY}) _panHalfExtents(
  double basisW,
  double basisH,
  double scale,
  int quarterTurns,
) {
  final sideways = quarterTurns % 2 == 1;
  final childW = sideways ? basisH : basisW;
  final childH = sideways ? basisW : basisH;
  final scaledW = childW * scale;
  final scaledH = childH * scale;
  return (
    maxX: ((scaledW - basisW) / 2).clamp(0.0, double.infinity),
    maxY: ((scaledH - basisH) / 2).clamp(0.0, double.infinity),
  );
}

double _translationFromNorm(double norm, double centeredBase, double extent) {
  if (extent <= 1e-6) return centeredBase;
  return centeredBase - norm.clamp(-1.0, 1.0) * extent;
}
