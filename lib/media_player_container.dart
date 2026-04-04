import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'widgets/video_player_widget.dart'; // 确保正确导入 VideoPlayerWidget
import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'media_selection_dialog.dart'; // 导入媒体选择对话框
import 'models/media_item.dart'; // 添加MediaItem类的导入
import 'models/media_type.dart'; // 导入MediaType枚举
import 'services/logger.dart';
import 'media_player_settings.dart';
import 'widgets/ken_burns_image_display.dart';
import 'widgets/zoom_pan_edge_image_display.dart';
import 'widgets/fit_width_blur_static_image.dart';

enum MediaMode { none, manual, auto }

class MediaPlayerContainer extends StatefulWidget {
  const MediaPlayerContainer({super.key});

  @override
  MediaPlayerContainerState createState() => MediaPlayerContainerState();
}

class MediaPlayerContainerState extends State<MediaPlayerContainer> {
  MediaMode _mediaMode = MediaMode.none;
  Timer? _mediaTimer;
  List<Map<String, dynamic>> _mediaList = [];
  final Random _random = Random();
  Widget? _mediaWidget;
  VideoPlayerWidget? _currentVideoWidget; // 保存当前的VideoPlayerWidget实例
  String? _selectedDirectory;
  late final DatabaseService _databaseService;
  Map<String, dynamic>? _currentPlayingMedia; // 添加当前正在播放的媒体项

  Duration _imageDuration = const Duration(seconds: 5);
  MediaImageDisplayMode _imageMode = MediaImageDisplayMode.fitWidth;
  double _zoomMax = 3.0;
  MediaPlaybackOrder _playbackOrder = MediaPlaybackOrder.random;
  bool _panClockwise = true;
  double _imagePanRoamCoverage = 0.28;
  int _sequentialIndex = 0;

  @override
  void initState() {
    super.initState();
    _databaseService = getService<DatabaseService>();
    _loadSelectedDirectory();
  }

  Future<void> _loadSelectedDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await loadMediaPlayerSettings(prefs);
    setState(() {
      _selectedDirectory = prefs.getString('selected_media_directory') ?? 'root';
      _imageDuration = settings.imageDuration;
      _imageMode = settings.imageMode;
      _zoomMax = settings.zoomMaxScale;
      _playbackOrder = settings.playbackOrder;
      _panClockwise = settings.panClockwise;
      _imagePanRoamCoverage = settings.imagePanRoamCoverage;
      Logger.i('Loaded selected directory: $_selectedDirectory');
    });
    await _loadMediaList(); // 确保加载目录后立即加载媒体列表
  }

  void showMediaPlayerSettings() {
    showMediaPlayerSettingsDialog(
      context: context,
      initial: MediaPlayerSettingsSnapshot(
        imageDuration: _imageDuration,
        imageMode: _imageMode,
        zoomMaxScale: _zoomMax,
        playbackOrder: _playbackOrder,
        panClockwise: _panClockwise,
        imagePanRoamCoverage: _imagePanRoamCoverage,
      ),
      onApply: (snap) async {
        setState(() {
          _imageDuration = snap.imageDuration;
          _imageMode = snap.imageMode;
          _zoomMax = snap.zoomMaxScale;
          _playbackOrder = snap.playbackOrder;
          _panClockwise = snap.panClockwise;
          _imagePanRoamCoverage = snap.imagePanRoamCoverage;
        });
        await _loadMediaList();
      },
    );
  }

  void _sortMediaListInPlace(List<Map<String, dynamic>> list) {
    if (_playbackOrder != MediaPlaybackOrder.sequential) return;
    list.sort((a, b) {
      final da = '${a['date_added'] ?? ''}';
      final db = '${b['date_added'] ?? ''}';
      final c = da.compareTo(db);
      if (c != 0) return c;
      return '${a['path']}'.compareTo('${b['path']}');
    });
  }


  Future<void> _saveSelectedDirectory(String directory) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_media_directory', directory);
    Logger.i('Saved selected directory: $directory');
  }

  Future<void> _loadMediaList() async {
    setState(() {
      _mediaList = []; // 先清空列表，避免在加载过程中显示旧的媒体
    });
    
    List<Map<String, dynamic>> mediaList = await _getMediaList();
    _sortMediaListInPlace(mediaList);

    if (mounted) {
      setState(() {
        _mediaList = mediaList;
        Logger.i('加载了 ${_mediaList.length} 个媒体文件');

        // 仅在调试模式下打印媒体列表详情
        for (var media in _mediaList) {
          Logger.d('媒体文件: ${media['path']}, 类型: ${media['type']}');
        }
      });
      if (_mediaList.isEmpty) {
        Logger.w('目录 $_selectedDirectory 中没有找到媒体文件');
        setState(() {
          _mediaWidget = Center(child: Text('该目录中没有媒体文件'));
          _currentPlayingMedia = null;
        });
      } else if (_mediaMode != MediaMode.none) {
        // 如果之前在播放，重新开始播放
        _showNextMedia();
      }
    }
  }

  Future<List<Map<String, dynamic>>> _getMediaList() async {
    try {
      await _databaseService.ensureMediaItemsTableExists();
      List<Map<String, dynamic>> mediaFiles = [];

      if (_selectedDirectory == 'root') {
        // 如果选择的是"整个媒体库"，递归加载所有媒体文件
        Logger.i('加载整个媒体库的文件');
        mediaFiles = await _getAllMediaFiles('root');
      } else {
        // 如果选择的是具体目录，只加载该目录下的媒体文件
        Logger.i('加载目录 $_selectedDirectory 下的文件');
        final db = await _databaseService.database;
        List<Map<String, dynamic>> dbItems = await db.query(
          'media_items',
          where: 'type IN (?, ?) AND directory = ?',
          whereArgs: [0, 1, _selectedDirectory],
        );
        
        // 验证文件是否存在
        for (var item in dbItems) {
          final String path = item['path'];
          final File file = File(path);
          
          if (await file.exists()) {
            mediaFiles.add(item);
          } else {
            Logger.w('文件不存在，从数据库中移除: $path');
            await _databaseService.deleteMediaItem(item['id']);
          }
        }
      }

      Logger.i('找到 ${mediaFiles.length} 个有效媒体文件');
      return mediaFiles;
    } catch (e) {
      Logger.e('获取媒体列表时出错', e);
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _getAllMediaFiles(String directoryId) async {
    List<Map<String, dynamic>> allMediaFiles = [];
    final db = await _databaseService.database;

    // 获取当前目录下的所有项
    final List<Map<String, dynamic>> items = await db.query(
      'media_items',
      where: 'directory = ?',
      whereArgs: [directoryId],
    );
    Logger.d('目录 $directoryId 下的项: ${items.length} 个');

    for (var item in items) {
      if (item['type'] == 3) {
        // 如果是文件夹，递归加载其下的文件
        Logger.d('发现文件夹: ${item['name']}, ID: ${item['id']}');
        final subFiles = await _getAllMediaFiles(item['id']);
        allMediaFiles.addAll(subFiles);
      } else if (item['type'] == 0 || item['type'] == 1) {
        // 如果是图片或视频文件，检查文件是否存在
        final String path = item['path'];
        final File file = File(path);
        
        if (await file.exists()) {
          Logger.d('发现媒体文件: ${item['name']}, 路径: $path, 类型: ${item['type']}');
          allMediaFiles.add(item);
        } else {
          Logger.w('文件不存在，跳过: $path');
          // 考虑清理数据库中不存在的文件记录
          try {
            await _databaseService.deleteMediaItem(item['id']);
            Logger.i('已从数据库删除不存在的文件记录: ${item['id']}');
          } catch (e) {
            Logger.w('清理数据库记录失败: $e');
          }
        }
      }
    }

    return allMediaFiles;
  }

  void playCurrentMedia() {
    Logger.d('playCurrentMedia called');
    playManual();
  }

  void stopMedia() {
    Logger.d('stopMedia called');
    stop();
  }

  void playContinuously() {
    Logger.d('playContinuously called');
    playAuto();
  }

  void playManual() {
    final wasNone = _mediaMode == MediaMode.none;
    if (wasNone && _playbackOrder == MediaPlaybackOrder.sequential) {
      _sequentialIndex = 0;
    }
    setState(() {
      _mediaMode = MediaMode.manual;
    });
    _showNextMedia();
  }

  void playAuto() {
    final wasNone = _mediaMode == MediaMode.none;
    if (wasNone && _playbackOrder == MediaPlaybackOrder.sequential) {
      _sequentialIndex = 0;
    }
    setState(() {
      _mediaMode = MediaMode.auto;
    });
    _showNextMedia();
  }

  void stop() {
    setState(() {
      _mediaMode = MediaMode.none;
      _sequentialIndex = 0;
      _mediaWidget = null;
      _currentVideoWidget = null;
      _currentPlayingMedia = null; // 清除当前播放媒体
      _mediaTimer?.cancel();
      _mediaTimer = null;
    });
  }

  Future<MediaItem?> getCurrentMedia() async {
    if (_currentPlayingMedia == null) return null;
    
    // 安全地获取type索引，确保不会超出范围
    final typeIndex = _currentPlayingMedia!['type'] as int;
    final safeTypeIndex = typeIndex < MediaType.values.length ? typeIndex : 0; // 如果索引越界，默认使用image类型
    
    return MediaItem(
      id: _currentPlayingMedia!['id'],
      name: _currentPlayingMedia!['name'],
      path: _currentPlayingMedia!['path'],
      type: MediaType.values[safeTypeIndex],
      directory: _currentPlayingMedia!['directory'],
      dateAdded: DateTime.parse(_currentPlayingMedia!['date_added']),
    );
  }

  // 获取当前的VideoPlayerWidget实例
  VideoPlayerWidget? getCurrentVideoWidget() {
    return _currentVideoWidget;
  }

  void _showNextMedia() async {
    if (_mediaList.isEmpty) {
      setState(() {
        _mediaWidget = Center(child: Text('没有可用的媒体文件'));
        _currentPlayingMedia = null; // 重置当前媒体
      });
      return;
    }

    try {
      // 尝试最多3次，避免无限循环
      for (int attempt = 0; attempt < 3; attempt++) {
        if (_mediaList.isEmpty) {
          setState(() {
            _mediaWidget = Center(child: Text('没有可用的媒体文件'));
            _currentPlayingMedia = null;
          });
          return;
        }

        final int mediaIndex = _playbackOrder == MediaPlaybackOrder.random
            ? _random.nextInt(_mediaList.length)
            : _sequentialIndex % _mediaList.length;
        final Map<String, dynamic> nextMedia = _mediaList[mediaIndex];

        // 先验证文件是否存在
        final String path = nextMedia['path'];
        final File file = File(path);

        if (!await file.exists()) {
          Logger.w('选择的文件不存在，从列表中移除: $path');

          await _databaseService.deleteMediaItem(nextMedia['id']);

          setState(() {
            _mediaList.removeAt(mediaIndex);
          });

          continue;
        }

        // 文件存在，设置为当前播放媒体
        _currentPlayingMedia = nextMedia;
        File? mediaFile = await _getFileFromMediaItem(nextMedia);

        if (mediaFile == null) {
          Logger.w('无法访问媒体文件: $path');

          setState(() {
            _mediaList.removeAt(mediaIndex);
          });

          continue;
        }

        void advanceSequentialCursor() {
          if (_playbackOrder == MediaPlaybackOrder.sequential) {
            _sequentialIndex = (_sequentialIndex + 1) % _mediaList.length;
          }
        }

        // 成功获取到文件，显示相应媒体
        if (nextMedia['type'] == 0) {
          advanceSequentialCursor();
          // 图片
          if (_imageMode == MediaImageDisplayMode.kenBurns) {
            setState(() {
              _mediaWidget = KenBurnsImageDisplay(
                key: ValueKey('${nextMedia['path']}_ken_$_mediaMode'),
                imageFile: mediaFile,
                animationDuration: _imageDuration,
                maxScale: _zoomMax,
                loop: _mediaMode == MediaMode.manual,
                onAnimationComplete: _mediaMode == MediaMode.auto
                    ? () {
                        if (_mediaMode == MediaMode.auto) {
                          _showNextMedia();
                        }
                      }
                    : null,
              );
            });
          } else if (_imageMode == MediaImageDisplayMode.zoomPanEdge) {
            setState(() {
              _mediaWidget = ZoomPanEdgeImageDisplay(
                key: ValueKey(
                  '${nextMedia['path']}_zpan_$_mediaMode'
                  '_${_imagePanRoamCoverage.toStringAsFixed(2)}',
                ),
                imageFile: mediaFile,
                totalDuration: _imageDuration,
                maxScale: _zoomMax,
                clockwise: _panClockwise,
                panPathCoverage: _imagePanRoamCoverage,
                loop: _mediaMode == MediaMode.manual,
                onAnimationComplete: _mediaMode == MediaMode.auto
                    ? () {
                        if (_mediaMode == MediaMode.auto) {
                          _showNextMedia();
                        }
                      }
                    : null,
              );
            });
          } else {
            setState(() {
              _mediaWidget = FitWidthBlurStaticImage(file: mediaFile);
            });

            if (_mediaMode == MediaMode.auto) {
              _mediaTimer?.cancel();
              _mediaTimer = Timer(_imageDuration, () {
                if (_mediaMode == MediaMode.auto) {
                  _showNextMedia();
                }
              });
            }
          }

          return;
        } else if (nextMedia['type'] == 1) {
          advanceSequentialCursor();
          // 视频
          setState(() {
            _currentVideoWidget = VideoPlayerWidget(
              key: ValueKey(nextMedia['path']),
              file: File(nextMedia['path']!),
              onVideoEnd: () {
                if (_mediaMode == MediaMode.auto) {
                  _showNextMedia();
                }
              },
              looping: false,
              forceManualLoop: _mediaMode == MediaMode.manual,
            );
            _mediaWidget = _currentVideoWidget;
          });

          return;
        }

        Logger.w('不支持的媒体类型: ${nextMedia['type']}');
        continue;
      }

      // 如果尝试多次后仍未成功，显示错误信息
      setState(() {
        _mediaWidget = Center(child: Text('无法加载媒体文件，请检查媒体库'));
        _currentPlayingMedia = null;
      });
    } catch (e) {
      Logger.e('显示媒体时出错', e);
      setState(() {
        _mediaWidget = Center(child: Text('加载媒体时出错'));
        _mediaTimer?.cancel();
        _currentPlayingMedia = null; // 出错时重置当前媒体
      });
    }
  }

  Future<File?> _getFileFromMediaItem(Map<String, dynamic> mediaItem) async {
    try {
      String path = mediaItem['path'];
      File file = File(path);
      
      if (await file.exists()) {
        try {
          // 尝试简单读取操作验证文件可读
          await file.openRead(0, 1).first;
          return file;
        } catch (readError) {
          Logger.w('文件读取权限问题: $readError');

          try {
            // 试图创建一个临时副本来访问只读文件
            return await _ensureFileAccessible(path);
          } catch (copyError) {
            Logger.w('无法创建临时副本: $copyError');
            return null;
          }
        }
      }
      
      Logger.w('文件不存在: $path');
      return null;
    } catch (e) {
      Logger.e('获取媒体文件时出错', e);
      return null;
    }
  }

  void selectMediaSource() {
    Logger.d('selectMediaSource called!');
    _showMediaSourceSelectionDialog();
  }

  void _showMediaSourceSelectionDialog() {
    Logger.d('Showing media source selection dialog');
    showDialog(
      context: context,
      barrierDismissible: true,  // 允许点击外部关闭对话框
      builder: (BuildContext dialogContext) => MediaSelectionDialog(
        selectedDirectory: _selectedDirectory,  // 传入当前选中的目录
        onDirectorySelected: (directory) async {
          if (directory != _selectedDirectory) {
            setState(() {
              _selectedDirectory = directory;
              _currentPlayingMedia = null; // 选择新的媒体源时重置当前播放
              _mediaWidget = null; // 清除当前显示的媒体
              _currentVideoWidget = null;
              _mediaMode = MediaMode.none; // 停止播放模式
              _mediaTimer?.cancel(); // 取消自动播放定时器
            });
            
            await _saveSelectedDirectory(directory);
            await _loadMediaList(); // 重新加载媒体列表
            Logger.i('已选择目录并加载新的媒体列表: $directory');
          }
          // 选择完成后关闭对话框
          Navigator.of(dialogContext).pop();
        },
      ),
    ).then((_) {
      Logger.d('Dialog closed');
    });
  }

  @override
  void dispose() {
    _mediaTimer?.cancel();
    super.dispose();
  }

  // 新增方法: 移动当前媒体到指定目录
  Future<bool> moveCurrentMedia(BuildContext context) async {
    if (_currentPlayingMedia == null) {
      _showMessage(context, '没有正在播放的媒体文件');
      return false;
    }
    
    try {
      // 显示移动对话框
      final List<Map<String, dynamic>> availableFolders = await _getAllAvailableFolders();
      
      if (!context.mounted) return false;
      
      final String? targetDirectory = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.white.withAlpha((0.6 * 255).round()), // 增加透明度（使用 withAlpha 以避免弃用警告）
          title: Container(
            padding: EdgeInsets.zero,
            height: 30,
            child: const Text('移动到', style: TextStyle(fontSize: 14)),
          ),
          titlePadding: const EdgeInsets.only(left: 12, top: 8, bottom: 0),
          contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          content: SizedBox(
            width: MediaQuery.of(context).size.width * 0.9, // 加宽面板
            height: MediaQuery.of(context).size.height * 0.7, // 加高面板
            child: Wrap(
              spacing: 4, // 水平间距
              runSpacing: 2, // 垂直间距
              children: [
                // 根目录选项
                SizedBox(
                  width: (MediaQuery.of(context).size.width * 0.9 - 20) / 2, // 计算每个项的宽度
                  height: 32, // 固定高度
                  child: ListTile(
                    dense: true,
                    visualDensity: VisualDensity(horizontal: 0, vertical: -4), // 进一步压缩
                    contentPadding: EdgeInsets.symmetric(horizontal: 4),
                    title: const Text('根目录', style: TextStyle(fontSize: 13)),
                    onTap: () => Navigator.of(context).pop('root'),
                  ),
                ),
                // 其他文件夹选项
                ...availableFolders.map((folder) {
                  return SizedBox(
                    width: (MediaQuery.of(context).size.width * 0.9 - 20) / 2, // 计算每个项的宽度
                    height: 32, // 固定高度
                    child: ListTile(
                      dense: true,
                      visualDensity: VisualDensity(horizontal: 0, vertical: -4), // 进一步压缩
                      contentPadding: EdgeInsets.symmetric(horizontal: 4),
                      title: Text(folder['name'], style: const TextStyle(fontSize: 13)),
                      onTap: () => Navigator.of(context).pop(folder['id']),
                    ),
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('取消', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
      
      if (targetDirectory == null) return false;
      
      // 检查目标是否与当前目录相同
      if (_currentPlayingMedia!['directory'] == targetDirectory) {
        if (context.mounted) {
          _showMessage(context, '媒体文件已在所选目录中');
        }
        return false;
      }
      
      // 获取当前媒体信息的完整副本和索引
      final currentMedia = Map<String, dynamic>.from(_currentPlayingMedia!);
      final int currentIndex = _mediaList.indexWhere((media) => media['id'] == currentMedia['id']);
      
      // 如果是只读文件，我们仍然可以更新数据库记录，但不能移动实际文件
      try {
        // 获取文件信息
        final File file = File(currentMedia['path']);
        if (await file.exists()) {
          // 检查文件是否可写（我们这里只是检测数据库记录）
          // 对于只读文件，我们只更新数据库记录
          Logger.i('文件存在: ${currentMedia['path']}，更新数据库记录');
        }
      } catch (fileError) {
        Logger.w('检查文件时出错: $fileError');
         // 我们仍然可以继续更新数据库记录
      }
      
      // 更新数据库记录
      await _databaseService.updateMediaItem({
        'id': currentMedia['id'],
        'name': currentMedia['name'],
        'path': currentMedia['path'],
        'type': currentMedia['type'],
        'directory': targetDirectory,
        'date_added': currentMedia['date_added'] ?? DateTime.now().millisecondsSinceEpoch,
      });
      
      // 立即从当前列表中移除该媒体
      if (currentIndex != -1) {
        setState(() {
          _mediaList.removeAt(currentIndex);
        });
      }
      
      if (!context.mounted) return false;
      
      // 如果列表为空，停止播放
      if (_mediaList.isEmpty) {
        stop();
        return true;
      }
      
      // 如果删除的是当前播放的媒体，立即播放下一个
      if (_currentPlayingMedia != null && _currentPlayingMedia!['id'] == currentMedia['id']) {
        _showNextMedia();
      }
      
      return true;
    } catch (e) {
      Logger.e('移动媒体文件时出错', e);
      if (context.mounted) {
        _showMessage(context, '移动媒体文件时出错: $e');
      }
      return false;
    }
  }
  
  // 获取所有可用的文件夹
  Future<List<Map<String, dynamic>>> _getAllAvailableFolders() async {
    try {
      final db = await _databaseService.database;
      
      // 获取所有文件夹
      final List<Map<String, dynamic>> allFolders = await db.query(
        'media_items',
        where: 'type = ?',
        whereArgs: [3], // 文件夹类型
      );
      
      return allFolders;
    } catch (e) {
      Logger.e('获取可用文件夹时出错', e);
      return [];
    }
  }
  
  // 辅助方法：处理文件读取权限问题并提供解决方案
  Future<File> _ensureFileAccessible(String filePath) async {
    final originalFile = File(filePath);
    
    try {
      // 仅读取前 8KB 检查权限，避免大文件 OOM
      await originalFile.openRead(0, 8192).first;
      return originalFile; // 如果能读取，直接返回原始文件
    } catch (e) {
      Logger.w('文件访问出错，创建临时副本: $e');

     // 创建临时文件副本（流式复制，避免大文件 OOM）
     final tempDir = await getTemporaryDirectory();
     final String fileName = path.basename(filePath);
     final String tempPath = '${tempDir.path}/$fileName';

     final tempFile = File(tempPath);

     try {
       await originalFile.openRead().pipe(tempFile.openWrite());
       return tempFile;
     } catch (copyError) {
       Logger.w('创建临时副本失败: $copyError');
         throw Exception('无法访问文件: $filePath，原因: $copyError');
       }
     }
   }

   // 新增方法: 导出当前媒体
   Future<bool> exportCurrentMedia(BuildContext context) async {
     if (_currentPlayingMedia == null) {
       _showMessage(context, '没有正在播放的媒体文件');
       return false;
     }

     try {
       // 获取文件路径
       final String filePath = _currentPlayingMedia!['path'];

       // 创建文件对象
       final File originalFile = File(filePath);

       if (!await originalFile.exists()) {
         _showMessage(context, '文件不存在: $filePath');
         return false;
       }

       // 确保文件可访问，可能需要创建临时副本
       File fileToShare = originalFile;
       bool needsCleanup = false;

       try {
         // 尝试直接分享原始文件
         await Share.shareXFiles([XFile(filePath)], subject: '分享: ${_currentPlayingMedia!['name']}');
       } catch (shareError) {
         Logger.w('直接分享文件失败，尝试创建临时副本: $shareError');

         try {
           // 确保文件可访问
           fileToShare = await _ensureFileAccessible(filePath);
           needsCleanup = fileToShare.path != filePath;

           // 使用临时文件分享
           await Share.shareXFiles([XFile(fileToShare.path)], subject: '分享: ${_currentPlayingMedia!['name']}');
         } catch (accessError) {
           Logger.w('文件访问错误: $accessError');
           // 分享失败时清理临时文件，避免堆积
           if (needsCleanup && fileToShare.path != filePath) {
             try {
               await fileToShare.delete();
             } catch (_) {}
           }
           if (!context.mounted) return false;
           _showMessage(context, '无法访问文件，导出失败');
           return false;
         }
       }

       // 如果使用了临时文件，在分享后清理
       if (needsCleanup) {
         try {
           await fileToShare.delete();
         } catch (e) {
           Logger.w('清理临时文件失败: $e');
           // 这不是关键错误，可以忽略
         }
       }

       if (!context.mounted) return false;
       return true;
     } catch (e) {
       Logger.e('导出媒体文件时出错', e);
       if (context.mounted) {
         _showMessage(context, '导出媒体文件时出错: $e');
       }
       return false;
     }
   }

   // 新增方法: 删除当前媒体 (无确认对话框直接删除)
   Future<bool> deleteCurrentMedia(BuildContext context) async {
     if (_currentPlayingMedia == null) {
       _showMessage(context, '没有正在播放的媒体文件');
       return false;
     }

     try {
       // 获取完整的媒体信息
       final String mediaId = _currentPlayingMedia!['id'];
       final String mediaName = _currentPlayingMedia!['name'];
       final String mediaPath = _currentPlayingMedia!['path'];
       final int currentIndex = _mediaList.indexWhere((media) => media['id'] == mediaId);

       // 先删除数据库记录
       await _databaseService.deleteMediaItem(mediaId);

       // 尝试删除文件
       try {
         final File file = File(mediaPath);
         if (await file.exists()) {
           await file.delete();
         }
       } catch (fileError) {
         // 文件可能是只读的，但数据库项已经删除，所以我们继续
         Logger.w('删除媒体文件时出错 (仅文件删除失败): $fileError');
         // 如果我们无法删除文件，这可能是因为文件在系统位置或只读位置，但数据库记录已经删除
       }

       // 立即从当前列表中移除该媒体
       if (currentIndex != -1) {
         setState(() {
           _mediaList.removeAt(currentIndex);
         });
       }

       if (!context.mounted) return false;

       // 如果列表为空，停止播放
       if (_mediaList.isEmpty) {
         stop();
         return true;
       }

       // 如果删除的是当前播放的媒体，立即播放下一个
       if (_currentPlayingMedia != null && _currentPlayingMedia!['id'] == mediaId) {
         _showNextMedia();
       }

       return true;
     } catch (e) {
       Logger.e('删除媒体文件时出错', e);
       if (context.mounted) {
         _showMessage(context, '删除媒体文件时出错: $e');
       }
       return false;
     }
   }

   /// 从当前列表中移除当前播放的媒体并切换到下一个。
   /// 用于文档编辑界面等场景：外部已更新数据库（如移动到回收站/收藏夹）后，
   /// 需要从展示列表中移除该项并自动播放下一个，与媒体页面的删除/收藏/移动行为一致。
   void removeCurrentAndPlayNext() {
     if (_currentPlayingMedia == null) return;
     final String currentId = _currentPlayingMedia!['id'];
     final int currentIndex = _mediaList.indexWhere((media) => media['id'] == currentId);
     if (currentIndex == -1) return;

     setState(() {
       _mediaList.removeAt(currentIndex);
     });

     if (_mediaList.isEmpty) {
       stop();
       return;
     }

     _showNextMedia();
   }

   // 辅助方法：显示消息
   void _showMessage(BuildContext context, String message) {
     ScaffoldMessenger.of(context).showSnackBar(
       SnackBar(content: Text(message)),
     );
   }

   // 新增方法：刷新媒体列表
   Future<void> refreshMediaList() async {
     Logger.d('刷新媒体列表...');
     await _loadMediaList();
   }

   @override
   Widget build(BuildContext context) {
     return _mediaWidget != null
         ? SizedBox.expand(child: _mediaWidget!)
         : Container();
   }
 }
