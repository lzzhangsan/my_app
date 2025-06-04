// 媒体类型枚举定义
// 从database_helper.dart中提取出来，作为独立的模型文件

enum MediaType {
  image,   // 图片
  video,   // 视频
  audio,   // 音频
  folder,  // 文件夹
}

/// MediaType扩展方法
extension MediaTypeExtension on MediaType {
  /// 获取媒体类型的显示名称
  String get displayName {
    switch (this) {
      case MediaType.image:
        return '图片';
      case MediaType.video:
        return '视频';
      case MediaType.audio:
        return '音频';
      case MediaType.folder:
        return '文件夹';
    }
  }

  /// 获取媒体类型的图标
  String get iconName {
    switch (this) {
      case MediaType.image:
        return 'image';
      case MediaType.video:
        return 'video_file';
      case MediaType.audio:
        return 'audio_file';
      case MediaType.folder:
        return 'folder';
    }
  }

  /// 从字符串创建MediaType
  static MediaType? fromString(String value) {
    switch (value.toLowerCase()) {
      case 'image':
        return MediaType.image;
      case 'video':
        return MediaType.video;
      case 'audio':
        return MediaType.audio;
      case 'folder':
        return MediaType.folder;
      default:
        return null;
    }
  }
}