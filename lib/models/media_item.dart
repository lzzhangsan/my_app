// lib/models/media_item.dart
import '../database_helper.dart'; // 导入MediaType枚举

/// 媒体项类，用于表示一个媒体文件或文件夹
class MediaItem {
  final String id; // 唯一标识符
  final String name; // 名称
  final String path; // 文件路径
  final MediaType type; // 媒体类型
  final String directory; // 所在目录
  final DateTime dateAdded; // 添加日期

  MediaItem({
    required this.id,
    required this.name,
    required this.path,
    required this.type,
    required this.directory,
    required this.dateAdded,
  });

  /// 从 Map 构造 MediaItem，用于从数据库读取数据
  factory MediaItem.fromMap(Map<String, dynamic> map) => MediaItem(
    id: map['id'] as String,
    name: map['name'] as String,
    path: map['path'] as String,
    type: MediaType.values[map['type'] as int],
    directory: map['directory'] as String,
    dateAdded: DateTime.parse(map['date_added'] as String),
  );

  /// 将 MediaItem 转换为 Map，用于存储到数据库
  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'path': path,
    'type': type.index,
    'directory': directory,
    'date_added': dateAdded.toIso8601String(),
  };
}

