import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// 与 [MediaManagerPage] 使用相同的 support 下 `video_thumbnails` 目录及
/// `${hashCode}_${length}_thumbnail.jpg` 命名，便于命中已有缓存。
class VideoGridThumbnailHelper {
  VideoGridThumbnailHelper._();

  static final Map<String, Future<File?>> _futures = {};
  static int _active = 0;
  static const int _maxConcurrent = 3;
  static final List<Completer<void>> _waitQueue = [];

  static String cacheKeyForPath(String videoPath) =>
      '${videoPath.hashCode.abs()}_${videoPath.length}';

  static Future<Directory> _thumbnailCacheDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final thumbnailDir = Directory(
      path.join(supportDir.path, 'video_thumbnails'),
    );
    if (!await thumbnailDir.exists()) {
      await thumbnailDir.create(recursive: true);
    }
    return thumbnailDir;
  }

  static Future<void> _acquireSlot() async {
    while (_active >= _maxConcurrent) {
      final c = Completer<void>();
      _waitQueue.add(c);
      await c.future;
    }
    _active++;
  }

  static void _releaseSlot() {
    _active--;
    if (_waitQueue.isNotEmpty) {
      _waitQueue.removeAt(0).complete();
    }
  }

  /// 返回磁盘上的 JPEG 缩略图文件，失败返回 null。
  static Future<File?> getOrCreateThumbnail(String videoPath) async {
    if (kIsWeb) return null;

    var fut = _futures[videoPath];
    if (fut == null) {
      fut = _generateImpl(videoPath);
      _futures[videoPath] = fut;
    }
    final result = await fut;
    if (result == null) {
      _futures.remove(videoPath);
    }
    return result;
  }

  static Future<File?> _generateImpl(String videoPath) async {
    final videoFile = File(videoPath);
    if (!await videoFile.exists()) return null;

    await _acquireSlot();
    try {
      final thumbnailDir = await _thumbnailCacheDirectory();
      rememberThumbnailDirForSyncLookup(thumbnailDir);
      final cacheKey = cacheKeyForPath(videoPath);
      final destPath = path.join(thumbnailDir.path, '${cacheKey}_thumbnail.jpg');
      final dest = File(destPath);

      if (await dest.exists() && await dest.length() > 100) {
        return dest;
      }

      final tempDir = await getTemporaryDirectory();

      for (final timeMs in [0, 500]) {
        try {
          final generated = await VideoThumbnail.thumbnailFile(
            video: videoPath,
            thumbnailPath: tempDir.path,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 320,
            quality: 72,
            timeMs: timeMs,
          );
          if (generated == null) continue;
          final tmp = File(generated);
          if (!await tmp.exists() || await tmp.length() <= 100) {
            try {
              await tmp.delete();
            } catch (_) {}
            continue;
          }
          await tmp.copy(dest.path);
          try {
            await tmp.delete();
          } catch (_) {}
          if (await dest.exists() && await dest.length() > 100) {
            return dest;
          }
        } catch (_) {
          continue;
        }
      }
      return null;
    } finally {
      _releaseSlot();
    }
  }

  /// 若磁盘上已有有效缩略图则同步返回（与媒体页逻辑一致），避免 [FutureBuilder] 闪屏。
  /// 需先通过生成流程或 [primeSyncThumbnailLookup] 写入 [_syncPathCache]。
  static File? syncThumbnailFileIfReady(String videoPath) {
    if (kIsWeb) return null;
    final root = _syncPathCache;
    if (root == null) return null;
    return _tryReadCachedFile(root, videoPath);
  }

  /// 打开选择器时调用一次，便于首屏网格同步命中已存在的缩略图文件。
  static Future<void> primeSyncThumbnailLookup() async {
    if (kIsWeb) return;
    final d = await _thumbnailCacheDirectory();
    rememberThumbnailDirForSyncLookup(d);
  }

  static String? _syncPathCache;

  /// 在任意一次异步拿到缓存目录后调用，供后续网格项同步命中磁盘。
  static void rememberThumbnailDirForSyncLookup(Directory dir) {
    _syncPathCache = dir.path;
  }

  static File? _tryReadCachedFile(String thumbDirPath, String videoPath) {
    final cacheKey = cacheKeyForPath(videoPath);
    final f = File(path.join(thumbDirPath, '${cacheKey}_thumbnail.jpg'));
    if (f.existsSync()) {
      try {
        if (f.lengthSync() > 100) return f;
      } catch (_) {}
    }
    return null;
  }
}

/// 网格内视频缩略图：真实帧图 + 右下角播放角标（风格对齐媒体管理页）。
class VideoGridThumbnail extends StatefulWidget {
  const VideoGridThumbnail({
    super.key,
    required this.videoPath,
  });

  final String videoPath;

  @override
  State<VideoGridThumbnail> createState() => _VideoGridThumbnailState();
}

class _VideoGridThumbnailState extends State<VideoGridThumbnail> {
  Future<File?>? _future;

  @override
  void initState() {
    super.initState();
    _primeFuture();
  }

  @override
  void didUpdateWidget(covariant VideoGridThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _primeFuture();
    }
  }

  void _primeFuture() {
    if (kIsWeb) {
      _future = Future.value(null);
      return;
    }
    _future = VideoGridThumbnailHelper.getOrCreateThumbnail(widget.videoPath);
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return _placeholder();
    }

    final ready = VideoGridThumbnailHelper.syncThumbnailFileIfReady(
      widget.videoPath,
    );
    if (ready != null) {
      return _loadedStack(ready);
    }

    return FutureBuilder<File?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _generatingStack();
        }
        final file = snapshot.data;
        if (file != null && file.existsSync()) {
          try {
            if (file.lengthSync() > 100) {
              return _loadedStack(file);
            }
          } catch (_) {}
        }
        return _placeholder();
      },
    );
  }

  Widget _loadedStack(File file) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            file,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) => _placeholder(),
          ),
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.play_arrow, size: 14, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _generatingStack() {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _placeholder(),
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder() {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blueGrey.shade900, Colors.black],
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.videocam, size: 32, color: Colors.white70),
                  SizedBox(height: 4),
                  Text(
                    '视频',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.play_arrow,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
