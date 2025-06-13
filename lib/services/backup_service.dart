// lib/services/backup_service.dart
// 备份服务 - 处理应用数据备份和恢复

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import '../core/service_locator.dart';
import 'database_service.dart';
import 'package:archive/archive_io.dart';

class BackupService {
  static final BackupService _instance = BackupService._internal();
  factory BackupService() => _instance;
  BackupService._internal();

  bool _isInitialized = false;
  Directory? _backupDirectory;
  final List<BackupRecord> _backupHistory = [];
  
  // 备份配置
  static const int _maxBackupHistory = 50;
  static const Duration _autoBackupInterval = Duration(hours: 24);
  Timer? _autoBackupTimer;
  
  bool get isInitialized => _isInitialized;
  List<BackupRecord> get backupHistory => List.unmodifiable(_backupHistory);
  
  /// 初始化备份服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 获取备份目录
      final appDir = await getApplicationDocumentsDirectory();
      _backupDirectory = Directory('${appDir.path}/backups');
      
      // 确保备份目录存在
      if (!await _backupDirectory!.exists()) {
        await _backupDirectory!.create(recursive: true);
      }
      
      // 加载备份历史
      await _loadBackupHistory();
      
      // 启动自动备份
      _startAutoBackup();
      
      _isInitialized = true;
      
      if (kDebugMode) {
        print('BackupService: 初始化完成');
        print('备份目录: ${_backupDirectory!.path}');
        print('备份历史: ${_backupHistory.length} 条记录');
      }
    } catch (e) {
      if (kDebugMode) {
        print('BackupService 初始化失败: $e');
      }
      rethrow;
    }
  }

  /// 启动自动备份
  void _startAutoBackup() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer.periodic(_autoBackupInterval, (timer) {
      _performAutoBackup();
    });
  }

  /// 执行自动备份
  Future<void> _performAutoBackup() async {
    try {
      // 这里需要实现自动备份逻辑
    } catch (e) {
      // 可集成到远程错误报告系统
    }
  }

  /// 收集备份数据
  Future<Map<String, dynamic>> _collectBackupData(List<String>? includePaths) async {
    final backupData = <String, dynamic>{};
    
    try {
      // 获取应用目录
      final appDir = await getApplicationDocumentsDirectory();
      
      // 默认备份路径
      final defaultPaths = [
        '${appDir.path}/databases',
        '${appDir.path}/documents',
        '${appDir.path}/media',
      ];
      
      final pathsToBackup = includePaths ?? defaultPaths;
      
      for (final path in pathsToBackup) {
        final directory = Directory(path);
        if (await directory.exists()) {
          final pathName = path.split('/').last;
          backupData[pathName] = await _backupDirectoryContents(directory);
        }
      }
      
      // 备份SharedPreferences（如果可能）
      backupData['preferences'] = await _backupPreferences();
      
    } catch (e) {
      if (kDebugMode) {
        print('收集备份数据失败: $e');
      }
    }
    
    return backupData;
  }

  /// 备份目录内容
  Future<Map<String, dynamic>> _backupDirectoryContents(Directory directory) async {
    final directoryData = <String, dynamic>{};
    
    try {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          final relativePath = entity.path.replaceFirst('${directory.path}/', '');
          
          // 检查文件大小，避免备份过大的文件
          final fileSize = await entity.length();
          if (fileSize > 10 * 1024 * 1024) { // 10MB限制
            directoryData[relativePath] = {
              'type': 'large_file',
              'size': fileSize,
              'note': '文件过大，未包含在备份中',
            };
            continue;
          }
          
          try {
            // 尝试读取为文本
            final content = await entity.readAsString();
            directoryData[relativePath] = {
              'type': 'text',
              'content': content,
              'size': fileSize,
            };
          } catch (e) {
            // 如果不是文本文件，读取为字节
            final bytes = await entity.readAsBytes();
            directoryData[relativePath] = {
              'type': 'binary',
              'content': base64Encode(bytes),
              'size': fileSize,
            };
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('备份目录失败: ${directory.path}, $e');
      }
    }
    
    return directoryData;
  }

  /// 备份SharedPreferences
  Future<Map<String, dynamic>> _backupPreferences() async {
    try {
      // 这里需要根据实际的SharedPreferences实现来备份
      // 由于无法直接访问所有键值，这里返回空映射
      return <String, dynamic>{};
    } catch (e) {
      return <String, dynamic>{};
    }
  }

  /// 恢复备份
  Future<bool> restoreBackup(String backupId) async {
    if (!_isInitialized || _backupDirectory == null) {
      throw Exception('BackupService 未初始化');
    }

    try {
      // 查找备份记录
      final backupRecord = _backupHistory.firstWhere(
        (record) => record.id == backupId,
        orElse: () => throw Exception('备份记录不存在: $backupId'),
      );
      // 检查备份文件是否存在
      final backupFile = File(backupRecord.filePath);
      if (!await backupFile.exists()) {
        throw Exception('备份文件不存在: ${backupRecord.filePath}');
      }
      // 验证文件完整性
      final currentHash = await _calculateFileHash(backupFile);
      if (currentHash != backupRecord.fileHash) {
        throw Exception('备份文件已损坏');
      }
      // 读取并解压备份文件
      final compressedData = await backupFile.readAsBytes();
      final jsonString = utf8.decode(gzip.decode(compressedData));
      final backupContent = jsonDecode(jsonString) as Map<String, dynamic>;
      // 恢复前清空所有表和目录
      await getService<DatabaseService>().clearAllData();
      final appDir = await getApplicationDocumentsDirectory();
      final List<String> dirsToClear = ['documents', 'media'];
      for (final dirName in dirsToClear) {
        final dir = Directory('${appDir.path}/$dirName');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          await dir.create(recursive: true);
        }
      }
      // 恢复数据
      final data = backupContent['data'] as Map<String, dynamic>;
      await _restoreData(data);
      if (kDebugMode) {
        print('备份恢复成功: ${backupRecord.name}');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('恢复备份失败: $e');
      }
      return false;
    }
  }

  /// 恢复数据
  Future<void> _restoreData(Map<String, dynamic> data) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      for (final entry in data.entries) {
        final pathName = entry.key;
        final pathData = entry.value as Map<String, dynamic>;
        if (pathName == 'preferences') {
          await _restorePreferences(pathData);
        } else {
          final targetDir = Directory('${appDir.path}/$pathName');
          await _restoreDirectory(targetDir, pathData);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('恢复数据失败: $e');
      }
      rethrow;
    }
  }

  /// 恢复目录
  Future<void> _restoreDirectory(Directory targetDir, Map<String, dynamic> directoryData) async {
    try {
      // 确保目标目录存在
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      
      for (final entry in directoryData.entries) {
        final relativePath = entry.key;
        final fileData = entry.value as Map<String, dynamic>;
        
        if (fileData['type'] == 'large_file') {
          // 跳过大文件
          continue;
        }
        
        final targetFile = File('${targetDir.path}/$relativePath');
        
        // 确保父目录存在
        await targetFile.parent.create(recursive: true);
        
        if (fileData['type'] == 'text') {
          await targetFile.writeAsString(fileData['content']);
        } else if (fileData['type'] == 'binary') {
          final bytes = base64Decode(fileData['content']);
          await targetFile.writeAsBytes(bytes);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('恢复目录失败: ${targetDir.path}, $e');
      }
      rethrow;
    }
  }

  /// 恢复SharedPreferences
  Future<void> _restorePreferences(Map<String, dynamic> preferencesData) async {
    try {
      // 这里需要根据实际的SharedPreferences实现来恢复
      // 目前为空实现
    } catch (e) {
      if (kDebugMode) {
        print('恢复SharedPreferences失败: $e');
      }
    }
  }

  /// 删除备份
  Future<bool> deleteBackup(String backupId) async {
    try {
      final backupIndex = _backupHistory.indexWhere((record) => record.id == backupId);
      if (backupIndex == -1) {
        return false;
      }
      
      final backupRecord = _backupHistory[backupIndex];
      
      // 删除备份文件
      await _deleteBackupFile(backupRecord.filePath);
      
      // 从历史记录中移除
      _backupHistory.removeAt(backupIndex);
      
      // 保存备份历史
      await _saveBackupHistory();
      
      if (kDebugMode) {
        print('备份删除成功: ${backupRecord.name}');
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('删除备份失败: $e');
      }
      return false;
    }
  }

  /// 获取备份详情
  BackupRecord? getBackupById(String backupId) {
    try {
      return _backupHistory.firstWhere((record) => record.id == backupId);
    } catch (e) {
      return null;
    }
  }

  /// 获取备份统计
  Map<String, dynamic> getBackupStatistics() {
    if (_backupHistory.isEmpty) {
      return {
        'total_backups': 0,
        'total_size': 0,
        'auto_backups': 0,
        'manual_backups': 0,
        'oldest_backup': null,
        'newest_backup': null,
      };
    }
    
    final totalSize = _backupHistory.fold<int>(0, (sum, record) => sum + record.fileSize);
    final autoBackups = _backupHistory.where((record) => record.isAutoBackup).length;
    final manualBackups = _backupHistory.length - autoBackups;
    
    _backupHistory.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    return {
      'total_backups': _backupHistory.length,
      'total_size': totalSize,
      'auto_backups': autoBackups,
      'manual_backups': manualBackups,
      'oldest_backup': _backupHistory.first.timestamp.toIso8601String(),
      'newest_backup': _backupHistory.last.timestamp.toIso8601String(),
      'average_size': totalSize / _backupHistory.length,
    };
  }

  /// 清理旧备份
  Future<void> cleanupOldBackups({Duration? olderThan, int? keepCount}) async {
    try {
      List<BackupRecord> backupsToDelete = [];
      
      if (olderThan != null) {
        final cutoffTime = DateTime.now().subtract(olderThan);
        backupsToDelete.addAll(
          _backupHistory.where((record) => record.timestamp.isBefore(cutoffTime)),
        );
      }
      
      if (keepCount != null && _backupHistory.length > keepCount) {
        _backupHistory.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        backupsToDelete.addAll(_backupHistory.skip(keepCount));
      }
      
      // 去重
      backupsToDelete = backupsToDelete.toSet().toList();
      
      for (final backup in backupsToDelete) {
        await deleteBackup(backup.id);
      }
      
      if (kDebugMode && backupsToDelete.isNotEmpty) {
        print('清理旧备份: ${backupsToDelete.length} 个');
      }
    } catch (e) {
      if (kDebugMode) {
        print('清理旧备份失败: $e');
      }
    }
  }

  /// 生成备份ID
  String _generateBackupId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = (timestamp % 10000).toString().padLeft(4, '0');
    return 'BACKUP_${timestamp}_$random';
  }

  /// 计算文件哈希
  Future<String> _calculateFileHash(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final digest = sha256.convert(bytes);
      return digest.toString();
    } catch (e) {
      return '';
    }
  }

  /// 获取应用版本
  Future<String> _getAppVersion() async {
    try {
      // 这里应该从package_info获取版本信息
      return '1.0.0';
    } catch (e) {
      return 'unknown';
    }
  }

  /// 删除备份文件
  Future<void> _deleteBackupFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      if (kDebugMode) {
        print('删除备份文件失败: $filePath, $e');
      }
    }
  }

  /// 加载备份历史
  Future<void> _loadBackupHistory() async {
    try {
      final historyFile = File('${_backupDirectory!.path}/backup_history.json');
      if (await historyFile.exists()) {
        final jsonString = await historyFile.readAsString();
        final historyData = jsonDecode(jsonString) as List<dynamic>;
        
        _backupHistory.clear();
        for (final item in historyData) {
          _backupHistory.add(BackupRecord.fromMap(item as Map<String, dynamic>));
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('加载备份历史失败: $e');
      }
    }
  }

  /// 保存备份历史
  Future<void> _saveBackupHistory() async {
    try {
      final historyFile = File('${_backupDirectory!.path}/backup_history.json');
      final historyData = _backupHistory.map((record) => record.toMap()).toList();
      final jsonString = jsonEncode(historyData);
      await historyFile.writeAsString(jsonString);
    } catch (e) {
      if (kDebugMode) {
        print('保存备份历史失败: $e');
      }
    }
  }

  /// 停止自动备份
  void stopAutoBackup() {
    _autoBackupTimer?.cancel();
    if (kDebugMode) {
      print('自动备份已停止');
    }
  }

  /// 启动自动备份
  void startAutoBackup() {
    if (_isInitialized) {
      _startAutoBackup();
      if (kDebugMode) {
        print('自动备份已启动');
      }
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    _autoBackupTimer?.cancel();
    _backupHistory.clear();
    _isInitialized = false;
    
    if (kDebugMode) {
      print('BackupService: 资源已释放');
    }
  }
}

/// 备份记录数据类
class BackupRecord {
  final String id;
  final String name;
  final String? description;
  final DateTime timestamp;
  final String filePath;
  final int fileSize;
  final String fileHash;
  final bool isAutoBackup;
  final DateTime createdAt;

  const BackupRecord({
    required this.id,
    required this.name,
    this.description,
    required this.timestamp,
    required this.filePath,
    required this.fileSize,
    required this.fileHash,
    required this.isAutoBackup,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'timestamp': timestamp.toIso8601String(),
      'file_path': filePath,
      'file_size': fileSize,
      'file_hash': fileHash,
      'is_auto_backup': isAutoBackup,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory BackupRecord.fromMap(Map<String, dynamic> map) {
    return BackupRecord(
      id: map['id'],
      name: map['name'],
      description: map['description'],
      timestamp: DateTime.parse(map['timestamp']),
      filePath: map['file_path'],
      fileSize: map['file_size'],
      fileHash: map['file_hash'],
      isAutoBackup: map['is_auto_backup'] ?? false,
      createdAt: DateTime.parse(map['created_at']),
    );
  }

  @override
  String toString() {
    return 'BackupRecord(id: $id, name: $name, size: ${(fileSize / 1024).toStringAsFixed(2)} KB, '
           'timestamp: ${timestamp.toIso8601String()})';
  }
}