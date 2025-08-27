// lib/storage_management_page.dart
// 存储管理页面 - 显示存储使用情况和提供清理功能

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../core/service_locator.dart';
import '../services/file_cleanup_service.dart';
import '../services/database_service.dart';
import '../services/media_service.dart';
import 'dart:io';

class StorageManagementPage extends StatefulWidget {
  const StorageManagementPage({Key? key}) : super(key: key);

  @override
  _StorageManagementPageState createState() => _StorageManagementPageState();
}

class _StorageManagementPageState extends State<StorageManagementPage> {
  bool _isLoading = true;
  int _totalStorageUsage = 0;
  int _documentsSize = 0;
  int _mediaSize = 0;
  int _cacheSize = 0;
  int _tempSize = 0;
  int _databaseSize = 0;
  
  final FileCleanupService _fileCleanupService = getService<FileCleanupService>();
  final DatabaseService _databaseService = getService<DatabaseService>();
  final MediaService _mediaService = getService<MediaService>();

  @override
  void initState() {
    super.initState();
    _loadStorageInfo();
  }

  /// 加载存储信息
  Future<void> _loadStorageInfo() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // 获取各种存储大小
      _totalStorageUsage = await _fileCleanupService.getAppTotalStorageUsage();
      
      // 获取文档目录大小
      final documentsDir = Directory('${(await getApplicationDocumentsDirectory()).path}/documents');
      if (await documentsDir.exists()) {
        _documentsSize = await _getDirectorySize(documentsDir.path);
      }
      
      // 获取媒体目录大小
      final mediaDir = Directory('${(await getApplicationDocumentsDirectory()).path}/media');
      if (await mediaDir.exists()) {
        _mediaSize = await _getDirectorySize(mediaDir.path);
      }
      
      // 获取缓存目录大小
      final cacheDir = await getApplicationCacheDirectory();
      if (await cacheDir.exists()) {
        _cacheSize = await _getDirectorySize(cacheDir.path);
      }
      
      // 获取临时目录大小
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        _tempSize = await _getDirectorySize(tempDir.path);
      }
      
      // 获取数据库大小
      final dbPath = '${(await getApplicationDocumentsDirectory()).path}/change_app.db';
      final dbFile = File(dbPath);
      if (await dbFile.exists()) {
        _databaseSize = await dbFile.length();
      }
      
    } catch (e) {
      if (kDebugMode) {
        print('加载存储信息失败: $e');
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
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

  /// 清理临时文件
  Future<void> _cleanTempFiles() async {
    try {
      await _fileCleanupService.cleanAllTempFiles();
      await _loadStorageInfo();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('临时文件清理完成')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理临时文件失败: $e')),
        );
      }
    }
  }

  /// 清理缓存文件
  Future<void> _cleanCacheFiles() async {
    try {
      await _fileCleanupService.cleanAllCacheFiles();
      await _loadStorageInfo();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('缓存文件清理完成')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理缓存文件失败: $e')),
        );
      }
    }
  }

  /// 执行完整清理
  Future<void> _performFullCleanup() async {
    try {
      await _fileCleanupService.performFullStorageCleanup();
      await _loadStorageInfo();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('完整存储清理完成')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('完整存储清理失败: $e')),
        );
      }
    }
  }

  /// 清理孤立文件
  Future<void> _cleanOrphanedFiles() async {
    try {
      // 获取数据库中有效的文件路径
      final validPaths = <String>[];
      
      // 从媒体服务获取有效路径
      for (final mediaItem in _mediaService.mediaItems) {
        validPaths.add(mediaItem.path);
      }
      
      // 清理孤立文件
      await _fileCleanupService.cleanOrphanedFiles(validPaths);
      await _loadStorageInfo();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('孤立文件清理完成')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理孤立文件失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('存储管理'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadStorageInfo,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 总存储使用量
                  _buildStorageCard(
                    title: '总存储使用量',
                    size: _totalStorageUsage,
                    color: Colors.blue,
                    icon: Icons.storage,
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // 详细存储信息
                  _buildDetailedStorageInfo(),
                  
                  const SizedBox(height: 24),
                  
                  // 清理操作
                  _buildCleanupActions(),
                  
                  const SizedBox(height: 24),
                  
                  // 存储建议
                  _buildStorageTips(),
                ],
              ),
            ),
    );
  }

  /// 构建存储卡片
  Widget _buildStorageCard({
    required String title,
    required int size,
    required Color color,
    required IconData icon,
  }) {
    return Card(
      elevation: 4,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withOpacity(0.1), color.withOpacity(0.05)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _formatFileSize(size),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建详细存储信息
  Widget _buildDetailedStorageInfo() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '详细存储信息',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildStorageItem('文档文件', _documentsSize, Icons.description),
            _buildStorageItem('媒体文件', _mediaSize, Icons.photo_library),
            _buildStorageItem('缓存文件', _cacheSize, Icons.cached),
            _buildStorageItem('临时文件', _tempSize, Icons.folder_open),
            _buildStorageItem('数据库文件', _databaseSize, Icons.storage),
          ],
        ),
      ),
    );
  }

  /// 构建存储项
  Widget _buildStorageItem(String name, int size, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey[600]),
          const SizedBox(width: 12),
          Expanded(child: Text(name)),
          Text(
            _formatFileSize(size),
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建清理操作
  Widget _buildCleanupActions() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '清理操作',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildCleanupButton(
              '清理临时文件',
              '删除所有临时文件，释放空间',
              Icons.cleaning_services,
              _cleanTempFiles,
            ),
            _buildCleanupButton(
              '清理缓存文件',
              '删除所有缓存文件，释放空间',
              Icons.cached,
              _cleanCacheFiles,
            ),
            _buildCleanupButton(
              '清理孤立文件',
              '删除数据库中不存在的文件',
              Icons.delete_sweep,
              _cleanOrphanedFiles,
            ),
            _buildCleanupButton(
              '完整清理',
              '执行所有清理操作',
              Icons.cleaning_services,
              _performFullCleanup,
              isPrimary: true,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建清理按钮
  Widget _buildCleanupButton(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback onPressed, {
    bool isPrimary = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: isPrimary ? Colors.white70 : Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: isPrimary ? Colors.blue : Colors.grey[200],
          foregroundColor: isPrimary ? Colors.white : Colors.black87,
          padding: const EdgeInsets.all(16),
          alignment: Alignment.centerLeft,
        ),
      ),
    );
  }

  /// 构建存储建议
  Widget _buildStorageTips() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '存储优化建议',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildTipItem(
              '定期清理临时文件和缓存文件',
              Icons.lightbulb_outline,
            ),
            _buildTipItem(
              '删除不需要的媒体文件',
              Icons.photo_library,
            ),
            _buildTipItem(
              '定期备份重要数据',
              Icons.backup,
            ),
            _buildTipItem(
              '使用压缩格式存储图片和视频',
              Icons.compress,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建建议项
  Widget _buildTipItem(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.orange),
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
