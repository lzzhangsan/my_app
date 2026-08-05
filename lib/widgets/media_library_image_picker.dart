import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import '../core/service_locator.dart';
import '../services/logger.dart';
import '../services/database_service.dart';
import '../models/media_type.dart';
import '../utils/app_storage_paths.dart';

class MediaLibraryImagePicker extends StatefulWidget {
  final Function(String)? onImageSelected;

  const MediaLibraryImagePicker({
    super.key,
    this.onImageSelected,
  });

  @override
  _MediaLibraryImagePickerState createState() => _MediaLibraryImagePickerState();
}

class _MediaLibraryImagePickerState extends State<MediaLibraryImagePicker> {
  List<Map<String, dynamic>> _imageItems = [];
  List<Map<String, dynamic>> _folderItems = [];
  bool _isLoading = true;
  String _currentDirectory = 'root';
  late final DatabaseService _databaseService;
  List<String> _directoryPath = ['根目录'];

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
      final items = await _databaseService.getMediaItems(_currentDirectory);
      Logger.log('加载媒体项: $_currentDirectory, 共 ${items.length} 项');
      
      setState(() {
        // 分离图片和文件夹
        _imageItems = items.where((item) => item['type'] == MediaType.image.index).toList();
        _folderItems = items.where((item) => item['type'] == MediaType.folder.index).toList();
        _isLoading = false;
      });
    } catch (e) {
      Logger.log('加载媒体项时出错: $e');
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载图片时出错，请重试。')),
        );
      }
    }
  }

  Future<void> _navigateToDirectory(String directoryId, String directoryName) async {
    setState(() {
      _currentDirectory = directoryId;
      _directoryPath.add(directoryName);
    });
    await _loadMediaItems();
  }

  Future<void> _navigateUp() async {
    if (_currentDirectory != 'root' && _directoryPath.length > 1) {
      final parentDir = await _databaseService.getMediaItemParentDirectory(_currentDirectory);
      setState(() {
        _currentDirectory = parentDir ?? 'root';
        _directoryPath.removeLast();
      });
      await _loadMediaItems();
    }
  }

  Widget _buildFolderItem(Map<String, dynamic> item) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _navigateToDirectory(item['id'], item['name']),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF87CEEB), width: 1.2),
            color: Colors.white.withValues(alpha: 0.35),
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.folder, size: 32, color: Colors.amber),
              const SizedBox(height: 2),
              Expanded(
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    item['name'],
                    style: const TextStyle(fontSize: 11, height: 1.1),
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

  Widget _buildImageItem(Map<String, dynamic> item) {
    final srcPath = item['path'] as String? ?? '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
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
                '${const Uuid().v4()}${path.extension(srcPath)}',
              ),
            );
            await src.copy(dest.path);
            if (!mounted) return;
            if (widget.onImageSelected != null) {
              widget.onImageSelected!(dest.path);
            } else {
              Navigator.of(context).pop(dest.path);
            }
          } catch (e) {
            Logger.log('复制媒体库图片到日记目录失败: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('复制图片失败: $e')),
              );
            }
          }
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF87CEEB), width: 1.2),
            color: Colors.white.withValues(alpha: 0.35),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Expanded(
                child:
                    srcPath.isNotEmpty && File(srcPath).existsSync()
                        ? Image.file(
                          File(srcPath),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          errorBuilder: (context, error, stackTrace) {
                            return ColoredBox(
                              color: Colors.grey[300]!,
                              child: Icon(
                                Icons.broken_image,
                                color: Colors.grey[600],
                                size: 26,
                              ),
                            );
                          },
                        )
                        : ColoredBox(
                          color: Colors.grey[300]!,
                          child: Icon(
                            Icons.image_not_supported,
                            color: Colors.grey[600],
                            size: 26,
                          ),
                        ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
                child: Text(
                  item['name'] as String? ?? '',
                  style: const TextStyle(fontSize: 10, height: 1.1),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final contentBottomPad = MediaQuery.viewPaddingOf(context).bottom + 38;
    return Container(
      height: screenHeight * 0.85,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                if (_currentDirectory != 'root')
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                    onPressed: _navigateUp,
                    tooltip: '返回上级',
                  )
                else
                  const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _directoryPath.join(' / '),
                    style: TextStyle(color: Colors.grey[700], fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: '取消',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child:
                _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : (_folderItems.isEmpty && _imageItems.isEmpty)
                    ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.image_not_supported,
                            size: 56,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '此文件夹中没有图片',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    )
                    : GridView.builder(
                      padding: EdgeInsets.fromLTRB(10, 0, 10, contentBottomPad),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                            childAspectRatio: 0.78,
                          ),
                      itemCount: _folderItems.length + _imageItems.length,
                      itemBuilder: (context, index) {
                        if (index < _folderItems.length) {
                          return _buildFolderItem(_folderItems[index]);
                        }
                        return _buildImageItem(
                          _imageItems[index - _folderItems.length],
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}