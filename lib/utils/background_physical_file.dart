import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/background_media_origin.dart';

/// 路径是否落在应用文档目录下的媒体库文件夹（引用媒体库，不可删）。
bool isAppMediaLibraryFilePath(String filePath, String appDocumentsDirectory) {
  final a = p.normalize(filePath).replaceAll('\\', '/').toLowerCase();
  final b = p.normalize(appDocumentsDirectory).replaceAll('\\', '/').toLowerCase();
  if (!a.startsWith('$b/')) return false;
  return a.contains('/media/');
}

/// 是否允许在「用户清除/删除背景」时删除磁盘上的该文件。
///
/// 规则：媒体库路径、相册来源、未知来源（旧数据）均不删；仅拍照来源或
/// 新路径约定（`images/camera/`、`videos/camera/`）下的副本可删。
bool shouldDeleteBackgroundPhysicalFile(
  String? filePath,
  BackgroundMediaOrigin? origin,
  String appDocumentsDirectory,
) {
  if (filePath == null || filePath.isEmpty) return false;
  if (isAppMediaLibraryFilePath(filePath, appDocumentsDirectory)) return false;
  if (origin == BackgroundMediaOrigin.mediaLibrary ||
      origin == BackgroundMediaOrigin.gallery) {
    return false;
  }
  if (origin == BackgroundMediaOrigin.camera) return true;
  final n = p.normalize(filePath).replaceAll('\\', '/').toLowerCase();
  if (n.contains('/images/camera/') || n.contains('/videos/camera/')) {
    return true;
  }
  return false;
}

/// 在允许时删除背景关联的物理文件（忽略错误）。
Future<void> deleteBackgroundPhysicalFileIfAllowed(
  String? filePath,
  BackgroundMediaOrigin? origin,
  String appDocumentsDirectory,
) async {
  final p = filePath;
  if (p == null || p.isEmpty) return;
  if (!shouldDeleteBackgroundPhysicalFile(p, origin, appDocumentsDirectory)) {
    return;
  }
  try {
    final f = File(p);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
