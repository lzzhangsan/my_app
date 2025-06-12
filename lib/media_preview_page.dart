import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'models/media_item.dart';
import 'models/media_type.dart';


enum MediaMode { none, manual, auto }

class MediaPreviewPage extends StatefulWidget {
  final List<MediaItem> mediaItems;
  final int initialIndex;

  const MediaPreviewPage({
    required this.mediaItems, 
    required this.initialIndex, 
    super.key
  });

  @override
  _MediaPreviewPageState createState() => _MediaPreviewPageState();
}

class _MediaPreviewPageState extends State<MediaPreviewPage> {
  late PageController _pageController;
  int _currentIndex = 0;
  final Map<int, VideoPlayerController> _videoControllers = {};
  final Map<int, ChewieController> _chewieControllers = {};
  final bool _isFullScreen = false;
  late final DatabaseService _dbService;
  MediaMode _mediaMode = MediaMode.none;
  Timer? _mediaTimer;

  @override
  void initState() {
    super.initState();
    _dbService = getService<DatabaseService>();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    
    // 预初始化当前页和相邻页的视频控制器
    _initializeVideoControllerAt(_currentIndex);
    if (_currentIndex > 0) {
      _initializeVideoControllerAt(_currentIndex - 1);
    }
    if (_currentIndex < widget.mediaItems.length - 1) {
      _initializeVideoControllerAt(_currentIndex + 1);
    }
    
    // 设置状态栏为透明
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _mediaTimer?.cancel();
    
    // 释放所有视频控制器
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    for (final controller in _chewieControllers.values) {
      controller.dispose();
    }
    
    // 恢复状态栏
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values
    );
    
    super.dispose();
  }

  Future<void> _initializeVideoControllerAt(int index) async {
    if (index < 0 || index >= widget.mediaItems.length) return;
    
    final item = widget.mediaItems[index];
    if (item.type != MediaType.video) return;
    
    try {
      if (!_videoControllers.containsKey(index)) {
        // 检查文件是否存在
        final File videoFile = File(item.path);
        if (!await videoFile.exists()) {
          return;
        }

        // 验证文件大小
        final fileSize = await videoFile.length();
        if (fileSize <= 0) {
          return;
        }

        final controller = VideoPlayerController.file(videoFile);
        _videoControllers[index] = controller;
        
        // 添加错误监听器
        controller.addListener(() {
          if (controller.value.hasError) {
          }
        });
        
        // 初始化带有超时处理
        bool initializeSuccessful = false;
        try {
          await controller.initialize().timeout(const Duration(seconds: 10));
          initializeSuccessful = controller.value.isInitialized;
        } catch (timeoutError) {
        }
        
        if (!initializeSuccessful) {
          if (_videoControllers.containsKey(index)) {
            _videoControllers[index]?.dispose();
            _videoControllers.remove(index);
          }
          return;
        }
        
        // 自动播放当前视频
        final bool shouldAutoPlay = index == _currentIndex;
        
        try {
          final chewieController = ChewieController(
            videoPlayerController: controller,
            autoPlay: shouldAutoPlay,
            looping: false,
            allowFullScreen: true,
            allowMuting: true,
            showControls: true,
            showControlsOnInitialize: true,
            deviceOrientationsAfterFullScreen: [DeviceOrientation.portraitUp],
            placeholder: Container(
              color: Colors.black,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
            errorBuilder: (context, errorMessage) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 42),
                    const SizedBox(height: 8),
                    Text(
                      '无法播放视频: $errorMessage',
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
            materialProgressColors: ChewieProgressColors(
              playedColor: Colors.red,
              handleColor: Colors.red,
              backgroundColor: Colors.white.withOpacity(0.3),
              bufferedColor: Colors.white.withOpacity(0.5),
            ),
            controlsSafeAreaMinimum: EdgeInsets.zero,
            showOptions: true,
            isLive: false,
            allowPlaybackSpeedChanging: true,
            draggableProgressBar: true,
            useRootNavigator: false,
            customControls: const MaterialControls(
              showPlayButton: false,
            ),
          );
          
          _chewieControllers[index] = chewieController;
          
          // 添加视频控制器状态变化监听
          controller.addListener(() {
            debugPrint('视频播放位置: ${controller.value.position}');
            debugPrint('缓冲进度: ${controller.value.buffered}');
            debugPrint('播放状态: ${controller.value.isPlaying}');
          });
          
          // 如果是当前页面，立即开始播放
          if (shouldAutoPlay && controller.value.isInitialized) {
            await controller.play();
          }
        } catch (chewieError) {
          if (_videoControllers.containsKey(index)) {
            await _videoControllers[index]?.pause();
            await _videoControllers[index]?.dispose();
            _videoControllers.remove(index);
          }
          return;
        }
        
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (_videoControllers.containsKey(index)) {
        _videoControllers[index]?.dispose();
        _videoControllers.remove(index);
      }
      if (_chewieControllers.containsKey(index)) {
        _chewieControllers[index]?.dispose();
        _chewieControllers.remove(index);
      }
    }
  }

  void _disposeVideoControllerAt(int index) {
    if (_videoControllers.containsKey(index)) {
      _videoControllers[index]?.pause();
    }
    
    if (_chewieControllers.containsKey(index)) {
      _chewieControllers[index]?.dispose();
      _chewieControllers.remove(index);
    }
    
    if (_videoControllers.containsKey(index)) {
      _videoControllers[index]?.dispose();
      _videoControllers.remove(index);
    }
  }
  
  void _cleanupUnusedControllers() {
    final List<int> indicesToKeep = [_currentIndex];
    if (_currentIndex > 0) indicesToKeep.add(_currentIndex - 1);
    if (_currentIndex < widget.mediaItems.length - 1) indicesToKeep.add(_currentIndex + 1);
    
    final List<int> indicesToRemove = _videoControllers.keys
        .where((index) => !indicesToKeep.contains(index))
        .toList();
    
    for (final index in indicesToRemove) {
      _disposeVideoControllerAt(index);
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    
    // 暂停上一页的视频
    if (_videoControllers.containsKey(_currentIndex - 1)) {
      _videoControllers[_currentIndex - 1]?.pause();
    }
    
    // 暂停下一页的视频
    if (_videoControllers.containsKey(_currentIndex + 1)) {
      _videoControllers[_currentIndex + 1]?.pause();
    }
    
    // 初始化相邻页面的视频控制器
    _initializeVideoControllerAt(index);
    if (index > 0) {
      _initializeVideoControllerAt(index - 1);
    }
    if (index < widget.mediaItems.length - 1) {
      _initializeVideoControllerAt(index + 1);
    }
    
    // 清理不需要的视频控制器
    _cleanupUnusedControllers();
    
    // 添加自动播放当前视频的逻辑
    _autoPlayCurrentVideo();
  }

  // 自动播放当前视频
  void _autoPlayCurrentVideo() {
    if (_currentIndex < 0 || _currentIndex >= widget.mediaItems.length) return;
    
    final currentItem = widget.mediaItems[_currentIndex];
    if (currentItem.type == MediaType.video) {
      // 确保视频控制器已初始化
      _initializeVideoControllerAt(_currentIndex).then((_) {
        if (_videoControllers.containsKey(_currentIndex) && 
            _videoControllers[_currentIndex]?.value.isInitialized == true) {
          _videoControllers[_currentIndex]?.play();
        }
      });
    }
  }

  void _shareMediaItem() async {
    final item = widget.mediaItems[_currentIndex];
    try {
      await Share.shareXFiles(
        [XFile(item.path)],
        subject: '分享: ${item.name}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享文件时出错: $e')),
        );
      }
    }
  }
  
  // 删除当前媒体项 - 无需确认
  Future<void> _deleteCurrentMediaItem() async {
    final item = widget.mediaItems[_currentIndex];
    
    try {
      // 1. 从数据库中删除
      try {
        await _dbService.deleteMediaItem(item.id);
      } catch (e) {
      }
      
      // 2. 尝试删除实际文件
      try {
        final file = File(item.path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
      }
      
      // 3. 从当前列表中移除
      if (!mounted) return;
      
      // 判断是否还有媒体项
      if (widget.mediaItems.length <= 1) {
        // 如果当前是最后一个媒体项，则关闭预览页面
        Navigator.of(context).pop(true); // 返回true表示有更改发生
        return;
      }
      
      // 保存当前索引，确定是移动到下一个还是前一个
      int nextIndex = _currentIndex;
      if (_currentIndex >= widget.mediaItems.length - 1) {
        // 如果删除的是最后一项，则移到前一项
        nextIndex = _currentIndex - 1;
      }
      // 否则保持当前索引，因为删除后当前索引会对应下一项
      
      setState(() {
        widget.mediaItems.removeAt(_currentIndex);
        
        // 调整当前索引
        _currentIndex = nextIndex;
        
        // 重新加载当前页面
        _pageController.jumpToPage(_currentIndex);
      });
      
      // 如果新的当前项是视频，立即播放
      _autoPlayCurrentVideo();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('媒体项已删除')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
    }
  }
  
  // 移动当前媒体项 - 完全使用媒体管理页面中的移动功能实现
  Future<void> _moveCurrentMediaItem() async {
    final item = widget.mediaItems[_currentIndex];
    List<MediaItem> folders = [];

    try {
      // 获取根目录下的文件夹
      final rootItems = await _dbService.getMediaItems('root');
      final rootFolders = rootItems
          .where((item) => item['type'] == MediaType.folder.index)
          .map((item) => MediaItem.fromMap(item))
          .toList();
          
      folders = rootFolders;
      
      // 递归获取子文件夹（如果需要）
      for (var folder in rootFolders) {
        try {
          final subItems = await _dbService.getMediaItems(folder.id);
          final subFolders = subItems
              .where((item) => item['type'] == MediaType.folder.index)
              .map((item) => MediaItem.fromMap(item))
              .toList();
          if (subFolders.isNotEmpty) {
            folders.addAll(subFolders);
          }
        } catch (e) {
        }
      }
    } catch (e) {
    }
    
    // 在对话框中显示文件夹列表
    final MediaItem? targetFolder = await showDialog<MediaItem?>(
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
                  onTap: () => Navigator.pop(context, MediaItem(
                    id: 'root',
                    name: '根目录',
                    path: '',
                    type: MediaType.folder,
                    directory: '',
                    dateAdded: DateTime.now(),
                  )),
                ),
              ),
              // 其他文件夹选项
              ...folders.map((folder) => SizedBox(
                width: (MediaQuery.of(context).size.width * 0.9 - 20) / 2, // 计算每个项的宽度
                height: 32, // 固定高度
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity(horizontal: 0, vertical: -4), // 进一步压缩
                  contentPadding: EdgeInsets.symmetric(horizontal: 4),
                  title: Text(folder.name, style: const TextStyle(fontSize: 13)),
                  onTap: () => Navigator.pop(context, folder),
                ),
              )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
    
    // 如果用户取消，则不执行任何操作
    if (targetFolder == null) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white.withOpacity(0.8),
        content: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 20),
            Text('正在移动媒体...', style: TextStyle(fontSize: 13))
          ],
        ),
      ),
    );
    
    try {
      // 使用媒体管理页面中的移动方法
      final updatedItem = MediaItem(
        id: item.id,
        name: item.name,
        path: item.path,
        type: item.type,
        directory: targetFolder.id,
        dateAdded: item.dateAdded,
      );
      
      final result = await _dbService.updateMediaItem(updatedItem.toMap());
      if (result <= 0) {
        throw Exception('媒体项更新失败');
      }
      
      if (mounted) {
        Navigator.of(context).pop();
      }
      
      // 从当前列表中移除
      if (!mounted) return;
      
      // 保存当前索引，确定是移动到下一个还是前一个
      int nextIndex = _currentIndex;
      if (_currentIndex >= widget.mediaItems.length - 1) {
        // 如果移动的是最后一项，则移到前一项
        nextIndex = _currentIndex - 1;
      }
      // 否则保持当前索引，因为移动后当前索引会对应下一项
      
      setState(() {
        widget.mediaItems.removeAt(_currentIndex);
        
        // 如果没有更多媒体项，关闭预览页面
        if (widget.mediaItems.isEmpty) {
          Navigator.of(context).pop(true); // 返回true表示有更改发生
          return;
        }
        
        // 调整当前索引
        _currentIndex = nextIndex;
        
        // 重新加载当前页面
        _pageController.jumpToPage(_currentIndex);
      });
      
      // 如果新的当前项是视频，立即播放
      _autoPlayCurrentVideo();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已移动到 ${targetFolder.name}')),
      );
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // 关闭进度对话框
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移动失败: $e')),
        );
      }
    }
  }

  Widget _buildImagePreview(MediaItem item) {
    return GestureDetector(
      onTap: () => _toggleControls(),
      child: Center(
        child: InteractiveViewer(
          clipBehavior: Clip.none,
          panEnabled: true,
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.file(
            File(item.path),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.broken_image, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    '无法加载图片: $error',
                    style: const TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
                  )
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildVideoPreview(MediaItem item, int index) {
    if (!_videoControllers.containsKey(index) || !_chewieControllers.containsKey(index)) {
      // 视频控制器尚未初始化，显示加载中
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 8),
            Text(
              '正在加载视频...',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    final videoController = _videoControllers[index]!;
    final chewieController = _chewieControllers[index]!;
    
    if (videoController.value.hasError) {
      // 视频加载出错
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error, color: Colors.red, size: 48),
            const SizedBox(height: 8),
            Text(
              '视频加载失败: ${videoController.value.errorDescription}',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // 添加详细调试信息
    final screenSize = MediaQuery.of(context).size;
    final videoSize = videoController.value.size;
    final videoPath = item.path;
    final aspectRatio = videoController.value.aspectRatio;
    
    return Stack(
      children: [
        // 视频播放器
        Container(
          color: Colors.transparent,
          child: Center(
            child: GestureDetector(
              onDoubleTap: () {
                if (videoController.value.isPlaying) {
                  videoController.pause();
                } else {
                  videoController.play();
                }
              },
              child: Container(
                color: Colors.transparent,
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.contain, // 使用contain而不是cover，确保视频完整显示
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: videoController.value.size.width,
                      height: videoController.value.size.height,
                      child: Theme(
                        data: ThemeData.light().copyWith(
                          platform: TargetPlatform.iOS,
                        ),
                        child: Chewie(controller: chewieController),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 主内容 - 媒体预览
          PageView.builder(
            controller: _pageController,
            itemCount: widget.mediaItems.length,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
              
              // 预加载相邻页面的视频
              if (index > 0) {
                _initializeVideoControllerAt(index - 1);
              }
              if (index < widget.mediaItems.length - 1) {
                _initializeVideoControllerAt(index + 1);
              }
              
              // 清理不需要的视频控制器
              _cleanupUnusedControllers();
              
              // 如果处于自动播放模式，开始播放当前媒体
              if (_mediaMode == MediaMode.auto) {
                _playCurrentMedia();
              }
            },
            itemBuilder: (context, index) {
              final item = widget.mediaItems[index];
              return item.type == MediaType.video
                  ? _buildVideoPreview(item, index)
                  : _buildImagePreview(item);
            },
          ),

          // 顶部工具栏 - 始终显示
          Positioned(
            top: MediaQuery.of(context).padding.top,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.share, color: Colors.white),
                    onPressed: _shareMediaItem,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      _mediaMode == MediaMode.auto ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      if (_mediaMode == MediaMode.auto) {
                        stop();
                      } else {
                        playAuto();
                      }
                    },
                    tooltip: _mediaMode == MediaMode.auto ? '暂停自动播放' : '开始自动播放',
                  ),
                ],
              ),
            ),
          ),

          // 设置按钮 - 始终显示
          Positioned(
            right: 16,
            bottom: 160,
            child: GestureDetector(
              onTap: () => _addToFavorites(),
              onDoubleTap: () => _moveToTrash(),
              onLongPress: () => _moveCurrentMediaItem(),
              child: Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.settings,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 添加到收藏夹
  Future<void> _addToFavorites() async {
    final item = widget.mediaItems[_currentIndex];
    try {
      // 更新媒体项到收藏夹目录
      final updatedItem = MediaItem(
        id: item.id,
        name: item.name,
        path: item.path,
        type: item.type,
        directory: 'favorites', // 假设'favorites'是收藏夹的目录ID
        dateAdded: item.dateAdded,
      );
      
      final result = await _dbService.updateMediaItem(updatedItem.toMap());
      if (result <= 0) {
        throw Exception('添加到收藏夹失败');
      }
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已添加到收藏夹')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加到收藏夹失败: $e')),
      );
    }
  }

  // 移动到回收站
  Future<void> _moveToTrash() async {
    final item = widget.mediaItems[_currentIndex];
    try {
      // 获取所有文件夹以找到回收站文件夹
      final rootItems = await _dbService.getMediaItems('root');
      final trashFolder = rootItems
          .where((item) => 
              item['type'] == MediaType.folder.index && 
              item['name'] == '回收站')
          .map((item) => MediaItem.fromMap(item))
          .firstOrNull;
      
      if (trashFolder == null) {
        throw Exception('找不到回收站文件夹');
      }

      // 更新媒体项到回收站目录
      final updatedItem = MediaItem(
        id: item.id,
        name: item.name,
        path: item.path,
        type: item.type,
        directory: trashFolder.id, // 使用实际的回收站文件夹ID
        dateAdded: item.dateAdded,
      );
      
      final result = await _dbService.updateMediaItem(updatedItem.toMap());
      if (result <= 0) {
        throw Exception('移动到回收站失败');
      }
      
      // 从当前列表中移除
      if (!mounted) return;
      
      setState(() {
        widget.mediaItems.removeAt(_currentIndex);
        if (widget.mediaItems.isEmpty) {
          Navigator.of(context).pop(true);
          return;
        }
        _currentIndex = _currentIndex >= widget.mediaItems.length 
            ? widget.mediaItems.length - 1 
            : _currentIndex;
        _pageController.jumpToPage(_currentIndex);
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已移动到回收站')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('移动到回收站失败: $e')),
      );
    }
  }

  void _toggleControls() {
    // 如果当前项是视频且控制器存在，则切换视频播放状态
    if (_currentIndex >= 0 && 
        _currentIndex < widget.mediaItems.length &&
        widget.mediaItems[_currentIndex].type == MediaType.video &&
        _videoControllers.containsKey(_currentIndex)) {
      final controller = _videoControllers[_currentIndex];
      if (controller != null) {
        if (controller.value.isPlaying) {
          controller.pause();
        } else {
          controller.play();
        }
      }
    }
  }

  void playManual() {
    setState(() {
      _mediaMode = MediaMode.manual;
    });
    _playCurrentMedia();
  }

  void playAuto() {
    setState(() {
      _mediaMode = MediaMode.auto;
    });
    _playCurrentMedia();
  }

  void stop() {
    setState(() {
      _mediaMode = MediaMode.none;
    });
    _mediaTimer?.cancel();
    _mediaTimer = null;
  }

  Future<void> _playCurrentMedia() async {
    final currentItem = widget.mediaItems[_currentIndex];
    
    if (currentItem.type == MediaType.video) {
      final controller = _videoControllers[_currentIndex];
      if (controller != null && controller.value.isInitialized) {
        await controller.play();
        
        // 监听视频播放完成
        controller.addListener(() {
          if (controller.value.position >= controller.value.duration) {
            _onMediaComplete();
          }
        });
      }
    } else if (currentItem.type == MediaType.image) {
      // 图片显示5秒后自动切换
      _mediaTimer?.cancel();
      _mediaTimer = Timer(const Duration(seconds: 5), _onMediaComplete);
    }
  }

  void _onMediaComplete() {
    if (_mediaMode == MediaMode.auto && _currentIndex < widget.mediaItems.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else if (_mediaMode == MediaMode.manual) {
      stop();
    }
  }
}