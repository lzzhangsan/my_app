// lib/services/directory_check_service.dart
// 目录检查服务 - 检查目录的写入权限和可用空间

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class DirectoryCheckService {
  static final DirectoryCheckService _instance = DirectoryCheckService._internal();
  factory DirectoryCheckService() => _instance;
  DirectoryCheckService._internal();

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
      
      // 检查是否可读
      if (!dir.existsSync()) {
        if (kDebugMode) {
          print('目录不存在且无法创建: $directoryPath');
        }
        return {'success': false, 'message': '目录不存在且无法创建: $directoryPath'};
      }
      
      // 检查是否可读
      if (!dir.statSync().modeString().contains('r')) {
        if (kDebugMode) {
          print('目录不可读: $directoryPath');
        }
        return {'success': false, 'message': '目录不可读: $directoryPath'};
      }
      
      // 检查是否可写
      if (!dir.statSync().modeString().contains('w')) {
        if (kDebugMode) {
          print('目录不可写: $directoryPath');
        }
        return {'success': false, 'message': '目录不可写: $directoryPath'};
      }
      
      // 尝试创建测试文件
      final testFile = File('${dir.path}/_test_write_access.tmp');
      await testFile.writeAsString('test', flush: true);
      
      // 检查文件是否创建成功
      if (!await testFile.exists()) {
        if (kDebugMode) {
          print('无法在目录中创建文件: $directoryPath');
        }
        return {'success': false, 'message': '无法在目录中创建文件: $directoryPath'};
      }
      
      // 删除测试文件
      await testFile.delete();
      
      // 粗略检查可用空间 (至少需要100MB可用空间)
      // 注意：stat.size 返回的是目录本身的大小，不是可用空间
      // 这里使用一个简单的检查方法
      const minSpaceRequired = 100 * 1024 * 1024; // 100 MB
      
      // 尝试创建一个较大的测试文件来检查空间
      final spaceTestFile = File('${dir.path}/_space_test.tmp');
      try {
        final randomBytes = List<int>.generate(minSpaceRequired, (i) => i % 256);
        await spaceTestFile.writeAsBytes(randomBytes, flush: true);
        await spaceTestFile.delete();
      } catch (e) {
        if (kDebugMode) {
          print('目录空间不足: $directoryPath');
        }
        return {'success': false, 'message': '目录空间不足: $directoryPath'};
      }
      
      if (kDebugMode) {
        print('目录检查通过: $directoryPath');
      }
      return {'success': true, 'message': '目录检查通过'};
    } catch (e) {
      if (kDebugMode) {
        print('目录检查失败: $directoryPath, 错误: $e');
      }
      return {'success': false, 'message': '目录检查失败: $directoryPath\n错误: $e'};
    }
  }

  /// 显示目录检查错误提示（仅开发态使用）
  void showDirectoryCheckError({
    required BuildContext context,
    required String message,
  }) {
    if (kDebugMode) {
      // 仅在开发模式下显示错误提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }
}