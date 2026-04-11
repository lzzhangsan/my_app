import 'package:shared_preferences/shared_preferences.dart';

/// 文档编辑顺序模式下按媒体 [id] 记录上次退出时的播放位置（毫秒），换来源后同一 id 仍续播。
const String kDocSeqVideoResumeMsPrefix = 'doc_seq_video_resume_ms_';

String videoResumePrefsKeyForMediaId(String mediaId) =>
    '$kDocSeqVideoResumeMsPrefix$mediaId';

Future<int?> readVideoResumePositionMs(
  SharedPreferences prefs,
  String mediaId,
) async {
  if (mediaId.isEmpty) return null;
  return prefs.getInt(videoResumePrefsKeyForMediaId(mediaId));
}

Future<void> writeVideoResumePositionMs(
  SharedPreferences prefs,
  String mediaId,
  int positionMs,
) async {
  if (mediaId.isEmpty) return;
  await prefs.setInt(videoResumePrefsKeyForMediaId(mediaId), positionMs);
}

Future<void> clearVideoResumePositionMs(
  SharedPreferences prefs,
  String mediaId,
) async {
  if (mediaId.isEmpty) return;
  await prefs.remove(videoResumePrefsKeyForMediaId(mediaId));
}
