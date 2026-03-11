// lib/services/export_import_utils.dart
// Shared utilities for export/import - streaming, chunk sizes, thresholds

import 'dart:io';

/// Streaming threshold: files larger than this use stream pipe instead of copy
const int kStreamingThresholdBytes = 2 * 1024 * 1024; // 2MB

/// Chunk size for splitting large JSON arrays (e.g. 5000 rows per file)
const int kExportChunkSize = 5000;

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
