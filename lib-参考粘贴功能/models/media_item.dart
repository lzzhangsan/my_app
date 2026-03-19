// lib/models/media_item.dart
import 'media_type.dart'; // 导入MediaType枚举

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
  factory MediaItem.fromMap(Map<String, dynamic> map) {
    final id = map['id'] as String? ?? '';
    
    // 对于特殊文件夹ID（回收站和收藏夹），始终使用文件夹类型
    if (id == 'recycle_bin' || id == 'favorites') {
      return MediaItem(
        id: id,
        name: map['name'] as String? ?? '',
        path: map['path'] as String? ?? '',
        type: MediaType.folder, // 强制使用文件夹类型
        directory: map['directory'] as String? ?? '',
        dateAdded: DateTime.parse(map['date_added'] as String? ?? DateTime.now().toIso8601String()),
      );
    }
    
    // 对于其他媒体项，安全地获取type索引
    final typeIndex = map['type'] as int? ?? 0;
    final safeTypeIndex = typeIndex < MediaType.values.length ? typeIndex : 0; // 如果索引越界，默认使用image类型
    
    return MediaItem(
      id: id,
      name: map['name'] as String? ?? '',
      path: map['path'] as String? ?? '',
      type: MediaType.values[safeTypeIndex],
      directory: map['directory'] as String? ?? '',
      dateAdded: DateTime.parse(map['date_added'] as String? ?? DateTime.now().toIso8601String()),
    );
  }

  /// 将 MediaItem 转换为 Map，用于存储到数据库
  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'path': path,
    'type': type.index,
    'directory': directory,
    'date_added': dateAdded.toIso8601String(),
    'created_at': DateTime.now().millisecondsSinceEpoch,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  };
}

