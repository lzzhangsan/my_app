// lib/models/media_item.dart
import 'media_type.dart'; // 导入MediaType枚举
import 'video_view_params.dart';

double? _readKenBurnsCoord(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is num) return v.toDouble();
  return null;
}

/// 媒体项类，用于表示一个媒体文件或文件夹
class MediaItem {
  final String id; // 唯一标识符
  final String name; // 名称
  final String path; // 文件路径
  final MediaType type; // 媒体类型
  final String directory; // 所在目录
  final DateTime dateAdded; // 添加日期
  /// 渐进放大（Ken Burns）缩放中心，相对图片左上角的归一化横坐标 0～1；null 表示几何中心。
  final double? kenBurnsCenterX;

  /// 渐进放大缩放中心纵坐标 0～1；null 表示几何中心。
  final double? kenBurnsCenterY;

  /// 视频视窗变换（仅 type 为视频时有效）。
  final VideoViewParams videoViewParams;

  /// 星标收藏（仅图/视频；不移动目录，仅排序靠前 + UI 标识）。
  final bool isFavorite;

  /// User-defined position inside [directory]. Null keeps the legacy order.
  final int? sortOrder;

  MediaItem({
    required this.id,
    required this.name,
    required this.path,
    required this.type,
    required this.directory,
    required this.dateAdded,
    this.kenBurnsCenterX,
    this.kenBurnsCenterY,
    this.videoViewParams = const VideoViewParams(),
    this.isFavorite = false,
    this.sortOrder,
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
        dateAdded: DateTime.parse(
          map['date_added'] as String? ?? DateTime.now().toIso8601String(),
        ),
        videoViewParams: const VideoViewParams(),
        isFavorite: false,
        sortOrder:
            map['sort_order'] is num
                ? (map['sort_order'] as num).toInt()
                : int.tryParse('${map['sort_order'] ?? ''}'),
      );
    }

    // 对于其他媒体项，安全地获取type索引
    final typeIndex = map['type'] as int? ?? 0;
    final safeTypeIndex =
        typeIndex < MediaType.values.length
            ? typeIndex
            : 0; // 如果索引越界，默认使用image类型

    final favRaw = map['is_favorite'];
    final isFav =
        favRaw == true || favRaw == 1 || (favRaw is num && favRaw != 0);

    return MediaItem(
      id: id,
      name: map['name'] as String? ?? '',
      path: map['path'] as String? ?? '',
      type: MediaType.values[safeTypeIndex],
      directory: map['directory'] as String? ?? '',
      dateAdded: DateTime.parse(
        map['date_added'] as String? ?? DateTime.now().toIso8601String(),
      ),
      kenBurnsCenterX: _readKenBurnsCoord(map['ken_burns_center_x']),
      kenBurnsCenterY: _readKenBurnsCoord(map['ken_burns_center_y']),
      videoViewParams: VideoViewParams.fromMediaMap(map),
      isFavorite: isFav,
      sortOrder:
          map['sort_order'] is num
              ? (map['sort_order'] as num).toInt()
              : int.tryParse('${map['sort_order'] ?? ''}'),
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
    if (kenBurnsCenterX != null) 'ken_burns_center_x': kenBurnsCenterX,
    if (kenBurnsCenterY != null) 'ken_burns_center_y': kenBurnsCenterY,
    if (!videoViewParams.isDefault) ...videoViewParams.toDbUpdateMap(),
    'is_favorite': isFavorite ? 1 : 0,
    if (sortOrder != null) 'sort_order': sortOrder,
  };

  MediaItem copyWith({
    String? id,
    String? name,
    String? path,
    MediaType? type,
    String? directory,
    DateTime? dateAdded,
    double? kenBurnsCenterX,
    double? kenBurnsCenterY,
    VideoViewParams? videoViewParams,
    bool? isFavorite,
    int? sortOrder,
    bool clearSortOrder = false,
    bool clearKenBurnsCenter = false,
    bool clearVideoViewParams = false,
  }) {
    return MediaItem(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      type: type ?? this.type,
      directory: directory ?? this.directory,
      dateAdded: dateAdded ?? this.dateAdded,
      kenBurnsCenterX:
          clearKenBurnsCenter
              ? null
              : (kenBurnsCenterX ?? this.kenBurnsCenterX),
      kenBurnsCenterY:
          clearKenBurnsCenter
              ? null
              : (kenBurnsCenterY ?? this.kenBurnsCenterY),
      videoViewParams:
          clearVideoViewParams
              ? const VideoViewParams()
              : (videoViewParams ?? this.videoViewParams),
      isFavorite: isFavorite ?? this.isFavorite,
      sortOrder: clearSortOrder ? null : (sortOrder ?? this.sortOrder),
    );
  }
}
