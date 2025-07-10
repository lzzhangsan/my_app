// test_cache_cleanup.dart
// 测试智能清理功能的脚本

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'lib/services/cache_service.dart';

void main() async {
  print('开始测试智能清理功能...');
  
  try {
    // 初始化CacheService
    final cacheService = CacheService();
    await cacheService.initialize();
    
    // 获取缓存信息
    print('\n=== 清理前缓存信息 ===');
    final cacheInfo = await cacheService.getCacheInfo();
    if (cacheInfo.containsKey('error')) {
      print('获取缓存信息失败: ${cacheInfo['error']}');
      return;
    }
    
    print('总文件数: ${cacheInfo['totalFiles']}');
    print('总大小: ${cacheInfo['totalSizeMB']} MB');
    print('大文件数(>10MB): ${cacheInfo['largeFiles']}');
    print('大文件总大小: ${cacheInfo['largeFilesSizeMB']} MB');
    
    if (cacheInfo['largeFileList'] != null) {
      print('\n大文件列表:');
      for (final file in cacheInfo['largeFileList']) {
        print('  - $file');
      }
    }
    
    // 执行智能清理
    print('\n=== 开始智能清理 ===');
    final result = await cacheService.cleanLargeCacheFiles(maxSizeMB: 10);
    
    if (result['success'] == true) {
      print('清理成功!');
      print('删除文件数: ${result['deletedCount']}');
      print('释放空间: ${result['freedSizeMB']} MB');
      
      if (result['deletedFiles'] != null) {
        print('\n删除的文件:');
        for (final file in result['deletedFiles']) {
          print('  - $file');
        }
      }
      
      if (result['protectedFiles'] != null && result['protectedFiles'].isNotEmpty) {
        print('\n保护的文件:');
        for (final file in result['protectedFiles']) {
          print('  - $file');
        }
      }
    } else {
      print('清理失败: ${result['error']}');
    }
    
    // 清理后再次获取缓存信息
    print('\n=== 清理后缓存信息 ===');
    final afterCacheInfo = await cacheService.getCacheInfo();
    if (!afterCacheInfo.containsKey('error')) {
      print('总文件数: ${afterCacheInfo['totalFiles']}');
      print('总大小: ${afterCacheInfo['totalSizeMB']} MB');
      print('大文件数(>10MB): ${afterCacheInfo['largeFiles']}');
      print('大文件总大小: ${afterCacheInfo['largeFilesSizeMB']} MB');
    }
    
  } catch (e) {
    print('测试过程中出错: $e');
  }
  
  print('\n测试完成!');
} 