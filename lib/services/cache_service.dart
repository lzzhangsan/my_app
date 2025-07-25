// lib/services/cache_service.dart
// 缓存服务 - 处理应用数据缓存

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  bool _isInitialized = false;
  SharedPreferences? _prefs;
  Directory? _cacheDirectory;
  final Map<String, dynamic> _memoryCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  
  // 缓存配置
  static const int _maxMemoryCacheSize = 100;
  static const Duration _defaultCacheExpiry = Duration(hours: 24);
  
  bool get isInitialized => _isInitialized;
  int get memoryCacheSize => _memoryCache.length;

  /// 初始化缓存服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 初始化SharedPreferences
      _prefs = await SharedPreferences.getInstance();
      
      // 获取缓存目录
      _cacheDirectory = await getApplicationCacheDirectory();
      
      // 确保缓存目录存在
      if (!await _cacheDirectory!.exists()) {
        await _cacheDirectory!.create(recursive: true);
      }
      
      // 清理过期缓存
      await _cleanExpiredCache();
      
      _isInitialized = true;
      
      if (kDebugMode) {
        debugPrint('CacheService: 初始化完成，缓存目录: ${_cacheDirectory!.path}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CacheService 初始化失败: $e');
      }
      rethrow;
    }
  }

  /// 设置字符串缓存
  Future<bool> setString(String key, String value, {Duration? expiry}) async {
    if (!_isInitialized || _prefs == null) {
      throw Exception('CacheService 未初始化');
    }

    try {
      // 保存到SharedPreferences
      await _prefs!.setString(key, value);
      
      // 保存到内存缓存
      _setMemoryCache(key, value, expiry);
      
      // 保存过期时间
      if (expiry != null) {
        final expiryTime = DateTime.now().add(expiry);
        await _prefs!.setString('${key}_expiry', expiryTime.toIso8601String());
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('设置字符串缓存失败: $e');
      }
      return false;
    }
  }

  /// 获取字符串缓存
  Future<String?> getString(String key) async {
    if (!_isInitialized || _prefs == null) {
      return null;
    }

    try {
      // 检查是否过期
      if (await _isCacheExpired(key)) {
        await remove(key);
        return null;
      }
      
      // 先从内存缓存获取
      if (_memoryCache.containsKey(key)) {
        return _memoryCache[key] as String?;
      }
      
      // 从SharedPreferences获取
      final value = _prefs!.getString(key);
      if (value != null) {
        _setMemoryCache(key, value);
      }
      
      return value;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取字符串缓存失败: $e');
      }
      return null;
    }
  }

  /// 设置整数缓存
  Future<bool> setInt(String key, int value, {Duration? expiry}) async {
    if (!_isInitialized || _prefs == null) {
      throw Exception('CacheService 未初始化');
    }

    try {
      await _prefs!.setInt(key, value);
      _setMemoryCache(key, value, expiry);
      
      if (expiry != null) {
        final expiryTime = DateTime.now().add(expiry);
        await _prefs!.setString('${key}_expiry', expiryTime.toIso8601String());
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('设置整数缓存失败: $e');
      }
      return false;
    }
  }

  /// 获取整数缓存
  Future<int?> getInt(String key) async {
    if (!_isInitialized || _prefs == null) {
      return null;
    }

    try {
      if (await _isCacheExpired(key)) {
        await remove(key);
        return null;
      }
      
      if (_memoryCache.containsKey(key)) {
        return _memoryCache[key] as int?;
      }
      
      final value = _prefs!.getInt(key);
      if (value != null) {
        _setMemoryCache(key, value);
      }
      
      return value;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取整数缓存失败: $e');
      }
      return null;
    }
  }

  /// 设置布尔缓存
  Future<bool> setBool(String key, bool value, {Duration? expiry}) async {
    if (!_isInitialized || _prefs == null) {
      throw Exception('CacheService 未初始化');
    }

    try {
      await _prefs!.setBool(key, value);
      _setMemoryCache(key, value, expiry);
      
      if (expiry != null) {
        final expiryTime = DateTime.now().add(expiry);
        await _prefs!.setString('${key}_expiry', expiryTime.toIso8601String());
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('设置布尔缓存失败: $e');
      }
      return false;
    }
  }

  /// 获取布尔缓存
  Future<bool?> getBool(String key) async {
    if (!_isInitialized || _prefs == null) {
      return null;
    }

    try {
      if (await _isCacheExpired(key)) {
        await remove(key);
        return null;
      }
      
      if (_memoryCache.containsKey(key)) {
        return _memoryCache[key] as bool?;
      }
      
      final value = _prefs!.getBool(key);
      if (value != null) {
        _setMemoryCache(key, value);
      }
      
      return value;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取布尔缓存失败: $e');
      }
      return null;
    }
  }

  /// 设置JSON对象缓存
  Future<bool> setJson(String key, Map<String, dynamic> value, {Duration? expiry}) async {
    try {
      final jsonString = jsonEncode(value);
      return await setString(key, jsonString, expiry: expiry);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('设置JSON缓存失败: $e');
      }
      return false;
    }
  }

  /// 获取JSON对象缓存
  Future<Map<String, dynamic>?> getJson(String key) async {
    try {
      final jsonString = await getString(key);
      if (jsonString != null) {
        return jsonDecode(jsonString) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取JSON缓存失败: $e');
      }
      return null;
    }
  }

  /// 缓存文件
  Future<bool> cacheFile(String key, File file, {Duration? expiry}) async {
    if (!_isInitialized || _cacheDirectory == null) {
      throw Exception('CacheService 未初始化');
    }

    try {
      final cacheFile = File('${_cacheDirectory!.path}/$key');
      await file.copy(cacheFile.path);
      
      // 记录缓存时间
      if (expiry != null) {
        final expiryTime = DateTime.now().add(expiry);
        await setString('${key}_file_expiry', expiryTime.toIso8601String());
      }
      
      if (kDebugMode) {
        debugPrint('文件缓存成功: $key');
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('文件缓存失败: $e');
      }
      return false;
    }
  }

  /// 获取缓存文件
  Future<File?> getCachedFile(String key) async {
    if (!_isInitialized || _cacheDirectory == null) {
      return null;
    }

    try {
      // 检查文件缓存是否过期
      final expiryString = await getString('${key}_file_expiry');
      if (expiryString != null) {
        final expiryTime = DateTime.parse(expiryString);
        if (DateTime.now().isAfter(expiryTime)) {
          await removeCachedFile(key);
          return null;
        }
      }
      
      final cacheFile = File('${_cacheDirectory!.path}/$key');
      if (await cacheFile.exists()) {
        return cacheFile;
      }
      
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取缓存文件失败: $e');
      }
      return null;
    }
  }

  /// 删除缓存文件
  Future<bool> removeCachedFile(String key) async {
    if (!_isInitialized || _cacheDirectory == null) {
      return false;
    }

    try {
      final cacheFile = File('${_cacheDirectory!.path}/$key');
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
      
      // 删除过期时间记录
      await remove('${key}_file_expiry');
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('删除缓存文件失败: $e');
      }
      return false;
    }
  }

  /// 删除缓存项
  Future<bool> remove(String key) async {
    if (!_isInitialized || _prefs == null) {
      return false;
    }

    try {
      await _prefs!.remove(key);
      await _prefs!.remove('${key}_expiry');
      _memoryCache.remove(key);
      _cacheTimestamps.remove(key);
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('删除缓存失败: $e');
      }
      return false;
    }
  }

  /// 清空所有缓存
  Future<void> clear() async {
    if (!_isInitialized || _prefs == null) {
      return;
    }

    try {
      await _prefs!.clear();
      _memoryCache.clear();
      _cacheTimestamps.clear();
      
      // 清空文件缓存
      if (_cacheDirectory != null && await _cacheDirectory!.exists()) {
        await for (final file in _cacheDirectory!.list()) {
          if (file is File) {
            await file.delete();
          }
        }
      }
      
      if (kDebugMode) {
        debugPrint('清空所有缓存完成');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('清空缓存失败: $e');
      }
    }
  }

  /// 获取缓存大小
  Future<int> getCacheSize() async {
    if (!_isInitialized || _cacheDirectory == null) {
      return 0;
    }

    try {
      int totalSize = 0;
      await for (final file in _cacheDirectory!.list(recursive: true)) {
        if (file is File) {
          final stat = await file.stat();
          totalSize += stat.size;
        }
      }
      return totalSize;
    } catch (e) {
      return 0;
    }
  }

  /// 智能清理大缓存文件
  /// 删除大于指定大小的非缩略图文件，保留必要的缓存
  Future<Map<String, dynamic>> cleanLargeCacheFiles({int maxSizeMB = 10}) async {
    if (!_isInitialized || _cacheDirectory == null) {
      return {'success': false, 'error': 'CacheService未初始化'};
    }

    try {
      int totalDeleted = 0;
      int totalSize = 0;
      final List<String> deletedFiles = [];
      final List<String> protectedFiles = [];
      
      // 需要保护的文件关键词（缩略图等）
      final List<String> protectedKeywords = [
        'thumbnail', 'thumb', '_thumb_', 'video_thumb_', 'img_thumb_',
        'waveform', 'ocr', 'cache_', 'temp_thumb'
      ];
      
      // 递归扫描cache目录
      await for (final entity in _cacheDirectory!.list(recursive: true)) {
        if (entity is File) {
          try {
            final fileSize = await entity.length();
            final fileName = entity.path.split('/').last.toLowerCase();
            final filePath = entity.path.toLowerCase();
            
            // 检查文件大小是否超过限制
            if (fileSize > maxSizeMB * 1024 * 1024) {
              // 检查是否为需要保护的文件
              bool isProtected = protectedKeywords.any((keyword) => 
                fileName.contains(keyword) || filePath.contains(keyword)
              );
              
              if (isProtected) {
                protectedFiles.add('${entity.path} (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)');
                continue;
              }
              
              // 删除大文件
              await entity.delete();
              totalDeleted++;
              totalSize += fileSize;
              deletedFiles.add('${entity.path} (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)');
              
              if (kDebugMode) {
                debugPrint('已删除大缓存文件: ${entity.path} (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)');
              }
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint('处理文件时出错: ${entity.path}, 错误: $e');
            }
          }
        }
      }
      
      if (kDebugMode) {
        debugPrint('智能清理完成: 删除 $totalDeleted 个文件，释放 ${(totalSize / 1024 / 1024).toStringAsFixed(1)}MB 空间');
        if (protectedFiles.isNotEmpty) {
          debugPrint('保护的文件: ${protectedFiles.length} 个');
        }
      }
      
      return {
        'success': true,
        'deletedCount': totalDeleted,
        'freedSizeMB': (totalSize / 1024 / 1024).toStringAsFixed(1),
        'deletedFiles': deletedFiles,
        'protectedFiles': protectedFiles,
      };
    } catch (e) {
      if (kDebugMode) {
        debugPrint('智能清理缓存失败: $e');
      }
      return {'success': false, 'error': e.toString()};
    }
  }

  /// 获取缓存目录详细信息
  Future<Map<String, dynamic>> getCacheInfo() async {
    if (!_isInitialized || _cacheDirectory == null) {
      return {'error': 'CacheService未初始化'};
    }

    try {
      int totalFiles = 0;
      int totalSize = 0;
      int largeFiles = 0;
      int largeFilesSize = 0;
      final List<String> largeFileList = [];
      
      await for (final entity in _cacheDirectory!.list(recursive: true)) {
        if (entity is File) {
          totalFiles++;
          final fileSize = await entity.length();
          totalSize += fileSize;
          
          // 统计大于10MB的文件
          if (fileSize > 10 * 1024 * 1024) {
            largeFiles++;
            largeFilesSize += fileSize;
            largeFileList.add('${entity.path} (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)');
          }
        }
      }
      
      return {
        'totalFiles': totalFiles,
        'totalSizeMB': (totalSize / 1024 / 1024).toStringAsFixed(1),
        'largeFiles': largeFiles,
        'largeFilesSizeMB': (largeFilesSize / 1024 / 1024).toStringAsFixed(1),
        'largeFileList': largeFileList,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// 设置内存缓存
  void _setMemoryCache(String key, dynamic value, [Duration? expiry]) {
    // 如果内存缓存已满，删除最旧的项
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      final oldestKey = _cacheTimestamps.entries
          .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
          .key;
      _memoryCache.remove(oldestKey);
      _cacheTimestamps.remove(oldestKey);
    }
    
    _memoryCache[key] = value;
    _cacheTimestamps[key] = DateTime.now();
  }

  /// 检查缓存是否过期
  Future<bool> _isCacheExpired(String key) async {
    if (_prefs == null) return false;
    
    try {
      final expiryString = _prefs!.getString('${key}_expiry');
      if (expiryString != null) {
        final expiryTime = DateTime.parse(expiryString);
        return DateTime.now().isAfter(expiryTime);
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 清理过期缓存
  Future<void> _cleanExpiredCache() async {
    if (_prefs == null) return;
    
    try {
      final keys = _prefs!.getKeys();
      final expiredKeys = <String>[];
      
      for (final key in keys) {
        if (key.endsWith('_expiry')) {
          final originalKey = key.replaceAll('_expiry', '');
          if (await _isCacheExpired(originalKey)) {
            expiredKeys.add(originalKey);
          }
        }
      }
      
      for (final key in expiredKeys) {
        await remove(key);
      }
      
      if (kDebugMode && expiredKeys.isNotEmpty) {
        debugPrint('清理过期缓存: ${expiredKeys.length} 项');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('清理过期缓存失败: $e');
      }
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    _memoryCache.clear();
    _cacheTimestamps.clear();
    _isInitialized = false;
    
    if (kDebugMode) {
      debugPrint('CacheService: 资源已释放');
    }
  }
}