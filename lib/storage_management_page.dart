// lib/storage_management_page.dart
// 存储管理页面 - 显示存储使用情况和提供清理功能

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'cover_page.dart';
import 'diary_page.dart';
import 'directory_page.dart';
import 'document_editor_page.dart';
import '../core/service_locator.dart';
import '../services/logger.dart';
import '../services/file_cleanup_service.dart';
import '../services/database_service.dart';
import 'dart:io' show Directory, File, FileMode, Platform;
import 'dart:typed_data';
import 'package:photo_manager/photo_manager.dart';

class StorageManagementPage extends StatefulWidget {
  const StorageManagementPage({Key? key}) : super(key: key);

  @override
  _StorageManagementPageState createState() => _StorageManagementPageState();
}

class _StorageManagementPageState extends State<StorageManagementPage> {
  static const int _selfCheckUiVersion = 2;
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
  int _videoThumbnailCacheSize = 0;
  int _cacheSize = 0;
  int _tempSize = 0;
  int _databaseSize = 0;

  /// 应用专属外部存储（Android 计入系统「数据」，含导出文件、browser_backups 等）
  int _externalStorageSize = 0;

  /// 应用文档目录下其他未分类的子项（目录名 -> 字节数），用于定位不明占用
  final Map<String, int> _otherAppPaths = {};

  final FileCleanupService _fileCleanupService =
      getService<FileCleanupService>();
  final DatabaseService _databaseService = getService<DatabaseService>();

  bool _selfCheckRunning = false;
  Map<String, dynamic>? _selfCheckResult;

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
        _backgroundImagesSize = await _getDirectorySize(
          backgroundImagesDir.path,
        );
      }

      final backgroundsDir = Directory('$appPath/backgrounds');
      if (await backgroundsDir.exists()) {
        _backgroundsSize = await _getDirectorySize(backgroundsDir.path);
      }

      final diaryBackgroundsDir = Directory('$appPath/diary_backgrounds');
      if (await diaryBackgroundsDir.exists()) {
        _diaryBackgroundsSize = await _getDirectorySize(
          diaryBackgroundsDir.path,
        );
      }

      final backupsDir = Directory('$appPath/backups');
      if (await backupsDir.exists()) {
        _backupsSize = await _getDirectorySize(backupsDir.path);
      }

      final videosDir = Directory('$appPath/videos');
      if (await videosDir.exists()) {
        _videosSize = await _getDirectorySize(videosDir.path);
      }

      _videoThumbnailCacheSize =
          await _fileCleanupService.getVideoThumbnailCacheUsage();

      // 动态扫描应用文档根目录下所有子项，定位未列出的占用（如插件缓存等）
      _otherAppPaths.clear();
      final appDir = Directory(appPath);
      if (await appDir.exists()) {
        await for (final entity in appDir.list()) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.') ||
              name == 'change_app.db' ||
              name == 'change_app.db-journal' ||
              name == 'change_app.db-wal')
            continue;
          final known = {
            'documents',
            'folders',
            'images',
            'audios',
            'audio',
            'media',
            'diary_media',
            'background_images',
            'backgrounds',
            'background_videos',
            'diary_backgrounds',
            'backups',
            'videos',
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
      final dbPath =
          '${(await getApplicationDocumentsDirectory()).path}/change_app.db';
      final dbFile = File(dbPath);
      if (await dbFile.exists()) {
        _databaseSize = await dbFile.length();
      }

      // 应用专属外部存储（与系统「数据」一致，含导出 ZIP、browser_backups 等）
      _externalStorageSize =
          await _fileCleanupService.getExternalStorageUsage();
    } catch (e) {
      if (kDebugMode) {
        Logger.log('加载存储信息失败: $e');
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
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  Color _selfCheckColor(bool ok) {
    return ok ? Colors.green.shade700 : Colors.red.shade700;
  }

  TextStyle _selfCheckTextStyle(bool ok, {bool bold = false}) {
    return TextStyle(
      color: _selfCheckColor(ok),
      fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
    );
  }

  Widget _selfCheckLine(
    String label,
    bool ok,
    String okText,
    String badText, {
    bool bold = false,
  }) {
    return Text(
      '$label${ok ? okText : badText}',
      style: _selfCheckTextStyle(ok, bold: bold),
    );
  }

  Future<Map<String, dynamic>> _inspectZipArchive(File file) async {
    final path = file.path;
    final name = path.split(Platform.pathSeparator).last;
    int sizeBytes = 0;
    InputFileStream? inputStream;
    try {
      sizeBytes = await file.length();
      if (sizeBytes < 4) {
        return {
          'ok': false,
          'path': path,
          'name': name,
          'sizeBytes': sizeBytes,
          'entryCount': 0,
          'jsonEntryCount': 0,
          'reason': '文件过小，不像有效 ZIP',
        };
      }
      inputStream = InputFileStream(path);
      final archive = ZipDecoder().decodeStream(inputStream);
      final fileEntries = archive.files.where((e) => e.isFile).toList();
      final jsonEntries =
          fileEntries
              .where((e) => e.name.toLowerCase().endsWith('.json'))
              .toList();
      final ok = fileEntries.isNotEmpty && jsonEntries.isNotEmpty;
      return {
        'ok': ok,
        'path': path,
        'name': name,
        'sizeBytes': sizeBytes,
        'entryCount': fileEntries.length,
        'jsonEntryCount': jsonEntries.length,
        'reason': ok ? '' : 'ZIP 可读取，但缺少有效文件条目或关键 JSON',
      };
    } catch (e) {
      return {
        'ok': false,
        'path': path,
        'name': name,
        'sizeBytes': sizeBytes,
        'entryCount': 0,
        'jsonEntryCount': 0,
        'reason': e.toString(),
      };
    } finally {
      try {
        inputStream?.close();
      } catch (_) {}
    }
  }

  Map<String, dynamic> _buildReleaseReadinessReport({
    required bool deep,
    required bool sqliteOk,
    required int fkViolations,
    required Map<String, dynamic> dataIntegrity,
    required int validPathCount,
    required int checkedPathCount,
    required int missingCount,
    required Map<String, dynamic> duplicateSummary,
    required Map<String, dynamic> staging,
    required Map<String, dynamic> ioPrecheck,
    required int cleanupPreviewCount,
    required int cleanupPreviewBytes,
  }) {
    final blockers = <String>[];
    final warnings = <String>[];

    final bool checkedAllRefs =
        validPathCount == 0 || checkedPathCount >= validPathCount;
    final int duplicateTotal = duplicateSummary['total'] as int? ?? 0;
    final bool docsWritable = ioPrecheck['docsWritable'] == true;
    final bool tempWritable = ioPrecheck['tempWritable'] == true;
    final bool extWritable = ioPrecheck['externalWritable'] == true;
    final int backupZipCount = ioPrecheck['backupZipCount'] as int? ?? 0;
    final int backupZipBadCount = ioPrecheck['backupZipBadCount'] as int? ?? 0;
    final int exportZipCount = ioPrecheck['exportZipCount'] as int? ?? 0;
    final int exportZipBadCount = ioPrecheck['exportZipBadCount'] as int? ?? 0;
    final bool stagingExists = staging['exists'] == true;
    final bool stagingParseOk = staging['parseOk'] == true;
    final int stagingUnknown = staging['unknownIdCount'] as int? ?? 0;
    final int stagingItems = staging['itemCount'] as int? ?? 0;
    final bool dataIntegrityOk = dataIntegrity['isValid'] == true;
    final issues =
        (dataIntegrity['issues'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();

    if (!deep) {
      blockers.add('当前不是发布级全量自检，结果不能作为正式版 APK 发布依据。');
    }
    if (!checkedAllRefs) {
      blockers.add('文件引用只检查了 $checkedPathCount/$validPathCount，未完成全量扫描。');
    }
    if (!sqliteOk) {
      blockers.add('SQLite 完整性检查异常。');
    }
    if (fkViolations > 0) {
      blockers.add('发现 $fkViolations 个外键异常。');
    }
    if (!dataIntegrityOk) {
      blockers.add('业务数据完整性检查发现 ${issues.length} 项问题。');
    }
    if (missingCount > 0) {
      blockers.add('发现 $missingCount 个失效文件引用。');
    }
    if (duplicateTotal > 0) {
      blockers.add('发现 $duplicateTotal 组重复媒体；按产品要求，正式版前应只保留一份。');
    }
    if (!stagingParseOk || stagingUnknown > 0) {
      blockers.add('媒体取景参数暂存文件异常，存在未解析或未知媒体 ID。');
    }
    if (!docsWritable) {
      blockers.add('应用文档目录不可写。');
    }
    if (!tempWritable) {
      blockers.add('临时目录不可写。');
    }
    if (Platform.isAndroid && !extWritable) {
      blockers.add('Android 外部存储不可写，导出/备份能力异常。');
    }
    if (backupZipBadCount > 0) {
      blockers.add('发现 $backupZipBadCount 个损坏或不可读取的备份 ZIP。');
    }
    if (Platform.isAndroid && exportZipBadCount > 0) {
      blockers.add('发现 $exportZipBadCount 个损坏或不可读取的导出 ZIP。');
    }

    if (cleanupPreviewCount > 0) {
      warnings.add(
        '存在 $cleanupPreviewCount 个可清理项（${_formatFileSize(cleanupPreviewBytes)}），建议清理后再发版。',
      );
    }
    if (stagingExists && stagingItems > 0 && stagingParseOk && stagingUnknown == 0) {
      warnings.add('仍有 $stagingItems 条取景参数暂存待自然合并，建议重启应用后复检一次。');
    }

    final bool releaseReady = blockers.isEmpty;
    final String verdict =
        releaseReady
            ? (warnings.isEmpty ? 'ready' : 'ready_with_warnings')
            : 'blocked';
    final String title =
        verdict == 'ready'
            ? '可以生成正式版 APK'
            : verdict == 'ready_with_warnings'
            ? '基本可生成正式版 APK'
            : '暂不可以生成正式版 APK';
    final String summary =
        verdict == 'ready'
            ? '通过：当前数据状态和关键存储能力满足正式版发布门槛。'
            : verdict == 'ready_with_warnings'
            ? '通过但有提醒：当前没有阻断发布的问题，但建议先处理提醒项。'
            : '未通过：存在会影响正式版发布的阻断问题，需先修复。';

    return {
      'releaseReady': releaseReady,
      'verdict': verdict,
      'title': title,
      'summary': summary,
      'blockers': blockers,
      'warnings': warnings,
      'checkedAllRefs': checkedAllRefs,
    };
  }

  /// 清理临时文件
  Future<void> _cleanTempFiles() async {
    try {
      await _fileCleanupService.cleanAllTempFiles();
      await _loadStorageInfo();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清理临时文件失败: $e')));
      }
    }
  }

  /// 清理缓存文件
  Future<void> _cleanCacheFiles() async {
    try {
      try {
        await PhotoManager.clearFileCache();
      } catch (_) {}
      await _fileCleanupService.cleanAllCacheFiles();
      await _loadStorageInfo();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清理缓存文件失败: $e')));
      }
    }
  }

  /// 执行完整清理（临时+缓存+孤立文件）
  Future<void> _performFullCleanup() async {
    try {
      final validPaths = await _databaseService.getAllValidFilePaths();
      final preview = await _fileCleanupService.previewFullStorageCleanup(
        validPaths,
      );
      final int totalCount = preview['totalCount'] as int? ?? 0;
      final int totalBytes = preview['totalBytes'] as int? ?? 0;
      final List<Map<String, dynamic>> sections =
          (preview['sections'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();

      if (!mounted) return;
      if (totalCount == 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未发现可清理的垃圾或孤立文件')));
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('完整清理预览'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '预计删除 $totalCount 个文件，释放 ${_formatFileSize(totalBytes)}。',
                    ),
                    const SizedBox(height: 10),
                    ...sections.map((s) {
                      final title = s['title']?.toString() ?? '未命名';
                      final path = s['path']?.toString() ?? '';
                      final count = s['count'] as int? ?? 0;
                      final bytes = s['bytes'] as int? ?? 0;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$title: $count 个 (${_formatFileSize(bytes)})',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (path.isNotEmpty)
                              Text(
                                path,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 6),
                    const Text(
                      '仅删除临时/缓存/孤立文件，不会删除数据库仍在引用的文件。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确认清理'),
              ),
            ],
          );
        },
      );

      if (confirmed != true) return;

      await _fileCleanupService.performFullStorageCleanup();
      await _fileCleanupService.cleanOrphanedFiles(validPaths);
      await _loadStorageInfo();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('完整清理完成：删除 $totalCount 个文件，释放 ${_formatFileSize(totalBytes)}'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('完整存储清理失败: $e')));
      }
    }
  }

  /// 清理备份文件（需确认，删除后无法恢复）
  Future<void> _cleanBackupFiles() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('确认清理备份'),
            content: Text(
              '备份文件包含目录导出、数据库备份等，用于数据恢复。\n\n'
              '删除后将无法恢复，确定要清理约 ${_formatFileSize(_backupsSize)} 的备份文件吗？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清理备份失败: $e')));
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
            content: Text(
              count > 0 ? '已清理 $count 项外部存储，释放 $sizeStr' : '外部存储无可清理项',
            ),
            backgroundColor: count > 0 ? Colors.green : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清理外部存储失败: $e')));
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
        final sizeStr =
            bytes < 1024
                ? '${bytes}B'
                : bytes < 1024 * 1024
                ? '${(bytes / 1024).toStringAsFixed(1)}KB'
                : '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              count > 0 ? '已清理 $count 个孤立文件，释放 $sizeStr 空间' : '未发现孤立文件',
            ),
            backgroundColor: count > 0 ? Colors.green : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清理孤立文件失败: $e')));
      }
    }
  }

  Widget _buildStorageFloatingTopBar() {
    const Color fg = Color(0xDE000000);
    final pad = MediaQuery.paddingOf(context);
    const ts = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w500,
      color: fg,
    );
    final iconBtnStyle = IconButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      minimumSize: const Size(36, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
    );
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          color: Colors.transparent,
          child: Row(
            children: [
              if (Navigator.of(context).canPop())
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: fg),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '返回',
                  style: iconBtnStyle,
                ),
              const Expanded(
                child: Text('存储管理', style: ts),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: fg),
                onPressed: _loadStorageInfo,
                tooltip: '刷新',
                style: iconBtnStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child:
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(16, topInset + 16, 16, 16),
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
            ),
            _buildStorageFloatingTopBar(),
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
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildStorageItem('文档文件', _documentsSize, Icons.description),
            _buildStorageItem('图片文件(目录)', _imagesSize, Icons.image),
            _buildStorageItem('音频文件(目录)', _audiosSize, Icons.audiotrack),
            _buildStorageItem('媒体文件', _mediaSize, Icons.photo_library),
            _buildStorageItem('日记媒体', _diaryMediaSize, Icons.photo),
            _buildStorageItem('背景图片', _backgroundImagesSize, Icons.wallpaper),
            _buildStorageItem('文档背景', _backgroundsSize, Icons.image),
            _buildStorageItem(
              '日记背景',
              _diaryBackgroundsSize,
              Icons.photo_library,
            ),
            _buildStorageItem('备份文件', _backupsSize, Icons.backup),
            _buildStorageItem('视频文件', _videosSize, Icons.videocam),
            _buildStorageItem(
              '视频缩略图缓存',
              _videoThumbnailCacheSize,
              Icons.video_library,
            ),
            ..._otherAppPaths.entries.map(
              (e) => _buildStorageItem('其他(${e.key})', e.value, Icons.folder),
            ),
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
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildCleanupButton(
              _selfCheckRunning ? '发布级自检（运行中…）' : '发布级自检',
              _selfCheckResult == null
                  ? '全量检查数据库、文件引用、重复媒体、备份可恢复性，并给出是否可生成正式版 APK 的结论'
                  : _selfCheckResult!['summary']?.toString() ?? '查看上次自检结果',
              Icons.verified_user,
              _selfCheckRunning ? () {} : _runReleaseGateCheck,
              isPrimary: true,
            ),
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
                '仅删除已知导出文件和插件缓存，不会清空整个外部存储目录',
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
              '仅清理临时/缓存/孤立文件，保留可用数据与导出文件',
              Icons.cleaning_services,
              _performFullCleanup,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runStabilitySelfCheck({bool deep = false}) async {
    setState(() {
      _selfCheckRunning = true;
    });

    Map<String, dynamic> result = {};
    try {
      final ioPrecheck = await _runImportExportPrecheck(deep: deep);
      final sqliteCheck = await _databaseService.sqliteIntegrityCheck(
        quick: !deep,
      );
      final fkViolations = await _databaseService.sqliteForeignKeyViolationCount();
      final coreCounts = await _databaseService.getCoreTableRowCounts();
      final duplicateSummary = await _databaseService.findDuplicateMediaItemsSummary();
      final staging = await _databaseService.getVideoViewStagingJsonStatus();
      final dataIntegrity = await _databaseService.checkDataIntegrity();
      final validPaths = await _databaseService.getAllValidFilePaths();
      final preview = await _fileCleanupService.previewFullStorageCleanup(
        validPaths,
      );

      final paths = validPaths.toList();
      final missingPaths = <String>[];
      final int maxCheck =
          deep
              ? paths.length
              : (paths.length <= 5000 ? paths.length : (paths.length > 300 ? 300 : paths.length));
      int missingCount = 0;
      final sampleMissing = <String>[];
      for (int i = 0; i < maxCheck; i++) {
        final p = paths[i];
        if (p.isEmpty) continue;
        final ok = await File(p).exists();
        if (!ok) {
          missingCount++;
          missingPaths.add(p);
          if (sampleMissing.length < 20) sampleMissing.add(p);
        }
      }

      final isFullScan = maxCheck == paths.length;
      final detailPaths =
          (isFullScan && missingPaths.length <= 60)
              ? missingPaths
              : missingPaths.take(20).toList();
      final missingDetails =
          detailPaths.isEmpty
              ? const <Map<String, dynamic>>[]
              : await _databaseService.describeMissingFileReferences(detailPaths);

      final bool sqliteOk = sqliteCheck.trim().toLowerCase() == 'ok';
      final bool integrityOk =
          (dataIntegrity['isValid'] == true) && (fkViolations == 0);
      final bool refsOk = missingCount == 0;
      final bool stagingOk =
          (staging['parseOk'] == true) && ((staging['unknownIdCount'] ?? 0) == 0);
      final bool duplicatesOk = (duplicateSummary['total'] as int? ?? 0) == 0;
      final bool ioOk = ioPrecheck['ok'] == true;
      final overallOk =
          sqliteOk && integrityOk && refsOk && stagingOk && duplicatesOk && ioOk;
      final int totalCount = preview['totalCount'] as int? ?? 0;
      final int totalBytes = preview['totalBytes'] as int? ?? 0;

      result = {
        'ok': overallOk,
        'deep': deep,
        'ioPrecheck': ioPrecheck,
        'sqliteCheck': sqliteCheck,
        'foreignKeyViolations': fkViolations,
        'coreCounts': coreCounts,
        'duplicateSummary': duplicateSummary,
        'staging': staging,
        'dataIntegrity': dataIntegrity,
        'validPathCount': validPaths.length,
        'checkedPathCount': maxCheck,
        'isFullScan': isFullScan,
        'missingPathCount': missingCount,
        'missingSamples': sampleMissing,
        'missingDetails': missingDetails,
        'missingPaths': isFullScan ? missingPaths : const <String>[],
        'cleanupPreviewCount': totalCount,
        'cleanupPreviewBytes': totalBytes,
        'summary':
            overallOk
                ? '通过：核心数据与文件引用正常；可清理项 ${totalCount > 0 ? '$totalCount 个' : '0'}'
                : '发现问题：建议点开查看详情',
      };

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          final dupTotal = duplicateSummary['total'] as int? ?? 0;
          final dupTop =
              (duplicateSummary['top'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .toList();
          final stagingExists = staging['exists'] == true;
          final stagingSize = staging['sizeBytes'] as int? ?? 0;
          final stagingItems = staging['itemCount'] as int? ?? 0;
          final stagingUnknown = staging['unknownIdCount'] as int? ?? 0;
          final ioOk = ioPrecheck['ok'] == true;
          final docsWritable = ioPrecheck['docsWritable'] == true;
          final tempWritable = ioPrecheck['tempWritable'] == true;
          final extWritable = ioPrecheck['externalWritable'] == true;
          final backupZipTotal = ioPrecheck['backupZipCount'] as int? ?? 0;
          final backupZipBad = ioPrecheck['backupZipBadCount'] as int? ?? 0;
          final exportZipTotal = ioPrecheck['exportZipCount'] as int? ?? 0;
          final exportZipBad = ioPrecheck['exportZipBadCount'] as int? ?? 0;
          final missingDetails =
              (result['missingDetails'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .toList();
          final missingPaths =
              (result['missingPaths'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString())
                  .where((e) => e.trim().isNotEmpty)
                  .toList();
          final isFullScan = result['isFullScan'] == true;

          String _basename(String p) {
            final s = p.trim();
            if (s.isEmpty) return '';
            final i1 = s.lastIndexOf('/');
            final i2 = s.lastIndexOf('\\');
            final i = i1 > i2 ? i1 : i2;
            return i >= 0 ? s.substring(i + 1) : s;
          }

          String _usageLabel(Map<String, dynamic> u) {
            final t = u['type']?.toString() ?? '';
            if (t == 'document_background_image' || t == 'document_background_video') {
              final doc = u['documentName']?.toString() ?? '';
              final folder = u['folderName']?.toString();
              final kind = t == 'document_background_image' ? '背景图片' : '背景视频';
              final prefix = folder == null || folder.isEmpty ? '' : '（$folder）';
              return '文档$prefix《$doc》$kind';
            }
            if (t == 'directory_background_image' || t == 'directory_background_video') {
              final folder = u['folderName']?.toString() ?? '';
              final kind = t == 'directory_background_image' ? '背景图片' : '背景视频';
              return '目录「${folder.isEmpty ? '根目录' : folder}」$kind';
            }
            if (t == 'diary_background_image' || t == 'diary_background_video') {
              return t == 'diary_background_image' ? '日记本背景图片' : '日记本背景视频';
            }
            if (t == 'cover_background_image' || t == 'cover_background_video') {
              return t == 'cover_background_image' ? '封面背景图片' : '封面背景视频';
            }
            if (t == 'cover_image') return '封面图片';
            if (t == 'background_file_view_params') return '背景取景参数缓存';
            if (t == 'document_image_box') {
              final doc = u['documentName']?.toString() ?? '';
              final folder = u['folderName']?.toString();
              final prefix = folder == null || folder.isEmpty ? '' : '（$folder）';
              return '文档$prefix《$doc》图片框内容';
            }
            if (t == 'document_audio_box') {
              final doc = u['documentName']?.toString() ?? '';
              final folder = u['folderName']?.toString();
              final prefix = folder == null || folder.isEmpty ? '' : '（$folder）';
              return '文档$prefix《$doc》音频框内容';
            }
            if (t == 'media_item_file' || t == 'media_item_thumbnail') {
              final name = u['mediaName']?.toString() ?? '';
              final kind = t == 'media_item_file' ? '媒体文件' : '媒体缩略图';
              return '媒体库「$name」$kind';
            }
            if (t == 'diary_entry_media') {
              final date = u['date']?.toString() ?? '';
              return '日记条目（$date）内嵌媒体';
            }
            return t.isEmpty ? '未知引用' : t;
          }

          Future<void> _openDocumentByName(String name) async {
            final trimmed = name.trim();
            if (trimmed.isEmpty) return;
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (c) => DocumentEditorPage(
                  documentName: trimmed,
                  onSave: (updatedTextBoxes) {},
                ),
              ),
            );
          }

          Future<void> _openDirectoryPage() async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (c) => DirectoryPage(
                  onDocumentOpen: (doc) async {
                    await _openDocumentByName(doc);
                  },
                ),
              ),
            );
          }

          Future<void> _openDiaryPage() async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const DiaryPage()),
            );
          }

          Future<void> _openCoverPage() async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const CoverPage()),
            );
          }

          return AlertDialog(
            title: Text(overallOk ? '稳定性自检：通过' : '稳定性自检：发现问题'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('自检模块版本：$_selfCheckUiVersion'),
                    const SizedBox(height: 10),
                    Text('核心表计数：'),
                    Text(
                      [
                        'folders:${coreCounts['folders'] ?? 0}',
                        'documents:${coreCounts['documents'] ?? 0}',
                        'media_items:${coreCounts['media_items'] ?? 0}',
                        'diary_entries:${coreCounts['diary_entries'] ?? 0}',
                      ].join('  '),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '导入/导出预检：${ioOk ? 'OK' : '异常'}'
                      '（文档${docsWritable ? '可写' : '不可写'} / 临时${tempWritable ? '可写' : '不可写'}'
                      '${Platform.isAndroid ? ' / 外部${extWritable ? '可写' : '不可写'}' : ''}）',
                    ),
                    Text(
                      '备份ZIP：$backupZipTotal 个（异常 $backupZipBad）'
                      '${Platform.isAndroid ? '  导出ZIP：$exportZipTotal 个（异常 $exportZipBad）' : ''}',
                    ),
                    const SizedBox(height: 10),
                    Text('SQLite 检查：${sqliteOk ? 'OK' : '异常'}'),
                    if (!sqliteOk) Text(sqliteCheck),
                    const SizedBox(height: 8),
                    Text('外键异常：$fkViolations'),
                    const SizedBox(height: 8),
                    Text('业务数据完整性：${integrityOk ? 'OK' : '异常'}'),
                    if (dataIntegrity['issues'] is List &&
                        (dataIntegrity['issues'] as List).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text((dataIntegrity['issues'] as List).take(20).join('\n')),
                    ],
                    const SizedBox(height: 8),
                    Text('媒体重复（按 file_hash）：${dupTotal == 0 ? '0（OK）' : dupTotal.toString()}'),
                    if (dupTop.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        dupTop
                            .map((e) {
                              final h = e['hash']?.toString() ?? '';
                              final prefix = h.length <= 8 ? h : h.substring(0, 8);
                              return '$prefix… ×${e['count']}';
                            })
                            .take(12)
                            .join('\n'),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '取景参数暂存：${stagingExists ? '存在' : '无'}，解析 ${stagingOk ? 'OK' : '异常'}'
                      '${stagingExists ? '（${_formatFileSize(stagingSize)}，$stagingItems 条，未知ID $stagingUnknown）' : ''}',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '引用文件检查：$missingCount/$maxCheck 缺失'
                      '${result['isFullScan'] == true ? '（全量）' : '（抽样）'}',
                    ),
                    if (missingDetails.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('缺失引用定位：'),
                      const SizedBox(height: 4),
                      ...missingDetails.take(12).map((d) {
                        final p = d['path']?.toString() ?? '';
                        final usages =
                            (d['usages'] as List<dynamic>? ?? const [])
                                .whereType<Map<String, dynamic>>()
                                .toList();
                        final repairable = d['repairable'] == true;
                        final lines =
                            usages.isEmpty
                                ? ['未能定位到具体来源（可能来自旧数据残留）']
                                : usages.map(_usageLabel).toList();
                        final docUsage =
                            usages.firstWhere(
                              (u) =>
                                  (u['type']?.toString() ?? '')
                                      .startsWith('document_'),
                              orElse: () => const {},
                            );
                        final docName = docUsage['documentName']?.toString() ?? '';
                        final hasDir = usages.any((u) {
                          final t = u['type']?.toString() ?? '';
                          return t.startsWith('directory_');
                        });
                        final hasDiary = usages.any((u) {
                          final t = u['type']?.toString() ?? '';
                          return t.startsWith('diary_');
                        });
                        final hasCover = usages.any((u) {
                          final t = u['type']?.toString() ?? '';
                          return t.startsWith('cover_');
                        });

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                lines.take(3).join('\n'),
                                style: const TextStyle(fontSize: 13),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _basename(p).isEmpty ? p : _basename(p),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  TextButton(
                                    onPressed: () async {
                                      await Clipboard.setData(
                                        ClipboardData(
                                          text:
                                              usages.isEmpty
                                                  ? p
                                                  : lines.join('\n'),
                                        ),
                                      );
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('已复制定位信息')),
                                      );
                                    },
                                    child: const Text('复制定位'),
                                  ),
                                  if (docName.isNotEmpty)
                                    TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await _openDocumentByName(docName);
                                      },
                                      child: const Text('打开文档'),
                                    ),
                                  if (hasDir)
                                    TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await _openDirectoryPage();
                                      },
                                      child: const Text('打开目录'),
                                    ),
                                  if (hasDiary)
                                    TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await _openDiaryPage();
                                      },
                                      child: const Text('打开日记'),
                                    ),
                                  if (hasCover)
                                    TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await _openCoverPage();
                                      },
                                      child: const Text('打开封面'),
                                    ),
                                  if (!repairable)
                                    const Text(
                                      '需手动处理',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.red,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                      if (missingDetails.length > 12)
                        Text('… 还有 ${missingDetails.length - 12} 项（仅展示部分）'),
                    ] else if (sampleMissing.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(sampleMissing.join('\n')),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '可清理预览：${preview['totalCount'] ?? 0} 个，约 ${_formatFileSize(totalBytes)}',
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (missingCount > 0 && isFullScan && missingPaths.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (c) {
                        return AlertDialog(
                          title: const Text('修复缺失文件引用'),
                          content: Text(
                            '检测到 $missingCount 个缺失引用。\n\n'
                            '将清除“背景/封面/设置/取景缓存/日记条目列表”等可安全修复的引用；\n'
                            '不会自动删除文档图片框/音频框/媒体库条目这类内容数据。\n\n'
                            '修复后会自动重新跑一次深度自检。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(c, true),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                              child: const Text('确定修复'),
                            ),
                          ],
                        );
                      },
                    );
                    if (confirmed != true) return;
                    setState(() {
                      _selfCheckRunning = true;
                    });
                    try {
                      final r =
                          await _databaseService.repairMissingFileReferences(
                        missingPaths,
                      );
                      if (!mounted) return;
                      final fixedPaths = r['fixedPathCount'] ?? 0;
                      final totalPaths = r['pathCount'] ?? 0;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '已修复缺失引用：$fixedPaths/$totalPaths 条路径（可安全修复项）',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('修复缺失引用失败: $e')),
                      );
                    } finally {
                      if (mounted) {
                        setState(() {
                          _selfCheckRunning = false;
                        });
                      }
                      await _loadStorageInfo();
                      await _runStabilitySelfCheck(deep: true);
                    }
                  },
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('修复缺失引用'),
                ),
              if (dupTotal > 0)
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (c) {
                        return AlertDialog(
                          title: const Text('修复重复媒体'),
                          content: Text(
                            '检测到 $dupTotal 组重复媒体（按 file_hash）。\n\n'
                            '将保留每组中更可能是“主副本”的一条记录，删除其余重复记录；随后执行一次“孤立文件清理”以回收重复占用的磁盘文件。\n\n'
                            '该操作不会清空回收站。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(c, true),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                              child: const Text('确定修复'),
                            ),
                          ],
                        );
                      },
                    );
                    if (confirmed != true) return;
                    setState(() {
                      _selfCheckRunning = true;
                    });
                    try {
                      final r = await _databaseService.resolveDuplicateMediaItems(
                        maxGroups: 2000,
                      );
                      if (!mounted) return;
                      final groups = r['groupsResolved'] ?? 0;
                      final rows = r['mediaRowsDeleted'] ?? 0;
                      final of = r['orphanFilesDeleted'] ?? 0;
                      final ob = r['orphanBytesDeleted'] ?? 0;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '已处理重复媒体：$groups 组，删除记录 $rows 条，回收孤立文件 $of 个（${_formatFileSize(ob)}）',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('修复重复媒体失败: $e')),
                      );
                    } finally {
                      if (mounted) {
                        setState(() {
                          _selfCheckRunning = false;
                        });
                      }
                      await _loadStorageInfo();
                      await _runStabilitySelfCheck(deep: true);
                    }
                  },
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('修复重复媒体'),
                ),
              if (!deep)
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _runStabilitySelfCheck(deep: true);
                  },
                  child: const Text('深度自检'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      result = {
        'ok': false,
        'summary': '自检失败：$e',
      };
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('稳定性自检失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _selfCheckRunning = false;
          _selfCheckResult = result;
        });
      }
    }
  }

  Future<void> _runReleaseGateCheck() async {
    setState(() {
      _selfCheckRunning = true;
    });

    Map<String, dynamic> result = {};
    try {
      const bool deep = true;
      final ioPrecheck = await _runImportExportPrecheck(deep: deep);
      final sqliteCheck = await _databaseService.sqliteIntegrityCheck(
        quick: false,
      );
      final fkViolations =
          await _databaseService.sqliteForeignKeyViolationCount();
      final coreCounts = await _databaseService.getCoreTableRowCounts();
      final duplicateSummary =
          await _databaseService.findDuplicateMediaItemsSummary();
      final staging = await _databaseService.getVideoViewStagingJsonStatus();
      final dataIntegrity = await _databaseService.checkDataIntegrity();
      final validPaths = await _databaseService.getAllValidFilePaths();
      final preview = await _fileCleanupService.previewFullStorageCleanup(
        validPaths,
      );

      int missingCount = 0;
      final sampleMissing = <String>[];
      final missingPaths = <String>[];
      for (final p in validPaths) {
        if (p.isEmpty) continue;
        final ok = await File(p).exists();
        if (!ok) {
          missingCount++;
          missingPaths.add(p);
          if (sampleMissing.length < 20) sampleMissing.add(p);
        }
      }

      final detailPaths =
          missingPaths.length <= 60 ? missingPaths : missingPaths.take(20).toList();
      final missingDetails =
          detailPaths.isEmpty
              ? const <Map<String, dynamic>>[]
              : await _databaseService.describeMissingFileReferences(detailPaths);

      final bool sqliteOk = sqliteCheck.trim().toLowerCase() == 'ok';
      final int totalCount = preview['totalCount'] as int? ?? 0;
      final int totalBytes = preview['totalBytes'] as int? ?? 0;
      final releaseReport = _buildReleaseReadinessReport(
        deep: true,
        sqliteOk: sqliteOk,
        fkViolations: fkViolations,
        dataIntegrity: dataIntegrity,
        validPathCount: validPaths.length,
        checkedPathCount: validPaths.length,
        missingCount: missingCount,
        duplicateSummary: duplicateSummary,
        staging: staging,
        ioPrecheck: ioPrecheck,
        cleanupPreviewCount: totalCount,
        cleanupPreviewBytes: totalBytes,
      );
      final blockers =
          (releaseReport['blockers'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList();
      final warnings =
          (releaseReport['warnings'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList();

      result = {
        'ok': releaseReport['releaseReady'] == true,
        'summary': releaseReport['summary'],
        'releaseReport': releaseReport,
        'missingPathCount': missingCount,
        'missingDetails': missingDetails,
        'missingPaths': missingPaths,
        'cleanupPreviewCount': totalCount,
        'cleanupPreviewBytes': totalBytes,
      };

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          final dupTotal = duplicateSummary['total'] as int? ?? 0;
          final dupTop =
              (duplicateSummary['top'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .toList();
          final stagingExists = staging['exists'] == true;
          final stagingSize = staging['sizeBytes'] as int? ?? 0;
          final stagingItems = staging['itemCount'] as int? ?? 0;
          final stagingUnknown = staging['unknownIdCount'] as int? ?? 0;
          final stagingOk =
              (staging['parseOk'] == true) && (stagingUnknown == 0);
          final integrityOk =
              (dataIntegrity['isValid'] == true) && (fkViolations == 0);
          final ioOk = ioPrecheck['ok'] == true;
          final docsWritable = ioPrecheck['docsWritable'] == true;
          final tempWritable = ioPrecheck['tempWritable'] == true;
          final extWritable = ioPrecheck['externalWritable'] == true;
          final backupZipTotal = ioPrecheck['backupZipCount'] as int? ?? 0;
          final backupZipBad = ioPrecheck['backupZipBadCount'] as int? ?? 0;
          final exportZipTotal = ioPrecheck['exportZipCount'] as int? ?? 0;
          final exportZipBad = ioPrecheck['exportZipBadCount'] as int? ?? 0;
          final backupZipChecked =
              ioPrecheck['backupZipCheckedCount'] as int? ?? 0;
          final exportZipChecked =
              ioPrecheck['exportZipCheckedCount'] as int? ?? 0;
          final badBackupZips =
              (ioPrecheck['badBackupZipSamples'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString())
                  .toList();
          final badExportZips =
              (ioPrecheck['badExportZipSamples'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString())
                  .toList();
          final String verdictTitle =
              releaseReport['title']?.toString() ?? '发布级自检';
          final String verdictSummary =
              releaseReport['summary']?.toString() ?? '请查看详细结果。';
          final missingDetails =
              (result['missingDetails'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .toList();
          final missingPaths =
              (result['missingPaths'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString())
                  .where((e) => e.trim().isNotEmpty)
                  .toList();

          String _basename(String p) {
            final s = p.trim();
            if (s.isEmpty) return '';
            final i1 = s.lastIndexOf('/');
            final i2 = s.lastIndexOf('\\');
            final i = i1 > i2 ? i1 : i2;
            return i >= 0 ? s.substring(i + 1) : s;
          }

          String _usageLabel(Map<String, dynamic> u) {
            final t = u['type']?.toString() ?? '';
            if (t == 'document_background_image' || t == 'document_background_video') {
              final doc = u['documentName']?.toString() ?? '';
              final folder = u['folderName']?.toString();
              final kind = t == 'document_background_image' ? '背景图片' : '背景视频';
              final prefix = folder == null || folder.isEmpty ? '' : '（$folder）';
              return '文档$prefix《$doc》$kind';
            }
            if (t == 'directory_background_image' || t == 'directory_background_video') {
              final folder = u['folderName']?.toString() ?? '';
              final kind = t == 'directory_background_image' ? '背景图片' : '背景视频';
              return '目录「${folder.isEmpty ? '根目录' : folder}」$kind';
            }
            if (t == 'diary_background_image' || t == 'diary_background_video') {
              return t == 'diary_background_image' ? '日记本背景图片' : '日记本背景视频';
            }
            if (t == 'cover_background_image' || t == 'cover_background_video') {
              return t == 'cover_background_image' ? '封面背景图片' : '封面背景视频';
            }
            if (t == 'cover_image') return '封面图片';
            if (t == 'background_file_view_params') return '背景取景参数缓存';
            if (t == 'document_image_box') {
              final doc = u['documentName']?.toString() ?? '';
              final folder = u['folderName']?.toString();
              final prefix = folder == null || folder.isEmpty ? '' : '（$folder）';
              return '文档$prefix《$doc》图片框内容';
            }
            if (t == 'document_audio_box') {
              final doc = u['documentName']?.toString() ?? '';
              final folder = u['folderName']?.toString();
              final prefix = folder == null || folder.isEmpty ? '' : '（$folder）';
              return '文档$prefix《$doc》音频框内容';
            }
            if (t == 'media_item_file' || t == 'media_item_thumbnail') {
              final name = u['mediaName']?.toString() ?? '';
              final kind = t == 'media_item_file' ? '媒体文件' : '媒体缩略图';
              return '媒体库「$name」$kind';
            }
            if (t == 'diary_entry_media') {
              final date = u['date']?.toString() ?? '';
              return '日记条目（$date）内嵌媒体';
            }
            return t.isEmpty ? '未知引用' : t;
          }

          Future<void> _openDocumentByName(String name) async {
            final trimmed = name.trim();
            if (trimmed.isEmpty) return;
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (c) => DocumentEditorPage(
                  documentName: trimmed,
                  onSave: (updatedTextBoxes) {},
                ),
              ),
            );
          }

          Future<void> _openDirectoryPage() async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (c) => DirectoryPage(
                  onDocumentOpen: (doc) async {
                    await _openDocumentByName(doc);
                  },
                ),
              ),
            );
          }

          Future<void> _openDiaryPage() async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const DiaryPage()),
            );
          }

          Future<void> _openCoverPage() async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const CoverPage()),
            );
          }

          return AlertDialog(
            title: Text(verdictTitle),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      verdictSummary,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color:
                            blockers.isEmpty
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (blockers.isNotEmpty) ...[
                      const Text('阻断问题：'),
                      const SizedBox(height: 6),
                      Text(blockers.map((e) => '• $e').join('\n')),
                      const SizedBox(height: 10),
                    ],
                    if (warnings.isNotEmpty) ...[
                      const Text('提醒项：'),
                      const SizedBox(height: 6),
                      Text(warnings.map((e) => '• $e').join('\n')),
                      const SizedBox(height: 10),
                    ],
                    const Text('本次模式：发布级全量扫描'),
                    Text('文件引用检查：${validPaths.length}/${validPaths.length}（全量）'),
                    const SizedBox(height: 10),
                    const Text('核心表计数：'),
                    Text(
                      [
                        'folders:${coreCounts['folders'] ?? 0}',
                        'documents:${coreCounts['documents'] ?? 0}',
                        'media_items:${coreCounts['media_items'] ?? 0}',
                        'diary_entries:${coreCounts['diary_entries'] ?? 0}',
                      ].join('  '),
                    ),
                    const SizedBox(height: 10),
                    _selfCheckLine(
                      '导入/导出与恢复预检：',
                      ioOk && docsWritable && tempWritable && (!Platform.isAndroid || extWritable),
                      'OK（文档${docsWritable ? '可写' : '不可写'} / 临时${tempWritable ? '可写' : '不可写'}${Platform.isAndroid ? ' / 外部${extWritable ? '可写' : '不可写'}' : ''}）',
                      '异常（文档${docsWritable ? '可写' : '不可写'} / 临时${tempWritable ? '可写' : '不可写'}${Platform.isAndroid ? ' / 外部${extWritable ? '可写' : '不可写'}' : ''}）',
                      bold: true,
                    ),
                    _selfCheckLine(
                      '备份ZIP：',
                      backupZipBad == 0,
                      '$backupZipTotal 个（已校验 $backupZipChecked，异常 $backupZipBad）',
                      '$backupZipTotal 个（已校验 $backupZipChecked，异常 $backupZipBad）',
                      bold: true,
                    ),
                    if (Platform.isAndroid)
                      _selfCheckLine(
                        '导出ZIP：',
                        exportZipBad == 0,
                        '$exportZipTotal 个（已校验 $exportZipChecked，异常 $exportZipBad）',
                        '$exportZipTotal 个（已校验 $exportZipChecked，异常 $exportZipBad）',
                        bold: true,
                      ),
                    if (badBackupZips.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        badBackupZips.map((e) => '• $e').join('\n'),
                        style: _selfCheckTextStyle(false),
                      ),
                    ],
                    if (badExportZips.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        badExportZips.map((e) => '• $e').join('\n'),
                        style: _selfCheckTextStyle(false),
                      ),
                    ],
                    const SizedBox(height: 10),
                    _selfCheckLine('SQLite 检查：', sqliteOk, 'OK', '异常', bold: true),
                    if (!sqliteOk)
                      Text(sqliteCheck, style: _selfCheckTextStyle(false)),
                    const SizedBox(height: 8),
                    _selfCheckLine(
                      '外键异常：',
                      fkViolations == 0,
                      '0',
                      '$fkViolations',
                      bold: true,
                    ),
                    const SizedBox(height: 8),
                    _selfCheckLine(
                      '业务数据完整性：',
                      integrityOk,
                      'OK',
                      '异常',
                      bold: true,
                    ),
                    if (dataIntegrity['issues'] is List &&
                        (dataIntegrity['issues'] as List).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        (dataIntegrity['issues'] as List).take(20).join('\n'),
                        style: _selfCheckTextStyle(false),
                      ),
                    ],
                    const SizedBox(height: 8),
                    _selfCheckLine(
                      '重复媒体（按 file_hash）：',
                      dupTotal == 0,
                      '0（OK）',
                      '$dupTotal 组',
                      bold: true,
                    ),
                    if (dupTop.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        dupTop
                            .map((e) {
                              final h = e['hash']?.toString() ?? '';
                              final prefix =
                                  h.length <= 8 ? h : h.substring(0, 8);
                              return '$prefix... x${e['count']}';
                            })
                            .take(12)
                            .join('\n'),
                        style: _selfCheckTextStyle(false),
                      ),
                    ],
                    const SizedBox(height: 8),
                    _selfCheckLine(
                      '取景参数暂存：',
                      stagingOk,
                      stagingExists ? '存在，解析 OK' : '无',
                      stagingExists
                          ? '存在，解析异常（${_formatFileSize(stagingSize)}，$stagingItems 条，未知ID $stagingUnknown）'
                          : '无',
                      bold: true,
                    ),
                    const SizedBox(height: 8),
                    _selfCheckLine(
                      '引用文件检查：',
                      missingCount == 0,
                      '0 缺失',
                      '$missingCount/${validPaths.length} 缺失',
                      bold: true,
                    ),
                    if (missingDetails.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text('缺失引用定位：'),
                      const SizedBox(height: 4),
                      ...missingDetails.take(12).map((d) {
                        final p = d['path']?.toString() ?? '';
                        final usages =
                            (d['usages'] as List<dynamic>? ?? const [])
                                .whereType<Map<String, dynamic>>()
                                .toList();
                        final repairable = d['repairable'] == true;
                        final lines =
                            usages.isEmpty
                                ? ['未能定位到具体来源（可能来自旧数据残留）']
                                : usages.map(_usageLabel).toList();
                        final docUsage =
                            usages.firstWhere(
                              (u) =>
                                  (u['type']?.toString() ?? '')
                                      .startsWith('document_'),
                              orElse: () => const {},
                            );
                        final docName = docUsage['documentName']?.toString() ?? '';
                        final hasDir = usages.any((u) {
                          final t = u['type']?.toString() ?? '';
                          return t.startsWith('directory_');
                        });
                        final hasDiary = usages.any((u) {
                          final t = u['type']?.toString() ?? '';
                          return t.startsWith('diary_');
                        });
                        final hasCover = usages.any((u) {
                          final t = u['type']?.toString() ?? '';
                          return t.startsWith('cover_');
                        });

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                lines.take(3).join('\n'),
                                style: const TextStyle(fontSize: 13),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _basename(p).isEmpty ? p : _basename(p),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  TextButton(
                                    onPressed: () async {
                                      await Clipboard.setData(
                                        ClipboardData(
                                          text:
                                              usages.isEmpty
                                                  ? p
                                                  : lines.join('\n'),
                                        ),
                                      );
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('已复制定位信息')),
                                      );
                                    },
                                    child: const Text('复制定位'),
                                  ),
                                  if (docName.isNotEmpty)
                                    TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await _openDocumentByName(docName);
                                      },
                                      child: const Text('打开文档'),
                                    ),
                                  if (hasDir)
                                    TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await _openDirectoryPage();
                                      },
                                      child: const Text('打开目录'),
                                    ),
                                  if (hasDiary)
                                    TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await _openDiaryPage();
                                      },
                                      child: const Text('打开日记'),
                                    ),
                                  if (hasCover)
                                    TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await _openCoverPage();
                                      },
                                      child: const Text('打开封面'),
                                    ),
                                  if (!repairable)
                                    const Text(
                                      '需手动处理',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.red,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                      if (missingDetails.length > 12)
                        Text('… 还有 ${missingDetails.length - 12} 项（仅展示部分）'),
                    ] else if (sampleMissing.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        sampleMissing.join('\n'),
                        style: _selfCheckTextStyle(false),
                      ),
                    ],
                    const SizedBox(height: 8),
                    _selfCheckLine(
                      '可清理预览：',
                      preview['totalCount'] == 0,
                      '0 个',
                      '${preview['totalCount'] ?? 0} 个，约 ${_formatFileSize(totalBytes)}',
                      bold: true,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (missingCount > 0 && missingPaths.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (c) {
                        return AlertDialog(
                          title: const Text('修复缺失文件引用'),
                          content: Text(
                            '检测到 $missingCount 个缺失引用。\n\n'
                            '将清除“背景/封面/设置/取景缓存/日记条目列表”等可安全修复的引用；\n'
                            '不会自动删除文档图片框/音频框/媒体库条目这类内容数据。\n\n'
                            '修复后会自动重新跑一次发布级自检。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(c, true),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                              child: const Text('确定修复'),
                            ),
                          ],
                        );
                      },
                    );
                    if (confirmed != true) return;
                    setState(() {
                      _selfCheckRunning = true;
                    });
                    try {
                      final r =
                          await _databaseService.repairMissingFileReferences(
                        missingPaths,
                      );
                      if (!mounted) return;
                      final fixedPaths = r['fixedPathCount'] ?? 0;
                      final totalPaths = r['pathCount'] ?? 0;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '已修复缺失引用：$fixedPaths/$totalPaths 条路径（可安全修复项）',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('修复缺失引用失败: $e')),
                      );
                    } finally {
                      if (mounted) {
                        setState(() {
                          _selfCheckRunning = false;
                        });
                      }
                      await _loadStorageInfo();
                      await _runReleaseGateCheck();
                    }
                  },
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('修复缺失引用'),
                ),
              if (dupTotal > 0)
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (c) {
                        return AlertDialog(
                          title: const Text('修复重复媒体'),
                          content: Text(
                            '检测到 $dupTotal 组重复媒体（按 file_hash）。\n\n'
                            '将保留每组中更可能是“主副本”的一条记录，删除其余重复记录；随后执行一次“孤立文件清理”以回收重复占用的磁盘文件。\n\n'
                            '该操作不会清空回收站。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(c, true),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                              child: const Text('确定修复'),
                            ),
                          ],
                        );
                      },
                    );
                    if (confirmed != true) return;
                    setState(() {
                      _selfCheckRunning = true;
                    });
                    try {
                      final r = await _databaseService.resolveDuplicateMediaItems(
                        maxGroups: 2000,
                      );
                      if (!mounted) return;
                      final groups = r['groupsResolved'] ?? 0;
                      final rows = r['mediaRowsDeleted'] ?? 0;
                      final of = r['orphanFilesDeleted'] ?? 0;
                      final ob = r['orphanBytesDeleted'] ?? 0;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '已处理重复媒体：$groups 组，删除记录 $rows 条，回收孤立文件 $of 个（${_formatFileSize(ob)}）',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('修复重复媒体失败: $e')),
                      );
                    } finally {
                      if (mounted) {
                        setState(() {
                          _selfCheckRunning = false;
                        });
                      }
                      await _loadStorageInfo();
                      await _runReleaseGateCheck();
                    }
                  },
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('修复重复媒体'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      result = {
        'ok': false,
        'summary': '发布级自检失败：$e',
      };
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发布级自检失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _selfCheckRunning = false;
          _selfCheckResult = result;
        });
      }
    }
  }

  Future<Map<String, dynamic>> _runImportExportPrecheck({required bool deep}) async {
    bool docsWritable = false;
    bool tempWritable = false;
    bool externalWritable = false;

    bool backupZipOk = true;
    int backupZipCount = 0;
    int backupZipBadCount = 0;
    int backupZipCheckedCount = 0;
    final badBackupZipSamples = <String>[];

    bool exportZipOk = true;
    int exportZipCount = 0;
    int exportZipBadCount = 0;
    int exportZipCheckedCount = 0;
    final badExportZipSamples = <String>[];

    Future<bool> canWrite(Directory dir) async {
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final f = File(
          '${dir.path}${Platform.pathSeparator}selfcheck_${DateTime.now().millisecondsSinceEpoch}.tmp',
        );
        await f.writeAsString('ok', flush: true);
        await f.delete();
        return true;
      } catch (_) {
        return false;
      }
    }

    Future<bool> looksLikeZip(File f) async {
      try {
        final len = await f.length();
        if (len < 2) return false;
        final raf = await f.open(mode: FileMode.read);
        final Uint8List head = await raf.read(4);
        await raf.close();
        if (head.length < 2) return false;
        return head[0] == 0x50 && head[1] == 0x4B;
      } catch (_) {
        return false;
      }
    }

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      docsWritable = await canWrite(docsDir);

      final tempDir = await getTemporaryDirectory();
      tempWritable = await canWrite(tempDir);

      final backupDir = Directory('${docsDir.path}${Platform.pathSeparator}backups');
      if (await backupDir.exists()) {
        final zips = <File>[];
        await for (final e in backupDir.list()) {
          if (e is! File) continue;
          final name = e.path.toLowerCase();
          if (!name.endsWith('.zip')) continue;
          zips.add(e);
        }
        backupZipCount = zips.length;
        final max = deep ? zips.length : (zips.length > 30 ? 30 : zips.length);
        for (int i = 0; i < max; i++) {
          backupZipCheckedCount++;
          final looksZip = await looksLikeZip(zips[i]);
          final inspect = looksZip ? await _inspectZipArchive(zips[i]) : null;
          final ok = looksZip && (inspect?['ok'] == true);
          if (!ok) {
            backupZipBadCount++;
            backupZipOk = false;
            if (badBackupZipSamples.length < 8) {
              final reason =
                  inspect?['reason']?.toString() ??
                  '文件头校验失败，不是有效 ZIP';
              badBackupZipSamples.add(
                '${zips[i].path.split(Platform.pathSeparator).last}: $reason',
              );
            }
          }
        }
      }

      if (Platform.isAndroid) {
        Directory? extDir;
        try {
          extDir = await getExternalStorageDirectory();
        } catch (_) {}
        if (extDir != null) {
          externalWritable = await canWrite(extDir);
          final zips = <File>[];
          await for (final e in extDir.list()) {
            if (e is! File) continue;
            final lower = e.path.toLowerCase();
            if (!lower.endsWith('.zip')) continue;
            final base = lower.split(Platform.pathSeparator).last;
            const prefixes = [
              'directory_backup_',
              'media_backup_',
              'media_folder_',
              'browser_backup_',
              'diary_export_',
              'exported_docs_',
            ];
            if (!prefixes.any(base.startsWith)) continue;
            zips.add(e);
          }
          exportZipCount = zips.length;
          final max = deep ? zips.length : (zips.length > 30 ? 30 : zips.length);
          for (int i = 0; i < max; i++) {
            exportZipCheckedCount++;
            final looksZip = await looksLikeZip(zips[i]);
            final inspect = looksZip ? await _inspectZipArchive(zips[i]) : null;
            final ok = looksZip && (inspect?['ok'] == true);
            if (!ok) {
              exportZipBadCount++;
              exportZipOk = false;
              if (badExportZipSamples.length < 8) {
                final reason =
                    inspect?['reason']?.toString() ??
                    '文件头校验失败，不是有效 ZIP';
                badExportZipSamples.add(
                  '${zips[i].path.split(Platform.pathSeparator).last}: $reason',
                );
              }
            }
          }
        }
      }
    } catch (_) {}

    final ok =
        docsWritable &&
        tempWritable &&
        (Platform.isAndroid ? externalWritable : true) &&
        backupZipOk &&
        exportZipOk;

    return {
      'ok': ok,
      'docsWritable': docsWritable,
      'tempWritable': tempWritable,
      'externalWritable': externalWritable,
      'backupZipCount': backupZipCount,
      'backupZipBadCount': backupZipBadCount,
      'backupZipCheckedCount': backupZipCheckedCount,
      'badBackupZipSamples': badBackupZipSamples,
      'exportZipCount': exportZipCount,
      'exportZipBadCount': exportZipBadCount,
      'exportZipCheckedCount': exportZipCheckedCount,
      'badExportZipSamples': badExportZipSamples,
    };
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
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
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
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildTipItem(
              '「应用外部存储」只清理已知导出文件和插件缓存；「备份文件」为目录/数据库导出备份',
              Icons.info_outline,
            ),
            _buildTipItem(
              '视频缩略图缓存会保留；只有与现有媒体无关的孤立缩略图才会被清理',
              Icons.video_library_outlined,
            ),
            _buildTipItem('定期清理临时文件和缓存文件', Icons.lightbulb_outline),
            _buildTipItem('删除不需要的媒体文件', Icons.photo_library),
            _buildTipItem('定期备份重要数据', Icons.backup),
            _buildTipItem('使用压缩格式存储图片和视频', Icons.compress),
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
