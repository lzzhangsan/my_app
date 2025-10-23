import 'package:flutter/material.dart';
import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'services/logger.dart';

class MediaSelectionDialog extends StatefulWidget {
  final Function(String)? onMediaSelected;
  final Function(String)? onDirectorySelected;
  final String? selectedDirectory;

  const MediaSelectionDialog({
    super.key,
    this.onMediaSelected,
    this.onDirectorySelected,
    this.selectedDirectory,
  });

  @override
  _MediaSelectionDialogState createState() => _MediaSelectionDialogState();
}

class _MediaSelectionDialogState extends State<MediaSelectionDialog> {
  List<Map<String, dynamic>> _mediaItems = [];
  bool _isLoading = true;
  String _currentDirectory = 'root';
  late final DatabaseService _databaseService;

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
      Logger.i('加载媒体项: $_currentDirectory, 共 ${items.length} 项');
      for (var item in items) {
        Logger.d('媒体项: ${item['name']}, 类型: ${item['type']}');
      }
      setState(() {
        _mediaItems = items.where((item) => item['type'] == 3).toList();
        _isLoading = false;
      });
    } catch (e) {
      Logger.e('加载媒体项时出错', e);
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载媒体文件时出错，请重试。')),
        );
      }
    }
  }

  Future<void> _navigateToDirectory(String directoryId) async {
    setState(() {
      _currentDirectory = directoryId;
    });
    await _loadMediaItems();
  }

  Future<void> _navigateUp() async {
    if (_currentDirectory != 'root') {
      final parentDir =
      await _databaseService.getMediaItemParentDirectory(_currentDirectory);
      setState(() {
        _currentDirectory = parentDir ?? 'root';
      });
      await _loadMediaItems();
    }
  }

  String _getFolderNameById(String id) {
    final item = _mediaItems.firstWhere(
          (item) => item['id'] == id,
      orElse: () => {'name': '未知文件夹'},
    );
    return item['name'];
  }

  bool _isSelected(String directoryId) {
    return widget.selectedDirectory == directoryId;
  }

  Widget _buildDirectoryItem(Map<String, dynamic> item) {
    final bool isSelected = _isSelected(item['id']);
    
    return ListTile(
      leading: Icon(
        Icons.folder,
        color: isSelected ? Colors.blue : Colors.amber,
      ),
      title: Text(
        item['name'],
        style: TextStyle(
          color: isSelected ? Colors.blue : null,
          fontWeight: isSelected ? FontWeight.bold : null,
        ),
      ),
      tileColor: isSelected ? Colors.blue.withOpacity(0.1) : null,
      onTap: () {
        if (widget.onDirectorySelected != null) {
          widget.onDirectorySelected!(item['id']);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.8,
        height: MediaQuery.of(context).size.height * 0.7,
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    _currentDirectory == 'root'
                        ? '选择媒体来源'
                        : '选择媒体来源 / ${_getFolderNameById(_currentDirectory)}',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_currentDirectory != 'root')
                  IconButton(
                    icon: Icon(Icons.arrow_upward),
                    onPressed: _navigateUp,
                    tooltip: '返回上级',
                  ),
              ],
            ),
            SizedBox(height: 16),
            if (widget.onDirectorySelected != null)
              ListTile(
                leading: Icon(
                  Icons.library_music,
                  color: _isSelected('root') ? Colors.blue : null,
                ),
                title: Text(
                  '整个媒体库',
                  style: TextStyle(
                    color: _isSelected('root') ? Colors.blue : null,
                    fontWeight: _isSelected('root') ? FontWeight.bold : null,
                  ),
                ),
                tileColor: _isSelected('root') ? Colors.blue.withOpacity(0.1) : null,
                onTap: () {
                  widget.onDirectorySelected!('root');
                },
              ),
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator())
                  : _mediaItems.isEmpty
                      ? Center(child: Text('没有可用的文件夹'))
                      : ListView.builder(
                          itemCount: _mediaItems.length,
                          itemBuilder: (context, index) {
                            final item = _mediaItems[index];
                            return _buildDirectoryItem(item);
                          },
                        ),
            ),
            SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('取消'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}