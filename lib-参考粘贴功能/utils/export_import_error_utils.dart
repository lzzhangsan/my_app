// lib/utils/export_import_error_utils.dart
// 导出/导入错误格式化与展示 - 供目录、媒体、日记等模块共用

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_file_manager/open_file_manager.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/export_import_utils.dart' show kShareSizeLimitBytes;

/// 将技术异常转为用户可读的中文提示
String formatExportImportError(Object e, String phase) {
  final msg = e.toString().toLowerCase();
  if (msg.contains('memory') || msg.contains('oom') || msg.contains('out of memory')) {
    return '[$phase] 内存不足。数据量较大时请关闭其他应用后重试，或尝试分批导出。';
  }
  if (msg.contains('space') || msg.contains('disk') || msg.contains('storage') || msg.contains('enospc')) {
    return '[$phase] 存储空间不足。请清理设备存储后重试。';
  }
  if (msg.contains('permission') || msg.contains('access') || msg.contains('denied')) {
    return '[$phase] 权限不足。请检查存储权限设置。';
  }
  if (msg.contains('format') || msg.contains('invalid') || msg.contains('corrupt')) {
    return '[$phase] 数据格式错误或文件损坏。请确认压缩包完整且为本应用导出。';
  }
  if (msg.contains('file') && msg.contains('not found')) {
    return '[$phase] 找不到文件。部分数据可能已被删除或移动。';
  }
  if (msg.contains('path')) {
    return '[$phase] 路径错误。$e';
  }
  return '[$phase] $e';
}

/// 格式化文件大小
String formatFileSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
}

/// 判断路径是否为公共下载目录（用户可在文件管理器中直接找到）
bool _isPublicDownloadPath(String path) {
  return (path.contains('/Download') || path.contains('/sdcard/Download')) &&
      !path.contains('Android/data');
}

/// 显示导出完成对话框：路径、复制、打开、分享、保存到文件夹
void showExportResultDialog(
  BuildContext context,
  String filePath,
  int fileSizeBytes, {
  String shareText = '数据导出',
  bool showShareButton = true,
  bool showSaveToFolderButton = false,  // 大文件时显示，便于用户选择文件夹保存
  bool savedToPublicDownloads = false,  // 已保存到公共下载目录时，简化界面，不显示打开文件
}) {
  if (!context.mounted) return;
  final isPublic = savedToPublicDownloads || _isPublicDownloadPath(filePath);
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green),
          SizedBox(width: 8),
          Text('导出完成'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件大小：${formatFileSize(fileSizeBytes)}', style: const TextStyle(fontWeight: FontWeight.bold)),
            if (isPublic) ...[
              const SizedBox(height: 12),
              const Text('已保存到下载目录，请在文件管理器的「下载」中查看。', style: TextStyle(fontSize: 14, color: Colors.green)),
            ],
            const SizedBox(height: 8),
            const Text('保存位置：', style: TextStyle(fontSize: 12, color: Colors.grey)),
            SelectableText(filePath, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
      actions: [
        if (isPublic)
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('直达'),
            onPressed: () async {
              try {
                if (Platform.isAndroid) {
                  final dirPath = p.dirname(filePath);
                  await openFileManager(
                    androidConfig: AndroidConfig(
                      folderType: AndroidFolderType.other,
                      folderPath: dirPath,
                    ),
                  );
                } else {
                  await openFileManager();
                }
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('无法打开: $e')));
                }
              }
            },
          )
        else
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制路径'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: filePath));
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('路径已复制到剪贴板')));
            },
          ),
        if (!isPublic)
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('打开文件'),
            onPressed: () async {
              final result = await OpenFilex.open(filePath);
              if (result.type != ResultType.done && ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('打开失败: ${result.message}')));
              }
            },
          ),
        if (showShareButton)
          TextButton.icon(
            icon: const Icon(Icons.share, size: 18),
            label: const Text('分享'),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await Share.shareXFiles([XFile(filePath)], text: shareText);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('分享失败: $e')));
                }
              }
            },
          ),
        if (showSaveToFolderButton && !isPublic)
          TextButton.icon(
            icon: const Icon(Icons.save_alt, size: 18),
            label: const Text('保存到文件夹'),
            onPressed: () async {
              final destPath = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择保存位置');
              if (destPath == null || destPath.isEmpty) return;
              final src = File(filePath);
              final dest = File(p.join(destPath, p.basename(filePath)));
              try {
                await src.copy(dest.path);
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('已保存到：$destPath'), backgroundColor: Colors.green),
                  );
                }
              } catch (_) {
                // Android 10+：FilePicker 返回的路径往往无写入权限，File.copy 会失败
                // 回退：仅当 getDownloadsDirectory 返回公共目录时才复制（OPPO 等设备可能返回应用私有路径，用户无法访问）
                if (!ctx.mounted) return;
                try {
                  final downloadsDir = await getDownloadsDirectory();
                  final isPublicPath = downloadsDir != null &&
                      !downloadsDir.path.contains('Android/data');
                  if (downloadsDir != null && isPublicPath) {
                    await downloadsDir.create(recursive: true);
                    final fallbackDest = File(p.join(downloadsDir.path, p.basename(filePath)));
                    await src.copy(fallbackDest.path);
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text('已保存到下载目录：${downloadsDir.path}'),
                          backgroundColor: Colors.green,
                          duration: const Duration(seconds: 5),
                        ),
                      );
                    }
                    return;
                  }
                } catch (__) {}
                // 回退也失败：提示用户。大文件(>500MB)分享会卡死闪退，改用「打开文件」引导
                if (!ctx.mounted) return;
                final bool tooLargeToShare = fileSizeBytes > kShareSizeLimitBytes;
                showDialog(
                  context: ctx,
                  builder: (dctx) => AlertDialog(
                    title: const Text('保存失败'),
                    content: Text(
                      tooLargeToShare
                          ? '由于系统限制，无法直接保存到所选文件夹。\n\n'
                            '文件较大，分享功能可能无响应。请点击「打开文件」，用文件管理器打开后，选择「复制」或「移动」到您想保存的位置（如 oppo share）。'
                          : '由于系统限制，无法直接保存到所选文件夹。\n\n'
                            '请使用「分享」按钮，在分享菜单中选择「保存到文件」或「文件」应用，即可将文件保存到您选择的位置。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dctx),
                        child: const Text('关闭'),
                      ),
                      if (tooLargeToShare)
                        TextButton.icon(
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('打开文件'),
                          onPressed: () async {
                            Navigator.pop(dctx);
                            Navigator.pop(ctx);
                            try {
                              await OpenFilex.open(filePath);
                            } catch (e) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('打开失败: $e')));
                              }
                            }
                          },
                        )
                      else
                        TextButton.icon(
                          icon: const Icon(Icons.share, size: 18),
                          label: const Text('分享保存'),
                          onPressed: () async {
                            Navigator.pop(dctx);
                            Navigator.pop(ctx);
                            try {
                              await Share.shareXFiles([XFile(filePath)], text: shareText);
                            } catch (e) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('分享失败: $e')));
                              }
                            }
                          },
                        ),
                    ],
                  ),
                );
              }
            },
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 显示导出/导入错误（弹窗，便于用户完整查看）
void showExportImportErrorDialog(BuildContext context, String title, String message) {
  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(color: Colors.red)),
      content: SingleChildScrollView(
        child: Text(message, style: const TextStyle(fontSize: 14)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
