// lib/core/directory_utils.dart
// 目录工具类 - 提供便捷的目录检查方法

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/service_locator.dart';
import '../services/directory_check_service.dart';
import '../services/file_service.dart';

/// 检查指定目录列表的写入权限和可用空间
/// 仅在开发模式下显示错误提示
class DirectoryUtils {
  /// 检查项目所需的核心目录
  static Future<void> checkCoreDirectories(BuildContext context) async {
    // 只在调试模式下执行检查并显示提示
    if (!kDebugMode) return;
    
    try {
      final directoryCheckService = getService<DirectoryCheckService>();
      final fileService = getService<FileService>();
      
      // 获取应用文档目录
      final documentsDir = fileService.documentsDirectory;
      if (documentsDir == null) return;
      
      // 需要检查的目录列表
      final directoriesToCheck = [
        '${documentsDir.path}/backups',
        '${documentsDir.path}/temp_export',
        '${documentsDir.path}/temp_import',
      ];
      
      // 检查每个目录
      for (final dirPath in directoriesToCheck) {
        final result = await directoryCheckService.checkDirectoryWriteAccess(
          directoryPath: dirPath,
        );
        
        // 如果检查失败，显示错误提示
        if (!result['success']) {
          directoryCheckService.showDirectoryCheckError(
            context: context,
            message: result['message'],
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('目录检查过程中发生错误: $e');
      }
    }
  }
  
  /// 静默检查目录（不显示UI提示）
  static Future<List<Map<String, dynamic>>> checkCoreDirectoriesSilently() async {
    final List<Map<String, dynamic>> results = [];
    
    try {
      final directoryCheckService = getService<DirectoryCheckService>();
      final fileService = getService<FileService>();
      
      // 获取应用文档目录
      final documentsDir = fileService.documentsDirectory;
      if (documentsDir == null) return results;
      
      // 需要检查的目录列表
      final directoriesToCheck = [
        '${documentsDir.path}/backups',
        '${documentsDir.path}/temp_export',
        '${documentsDir.path}/temp_import',
      ];
      
      // 检查每个目录
      for (final dirPath in directoriesToCheck) {
        final result = await directoryCheckService.checkDirectoryWriteAccess(
          directoryPath: dirPath,
        );
        
        results.add({
          'path': dirPath,
          'success': result['success'],
          'message': result['message'],
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('目录检查过程中发生错误: $e');
      }
    }
    
    return results;
  }
}