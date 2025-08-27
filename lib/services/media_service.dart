// lib/services/media_service.dart
// 媒体服务 - 处理图片、视频、音频等媒体文件

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/media_item.dart';
import '../models/media_type.dart';
import '../core/service_locator.dart';
import 'file_cleanup_service.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class MediaService {
  static final MediaService _instance = MediaService._internal();
  factory MediaService() => _instance;
  MediaService._internal();

  bool _isInitialized = false;
  Directory? _mediaDirectory;
  final List<MediaItem> _mediaCache = [];
  final ValueNotifier<List<MediaItem>> _mediaNotifier = ValueNotifier([]);

  ValueNotifier<List<MediaItem>> get mediaNotifier => _mediaNotifier;
  List<MediaItem> get mediaItems => List.unmodifiable(_mediaCache);
  bool get isInitialized => _isInitialized;

  /// 初始化媒体服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 获取应用文档目录
      final appDir = await getApplicationDocumentsDirectory();
      _mediaDirectory = Directory('${appDir.path}/media');
      
      // 确保媒体目录存在
      if (!await _mediaDirectory!.exists()) {
        await _mediaDirectory!.create(recursive: true);
      }

      // 请求存储权限
      await _requestPermissions();
      
      // 加载现有媒体文件
      await _loadMediaFiles();
      
      _isInitialized = true;
      
      if (kDebugMode) {
        print('MediaService: 初始化完成，找到 ${_mediaCache.length} 个媒体文件');
      }
    } catch (e) {
      if (kDebugMode) {
        print('MediaService 初始化失败: $e');
      }
      rethrow;
    }
  }

  /// 请求必要权限
  Future<void> _requestPermissions() async {
    final permissions = [
      Permission.storage,
      Permission.camera,
      Permission.microphone,
    ];

    for (final permission in permissions) {
      final status = await permission.status;
      if (!status.isGranted) {
        await permission.request();
      }
    }
  }

  /// 加载媒体文件
  Future<void> _loadMediaFiles() async {
    if (_mediaDirectory == null) return;

    try {
      _mediaCache.clear();
      
      final files = await _mediaDirectory!.list().toList();
      
      for (final file in files) {
        if (file is File) {
          final mediaItem = await _createMediaItemFromFile(file);
          if (mediaItem != null) {
            _mediaCache.add(mediaItem);
          }
        }
      }
      
      // 按日期排序（最新的在前）
      _mediaCache.sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      
      _mediaNotifier.value = List.from(_mediaCache);
    } catch (e) {
      if (kDebugMode) {
        print('加载媒体文件失败: $e');
      }
    }
  }

  /// 从文件创建MediaItem
  Future<MediaItem?> _createMediaItemFromFile(File file) async {
    try {
      final stat = await file.stat();
      final fileName = file.path.split('/').last;
      final extension = fileName.split('.').last.toLowerCase();
      
      MediaType type;
      if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].contains(extension)) {
        type = MediaType.image;
      } else if (['mp4', 'avi', 'mov', 'wmv', 'flv', 'webm'].contains(extension)) {
        type = MediaType.video;
      } else if (['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a'].contains(extension)) {
        type = MediaType.audio;
      } else {
        return null; // 不支持的文件类型
      }
      
      return MediaItem(
        id: fileName.hashCode.toString(),
        name: fileName,
        path: file.path,
        type: type,
        directory: 'media',
        dateAdded: stat.modified,
      );
    } catch (e) {
      if (kDebugMode) {
        print('创建MediaItem失败: $e');
      }
      return null;
    }
  }

  /// 添加媒体文件
  Future<MediaItem?> addMediaFile(File sourceFile, {String? customName}) async {
    if (!_isInitialized || _mediaDirectory == null) {
      throw Exception('MediaService 未初始化');
    }

    try {
      final fileName = customName ?? sourceFile.path.split('/').last;
      final targetFile = File('${_mediaDirectory!.path}/$fileName');
      
      // 复制文件到媒体目录
      await sourceFile.copy(targetFile.path);
      
      // 创建MediaItem
      final mediaItem = await _createMediaItemFromFile(targetFile);
      
      if (mediaItem != null) {
        _mediaCache.insert(0, mediaItem); // 添加到开头
        _mediaNotifier.value = List.from(_mediaCache);
        
        if (kDebugMode) {
          print('添加媒体文件成功: ${mediaItem.name}');
        }
      }
      
      return mediaItem;
    } catch (e) {
      if (kDebugMode) {
        print('添加媒体文件失败: $e');
      }
      rethrow;
    }
  }

  /// 删除媒体文件
  Future<bool> deleteMediaFile(MediaItem mediaItem) async {
    try {
      // 使用文件清理服务彻底删除文件
      final fileCleanupService = getService<FileCleanupService>();
      if (fileCleanupService.isInitialized) {
        await fileCleanupService.deleteMediaFileCompletely(mediaItem.path);
      } else {
        // 如果清理服务未初始化，使用传统方法删除
        final file = File(mediaItem.path);
        if (await file.exists()) {
          await file.delete();
        }
      }
      
      _mediaCache.removeWhere((item) => item.id == mediaItem.id);
      _mediaNotifier.value = List.from(_mediaCache);
      
      if (kDebugMode) {
        print('删除媒体文件成功: ${mediaItem.name}');
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('删除媒体文件失败: $e');
      }
      return false;
    }
  }

  /// 获取媒体文件大小
  Future<int> getMediaFileSize(MediaItem mediaItem) async {
    try {
      final file = File(mediaItem.path);
      if (await file.exists()) {
        final stat = await file.stat();
        return stat.size;
      }
      return 0;
    } catch (e) {
      return 0;
    }
  }

  /// 获取总媒体文件大小
  Future<int> getTotalMediaSize() async {
    int totalSize = 0;
    for (final item in _mediaCache) {
      totalSize += await getMediaFileSize(item);
    }
    return totalSize;
  }

  /// 按类型筛选媒体文件
  List<MediaItem> getMediaByType(MediaType type) {
    return _mediaCache.where((item) => item.type == type).toList();
  }

  /// 搜索媒体文件
  List<MediaItem> searchMedia(String query) {
    if (query.isEmpty) return _mediaCache;
    
    final lowerQuery = query.toLowerCase();
    return _mediaCache.where((item) => 
      item.name.toLowerCase().contains(lowerQuery)
    ).toList();
  }

  /// 刷新媒体列表
  Future<void> refresh() async {
    await _loadMediaFiles();
  }

  /// 清理缓存
  void clearCache() {
    _mediaCache.clear();
    _mediaNotifier.value = [];
  }

  /// 释放资源
  Future<void> dispose() async {
    _mediaNotifier.dispose();
    clearCache();
    _isInitialized = false;
    
    if (kDebugMode) {
      print('MediaService: 资源已释放');
    }
  }

  Future<File?> generateVideoThumbnail(String videoPath) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final thumbnailPath = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: tempDir.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 320,
        quality: 75,
      );
      if (thumbnailPath != null) {
        final thumbnailFile = File(thumbnailPath);
        if (await thumbnailFile.exists() && await thumbnailFile.length() > 100) {
          return thumbnailFile;
        }
      }
      return null;
    } catch (e) {
      print('生成视频缩略图失败: $e');
      return null;
    }
  }
}