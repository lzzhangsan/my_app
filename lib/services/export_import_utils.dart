// lib/services/export_import_utils.dart
// Shared utilities for export/import - streaming, chunk sizes, thresholds

import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 获取导出文件的保存目录，优先公共下载目录（用户可在文件管理器中找到）
/// OPPO 等设备 getDownloadsDirectory 可能返回应用私有路径，会尝试 /storage/emulated/0/Download
Future<Directory> getExportSaveDirectory() async {
  Directory? saveDir = await getDownloadsDirectory();
  if (saveDir == null || saveDir.path.contains('Android/data')) {
    if (Platform.isAndroid) {
      for (final p in ['/storage/emulated/0/Download', '/sdcard/Download']) {
        final d = Directory(p);
        try {
          await d.create(recursive: true);
          return d;
        } catch (_) {}
      }
    }
  }
  if (saveDir != null) return saveDir;
  saveDir = await getExternalStorageDirectory();
  if (saveDir != null) return saveDir;
  return getApplicationDocumentsDirectory();
}

/// Streaming threshold: files larger than this use stream pipe instead of copy
const int kStreamingThresholdBytes = 2 * 1024 * 1024; // 2MB

/// Chunk size for splitting large JSON arrays (e.g. 5000 rows per file)
const int kExportChunkSize = 5000;

/// 分享文件大小上限：超过此值不自动调用 Share（share_plus 在主线程复制文件，大文件会导致 ANR/卡死）
/// 500MB：复制约 10 秒，有卡顿风险但可接受；超过则弹窗提供「直达」等
const int kShareSizeLimitBytes = 500 * 1024 * 1024; // 500MB

/// Progress update interval (update every N items)
const int kProgressUpdateInterval = 75;

/// Copy a file, using streaming for files larger than threshold to avoid memory issues.
/// Returns the number of bytes copied.
Future<int> copyFileWithStreaming(
  File source,
  String targetPath, {
  int threshold = kStreamingThresholdBytes,
}) async {
  if (!await source.exists()) return 0;
  final fileSize = await source.length();
  final targetFile = File(targetPath);
  await targetFile.parent.create(recursive: true);

  if (fileSize > threshold) {
    final sourceStream = source.openRead();
    final targetSink = targetFile.openWrite();
    await sourceStream.pipe(targetSink);
    await targetSink.close();
  } else {
    await source.copy(targetPath);
  }
  return fileSize;
}

/// Copy source file to target file using streaming when large.
Future<void> copyFileWithStreamingToFile(
  File source,
  File target, {
  int threshold = kStreamingThresholdBytes,
}) async {
  if (!await source.exists()) return;
  final fileSize = await source.length();
  await target.parent.create(recursive: true);

  if (fileSize > threshold) {
    final sourceStream = source.openRead();
    final targetSink = target.openWrite();
    await sourceStream.pipe(targetSink);
    await targetSink.close();
  } else {
    await source.copy(target.path);
  }
}
