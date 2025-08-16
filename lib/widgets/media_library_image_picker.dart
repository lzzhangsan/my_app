import 'package:flutter/material.dart';
import 'dart:io';
import '../core/service_locator.dart';
import '../services/database_service.dart';
import '../models/media_type.dart';

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
      print('加载媒体项: $_currentDirectory, 共 ${items.length} 项');
      
      setState(() {
        // 分离图片和文件夹
        _imageItems = items.where((item) => item['type'] == MediaType.image.index).toList();
        _folderItems = items.where((item) => item['type'] == MediaType.folder.index).toList();
        _isLoading = false;
      });
    } catch (e) {
      print('加载媒体项时出错: $e');
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
    return Card(
      child: InkWell(
        onTap: () => _navigateToDirectory(item['id'], item['name']),
        child: Container(
          padding: EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.folder,
                size: 40,
                color: Colors.amber,
              ),
              SizedBox(height: 4),
              Text(
                item['name'],
                style: TextStyle(fontSize: 12),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageItem(Map<String, dynamic> item) {
    return Card(
      child: InkWell(
        onTap: () {
          if (widget.onImageSelected != null) {
            widget.onImageSelected!(item['path']);
          } else {
            Navigator.of(context).pop(item['path']);
          }
        },
        child: Container(
          child: Column(
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
                    child: File(item['path']).existsSync()
                        ? Image.file(
                            File(item['path']),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                color: Colors.grey[300],
                                child: Icon(
                                  Icons.broken_image,
                                  color: Colors.grey[600],
                                  size: 30,
                                ),
                              );
                            },
                          )
                        : Container(
                            color: Colors.grey[300],
                            child: Icon(
                              Icons.image_not_supported,
                              color: Colors.grey[600],
                              size: 30,
                            ),
                          ),
                  ),
                ),
              ),
              Container(
                padding: EdgeInsets.all(4),
                child: Text(
                  item['name'],
                  style: TextStyle(fontSize: 10),
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
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            // 标题栏
            Row(
              children: [
                Expanded(
                  child: Text(
                    '选择背景图片',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                if (_currentDirectory != 'root')
                  IconButton(
                    icon: Icon(Icons.arrow_upward),
                    onPressed: _navigateUp,
                    tooltip: '返回上级',
                  ),
                IconButton(
                  icon: Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            // 路径导航
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _directoryPath.join(' / '),
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ),
            Divider(),
            // 内容区域
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator())
                  : (_folderItems.isEmpty && _imageItems.isEmpty)
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.image_not_supported,
                                size: 64,
                                color: Colors.grey[400],
                              ),
                              SizedBox(height: 16),
                              Text(
                                '此文件夹中没有图片',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        )
                      : GridView.builder(
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 0.8,
                          ),
                          itemCount: _folderItems.length + _imageItems.length,
                          itemBuilder: (context, index) {
                            if (index < _folderItems.length) {
                              return _buildFolderItem(_folderItems[index]);
                            } else {
                              return _buildImageItem(_imageItems[index - _folderItems.length]);
                            }
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}