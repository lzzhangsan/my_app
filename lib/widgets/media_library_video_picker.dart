import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../core/service_locator.dart';
import '../services/logger.dart';
import '../services/database_service.dart';
import '../models/media_type.dart';
import '../utils/app_storage_paths.dart';
import 'video_grid_thumbnail.dart';

/// 从应用内媒体库浏览文件夹并选择视频（与 [MediaLibraryImagePicker] 一致，用于背景等）。
class MediaLibraryVideoPicker extends StatefulWidget {
  final void Function(String path)? onVideoSelected;

  const MediaLibraryVideoPicker({
    super.key,
    this.onVideoSelected,
  });

  @override
  State<MediaLibraryVideoPicker> createState() =>
      _MediaLibraryVideoPickerState();
}

class _MediaLibraryVideoPickerState extends State<MediaLibraryVideoPicker> {
  List<Map<String, dynamic>> _videoItems = [];
  List<Map<String, dynamic>> _folderItems = [];
  bool _isLoading = true;
  String _currentDirectory = 'root';
  late final DatabaseService _databaseService;
  final List<String> _directoryPath = ['根目录'];

  @override
  void initState() {
    super.initState();
    _databaseService = getService<DatabaseService>();
    _loadMediaItems();
  }

  Future<void> _loadMediaItems() async {
    setState(() {
      _isLoading = true;
    });
    try {
      await VideoGridThumbnailHelper.primeSyncThumbnailLookup();
      final items = await _databaseService.getMediaItems(_currentDirectory);
      Logger.log('加载媒体项(视频选择): $_currentDirectory, 共 ${items.length} 项');

      setState(() {
        _videoItems =
            items
                .where((item) => item['type'] == MediaType.video.index)
                .toList();
        _folderItems =
            items
                .where((item) => item['type'] == MediaType.folder.index)
                .toList();
        _isLoading = false;
      });
    } catch (e) {
      Logger.log('加载媒体项时出错: $e');
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载视频时出错，请重试。')),
        );
      }
    }
  }

  Future<void> _navigateToDirectory(
    String directoryId,
    String directoryName,
  ) async {
    setState(() {
      _currentDirectory = directoryId;
      _directoryPath.add(directoryName);
    });
    await _loadMediaItems();
  }

  Future<void> _navigateUp() async {
    if (_currentDirectory != 'root' && _directoryPath.length > 1) {
      final parentDir = await _databaseService.getMediaItemParentDirectory(
        _currentDirectory,
      );
      setState(() {
        _currentDirectory = parentDir ?? 'root';
        _directoryPath.removeLast();
      });
      await _loadMediaItems();
    }
  }

  Widget _buildFolderItem(Map<String, dynamic> item) {
    return Card(
      child: InkWell(
        onTap: () => _navigateToDirectory(item['id'], item['name']),
        child: Container(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.folder, size: 40, color: Colors.amber),
              const SizedBox(height: 4),
              Expanded(
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    item['name'],
                    style: const TextStyle(fontSize: 12),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoItem(Map<String, dynamic> item) {
    final srcPath = item['path'] as String? ?? '';
    return Card(
      child: InkWell(
        onTap: () async {
          if (srcPath.isEmpty) return;
          final src = File(srcPath);
          if (!await src.exists()) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('文件不存在或已被移动')),
            );
            return;
          }
          try {
            final diaryDir = await ensureDiaryMediaDirectory();
            final dest = File(
              path.join(
                diaryDir.path,
                '${const Uuid().v4()}${path.extension(srcPath).isNotEmpty ? path.extension(srcPath) : '.mp4'}',
              ),
            );
            await src.copy(dest.path);
            if (!mounted) return;
            if (widget.onVideoSelected != null) {
              widget.onVideoSelected!(dest.path);
            } else {
              Navigator.of(context).pop(dest.path);
            }
          } catch (e) {
            Logger.log('复制媒体库视频失败: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('复制视频失败: $e')),
              );
            }
          }
        },
        child: Column(
          children: [
            Expanded(
              child: srcPath.isNotEmpty && File(srcPath).existsSync()
                  ? VideoGridThumbnail(
                      key: ValueKey('mlv_thumb_$srcPath'),
                      videoPath: srcPath,
                    )
                  : Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                        color: Colors.grey[900],
                      ),
                      child: Center(
                        child: Icon(
                          Icons.videocam_off,
                          color: Colors.grey[600],
                          size: 30,
                        ),
                      ),
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(4),
              child: Text(
                item['name'] as String? ?? '',
                style: const TextStyle(fontSize: 10),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '从媒体库选择视频',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                if (_currentDirectory != 'root')
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _navigateUp,
                    tooltip: '返回上级',
                  ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _directoryPath.join(' / '),
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ),
            const Divider(),
            Expanded(
              child:
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : (_folderItems.isEmpty && _videoItems.isEmpty)
                      ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.video_library,
                              size: 64,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '此文件夹中没有视频',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      )
                      : GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                              childAspectRatio: 0.8,
                            ),
                        itemCount: _folderItems.length + _videoItems.length,
                        itemBuilder: (context, index) {
                          if (index < _folderItems.length) {
                            return _buildFolderItem(_folderItems[index]);
                          }
                          return _buildVideoItem(
                            _videoItems[index - _folderItems.length],
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }
}
