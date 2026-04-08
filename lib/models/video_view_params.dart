/// 视频与图片在媒体预览/文档栏中的视窗变换（持久化到 `media_items` 的 `video_view_*` 列；图片主要使用 `video_view_rot`）。
/// 平移为相对当前视口宽高的归一化量，换机后仍可按比例还原。
class VideoViewParams {
  const VideoViewParams({
    this.scale = 1.0,
    this.txNorm = 0.0,
    this.tyNorm = 0.0,
    this.quarterTurns = 0,
  });

  /// 缩放倍数，≥1。
  final double scale;

  /// 水平平移 / 视口宽度（约 -1～1）。
  final double txNorm;

  /// 垂直平移 / 视口高度。
  final double tyNorm;

  /// 顺时针四分之一圈数 0～3（与 [RotatedBox] 一致）。
  final int quarterTurns;

  static VideoViewParams fromMediaMap(Map<String, dynamic> map) {
    final s = map['video_view_scale'];
    final tx = map['video_view_tx'];
    final ty = map['video_view_ty'];
    final r = map['video_view_rot'];
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
    return VideoViewParams(
      scale: (s is num) ? s.toDouble().clamp(1.0, 16.0) : 1.0,
      txNorm: (tx is num) ? tx.toDouble() : 0.0,
      tyNorm: (ty is num) ? ty.toDouble() : 0.0,
      quarterTurns: rot,
    );
  }

  Map<String, dynamic> toDbUpdateMap() {
    return {
      'video_view_scale': scale,
      'video_view_tx': txNorm,
      'video_view_ty': tyNorm,
      'video_view_rot': quarterTurns % 4,
    };
  }

  bool get isDefault =>
      (scale - 1.0).abs() < 1e-6 &&
      txNorm.abs() < 1e-6 &&
      tyNorm.abs() < 1e-6 &&
      (quarterTurns % 4) == 0;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VideoViewParams &&
        (scale - other.scale).abs() < 1e-6 &&
        (txNorm - other.txNorm).abs() < 1e-6 &&
        (tyNorm - other.tyNorm).abs() < 1e-6 &&
        (quarterTurns % 4) == (other.quarterTurns % 4);
  }

  @override
  int get hashCode => Object.hash(scale, txNorm, tyNorm, quarterTurns % 4);
}
