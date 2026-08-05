// lib/services/file_cleanup_service.dart
// 文件清理服务 - 确保删除操作真正释放存储空间

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'cache_service.dart';
import 'file_service.dart';

class FileCleanupService {
  static final FileCleanupService _instance = FileCleanupService._internal();
  factory FileCleanupService() => _instance;
  FileCleanupService._internal();

  /// 应用文档目录下按「非数据库引用」规则扫描孤立文件的子目录名（标题用于预览；须与 [cleanOrphanedFiles] 一致）。
  static const List<({String title, String subdir})>
  kOrphanScanDocumentSubdirs = [
    (title: '孤立媒体文件', subdir: 'media'),
    (title: '孤立图片文件', subdir: 'images'),
    (title: '孤立音频文件', subdir: 'audio'),
    (title: '孤立音频文件', subdir: 'audios'),
    (title: '孤立背景文件', subdir: 'background_images'),
    (title: '孤立背景文件', subdir: 'backgrounds'),
    (title: '孤立背景视频', subdir: 'background_videos'),
    (title: '孤立日记背景', subdir: 'diary_backgrounds'),
    (title: '孤立视频文件', subdir: 'videos'),
    (title: '孤立日记媒体', subdir: 'diary_media'),
    (title: '导入临时文件', subdir: 'temp_import'),
    (title: '孤立文档附件', subdir: 'documents'),

    /// 与 [deleteFolderCompletely] 使用的目录一致；库内路径均不指向此目录，仅清理删除文件夹后的残留。
    (title: '孤立文件夹附件', subdir: 'folders'),
    (title: '导出临时文件', subdir: 'backups/temp_document_export'),
  ];

  bool _isInitialized = false;
  Directory? _appDocumentsDirectory;
  Directory? _appCacheDirectory;
  Directory? _appSupportDirectory;
  Directory? _tempDirectory;

  /// 应用专属外部存储（Android: `/Android/data/<package>/files/`，系统计入「数据」）
  Directory? _externalStorageDirectory;

  /// 应用外部缓存目录（插件如 WebView、PhotoManager 可能使用）
  List<Directory> _externalCacheDirectories = [];
  CacheService? _cacheService;
  FileService? _fileService;

  bool get isInitialized => _isInitialized;

  static const MethodChannel _appStorageChannel = MethodChannel('app_storage');

  /// 读取 Android 应用私有 dataDir 一级子目录体积（含 [app_webview] 等）。
  /// 非 Android 或失败时返回空。
  Future<({String dataDir, int totalBytes, Map<String, int> children})>
  getInternalDataDirBreakdown() async {
    if (!Platform.isAndroid) {
      return (dataDir: '', totalBytes: 0, children: <String, int>{});
    }
    try {
      final raw = await _appStorageChannel.invokeMethod<dynamic>(
        'getInternalDataDirBreakdown',
      );
      if (raw is! Map) {
        return (dataDir: '', totalBytes: 0, children: <String, int>{});
      }
      final dataDir = raw['dataDir']?.toString() ?? '';
      final total =
          raw['totalBytes'] is int
              ? raw['totalBytes'] as int
              : (raw['totalBytes'] as num?)?.toInt() ?? 0;
      final children = <String, int>{};
      final c = raw['children'];
      if (c is Map) {
        c.forEach((key, value) {
          final n = value is int ? value : (value as num?)?.toInt() ?? 0;
          if (n > 0) children[key.toString()] = n;
        });
      }
      return (dataDir: dataDir, totalBytes: total, children: children);
    } catch (e) {
      if (kDebugMode) Logger.log('getInternalDataDirBreakdown 失败: $e');
      return (dataDir: '', totalBytes: 0, children: <String, int>{});
    }
  }

  /// 清理浏览器媒体/资源缓存（保留 Cookies 等登录态）。返回释放字节数。
  Future<int> clearWebViewData() async {
    if (!Platform.isAndroid) return 0;
    try {
      final freed = await _appStorageChannel.invokeMethod<dynamic>(
        'clearWebViewData',
      );
      if (freed is int) return freed;
      if (freed is num) return freed.toInt();
      return 0;
    } catch (e) {
      if (kDebugMode) Logger.log('clearWebViewData 失败: $e');
      rethrow;
    }
  }

  /// 当前浏览器媒体缓存字节数（CacheStorage 等，不含登录 Cookie）。
  Future<int> getWebViewMediaCacheBytes() async {
    if (!Platform.isAndroid) return 0;
    try {
      final raw = await _appStorageChannel.invokeMethod<dynamic>(
        'getWebViewMediaCacheBytes',
      );
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return 0;
    } catch (e) {
      if (kDebugMode) Logger.log('getWebViewMediaCacheBytes 失败: $e');
      return 0;
    }
  }

  static const String _kWebViewCacheAutoClean =
      'webview_media_cache_auto_clean_v1';
  static const String _kWebViewCacheQuotaBytes =
      'webview_media_cache_quota_bytes_v1';

  /// 默认配额 1GB（十进制，与系统存储单位一致）。
  static const int kDefaultWebViewCacheQuotaBytes = 1000 * 1000 * 1000;

  Future<bool> isWebViewMediaCacheAutoCleanEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kWebViewCacheAutoClean) ?? true;
  }

  Future<void> setWebViewMediaCacheAutoCleanEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWebViewCacheAutoClean, enabled);
  }

  Future<int> getWebViewMediaCacheQuotaBytes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kWebViewCacheQuotaBytes) ??
        kDefaultWebViewCacheQuotaBytes;
  }

  Future<void> setWebViewMediaCacheQuotaBytes(int bytes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kWebViewCacheQuotaBytes, bytes.clamp(0, 50 * 1000 * 1000 * 1000));
  }

  /// 若开启自动清理且缓存超过配额，则清理媒体缓存（保留登录）。返回释放字节；未触发返回 0。
  Future<int> enforceWebViewMediaCacheQuota({bool forceLog = false}) async {
    if (!Platform.isAndroid) return 0;
    try {
      final enabled = await isWebViewMediaCacheAutoCleanEnabled();
      if (!enabled) return 0;
      final quota = await getWebViewMediaCacheQuotaBytes();
      if (quota <= 0) return 0;
      final used = await getWebViewMediaCacheBytes();
      if (used <= quota) {
        if (forceLog && kDebugMode) {
          Logger.log(
            '浏览器媒体缓存未超限: ${_formatFileSize(used)} / ${_formatFileSize(quota)}',
          );
        }
        return 0;
      }
      if (kDebugMode) {
        Logger.log(
          '浏览器媒体缓存超限，开始清理: ${_formatFileSize(used)} > ${_formatFileSize(quota)}',
        );
      }
      final freed = await clearWebViewData();
      if (kDebugMode) {
        Logger.log('浏览器媒体缓存已自动清理，释放 ${_formatFileSize(freed)}');
      }
      return freed;
    } catch (e) {
      if (kDebugMode) Logger.log('enforceWebViewMediaCacheQuota 失败: $e');
      return 0;
    }
  }

  /// 初始化文件清理服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 获取各种目录
      _appDocumentsDirectory = await getApplicationDocumentsDirectory();
      _appCacheDirectory = await getApplicationCacheDirectory();
      _appSupportDirectory = await getApplicationSupportDirectory();
      _tempDirectory = await getTemporaryDirectory();
      try {
        _externalStorageDirectory = await getExternalStorageDirectory();
      } catch (_) {}
      try {
        final extCaches = await getExternalCacheDirectories();
        _externalCacheDirectories = extCaches ?? [];
      } catch (_) {}

      // 获取服务实例
      _cacheService = CacheService();
      _fileService = FileService();

      _isInitialized = true;

      if (kDebugMode) {
        Logger.log('FileCleanupService: 初始化完成');
        Logger.log('应用文档目录: ${_appDocumentsDirectory!.path}');
        Logger.log('应用缓存目录: ${_appCacheDirectory!.path}');
        Logger.log('应用支持目录: ${_appSupportDirectory!.path}');
        Logger.log('临时目录: ${_tempDirectory!.path}');
        if (_externalStorageDirectory != null) {
          Logger.log('应用外部存储: ${_externalStorageDirectory!.path}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('FileCleanupService 初始化失败: $e');
      }
      rethrow;
    }
  }

  /// 彻底删除媒体文件
  Future<bool> deleteMediaFileCompletely(String filePath) async {
    if (!_isInitialized) {
      throw Exception('FileCleanupService 未初始化');
    }

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        if (kDebugMode) {
          Logger.log('文件不存在，无需删除: $filePath');
        }
        return true;
      }

      // 获取文件大小用于日志记录
      final fileSize = await file.length();

      // 删除主文件
      await file.delete();

      // 删除相关的缩略图文件
      await _deleteRelatedThumbnails(filePath);

      // 删除相关的缓存文件
      await _deleteRelatedCacheFiles(filePath);
      await _deleteSupportVideoThumbnailCacheForMedia(filePath);

      if (kDebugMode) {
        Logger.log(
          '彻底删除媒体文件成功: $filePath (释放空间: ${_formatFileSize(fileSize)})',
        );
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        Logger.log('彻底删除媒体文件失败: $filePath, 错误: $e');
      }
      return false;
    }
  }

  /// 彻底删除文档及其所有相关文件
  Future<bool> deleteDocumentCompletely(String documentName) async {
    if (!_isInitialized) {
      throw Exception('FileCleanupService 未初始化');
    }

    try {
      final documentDir = Directory(
        '${_appDocumentsDirectory!.path}/documents/$documentName',
      );
      if (!await documentDir.exists()) {
        if (kDebugMode) {
          Logger.log('文档目录不存在，无需删除: $documentName');
        }
        return true;
      }

      // 计算文档目录大小
      final directorySize = await _getDirectorySize(documentDir.path);

      // 删除整个文档目录
      await documentDir.delete(recursive: true);

      // 删除相关的缓存文件
      await _deleteDocumentCacheFiles(documentName);

      if (kDebugMode) {
        Logger.log(
          '彻底删除文档成功: $documentName (释放空间: ${_formatFileSize(directorySize)})',
        );
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        Logger.log('彻底删除文档失败: $documentName, 错误: $e');
      }
      return false;
    }
  }

  /// 彻底删除文件夹及其所有内容
  Future<bool> deleteFolderCompletely(String folderName) async {
    if (!_isInitialized) {
      throw Exception('FileCleanupService 未初始化');
    }

    try {
      final folderDir = Directory(
        '${_appDocumentsDirectory!.path}/folders/$folderName',
      );
      if (!await folderDir.exists()) {
        if (kDebugMode) {
          Logger.log('文件夹不存在，无需删除: $folderName');
        }
        return true;
      }

      // 计算文件夹大小
      final directorySize = await _getDirectorySize(folderDir.path);

      // 删除整个文件夹
      await folderDir.delete(recursive: true);

      // 删除相关的缓存文件
      await _deleteFolderCacheFiles(folderName);

      if (kDebugMode) {
        Logger.log(
          '彻底删除文件夹成功: $folderName (释放空间: ${_formatFileSize(directorySize)})',
        );
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        Logger.log('彻底删除文件夹失败: $folderName, 错误: $e');
      }
      return false;
    }
  }

  /// 删除相关的缩略图文件
  Future<void> _deleteRelatedThumbnails(String filePath) async {
    try {
      final fileName = path.basename(filePath);
      final fileNameWithoutExt = path.basenameWithoutExtension(fileName);
      final extension = path.extension(fileName);

      // 查找可能的缩略图文件
      final thumbnailPatterns = [
        '${fileNameWithoutExt}_thumb$extension',
        '${fileNameWithoutExt}_thumbnail$extension',
        '${fileNameWithoutExt}_preview$extension',
        'thumb_$fileName',
        'thumbnail_$fileName',
      ];

      final fileDir = Directory(path.dirname(filePath));
      if (await fileDir.exists()) {
        final files = await fileDir.list().toList();

        for (final file in files) {
          if (file is File) {
            final fileName = path.basename(file.path);
            if (thumbnailPatterns.any(
              (pattern) => fileName.contains(pattern),
            )) {
              try {
                await file.delete();
                if (kDebugMode) {
                  Logger.log('删除缩略图文件: ${file.path}');
                }
              } catch (e) {
                if (kDebugMode) {
                  Logger.log('删除缩略图文件失败: ${file.path}, 错误: $e');
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('删除相关缩略图失败: $e');
      }
    }
  }

  /// 删除相关的缓存文件
  Future<void> _deleteRelatedCacheFiles(String filePath) async {
    try {
      final fileName = path.basename(filePath);
      final fileNameWithoutExt = path.basenameWithoutExtension(fileName);

      // 在缓存目录中查找相关文件
      if (_appCacheDirectory != null && await _appCacheDirectory!.exists()) {
        await for (final entity in _appCacheDirectory!.list(recursive: true)) {
          if (entity is File) {
            final cacheFileName = path.basename(entity.path);
            if (cacheFileName.contains(fileNameWithoutExt) ||
                cacheFileName.contains(fileName)) {
              try {
                await entity.delete();
                if (kDebugMode) {
                  Logger.log('删除缓存文件: ${entity.path}');
                }
              } catch (e) {
                if (kDebugMode) {
                  Logger.log('删除缓存文件失败: ${entity.path}, 错误: $e');
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('删除相关缓存文件失败: $e');
      }
    }
  }

  Directory? _getVideoThumbnailCacheDirectorySync() {
    if (_appSupportDirectory == null) return null;
    return Directory(path.join(_appSupportDirectory!.path, 'video_thumbnails'));
  }

  Future<Directory?> _getExistingVideoThumbnailCacheDirectory() async {
    final dir = _getVideoThumbnailCacheDirectorySync();
    if (dir == null || !await dir.exists()) return null;
    return dir;
  }

  bool _looksLikeVideoFile(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    const videoExts = {
      '.mp4',
      '.mov',
      '.m4v',
      '.mkv',
      '.avi',
      '.wmv',
      '.flv',
      '.webm',
      '.3gp',
      '.3gpp',
      '.3g2',
      '.mpeg',
      '.mpg',
      '.mts',
      '.m2ts',
      '.ts',
    };
    return videoExts.contains(ext);
  }

  String _buildVideoThumbnailCacheKey(String videoPath) {
    return '${videoPath.hashCode.abs()}_${videoPath.length}';
  }

  Set<String> _buildExpectedVideoThumbnailCacheNames(
    Iterable<String> validFilePaths,
  ) {
    final expected = <String>{};
    for (final filePath in validFilePaths) {
      if (!_looksLikeVideoFile(filePath)) continue;
      final normalized = path.normalize(path.absolute(filePath));
      final candidates = <String>{filePath, normalized};
      for (final candidate in candidates) {
        final key = _buildVideoThumbnailCacheKey(candidate);
        // 媒体页当前可能生成两类可用缩略图，完整清理时都必须保留。
        expected.add('${key}_thumbnail.jpg');
        expected.add('${key}_color_thumbnail.jpg');
      }
    }
    return expected;
  }

  Future<void> _deleteSupportVideoThumbnailCacheForMedia(
    String filePath,
  ) async {
    if (!_looksLikeVideoFile(filePath)) return;
    final thumbnailDir = await _getExistingVideoThumbnailCacheDirectory();
    if (thumbnailDir == null) return;

    final key = _buildVideoThumbnailCacheKey(
      path.normalize(path.absolute(filePath)),
    );
    await for (final entity in thumbnailDir.list()) {
      if (entity is! File) continue;
      final name = path.basename(entity.path);
      if (!name.startsWith(key)) continue;
      try {
        await entity.delete();
      } catch (e) {
        if (kDebugMode) {
          Logger.log('删除支持目录视频缩略图失败: ${entity.path}, 错误: $e');
        }
      }
    }
  }

  /// 删除文档相关的缓存文件
  Future<void> _deleteDocumentCacheFiles(String documentName) async {
    try {
      if (_appCacheDirectory != null && await _appCacheDirectory!.exists()) {
        await for (final entity in _appCacheDirectory!.list(recursive: true)) {
          if (entity is File) {
            final fileName = path.basename(entity.path);
            if (fileName.contains(documentName)) {
              try {
                await entity.delete();
                if (kDebugMode) {
                  Logger.log('删除文档缓存文件: ${entity.path}');
                }
              } catch (e) {
                if (kDebugMode) {
                  Logger.log('删除文档缓存文件失败: ${entity.path}, 错误: $e');
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('删除文档缓存文件失败: $e');
      }
    }
  }

  /// 删除文件夹相关的缓存文件
  Future<void> _deleteFolderCacheFiles(String folderName) async {
    try {
      if (_appCacheDirectory != null && await _appCacheDirectory!.exists()) {
        await for (final entity in _appCacheDirectory!.list(recursive: true)) {
          if (entity is File) {
            final fileName = path.basename(entity.path);
            if (fileName.contains(folderName)) {
              try {
                await entity.delete();
                if (kDebugMode) {
                  Logger.log('删除文件夹缓存文件: ${entity.path}');
                }
              } catch (e) {
                if (kDebugMode) {
                  Logger.log('删除文件夹缓存文件失败: ${entity.path}, 错误: $e');
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('删除文件夹缓存文件失败: $e');
      }
    }
  }

  /// 判断是否为媒体缩略图等需保留的有用缓存（清理临时文件时跳过，避免误删导致媒体页无法显示并误判为垃圾文件）
  bool _isProtectedThumbnailOrCache(String fileName) {
    final lower = fileName.toLowerCase();
    return lower.endsWith('_thumbnail.jpg') ||
        lower.endsWith('_color_thumbnail.jpg') ||
        lower.startsWith('video_thumb_') ||
        lower.startsWith('img_thumb_') ||
        lower.contains('thumbnail') ||
        lower.contains('thumb') ||
        lower.contains('waveform') ||
        lower.contains('ocr');
  }

  /// 清理所有临时文件（递归清理子目录，导入等操作会在 temp 下创建子目录）
  /// 安全策略：跳过媒体页/日记页的缩略图缓存，避免误删后媒体页无法及时重建缩略图而将正常媒体误判为垃圾删除
  Future<void> cleanAllTempFiles() async {
    if (!_isInitialized || _tempDirectory == null) return;

    try {
      int deletedCount = 0;
      int totalSize = 0;
      int skippedCount = 0;

      if (await _tempDirectory!.exists()) {
        await for (final entity in _tempDirectory!.list(recursive: true)) {
          if (entity is File) {
            final fileName = path.basename(entity.path);
            if (_isProtectedThumbnailOrCache(fileName)) {
              skippedCount++;
              if (kDebugMode) {
                Logger.log('保留缩略图缓存: ${entity.path}');
              }
              continue;
            }
            try {
              final fileSize = await entity.length();
              await entity.delete();
              deletedCount++;
              totalSize += fileSize;
            } catch (e) {
              if (kDebugMode) {
                Logger.log('删除临时文件失败: ${entity.path}, 错误: $e');
              }
            }
          }
        }
      }

      if (kDebugMode) {
        Logger.log(
          '清理临时文件完成: 删除 $deletedCount 个文件，保留 $skippedCount 个缩略图，释放空间: ${_formatFileSize(totalSize)}',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('清理临时文件失败: $e');
      }
    }
  }

  /// 清理所有缓存文件
  /// 安全策略：跳过媒体缩略图等有用缓存，与 cleanAllTempFiles 保持一致
  Future<void> cleanAllCacheFiles() async {
    if (!_isInitialized || _appCacheDirectory == null) return;

    try {
      int deletedCount = 0;
      int totalSize = 0;
      int skippedCount = 0;

      if (await _appCacheDirectory!.exists()) {
        await for (final entity in _appCacheDirectory!.list(recursive: true)) {
          if (entity is File) {
            final fileName = path.basename(entity.path);
            if (_isProtectedThumbnailOrCache(fileName)) {
              skippedCount++;
              if (kDebugMode) {
                Logger.log('保留缩略图缓存: ${entity.path}');
              }
              continue;
            }
            try {
              final fileSize = await entity.length();
              await entity.delete();
              deletedCount++;
              totalSize += fileSize;
            } catch (e) {
              if (kDebugMode) {
                Logger.log('删除缓存文件失败: ${entity.path}, 错误: $e');
              }
            }
          }
        }
      }

      if (kDebugMode) {
        Logger.log(
          '清理缓存文件完成: 删除 $deletedCount 个文件，保留 $skippedCount 个缩略图，释放空间: ${_formatFileSize(totalSize)}',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('清理缓存文件失败: $e');
      }
    }
  }

  /// 清理孤立文件（数据库中不存在但文件系统中存在的文件）
  /// validFilePaths: 数据库中有效引用的文件路径集合
  /// 安全策略：仅删除不在有效路径集合中的文件，且路径比较使用规范化+大小写不敏感（Windows/Android）
  Future<Map<String, int>> cleanOrphanedFiles(
    Iterable<String> validFilePaths,
  ) async {
    if (!_isInitialized) return {'count': 0, 'bytes': 0};

    String toKey(String p) {
      final n = path.normalize(path.absolute(p));
      return n.isEmpty
          ? n
          : (Platform.isWindows || Platform.isAndroid ? n.toLowerCase() : n);
    }

    final validSet =
        validFilePaths.map((p) => toKey(p)).where((p) => p.isNotEmpty).toSet();

    if (validSet.isEmpty) {
      if (kDebugMode) Logger.log('清理孤立文件: 有效路径集合为空，跳过清理以确保安全');
      return {'count': 0, 'bytes': 0};
    }

    int deletedCount = 0;
    int totalSize = 0;

    bool isValidFile(String filePath) {
      final key = toKey(filePath);
      if (key.isEmpty) return true;
      return validSet.contains(key);
    }

    Future<void> scanAndDelete(Directory dir) async {
      if (!await dir.exists()) return;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final filePath = entity.path;
          if (!isValidFile(filePath)) {
            try {
              final fileSize = await entity.length();
              await entity.delete();
              deletedCount++;
              totalSize += fileSize;
              if (kDebugMode) Logger.log('删除孤立文件: $filePath');
            } catch (e) {
              if (kDebugMode) Logger.log('删除孤立文件失败: $filePath, 错误: $e');
            }
          }
        }
      }
    }

    Future<void> cleanSupportVideoThumbnails() async {
      final thumbnailDir = await _getExistingVideoThumbnailCacheDirectory();
      if (thumbnailDir == null) return;

      final expectedNames = _buildExpectedVideoThumbnailCacheNames(
        validFilePaths,
      );
      await for (final entity in thumbnailDir.list()) {
        if (entity is! File) continue;
        final fileName = path.basename(entity.path);
        if (expectedNames.contains(fileName)) continue;
        try {
          final fileSize = await entity.length();
          await entity.delete();
          deletedCount++;
          totalSize += fileSize;
          if (kDebugMode) {
            Logger.log('删除孤立视频缩略图缓存: ${entity.path}');
          }
        } catch (e) {
          if (kDebugMode) {
            Logger.log('删除孤立视频缩略图缓存失败: ${entity.path}, 错误: $e');
          }
        }
      }
    }

    try {
      final base = _appDocumentsDirectory!.path;
      for (final spec in kOrphanScanDocumentSubdirs) {
        await scanAndDelete(Directory(path.join(base, spec.subdir)));
      }
      await cleanSupportVideoThumbnails();

      if (kDebugMode) {
        Logger.log(
          '清理孤立文件完成: 删除 $deletedCount 个文件，释放空间: ${_formatFileSize(totalSize)}',
        );
      }
      return {'count': deletedCount, 'bytes': totalSize};
    } catch (e) {
      if (kDebugMode) Logger.log('清理孤立文件失败: $e');
      return {'count': deletedCount, 'bytes': totalSize};
    }
  }

  /// 获取目录大小
  Future<int> _getDirectorySize(String dirPath) async {
    try {
      int totalSize = 0;
      final directory = Directory(dirPath);

      if (await directory.exists()) {
        await for (final entity in directory.list(recursive: true)) {
          if (entity is File) {
            try {
              totalSize += await entity.length();
            } catch (e) {
              // 忽略无法访问的文件
            }
          }
        }
      }

      return totalSize;
    } catch (e) {
      return 0;
    }
  }

  /// 格式化文件大小
  String _formatFileSize(int bytes) {
    if (bytes < 1000) return '${bytes}B';
    if (bytes < 1000 * 1000) {
      return '${(bytes / 1000).toStringAsFixed(1)}KB';
    }
    if (bytes < 1000 * 1000 * 1000) {
      return '${(bytes / (1000 * 1000)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1000 * 1000 * 1000)).toStringAsFixed(1)}GB';
  }

  Future<int> getPackageCodeBytes() async {
    if (!Platform.isAndroid) return 0;
    try {
      final raw = await _appStorageChannel.invokeMethod<dynamic>(
        'getPackageCodeBytes',
      );
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return 0;
    } catch (e) {
      if (kDebugMode) Logger.log('getPackageCodeBytes 失败: $e');
      return 0;
    }
  }

  /// 获取应用总存储使用量（含内部 dataDir + 应用包体 + 外部存储，对齐系统「总计」口径）
  Future<int> getAppTotalStorageUsage() async {
    if (!_isInitialized) return 0;

    try {
      int totalSize = 0;

      // Android：以系统 dataDir 全量为准（含 app_webview），避免漏计浏览器缓存
      if (Platform.isAndroid) {
        final breakdown = await getInternalDataDirBreakdown();
        if (breakdown.totalBytes > 0) {
          totalSize += breakdown.totalBytes;
        } else {
          // 通道失败时回退到 path_provider 可见目录
          if (_appDocumentsDirectory != null &&
              await _appDocumentsDirectory!.exists()) {
            totalSize += await _getDirectorySize(_appDocumentsDirectory!.path);
          }
          if (_appCacheDirectory != null && await _appCacheDirectory!.exists()) {
            totalSize += await _getDirectorySize(_appCacheDirectory!.path);
          }
          if (_appSupportDirectory != null &&
              await _appSupportDirectory!.exists()) {
            totalSize += await _getDirectorySize(_appSupportDirectory!.path);
          }
          if (_tempDirectory != null && await _tempDirectory!.exists()) {
            final tempPath = _tempDirectory!.path;
            final cachePath = _appCacheDirectory?.path;
            if (cachePath == null ||
                path.normalize(tempPath) != path.normalize(cachePath)) {
              totalSize += await _getDirectorySize(tempPath);
            }
          }
        }
        // 系统「总计」含「应用」APK 体积
        totalSize += await getPackageCodeBytes();
      } else {
        if (_appDocumentsDirectory != null &&
            await _appDocumentsDirectory!.exists()) {
          totalSize += await _getDirectorySize(_appDocumentsDirectory!.path);
        }

        if (_appCacheDirectory != null && await _appCacheDirectory!.exists()) {
          totalSize += await _getDirectorySize(_appCacheDirectory!.path);
        }

        if (_appSupportDirectory != null &&
            await _appSupportDirectory!.exists()) {
          totalSize += await _getDirectorySize(_appSupportDirectory!.path);
        }

        if (_tempDirectory != null && await _tempDirectory!.exists()) {
          totalSize += await _getDirectorySize(_tempDirectory!.path);
        }
      }

      // 应用专属外部存储（Android: browser_backups、导出文件等，系统计入「数据」）
      if (_externalStorageDirectory != null &&
          await _externalStorageDirectory!.exists()) {
        totalSize += await _getDirectorySize(_externalStorageDirectory!.path);
      }

      // 应用外部缓存（插件如 WebView、PhotoManager 可能使用）
      for (final d in _externalCacheDirectories) {
        if (await d.exists()) {
          totalSize += await _getDirectorySize(d.path);
        }
      }

      return totalSize;
    } catch (e) {
      if (kDebugMode) {
        Logger.log('获取应用存储使用量失败: $e');
      }
      return 0;
    }
  }

  /// 获取应用专属外部存储大小（含外部缓存，用于存储管理页展示）
  Future<int> getExternalStorageUsage() async {
    if (!_isInitialized) return 0;
    int total = 0;
    try {
      if (_externalStorageDirectory != null &&
          await _externalStorageDirectory!.exists()) {
        total += await _getDirectorySize(_externalStorageDirectory!.path);
      }
      for (final d in _externalCacheDirectories) {
        if (await d.exists()) {
          total += await _getDirectorySize(d.path);
        }
      }
    } catch (e) {
      if (kDebugMode) Logger.log('获取外部存储大小失败: $e');
    }
    return total;
  }

  Future<int> getVideoThumbnailCacheUsage() async {
    if (!_isInitialized) return 0;
    try {
      final dir = await _getExistingVideoThumbnailCacheDirectory();
      if (dir == null) return 0;
      return await _getDirectorySize(dir.path);
    } catch (e) {
      if (kDebugMode) Logger.log('获取视频缩略图缓存大小失败: $e');
      return 0;
    }
  }

  bool _shouldDeleteExternalStorageFile(String fileName) {
    final lower = fileName.toLowerCase();
    const knownPrefixes = [
      'directory_backup_',
      'media_backup_',
      'media_folder_',
      'browser_backup_',
      'diary_export_',
      'exported_docs_',
      'browser_data',
    ];
    const knownExtensions = {'.zip', '.json', '.tmp', '.part', '.temp'};
    return knownPrefixes.any(lower.startsWith) &&
        knownExtensions.contains(path.extension(lower));
  }

  bool _shouldDeleteExternalStorageDirectory(String dirName) {
    final lower = dirName.toLowerCase();
    const exactNames = {
      'browser_backups',
      'browser_cache',
      'webview',
      'photo_manager',
    };
    return exactNames.contains(lower) ||
        lower.endsWith('_cache') ||
        lower.endsWith('_temp') ||
        lower.startsWith('tmp');
  }

  /// 清理应用专属外部存储（含外部缓存，释放系统「数据」占用）
  /// 仅清理已知可重建的导出文件/插件缓存，避免误删用户仍需保留的外部文件。
  Future<Map<String, int>> cleanExternalStorage() async {
    int deletedCount = 0;
    int totalBytes = 0;
    if (!_isInitialized) return {'count': 0, 'bytes': 0};
    try {
      // 1. 清理外部文件目录下已知的导出文件和可重建缓存目录
      if (_externalStorageDirectory != null &&
          await _externalStorageDirectory!.exists()) {
        await for (final entity in _externalStorageDirectory!.list()) {
          try {
            if (entity is File) {
              final fileName = path.basename(entity.path);
              if (!_shouldDeleteExternalStorageFile(fileName)) continue;
              final len = await entity.length();
              await entity.delete();
              deletedCount++;
              totalBytes += len;
            } else if (entity is Directory) {
              final dirName = path.basename(entity.path);
              if (!_shouldDeleteExternalStorageDirectory(dirName)) continue;
              final size = await _getDirectorySize(entity.path);
              await entity.delete(recursive: true);
              deletedCount++;
              totalBytes += size;
            }
          } catch (_) {}
        }
      }
      // 2. 清理外部缓存目录（PhotoManager、WebView 等插件缓存）
      for (final cacheDir in _externalCacheDirectories) {
        if (!await cacheDir.exists()) continue;
        try {
          await for (final entity in cacheDir.list()) {
            try {
              if (entity is File) {
                final len = await entity.length();
                await entity.delete();
                deletedCount++;
                totalBytes += len;
              } else if (entity is Directory) {
                final size = await _getDirectorySize(entity.path);
                await entity.delete(recursive: true);
                deletedCount++;
                totalBytes += size;
              }
            } catch (_) {}
          }
        } catch (_) {}
      }
      if (kDebugMode && totalBytes > 0) {
        Logger.log(
          '清理外部存储: 删除 $deletedCount 项，释放 ${_formatFileSize(totalBytes)}',
        );
      }
    } catch (e) {
      if (kDebugMode) Logger.log('清理外部存储失败: $e');
    }
    return {'count': deletedCount, 'bytes': totalBytes};
  }

  /// 清理备份文件（directory_backup_*.zip、数据库备份等，释放空间）
  /// 备份用于恢复数据，删除后无法恢复，需用户确认
  Future<Map<String, int>> cleanBackupFiles() async {
    int deletedCount = 0;
    int totalBytes = 0;
    if (!_isInitialized || _appDocumentsDirectory == null)
      return {'count': 0, 'bytes': 0};
    try {
      final backupsDir = Directory('${_appDocumentsDirectory!.path}/backups');
      if (!await backupsDir.exists()) return {'count': 0, 'bytes': 0};
      await for (final entity in backupsDir.list()) {
        try {
          final name = path.basename(entity.path);
          if (entity is File) {
            if (name.endsWith('.zip') || name.endsWith('.json')) {
              final len = await entity.length();
              await entity.delete();
              deletedCount++;
              totalBytes += len;
            }
          } else if (entity is Directory) {
            final size = await _getDirectorySize(entity.path);
            await entity.delete(recursive: true);
            deletedCount++;
            totalBytes += size;
          }
        } catch (_) {}
      }
      if (kDebugMode && totalBytes > 0) {
        Logger.log(
          '清理备份文件: 删除 $deletedCount 项，释放 ${_formatFileSize(totalBytes)}',
        );
      }
    } catch (e) {
      if (kDebugMode) Logger.log('清理备份文件失败: $e');
    }
    return {'count': deletedCount, 'bytes': totalBytes};
  }

  /// 执行完整的存储清理（安全模式）
  /// 仅清理可重建的临时/缓存与孤立文件，不触碰用户导出/备份等可用资产。
  Future<void> performFullStorageCleanup() async {
    if (!_isInitialized) return;

    try {
      if (kDebugMode) {
        Logger.log('开始执行完整存储清理...');
      }

      // 清理临时文件
      await cleanAllTempFiles();

      // 清理缓存文件
      await cleanAllCacheFiles();

      if (kDebugMode) {
        Logger.log('完整存储清理完成');
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('完整存储清理失败: $e');
      }
    }
  }

  Future<({int count, int bytes})> _scanDeletableFilesInDirectory(
    Directory dir,
    bool Function(File file) shouldDelete,
  ) async {
    int deletedCount = 0;
    int totalSize = 0;
    if (!await dir.exists()) {
      return (count: 0, bytes: 0);
    }
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      if (!shouldDelete(entity)) continue;
      try {
        final len = await entity.length();
        deletedCount++;
        totalSize += len;
      } catch (_) {}
    }
    return (count: deletedCount, bytes: totalSize);
  }

  /// 完整清理预览（仅统计，不执行删除）
  Future<Map<String, dynamic>> previewFullStorageCleanup(
    Iterable<String> validFilePaths,
  ) async {
    final sections = <Map<String, dynamic>>[];
    int totalCount = 0;
    int totalBytes = 0;

    if (!_isInitialized) {
      return {'totalCount': 0, 'totalBytes': 0, 'sections': sections};
    }

    String toKey(String p) {
      final n = path.normalize(path.absolute(p));
      return n.isEmpty
          ? n
          : (Platform.isWindows || Platform.isAndroid ? n.toLowerCase() : n);
    }

    void addSection(String title, String pathLabel, int count, int bytes) {
      if (count <= 0 || bytes < 0) return;
      sections.add({
        'title': title,
        'path': pathLabel,
        'count': count,
        'bytes': bytes,
      });
      totalCount += count;
      totalBytes += bytes;
    }

    if (_tempDirectory != null) {
      final result = await _scanDeletableFilesInDirectory(
        _tempDirectory!,
        (file) => !_isProtectedThumbnailOrCache(path.basename(file.path)),
      );
      addSection('临时文件', _tempDirectory!.path, result.count, result.bytes);
    }

    if (_appCacheDirectory != null) {
      final result = await _scanDeletableFilesInDirectory(
        _appCacheDirectory!,
        (file) => !_isProtectedThumbnailOrCache(path.basename(file.path)),
      );
      addSection('缓存文件', _appCacheDirectory!.path, result.count, result.bytes);
    }

    final validSet =
        validFilePaths.map((p) => toKey(p)).where((p) => p.isNotEmpty).toSet();
    if (validSet.isNotEmpty && _appDocumentsDirectory != null) {
      final base = _appDocumentsDirectory!.path;
      for (final spec in kOrphanScanDocumentSubdirs) {
        final dir = Directory(path.join(base, spec.subdir));
        final result = await _scanDeletableFilesInDirectory(
          dir,
          (file) => !validSet.contains(toKey(file.path)),
        );
        addSection(spec.title, dir.path, result.count, result.bytes);
      }

      final thumbDir = await _getExistingVideoThumbnailCacheDirectory();
      if (thumbDir != null) {
        final expectedNames = _buildExpectedVideoThumbnailCacheNames(
          validFilePaths,
        );
        final result = await _scanDeletableFilesInDirectory(
          thumbDir,
          (file) => !expectedNames.contains(path.basename(file.path)),
        );
        addSection('孤立视频缩略图缓存', thumbDir.path, result.count, result.bytes);
      }
    }

    return {
      'totalCount': totalCount,
      'totalBytes': totalBytes,
      'sections': sections,
    };
  }

  /// 释放资源
  Future<void> dispose() async {
    _isInitialized = false;

    if (kDebugMode) {
      Logger.log('FileCleanupService: 资源已释放');
    }
  }
}
