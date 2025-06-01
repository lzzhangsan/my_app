// lib/services/file_service.dart
// 文件服务 - 处理文件系统操作

import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/folder.dart';
import '../models/document.dart';

class FileService {
  static final FileService _instance = FileService._internal();
  factory FileService() => _instance;
  FileService._internal();

  bool _isInitialized = false;
  Directory? _documentsDirectory;
  Directory? _tempDirectory;
  Directory? _cacheDirectory;
  
  bool get isInitialized => _isInitialized;
  Directory? get documentsDirectory => _documentsDirectory;
  Directory? get tempDirectory => _tempDirectory;
  Directory? get cacheDirectory => _cacheDirectory;

  /// 初始化文件服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 获取各种目录
      _documentsDirectory = await getApplicationDocumentsDirectory();
      _tempDirectory = await getTemporaryDirectory();
      _cacheDirectory = await getApplicationCacheDirectory();
      
      // 确保文档目录存在
      if (!await _documentsDirectory!.exists()) {
        await _documentsDirectory!.create(recursive: true);
      }
      
      // 请求存储权限
      await _requestStoragePermission();
      
      _isInitialized = true;
      
      if (kDebugMode) {
        print('FileService: 初始化完成');
        print('文档目录: ${_documentsDirectory!.path}');
        print('临时目录: ${_tempDirectory!.path}');
        print('缓存目录: ${_cacheDirectory!.path}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('FileService 初始化失败: $e');
      }
      rethrow;
    }
  }

  /// 请求存储权限
  Future<void> _requestStoragePermission() async {
    final status = await Permission.storage.status;
    if (!status.isGranted) {
      await Permission.storage.request();
    }
  }

  /// 创建文件
  Future<File> createFile(String path, {String content = ''}) async {
    if (!_isInitialized) {
      throw Exception('FileService 未初始化');
    }

    try {
      final file = File(path);
      
      // 确保父目录存在
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      
      await file.writeAsString(content, encoding: utf8);
      
      if (kDebugMode) {
        print('创建文件成功: $path');
      }
      
      return file;
    } catch (e) {
      if (kDebugMode) {
        print('创建文件失败: $e');
      }
      rethrow;
    }
  }

  /// 读取文件内容
  Future<String> readFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        throw FileSystemException('文件不存在', path);
      }
      
      return await file.readAsString(encoding: utf8);
    } catch (e) {
      if (kDebugMode) {
        print('读取文件失败: $e');
      }
      rethrow;
    }
  }

  /// 写入文件内容
  Future<void> writeFile(String path, String content) async {
    try {
      final file = File(path);
      
      // 确保父目录存在
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      
      await file.writeAsString(content, encoding: utf8);
      
      if (kDebugMode) {
        print('写入文件成功: $path');
      }
    } catch (e) {
      if (kDebugMode) {
        print('写入文件失败: $e');
      }
      rethrow;
    }
  }

  /// 复制文件
  Future<File> copyFile(String sourcePath, String targetPath) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        throw FileSystemException('源文件不存在', sourcePath);
      }
      
      final targetFile = File(targetPath);
      
      // 确保目标目录存在
      final parentDir = targetFile.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      
      await sourceFile.copy(targetPath);
      
      if (kDebugMode) {
        print('复制文件成功: $sourcePath -> $targetPath');
      }
      
      return targetFile;
    } catch (e) {
      if (kDebugMode) {
        print('复制文件失败: $e');
      }
      rethrow;
    }
  }

  /// 移动文件
  Future<File> moveFile(String sourcePath, String targetPath) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        throw FileSystemException('源文件不存在', sourcePath);
      }
      
      // 确保目标目录存在
      final targetFile = File(targetPath);
      final parentDir = targetFile.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      
      final movedFile = await sourceFile.rename(targetPath);
      
      if (kDebugMode) {
        print('移动文件成功: $sourcePath -> $targetPath');
      }
      
      return movedFile;
    } catch (e) {
      if (kDebugMode) {
        print('移动文件失败: $e');
      }
      rethrow;
    }
  }

  /// 删除文件
  Future<bool> deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        
        if (kDebugMode) {
          print('删除文件成功: $path');
        }
        
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        print('删除文件失败: $e');
      }
      return false;
    }
  }

  /// 创建目录
  Future<Directory> createDirectory(String path) async {
    try {
      final directory = Directory(path);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
        
        if (kDebugMode) {
          print('创建目录成功: $path');
        }
      }
      return directory;
    } catch (e) {
      if (kDebugMode) {
        print('创建目录失败: $e');
      }
      rethrow;
    }
  }

  /// 删除目录
  Future<bool> deleteDirectory(String path, {bool recursive = false}) async {
    try {
      final directory = Directory(path);
      if (await directory.exists()) {
        await directory.delete(recursive: recursive);
        
        if (kDebugMode) {
          print('删除目录成功: $path');
        }
        
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        print('删除目录失败: $e');
      }
      return false;
    }
  }

  /// 列出目录内容
  Future<List<FileSystemEntity>> listDirectory(String path) async {
    try {
      final directory = Directory(path);
      if (!await directory.exists()) {
        throw FileSystemException('目录不存在', path);
      }
      
      return await directory.list().toList();
    } catch (e) {
      if (kDebugMode) {
        print('列出目录内容失败: $e');
      }
      rethrow;
    }
  }

  /// 检查文件是否存在
  Future<bool> fileExists(String path) async {
    try {
      return await File(path).exists();
    } catch (e) {
      return false;
    }
  }

  /// 检查目录是否存在
  Future<bool> directoryExists(String path) async {
    try {
      return await Directory(path).exists();
    } catch (e) {
      return false;
    }
  }

  /// 获取文件大小
  Future<int> getFileSize(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final stat = await file.stat();
        return stat.size;
      }
      return 0;
    } catch (e) {
      return 0;
    }
  }

  /// 获取文件修改时间
  Future<DateTime?> getFileModifiedTime(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final stat = await file.stat();
        return stat.modified;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 获取目录大小
  Future<int> getDirectorySize(String path) async {
    try {
      final directory = Directory(path);
      if (!await directory.exists()) {
        return 0;
      }
      
      int totalSize = 0;
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          final stat = await entity.stat();
          totalSize += stat.size;
        }
      }
      
      return totalSize;
    } catch (e) {
      if (kDebugMode) {
        print('获取目录大小失败: $e');
      }
      return 0;
    }
  }

  /// 清理临时文件
  Future<void> cleanTempFiles() async {
    if (_tempDirectory == null) return;
    
    try {
      final files = await _tempDirectory!.list().toList();
      for (final file in files) {
        if (file is File) {
          await file.delete();
        }
      }
      
      if (kDebugMode) {
        print('清理临时文件完成');
      }
    } catch (e) {
      if (kDebugMode) {
        print('清理临时文件失败: $e');
      }
    }
  }

  /// 清理缓存文件
  Future<void> cleanCacheFiles() async {
    if (_cacheDirectory == null) return;
    
    try {
      final files = await _cacheDirectory!.list().toList();
      for (final file in files) {
        if (file is File) {
          await file.delete();
        }
      }
      
      if (kDebugMode) {
        print('清理缓存文件完成');
      }
    } catch (e) {
      if (kDebugMode) {
        print('清理缓存文件失败: $e');
      }
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    _isInitialized = false;
    
    if (kDebugMode) {
      print('FileService: 资源已释放');
    }
  }
}