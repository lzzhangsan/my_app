import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as p;

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'services/browser_service.dart';
import 'services/media_download_service.dart';
import 'services/logger.dart';
import 'services/network_service.dart';
import 'models/media_item.dart';
import 'models/media_type.dart';
import 'media_manager_page.dart';
import 'media_preview_page.dart';
import 'widgets/browser_address_bar.dart';
import 'widgets/browser_home_page.dart';
import 'widgets/safe_modal_sheet_body.dart';
import 'utils/media_sniffer_js.dart';

class BrowserPage extends StatefulWidget {
  final ValueChanged<bool>? onBrowserHomePageChanged;
  final int? currentMainPageIndex;

  const BrowserPage({
    Key? key,
    this.onBrowserHomePageChanged,
    this.currentMainPageIndex,
  }) : super(key: key);

  @override
  _BrowserPageState createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  InAppWebViewController? _controller;
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  double _loadingProgress = 0.0;
  String _currentUrl = 'https://www.baidu.com';
  bool _showHomePage = true;
  bool _isBrowsingWebPage = false;

  final BrowserService _browserService = BrowserService();
  final MediaDownloadService _downloadService = MediaDownloadService();
  final DatabaseService _databaseService = getService<DatabaseService>();

  List<Map<String, dynamic>> _commonWebsites = [];
  List<Map<String, String>> _bookmarks = [];
  Map<String, String> _videoSourceUrlToMediaId = {};

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    _commonWebsites = await _browserService.loadCommonWebsites();
    _bookmarks = await _browserService.loadBookmarks();
    _videoSourceUrlToMediaId = await _browserService.loadVideoSourceUrlMap();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant BrowserPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentMainPageIndex == 3 && oldWidget.currentMainPageIndex != 3 && !_showHomePage) {
      _goToHomePage();
    }
  }

  void _loadUrl(String url) {
    String processedUrl = url.trim();
    if (!processedUrl.startsWith('http://') && !processedUrl.startsWith('https://')) {
      processedUrl = 'https://$processedUrl';
    }
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(processedUrl)));
    setState(() {
      _showHomePage = false;
      _currentUrl = processedUrl;
      _urlController.text = processedUrl;
      _isBrowsingWebPage = true;
    });
    widget.onBrowserHomePageChanged?.call(_showHomePage);
  }

  Future<void> _goToHomePage() async {
    setState(() => _showHomePage = true);
    widget.onBrowserHomePageChanged?.call(_showHomePage);
  }

  void _onMessageReceived(String message) async {
    try {
      final data = jsonDecode(message);
      if (data['type'] == 'media' && data['action'] == 'download') {
        final url = data['url'];
        final isBase64 = data['isBase64'] ?? false;
        final mediaType = data['mediaType'] == 'image' ? MediaType.image : MediaType.video;

        if (isBase64) {
          await _handleBase64Download(url, mediaType);
        } else {
          await _handleUrlDownload(url, mediaType);
        }
      }
    } catch (e) {
      Logger.log('Error handling JS message: $e');
    }
  }

  Future<void> _handleBase64Download(String base64, MediaType type) async {
    final bytes = base64Decode(base64.split(',').last);
    final appDir = await getApplicationDocumentsDirectory();
    final file = File('${appDir.path}/media/${const Uuid().v4()}${type == MediaType.image ? ".jpg" : ".mp4"}');
    await file.create(recursive: true);
    await file.writeAsBytes(bytes);
    await _downloadService.saveToMediaLibrary(file, type);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存到媒体库')));
    }
  }

  Future<void> _handleUrlDownload(String url, MediaType type) async {
    final absoluteUrl = _toAbsoluteUrl(url);
    final referer = _getReferer(absoluteUrl);
    
    // 检查重复
    final existing = await _findExistingVideo(absoluteUrl);
    if (existing != null) {
      _showDuplicateDialog(existing);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('开始下载...')));
    
    try {
      final file = await _downloadService.downloadFile(
        absoluteUrl,
        type,
        referer: referer,
        userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        onProgress: (p, {detail}) {
          // Update global download progress if needed
        },
      );

      if (file != null) {
        await _downloadService.saveToMediaLibrary(file, type);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('下载成功')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    }
  }

  String _toAbsoluteUrl(String url) {
    if (url.startsWith('http')) return url;
    final baseUri = Uri.parse(_currentUrl);
    return baseUri.resolve(url).toString();
  }

  String _getReferer(String url) {
    if (url.contains('baidu.com')) return 'https://www.baidu.com';
    return _currentUrl;
  }

  Future<Map<String, dynamic>?> _findExistingVideo(String url) async {
    final mediaId = _videoSourceUrlToMediaId[url];
    if (mediaId != null) {
      return await _databaseService.getMediaItemById(mediaId);
    }
    return null;
  }

  void _showDuplicateDialog(Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('视频已存在'),
        content: Text('文件: ${item['name']}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (c) => MediaPreviewPage(mediaItems: [MediaItem.fromMap(item)], initialIndex: 0)));
            },
            child: const Text('查看'),
          ),
        ],
      ),
    );
  }

  void _showAddWebsiteDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加网站'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '名称')),
            TextField(controller: urlController, decoration: const InputDecoration(labelText: '地址')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && urlController.text.isNotEmpty) {
                final newSite = {
                  'name': nameController.text,
                  'url': urlController.text,
                  'iconCode': Icons.public.codePoint,
                };
                setState(() => _commonWebsites.add(newSite));
                await _browserService.saveCommonWebsites(_commonWebsites);
                Navigator.pop(ctx);
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showWebsiteOptions(Map<String, dynamic> website, int index) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeModalSheetScrollable(
        children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _showRenameDialog(website, index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('删除'),
              onTap: () async {
                setState(() => _commonWebsites.removeAt(index));
                await _browserService.saveCommonWebsites(_commonWebsites);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(Map<String, dynamic> website, int index) {
    final controller = TextEditingController(text: website['name']);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: controller),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              setState(() => _commonWebsites[index]['name'] = controller.text);
              await _browserService.saveCommonWebsites(_commonWebsites);
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            BrowserAddressBar(
              controller: _urlController,
              isLoading: _isLoading,
              progress: _loadingProgress,
              onHome: _goToHomePage,
              onBack: () => _controller?.goBack(),
              onForward: () => _controller?.goForward(),
              onRefresh: () => _controller?.reload(),
              onSubmitted: () => _loadUrl(_urlController.text),
            ),
            Expanded(
              child: Stack(
                children: [
                  InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(_currentUrl)),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      controller.addJavaScriptHandler(
                        handlerName: 'Flutter',
                        callback: (args) => _onMessageReceived(args[0]),
                      );
                    },
                    onLoadStart: (controller, url) {
                      setState(() {
                        _isLoading = true;
                        _currentUrl = url.toString();
                        _urlController.text = _currentUrl;
                      });
                    },
                    onLoadStop: (controller, url) async {
                      setState(() => _isLoading = false);
                      await controller.evaluateJavascript(source: MediaSnifferJs.snifferScript);
                    },
                    onProgressChanged: (controller, progress) {
                      setState(() => _loadingProgress = progress / 100);
                    },
                  ),
                  if (_showHomePage)
                    Container(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: BrowserHomePage(
                        commonWebsites: _commonWebsites,
                        onWebsiteTap: _loadUrl,
                        onAddWebsite: () => _showAddWebsiteDialog(),
                        onWebsiteLongPress: (w, i) => _showWebsiteOptions(w, i),
                        onReorder: (oldIdx, newIdx) {
                          setState(() {
                            if (oldIdx < newIdx) newIdx -= 1;
                            final item = _commonWebsites.removeAt(oldIdx);
                            _commonWebsites.insert(newIdx, item);
                          });
                          _browserService.saveCommonWebsites(_commonWebsites);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
