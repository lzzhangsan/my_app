// lib/services/file_cleanup_service.dart
// 文件清理服务 - 确保删除操作真正释放存储空间

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'cache_service.dart';
import 'file_service.dart';

class FileCleanupService {
  static final FileCleanupService _instance = FileCleanupService._internal();
  factory FileCleanupService() => _instance;
  FileCleanupService._internal();

  bool _isInitialized = false;
  Directory? _appDocumentsDirectory;
  Directory? _appCacheDirectory;
  Directory? _tempDirectory;
  CacheService? _cacheService;
  FileService? _fileService;

  bool get isInitialized => _isInitialized;

  /// 初始化文件清理服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 获取各种目录
      _appDocumentsDirectory = await getApplicationDocumentsDirectory();
      _appCacheDirectory = await getApplicationCacheDirectory();
      _tempDirectory = await getTemporaryDirectory();
      
      // 获取服务实例
      _cacheService = CacheService();
      _fileService = FileService();
      
      _isInitialized = true;
      
      if (kDebugMode) {
        print('FileCleanupService: 初始化完成');
        print('应用文档目录: ${_appDocumentsDirectory!.path}');
        print('应用缓存目录: ${_appCacheDirectory!.path}');
        print('临时目录: ${_tempDirectory!.path}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('FileCleanupService 初始化失败: $e');
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
          print('文件不存在，无需删除: $filePath');
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
      
      if (kDebugMode) {
        print('彻底删除媒体文件成功: $filePath (释放空间: ${_formatFileSize(fileSize)})');
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('彻底删除媒体文件失败: $filePath, 错误: $e');
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
      final documentDir = Directory('${_appDocumentsDirectory!.path}/documents/$documentName');
      if (!await documentDir.exists()) {
        if (kDebugMode) {
          print('文档目录不存在，无需删除: $documentName');
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
        print('彻底删除文档成功: $documentName (释放空间: ${_formatFileSize(directorySize)})');
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('彻底删除文档失败: $documentName, 错误: $e');
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
      final folderDir = Directory('${_appDocumentsDirectory!.path}/folders/$folderName');
      if (!await folderDir.exists()) {
        if (kDebugMode) {
          print('文件夹不存在，无需删除: $folderName');
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
        print('彻底删除文件夹成功: $folderName (释放空间: ${_formatFileSize(directorySize)})');
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('彻底删除文件夹失败: $folderName, 错误: $e');
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
            if (thumbnailPatterns.any((pattern) => fileName.contains(pattern))) {
              try {
                await file.delete();
                if (kDebugMode) {
                  print('删除缩略图文件: ${file.path}');
                }
              } catch (e) {
                if (kDebugMode) {
                  print('删除缩略图文件失败: ${file.path}, 错误: $e');
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('删除相关缩略图失败: $e');
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
                  print('删除缓存文件: ${entity.path}');
                }
              } catch (e) {
                if (kDebugMode) {
                  print('删除缓存文件失败: ${entity.path}, 错误: $e');
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('删除相关缓存文件失败: $e');
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
                  print('删除文档缓存文件: ${entity.path}');
                }
              } catch (e) {
                if (kDebugMode) {
                  print('删除文档缓存文件失败: ${entity.path}, 错误: $e');
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('删除文档缓存文件失败: $e');
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
                  print('删除文件夹缓存文件: ${entity.path}');
                }
              } catch (e) {
                if (kDebugMode) {
                  print('删除文件夹缓存文件失败: ${entity.path}, 错误: $e');
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('删除文件夹缓存文件失败: $e');
      }
    }
  }

  /// 清理所有临时文件
  Future<void> cleanAllTempFiles() async {
    if (!_isInitialized || _tempDirectory == null) return;

    try {
      int deletedCount = 0;
      int totalSize = 0;
      
      if (await _tempDirectory!.exists()) {
        final files = await _tempDirectory!.list().toList();
        
        for (final file in files) {
          if (file is File) {
            try {
              final fileSize = await file.length();
              await file.delete();
              deletedCount++;
              totalSize += fileSize;
            } catch (e) {
              if (kDebugMode) {
                print('删除临时文件失败: ${file.path}, 错误: $e');
              }
            }
          }
        }
      }
      
      if (kDebugMode) {
        print('清理临时文件完成: 删除 $deletedCount 个文件，释放空间: ${_formatFileSize(totalSize)}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('清理临时文件失败: $e');
      }
    }
  }

  /// 清理所有缓存文件
  Future<void> cleanAllCacheFiles() async {
    if (!_isInitialized || _appCacheDirectory == null) return;

    try {
      int deletedCount = 0;
      int totalSize = 0;
      
      if (await _appCacheDirectory!.exists()) {
        await for (final entity in _appCacheDirectory!.list(recursive: true)) {
          if (entity is File) {
            try {
              final fileSize = await entity.length();
              await entity.delete();
              deletedCount++;
              totalSize += fileSize;
            } catch (e) {
              if (kDebugMode) {
                print('删除缓存文件失败: ${entity.path}, 错误: $e');
              }
            }
          }
        }
      }
      
      if (kDebugMode) {
        print('清理缓存文件完成: 删除 $deletedCount 个文件，释放空间: ${_formatFileSize(totalSize)}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('清理缓存文件失败: $e');
      }
    }
  }

  /// 清理孤立文件（数据库中不存在但文件系统中存在的文件）
  Future<void> cleanOrphanedFiles(List<String> validFilePaths) async {
    if (!_isInitialized) return;

    try {
      int deletedCount = 0;
      int totalSize = 0;
      
      // 扫描媒体目录
      final mediaDir = Directory('${_appDocumentsDirectory!.path}/media');
      if (await mediaDir.exists()) {
        await for (final entity in mediaDir.list(recursive: true)) {
          if (entity is File) {
            final filePath = entity.path;
            if (!validFilePaths.contains(filePath)) {
              try {
                final fileSize = await entity.length();
                await entity.delete();
                deletedCount++;
                totalSize += fileSize;
                
                if (kDebugMode) {
                  print('删除孤立文件: $filePath');
                }
              } catch (e) {
                if (kDebugMode) {
                  print('删除孤立文件失败: $filePath, 错误: $e');
                }
              }
            }
          }
        }
      }
      
      if (kDebugMode) {
        print('清理孤立文件完成: 删除 $deletedCount 个文件，释放空间: ${_formatFileSize(totalSize)}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('清理孤立文件失败: $e');
      }
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
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  /// 获取应用总存储使用量
  Future<int> getAppTotalStorageUsage() async {
    if (!_isInitialized) return 0;

    try {
      int totalSize = 0;
      
      // 计算文档目录大小
      if (_appDocumentsDirectory != null && await _appDocumentsDirectory!.exists()) {
        totalSize += await _getDirectorySize(_appDocumentsDirectory!.path);
      }
      
      // 计算缓存目录大小
      if (_appCacheDirectory != null && await _appCacheDirectory!.exists()) {
        totalSize += await _getDirectorySize(_appCacheDirectory!.path);
      }
      
      return totalSize;
    } catch (e) {
      if (kDebugMode) {
        print('获取应用存储使用量失败: $e');
      }
      return 0;
    }
  }

  /// 执行完整的存储清理
  Future<void> performFullStorageCleanup() async {
    if (!_isInitialized) return;

    try {
      if (kDebugMode) {
        print('开始执行完整存储清理...');
      }
      
      // 清理临时文件
      await cleanAllTempFiles();
      
      // 清理缓存文件
      await cleanAllCacheFiles();
      
      if (kDebugMode) {
        print('完整存储清理完成');
      }
    } catch (e) {
      if (kDebugMode) {
        print('完整存储清理失败: $e');
      }
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    _isInitialized = false;
    
    if (kDebugMode) {
      print('FileCleanupService: 资源已释放');
    }
  }
}
