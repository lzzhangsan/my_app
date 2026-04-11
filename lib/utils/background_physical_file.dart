import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/background_media_origin.dart';

/// 路径是否落在应用文档目录下的媒体库文件夹（引用媒体库，清除背景时不可删此文件）。
bool isAppMediaLibraryFilePath(String filePath, String appDocumentsDirectory) {
  final a = p.normalize(filePath).replaceAll('\\', '/').toLowerCase();
  final b = p.normalize(appDocumentsDirectory).replaceAll('\\', '/').toLowerCase();
  if (!a.startsWith('$b/')) return false;
  return a.contains('/media/');
}

/// 是否为「应用私有目录内的背景副本」（相册/拍摄经复制、或封面/目录/日记等专用目录），
/// 清除/更换背景时可删除以节省空间；不含 [isAppMediaLibraryFilePath] 所指的媒体库本体。
bool isAppPrivateBackgroundOwnedCopy(
  String filePath,
  String appDocumentsDirectory,
) {
  final a = p.normalize(filePath).replaceAll('\\', '/').toLowerCase();
  final b = p.normalize(appDocumentsDirectory).replaceAll('\\', '/').toLowerCase();
  if (!a.startsWith('$b/')) return false;
  if (a.contains('/media/')) return false;

  const markers = <String>[
    '/backgrounds/',
    '/background_videos/',
    '/background_images/',
    '/diary_backgrounds/',
    '/images/camera/',
    '/images/gallery/',
    '/videos/camera/',
    '/videos/gallery/',
  ];
  for (final m in markers) {
    if (a.contains(m)) return true;
  }
  return false;
}

/// 是否允许在「用户清除/更换背景」时删除磁盘上的该文件。
///
/// - **媒体库引用**（路径在 `…/media/` 或来源为 [BackgroundMediaOrigin.mediaLibrary]）：只清记录，不删文件。
/// - **相册**：系统相册原图不动；经本应用复制到私有目录的副本（含 `images/gallery`、`backgrounds` 等）应删除。
/// - **拍摄**：删除应用内保存的副本（`camera` 子目录等）。
/// - **旧数据**（[origin] 为 null）：仅当路径落在 [isAppPrivateBackgroundOwnedCopy] 时删除副本。
bool shouldDeleteBackgroundPhysicalFile(
  String? filePath,
  BackgroundMediaOrigin? origin,
  String appDocumentsDirectory,
) {
  if (filePath == null || filePath.isEmpty) return false;

  if (isAppMediaLibraryFilePath(filePath, appDocumentsDirectory)) {
    return false;
  }
  if (origin == BackgroundMediaOrigin.mediaLibrary) {
    return false;
  }

  if (origin == BackgroundMediaOrigin.camera) {
    return isAppPrivateBackgroundOwnedCopy(filePath, appDocumentsDirectory);
  }

  if (origin == BackgroundMediaOrigin.gallery) {
    return isAppPrivateBackgroundOwnedCopy(filePath, appDocumentsDirectory);
  }

  if (origin == null) {
    return isAppPrivateBackgroundOwnedCopy(filePath, appDocumentsDirectory);
  }

  return false;
}

/// 在允许时删除背景关联的物理文件（忽略错误）。
Future<void> deleteBackgroundPhysicalFileIfAllowed(
  String? filePath,
  BackgroundMediaOrigin? origin,
  String appDocumentsDirectory,
) async {
  final path = filePath;
  if (path == null || path.isEmpty) return;
  if (!shouldDeleteBackgroundPhysicalFile(path, origin, appDocumentsDirectory)) {
    return;
  }
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
