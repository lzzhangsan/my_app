import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用文档下「媒体库」目录名（仅含图片/视频，与 [DatabaseService] 中 `media_items` 对应；
/// 「导入媒体数据」只替换此目录，不涉及日记）。
const String kMediaLibraryDirName = 'media';

/// 日记本专属媒体目录（图/视/音附件从媒体库选入时会复制到此；勿在「导入媒体数据」中删除此目录）。
const String kDiaryOwnedMediaDirName = 'diary_media';

/// 日记录音等默认保存目录（与 [kMediaLibraryDirName] 无关；「导入媒体数据」不会删除此目录）。
const String kDiaryRecordingDirName = 'audio';

Future<String> getApplicationDocumentsPath() async =>
    (await getApplicationDocumentsDirectory()).path;

Future<String> getMediaLibraryRootPath() async =>
    p.join(await getApplicationDocumentsPath(), kMediaLibraryDirName);

Future<String> getDiaryMediaRootPath() async =>
    p.join(await getApplicationDocumentsPath(), kDiaryOwnedMediaDirName);

/// 确保日记专属目录存在。
Future<Directory> ensureDiaryMediaDirectory() async {
  final d = Directory(await getDiaryMediaRootPath());
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

/// [absolutePath] 是否落在 [directoryRoot] 之下（规范化后比较，兼容 Windows）。
bool isPathUnderDirectory(String absolutePath, String directoryRoot) {
  final a = p.normalize(p.absolute(absolutePath));
  final r = p.normalize(p.absolute(directoryRoot));
  final sep = p.separator;
  if (Platform.isWindows) {
    final al = a.toLowerCase();
    final rl = r.toLowerCase();
    return al.startsWith('$rl$sep') || al == rl;
  }
  return a.startsWith('$r$sep') || a == r;
}
