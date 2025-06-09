import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'video_player_widget.dart'; // 确保正确导入 VideoPlayerWidget
import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'media_selection_dialog.dart'; // 导入媒体选择对话框
import 'models/media_item.dart'; // 添加MediaItem类的导入
import 'models/media_type.dart'; // 导入MediaType枚举

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

  @override
  void initState() {
    super.initState();
    _databaseService = getService<DatabaseService>();
    _loadSelectedDirectory();
  }

  Future<void> _loadSelectedDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedDirectory = prefs.getString('selected_media_directory') ?? 'root';
      print('Loaded selected directory: $_selectedDirectory');
    });
    await _loadMediaList(); // 确保加载目录后立即加载媒体列表
  }

  Future<void> _saveSelectedDirectory(String directory) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_media_directory', directory);
    print('Saved selected directory: $directory');
  }

  Future<void> _loadMediaList() async {
    setState(() {
      _mediaList = []; // 先清空列表，避免在加载过程中显示旧的媒体
    });
    
    List<Map<String, dynamic>> mediaList = await _getMediaList();
    
    if (mounted) {
      setState(() {
        _mediaList = mediaList;
        print('加载了 ${_mediaList.length} 个媒体文件');
        
        // 仅在调试模式下打印媒体列表详情
        for (var media in _mediaList) {
          print('媒体文件: ${media['path']}, 类型: ${media['type']}');
        }
      });
      if (_mediaList.isEmpty) {
        print('目录 $_selectedDirectory 中没有找到媒体文件');
        setState(() {
          _mediaWidget = Center(child: Text('该目录中没有媒体文件'));
          _currentPlayingMedia = null;
        });
      } else if (_mediaMode != MediaMode.none) {
        // 如果之前在播放，重新开始播放
        _showRandomMedia();
      }
    }
  }

  Future<List<Map<String, dynamic>>> _getMediaList() async {
    try {
      await _databaseService.ensureMediaItemsTableExists();
      List<Map<String, dynamic>> mediaFiles = [];

      if (_selectedDirectory == 'root') {
        // 如果选择的是"整个媒体库"，递归加载所有媒体文件
        print('加载整个媒体库的文件');
        mediaFiles = await _getAllMediaFiles('root');
      } else {
        // 如果选择的是具体目录，只加载该目录下的媒体文件
        print('加载目录 $_selectedDirectory 下的文件');
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
            print('文件不存在，从数据库中移除: $path');
            await _databaseService.deleteMediaItem(item['id']);
          }
        }
      }

      print('找到 ${mediaFiles.length} 个有效媒体文件');
      return mediaFiles;
    } catch (e) {
      print('获取媒体列表时出错: $e');
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
    print('目录 $directoryId 下的项: ${items.length} 个');

    for (var item in items) {
      if (item['type'] == 3) {
        // 如果是文件夹，递归加载其下的文件
        print('发现文件夹: ${item['name']}, ID: ${item['id']}');
        final subFiles = await _getAllMediaFiles(item['id']);
        allMediaFiles.addAll(subFiles);
      } else if (item['type'] == 0 || item['type'] == 1) {
        // 如果是图片或视频文件，检查文件是否存在
        final String path = item['path'];
        final File file = File(path);
        
        if (await file.exists()) {
          print('发现媒体文件: ${item['name']}, 路径: $path, 类型: ${item['type']}');
          allMediaFiles.add(item);
        } else {
          print('文件不存在，跳过: $path');
          // 考虑清理数据库中不存在的文件记录
          try {
            await _databaseService.deleteMediaItem(item['id']);
            print('已从数据库删除不存在的文件记录: ${item['id']}');
          } catch (e) {
            print('清理数据库记录失败: $e');
          }
        }
      }
    }

    return allMediaFiles;
  }

  void playCurrentMedia() {
    print('playCurrentMedia called');
    playManual();
  }

  void stopMedia() {
    print('stopMedia called');
    stop();
  }

  void playContinuously() {
    print('playContinuously called');
    playAuto();
  }

  void playManual() {
    setState(() {
      _mediaMode = MediaMode.manual;
      _showRandomMedia();
    });
  }

  void playAuto() {
    setState(() {
      _mediaMode = MediaMode.auto;
      _showRandomMedia();
    });
  }

  void stop() {
    setState(() {
      _mediaMode = MediaMode.none;
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

  void _showRandomMedia() async {
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
        
        int randomIndex = _random.nextInt(_mediaList.length);
        Map<String, dynamic> randomMedia = _mediaList[randomIndex];
        
        // 先验证文件是否存在
        final String path = randomMedia['path'];
        final File file = File(path);
        
        if (!await file.exists()) {
          print('随机选择的文件不存在，从列表中移除: $path');
          
          // 从数据库和列表中移除不存在的文件
          await _databaseService.deleteMediaItem(randomMedia['id']);
          
          setState(() {
            _mediaList.removeAt(randomIndex);
          });
          
          // 继续尝试下一个随机文件
          continue;
        }
        
        // 文件存在，设置为当前播放媒体
        _currentPlayingMedia = randomMedia;
        File? mediaFile = await _getFileFromMediaItem(randomMedia);

        if (mediaFile == null) {
          print('无法访问媒体文件: $path');
          
          // 从列表中移除无法访问的文件
          setState(() {
            _mediaList.removeAt(randomIndex);
          });
          
          // 继续尝试下一个
          continue;
        }

        // 成功获取到文件，显示相应媒体
        if (randomMedia['type'] == 0) { // 图片
          setState(() {
            _mediaWidget = Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: FileImage(mediaFile),
                  fit: BoxFit.fitWidth, // 改为横向填满
                  alignment: Alignment.center, // 高度不足时居中
                ),
              ),
            );
          });
          
          if (_mediaMode == MediaMode.auto) {
            _mediaTimer?.cancel();
            _mediaTimer = Timer(Duration(seconds: 5), () {
              if (_mediaMode == MediaMode.auto) _showRandomMedia();
            });
          }
          
          // 成功显示，退出尝试循环
          return;
        } else if (randomMedia['type'] == 1) { // 视频
          setState(() {
            _currentVideoWidget = VideoPlayerWidget(
              key: ValueKey(randomMedia['path']),
              file: File(randomMedia['path']!),
              onVideoEnd: () {
                // 视频播放完成后，如果是自动播放模式，则切换到下一个媒体
                if (_mediaMode == MediaMode.auto) {
                  _showRandomMedia();
                }
              },
            );
            _mediaWidget = _currentVideoWidget;
          });
          
          // 成功显示，退出尝试循环
          return;
        }
      }
      
      // 如果尝试多次后仍未成功，显示错误信息
      setState(() {
        _mediaWidget = Center(child: Text('无法加载媒体文件，请检查媒体库'));
        _currentPlayingMedia = null;
      });
    } catch (e) {
      print('显示随机媒体时出错: $e');
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
          print('文件读取权限问题: $readError');
          
          try {
            // 试图创建一个临时副本来访问只读文件
            return await _ensureFileAccessible(path);
          } catch (copyError) {
            print('无法创建临时副本: $copyError');
            return null;
          }
        }
      }
      
      print('文件不存在: $path');
      return null;
    } catch (e) {
      print('获取媒体文件时出错: $e');
      return null;
    }
  }

  void selectMediaSource() {
    print('selectMediaSource called!');
    _showMediaSourceSelectionDialog();
  }

  void _showMediaSourceSelectionDialog() {
    print('Showing media source selection dialog');
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
            print('已选择目录并加载新的媒体列表: $directory');
          }
          // 选择完成后关闭对话框
          Navigator.of(dialogContext).pop();
        },
      ),
    ).then((_) {
      print('Dialog closed');
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
          backgroundColor: Colors.white.withOpacity(0.6), // 增加透明度
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
          print('文件存在: ${currentMedia['path']}，更新数据库记录');
        }
      } catch (fileError) {
        print('检查文件时出错: $fileError');
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
      _showMessage(context, '媒体文件已移动');
      
      // 如果列表为空，停止播放
      if (_mediaList.isEmpty) {
        stop();
        return true;
      }
      
      // 如果删除的是当前播放的媒体，立即播放下一个
      if (_currentPlayingMedia != null && _currentPlayingMedia!['id'] == currentMedia['id']) {
        _showRandomMedia();
      }
      
      return true;
    } catch (e) {
      print('移动媒体文件时出错: $e');
      if (context.mounted) {
        _showMessage(context, '移动媒体文件时出错: $e');
      }
      return false;
    }
  }
  
  // 获取所有可用的文件夹
  Future<List<Map<String, dynamic>>> _getAllAvailableFolders() async {
    try {
      List<Map<String, dynamic>> folders = [];
      final db = await _databaseService.database;
      
      // 获取所有文件夹
      final List<Map<String, dynamic>> allFolders = await db.query(
        'media_items',
        where: 'type = ?',
        whereArgs: [3], // 文件夹类型
      );
      
      return allFolders;
    } catch (e) {
      print('获取可用文件夹时出错: $e');
      return [];
    }
  }
  
  // 辅助方法：处理文件读取权限问题并提供解决方案
  Future<File> _ensureFileAccessible(String filePath) async {
    final originalFile = File(filePath);
    
    try {
      // 尝试简单的读操作来检查权限
      await originalFile.readAsBytes();
      return originalFile; // 如果能读取，直接返回原始文件
    } catch (e) {
      print('文件访问出错，创建临时副本: $e');
      
      // 创建临时文件副本
      final tempDir = await getTemporaryDirectory();
      final String fileName = path.basename(filePath);
      final String tempPath = '${tempDir.path}/$fileName';
      
      final tempFile = File(tempPath);
      
      try {
        // 尝试读取原始文件（即使是只读的）并写入临时文件
        final bytes = await originalFile.readAsBytes();
        await tempFile.writeAsBytes(bytes);
        return tempFile;
      } catch (copyError) {
        print('创建临时副本失败: $copyError');
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
      File fileToShare;
      bool needsCleanup = false;
      
      try {
        // 尝试直接分享原始文件
        await Share.shareXFiles([XFile(filePath)], subject: '分享: ${_currentPlayingMedia!['name']}');
        fileToShare = originalFile;
      } catch (shareError) {
        print('直接分享文件失败，尝试创建临时副本: $shareError');
        
        try {
          // 确保文件可访问
          fileToShare = await _ensureFileAccessible(filePath);
          needsCleanup = fileToShare.path != filePath;
          
          // 使用临时文件分享
          await Share.shareXFiles([XFile(fileToShare.path)], subject: '分享: ${_currentPlayingMedia!['name']}');
        } catch (accessError) {
          print('文件访问错误: $accessError');
          
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
          print('清理临时文件失败: $e');
          // 这不是关键错误，可以忽略
        }
      }
      
      if (!context.mounted) return false;
      _showMessage(context, '文件已导出');
      return true;
    } catch (e) {
      print('导出媒体文件时出错: $e');
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
        print('删除媒体文件时出错 (仅文件删除失败): $fileError');
        // 如果我们无法删除文件，这可能是因为文件在系统位置或只读位置，但数据库记录已经删除
      }
      
      // 立即从当前列表中移除该媒体
      if (currentIndex != -1) {
        setState(() {
          _mediaList.removeAt(currentIndex);
        });
      }
      
      if (!context.mounted) return false;
      _showMessage(context, '$mediaName 已删除');
      
      // 如果列表为空，停止播放
      if (_mediaList.isEmpty) {
        stop();
        return true;
      }
      
      // 如果删除的是当前播放的媒体，立即播放下一个
      if (_currentPlayingMedia != null && _currentPlayingMedia!['id'] == mediaId) {
        _showRandomMedia();
      }
      
      return true;
    } catch (e) {
      print('删除媒体文件时出错: $e');
      if (context.mounted) {
        _showMessage(context, '删除媒体文件时出错: $e');
      }
      return false;
    }
  }
  
  // 辅助方法：显示消息
  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // 新增方法：刷新媒体列表
  Future<void> refreshMediaList() async {
    print('刷新媒体列表...');
    await _loadMediaList();
  }

  @override
  Widget build(BuildContext context) {
    return _mediaWidget ?? Container();
  }
}