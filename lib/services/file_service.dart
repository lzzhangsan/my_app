// lib/services/file_service.dart
// 文件服务 - 处理文件系统操作

import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class FileService { // 确认 FileService 类定义正确
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

  /// 检查指定目录的写入权限和可用空间（仅开发态使用）
  /// 用于检查 backups/、temp_export/、temp_import/ 目录
  Future<Map<String, dynamic>> checkDirectoryWriteAccess({
    required String directoryPath,
  }) async {
    try {
      final dir = Directory(directoryPath);
      
      // 检查目录是否存在，不存在则创建
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      
      // 尝试列出目录内容以检查读权限
      try {
        await dir.list().first;
      } catch (e) {
        if (kDebugMode) {
          print('目录不可读: $directoryPath');
        }
        return {'success': false, 'message': '目录不可读: $directoryPath'};
      }
      
      // 尝试创建测试文件以检查写权限
      final testFile = File('${dir.path}/_test_write_access.tmp');
      try {
        await testFile.writeAsString('test', flush: true);
      } catch (e) {
        if (kDebugMode) {
          print('目录不可写: $directoryPath');
        }
        return {'success': false, 'message': '目录不可写: $directoryPath'};
      }
      
      // 删除测试文件
      if (await testFile.exists()) {
        await testFile.delete();
      }
      
      // 检查可用空间 (至少需要100MB可用空间)
      final availableSpace = await _getAvailableSpace(dir);
      const minSpaceRequired = 100 * 1024 * 1024; // 100 MB
      if (availableSpace < minSpaceRequired) {
        if (kDebugMode) {
          print('目录空间不足: $directoryPath');
        }
        return {'success': false, 'message': '目录空间不足: $directoryPath'};
      }
```

file_service.dart