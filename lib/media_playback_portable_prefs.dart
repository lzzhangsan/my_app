import 'package:shared_preferences/shared_preferences.dart';

import 'video_sequential_resume_prefs.dart';

/// 文档/媒体栏「顺序模式」下按目录保存的播放游标（与 [MediaPlayerContainerState] 一致）。
const String kMediaSequentialIndexPrefsPrefix = 'media_player_seq_idx_';

/// 收集可随备份迁移的整型偏好：顺序播放游标、顺序模式下视频续播毫秒。
Map<String, int> collectPlaybackStateIntPrefs(SharedPreferences prefs) {
  final out = <String, int>{};
  for (final k in prefs.getKeys()) {
    if (!k.startsWith(kMediaSequentialIndexPrefsPrefix) &&
        !k.startsWith(kDocSeqVideoResumeMsPrefix)) {
      continue;
    }
    final v = prefs.getInt(k);
    if (v != null) out[k] = v;
  }
  return out;
}

/// 将 [collectPlaybackStateIntPrefs] 的条目写回；仅允许已知前缀，防止导入恶意键名。
Future<void> mergePlaybackStateIntPrefs(
  SharedPreferences prefs,
  Map<String, dynamic> container,
) async {
  final map = container['playback_state_ints'];
  if (map is! Map) return;
  for (final e in map.entries) {
    final k = e.key.toString();
    if (!k.startsWith(kMediaSequentialIndexPrefsPrefix) &&
        !k.startsWith(kDocSeqVideoResumeMsPrefix)) {
      continue;
    }
    final v = e.value;
    if (v is num) {
      await prefs.setInt(k, v.toInt());
    }
  }
}
