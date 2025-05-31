import 'dart:io';
import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
// import 'package:ffmpeg_kit_flutter_full/ffmpeg_kit.dart';  // 临时禁用
// import 'package:ffmpeg_kit_flutter_full/return_code.dart';  // 临时禁用
import 'package:photo_manager/photo_manager.dart';
// import 'package:video_thumbnail/video_thumbnail.dart';  // 临时禁用

import 'database_helper.dart';
import 'models/media_item.dart';
import 'media_preview_page.dart';
import 'create_folder_dialog.dart';

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
  final DatabaseHelper _databaseHelper = DatabaseHelper();
  int _imageCount = 0;
  int _videoCount = 0;
  bool _mediaVisible = true;
  final Set<String> _selectedItems = {};
  bool _isMultiSelectMode = false;
  final Map<String, File?> _videoThumbnailCache = {};
  String? _lastViewedVideoId;
  final StreamController<String> _progressController = StreamController<String>.broadcast();

  // 临时禁用FFmpeg功能的占位方法
  Future<void> _processVideoWithFFmpeg(String inputPath, String outputPath) async {
    print('FFmpeg功能临时禁用 - 输入: $inputPath, 输出: $outputPath');
    // 简单复制文件作为临时解决方案
    try {
      final inputFile = File(inputPath);
      final outputFile = File(outputPath);
      await inputFile.copy(outputFile.path);
      print('视频文件已复制（FFmpeg功能临时禁用）');
    } catch (e) {
      print('视频处理失败: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadMediaItems();
  }

  @override
  void dispose() {
    _progressController.close();
    super.dispose();
  }

  Future<void> _loadMediaItems() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final items = await _databaseHelper.getMediaItemsByDirectory(_currentDirectory);
      setState(() {
        _mediaItems.clear();
        _mediaItems.addAll(items);
        _updateCounts();
        _isLoading = false;
      });
    } catch (e) {
      print('加载媒体项目时出错: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _updateCounts() {
    _imageCount = _mediaItems.where((item) => item.type == 'image').length;
    _videoCount = _mediaItems.where((item) => item.type == 'video').length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('媒体管理器 - $_currentDirectory'),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(_mediaVisible ? Icons.visibility : Icons.visibility_off),
            onPressed: () {
              setState(() {
                _mediaVisible = !_mediaVisible;
              });
            },
          ),
          if (_isMultiSelectMode)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _selectedItems.isNotEmpty ? _deleteSelectedItems : null,
            ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showAddMediaDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey[100],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildCountCard('图片', _imageCount, Icons.image, Colors.blue),
                _buildCountCard('视频', _videoCount, Icons.videocam, Colors.red),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _mediaVisible
                    ? _buildMediaGrid()
                    : const Center(
                        child: Text(
                          '媒体已隐藏',
                          style: TextStyle(fontSize: 18, color: Colors.grey),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountCard(String title, int count, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 32, color: color),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              count.toString(),
              style: TextStyle(fontSize: 20, color: color, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaGrid() {
    if (_mediaItems.isEmpty) {
      return const Center(
        child: Text(
          '暂无媒体文件',
          style: TextStyle(fontSize: 18, color: Colors.grey),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: _mediaItems.length,
      itemBuilder: (context, index) {
        final item = _mediaItems[index];
        return _buildMediaCard(item);
      },
    );
  }

  Widget _buildMediaCard(MediaItem item) {
    final isSelected = _selectedItems.contains(item.id);
    
    return GestureDetector(
      onTap: () {
        if (_isMultiSelectMode) {
          setState(() {
            if (isSelected) {
              _selectedItems.remove(item.id);
            } else {
              _selectedItems.add(item.id);
            }
            if (_selectedItems.isEmpty) {
              _isMultiSelectMode = false;
            }
          });
        } else {
          _openMediaPreview(item);
        }
      },
      onLongPress: () {
        setState(() {
          _isMultiSelectMode = true;
          _selectedItems.add(item.id);
        });
      },
      child: Card(
        elevation: isSelected ? 8 : 2,
        color: isSelected ? Colors.blue[100] : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  color: Colors.grey[200],
                ),
                child: item.type == 'image'
                    ? _buildImageThumbnail(item)
                    : _buildVideoThumbnail(item),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${item.type} • ${_formatFileSize(item.size)}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageThumbnail(MediaItem item) {
    if (item.filePath != null && File(item.filePath!).existsSync()) {
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
        child: Image.file(
          File(item.filePath!),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return const Center(
              child: Icon(Icons.broken_image, size: 50, color: Colors.grey),
            );
          },
        ),
      );
    }
    return const Center(
      child: Icon(Icons.image, size: 50, color: Colors.grey),
    );
  }

  Widget _buildVideoThumbnail(MediaItem item) {
    return Stack(
      children: [
        Container(
          width: double.infinity,
          height: double.infinity,
          color: Colors.black12,
          child: const Icon(
            Icons.play_circle_outline,
            size: 50,
            color: Colors.grey,
          ),
        ),
        const Positioned(
          bottom: 8,
          right: 8,
          child: Icon(
            Icons.videocam,
            color: Colors.white,
            size: 20,
          ),
        ),
      ],
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  void _openMediaPreview(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MediaPreviewPage(mediaItem: item),
      ),
    );
  }

  void _showAddMediaDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加媒体'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(context);
                _pickImageFromCamera();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.pop(context);
                _pickImageFromGallery();
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('录制视频'),
              onTap: () {
                Navigator.pop(context);
                _pickVideoFromCamera();
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('从视频库选择'),
              onTap: () {
                Navigator.pop(context);
                _pickVideoFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImageFromCamera() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.camera);
    if (pickedFile != null) {
      await _saveMediaItem(File(pickedFile.path), 'image');
    }
  }

  Future<void> _pickImageFromGallery() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      await _saveMediaItem(File(pickedFile.path), 'image');
    }
  }

  Future<void> _pickVideoFromCamera() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickVideo(source: ImageSource.camera);
    if (pickedFile != null) {
      await _saveMediaItem(File(pickedFile.path), 'video');
    }
  }

  Future<void> _pickVideoFromGallery() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickVideo(source: ImageSource.gallery);
    if (pickedFile != null) {
      await _saveMediaItem(File(pickedFile.path), 'video');
    }
  }

  Future<void> _saveMediaItem(File file, String type) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory(path.join(appDir.path, 'media'));
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }

      final fileName = '${const Uuid().v4()}.${path.extension(file.path).substring(1)}';
      final newPath = path.join(mediaDir.path, fileName);
      final newFile = await file.copy(newPath);

      final mediaItem = MediaItem(
        id: const Uuid().v4(),
        name: fileName,
        type: type,
        filePath: newFile.path,
        size: await newFile.length(),
        createdAt: DateTime.now(),
        directory: _currentDirectory,
      );

      await _databaseHelper.insertMediaItem(mediaItem);
      await _loadMediaItems();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${type == 'image' ? '图片' : '视频'}已保存')),
        );
      }
    } catch (e) {
      print('保存媒体文件时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败')),
        );
      }
    }
  }

  Future<void> _deleteSelectedItems() async {
    try {
      for (final itemId in _selectedItems) {
        final item = _mediaItems.firstWhere((item) => item.id == itemId);
        if (item.filePath != null) {
          final file = File(item.filePath!);
          if (await file.exists()) {
            await file.delete();
          }
        }
        await _databaseHelper.deleteMediaItem(itemId);
      }

      setState(() {
        _selectedItems.clear();
        _isMultiSelectMode = false;
      });

      await _loadMediaItems();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除选中的项目')),
        );
      }
    } catch (e) {
      print('删除项目时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败')),
        );
      }
    }
  }
}