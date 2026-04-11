/// 背景图/背景视频的来源，用于「清除/更换背景」时决定是否删除应用内磁盘副本。
///
/// - [camera]：拍照/录像经本应用保存的副本（如 `images/camera`），清除时可删。
/// - [gallery]：相册原图不删；若已复制到应用私有目录（如 `images/gallery`、`backgrounds`），清除时删除该副本。
/// - [mediaLibrary]：引用应用内媒体库路径（`…/media/`），只清记录，不删库内文件。
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
