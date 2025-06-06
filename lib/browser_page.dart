import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'models/media_item.dart';
import 'models/media_type.dart';
import 'main.dart'; // 添加导入以访问MainScreen

class BrowserPage extends StatefulWidget {
  final ValueChanged<bool>? onBrowserHomePageChanged;

  const BrowserPage({Key? key, this.onBrowserHomePageChanged}) : super(key: key);

  @override
  _BrowserPageState createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late WebViewController _controller;
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  double _loadingProgress = 0.0;
  String _currentUrl = 'https://www.baidu.com';
  late final DatabaseService _databaseService;
  final List<String> _bookmarks = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  
  bool _showHomePage = true;
  bool _isBrowsingWebPage = false;
  bool _shouldKeepWebPageState = false;
  String? _lastBrowsedUrl;
  
  final List<Map<String, dynamic>> _commonWebsites = [
    {'name': 'Google', 'url': 'https://www.google.com', 'icon': Icons.search},
    {'name': 'Edge', 'url': 'https://www.microsoft.com/edge', 'icon': Icons.web},
    {'name': 'X', 'url': 'https://twitter.com', 'icon': Icons.chat},
    {'name': 'Facebook', 'url': 'https://www.facebook.com', 'icon': Icons.facebook},
    {'name': 'Telegram', 'url': 'https://web.telegram.org', 'icon': Icons.send},
    {'name': '百度', 'url': 'https://www.baidu.com', 'icon': Icons.search},
  ];
  
  bool _isEditMode = false;
  
  Future<void> _toggleEditMode() async {
    final wasInEditMode = _isEditMode;
    setState(() {
      _isEditMode = !_isEditMode;
    });
    if (wasInEditMode && !_isEditMode) {
      debugPrint('从编辑模式退出，保存网站列表');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正在保存常用网站...')));
      await _saveCommonWebsites();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('常用网站已保存')));
    }
  }

  Future<void> _removeWebsite(int index) async {
    final removedSite = _commonWebsites[index]['name'];
    setState(() {
      _commonWebsites.removeAt(index);
    });
    await _saveCommonWebsites();
    debugPrint('已删除并保存网站: $removedSite');
  }

  Future<void> _reorderWebsites(int oldIndex, int newIndex) async {
    setState(() {
      if (oldIndex < newIndex) newIndex -= 1;
      final item = _commonWebsites.removeAt(oldIndex);
      _commonWebsites.insert(newIndex, item);
    });
    await _saveCommonWebsites();
    debugPrint('已移动并保存网站从位置 $oldIndex 到 $newIndex');
  }

  Future<void> _addWebsite(String name, String url, IconData icon) async {
    setState(() {
      _commonWebsites.add({'name': name, 'url': url, 'iconCode': icon.codePoint});
    });
    await _saveCommonWebsites();
    debugPrint('已添加并保存网站: $name');
  }

  @override
  void initState() {
    super.initState();
    _databaseService = getService<DatabaseService>();
    _initializeDownloader();
    _initializeWebView();
    _loadBookmarks();
    _loadCommonWebsites();
  }

  Future<void> _initializeDownloader() async {
    await FlutterDownloader.initialize();
    await _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await Permission.storage.request();
    if (Platform.isAndroid) {
      await Permission.manageExternalStorage.request();
    }
  }

  void _initializeWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.162 Mobile Safari/537.36')
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..runJavaScript('''
        document.body.style.overflowX = 'hidden';
        document.documentElement.style.overflowX = 'hidden';
      ''')
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            setState(() {
              _loadingProgress = progress / 100;
              _isLoading = _loadingProgress < 1.0;
            });
          },
          onPageStarted: (url) {
            setState(() {
              _isLoading = true;
              _currentUrl = url;
              _urlController.text = url;
              _showHomePage = false;
            });
          },
          onPageFinished: (url) {
            setState(() {
              _isLoading = false;
              _currentUrl = url;
            });
            _controller.runJavaScript('''
              document.querySelectorAll('input').forEach(function(input) {
                input.autocomplete = 'on';
              });
            ''');
            _injectDownloadHandlers();
          },
          onWebResourceError: (error) {
            debugPrint('WebView错误: ${error.description}');
          },
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            debugPrint('导航请求: $url');
            if (_isDownloadableLink(url)) {
              debugPrint('检测到可能的下载链接: $url');
              _handleDownload(url, '', _guessMimeType(url));
              return NavigationDecision.prevent;
            }
            if (_isTelegramMediaLink(url)) {
              debugPrint('检测到电报媒体链接: $url');
              _handleDownload(url, '', _guessMimeType(url));
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (JavaScriptMessage message) {
          debugPrint('来自JavaScript的消息: ${message.message}');
          _handleJavaScriptMessage(message.message);
        },
      );
  }
  
  bool _isTelegramMediaLink(String url) {
    final telegramMediaPatterns = [
      'telegram.org/file/',
      't.me/file/',
      'web.telegram.org/file/',
      'cdn.telegram.org/',
      'cdn-telegram.org/',
      'tg://file',
      'tg://media',
      'tg://photo',
      'tg://video',
    ];
    for (final pattern in telegramMediaPatterns) {
      if (url.contains(pattern)) return true;
    }
    if (url.contains('telegram') || url.contains('t.me')) {
      final mediaExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.mp4', '.webp', '.webm'];
      for (final ext in mediaExtensions) {
        if (url.toLowerCase().contains(ext)) return true;
      }
    }
    return false;
  }
  
  // 添加下载状态跟踪
  final Set<String> _downloadingUrls = {};
  final Set<String> _processedUrls = {};

  void _injectDownloadHandlers() {
    debugPrint('为所有网站注入媒体下载处理程序');
    _controller.runJavaScript('''
      // 辅助函数：检查URL是否是Blob URL
      function isBlobUrl(url) {
        return url && typeof url === 'string' && url.startsWith('blob:');
      }

      // 辅助函数：将Blob URL转换为Base64数据
      async function resolveBlobUrl(blobUrl, mediaType) {
        try {
          const response = await fetch(blobUrl, { method: 'GET' });
          if (!response.ok) throw new Error('Fetch failed: ' + response.statusText);
          const blob = await response.blob();
          const reader = new FileReader();
          return new Promise((resolve, reject) => {
            reader.onloadend = () => resolve({ resolvedUrl: reader.result.split(',')[1], isBase64: true });
            reader.onerror = reject;
            reader.readAsDataURL(blob);
          });
        } catch (error) {
          console.error('Error resolving Blob URL:', error);
          return null;
        }
      }

      // 防止重复处理的URL集合
      window.processedMediaUrls = window.processedMediaUrls || new Set();

      // 监听点击事件以检测媒体
      document.addEventListener('click', async function(e) {
        let target = e.target;
        while (target != null) {
          let mediaUrl = null;
          let mediaType = null;
          
          // 检测图片
          if (target.tagName === 'IMG') {
            mediaUrl = target.src || target.getAttribute('data-src') || target.getAttribute('data-original');
            mediaType = 'image';
          }
          // 检测视频 - 增强检测逻辑
          else if (target.tagName === 'VIDEO') {
            mediaUrl = target.src || target.currentSrc;
            // 如果video元素没有直接的src，检查source子元素
            if (!mediaUrl) {
              const sources = target.querySelectorAll('source');
              for (let source of sources) {
                if (source.src) {
                  mediaUrl = source.src;
                  break;
                }
              }
            }
            mediaType = 'video';
          }
          // 检测包含视频的容器元素
          else if (target.querySelector('video')) {
            const videoElement = target.querySelector('video');
            mediaUrl = videoElement.src || videoElement.currentSrc;
            if (!mediaUrl) {
              const sources = videoElement.querySelectorAll('source');
              for (let source of sources) {
                if (source.src) {
                  mediaUrl = source.src;
                  break;
                }
              }
            }
            mediaType = 'video';
          }
          // 检测Telegram特有的媒体容器
          else if (target.classList && (target.classList.contains('media-photo') || target.classList.contains('media-video') || target.classList.contains('video-message'))) {
            const imgElement = target.querySelector('img');
            const videoElement = target.querySelector('video');
            if (videoElement) {
              mediaUrl = videoElement.src || videoElement.currentSrc;
              if (!mediaUrl) {
                const sources = videoElement.querySelectorAll('source');
                for (let source of sources) {
                  if (source.src) {
                    mediaUrl = source.src;
                    break;
                  }
                }
              }
              mediaType = 'video';
            } else if (imgElement) {
              mediaUrl = imgElement.src || imgElement.getAttribute('data-src');
              mediaType = 'image';
            }
          }
          
          if (mediaUrl && mediaType && !window.processedMediaUrls.has(mediaUrl)) {
            window.processedMediaUrls.add(mediaUrl);
            console.log('Detected media:', mediaType, mediaUrl);
            
            if (isBlobUrl(mediaUrl)) {
              console.log('Detected Blob URL:', mediaUrl);
              const result = await resolveBlobUrl(mediaUrl, mediaType);
              if (result) {
                Flutter.postMessage(JSON.stringify({
                  type: 'media',
                  mediaType: mediaType,
                  url: result.resolvedUrl,
                  isBase64: result.isBase64
                }));
              }
            } else {
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: mediaType,
                url: mediaUrl,
                isBase64: false
              }));
            }
            e.preventDefault();
            break;
          }
          target = target.parentElement;
        }
      }, true);



      // 定期检查并监控下载链接和Telegram特殊元素
      setInterval(function() {
        // 检查下载链接
        document.querySelectorAll('a[download], a[href*="/file/"], a[href*="/media/"], button:contains("Download"), button:contains("下载")').
forEach(function(element) {
          if (!element.hasAttribute('data-download-monitored')) {
            element.setAttribute('data-download-monitored', 'true');
            element.addEventListener('click', function(e) {
              let url = element.href || element.getAttribute('data-url') || element.getAttribute('data-src');
              if (url && !window.processedMediaUrls.has(url)) {
                window.processedMediaUrls.add(url);
                Flutter.postMessage(JSON.stringify({
                  type: 'download',
                  url: url
                }));
              }
            });
          }
        });
        
        // 特别检查Telegram的视频元素
        document.querySelectorAll('video, .video-message, .media-video, [data-entity-type="messageMediaVideo"]').forEach(function(element) {
          if (!element.hasAttribute('data-telegram-monitored')) {
            element.setAttribute('data-telegram-monitored', 'true');
            
            let videoUrl = null;
            if (element.tagName === 'VIDEO') {
              videoUrl = element.src || element.currentSrc;
              if (!videoUrl) {
                const sources = element.querySelectorAll('source');
                for (let source of sources) {
                  if (source.src) {
                    videoUrl = source.src;
                    break;
                  }
                }
              }
            } else {
              const videoElement = element.querySelector('video');
              if (videoElement) {
                videoUrl = videoElement.src || videoElement.currentSrc;
              }
            }
            
            if (videoUrl && !window.processedMediaUrls.has(videoUrl)) {
              console.log('发现Telegram视频:', videoUrl);
              // 自动触发检测
              window.processedMediaUrls.add(videoUrl);
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: 'video',
                url: videoUrl,
                isBase64: false
              }));
            }
          }
        });
      }, 2000);
    ''');
  }
  
  void _handleJavaScriptMessage(String message) {
    try {
      final data = jsonDecode(message);
      if (data is Map && data.containsKey('type')) {
        final type = data['type'];
        final url = data['url'];
        final isBase64 = data['isBase64'] ?? false;
        if (url != null && url is String) {
          // 防止重复处理相同的URL
          if (_processedUrls.contains(url)) {
            debugPrint('URL已处理过，跳过: $url');
            return;
          }
          _processedUrls.add(url);
          
          if (type == 'media') {
            final mediaType = data['mediaType'] ?? 'image';
            debugPrint('从JavaScript接收到媒体URL: $url，类型: $mediaType, 是否Base64: $isBase64');
            if (isBase64) {
              _handleBlobUrl(url, mediaType);
            } else {
              _showDownloadDialog(url, mediaType);
            }
          } else if (type == 'download') {
            debugPrint('从JavaScript接收到下载URL: $url');
            _handleDownload(url, '', _guessMimeType(url));
          }
        }
      }
    } catch (e) {
      debugPrint('处理JavaScript消息时出错: $e');
    }
  }

  void _handleBlobUrl(String base64Data, String mediaType) async {
    try {
      final bytes = base64Decode(base64Data);
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final uuid = const Uuid().v4();
      final extension = mediaType == 'image' ? '.jpg' : '.mp4';
      final filePath = '${mediaDir.path}/$uuid$extension';
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      debugPrint('已从Base64保存文件: $filePath');
      await _saveToMediaLibrary(file, mediaType == 'image' ? MediaType.image : MediaType.video);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('媒体已成功保存到媒体库: ${file.path.split('/').last}'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: '查看',
              onPressed: () => Navigator.pushNamed(context, '/media_manager'),
            ),
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('处理Base64数据时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    }
  }

  void _showDownloadDialog(String url, String mediaType) {
    MediaType selectedType = mediaType == 'image' ? MediaType.image : MediaType.video;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('下载媒体'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('您想下载这个 $mediaType 吗？'),
              const SizedBox(height: 8),
              Text('URL: $url', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              const SizedBox(height: 16),
              const Text('选择媒体类型:'),
              RadioListTile<MediaType>(
                title: const Text('图片'),
                value: MediaType.image,
                groupValue: selectedType,
                onChanged: (value) => setState(() => selectedType = value!),
              ),
              RadioListTile<MediaType>(
                title: const Text('视频'),
                value: MediaType.video,
                groupValue: selectedType,
                onChanged: (value) => setState(() => selectedType = value!),
              ),
              RadioListTile<MediaType>(
                title: const Text('音频'),
                value: MediaType.audio,
                groupValue: selectedType,
                onChanged: (value) => setState(() => selectedType = value!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                String mimeType = selectedType == MediaType.image ? 'image/jpeg' : selectedType == MediaType.video ? 'video/mp4' : 'audio/mpeg';
                _handleDownload(url, '', mimeType, selectedType: selectedType);
              },
              child: const Text('下载'),
            ),
          ],
        ),
      ),
    );
  }

  void _loadUrl(String url) {
    String processedUrl = url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      processedUrl = 'https://$url';
    }
    if (processedUrl.contains('telegram.org') || processedUrl.contains('t.me') || processedUrl.contains('web.telegram.org')) {
      debugPrint('检测到电报网站，强制使用移动版');
      _controller.setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1');
      if (processedUrl.contains('web.telegram.org')) {
        processedUrl = 'https://web.telegram.org/a/';
      }
    } else {
      _controller.setUserAgent('Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.162 Mobile Safari/537.36');
    }
    _controller.loadRequest(Uri.parse(processedUrl));
    setState(() {
      _showHomePage = false;
      _currentUrl = processedUrl;
      _urlController.text = processedUrl;
      _isBrowsingWebPage = true;
      _shouldKeepWebPageState = true;
      _lastBrowsedUrl = processedUrl;
      debugPrint('[_loadUrl] Loaded: $processedUrl, _showHomePage: $_showHomePage, _isBrowsingWebPage: $_isBrowsingWebPage');
    });
    widget.onBrowserHomePageChanged?.call(_showHomePage);
    debugPrint('[_loadUrl] Called onBrowserHomePageChanged(${_showHomePage})');
  }

  Future<void> _goToHomePage() async {
    debugPrint('[_goToHomePage] Called. Current _showHomePage: $_showHomePage');
    if (!_showHomePage) {
      await _saveCommonWebsites();
      debugPrint('[_goToHomePage] 已保存常用网站');
      await _loadBookmarks();
      await _loadCommonWebsites();
      debugPrint('[_goToHomePage] 已重新加载书签和常用网站');
      setState(() {
        _showHomePage = true;
        debugPrint('[_goToHomePage] setState _showHomePage = true');
      });
      widget.onBrowserHomePageChanged?.call(_showHomePage);
      debugPrint('[_goToHomePage] Called onBrowserHomePageChanged(${_showHomePage})');
      debugPrint('[_goToHomePage] 已返回常用网站首页视图，保持网页实例状态');
    }
  }

  void _restoreWebPage() {
    debugPrint('[_restoreWebPage] Called. Current _showHomePage: $_showHomePage, _isBrowsingWebPage: $_isBrowsingWebPage, _shouldKeepWebPageState: $_shouldKeepWebPageState');
    if (_showHomePage && _isBrowsingWebPage && _shouldKeepWebPageState) {
      setState(() {
        _showHomePage = false;
        debugPrint('[_restoreWebPage] setState _showHomePage = false');
      });
      widget.onBrowserHomePageChanged?.call(_showHomePage);
      debugPrint('[_restoreWebPage] Called onBrowserHomePageChanged(${_showHomePage})');
      debugPrint('[_restoreWebPage] 恢复网页浏览状态');
    } else {
      debugPrint('[_restoreWebPage] Cannot restore web page. State: _showHomePage: $_showHomePage, _isBrowsingWebPage: $_isBrowsingWebPage, _shouldKeepWebPageState: $_shouldKeepWebPageState');
    }
  }

  void _exitWebPage() {
    debugPrint('[_exitWebPage] Called.');
    setState(() {
      _showHomePage = true;
      _isBrowsingWebPage = false;
      _shouldKeepWebPageState = false;
      _lastBrowsedUrl = null;
      _controller.clearCache();
      _controller.clearLocalStorage();
      debugPrint('[_exitWebPage] setState _showHomePage = true, states reset');
      _currentUrl = 'https://www.baidu.com';
      _urlController.text = _currentUrl;
    });
    widget.onBrowserHomePageChanged?.call(_showHomePage);
    debugPrint('[_exitWebPage] Called onBrowserHomePageChanged(${_showHomePage})');
    debugPrint('[_exitWebPage] Completely exited web view and returned to common websites home view');
  }

  Widget _buildHomePage() {
    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '常用网站',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(_isEditMode ? Icons.done : Icons.edit),
                        onPressed: () async {
                          debugPrint('[_AppBar] Edit button pressed.');
                          showDialog(
                            context: context,
                            barrierDismissible: false,
                            builder: (BuildContext context) {
                              return const AlertDialog(
                                content: Row(
                                  children: [
                                    CircularProgressIndicator(),
                                    SizedBox(width: 20),
                                    Text("处理中..."),
                                  ],
                                ),
                              );
                            },
                          );
                          await _toggleEditMode();
                          Navigator.of(context).pop();
                        },
                        tooltip: _isEditMode ? '完成编辑' : '编辑网站',
                      ),
                      if (_isEditMode)
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: () => _showAddWebsiteDialog(context),
                          tooltip: '添加网站',
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: _isEditMode
                  ? ReorderableListView.builder(
                      padding: const EdgeInsets.all(16.0),
                      itemCount: _commonWebsites.length,
                      itemBuilder: (context, index) {
                        final website = _commonWebsites[index];
                        return _buildEditableWebsiteItem(website, index);
                      },
                      onReorder: _reorderWebsites,
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16.0),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 1.0,
                        crossAxisSpacing: 16.0,
                        mainAxisSpacing: 16.0,
                      ),
                      itemCount: _commonWebsites.length,
                      itemBuilder: (context, index) {
                        final website = _commonWebsites[index];
                        return _buildWebsiteCard(website);
                      },
                    ),
            ),
          ],
        ),
        if (_isBrowsingWebPage && _shouldKeepWebPageState)
          Positioned(
            bottom: 16.0,
            right: 16.0,
            child: FloatingActionButton(
              onPressed: _restoreWebPage,
              tooltip: '返回上次浏览的网页',
              child: const Icon(Icons.arrow_right_alt),
            ),
          ),
      ],
    );
  }

  void _showAddWebsiteDialog(BuildContext context) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加网站'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '网站名称',
                hintText: '例如：Google',
              ),
            ),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: '网站地址',
                hintText: '例如：https://www.google.com',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && urlController.text.isNotEmpty) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (BuildContext context) {
                    return const AlertDialog(
                      content: Row(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(width: 20),
                          Text("添加中..."),
                        ],
                      ),
                    );
                  },
                );
                await _addWebsite(nameController.text, urlController.text, Icons.web);
                await _saveCommonWebsites();
                debugPrint('网站已添加并立即保存');
                Navigator.of(context).pop();
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('网站已添加并保存')));
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableWebsiteItem(Map<String, dynamic> website, int index) {
    IconData iconData = Icons.public;
    return ListTile(
      key: ValueKey(website['url']),
      leading: Icon(iconData),
      title: Text(website['name']),
      subtitle: Text(website['url']),
      trailing: IconButton(
        icon: const Icon(Icons.delete, color: Colors.red),
        onPressed: () async {
          final shouldDelete = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('删除网站'),
              content: Text('确定要删除 ${website['name']} 吗？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          ) ?? false;
          if (shouldDelete) {
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (BuildContext context) {
                return const AlertDialog(
                  content: Row(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(width: 20),
                      Text("删除中..."),
                    ],
                  ),
                );
              },
            );
            await _removeWebsite(index);
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('网站已删除')));
          }
        },
      ),
    );
  }

  Widget _buildWebsiteCard(Map<String, dynamic> website) {
    IconData iconData = Icons.public;
    return InkWell(
      onTap: () => _loadUrl(website['url']),
      child: Card(
        elevation: 4.0,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(iconData, size: 40, color: Theme.of(context).primaryColor),
            const SizedBox(height: 8),
            Text(website['name'], style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Future<void> _loadBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookmarksList = prefs.getStringList('bookmarks');
      setState(() {
        if (bookmarksList != null && bookmarksList.isNotEmpty) {
          _bookmarks.clear();
          _bookmarks.addAll(bookmarksList);
        } else if (_bookmarks.isEmpty) {
          _bookmarks.addAll(['https://www.baidu.com', 'https://www.bilibili.com']);
          _saveBookmarks();
        }
      });
      debugPrint('Successfully loaded ${_bookmarks.length} bookmarks');
    } catch (e) {
      debugPrint('Error loading bookmarks: $e');
    }
  }

  Future<void> _saveCommonWebsites() async {
    try {
      debugPrint('Starting to save common websites...');
      final prefs = await SharedPreferences.getInstance();
      final cleanedWebsites = _commonWebsites.map((site) {
        return {
          'name': site['name'],
          'url': site['url'],
          'iconCode': Icons.public.codePoint,
        };
      }).toList();
      final jsonString = jsonEncode(cleanedWebsites);
      debugPrint('Common websites JSON: $jsonString');
      await prefs.remove('common_websites');
      final result = await prefs.setString('common_websites', jsonString);
      if (!result) debugPrint('Common websites save failed: SharedPreferences returned false');
    } catch (e) {
      debugPrint('Error saving common websites: $e');
      debugPrintStack(label: 'Save common websites error stack');
    }
  }

  Future<void> _handleDownload(String url, String contentDisposition, String mimeType, {MediaType? selectedType}) async {
    try {
      debugPrint('开始处理下载: $url, MIME类型: $mimeType');
      
      // 防止重复下载
      if (_downloadingUrls.contains(url)) {
        debugPrint('URL正在下载中，跳过: $url');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该文件正在下载中，请稍候...'))
          );
        }
        return;
      }
      
      String processedUrl = url;
      if (url.contains('telegram.org') || url.contains('t.me')) {
        if (!url.startsWith('http')) {
          processedUrl = url.startsWith('//') ? 'https:$url' : 'https://$url';
        }
        debugPrint('处理后的电报URL: $processedUrl');
      }
      
      if (selectedType == null) {
        final result = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (context) => _buildDownloadDialog(processedUrl, mimeType),
        );
        if (result != null) {
          final bool shouldDownload = result['download'];
          final MediaType mediaType = result['mediaType'];
          if (shouldDownload) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('开始下载，将在后台进行...'), duration: Duration(seconds: 2))
            );
            unawaited(_performBackgroundDownload(processedUrl, mediaType));
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('开始下载，将在后台进行...'), duration: Duration(seconds: 2))
        );
        unawaited(_performBackgroundDownload(processedUrl, selectedType));
      }
    } catch (e, stackTrace) {
      debugPrint('处理下载时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载出错: $e')));
    }
  }

  Widget _buildDownloadDialog(String url, String mimeType) {
    MediaType selectedType = _determineMediaType(mimeType);
    return StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('下载媒体'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('您想下载这个文件吗？'),
            const SizedBox(height: 8),
            Text('URL: $url', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 16),
            const Text('选择媒体类型:'),
            RadioListTile<MediaType>(
              title: const Text('图片'),
              value: MediaType.image,
              groupValue: selectedType,
              onChanged: (value) => setState(() => selectedType = value!),
            ),
            RadioListTile<MediaType>(
              title: const Text('视频'),
              value: MediaType.video,
              groupValue: selectedType,
              onChanged: (value) => setState(() => selectedType = value!),
            ),
            RadioListTile<MediaType>(
              title: const Text('音频'),
              value: MediaType.audio,
              groupValue: selectedType,
              onChanged: (value) => setState(() => selectedType = value!),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop({'download': true, 'mediaType': selectedType}),
            child: const Text('下载'),
          ),
        ],
      ),
    );
  }

  MediaType _determineMediaType(String mimeType) {
    if (mimeType.startsWith('image/')) return MediaType.image;
    if (mimeType.startsWith('video/')) return MediaType.video;
    if (mimeType.startsWith('audio/')) return MediaType.audio;
    return MediaType.image;
  }
  
  bool _isDownloadableLink(String url) {
    debugPrint('检查URL是否为可下载链接: $url');
    final fileExtensions = [
      '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico',
      '.mp4', '.avi', '.mov', '.wmv', '.flv', '.mkv', '.webm', '.m3u8', '.ts',
      '.mp3', '.wav', '.ogg', '.aac', '.flac', '.m4a',
      '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt',
      '.zip', '.rar', '.7z', '.tar', '.gz',
      '.exe', '.apk', '.dmg', '.iso'
    ];
    final lowercaseUrl = url.toLowerCase();
    for (final ext in fileExtensions) {
      if (lowercaseUrl.endsWith(ext)) {
        debugPrint('URL以文件扩展名结尾: $ext');
        return true;
      }
    }
    final downloadKeywords = [
      '/download/', '/dl/', '/attachment/', '/file/', '/media/download/',
      '/photo/download/', '/video/download/', '/document/download/'
    ];
    for (final keyword in downloadKeywords) {
      if (lowercaseUrl.contains(keyword)) {
        debugPrint('URL包含明确的下载关键词: $keyword');
        return true;
      }
    }
    final downloadParams = ['download=true', 'dl=1', 'attachment=1'];
    final uri = Uri.parse(url);
    final queryString = uri.query.toLowerCase();
    for (final param in downloadParams) {
      if (queryString.contains(param)) {
        debugPrint('URL参数中包含明确的下载相关参数: $param');
        return true;
      }
    }
    if (url.contains('telegram.org') || url.contains('t.me')) {
      final telegramMediaPatterns = ['/file/', '/photo/size', '/video/size', '/document/'];
      for (final pattern in telegramMediaPatterns) {
        if (lowercaseUrl.contains(pattern)) {
          debugPrint('检测到电报媒体链接模式: $pattern');
          return true;
        }
      }
    }
    return false;
  }
  
  String _guessMimeType(String url) {
    final uri = Uri.parse(url);
    final path = uri.path.toLowerCase();
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.gif')) return 'image/gif';
    if (path.endsWith('.bmp')) return 'image/bmp';
    if (path.endsWith('.webp')) return 'image/webp';
    if (path.endsWith('.mp4')) return 'video/mp4';
    if (path.endsWith('.avi')) return 'video/x-msvideo';
    if (path.endsWith('.mov')) return 'video/quicktime';
    if (path.endsWith('.wmv')) return 'video/x-ms-wmv';
    if (path.endsWith('.flv')) return 'video/x-flv';
    if (path.endsWith('.mkv')) return 'video/x-matroska';
    if (path.endsWith('.webm')) return 'video/webm';
    if (path.endsWith('.mp3')) return 'audio/mpeg';
    if (path.endsWith('.wav')) return 'audio/wav';
    if (path.endsWith('.ogg')) return 'audio/ogg';
    if (path.endsWith('.aac')) return 'audio/aac';
    if (path.endsWith('.flac')) return 'audio/flac';
    return 'application/octet-stream';
  }

  Future<File?> _downloadFile(String url) async {
    try {
      debugPrint('开始下载文件，URL: $url');
      
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 60); // 增加连接超时
      dio.options.receiveTimeout = const Duration(seconds: 300); // 增加接收超时，特别是视频文件
      dio.options.sendTimeout = const Duration(seconds: 60);
      
      // 设置更完整的请求头
      dio.options.headers = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
        'Sec-Fetch-Dest': 'document',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Site': 'none',
        'Upgrade-Insecure-Requests': '1',
      };
      
      // 针对Telegram的特殊处理
      if (url.contains('telegram.org') || url.contains('t.me')) {
        dio.options.headers['Referer'] = 'https://web.telegram.org/';
        dio.options.headers['Origin'] = 'https://web.telegram.org';
        dio.options.headers['Sec-Fetch-Site'] = 'same-origin';
        dio.options.headers['X-Requested-With'] = 'XMLHttpRequest';
        dio.options.headers['Cache-Control'] = 'no-cache';
        dio.options.headers['Pragma'] = 'no-cache';
        // 尝试使用当前WebView的Cookie
        final cookieManager = CookieManager.instance();
        final cookies = await cookieManager.getCookies(url: WebUri(url));
        if (cookies.isNotEmpty) {
          final cookieString = cookies.map((c) => '${c.name}=${c.value}').join('; ');
          dio.options.headers['Cookie'] = cookieString;
          debugPrint('添加Cookie: $cookieString');
        }
      }
      
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      
      final uuid = const Uuid().v4();
      final uri = Uri.parse(url);
      String extension = _getFileExtension(uri.path);
      
      if (extension.isEmpty) {
        final mimeType = _guessMimeType(url);
        extension = mimeType.startsWith('image/') ? '.jpg' : 
                   mimeType.startsWith('video/') ? '.mp4' : 
                   mimeType.startsWith('audio/') ? '.mp3' : '.bin';
        debugPrint('URL没有扩展名，根据MIME类型猜测为: $extension');
      }
      
      final filePath = '${mediaDir.path}/$uuid$extension';
      debugPrint('将下载到文件路径: $filePath');
      
      // 添加重试机制
      int retryCount = 0;
      const maxRetries = 3;
      
      while (retryCount < maxRetries) {
        try {
          // 对于Telegram，先尝试HEAD请求检查文件是否可访问
          if (url.contains('telegram.org') || url.contains('t.me')) {
            try {
              final headResponse = await dio.head(url);
              debugPrint('HEAD请求成功，状态码: ${headResponse.statusCode}');
              if (headResponse.headers['content-length'] != null) {
                debugPrint('文件大小: ${headResponse.headers['content-length']![0]} 字节');
              }
            } catch (e) {
              debugPrint('HEAD请求失败: $e，继续尝试直接下载');
            }
          }
          
          await dio.download(
            url, 
            filePath, 
            deleteOnError: true,
            options: Options(
              followRedirects: true,
              maxRedirects: 5,
              validateStatus: (status) => status != null && status < 400,
              responseType: ResponseType.bytes,
            ),
            onReceiveProgress: (received, total) {
              if (total != -1) {
                final progress = (received / total * 100).toStringAsFixed(2);
                debugPrint('下载进度: $progress%');
              } else {
                debugPrint('已接收: $received 字节');
              }
            }
          );
          break; // 下载成功，退出重试循环
        } catch (e) {
          retryCount++;
          debugPrint('下载失败 (尝试 $retryCount/$maxRetries): $e');
          
          // 对于Telegram，如果是403或401错误，尝试不同的策略
          if ((url.contains('telegram.org') || url.contains('t.me')) && retryCount < maxRetries) {
            if (e.toString().contains('403') || e.toString().contains('401')) {
              debugPrint('检测到认证错误，尝试调整请求头');
              // 移除一些可能导致问题的请求头
              dio.options.headers.remove('Sec-Fetch-Dest');
              dio.options.headers.remove('Sec-Fetch-Mode');
              dio.options.headers.remove('Sec-Fetch-Site');
              dio.options.headers['User-Agent'] = 'TelegramBot (like TwitterBot)';
            }
          }
          
          if (retryCount >= maxRetries) {
            rethrow;
          }
          // 等待一段时间后重试
          await Future.delayed(Duration(seconds: retryCount * 2));
        }
      }
      
      final file = File(filePath);
      if (await file.exists()) {
        final fileSize = await file.length();
        debugPrint('文件下载完成，大小: $fileSize 字节');
        if (fileSize > 0) {
          return file;
        } else {
          await file.delete();
          debugPrint('文件大小为0，下载可能失败');
        }
      }
      
      return null;
    } catch (e, stackTrace) {
      debugPrint('下载文件时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      return null;
    }
  }

  String _getFileExtension(String path) {
    final lastDot = path.lastIndexOf('.');
    return lastDot != -1 ? path.substring(lastDot) : '';
  }

  Future<void> _saveToMediaLibrary(File file, MediaType mediaType) async {
    try {
      final fileName = file.path.split('/').last;
      final fileHash = await _calculateFileHash(file);
      final duplicate = await _databaseService.findDuplicateMediaItem(fileHash, fileName);
      if (duplicate != null) {
        debugPrint('发现重复文件: ${duplicate['name']}');
        throw Exception('文件已存在于媒体库中');
      }
      final uuid = const Uuid().v4();
      final mediaItem = MediaItem(
        id: uuid,
        name: fileName,
        path: file.path,
        type: mediaType,
        directory: 'root',
        dateAdded: DateTime.now(),
      );
      final mediaItemMap = mediaItem.toMap();
      mediaItemMap['file_hash'] = fileHash;
      await _databaseService.insertMediaItem(mediaItemMap);
    } catch (e) {
      debugPrint('保存到媒体库时出错: $e');
      rethrow;
    }
  }

  Future<String> _calculateFileHash(File file) async {
    try {
      final bytes = await file.readAsBytes();
      return md5.convert(bytes).toString();
    } catch (e) {
      debugPrint('计算文件哈希值时出错: $e');
      return '';
    }
  }

  void _addBookmark(String url) {
    if (!_bookmarks.contains(url)) {
      setState(() {
        _bookmarks.add(url);
      });
      _saveBookmarks();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已添加书签')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('书签已存在')));
    }
  }

  void _showBookmarks() {
    showModalBottomSheet(
      context: context,
      builder: (context) => ListView.builder(
        itemCount: _bookmarks.length,
        itemBuilder: (context, index) {
          final url = _bookmarks[index];
          return ListTile(
            title: Text(url),
            onTap: () {
              _controller.loadRequest(Uri.parse(url));
              Navigator.pop(context);
            },
            trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () {
                setState(() {
                  _bookmarks.removeAt(index);
                });
                _saveBookmarks();
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除书签')));
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _saveBookmarks() async {
    try {
      debugPrint('Starting to save bookmarks...');
      final prefs = await SharedPreferences.getInstance();
      final result = await prefs.setStringList('bookmarks', _bookmarks);
      if (!result) debugPrint('Bookmark save failed: SharedPreferences returned false');
    } catch (e) {
      debugPrint('Error saving bookmarks: $e');
      debugPrintStack(label: 'Bookmark save error stack');
    }
  }

  Future<void> _loadCommonWebsites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final commonWebsitesJson = prefs.getString('common_websites');
      debugPrint('Loaded common websites JSON: $commonWebsitesJson');
      if (commonWebsitesJson != null && commonWebsitesJson.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(commonWebsitesJson);
        setState(() {
          _commonWebsites.clear();
          _commonWebsites.addAll(decoded.map((item) => {
            'name': item['name'],
            'url': item['url'],
            'iconCode': Icons.public.codePoint,
          }).toList());
        });
        debugPrint('Successfully loaded ${_commonWebsites.length} common websites');
      } else if (_commonWebsites.isEmpty) {
        debugPrint('No common websites found, using defaults.');
        setState(() {
          _commonWebsites.clear();
          _commonWebsites.addAll([
            {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
            {'name': 'Edge', 'url': 'https://www.bing.com', 'iconCode': Icons.public.codePoint},
            {'name': 'X', 'url': 'https://twitter.com', 'iconCode': Icons.public.codePoint},
            {'name': 'Facebook', 'url': 'https://www.facebook.com', 'iconCode': Icons.public.codePoint},
            {'name': 'Telegram', 'url': 'https://web.telegram.org', 'iconCode': Icons.public.codePoint},
            {'name': '百度', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint}
          ]);
        });
        await _saveCommonWebsites();
        debugPrint('Saved default common websites.');
      }
    } catch (e) {
      debugPrint('Error loading common websites: $e');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('common_websites');
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[_BrowserPage.build] _showHomePage: $_showHomePage, _isBrowsingWebPage: $_isBrowsingWebPage, _shouldKeepWebPageState: $_shouldKeepWebPageState');
    super.build(context);
    return WillPopScope(
      onWillPop: () async {
        debugPrint('[_WillPopScope] onWillPop called. Current _showHomePage: $_showHomePage');
        if (!_showHomePage) {
          if (await _controller.canGoBack()) {
            debugPrint('[_WillPopScope] canGoBack is true, going back in webview.');
            _controller.goBack();
            return false;
          } else {
            debugPrint('[_WillPopScope] canGoBack is false, going to home page.');
            _goToHomePage();
            return false;
          }
        }
        debugPrint('[_WillPopScope] On home page, allowing pop.');
        return true;
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          titleSpacing: 0,
          title: _showHomePage ? const Text('网页浏览器') : const SizedBox.shrink(),
          leading: _showHomePage
              ? null
              : IconButton(
                  icon: const Icon(Icons.home),
                  onPressed: () async {
                    debugPrint('[_AppBar] Home button pressed.');
                    _goToHomePage();
                  },
                  tooltip: '回到主页',
                ),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.bookmark),
              onPressed: _showBookmarks,
              tooltip: '显示书签',
            ),
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.bookmark_add),
                onPressed: () => _addBookmark(_currentUrl),
                tooltip: '添加书签',
              ),
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red),
                onPressed: _exitWebPage,
                tooltip: '退出网页',
              ),
          ],
        ),
        body: _showHomePage
            ? _buildHomePage()
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () async {
                            debugPrint('[_Toolbar] Back button pressed.');
                            if (await _controller.canGoBack()) _controller.goBack();
                          },
                          tooltip: '后退',
                        ),
                        IconButton(
                          icon: const Icon(Icons.arrow_forward),
                          onPressed: () async {
                            debugPrint('[_Toolbar] Forward button pressed.');
                            if (await _controller.canGoForward()) _controller.goForward();
                          },
                          tooltip: '前进',
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: () {
                            debugPrint('[_Toolbar] Refresh button pressed.');
                            _controller.reload();
                          },
                          tooltip: '刷新',
                        ),
                        Expanded(
                          child: TextField(
                            controller: _urlController,
                            decoration: const InputDecoration(
                              hintText: '输入网址',
                              contentPadding: EdgeInsets.symmetric(horizontal: 8),
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.url,
                            onSubmitted: _loadUrl,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.search),
                          onPressed: () {
                            debugPrint('[_Toolbar] Search button pressed: ${_urlController.text}');
                            _loadUrl(_urlController.text);
                          },
                          tooltip: '前往',
                        ),
                      ],
                    ),
                  ),
                  if (_isLoading) LinearProgressIndicator(value: _loadingProgress),
                  Expanded(child: WebViewWidget(controller: _controller)),
                ],
              ),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _saveBookmarks().then((_) => debugPrint('书签保存完成')).catchError((error) => debugPrint('保存书签时出错: $error'));
    _saveCommonWebsites().then((_) => debugPrint('常用网站保存完成')).catchError((error) => debugPrint('保存常用网站时出错: $error'));
    widget.onBrowserHomePageChanged?.call(true);
    super.dispose();
  }

  Future<void> _performBackgroundDownload(String url, MediaType mediaType) async {
    // 添加到下载中的URL集合
    _downloadingUrls.add(url);
    
    try {
      debugPrint('开始后台下载: $url, 媒体类型: $mediaType');
      final file = await _downloadFile(url);
      if (file != null) {
        debugPrint('文件下载成功: ${file.path}');
        await _saveToMediaLibrary(file, mediaType);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${mediaType == MediaType.video ? "视频" : mediaType == MediaType.image ? "图片" : "音频"}已成功保存到媒体库: ${file.path.split('/').last}'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: '查看',
                onPressed: () => Navigator.pushNamed(context, '/media_manager'),
              ),
            ),
          );
        }
      } else {
        debugPrint('文件下载失败: $url');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${mediaType == MediaType.video ? "视频" : mediaType == MediaType.image ? "图片" : "音频"}下载失败，请检查网络连接或稍后重试'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('后台下载出错: $url, 错误: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${mediaType == MediaType.video ? "视频" : mediaType == MediaType.image ? "图片" : "音频"}下载出错: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      // 无论成功还是失败，都要从下载中的URL集合中移除
      _downloadingUrls.remove(url);
      debugPrint('已从下载队列中移除URL: $url');
    }
  }
}