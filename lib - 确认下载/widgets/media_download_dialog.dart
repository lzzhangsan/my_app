import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/media_sniffer_service.dart';
import '../models/media_type.dart' as app_media;
import '../models/media_type.dart';

/// 媒体下载选择对话框
class MediaDownloadDialog extends StatefulWidget {
  final String pageUrl;
  final Function(MediaInfo, app_media.MediaType) onDownload;

  const MediaDownloadDialog({
    super.key,
    required this.pageUrl,
    required this.onDownload,
  });

  @override
  State<MediaDownloadDialog> createState() => _MediaDownloadDialogState();
}

class _MediaDownloadDialogState extends State<MediaDownloadDialog>
    with TickerProviderStateMixin {
  final MediaSnifferService _snifferService = MediaSnifferService();
  List<MediaInfo> _mediaList = [];
  bool _isLoading = true;
  String _errorMessage = '';
  late TabController _tabController;
  
  // 过滤器
  List<MediaInfo> _filteredImages = [];
  List<MediaInfo> _filteredVideos = [];
  List<MediaInfo> _filteredAudios = [];
  
  // 搜索
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  
  // 排序
  String _sortBy = 'probability'; // probability, name, size, format
  bool _sortAscending = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _snifferService.initialize();
    _startSniffing();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
      _applyFilters();
    });
  }

  Future<void> _startSniffing() async {
    try {
      setState(() {
        _isLoading = true;
        _errorMessage = '';
      });

      final mediaList = await _snifferService.sniffMediaFromPage(widget.pageUrl);
      
      // 获取文件大小信息
      for (final media in mediaList) {
        if (media.size == null) {
          final size = await _snifferService.getFileSize(media.url);
          if (size != null) {
            // 创建新的MediaInfo对象，包含大小信息
            final index = mediaList.indexOf(media);
            mediaList[index] = MediaInfo(
              url: media.url,
              name: media.name,
              format: media.format,
              size: size,
              quality: media.quality,
              type: media.type,
              downloadProbability: media.downloadProbability,
              metadata: media.metadata,
            );
          }
        }
      }

      setState(() {
        _mediaList = mediaList;
        _isLoading = false;
        _applyFilters();
      });

      if (_filteredImages.isEmpty && _filteredVideos.isEmpty && _filteredAudios.isEmpty) {
        setState(() {
          if (widget.pageUrl.contains('baidu.com')) {
            _errorMessage = '百度图片需要双击具体的图片才能下载。\n如果双击后仍无法下载，可能是由于网络限制或图片保护机制。';
          } else {
            _errorMessage = '未在此页面发现可下载的媒体文件\n\n可能的原因：\n• 页面使用了防下载保护\n• 媒体文件需要登录访问\n• 网络连接问题\n• 媒体文件动态加载中';
          }
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        if (e.toString().contains('CORS') || e.toString().contains('403')) {
          _errorMessage = '网络访问受限\n\n这通常是由于：\n• 网站的跨域访问限制(CORS)\n• 需要特殊权限访问\n• 网站防爬虫保护\n\n建议尝试双击页面中的具体媒体元素';
        } else if (e.toString().contains('timeout')) {
          _errorMessage = '网络连接超时\n\n请检查：\n• 网络连接是否正常\n• 目标网站是否可访问\n• 稍后重试';
        } else {
          _errorMessage = '媒体嗅探失败\n\n错误信息: $e\n\n建议尝试双击页面中的具体媒体元素';
        }
      });
    }
  }

  void _applyFilters() {
    // 按类型分类
    _filteredImages = _mediaList
        .where((media) => media.type == MediaType.image)
        .where((media) => _matchesSearch(media))
        .toList();
    
    _filteredVideos = _mediaList
        .where((media) => media.type == MediaType.video)
        .where((media) => _matchesSearch(media))
        .toList();
    
    _filteredAudios = _mediaList
        .where((media) => media.type == MediaType.audio)
        .where((media) => _matchesSearch(media))
        .toList();

    // 应用排序
    _sortMediaList(_filteredImages);
    _sortMediaList(_filteredVideos);
    _sortMediaList(_filteredAudios);
  }

  bool _matchesSearch(MediaInfo media) {
    if (_searchQuery.isEmpty) return true;
    
    return media.name.toLowerCase().contains(_searchQuery) ||
           media.format.toLowerCase().contains(_searchQuery) ||
           (media.size?.toLowerCase().contains(_searchQuery) ?? false) ||
           (media.quality?.toLowerCase().contains(_searchQuery) ?? false);
  }

  void _sortMediaList(List<MediaInfo> list) {
    list.sort((a, b) {
      int comparison = 0;
      
      switch (_sortBy) {
        case 'probability':
          comparison = a.downloadProbability.compareTo(b.downloadProbability);
          break;
        case 'name':
          comparison = a.name.compareTo(b.name);
          break;
        case 'size':
          final aSize = a.size ?? '';
          final bSize = b.size ?? '';
          comparison = aSize.compareTo(bSize);
          break;
        case 'format':
          comparison = a.format.compareTo(b.format);
          break;
      }
      
      return _sortAscending ? comparison : -comparison;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            _buildHeader(),
            _buildSearchAndSort(),
            _buildTabBar(),
            Expanded(child: _buildContent()),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).primaryColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(8),
          topRight: Radius.circular(8),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.download, color: Colors.white, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '媒体下载选择',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '发现 ${_mediaList.length} 个媒体文件',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _isLoading ? null : _startSniffing,
            tooltip: '重新嗅探',
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndSort() {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: '搜索媒体文件...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: 12),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: '排序方式',
            onSelected: (value) {
              setState(() {
                if (_sortBy == value) {
                  _sortAscending = !_sortAscending;
                } else {
                  _sortBy = value;
                  _sortAscending = false;
                }
                _applyFilters();
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'probability',
                child: Row(
                  children: [
                    Icon(_sortBy == 'probability' 
                        ? (_sortAscending ? Icons.arrow_upward : Icons.arrow_downward)
                        : Icons.trending_up),
                    const SizedBox(width: 8),
                    const Text('下载可能性'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'name',
                child: Row(
                  children: [
                    Icon(_sortBy == 'name' 
                        ? (_sortAscending ? Icons.arrow_upward : Icons.arrow_downward)
                        : Icons.text_fields),
                    const SizedBox(width: 8),
                    const Text('名称'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'size',
                child: Row(
                  children: [
                    Icon(_sortBy == 'size' 
                        ? (_sortAscending ? Icons.arrow_upward : Icons.arrow_downward)
                        : Icons.storage),
                    const SizedBox(width: 8),
                    const Text('大小'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'format',
                child: Row(
                  children: [
                    Icon(_sortBy == 'format' 
                        ? (_sortAscending ? Icons.arrow_upward : Icons.arrow_downward)
                        : Icons.extension),
                    const SizedBox(width: 8),
                    const Text('格式'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return TabBar(
      controller: _tabController,
      labelColor: Theme.of(context).primaryColor,
      unselectedLabelColor: Colors.grey,
      indicatorColor: Theme.of(context).primaryColor,
      tabs: [
        Tab(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.select_all, size: 18),
              const SizedBox(width: 4),
              Text('全部 (${_mediaList.length})'),
            ],
          ),
        ),
        Tab(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image, size: 18),
              const SizedBox(width: 4),
              Text('图片 (${_filteredImages.length})'),
            ],
          ),
        ),
        Tab(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam, size: 18),
              const SizedBox(width: 4),
              Text('视频 (${_filteredVideos.length})'),
            ],
          ),
        ),
        Tab(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.audiotrack, size: 18),
              const SizedBox(width: 4),
              Text('音频 (${_filteredAudios.length})'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在嗅探媒体文件...'),
            SizedBox(height: 8),
            Text(
              '这可能需要几秒钟时间',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    if (_errorMessage.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _startSniffing,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return TabBarView(
      controller: _tabController,
      children: [
        _buildMediaList(_mediaList.where((media) => _matchesSearch(media)).toList()),
        _buildMediaList(_filteredImages),
        _buildMediaList(_filteredVideos),
        _buildMediaList(_filteredAudios),
      ],
    );
  }

  Widget _buildMediaList(List<MediaInfo> mediaList) {
    if (mediaList.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              '没有找到匹配的媒体文件',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: mediaList.length,
      itemBuilder: (context, index) {
        final media = mediaList[index];
        return _buildMediaItem(media, index);
      },
    );
  }

  Widget _buildMediaItem(MediaInfo media, int index) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: _buildMediaIcon(media),
        title: Text(
          media.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Row(
              children: [
                _buildInfoChip('格式', media.format, Icons.extension),
                const SizedBox(width: 8),
                if (media.size != null)
                  _buildInfoChip('大小', media.size!, Icons.storage),
                if (media.quality != null) ...[
                  const SizedBox(width: 8),
                  _buildInfoChip('质量', media.quality!, Icons.high_quality),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _buildProbabilityIndicator(media.downloadProbability),
                const SizedBox(width: 8),
                if (media.metadata['source'] != null)
                  _buildSourceChip(media.metadata['source']),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: () => _showMediaDetails(media),
              tooltip: '详细信息',
            ),
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () => _copyUrl(media.url),
              tooltip: '复制链接',
            ),
            ElevatedButton.icon(
              onPressed: () => _downloadMedia(media),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('下载'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _getPriorityColor(media.downloadProbability),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }

  Widget _buildMediaIcon(MediaInfo media) {
    IconData iconData;
    Color iconColor;
    
    switch (media.type) {
      case MediaType.image:
        iconData = Icons.image;
        iconColor = Colors.blue;
        break;
      case MediaType.video:
        iconData = Icons.videocam;
        iconColor = Colors.red;
        break;
      case MediaType.audio:
        iconData = Icons.audiotrack;
        iconColor = Colors.green;
        break;
      default:
        iconData = Icons.insert_drive_file;
        iconColor = Colors.grey;
    }
    
    return CircleAvatar(
      backgroundColor: iconColor.withOpacity(0.1),
      child: Icon(iconData, color: iconColor),
    );
  }

  Widget _buildInfoChip(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.grey[600]),
          const SizedBox(width: 4),
          Text(
            '$label: $value',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProbabilityIndicator(double probability) {
    final percentage = (probability * 100).round();
    final color = _getPriorityColor(probability);
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.trending_up, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            '可能性: $percentage%',
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceChip(String source) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.purple[100],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.source, size: 12, color: Colors.purple[600]),
          const SizedBox(width: 4),
          Text(
            '来源: $source',
            style: TextStyle(
              fontSize: 11,
              color: Colors.purple[600],
            ),
          ),
        ],
      ),
    );
  }

  Color _getPriorityColor(double probability) {
    if (probability >= 0.8) return Colors.green;
    if (probability >= 0.6) return Colors.orange;
    if (probability >= 0.4) return Colors.blue;
    return Colors.grey;
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '提示: 下载可能性越高的文件越容易成功下载',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  void _downloadMedia(MediaInfo media) {
    // 转换媒体类型
    app_media.MediaType appMediaType;
    switch (media.type) {
      case MediaType.image:
        appMediaType = app_media.MediaType.image;
        break;
      case MediaType.video:
        appMediaType = app_media.MediaType.video;
        break;
      case MediaType.audio:
        appMediaType = app_media.MediaType.audio;
        break;
      default:
        appMediaType = app_media.MediaType.image;
    }
    
    widget.onDownload(media, appMediaType);
    Navigator.of(context).pop();
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('链接已复制到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _showMediaDetails(MediaInfo media) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('媒体详细信息'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailRow('名称', media.name),
              _buildDetailRow('URL', media.url),
              _buildDetailRow('格式', media.format),
              if (media.size != null) _buildDetailRow('大小', media.size!),
              if (media.quality != null) _buildDetailRow('质量', media.quality!),
              _buildDetailRow('类型', media.type.toString().split('.').last),
              _buildDetailRow('下载可能性', '${(media.downloadProbability * 100).round()}%'),
              if (media.metadata.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  '元数据:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ...media.metadata.entries.map(
                  (entry) => _buildDetailRow(entry.key, entry.value.toString()),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _downloadMedia(media);
            },
            child: const Text('下载'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}