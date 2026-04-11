/// 背景图/背景视频的来源，用于「清除背景」时决定是否删除应用内磁盘副本。
///
/// - [camera]：拍照/录像经本应用保存的副本，清除背景时可删除。
/// - [gallery]：来自相册，清除背景只清数据库记录，不删文件（亦不碰相册原图）。
/// - [mediaLibrary]：引用应用内媒体库路径，绝不删除该文件。
enum BackgroundMediaOrigin {
  camera(0),
  gallery(1),
  mediaLibrary(2);

  const BackgroundMediaOrigin(this.dbValue);
  final int dbValue;

  static BackgroundMediaOrigin? fromDbValue(int? v) {
    if (v == null) return null;
    for (final o in BackgroundMediaOrigin.values) {
      if (o.dbValue == v) return o;
    }
    return null;
  }
}
