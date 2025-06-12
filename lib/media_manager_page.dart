import 'dart:io';
import 'dart:math' as math;
import 'dart:async';
import 'package:crypto/crypto.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'models/media_item.dart';
import 'media_preview_page.dart';
import 'create_folder_dialog.dart';
import 'models/media_type.dart';
import 'browser_page.dart';

class MediaManagerPage extends StatefulWidget {
  const MediaManagerPage({super.key});

  @override
  _MediaManagerPageState createState() => _MediaManagerPageState();
}

class _MediaManagerPageState extends State<MediaManagerPage>
    with SingleTickerProviderStateMixin {
  final List<MediaItem> _mediaItems = [];
  bool _isLoading = true;
  String _currentDirectory = 'root';
  late final DatabaseService _databaseService;
  int _imageCount = 0;
  int _videoCount = 0;
  bool _mediaVisible = true;
  final Set<String> _selectedItems = {};
  bool _isMultiSelectMode = false;
  final Map<String, File?> _videoThumbnailCache = {};
  String? _lastViewedVideoId;
  final StreamController<String> _progressController = StreamController<String>.broadcast();
  final List<String> _availableDirectories = ['root'];

  // For automatic invalid media cleanup
  final Set<String> _itemsToCleanup = {};
  Timer? _cleanupTimer;

  @override
  void initState() {
    super.initState();
    
    if (!kIsWeb) {
      _databaseService = getService<DatabaseService>();
      _loadSettings();
      _checkPermissions().then((_) {
        _ensureMediaTable();
      });
    } else {
      print("Web environment: Skipping database and permission operations in MediaManagerPage");
      // 为Web环境设置默认状态
      if (mounted) {
        setState(() {
          _isLoading = false;
          _mediaVisible = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _progressController.close();
    _cleanupTimer?.cancel(); // Cancel the cleanup timer
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    var photosStatus = await Permission.photos.status;
    var videosStatus = await Permission.videos.status;
    var storageStatus = await Permission.storage.status;

    List<Permission> permissionsToRequest = [];

    if (!photosStatus.isGranted) {
      permissionsToRequest.add(Permission.photos);
    }
    if (!videosStatus.isGranted) {
      permissionsToRequest.add(Permission.videos);
    }
    if (!storageStatus.isGranted) {
      permissionsToRequest.add(Permission.storage);
    }

    if (permissionsToRequest.isNotEmpty) {
      await permissionsToRequest.request(); // 只请求权限，不显示任何提示
    }
  }

  Future<void> _ensureMediaTable() async {
    try {
      await _databaseService.ensureMediaItemsTableExists();
      await _loadMediaItems();
    } catch (e) {
      debugPrint('确保媒体表存在时出错: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMediaItems() async {
    setState(() {
      _isLoading = true;
    });

    try {
      debugPrint('开始加载媒体项...');
      
      // 检查并创建回收站文件夹
      final recycleBinFolder = await _databaseService.getMediaItemById('recycle_bin');
      debugPrint('检查回收站文件夹: ${recycleBinFolder != null ? '存在' : '不存在'}');
      
      if (recycleBinFolder == null) {
        debugPrint('创建回收站文件夹...');
        await _databaseService.insertMediaItem({
          'id': 'recycle_bin',
          'name': '回收站',
          'path': '',
          'type': MediaType.folder.index,
          'directory': 'root',
          'date_added': DateTime.now().toIso8601String(),
        });
        debugPrint('回收站文件夹创建成功');
      }

      // 检查并创建收藏夹
      final favoritesFolder = await _databaseService.getMediaItemById('favorites');
      debugPrint('检查收藏夹: ${favoritesFolder != null ? '存在' : '不存在'}');
      
      if (favoritesFolder == null) {
        debugPrint('创建收藏夹...');
        await _databaseService.insertMediaItem({
          'id': 'favorites',
          'name': '收藏夹',
          'path': '',
          'type': MediaType.folder.index,
          'directory': 'root',
          'date_added': DateTime.now().toIso8601String(),
        });
        debugPrint('收藏夹创建成功');
      }

      // 更新可用目录列表，确保包含回收站和收藏夹
      if (!_availableDirectories.contains('recycle_bin')) {
        setState(() {
          _availableDirectories.add('recycle_bin');
        });
      }
      
      if (!_availableDirectories.contains('favorites')) {
        setState(() {
          _availableDirectories.add('favorites');
        });
      }

      // 加载当前目录的媒体项
      final items = await _databaseService.getMediaItems(_currentDirectory);
      debugPrint('从目录 $_currentDirectory 加载了 ${items.length} 个项目');
      
      // 计算图片和视频数量
      int imageCount = items.where((item) {
        final typeIndex = item['type'] as int;
        if (typeIndex >= MediaType.values.length) return false;
        return MediaType.values[typeIndex] == MediaType.image;
      }).length;
      
      int videoCount = items.where((item) {
        final typeIndex = item['type'] as int;
        if (typeIndex >= MediaType.values.length) return false;
        return MediaType.values[typeIndex] == MediaType.video;
      }).length;
      
      debugPrint('当前目录下有 $imageCount 张图片和 $videoCount 个视频');
      
      // 更新状态
      setState(() {
        _mediaItems.clear();
        _mediaItems.addAll(items.map((item) => MediaItem.fromMap(item)));
        _isLoading = false;
        _imageCount = imageCount;
        _videoCount = videoCount;
      });
    } catch (e) {
      debugPrint('加载媒体项时出错: $e');
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载媒体文件时出错。请重试。')),
        );
      }
    }
  }

  Future<bool> _checkFolderNameExists(String folderName) async {
    final items = await _databaseService.getMediaItems(_currentDirectory);
    return items.any((item) {
      final typeIndex = item['type'] as int;
      if (typeIndex >= MediaType.values.length) return false;
      return item['name'] == folderName && MediaType.values[typeIndex] == MediaType.folder;
    });
  }

  Future<void> _createFolder(String folderName) async {
    try {
      if (await _checkFolderNameExists(folderName)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件夹 "$folderName" 已存在，请使用其他名称')),
          );
        }
        return;
      }

      final uuid = const Uuid().v4();
      final mediaItem = MediaItem(
        id: uuid,
        name: folderName,
        path: '',
        type: MediaType.folder,
        directory: _currentDirectory,
        dateAdded: DateTime.now(),
      );
      await _databaseService.insertMediaItem(mediaItem.toMap());
      await _loadMediaItems();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已创建文件夹: $folderName')));
      }
    } catch (e) {
      debugPrint('创建文件夹时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('创建文件夹时出错: $e')));
      }
    }
  }

  void _showCreateFolderDialog() {
    showDialog(
      context: context,
      builder: (context) => CreateFolderDialog(
        onCreate: (name) {
          _createFolder(name);
        },
      ),
    );
  }

  Future<List<File>> _pickMultipleImages() async {
    final picker = ImagePicker();
    final pickedFiles = await picker.pickMultiImage();
    return pickedFiles.map((xFile) => File(xFile.path)).toList();
  }

  Future<List<File>> _pickMultipleVideos() async {
    try {
      debugPrint('开始加载视频文件...');
      final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
        type: RequestType.video,
      );
      debugPrint('找到 ${paths.length} 个视频路径');
      if (paths.isEmpty) {
        // 如果 photo_manager 失败，尝试使用 file_picker 作为备用
        FilePickerResult? result = await FilePicker.platform.pickFiles(
          type: FileType.video,
          allowMultiple: true,
        );
        if (result == null || result.files.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('未找到视频文件，请确保设备上有视频或检查权限。')),
            );
          }
          return [];
        }
        return result.files.map((file) => File(file.path!)).toList();
      }

      List<AssetEntity> allVideos = [];
      Set<String> videoIds = {};
      for (var path in paths) {
        final assets = await path.getAssetListRange(start: 0, end: 100000);
        debugPrint('路径 ${path.name} 中找到 ${assets.length} 个视频资产');
        for (var asset in assets) {
          if (!videoIds.contains(asset.id)) {
            allVideos.add(asset);
            videoIds.add(asset.id);
          }
        }
      }

      debugPrint('总共找到 ${allVideos.length} 个唯一视频');

      List<AssetEntity> selectedVideos = await _showVideoSelectionDialog(allVideos);
      debugPrint('用户选择了 ${selectedVideos.length} 个视频');
      if (selectedVideos.isEmpty) return [];

      List<File> videoFiles = [];
      for (var asset in selectedVideos) {
        final file = await asset.file;
        if (file != null) {
          debugPrint('成功加载视频文件: ${file.path}');
          videoFiles.add(file);
        } else {
          debugPrint('无法加载视频文件: ${asset.id}');
        }
      }

      debugPrint('最终返回 ${videoFiles.length} 个视频文件');
      return videoFiles;
    } catch (e) {
      debugPrint('选择视频时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载视频文件时出错: $e')),
        );
      }
      return [];
    }
  }

  Future<List<AssetEntity>> _showVideoSelectionDialog(List<AssetEntity> videos) async {
    List<AssetEntity> selected = [];
    bool isSelecting = false;
    final screenSize = MediaQuery.of(context).size;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          insetPadding: EdgeInsets.zero,
          child: SizedBox(
            width: screenSize.width,
            height: screenSize.height * 0.9,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text('选择视频', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(4.0),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      childAspectRatio: 1,
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                    ),
                    itemCount: videos.length,
                    itemBuilder: (context, index) {
                      final video = videos[index];
                      final isSelected = selected.contains(video);
                      return GestureDetector(
                        onTap: () {
                          setDialogState(() {
                            if (isSelected) {
                              selected.remove(video);
                            } else {
                              selected.add(video);
                            }
                          });
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            FutureBuilder<Uint8List?>(
                              future: video.thumbnailDataWithSize(
                                const ThumbnailSize(200, 200),
                              ),
                              builder: (context, snapshot) {
                                if (snapshot.hasData && snapshot.data != null) {
                                  return Image.memory(
                                    snapshot.data!,
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                    height: double.infinity,
                                  );
                                }
                                return const Center(child: CircularProgressIndicator());
                              },
                            ),
                            if (isSelected)
                              const Positioned(
                                top: 4,
                                right: 4,
                                child: Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 24,
                                ),
                              ),
                            Positioned(
                              bottom: 4,
                              left: 4,
                              child: Container(
                                color: Colors.black54,
                                padding: const EdgeInsets.all(2),
                                child: Text(
                                  _formatDuration(Duration(seconds: video.duration)),
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () {
                          isSelecting = true;
                          Navigator.pop(context);
                        },
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return isSelecting ? selected : [];
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  Future<String> _calculateFileHash(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final hash = md5.convert(bytes);
      return hash.toString();
    } catch (e) {
      debugPrint('计算文件哈希值时出错: $e');
      return '';
    }
  }

  Future<void> _saveMultipleMediaToAppDirectory(
      List<File> sourceFiles, MediaType type) async {
    if (sourceFiles.isEmpty) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('正在导入媒体...')
          ],
        ),
      ),
    );

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

      int importedCount = 0;
      int skippedCount = 0;

      for (var sourceFile in sourceFiles) {
        final fileName = path.basename(sourceFile.path);
        final fileHash = await _calculateFileHash(sourceFile);
        
        // 检查是否存在重复文件
        final duplicate = await _databaseService.findDuplicateMediaItem(fileHash, fileName);
        if (duplicate != null) {
          debugPrint('发现重复文件: ${duplicate['name']}');
          skippedCount++;
          continue;
        }

        final uuid = const Uuid().v4();
        final extension = path.extension(sourceFile.path);
        final destinationPath = '${mediaDir.path}/$uuid$extension';
        await sourceFile.copy(destinationPath);

        final mediaItem = MediaItem(
          id: uuid,
          name: fileName,
          path: destinationPath,
          type: type,
          directory: _currentDirectory,
          dateAdded: DateTime.now(),
        );
        
        // 将文件哈希值添加到数据库记录中
        final mediaItemMap = mediaItem.toMap();
        mediaItemMap['file_hash'] = fileHash;
        
        await _databaseService.insertMediaItem(mediaItemMap);
        importedCount++;
      }

      if (mounted) {
        Navigator.of(context).pop();
        await _loadMediaItems();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '导入完成: 成功导入 $importedCount 个${_getMediaTypeName(type)}文件${skippedCount > 0 ? '，跳过 $skippedCount 个重复文件' : ''}'
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        debugPrint('批量导入媒体时出错: $e');
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('导入媒体文件时出错: $e')));
      }
    }
  }

  String _getMediaTypeName(MediaType type) {
    switch (type) {
      case MediaType.image:
        return '图片';
      case MediaType.video:
        return '视频';
      case MediaType.audio:
        return '音频';

      case MediaType.folder:
        return '文件夹';
    }
  }

  Future<void> _deleteMediaItem(MediaItem item) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除媒体'),
        content: Text('确定要删除 "${item.name}" 吗？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    ) ??
        false;

    if (shouldDelete) {
      try {
        await _databaseService.deleteMediaItem(item.id);
        final file = File(item.path);
        if (await file.exists()) await file.delete();
        await _loadMediaItems();
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已删除: ${item.name}')));
        }
      } catch (e) {
        debugPrint('删除媒体项时出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('删除媒体项时出错: $e')));
        }
      }
    }
  }

  Future<void> _renameMediaItem(MediaItem item) async {
    TextEditingController renameController =
    TextEditingController(text: item.name);

    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: renameController,
          decoration: const InputDecoration(
            labelText: '新名称',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final name = renameController.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(context, name);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != item.name) {
      try {
        final items = await _databaseService.getMediaItems(_currentDirectory);
        if (items.any((existingItem) =>
        existingItem['name'] == newName && existingItem['id'] != item.id)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('名称 "$newName" 已存在，请使用其他名称')),
            );
          }
          return;
        }

        final updatedItem = MediaItem(
          id: item.id,
          name: newName,
          path: item.path,
          type: item.type,
          directory: item.directory,
          dateAdded: item.dateAdded,
        );
        await _databaseService.updateMediaItem(updatedItem.toMap());
        await _loadMediaItems();
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已重命名为: $newName')));
        }
      } catch (e) {
        debugPrint('重命名媒体项时出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('重命名时出错: $e')));
        }
      }
    }
  }

  Future<void> _moveMediaItem(MediaItem item, String targetDirectory) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('正在移动媒体...')
          ],
        ),
      ),
    );

    try {
      final updatedItem = MediaItem(
        id: item.id,
        name: item.name,
        path: item.path,
        type: item.type,
        directory: targetDirectory,
        dateAdded: item.dateAdded,
      );
      await _databaseService.updateMediaItem(updatedItem.toMap());

      if (mounted) {
        Navigator.of(context).pop();
        await _loadMediaItems();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('成功移动: ${item.name}')));
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        debugPrint('移动媒体项时出错: $e');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('移动媒体项时出错: $e')));
      }
    }
  }

  Future<void> _navigateToFolder(MediaItem folder) async {
    setState(() {
      _currentDirectory = folder.id;
      _selectedItems.clear();
      _isMultiSelectMode = false;
    });
    await _loadMediaItems();
  }

  Future<void> _navigateUp() async {
    if (_currentDirectory != 'root') {
      final parentDir =
      await _databaseService.getMediaItemParentDirectory(_currentDirectory);
      setState(() {
        _currentDirectory = parentDir ?? 'root';
        _selectedItems.clear();
        _isMultiSelectMode = false;
      });
      await _loadMediaItems();
    }
  }

  void _toggleMediaVisibility() {
    setState(() => _mediaVisible = !_mediaVisible);
    _saveSettings();
  }

  void _toggleMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = !_isMultiSelectMode;
      if (!_isMultiSelectMode) _selectedItems.clear();
    });
  }

  void _selectAll() {
    setState(() {
      _isMultiSelectMode = true;
      _selectedItems.clear();
      // 只选择非文件夹的媒体项
      _selectedItems.addAll(_mediaItems
          .where((item) => item.type != MediaType.folder)
          .map((item) => item.id));
    });
  }

  Future<void> _moveSelectedItems(String targetDirectory) async {
    if (_selectedItems.isEmpty) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('正在移动媒体...')
          ],
        ),
      ),
    );

    try {
      for (var id in _selectedItems) {
        final item = _mediaItems.firstWhere((item) => item.id == id);
        final updatedItem = MediaItem(
          id: item.id,
          name: item.name,
          path: item.path,
          type: item.type,
          directory: targetDirectory,
          dateAdded: item.dateAdded,
        );
        await _databaseService.updateMediaItem(updatedItem.toMap());
      }

      if (mounted) {
        Navigator.of(context).pop();
        setState(() {
          _selectedItems.clear();
          _isMultiSelectMode = false;
        });
        await _loadMediaItems();
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('成功移动 ${_selectedItems.length} 个项')));
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        debugPrint('移动媒体项时出错: $e');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('移动媒体项时出错: $e')));
      }
    }
  }

  Future<void> _showMoveDialog({MediaItem? item}) async {
    String? excludeId;
    if (item != null && item.type == MediaType.folder) {
      excludeId = item.id;
    } else if (_isMultiSelectMode && _selectedItems.isNotEmpty) {
      // If multiple items are selected, and any of them is a folder,
      // exclude the first selected folder and its subfolders.
      // For simplicity, we just take the first selected item that is a folder.
      for (var selectedId in _selectedItems) {
        final selectedItem = _mediaItems.firstWhere((i) => i.id == selectedId);
        if (selectedItem.type == MediaType.folder) {
          excludeId = selectedItem.id;
          break;
        }
      }
    }

    showDialog(
      context: context,
      builder: (context) => FutureBuilder<List<MediaItem>>(
        future: _getAllAvailableFolders(excludeFolderId: excludeId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const AlertDialog(
                content: Row(children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('加载中...')
                ]));
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return AlertDialog(
              title: const Text('移动到'),
              content: const Text('没有可用的目标文件夹。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
              ],
            );
          }

          final folders = snapshot.data!;
          return AlertDialog(
            title: const Text('移动到'),
            content: SingleChildScrollView(
              child: Column(
                children: [
                  ListTile(
                    title: const Text('根目录'),
                    enabled: _currentDirectory != 'root',
                    onTap: _currentDirectory != 'root'
                        ? () {
                      Navigator.of(context).pop();
                      if (item != null) {
                        _moveMediaItem(item, 'root');
                      } else {
                        _moveSelectedItems('root');
                      }
                    }
                        : null,
                  ),
                  ...folders.map((folder) {
                    return ListTile(
                      title: Text(folder.name),
                      onTap: () {
                        Navigator.of(context).pop();
                        if (item != null) {
                          _moveMediaItem(item, folder.id);
                        } else {
                          _moveSelectedItems(folder.id);
                        }
                      },
                    );
                  }),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
            ],
          );
        },
      ),
    );
  }

  Future<List<MediaItem>> _getAllAvailableFolders({String? excludeFolderId}) async {
    try {
      final rootItems = await _databaseService.getMediaItems('root');
      final rootFolders = rootItems
          .where((item) => item['type'] == MediaType.folder.index)
          .map((item) => MediaItem.fromMap(item))
          .toList();

      final currentFolders = _currentDirectory != 'root'
          ? (await _databaseService.getMediaItems(_currentDirectory))
          .where((item) => item['type'] == MediaType.folder.index)
          .map((item) => MediaItem.fromMap(item))
          .toList()
          : <MediaItem>[];

      // Remove Recycle Bin and Favorites from fetched folders if they are already there
      final filteredRootFolders = rootFolders.where((folder) => folder.id != 'recycle_bin' && folder.id != 'favorites').toList();
      final filteredCurrentFolders = currentFolders.where((folder) => folder.id != 'recycle_bin' && folder.id != 'favorites').toList();

      // Explicitly add Recycle Bin and Favorites, ensuring they are always available
      final recycleBin = await _databaseService.getMediaItemById('recycle_bin') ??
          <String, dynamic>{'id': 'recycle_bin', 'name': '回收站', 'path': '', 'type': MediaType.folder.index, 'directory': 'root', 'date_added': DateTime.now().toIso8601String()};
      final favorites = await _databaseService.getMediaItemById('favorites') ??
          <String, dynamic>{'id': 'favorites', 'name': '收藏夹', 'path': '', 'type': MediaType.folder.index, 'directory': 'root', 'date_added': DateTime.now().toIso8601String()};

      final allFolders = <MediaItem>{}
        ..addAll(filteredRootFolders)
        ..addAll(filteredCurrentFolders)
        ..add(MediaItem.fromMap(recycleBin))
        ..add(MediaItem.fromMap(favorites));

      // Filter out the excluded folder and its subfolders
      if (excludeFolderId != null) {
        final excludedSubfolders = await _getAllSubfolderIds(excludeFolderId);
        allFolders.removeWhere((folder) => folder.id == excludeFolderId || excludedSubfolders.contains(folder.id));
      }

      return allFolders.toList();
    } catch (e) {
      debugPrint('获取可用文件夹时出错: $e');
      return [];
    }
  }

  // Helper method to get all subfolder IDs recursively
  Future<Set<String>> _getAllSubfolderIds(String parentFolderId) async {
    Set<String> subfolderIds = {};
    try {
      final itemsInParent = await _databaseService.getMediaItems(parentFolderId);
      for (var item in itemsInParent) {
        if (item['type'] == MediaType.folder.index) {
          subfolderIds.add(item['id']);
          subfolderIds.addAll(await _getAllSubfolderIds(item['id']));
        }
      }
    } catch (e) {
      debugPrint('递归获取子文件夹ID时出错: $e');
    }
    return subfolderIds;
  }

  Future<void> _deleteSelectedItems() async {
    if (_selectedItems.isEmpty) return;

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除选定项'),
        content: Text('确定要删除 ${_selectedItems.length} 个选定项吗？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    ) ??
        false;

    if (shouldDelete) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text('正在删除...')
            ],
          ),
        ),
      );

      try {
        for (var id in _selectedItems) {
          final item = _mediaItems.firstWhere((item) => item.id == id);
          await _databaseService.deleteMediaItem(id);
          final file = File(item.path);
          if (await file.exists()) await file.delete();
        }

        if (mounted) {
          Navigator.of(context).pop();
          setState(() {
            _selectedItems.clear();
            _isMultiSelectMode = false;
          });
          await _loadMediaItems();
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已删除 ${_selectedItems.length} 个项')));
        }
      } catch (e) {
        if (mounted) {
          Navigator.of(context).pop();
          debugPrint('删除选定项时出错: $e');
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('删除选定项时出错: $e')));
        }
      }
    }
  }

  Widget _buildMediaGrid() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_mediaItems.isEmpty) {
      return const Center(
        child: Text('没有媒体文件', style: TextStyle(fontSize: 18, color: Colors.grey)),
      );
    }

    if (!_mediaVisible) return Container();

    return GestureDetector(
      onTap: () {
        if (_isMultiSelectMode) {
          _toggleMultiSelectMode();
        }
      },
      child: GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          childAspectRatio: 0.7,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: _mediaItems.length,
        itemBuilder: (context, index) {
          final item = _mediaItems[index];
          return _buildMediaItem(item, index);
        },
      ),
    );
  }

  Widget _buildMediaItem(MediaItem item, int index) {
    bool isSelected = _selectedItems.contains(item.id);
    bool isLastViewed = item.id == _lastViewedVideoId;

    return GestureDetector(
      key: ValueKey(item.id),
      onTap: _isMultiSelectMode
          ? () => _toggleItemSelection(item.id)
          : () {
        if (item.type == MediaType.folder) {
          _navigateToFolder(item);
        } else {
          _previewMediaItem(item);
        }
      },
      onLongPress: () {
        if (!_isMultiSelectMode) {
          _toggleMultiSelectMode();
        }
        _toggleItemSelection(item.id);
      },
      child: Card(
        elevation: isLastViewed ? 6 : 2,
        margin: const EdgeInsets.all(0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: isLastViewed 
              ? const BorderSide(color: Colors.blue, width: 2.0)
              : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _buildMediaThumbnail(item)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
              if (_isMultiSelectMode)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 24, maxHeight: 24),
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (value) => _toggleItemSelection(item.id),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              if (!_isMultiSelectMode)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: const BoxDecoration(
                      color: Colors.black45,
                      shape: BoxShape.circle,
                    ),
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.more_vert,
                        size: 20,
                        color: Colors.white,
                      ),
                      onSelected: (value) {
                        if (value == 'delete') {
                          _deleteMediaItem(item);
                        } else if (value == 'move') {
                          _showMoveDialog(item: item);
                        } else if (value == 'rename') {
                          _renameMediaItem(item);
                        } else if (value == 'multi_select') {
                          _toggleMultiSelectMode();
                        } else if (value == 'select_all') {
                          _selectAll();
                        } else if (value == 'export') {
                          _exportMediaItem(item);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(value: 'rename', child: Text('重命名')),
                        const PopupMenuItem(value: 'move', child: Text('移动到')),
                        const PopupMenuItem(value: 'export', child: Text('导出')),
                        const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除', style: TextStyle(color: Colors.red))),
                        const PopupMenuItem(value: 'multi_select', child: Text('多选')),
                        const PopupMenuItem(value: 'select_all', child: Text('全选')),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMediaThumbnail(MediaItem item) {
    switch (item.type) {
      case MediaType.image:
        return Image.file(
          File(item.path),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            _scheduleCleanup(item.id); // Schedule cleanup on image load error
            return const Icon(Icons.image, size: 32);
          },
        );
      case MediaType.video:
        return FutureBuilder<File?>(
          future: _generateVideoThumbnail(item.path),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done &&
                snapshot.hasData &&
                snapshot.data != null) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    snapshot.data!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      debugPrint('加载视频缩略图失败: ${item.path}, 错误: $error');
                      _scheduleCleanup(item.id); // Schedule cleanup on video thumbnail load error
                      return _buildVideoPlaceholder();
                    },
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              );
            } else if (snapshot.connectionState == ConnectionState.waiting) {
              return Stack(
                children: [
                  _buildVideoPlaceholder(),
                  const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                      ),
                    ),
                  ),
                ],
              );
            } else { // Handle cases where thumbnail generation failed or data is null
              _scheduleCleanup(item.id); // Schedule cleanup if thumbnail is not available
              return _buildVideoPlaceholder();
            }
          },
        );
      case MediaType.audio:
        return Container(
          color: Colors.lightBlue.shade100,
          child: const Icon(Icons.audio_file, size: 32, color: Colors.blue),
        );

      case MediaType.folder:
        return Container(
          color: Colors.amber.shade100,
          child: const Icon(Icons.folder, size: 32, color: Colors.amber),
        );
      default:
        return Container();
    }
  }

  Widget _buildVideoPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.blueGrey.shade900, Colors.black],
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.videocam, size: 36, color: Colors.white70),
                SizedBox(height: 4),
                Text('视频', style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.play_arrow,
                size: 16,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<File?> _generateVideoThumbnail(String videoPath) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final thumbnailPath = '${tempDir.path}/${videoPath.hashCode}_thumbnail.jpg';
      final thumbnailFile = File(thumbnailPath);
      
      // 检查缓存
      if (await thumbnailFile.exists() && await thumbnailFile.length() > 100) {
        return thumbnailFile;
      }

      // 优先尝试使用 FFmpeg 生成缩略图
      debugPrint('开始尝试使用FFmpeg生成缩略图...');
      bool ffmpegSuccess = await _extractVideoFrameWithFFmpeg(videoPath, thumbnailPath);
      if (ffmpegSuccess && await thumbnailFile.exists()) {
        debugPrint('FFmpeg 缩略图生成成功: $thumbnailPath');
        return thumbnailFile;
      } 
      
      // 尝试使用video_thumbnail插件作为备选
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          final thumbnailBytes = await VideoThumbnail.thumbnailData(
            video: videoPath,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 250,
            quality: 50,
          );
          
          if (thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
            await thumbnailFile.writeAsBytes(thumbnailBytes);
            if (await thumbnailFile.exists()) {
              debugPrint('VideoThumbnail插件成功生成缩略图');
              return thumbnailFile;
            }
          }
        } catch (e) {
          debugPrint('VideoThumbnail插件生成缩略图失败: $e');
          // 继续尝试其他方法
        }
      }
      
      debugPrint('标准方法生成缩略图失败，使用简单替代方法');
      // 尝试生成彩色缩略图作为备选
      return _generateColoredThumbnail(videoPath);
    } catch (e) {
      debugPrint('缩略图生成过程中发生错误: $videoPath, 错误: $e');
      return null;
    }
  }
  
  Future<File?> _generateColoredThumbnail(String videoPath) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final thumbnailPath = '${tempDir.path}/${videoPath.hashCode}_color_thumbnail.jpg';
      final thumbnailFile = File(thumbnailPath);
      
      // 检查缓存
      if (await thumbnailFile.exists() && await thumbnailFile.length() > 100) {
        return thumbnailFile;
      }
      
      // 创建基于视频路径的唯一颜色缩略图
      final videoFileName = path.basename(videoPath);
      final fileSize = await File(videoPath).length();
      final colorSeed = videoFileName.hashCode + fileSize;
      final colorMap = _generateUniqueColors(colorSeed);
      
      // 使用简单的位图方法生成缩略图，而不依赖Canvas
      final imageBytes = await _createSimpleBitmapThumbnail(
        const Size(250, 141), // 16:9宽高比
        videoFileName,
        colorMap['primary']!,
        colorMap['secondary']!,
      );
      
      await thumbnailFile.writeAsBytes(imageBytes);
      if (await thumbnailFile.exists()) {
        return thumbnailFile;
      }
      
      return null;
    } catch (e) {
      debugPrint('生成彩色缩略图失败: $e');
      return null;
    }
  }
  
  Map<String, Color> _generateUniqueColors(int seed) {
    final random = math.Random(seed);
    final List<Color> primaryColors = [
      Colors.blue.shade900,
      Colors.indigo.shade800,
      Colors.purple.shade800,
      Colors.teal.shade800,
      Colors.green.shade800,
      Colors.orange.shade900,
      Colors.red.shade900,
      Colors.pink.shade800,
    ];
    final List<Color> secondaryColors = [
      Colors.blue.shade300,
      Colors.indigo.shade400,
      Colors.purple.shade400,
      Colors.teal.shade400,
      Colors.green.shade400,
      Colors.orange.shade400,
      Colors.red.shade400,
      Colors.pink.shade400,
    ];
    final primaryIndex = random.nextInt(primaryColors.length);
    final secondaryIndex = random.nextInt(secondaryColors.length);
    return {
      'primary': primaryColors[primaryIndex],
      'secondary': secondaryColors[secondaryIndex]
    };
  }
  
  Future<Uint8List> _createSimpleBitmapThumbnail(
    Size size, 
    String fileName,
    Color primaryColor,
    Color secondaryColor,
  ) async {
    final width = size.width.toInt().clamp(1, 300);
    final height = size.height.toInt().clamp(1, 300);
    const int bytesPerPixel = 4;
    final int rowStrideBytes = width * bytesPerPixel;
    final int totalBytes = rowStrideBytes * height;
    final Uint8List bytes = Uint8List(totalBytes);
    
    // 绘制渐变背景
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int pixelOffset = (y * rowStrideBytes) + (x * bytesPerPixel);
        
        // 计算当前位置的渐变颜色
        final double normalizedY = y / height;
        final double normalizedX = x / width;
        final double distanceFromCenter = math.sqrt(
          math.pow(normalizedX - 0.5, 2) + math.pow(normalizedY - 0.5, 2)
        ) * 2;
        
        final double ratio = (normalizedY * 0.7) + (distanceFromCenter * 0.3);
        final double inverseRatio = 1 - ratio;
        
        // 混合两种颜色
        final int r = (primaryColor.red * inverseRatio + secondaryColor.red * ratio).toInt();
        final int g = (primaryColor.green * inverseRatio + secondaryColor.green * ratio).toInt();
        final int b = (primaryColor.blue * inverseRatio + secondaryColor.blue * ratio).toInt();
        const int a = 255;
        
        bytes[pixelOffset] = r;
        bytes[pixelOffset + 1] = g;
        bytes[pixelOffset + 2] = b;
        bytes[pixelOffset + 3] = a;
      }
    }
    
    // 在中心绘制视频播放图标
    _drawPlayIcon(bytes, width, height, rowStrideBytes);
    
    // 在底部添加文件名
    _drawFileName(bytes, width, height, rowStrideBytes, fileName);
    
    return bytes;
  }
  
  // 绘制播放图标
  void _drawPlayIcon(Uint8List bytes, int width, int height, int rowStrideBytes) {
    final int centerX = width ~/ 2;
    final int centerY = height ~/ 2;
    final int iconSize = math.min(width, height) ~/ 5;
    
    // 绘制圆形背景
    for (int y = centerY - iconSize; y <= centerY + iconSize; y++) {
      if (y < 0 || y >= height) continue;
      for (int x = centerX - iconSize; x <= centerX + iconSize; x++) {
        if (x < 0 || x >= width) continue;
        
        final int dx = x - centerX;
        final int dy = y - centerY;
        final double distance = math.sqrt(dx * dx + dy * dy);
        
        if (distance <= iconSize) {
          final int pixelOffset = (y * rowStrideBytes) + (x * 4); // 使用固定值4代替bytesPerPixel

          // 圆形半透明背景
          bytes[pixelOffset] = (bytes[pixelOffset] * 0.3).toInt();
          bytes[pixelOffset + 1] = (bytes[pixelOffset + 1] * 0.3).toInt();
          bytes[pixelOffset + 2] = (bytes[pixelOffset + 2] * 0.3).toInt();
          
          // 播放三角形图标
          if (dx > -iconSize / 2 && distance < iconSize * 0.8) {
            const double slope = 1.2; // 控制三角形形状
            if (dy < slope * dx && dy > -slope * dx) {
              bytes[pixelOffset] = 255;
              bytes[pixelOffset + 1] = 255;
              bytes[pixelOffset + 2] = 255;
            }
          }
        }
      }
    }
  }
  
  // 绘制文件名
  void _drawFileName(Uint8List bytes, int width, int height, int rowStrideBytes, String fileName) {
    // 在底部创建一个半透明的条带
    final int startY = height - 20;
    final int endY = height;
    
    // 截断过长的文件名
    String displayName = fileName;
    if (displayName.length > 15) {
      displayName = '${displayName.substring(0, 12)}...';
    }
    
    // 创建半透明底部条带
    for (int y = startY; y < endY; y++) {
      if (y < 0 || y >= height) continue;
      for (int x = 0; x < width; x++) {
        final int pixelOffset = (y * rowStrideBytes) + (x * 4); // 使用固定值4代替bytesPerPixel
        bytes[pixelOffset] = (bytes[pixelOffset] * 0.3).toInt();
        bytes[pixelOffset + 1] = (bytes[pixelOffset + 1] * 0.3).toInt();
        bytes[pixelOffset + 2] = (bytes[pixelOffset + 2] * 0.3).toInt();
      }
    }
    
    // 由于无法直接在位图上绘制文本，我们只创建一个简单的标记
    // 实际应用中可以考虑使用第三方库处理文本绘制
  }

  Future<bool> _extractVideoFrameWithFFmpeg(String videoPath, String outputPath) async {
    try {
      debugPrint('使用 FFmpeg 提取视频帧: $videoPath -> $outputPath');
      final escapedVideoPath = videoPath.replaceAll('\\', '/');
      final escapedOutputPath = outputPath.replaceAll('\\', '/');
      
      // 创建临时目录，确保目标文件夹存在
      final outputDir = File(outputPath).parent;
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }
      
      // 临时禁用FFmpeg代码，直接返回false以使用备选方法
      debugPrint('FFmpeg功能临时禁用，使用备选方法生成缩略图');
      return false;

      /* 原FFmpeg代码已临时注释
      // 首先尝试视频序列的中间位置
      try {
        // 使用FFmpegKit执行命令获取视频时长
        String probCommand = '-i "$escapedVideoPath" -show_entries format=duration -v quiet -of csv="p=0"';
        final probeSession = await FFmpegKit.execute(probCommand);
        final probeReturnCode = await probeSession.getReturnCode();
        
        if (ReturnCode.isSuccess(probeReturnCode)) {
          ...更多FFmpeg代码...
        }
      } catch (probeError) {
        ...更多FFmpeg代码...
      }
      */
    } catch (e) {
      debugPrint('使用 FFmpeg 提取视频帧时出错: $e');
      return false;
    }
  }

  void _previewMediaItem(MediaItem item) {
    final index = _mediaItems.indexOf(item);
    if (index == -1) {
      debugPrint('错误：无法在媒体列表中找到该项目');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) =>
          MediaPreviewPage(mediaItems: _mediaItems, initialIndex: index),
    )).then((_) {
      // 当预览页面关闭时，记录最后查看的视频ID
      if (item.type == MediaType.video) {
        setState(() {
          _lastViewedVideoId = item.id;
        });
      }
    });
  }

  void _showMultiSelectOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.select_all),
              title: const Text('全选'),
              onTap: () {
                Navigator.pop(context);
                _selectAll();
              },
            ),
            ListTile(
              leading: const Icon(Icons.move_to_inbox),
              title: const Text('移动到'),
              onTap: () {
                Navigator.pop(context);
                _showMoveDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _deleteSelectedItems();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSettingsMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (context) {
        final screenWidth = MediaQuery.of(context).size.width;
        final dialogWidth = screenWidth;

        final List<Map<String, dynamic>> options = [
          {
            'icon': Icons.image,
            'color': Colors.blue,
            'title': '批量导入图片',
            'onTap': () async {
              Navigator.pop(context);
              List<File> files = await _pickMultipleImages();
              if (files.isNotEmpty) {
                await _saveMultipleMediaToAppDirectory(files, MediaType.image);
              }
            },
          },
          {
            'icon': Icons.videocam,
            'color': Colors.red,
            'title': '批量导入视频',
            'onTap': () async {
              Navigator.pop(context);
              List<File> files = await _pickMultipleVideos();
              if (files.isNotEmpty) {
                await _saveMultipleMediaToAppDirectory(files, MediaType.video);
              }
            },
          },
          {
            'icon': Icons.create_new_folder,
            'color': Colors.amber,
            'title': '创建文件夹',
            'onTap': () {
              Navigator.pop(context);
              _showCreateFolderDialog();
            },
          },
          {
            'icon': Icons.find_replace,
            'color': Colors.purple,
            'title': '扫描重复文件',
            'onTap': () async {
              Navigator.pop(context);
              await _scanAndUpdateFileHashes();
            },
          },
        ];

        if (_isMultiSelectMode && _selectedItems.isNotEmpty) {
          options.add({
            'icon': Icons.move_to_inbox,
            'color': Colors.grey,
            'title': '移动选定项',
            'onTap': () {
              Navigator.pop(context);
              _showMoveDialog();
            },
          });
          options.add({
            'icon': Icons.ios_share,
            'color': Colors.teal,
            'title': '导出选定项',
            'onTap': () {
              Navigator.pop(context);
              _exportSelectedMediaItems();
            },
          });
          options.add({
            'icon': Icons.delete,
            'color': Colors.red,
            'title': '删除选定项',
            'onTap': () {
              Navigator.pop(context);
              _deleteSelectedItems();
            },
          });
        }

        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: Container(
            width: dialogWidth,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '媒体管理选项',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 4,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 0,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final option = options[index];
                    return GestureDetector(
                      onTap: option['onTap'] as void Function(),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            Icon(
                              option['icon'] as IconData,
                              size: 20,
                              color: option['color'] as Color,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                option['title'] as String,
                                style: TextStyle(
                                    fontSize: 14,
                                    color: option['color'] == Colors.red
                                        ? Colors.red
                                        : Colors.black),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() => _mediaVisible = prefs.getBool('media_visible') ?? true);
    } catch (e) {
      debugPrint('加载设置时出错: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('media_visible', _mediaVisible);
    } catch (e) {
      debugPrint('保存设置时出错: $e');
    }
  }

  void _toggleItemSelection(String id) {
    setState(() {
      if (_selectedItems.contains(id)) {
        _selectedItems.remove(id);
      } else {
        _selectedItems.add(id);
      }
    });
  }
  
  Future<void> _exportMediaItem(MediaItem item) async {
    try {
      final file = File(item.path);
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件不存在: ${item.path}')),
          );
        }
        return;
      }

      // 直接分享文件，移除了保存到相册选项
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

  Future<void> _scanAndUpdateFileHashes() async {
    try {
      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              StreamBuilder<String>(
                stream: _progressController.stream,
                builder: (context, snapshot) {
                  return Text(
                    snapshot.data ?? '正在扫描媒体文件...',
                    style: const TextStyle(fontSize: 14),
                  );
                },
              ),
            ],
          ),
        ),
      );

      // 递归获取所有媒体项
      final allMediaItems = await _getAllMediaItemsRecursively('root');
      
      int processedCount = 0;
      int updatedCount = 0;
      int duplicateCount = 0;
      int errorCount = 0;
      Map<String, List<Map<String, dynamic>>> hashGroups = {};

      // 第一遍扫描：计算所有文件的哈希值
      for (var item in allMediaItems) {
        try {
          // 更新进度
          _progressController.add('正在处理: ${item['name']}');
          
          // 跳过文件夹
          if (item['type'] == MediaType.folder.index) {
            processedCount++;
            continue;
          }

          // 检查文件是否存在
          final file = File(item['path']);
          if (!await file.exists()) {
            errorCount++;
            processedCount++;
            continue;
          }

          // 计算文件哈希
          final fileHash = await _calculateFileHash(file);
          if (fileHash.isEmpty) {
            errorCount++;
            processedCount++;
            continue;
          }
          
          // 更新数据库中的哈希值
          await _databaseService.updateMediaItemHash(item['id'], fileHash);
          
          // 将文件按哈希值分组
          if (!hashGroups.containsKey(fileHash)) {
            hashGroups[fileHash] = [];
          }
          hashGroups[fileHash]!.add(item);
          
          updatedCount++;
          processedCount++;
        } catch (e) {
          print('处理文件时出错: ${item['name']}, 错误: $e');
          errorCount++;
          processedCount++;
        }
      }

      // 第二遍扫描：处理重复文件
      for (var hash in hashGroups.keys) {
        var files = hashGroups[hash]!;
        if (files.length > 1) {
          // 有重复文件
          _progressController.add('发现重复文件: ${files.map((f) => f['name']).join(', ')}');
          
          // 保留第一个文件，将其他文件移动到回收站
          var originalFile = files.first;
          var duplicates = files.skip(1).toList();
          
          for (var duplicate in duplicates) {
            try {
              // 将重复文件移动到回收站
              await _databaseService.updateMediaItemDirectory(duplicate['id'], 'recycle_bin');
              duplicateCount++;
            } catch (e) {
              print('移动重复文件到回收站时出错: ${duplicate['name']}, 错误: $e');
              errorCount++;
            }
          }
        }
      }

      // 关闭进度对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      // 显示结果
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '扫描完成\n'
              '处理文件: $processedCount\n'
              '更新哈希: $updatedCount\n'
              '重复文件: $duplicateCount\n'
              '错误: $errorCount'
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        
        // 重新加载媒体列表以反映变化
        await _loadMediaItems();
      }
    } catch (e) {
      print('扫描文件哈希时出错: $e');
      if (mounted) {
        Navigator.of(context).pop(); // 关闭进度对话框
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('扫描失败: $e')),
        );
      }
    }
  }

  // 递归获取所有媒体项的辅助方法
  Future<List<Map<String, dynamic>>> _getAllMediaItemsRecursively(String directory) async {
    List<Map<String, dynamic>> allItems = [];
    
    try {
      // 获取当前目录下的所有项目
      final items = await _databaseService.getMediaItems(directory);
      
      for (var item in items) {
        if (item['type'] == MediaType.folder.index) {
          // 如果是文件夹，递归获取其中的项目
          final subItems = await _getAllMediaItemsRecursively(item['id']);
          allItems.addAll(subItems);
        } else {
          // 只添加非文件夹的媒体文件
          allItems.add(item);
        }
      }
    } catch (e) {
      print('递归获取媒体项时出错: $e');
    }
    
    return allItems;
  }

  // 批量导出选中的媒体文件
  Future<void> _exportSelectedMediaItems() async {
    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先选择要导出的媒体文件')),
        );
      }
      return;
    }

    try {
      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text('正在准备导出...')
            ],
          ),
        ),
      );

      // 收集所有选中的文件
      List<XFile> filesToShare = [];
      List<String> missingFiles = [];

      for (String id in _selectedItems) {
        final item = _mediaItems.firstWhere((item) => item.id == id);
        // 跳过文件夹
        if (item.type == MediaType.folder) continue;
        
        final file = File(item.path);
        if (await file.exists()) {
          filesToShare.add(XFile(item.path));
        } else {
          missingFiles.add(item.name);
        }
      }

      // 关闭进度对话框
      if (mounted) {
        Navigator.pop(context);
      }

      if (filesToShare.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有找到可导出的文件')),
          );
        }
        return;
      }

      // 分享文件
      await Share.shareXFiles(
        filesToShare,
        subject: '分享: ${filesToShare.length} 个文件',
      );

      // 如果有文件丢失，显示提示
      if (missingFiles.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('以下文件不存在，已跳过：${missingFiles.join(", ")}')),
          );
        }
      }
    } catch (e) {
      // 确保关闭进度对话框
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出文件时出错: $e')),
        );
      }
    }
  }

  // New method for scheduling cleanup
  void _scheduleCleanup(String itemId) {
    _itemsToCleanup.add(itemId);
    _cleanupTimer?.cancel(); // Cancel any existing timer
    _cleanupTimer = Timer(const Duration(seconds: 5), () { // Debounce cleanup by 5 seconds
      _performCleanup();
    });
  }

  // New method to perform the cleanup
  Future<void> _performCleanup() async {
    if (_itemsToCleanup.isEmpty) return;

    debugPrint('开始自动清理无效媒体文件: ${_itemsToCleanup.length} 个');
    Set<String> cleanedItems = Set.from(_itemsToCleanup); // Copy items to avoid modification during iteration
    _itemsToCleanup.clear(); // Clear the main set

    for (var id in cleanedItems) {
      try {
        final item = _mediaItems.firstWhere((i) => i.id == id, orElse: () => null as MediaItem);
        if (item != null) {
          await _deleteMediaItemSilently(item);
          debugPrint('已自动清理无效文件: ${item.name}');
        }
      } catch (e) {
        debugPrint('自动清理文件时出错 ($id): $e');
      }
    }
    
    // Reload media items after cleanup
    await _loadMediaItems();
    debugPrint('无效媒体文件自动清理完成。');
  }

  // New method to delete media item silently (without confirmation dialog)
  Future<void> _deleteMediaItemSilently(MediaItem item) async {
    try {
      await _databaseService.deleteMediaItem(item.id);
      final file = File(item.path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('静默删除媒体项时出错: ${item.name}, 错误: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            _currentDirectory == 'root' ? '媒体' : '媒体 / $_currentDirectory'),
        actions: [
          if (_currentDirectory != 'root')
            IconButton(
              icon: const Icon(Icons.arrow_upward),
              onPressed: _navigateUp,
              tooltip: '返回上级',
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.0),
            child: Center(
              child: Row(
                children: [
                  const Icon(Icons.image, size: 14),
                  const SizedBox(width: 1),
                  Text('$_imageCount', style: const TextStyle(fontSize: 10)),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.0),
            child: Center(
              child: Row(
                children: [
                  const Icon(Icons.videocam, size: 14),
                  const SizedBox(width: 1),
                  Text('$_videoCount', style: const TextStyle(fontSize: 10)),
                ],
              ),
            ),
          ),
          IconButton(
            icon: Icon(
                _mediaVisible ? Icons.visibility : Icons.visibility_off),
            onPressed: _toggleMediaVisibility,
            tooltip: '切换媒体可见性',
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsMenu,
            tooltip: '设置',
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadMediaItems,
            tooltip: '刷新',
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
        ],
      ),
      body: _buildMediaGrid(),
    );
  }
}

