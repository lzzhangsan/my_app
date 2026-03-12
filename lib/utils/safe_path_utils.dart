// lib/utils/safe_path_utils.dart
// 安全路径工具 - 防止 Zip Slip 等路径遍历攻击

import 'package:path/path.dart' as p;

/// 校验解压路径是否在目标目录内，防止 Zip Slip 路径遍历
/// 返回规范化后的安全路径，若路径非法则抛出 [ArgumentError]
/// [baseDir] 解压目标根目录（如临时目录）
/// [entryName] ZIP 内条目名称（可能含 ../）
String resolveSafeExtractPath(String baseDir, String entryName) {
  final baseNormalized = p.normalize(p.absolute(baseDir));
  final resolved = p.normalize(p.absolute(p.join(baseDir, entryName)));
  final prefix = baseNormalized.endsWith(p.separator) ? baseNormalized : baseNormalized + p.separator;
  if (resolved != baseNormalized && !resolved.startsWith(prefix)) {
    throw ArgumentError('非法路径：ZIP 条目 "$entryName" 试图写入目标目录外');
  }
  return resolved;
}
