import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 背景视频音量（0～1），按「视频文件路径」持久化，供调整页与各处背景循环播放共用。
///
/// 含**进程内缓存**：[setVolumeForPath] 在 `await` 磁盘写入之前先更新缓存，避免退出调整页瞬间
/// 重建背景播放器时读到 SharedPreferences 尚未落盘的旧值。
class BackgroundVideoVolumePrefs {
  BackgroundVideoVolumePrefs._();

  static final Map<String, double> _memoryVolumeByCanonPath = {};

  /// 与存储键一致的路径规范化（Windows 统一小写，避免封面 `File.path` 与预览页路径大小写不一致）。
  static String canonicalPath(String pathStr) {
    if (pathStr.isEmpty) return '';
    var s = p.normalize(p.absolute(pathStr));
    if (Platform.isWindows) {
      s = s.replaceAll('/', '\\').toLowerCase();
    }
    return s;
  }

  static String _storageKey(String canon) {
    final h = md5.convert(utf8.encode(canon)).toString();
    return 'bg_vid_vol_v1_$h';
  }

  /// 仅读内存缓存；非 null 表示本会话已加载或刚写入，可立即用于 [VideoPlayerController.setVolume]。
  static double? tryMemoryVolumeForPath(String pathStr) {
    if (pathStr.isEmpty) return null;
    final canon = canonicalPath(pathStr);
    return _memoryVolumeByCanonPath[canon];
  }

  /// 未设置过则视为 0.0（无声）。
  static Future<double> volumeForPath(String pathStr) async {
    if (pathStr.isEmpty) return 0.0;
    final canon = canonicalPath(pathStr);
    final mem = _memoryVolumeByCanonPath[canon];
    if (mem != null) return mem;

    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble(_storageKey(canon)) ?? 0.0;
    _memoryVolumeByCanonPath[canon] = v;
    return v;
  }

  /// 先同步更新内存缓存，再异步写入磁盘。
  static Future<void> setVolumeForPath(String pathStr, double volume) async {
    if (pathStr.isEmpty) return;
    final canon = canonicalPath(pathStr);
    final v = volume.clamp(0.0, 1.0);
    final key = _storageKey(canon);
    if (v.abs() < 1e-6) {
      _memoryVolumeByCanonPath.remove(canon);
    } else {
      _memoryVolumeByCanonPath[canon] = v;
    }

    final prefs = await SharedPreferences.getInstance();
    if (v.abs() < 1e-6) {
      await prefs.remove(key);
    } else {
      await prefs.setDouble(key, v);
    }
  }

  /// 从备份恢复 SharedPreferences 后调用，避免内存缓存与磁盘不一致。
  static void clearMemoryCacheAfterImport() {
    _memoryVolumeByCanonPath.clear();
  }
}
