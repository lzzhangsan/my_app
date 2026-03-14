// lib/storage_management_page.dart
// 存储管理页面 - 显示存储使用情况和提供清理功能

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../core/service_locator.dart';
import '../services/file_cleanup_service.dart';
import '../services/database_service.dart';
import 'dart:io' show Directory, File, Platform;
import 'package:photo_manager/photo_manager.dart';

class StorageManagementPage extends StatefulWidget {
  const StorageManagementPage({Key? key}) : super(key: key);

  @override
  _StorageManagementPageState createState() => _StorageManagementPageState();
}

class _StorageManagementPageState extends State<StorageManagementPage> {
  bool _isLoading = true;
  int _totalStorageUsage = 0;
  int _documentsSize = 0;
  int _imagesSize = 0;
  int _audiosSize = 0;
  int _mediaSize = 0;
  int _diaryMediaSize = 0;
  int _backgroundImagesSize = 0;
  int _backgroundsSize = 0;
  int _diaryBackgroundsSize = 0;
  int _backupsSize = 0;
  int _videosSize = 0;
  int _cacheSize = 0;
  int _tempSize = 0;
  int _databaseSize = 0;
  /// 应用专属外部存储（Android 计入系统「数据」，含导出文件、browser_backups 等）
  int _externalStorageSize = 0;
  /// 应用文档目录下其他未分类的子项（目录名 -> 字节数），用于定位不明占用
  final Map<String, int> _otherAppPaths = {};
  
  final FileCleanupService _fileCleanupService = getService<FileCleanupService>();
  final DatabaseService _databaseService = getService<DatabaseService>();

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
      
      final appPath = (await getApplicationDocumentsDirectory()).path;
      
      final documentsDir = Directory('$appPath/documents');
      if (await documentsDir.exists()) {
        _documentsSize = await _getDirectorySize(documentsDir.path);
      }
      
      final imagesDir = Directory('$appPath/images');
      if (await imagesDir.exists()) {
        _imagesSize = await _getDirectorySize(imagesDir.path);
      }
      
      final audiosDir = Directory('$appPath/audios');
      if (await audiosDir.exists()) {
        _audiosSize = await _getDirectorySize(audiosDir.path);
      }
      
      final mediaDir = Directory('$appPath/media');
      if (await mediaDir.exists()) {
        _mediaSize = await _getDirectorySize(mediaDir.path);
      }
      
      final diaryMediaDir = Directory('$appPath/diary_media');
      if (await diaryMediaDir.exists()) {
        _diaryMediaSize = await _getDirectorySize(diaryMediaDir.path);
      }
      
      final backgroundImagesDir = Directory('$appPath/background_images');
      if (await backgroundImagesDir.exists()) {
        _backgroundImagesSize = await _getDirectorySize(backgroundImagesDir.path);
      }
      
      final backgroundsDir = Directory('$appPath/backgrounds');
      if (await backgroundsDir.exists()) {
        _backgroundsSize = await _getDirectorySize(backgroundsDir.path);
      }
      
      final diaryBackgroundsDir = Directory('$appPath/diary_backgrounds');
      if (await diaryBackgroundsDir.exists()) {
        _diaryBackgroundsSize = await _getDirectorySize(diaryBackgroundsDir.path);
      }
      
      final backupsDir = Directory('$appPath/backups');
      if (await backupsDir.exists()) {
        _backupsSize = await _getDirectorySize(backupsDir.path);
      }
      
      final videosDir = Directory('$appPath/videos');
      if (await videosDir.exists()) {
        _videosSize = await _getDirectorySize(videosDir.path);
      }
      
      // 动态扫描应用文档根目录下所有子项，定位未列出的占用（如插件缓存等）
      _otherAppPaths.clear();
      final appDir = Directory(appPath);
      if (await appDir.exists()) {
        await for (final entity in appDir.list()) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.') || name == 'change_app.db' || name == 'change_app.db-journal' || name == 'change_app.db-wal') continue;
          final known = {
            'documents', 'images', 'audios', 'media', 'diary_media',
            'background_images', 'backgrounds', 'diary_backgrounds', 'backups', 'videos',
          };
          if (known.contains(name)) continue;
          int size = 0;
          if (entity is File) {
            size = await entity.length();
          } else if (entity is Directory) {
            size = await _getDirectorySize(entity.path);
          }
          if (size > 0) _otherAppPaths[name] = size;
        }
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
      
      // 应用专属外部存储（与系统「数据」一致，含导出 ZIP、browser_backups 等）
      _externalStorageSize = await _fileCleanupService.getExternalStorageUsage();
      
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
      try { await PhotoManager.clearFileCache(); } catch (_) {}
      await _fileCleanupService.cleanAllCacheFiles();
      await _loadStorageInfo();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理缓存文件失败: $e')),
        );
      }
    }
  }

  /// 执行完整清理（临时+缓存+孤立文件）
  Future<void> _performFullCleanup() async {
    try {
      try { await PhotoManager.clearFileCache(); } catch (_) {}
      await _fileCleanupService.performFullStorageCleanup();
      final validPaths = await _databaseService.getAllValidFilePaths();
      await _fileCleanupService.cleanOrphanedFiles(validPaths);
      await _loadStorageInfo();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('完整存储清理失败: $e')),
        );
      }
    }
  }

  /// 清理备份文件（需确认，删除后无法恢复）
  Future<void> _cleanBackupFiles() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清理备份'),
        content: Text(
          '备份文件包含目录导出、数据库备份等，用于数据恢复。\n\n'
          '删除后将无法恢复，确定要清理约 ${_formatFileSize(_backupsSize)} 的备份文件吗？',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确定清理'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final result = await _fileCleanupService.cleanBackupFiles();
      await _loadStorageInfo();
      if (mounted) {
        final count = result['count'] ?? 0;
        final bytes = result['bytes'] ?? 0;
        final sizeStr = _formatFileSize(bytes);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(count > 0 ? '已清理 $count 项备份，释放 $sizeStr' : '备份目录为空'),
            backgroundColor: count > 0 ? Colors.green : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理备份失败: $e')),
        );
      }
    }
  }

  /// 清理应用外部存储（导出 ZIP、插件缓存等）
  Future<void> _cleanExternalStorage() async {
    try {
      final result = await _fileCleanupService.cleanExternalStorage();
      await _loadStorageInfo();
      if (mounted) {
        final count = result['count'] ?? 0;
        final bytes = result['bytes'] ?? 0;
        final sizeStr = _formatFileSize(bytes);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(count > 0 ? '已清理 $count 项外部存储，释放 $sizeStr' : '外部存储无可清理项'),
            backgroundColor: count > 0 ? Colors.green : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理外部存储失败: $e')),
        );
      }
    }
  }

  /// 清理孤立文件
  Future<void> _cleanOrphanedFiles() async {
    try {
      final validPaths = await _databaseService.getAllValidFilePaths();
      final result = await _fileCleanupService.cleanOrphanedFiles(validPaths);
      await _loadStorageInfo();

      if (mounted) {
        final count = result['count'] ?? 0;
        final bytes = result['bytes'] ?? 0;
        final sizeStr = bytes < 1024 ? '${bytes}B' : bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(1)}KB' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(count > 0 ? '已清理 $count 个孤立文件，释放 $sizeStr 空间' : '未发现孤立文件'),
            backgroundColor: count > 0 ? Colors.green : null,
          ),
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
            _buildStorageItem('图片文件(目录)', _imagesSize, Icons.image),
            _buildStorageItem('音频文件(目录)', _audiosSize, Icons.audiotrack),
            _buildStorageItem('媒体文件', _mediaSize, Icons.photo_library),
            _buildStorageItem('日记媒体', _diaryMediaSize, Icons.photo),
            _buildStorageItem('背景图片', _backgroundImagesSize, Icons.wallpaper),
            _buildStorageItem('文档背景', _backgroundsSize, Icons.image),
            _buildStorageItem('日记背景', _diaryBackgroundsSize, Icons.photo_library),
            _buildStorageItem('备份文件', _backupsSize, Icons.backup),
            _buildStorageItem('视频文件', _videosSize, Icons.videocam),
            ..._otherAppPaths.entries.map((e) => _buildStorageItem(
                  '其他(${e.key})', e.value, Icons.folder)),
            _buildStorageItem('缓存文件', _cacheSize, Icons.cached),
            _buildStorageItem('临时文件', _tempSize, Icons.folder_open),
            _buildStorageItem('数据库文件', _databaseSize, Icons.storage),
            _buildStorageItem('应用外部存储', _externalStorageSize, Icons.sd_storage),
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
            if (_externalStorageSize > 0)
              _buildCleanupButton(
                '清理外部存储',
                '删除导出 ZIP、插件缓存等，释放约 ${_formatFileSize(_externalStorageSize)}',
                Icons.sd_storage,
                _cleanExternalStorage,
              ),
            if (_backupsSize > 0)
              _buildCleanupButton(
                '清理备份文件',
                '删除目录导出、数据库备份等（约 ${_formatFileSize(_backupsSize)}），删除后无法恢复',
                Icons.backup,
                _cleanBackupFiles,
              ),
            _buildCleanupButton(
              '完整清理',
              '执行所有清理操作（含外部存储）',
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
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
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
          style: ElevatedButton.styleFrom(
            backgroundColor: isPrimary ? Colors.blue : Colors.grey[200],
            foregroundColor: isPrimary ? Colors.white : Colors.black87,
            padding: const EdgeInsets.all(16),
            alignment: Alignment.centerLeft,
          ),
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
              '「应用外部存储」含导出 ZIP、插件缓存等；「备份文件」为目录/数据库导出备份',
              Icons.info_outline,
            ),
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
