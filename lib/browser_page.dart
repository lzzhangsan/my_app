import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
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
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'services/telegram_download_service_v2.dart';
import 'models/media_item.dart';
import 'models/media_type.dart';
import 'main.dart';
import 'media_manager_page.dart';

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
  List<Map<String, String>> _bookmarks = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TelegramDownloadServiceV2 _telegramService = TelegramDownloadServiceV2.instance;
  
  // 添加轮询相关变量
  Timer? _telegramPollingTimer;
  int _lastUpdateId = 0;
  bool _isPollingActive = false;
  
  // 添加已下载文件ID集合
  final Set<String> _downloadedFileIds = <String>{};
  static const String _downloadedFileIdsKey = 'telegram_downloaded_file_ids';

  bool _showHomePage = true;
  bool _isBrowsingWebPage = false;

  // 添加视频下载进度和状态的ValueNotifier
  ValueNotifier<double?> _videoDownloadProgress = ValueNotifier(null);
  ValueNotifier<bool> _isDownloadingVideo = ValueNotifier(false);

  Future<void> _launchExternalApp(String url) async {
    debugPrint('尝试启动外部应用: $url');
    try {
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        debugPrint('成功启动外部应用');
      } else {
        debugPrint('无法启动外部应用: $url');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开: $url')),
        );
      }
    } catch (e) {
      debugPrint('启动外部应用时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开链接时出错: $e')),
      );
    }
  }
  bool _shouldKeepWebPageState = false;
  String? _lastBrowsedUrl;

  final List<Map<String, dynamic>> _commonWebsites = [
    {'name': 'Google', 'url': 'https://www.google.com', 'icon': Icons.search},
    {'name': 'Telegram', 'url': 'https://web.telegram.org', 'icon': Icons.send},
    {'name': '百度', 'url': 'https://www.baidu.com', 'icon': Icons.search},
  ];

  // 移除编辑模式状态变量
  // bool _isEditMode = false;

  // 保留此方法但简化功能，因为我们已移除编辑模式
  Future<void> _saveWebsites() async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正在保存常用网站...')));
    await _saveCommonWebsites();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('常用网站已保存')));
  }

  Future<void> _removeWebsite(int index) async {
    final removedSite = _commonWebsites[index]['name'];
    setState(() => _commonWebsites.removeAt(index));
    await _saveCommonWebsites();
    debugPrint('已删除并保存网站: $removedSite');
  }

  Future<void> _reorderWebsites(int oldIndex, int newIndex) async {
    // 如果是添加网站按钮，不允许拖动
    if (oldIndex >= _commonWebsites.length || newIndex > _commonWebsites.length) {
      return;
    }
    
    // 调整newIndex，因为ReorderableGridView的newIndex计算方式与ReorderableListView不同
    if (newIndex > _commonWebsites.length) newIndex = _commonWebsites.length;
    
    setState(() {
      if (oldIndex < newIndex) newIndex -= 1;
      final item = _commonWebsites.removeAt(oldIndex);
      _commonWebsites.insert(newIndex, item);
    });
    await _saveCommonWebsites();
    debugPrint('已移动并保存网站从位置 $oldIndex 到 $newIndex');
  }

  Future<void> _addWebsite(String name, String url, IconData icon) async {
    setState(() => _commonWebsites.add({'name': name, 'url': url, 'iconCode': icon.codePoint}));
    await _saveCommonWebsites();
    debugPrint('已添加并立即保存网站: $name');
  }

  @override
  void initState() {
    super.initState();
    _databaseService = getService<DatabaseService>();
    _initializeDownloader();
    _initializeWebView();
    _loadBookmarks();
    _loadCommonWebsites();
    _initializeTelegramService();
  }
  
  /// 初始化 Telegram 服务
  Future<void> _initializeTelegramService() async {
    await _telegramService.initialize();
    
    // 加载已下载的文件ID和最后更新ID
    await _loadDownloadedFileIds();
    await _loadLastUpdateId();
    
    // 如果已配置Bot Token，启动轮询
    if (_telegramService.isConfigured) {
      await _startTelegramPolling();
    }
  }

  Future<void> _initializeDownloader() async {
    await FlutterDownloader.initialize();
    await _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    var storageStatus = await Permission.storage.request();
    debugPrint('存储权限状态: $storageStatus');
    if (Platform.isAndroid) {
      var manageStorageStatus = await Permission.manageExternalStorage.request();
      debugPrint('管理外部存储权限状态: $manageStorageStatus');
    }
    var recordStatus = await Permission.microphone.request();
    debugPrint('录音权限状态: $recordStatus');
  }

  void _initializeWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.162 Mobile Safari/537.36')
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
            setState(() => _isLoading = false);
            _controller.runJavaScript('''
              document.querySelectorAll('input').forEach(function(input) {
                input.autocomplete = 'on';
              });
            ''');
            _injectDownloadHandlers();
          },
          onWebResourceError: (error) => debugPrint('WebView错误: ${error.description}'),
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            debugPrint('导航请求: $url');
            if (_isDownloadableLink(url) || _isTelegramMediaLink(url) || _isYouTubeLink(url)) {
              debugPrint('检测到可能的下载链接: $url');
              _handleDownload(url, '', _guessMimeType(url));
              return NavigationDecision.prevent;
            }
            // 处理自定义URL协议
            if (!url.startsWith('http://') && !url.startsWith('https://')) {
              debugPrint('检测到自定义URL协议: $url');
              _launchExternalApp(url);
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
    // 排除blob链接，让其由JavaScript处理
    if (url.startsWith('blob:')) return false;
    
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
      '/a/document',
      '/progressive/',
    ];
    for (final pattern in telegramMediaPatterns) {
      if (url.contains(pattern)) return true;
    }
    if (url.contains('telegram') || url.contains('t.me')) {
      final mediaExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.mp4', '.webp', '.webm', '.m3u8'];
      for (final ext in mediaExtensions) {
        if (url.toLowerCase().contains(ext)) return true;
      }
    }
    return false;
  }

  bool _isYouTubeLink(String url) {
    return url.contains('youtube.com') || url.contains('youtu.be');
  }

  final Set<String> _downloadingUrls = {};
  final Set<String> _processedUrls = {};

  void _injectDownloadHandlers() {
    debugPrint('为所有网站注入强化媒体下载处理程序');
    _controller.runJavaScript('''
      window.MediaInterceptor = window.MediaInterceptor || {
        processedUrls: new Set(),
        interceptedRequests: new Map(),
        blobUrls: new Map(),
        m3u8Segments: new Map()
      };

      function isBlobUrl(url) {
        return url && typeof url === 'string' && url.startsWith('blob:');
      }

      function isMediaUrl(url) {
        if (!url) return false;
        const mediaExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg',
                                '.mp4', '.webm', '.mov', '.avi', '.mkv', '.flv', '.wmv', '.m3u8',
                                '.mp3', '.wav', '.ogg', '.m4a', '.aac'];
        const lowerUrl = url.toLowerCase();
        return mediaExtensions.some(ext => lowerUrl.includes(ext)) || 
               lowerUrl.includes('image') || lowerUrl.includes('video') || lowerUrl.includes('audio') ||
               lowerUrl.includes('media') || lowerUrl.includes('.m3u8') ||
               lowerUrl.includes('youtube.com') || lowerUrl.includes('youtu.be');
      }

      async function resolveBlobUrl(blobUrl, mediaType) {
        try {
          console.log('正在解析Blob URL:', blobUrl);
          const response = await fetch(blobUrl, { method: 'GET', headers: {'Accept': '*/*', 'Cache-Control': 'no-cache'} });
          if (!response.ok) throw new Error('Fetch failed: ' + response.statusText);
          const blob = await response.blob();
          const reader = new FileReader();
          return new Promise((resolve, reject) => {
            reader.onloadend = () => {
              const base64Data = reader.result.split(',')[1];
              resolve({ resolvedUrl: base64Data, isBase64: true, mediaType: mediaType });
            };
            reader.onerror = reject;
            reader.readAsDataURL(blob);
          });
        } catch (error) {
          console.error('Error resolving Blob URL:', error);
          return null;
        }
      }

      (function() {
        const originalXHROpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, async, user, password) {
          this._interceptedUrl = url;
          this._interceptedMethod = method;
          return originalXHROpen.apply(this, arguments);
        };

        const originalXHRSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function(data) {
          const xhr = this;
          const url = this._interceptedUrl;
          if (isMediaUrl(url)) {
            console.log('拦截到媒体请求 (XHR):', url);
            window.MediaInterceptor.interceptedRequests.set(url, {
              method: this._interceptedMethod,
              timestamp: Date.now(),
              type: 'xhr'
            });
            if (!window.MediaInterceptor.processedUrls.has(url)) {
              window.MediaInterceptor.processedUrls.add(url);
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: 'video',
                url: url,
                isBase64: false,
                source: 'xhr_intercept',
                action: 'download'
              }));
            }
          }
          const originalOnLoad = this.onload;
          this.onload = function() {
            if (isMediaUrl(url) && this.response) console.log('媒体请求完成 (XHR):', url);
            if (originalOnLoad) originalOnLoad.apply(this, arguments);
          };
          return originalXHRSend.apply(this, arguments);
        };
      })();

      (function() {
        const originalFetch = window.fetch;
        window.fetch = async function(input, init) {
          const url = typeof input === 'string' ? input : input.url;
          if (isMediaUrl(url)) {
            console.log('拦截到媒体请求 (Fetch):', url);
            window.MediaInterceptor.interceptedRequests.set(url, {
              method: (init && init.method) || 'GET',
              timestamp: Date.now(),
              type: 'fetch'
            });
            if (!window.MediaInterceptor.processedUrls.has(url)) {
              window.MediaInterceptor.processedUrls.add(url);
              const response = await originalFetch.apply(this, arguments);
              if (response.ok && (response.headers.get('content-type')?.startsWith('video') || response.headers.get('content-type')?.startsWith('image'))) {
                const blob = await response.blob();
                const blobUrl = URL.createObjectURL(blob);
                const resolved = await resolveBlobUrl(blobUrl, response.headers.get('content-type')?.startsWith('image') ? 'image' : 'video');
                if (resolved) {
                  Flutter.postMessage(JSON.stringify({
                    type: 'media',
                    mediaType: resolved.mediaType || 'video',
                    url: resolved.resolvedUrl,
                    isBase64: resolved.isBase64,
                    action: 'download'
                  }));
                }
              }
              return response;
            }
          }
          return originalFetch.apply(this, arguments);
        };
      })();

      window.processedMediaUrls = window.MediaInterceptor.processedUrls;

      let pressTimer;
      let pressedElement = null;
      let feedbackElement = null;

      function createFeedbackElement(touchX, touchY) {
        removeFeedbackElement();
        feedbackElement = document.createElement('div');
        feedbackElement.style.position = 'fixed';
        feedbackElement.style.left = (touchX - 50) + 'px';
        feedbackElement.style.top = (touchY - 50) + 'px';
        feedbackElement.style.width = '100px';
        feedbackElement.style.height = '100px';
        feedbackElement.style.borderRadius = '50%';
        feedbackElement.style.backgroundColor = 'rgba(0, 0, 0, 0.5)';
        feedbackElement.style.zIndex = '9999';
        feedbackElement.style.display = 'flex';
        feedbackElement.style.justifyContent = 'center';
        feedbackElement.style.alignItems = 'center';
        feedbackElement.style.color = 'white';
        feedbackElement.style.fontSize = '14px';
        feedbackElement.style.textAlign = 'center';
        feedbackElement.style.transition = 'transform 0.5s, opacity 0.5s';
        feedbackElement.style.transform = 'scale(0.5)';
        feedbackElement.style.opacity = '0.7';
        feedbackElement.innerText = '正在检测媒体...';
        document.body.appendChild(feedbackElement);
        setTimeout(() => {
          if (feedbackElement) {
            feedbackElement.style.transform = 'scale(1)';
            feedbackElement.style.opacity = '1';
          }
        }, 10);
      }

      function removeFeedbackElement() {
        if (feedbackElement) {
          feedbackElement.style.transform = 'scale(0.5)';
          feedbackElement.style.opacity = '0';
          setTimeout(() => {
            if (feedbackElement && feedbackElement.parentNode) {
              feedbackElement.parentNode.removeChild(feedbackElement);
              feedbackElement = null;
            }
          }, 300);
        }
      }

      function updateFeedbackStatus(status, success) {
        if (feedbackElement) {
          feedbackElement.innerText = status;
          feedbackElement.style.backgroundColor = success ? 'rgba(0, 128, 0, 0.5)' : 'rgba(255, 0, 0, 0.5)';
          setTimeout(removeFeedbackElement, 1000);
        }
      }

      document.addEventListener('touchstart', function(e) {
        pressedElement = e.target.closest('a[href*="progressive/document"], a[href*="media"], a[href*="video"], [class*="download"], div[role="menuitem"][aria-label*="download"], video[src], img[src]');
        if (pressedElement) {
          const touch = e.touches[0];
          const touchX = touch.clientX;
          const touchY = touch.clientY;
          pressTimer = setTimeout(function() {
            createFeedbackElement(touchX, touchY);
            handleMediaDownload(pressedElement, e);
          }, 500);
        }
      }, true);

      document.addEventListener('touchmove', function(e) {
        clearTimeout(pressTimer);
        removeFeedbackElement();
        pressedElement = null;
      }, true);

      document.addEventListener('touchend', function(e) {
        clearTimeout(pressTimer);
        if (!pressedElement) removeFeedbackElement();
        pressedElement = null;
      }, true);

      // 添加点击事件监听器处理blob URL
      document.addEventListener('click', function(e) {
        const target = e.target;
        const link = target.closest('a');
        if (link && link.href && isBlobUrl(link.href)) {
          e.preventDefault();
          console.log('检测到blob URL点击:', link.href);
          resolveBlobUrl(link.href, 'video').then(resolved => {
            if (resolved) {
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: resolved.mediaType || 'video',
                url: resolved.resolvedUrl,
                isBase64: resolved.isBase64,
                action: 'download'
              }));
              console.log('已发送blob URL下载请求');
            } else {
              console.error('解析blob URL失败');
            }
          });
        }
      }, true);

      function handleMediaDownload(target, e) {
        if (!target) {
          updateFeedbackStatus('未找到媒体元素', false);
          return;
        }
        
        let url = target.href || target.getAttribute('data-href') || target.getAttribute('data-url') || target.src;
        if (!url) {
          updateFeedbackStatus('未找到下载链接', false);
          return;
        }

        if (!window.processedMediaUrls.has(url)) {
          if (isBlobUrl(url)) {
            updateFeedbackStatus('正在处理媒体...', true);
            resolveBlobUrl(url, target.tagName.toLowerCase() === 'img' ? 'image' : 'video').then(resolved => {
              if (resolved) {
                window.processedMediaUrls.add(url);
                Flutter.postMessage(JSON.stringify({
                  type: 'media',
                  mediaType: resolved.mediaType || 'video',
                  url: resolved.resolvedUrl,
                  isBase64: resolved.isBase64,
                  action: 'download'
                }));
                updateFeedbackStatus('已发送下载请求', true);
              } else {
                updateFeedbackStatus('解析媒体失败', false);
              }
            });
          } else {
            window.processedMediaUrls.add(url);
            Flutter.postMessage(JSON.stringify({
              type: 'media',
              mediaType: target.tagName.toLowerCase() === 'img' ? 'image' : 'video',
              url: url,
              isBase64: false,
              action: 'download'
            }));
            updateFeedbackStatus('已发送下载请求', true);
          }
          e.preventDefault();
        } else {
          updateFeedbackStatus('该媒体已在处理中', false);
        }
      }
    ''');
  }

  void _handleJavaScriptMessage(String message) {
    try {
      final data = jsonDecode(message);
      if (data is Map && data.containsKey('type')) {
        final type = data['type'];
        final url = data['url'];
        final isBase64 = data['isBase64'] ?? false;
        final action = data['action'];
        final mediaType = data['mediaType'] ?? (_guessMimeType(url).startsWith('image/') ? 'image' : (_guessMimeType(url).startsWith('video/') ? 'video' : 'audio'));

        if (url != null && url is String) {
          if (_processedUrls.contains(url)) return;
          _processedUrls.add(url);

          if (action == 'download') {
            debugPrint('Received URL from JavaScript with download action: $url, type: $mediaType, isBase64: $isBase64');
            if (isBase64) {
              _handleBlobUrl(url, mediaType);
            } else {
              MediaType selectedType = _determineMediaType(_guessMimeType(url));
              _performBackgroundDownload(url, selectedType);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error handling JavaScript message: $e');
    }
  }

  void _handleBlobUrl(String base64Data, String mediaType) async {
    try {
      debugPrint('处理Base64数据以直接保存: $mediaType');
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
            action: SnackBarAction(label: '查看', onPressed: () => Navigator.pushNamed(context, '/media_manager')),
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('处理Base64数据时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败: $e')));
    }
  }

  void _loadUrl(String url) {
    String processedUrl = url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) processedUrl = 'https://$url';
    if (processedUrl.contains('telegram.org') || processedUrl.contains('t.me') || processedUrl.contains('web.telegram.org')) {
      _controller.setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1');
      if (processedUrl.contains('web.telegram.org')) processedUrl = 'https://web.telegram.org/a/';
    } else if (processedUrl.contains('youtube.com') || processedUrl.contains('youtu.be')) {
      _controller.setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36');
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
    });
    widget.onBrowserHomePageChanged?.call(_showHomePage);
  }

  Future<void> _goToHomePage() async {
    if (!_showHomePage) {
      await _saveCommonWebsites();
      await _loadBookmarks();
      
      // 确保常用网站列表被正确加载
      await _loadCommonWebsites();
      
      // 如果常用网站列表为空，强制加载默认网站
      if (_commonWebsites.isEmpty) {
        debugPrint('常用网站列表为空，加载默认网站');
        setState(() {
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
      }
      
      setState(() => _showHomePage = true);
      widget.onBrowserHomePageChanged?.call(_showHomePage);
    }
  }

  void _restoreWebPage() {
    if (_showHomePage && _isBrowsingWebPage && _shouldKeepWebPageState) {
      setState(() => _showHomePage = false);
      widget.onBrowserHomePageChanged?.call(_showHomePage);
    }
  }

  void _exitWebPage() {
    setState(() {
      _showHomePage = true;
      _isBrowsingWebPage = false;
      _shouldKeepWebPageState = false;
      _lastBrowsedUrl = null;
      _controller.clearCache();
      _controller.clearLocalStorage();
      _currentUrl = 'https://www.baidu.com';
      _urlController.text = _currentUrl;
    });
    widget.onBrowserHomePageChanged?.call(_showHomePage);
  }

  Widget _buildHomePage() {
    // 确保_commonWebsites不为空
    if (_commonWebsites.isEmpty) {
      debugPrint('构建主页时发现常用网站列表为空，加载默认网站');
      _loadCommonWebsites();
    }
    
    return Stack(
      children: [
        Column(
          children: [
            // 移除了顶部工具栏
            Expanded(
              child: ReorderableGridView.builder(
                padding: const EdgeInsets.all(16.0),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 1.0,
                  crossAxisSpacing: 16.0,
                  mainAxisSpacing: 16.0,
                ),
                itemCount: _commonWebsites.length + 1, // +1 for the add button
                itemBuilder: (context, index) {
                  if (index == _commonWebsites.length) {
                    // 添加新网站的按钮
                    return InkWell(
                      key: const ValueKey('add_website'),
                      onTap: () => _showAddWebsiteDialog(context),
                      child: Card(
                        elevation: 4.0,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: const [
                            Icon(Icons.add_circle_outline, size: 40, color: Colors.green),
                            SizedBox(height: 8),
                            Text('添加网站', style: TextStyle(fontSize: 16), textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    );
                  } else {
                    return _buildWebsiteCard(_commonWebsites[index], index);
                  }
                },
                onReorder: _reorderWebsites,
                dragStartBehavior: DragStartBehavior.start,
                // 移除 dragEnabled 函数参数，改为在 _reorderWebsites 方法中处理
                // 移除 onReorderStart 参数，因为 ReorderableGridView 不支持此参数
              ),
            ),
          ],
        ),
        // 移除底部浮动按钮，改为在顶部显示
      ],
    );
  }

  void _showAddWebsiteDialog(BuildContext context) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    // 设置默认URL（如果在浏览网页，则使用当前URL）
    if (!_showHomePage && _isBrowsingWebPage) {
      urlController.text = _currentUrl;
    }

    // 先显示对话框，然后异步获取标题
    showDialog(
      context: context,
      builder: (dialogContext) {
        // 如果在浏览网页，异步获取网页标题
        if (!_showHomePage && _isBrowsingWebPage) {
          // 显示"获取中..."作为临时标题
          nameController.text = "获取中...";

          // 异步获取网页标题
          _controller.getTitle().then((title) {
            if (title != null && title.isNotEmpty && nameController.text == "获取中...") {
              // 直接更新文本控制器，而不使用setState
              nameController.text = title;
              // 自动选中文本，方便用户编辑
              nameController.selection = TextSelection(
                baseOffset: 0,
                extentOffset: title.length,
              );
            }
          }).catchError((error) {
            debugPrint('获取网页标题出错: $error');
            if (nameController.text == "获取中...") {
              nameController.text = "";
            }
          });
        }

        return AlertDialog(
          title: const Text('添加网站到标签'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '网站名称',
                  hintText: '输入自定义名称',
                  helperText: '为网站设置一个简短易记的名称',
                ),
                autofocus: true,
              ),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '网站地址',
                  hintText: '例如：https://www.google.com',
                ),
                enabled: !_isBrowsingWebPage, // 如果在浏览网页，则禁用URL输入框
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                if (nameController.text.isNotEmpty &&
                    urlController.text.isNotEmpty &&
                    nameController.text != "获取中...") {

                  // 创建一个变量存储加载对话框的context
                  BuildContext? loadingDialogContext;

                  // 显示加载对话框并保存context
                  showDialog(
                    context: dialogContext,
                    barrierDismissible: false,
                    builder: (context) {
                      loadingDialogContext = context;
                      return const AlertDialog(
                        content: Row(
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(width: 20),
                            Text('添加中...'),
                          ],
                        ),
                      );
                    },
                  );

                  await _addWebsite(nameController.text, urlController.text, Icons.web);
                  await _saveCommonWebsites();

                  // 安全地关闭加载对话框
                  if (loadingDialogContext != null && Navigator.canPop(loadingDialogContext!)) {
                    Navigator.pop(loadingDialogContext!);
                  }

                  // 关闭主对话框
                  Navigator.of(dialogContext).pop();

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已将"${nameController.text}"添加到标签栏'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                } else if (nameController.text == "获取中...") {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('请等待网页标题获取完成，或输入自定义名称'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('请输入网站名称和地址'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: const Text('添加'),
            ),
          ],
        );
      },
    );
  }

  // 移除_buildEditableWebsiteItem方法，因为我们已经移除了编辑模式

  void _showRenameWebsiteDialog(BuildContext context, Map<String, dynamic> website, int index) {
    final nameController = TextEditingController(text: website['name']);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名网站'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '网站名称', hintText: '输入新的网站名称'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text('当前URL: ${website['url']}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && nameController.text != website['name']) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const AlertDialog(
                    content: Row(
                      children: [CircularProgressIndicator(), SizedBox(width: 20), Text('保存中...')],
                    ),
                  ),
                );
                setState(() => _commonWebsites[index]['name'] = nameController.text);
                await _saveCommonWebsites();
                Navigator.of(context).pop();
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('网站名称已更新')));
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildWebsiteCard(Map<String, dynamic> website, int index) {
    return InkWell(
      key: ValueKey(website['url']),
      onTap: () => _loadUrl(website['url']),
      onDoubleTap: () => _showWebsiteOptionsDialog(context, website, _commonWebsites.indexWhere((site) => site['url'] == website['url'])),
      child: Card(
        elevation: 4.0,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.public, size: 40, color: Colors.blue),
            const SizedBox(height: 8),
            Text(website['name'], style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
  
  void _showWebsiteOptionsDialog(BuildContext context, Map<String, dynamic> website, int index) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit, color: Colors.blue),
            title: const Text('重命名'),
            onTap: () {
              Navigator.pop(context);
              _showRenameWebsiteDialog(context, website, index);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text('删除'),
            onTap: () async {
              Navigator.pop(context);
              final shouldDelete = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('删除网站'),
                  content: Text('确定要删除 ${website['name']} 吗？'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
                  ],
                ),
              ) ?? false;
              if (shouldDelete) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const AlertDialog(
                    content: Row(
                      children: [CircularProgressIndicator(), SizedBox(width: 20), Text('删除中...')],
                    ),
                  ),
                );
                await _removeWebsite(index);
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('网站已删除')));
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _loadBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookmarksJsonString = prefs.getString('bookmarks');
      setState(() {
        _bookmarks.clear();
        if (bookmarksJsonString != null && bookmarksJsonString.isNotEmpty) {
          final decoded = jsonDecode(bookmarksJsonString);
          if (decoded.isNotEmpty && decoded[0] is Map<String, dynamic> && decoded[0].containsKey('name') && decoded[0].containsKey('url')) {
            _bookmarks = (decoded as List).map((item) => {
              'name': item['name']?.toString() ?? '',
              'url': item['url']?.toString() ?? '',
            }).toList();
          } else if (decoded.isNotEmpty && decoded[0] is String) {
            _bookmarks = (decoded as List<String>).map((url) => {'name': url, 'url': url} as Map<String, String>).toList();
            _saveBookmarks();
          }
        }
        if (_bookmarks.isEmpty) {
          _bookmarks = [
            {'name': '百度', 'url': 'https://www.baidu.com'},
            {'name': 'Bilibili', 'url': 'https://www.bilibili.com'}
          ];
          _saveBookmarks();
        }
      });
    } catch (e) {
      debugPrint('Error loading bookmarks: $e');
    }
  }

  Future<void> _saveCommonWebsites() async {
    try {
      // 确保_commonWebsites不为空
      if (_commonWebsites.isEmpty) {
        debugPrint('警告：尝试保存空的常用网站列表，将加载默认网站');
        _commonWebsites.addAll([
          {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
          {'name': 'Telegram', 'url': 'https://web.telegram.org', 'iconCode': Icons.public.codePoint},
          {'name': '百度', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint}
        ]);
      }
      
      final prefs = await SharedPreferences.getInstance();
      final cleanedWebsites = _commonWebsites.map((site) => {
        'name': site['name'],
        'url': site['url'],
        'iconCode': Icons.public.codePoint,
      }).toList();
      final jsonString = jsonEncode(cleanedWebsites);
      
      // 先获取旧数据作为备份
      final oldJsonString = prefs.getString('common_websites');
      
      // 直接设置新数据，不先移除
      final success = await prefs.setString('common_websites', jsonString);
      
      if (success) {
        debugPrint('成功保存了${cleanedWebsites.length}个常用网站');
      } else {
        debugPrint('保存常用网站失败，尝试恢复旧数据');
        if (oldJsonString != null) {
          await prefs.setString('common_websites', oldJsonString);
        }
      }
    } catch (e) {
      debugPrint('Error saving common websites: $e');
    }
  }

  Future<void> _handleDownload(String url, String contentDisposition, String mimeType, {MediaType? selectedType}) async {
    try {
      debugPrint('开始处理下载: $url, MIME类型: $mimeType');
      if (_downloadingUrls.contains(url)) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该文件正在下载中，请稍候...')));
        return;
      }

      String processedUrl = url;
      if (url.startsWith('blob:https://web.telegram.org/')) {
        // Blob URL 由 JavaScript 处理，不直接下载
        return;
      } else if (url.contains('telegram.org') || url.contains('t.me')) {
        if (!url.startsWith('http')) processedUrl = url.startsWith('//') ? 'https:$url' : 'https://$url';
        if (processedUrl.contains('/progressive/https://')) {
          processedUrl = processedUrl.substring(processedUrl.indexOf('/progressive/https://') + '/progressive/'.length);
        }
      } else if (url.contains('youtube.com') || url.contains('youtu.be')) {
        processedUrl = await _resolveYouTubeUrl(url);
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
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('开始下载，将在后台进行...'), duration: Duration(seconds: 2)));
            unawaited(_performBackgroundDownload(processedUrl, mediaType));
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('开始下载，将在后台进行...'), duration: Duration(seconds: 2)));
        unawaited(_performBackgroundDownload(processedUrl, selectedType));
      }
    } catch (e, stackTrace) {
      debugPrint('处理下载时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载出错: $e')));
    }
  }

  Future<String> _resolveYouTubeUrl(String url) async {
    return url; // 占位符，需集成 youtube_explode_dart
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(context).pop({'download': true, 'mediaType': selectedType}),
            child: const Text('解析测试'),
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
    if (url.startsWith('blob:https://web.telegram.org/')) return false; // Blob URL 由 JavaScript 处理
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
      if (lowercaseUrl.endsWith(ext)) return true;
    }
    final downloadKeywords = [
      '/download/', '/dl/', '/attachment/', '/file/', '/media/download/',
      '/photo/download/', '/video/download/', '/document/download/'
    ];
    for (final keyword in downloadKeywords) {
      if (lowercaseUrl.contains(keyword)) return true;
    }
    final downloadParams = ['download=true', 'dl=1', 'attachment=1'];
    final uri = Uri.parse(url);
    final queryString = uri.query.toLowerCase();
    for (final param in downloadParams) {
      if (queryString.contains(param)) return true;
    }
    if (url.contains('youtube.com') || url.contains('youtu.be')) return true;
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
    if (path.endsWith('.m3u8')) return 'application/x-mpegURL';
    if (path.endsWith('.mp3')) return 'audio/mpeg';
    if (path.endsWith('.wav')) return 'audio/wav';
    if (path.endsWith('.ogg')) return 'audio/ogg';
    if (path.endsWith('.aac')) return 'audio/aac';
    if (path.endsWith('.flac')) return 'audio/flac';
    return 'application/octet-stream';
  }

  Future<File?> _downloadFile(String url, MediaType mediaType) async { // Added mediaType parameter
    try {
      debugPrint('开始下载文件，URL: $url');
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 60);
      dio.options.receiveTimeout = const Duration(seconds: 300);
      dio.options.sendTimeout = const Duration(seconds: 60);

      dio.options.headers = {
        'User-Agent': 'Mozilla/5.5 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
      };

      if (url.contains('telegram.org') || url.contains('t.me')) {
        dio.options.headers['Referer'] = 'https://web.telegram.org/a/';
        dio.options.headers['Origin'] = 'https://web.telegram.org';
        // 注意：webview_flutter 不支持直接获取 cookies
        // 如果需要 cookies，可以考虑其他方案
      } else if (url.contains('youtube.com') || url.contains('youtu.be')) {
        dio.options.headers['Referer'] = 'https://www.youtube.com';
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
                    mimeType.startsWith('video/') || mimeType == 'application/x-mpegURL' ? '.mp4' :
                    mimeType.startsWith('audio/') ? '.mp3' : '.bin';
      }

      final filePath = '${mediaDir.path}/$uuid$extension';
      debugPrint('将下载到文件路径: $filePath');

      int retryCount = 0;
      const maxRetries = 3;

      while (retryCount < maxRetries) {
        try {
          final response = await dio.download(
            url,
            filePath,
            deleteOnError: true,
            options: Options(
              followRedirects: true,
              maxRedirects: 5,
              validateStatus: (status) => status != null && status < 500, // Treat 4xx as valid, handle in catch block
              responseType: ResponseType.bytes,
            ),
            onReceiveProgress: (received, total) {
              if (total != -1) {
                final progress = received / total;
                debugPrint('下载进度: ${(progress * 100).toStringAsFixed(2)}%');
                if (mediaType == MediaType.video) { // Only update for video downloads
                  _videoDownloadProgress.value = progress;
                }
              }
            },
          );
          if (extension == '.m3u8') await _handleM3u8Download(filePath, url);
          break;
        } catch (e, stackTrace) {
          retryCount++;
          debugPrint('下载失败 (尝试 $retryCount/$maxRetries): $e');
          if (e is DioException) {
            if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout || e.type == DioExceptionType.sendTimeout) {
              debugPrint('下载超时错误: $e');
              if (retryCount >= maxRetries) throw Exception('下载超时，请检查网络连接或稍后重试');
            } else if (e.type == DioExceptionType.badResponse) {
              debugPrint('下载响应错误: 状态码 ${e.response?.statusCode}, 错误: ${e.response?.data}');
              if (e.response?.statusCode == 400) {
                if (retryCount >= maxRetries) throw Exception('下载失败: 文件无法访问或Bot权限不足');
              } else {
                if (retryCount >= maxRetries) throw Exception('下载失败: 服务器返回错误 ${e.response?.statusCode}');
              }
            } else if (e.type == DioExceptionType.unknown) {
              debugPrint('下载未知错误 (可能是网络问题): $e');
              if (retryCount >= maxRetries) throw Exception('下载失败: 网络连接异常或未知错误');
            } else {
              if (retryCount >= maxRetries) throw Exception('下载失败: ${e.message}');
            }
          } else {
            if (retryCount >= maxRetries) throw Exception('下载失败: $e');
          }
          await Future.delayed(Duration(seconds: retryCount * 3)); // Increased delay
        }
      }

      final file = File(filePath);
      if (await file.exists() && await file.length() > 0) return file;
      await file.delete();
      return null;
    } catch (e, stackTrace) {
      debugPrint('下载文件时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      return null;
    }
  }

  Future<void> _handleM3u8Download(String m3u8Path, String url) async {
    final dio = Dio();
    final response = await dio.get(url);
    final segments = response.data.toString().split('\n').where((line) => line.startsWith('http')).toList();
    if (segments.isNotEmpty) {
      final outputPath = '${m3u8Path.replaceAll('.m3u8', '.mp4')}';
      final file = File(outputPath)..createSync();
      final sink = file.openWrite();
      for (final segment in segments) {
        final segmentResponse = await dio.get(segment, options: Options(responseType: ResponseType.bytes));
        sink.add(segmentResponse.data);
      }
      await sink.close();
      await _saveToMediaLibrary(file, MediaType.video);
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
      if (duplicate != null) throw Exception('文件已存在于媒体库中');
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
    // 检查是否已存在相同URL的书签
    if (_bookmarks.any((bookmark) => bookmark['url'] == url)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('书签已存在')));
      return;
    }

    // 创建一个文本控制器，初始值设为当前网页的标题或URL
    final nameController = TextEditingController();
    
    // 如果在浏览网页，尝试获取网页标题
    if (!_showHomePage && _isBrowsingWebPage) {
      nameController.text = "获取中...";
      _controller.getTitle().then((title) {
        if (title != null && title.isNotEmpty && nameController.text == "获取中...") {
          nameController.text = title;
          // 自动选中文本，方便用户编辑
          nameController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: title.length,
          );
        }
      }).catchError((error) {
        debugPrint('获取网页标题出错: $error');
        if (nameController.text == "获取中...") {
          nameController.text = "";
        }
      });
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加书签'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '书签名称',
                hintText: '输入自定义名称',
                helperText: '为书签设置一个简短易记的名称',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text('URL: $url', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && nameController.text != "获取中...") {
                // 创建一个变量存储加载对话框的context
                BuildContext? loadingDialogContext;

                // 显示加载对话框并保存context
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) {
                    loadingDialogContext = context;
                    return const AlertDialog(
                      content: Row(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(width: 20),
                          Text('添加中...'),
                        ],
                      ),
                    );
                  },
                );

                setState(() => _bookmarks.add({
                  'name': nameController.text,
                  'url': url,
                }));
                await _saveBookmarks();

                // 安全地关闭加载对话框
                if (loadingDialogContext != null && Navigator.canPop(loadingDialogContext!)) {
                  Navigator.pop(loadingDialogContext!);
                }

                // 关闭主对话框
                Navigator.of(context).pop();

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('已将"${nameController.text}"添加到书签'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              } else if (nameController.text == "获取中...") {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('请等待网页标题获取完成，或输入自定义名称'),
                    duration: Duration(seconds: 2),
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('请输入书签名称'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showBookmarks() {
    showModalBottomSheet(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter modalSetState) {
          return ListView.builder(
            itemCount: _bookmarks.length,
            itemBuilder: (context, index) {
              final bookmark = _bookmarks[index];
              return ListTile(
                title: Text(bookmark['name'] ?? bookmark['url']!),
                onTap: () {
                  _loadUrl(bookmark['url']!);
                  Navigator.pop(context);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, color: Colors.blue),
                      onPressed: () {
                        Navigator.pop(context);
                        _showRenameBookmarkDialog(context, index);
                      },
                      tooltip: '重命名',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () async {
                        final shouldDelete = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('删除书签'),
                            content: Text('确定要删除书签 "${bookmark['name']}" 吗？'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
                            ],
                          ),
                        ) ?? false;
                        if (shouldDelete) {
                          modalSetState(() {
                            _bookmarks.removeAt(index);
                          });
                          _saveBookmarks();
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除书签')));
                        }
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showRenameBookmarkDialog(BuildContext context, int index) {
    final bookmark = _bookmarks[index];
    final nameController = TextEditingController(text: bookmark['name']);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名书签'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '书签名称', hintText: '输入新的书签名称'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text('URL: ${bookmark['url']}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && nameController.text != bookmark['name']) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const AlertDialog(
                    content: Row(
                      children: [CircularProgressIndicator(), SizedBox(width: 20), Text('保存中...')],
                    ),
                  ),
                );
                setState(() => _bookmarks[index]['name'] = nameController.text);
                await _saveBookmarks();
                Navigator.of(context).pop();
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('书签名称已更新')));
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(_bookmarks);
      await prefs.setString('bookmarks', jsonString);
    } catch (e) {
      debugPrint('Error saving bookmarks: $e');
    }
  }

  Future<void> _loadCommonWebsites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final commonWebsitesJson = prefs.getString('common_websites');
      if (commonWebsitesJson != null && commonWebsitesJson.isNotEmpty) {
        final decoded = jsonDecode(commonWebsitesJson);
        final List<dynamic> websitesList = decoded is List ? decoded : [];
        
        if (websitesList.isNotEmpty) {
          setState(() {
            _commonWebsites.clear();
            _commonWebsites.addAll(websitesList.map((item) => {
              'name': item['name'],
              'url': item['url'],
              'iconCode': Icons.public.codePoint,
            }).toList());
          });
          debugPrint('从SharedPreferences加载了${_commonWebsites.length}个常用网站');
          return;
        }
      }
      
      // 如果没有从SharedPreferences加载到数据，或者加载的数据为空，则加载默认网站
      setState(() {
        _commonWebsites.clear();
        _commonWebsites.addAll([
          {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
          {'name': 'Telegram', 'url': 'https://web.telegram.org', 'iconCode': Icons.public.codePoint},
          {'name': '百度', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint}
        ]);
      });
      debugPrint('加载了默认常用网站');
      await _saveCommonWebsites();
    } catch (e) {
      debugPrint('Error loading common websites: $e');
      // 出错时加载默认网站
      setState(() {
        _commonWebsites.clear();
        _commonWebsites.addAll([
          {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
          {'name': 'Telegram', 'url': 'https://web.telegram.org', 'iconCode': Icons.public.codePoint},
          {'name': '百度', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint}
        ]);
      });
      debugPrint('加载出错，使用默认常用网站');
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
        if (!_showHomePage) {
          if (await _controller.canGoBack()) {
            _controller.goBack();
            return false;
          } else {
            _goToHomePage();
            return false;
          }
        }
        return true;
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          titleSpacing: 0,
          title: _showHomePage ? const Text('浏览器') : const SizedBox.shrink(),
          leading: _showHomePage
              ? null
              : IconButton(
                  icon: const Icon(Icons.home),
                  onPressed: _goToHomePage,
                  tooltip: '回到主页',
                ),
          centerTitle: true,
          actions: [
            // 添加媒体库按钮到actions列表的第一个位置
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.photo_library),
                onPressed: () {
                  print('[BrowserPage] 媒体库按钮被点击');
                  // 使用MainScreen的PageController导航到媒体管理页面（索引2）
                  final mainScreenState = MainScreenState.instance;
                  print('[BrowserPage] mainScreenState: $mainScreenState');
                  if (mainScreenState != null) {
                    print('[BrowserPage] 准备调用goToPage(2)');
                    mainScreenState.goToPage(2); // 索引2是媒体管理页面
                    print('[BrowserPage] 已调用goToPage(2)');
                  } else {
                    print('[BrowserPage] 错误: mainScreenState为null，无法导航');
                    // 尝试使用Navigator直接导航到媒体管理页面
                    print('[BrowserPage] 尝试使用Navigator直接导航');
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (context) => const MediaManagerPage()),
                    );
                  }
                },
                tooltip: '媒体库',
              ),
            if (_isBrowsingWebPage && _shouldKeepWebPageState && _showHomePage)
              IconButton(
                icon: const Icon(Icons.arrow_right_alt),
                onPressed: _restoreWebPage,
                tooltip: '返回上次浏览的网页',
              ),
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
            IconButton(
              icon: const Icon(Icons.telegram),
              onPressed: _showTelegramDownloadDialog,
              tooltip: 'Telegram 下载',
            ),
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red),
                onPressed: _exitWebPage,
                tooltip: '退出网页',
              ),
          ],
        ),
        body: Stack( // Wrap the body in a Stack
          children: [
            _showHomePage
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
                                if (await _controller.canGoBack()) _controller.goBack();
                              },
                              tooltip: '后退',
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_forward),
                              onPressed: () async {
                                if (await _controller.canGoForward()) _controller.goForward();
                              },
                              tooltip: '前进',
                            ),
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              onPressed: () => _controller.reload(),
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
                              onPressed: () => _loadUrl(_urlController.text),
                              tooltip: '前往',
                            ),
                          ],
                        ),
                      ),
                      if (_isLoading) LinearProgressIndicator(value: _loadingProgress),
                      Expanded(
                        child: Stack(
                          children: [
                            WebViewWidget(controller: _controller),
                          ],
                        ),
                      ),
                    ],
                  ),
            // Floating Download Progress Indicator
            ValueListenableBuilder<bool>(
              valueListenable: _isDownloadingVideo,
              builder: (context, isDownloading, child) {
                if (!isDownloading) {
                  return const SizedBox.shrink(); // Hide if not downloading video
                }
                return Positioned(
                  left: 16.0,
                  bottom: 16.0,
                  child: ValueListenableBuilder<double?>(
                    valueListenable: _videoDownloadProgress,
                    builder: (context, progress, child) {
                      if (progress == null) {
                        return const SizedBox.shrink(); // Also hide if progress is null (e.g., finished)
                      }
                      return Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 50,
                              height: 50,
                              child: CircularProgressIndicator(
                                value: progress,
                                backgroundColor: Colors.grey.withOpacity(0.5),
                                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                                strokeWidth: 4,
                              ),
                            ),
                            Text(
                              '${(progress * 100).toInt()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stopTelegramPolling();
    _urlController.dispose();
    _videoDownloadProgress.dispose(); // Dispose ValueNotifier
    _isDownloadingVideo.dispose(); // Dispose ValueNotifier
    _saveBookmarks().then((_) => debugPrint('书签保存完成')).catchError((error) => debugPrint('保存书签时出错: $error'));
    _saveCommonWebsites().then((_) => debugPrint('常用网站保存完成')).catchError((error) => debugPrint('保存常用网站时出错: $error'));
    widget.onBrowserHomePageChanged?.call(true);
    super.dispose();
  }

  Future<void> _performBackgroundDownload(String url, MediaType mediaType) async {
    _downloadingUrls.add(url);
    try {
      debugPrint('开始后台下载: $url, 媒体类型: $mediaType');
      
      if (mediaType == MediaType.video) {
        _isDownloadingVideo.value = true;
        _videoDownloadProgress.value = 0.0;
      }

      final file = await _downloadFile(url, mediaType);

      if (file != null) {
        debugPrint('文件下载成功: ${file.path}');
        await _saveToMediaLibrary(file, mediaType);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${mediaType == MediaType.video ? "视频" : mediaType == MediaType.image ? "图片" : "音频"}已成功保存到媒体库: ${file.path.split('/').last}'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(label: '查看', onPressed: () => Navigator.pushNamed(context, '/media_manager')),
            ),
          );
        }
      } else {
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
      _downloadingUrls.remove(url);
      if (mediaType == MediaType.video) {
        _isDownloadingVideo.value = false;
        _videoDownloadProgress.value = null;
      }
    }
  }
  
  /// 显示 Telegram 下载对话框
  void _showTelegramDownloadDialog() {
    if (!_telegramService.isConfigured) {
      _showBotTokenConfigDialog();
    } else {
      _showTelegramUrlInputDialog();
    }
  }
  
  /// 显示 Bot Token 配置对话框
  void _showBotTokenConfigDialog() {
    final tokenController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('配置 Telegram Bot'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '请先配置 Telegram Bot Token 以使用下载功能：\n\n'
              '1. 在 Telegram 中找到 @BotFather\n'
              '2. 发送 /newbot 创建新机器人\n'
              '3. 按提示设置机器人名称\n'
              '4. 复制获得的 Token 并粘贴到下方',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: tokenController,
              decoration: const InputDecoration(
                labelText: 'Bot Token',
                hintText: '例如: 123456789:ABCdefGHIjklMNOpqrSTUVwxyz',
                border: OutlineInputBorder(),
                // 确保内容可以自动换行
                helperMaxLines: 3,
                errorMaxLines: 3,
              ),
              // 增加最大行数，防止溢出
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final token = tokenController.text.trim();
              if (token.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入 Bot Token')),
                );
                return;
              }
              
              // 关闭当前配置对话框
              Navigator.pop(dialogContext);
              // 添加短暂延迟，确保对话框已完全关闭
              await Future.delayed(const Duration(milliseconds: 100));
              if (!mounted) return; // 如果组件已卸载，直接返回

              // 创建一个变量存储加载对话框的context
              BuildContext? loadingDialogContext;

              // 显示加载对话框并保存context
              showDialog(
                context: context, // Use the main context here
                barrierDismissible: false,
                builder: (context) {
                  loadingDialogContext = context;
                  return const AlertDialog(
                    content: Row(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(width: 16),
                        Text('验证 Bot Token...'),
                      ],
                    ),
                  );
                },
              );
              
              bool isValid = false;
              try {
                // 添加超时处理
                isValid = await _telegramService.validateBotToken(token).timeout(
                  const Duration(seconds: 15),
                  onTimeout: () {
                    print('验证 Bot Token 超时');
                    return false;
                  },
                );
              } catch (e) {
                print('验证 Bot Token 过程中发生错误: $e');
                isValid = false;
              }

              // 安全地关闭加载对话框
              if (loadingDialogContext != null && mounted) {
                try {
                  Navigator.pop(loadingDialogContext!); // 关闭加载对话框
                } catch (e) {
                  // 忽略导航错误，可能是因为widget已经被销毁
                }
              }
              
              if (mounted) { // 确保组件仍然挂载
                // 显示验证结果对话框
                showDialog(
                  context: context, // Use the main context for this dialog
                  builder: (context) => AlertDialog(
                    title: Text(isValid ? '验证成功' : '验证失败'),
                    content: Text(isValid ? 'Bot Token 验证通过！' : '无效的 Bot Token，请检查后重试'),
                    actions: [
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(context); // 关闭验证结果对话框
                          if (isValid) {
                            final success = await _telegramService.saveBotToken(token);
                            if (mounted) {
                              if (success) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Bot Token 配置成功！'),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                                // 启动轮询
                                _startTelegramPolling();
                                if (mounted) {
                                  _showTelegramUrlInputDialog();
                                }
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('保存 Bot Token 失败'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          } else {
                            _showBotTokenConfigDialog(); // 重新显示配置对话框
                          }
                        },
                        child: Text('确定'),
                      ),
                    ],
                  ),
                );
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
  
  /// 显示 Telegram URL 输入对话框
  void _showTelegramUrlInputDialog() {
    final urlController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Telegram 媒体下载'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
               'Telegram Bot 下载功能说明：\n\n'
               '由于 Telegram Bot API 限制，机器人只能下载发送给它的消息。\n\n'
               '使用方法：\n'
               '1. 在 Telegram 中找到您的机器人\n'
               '2. 将要下载的媒体文件转发给机器人\n'
               '3. 机器人会自动处理并下载文件\n\n'
               '或者输入消息链接进行解析测试：',
               style: TextStyle(fontSize: 14),
             ),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                 labelText: 'Telegram 消息链接（测试解析）',
                 hintText: '例如: https://t.me/channel/123',
                 border: OutlineInputBorder(),
               ),
              maxLines: 3,
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
              _showBotTokenConfigDialog();
            },
            child: const Text('重新配置 Bot'),
          ),
          ElevatedButton(
            onPressed: () async {
              final url = urlController.text.trim();
              if (url.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入 Telegram 消息链接')),
                );
                return;
              }
              
              Navigator.pop(context);
              if (mounted) {
                await _downloadFromTelegram(url);
              }
            },
            child: const Text('解析测试'),
          ),
        ],
      ),
    );
  }
  
  /// 从 Telegram 下载媒体
  Future<void> _downloadFromTelegram(String url) async {
    // 显示下载进度对话框
    double progress = 0.0;
    bool isDownloading = true;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('正在下载'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 16),
              Text('${(progress * 100).toInt()}%'),
            ],
          ),
          actions: isDownloading
              ? []
              : [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('确定'),
                  ),
                ],
        ),
      ),
    );
    
    try {
      final result = await _telegramService.downloadFromMessage(
        url,
        onProgress: (p) {
          if (mounted) {
            // 更新进度
            progress = p;
            // 这里需要更新对话框状态，但由于 StatefulBuilder 的限制，
            // 我们可能需要使用其他方法来更新进度
          }
        },
      );
      
      isDownloading = false;
      if (mounted) {
        try {
          Navigator.pop(context); // 关闭进度对话框
        } catch (e) {
          // 忽略导航错误，可能是因为widget已经被销毁
        }
      }
      
      if (result.success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('下载成功：${result.fileName}'),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: '查看',
              onPressed: () {
                // 导航到媒体管理页面
                final mainScreenState = MainScreenState.instance;
                if (mainScreenState != null) {
                  mainScreenState.goToPage(2);
                } else {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const MediaManagerPage()),
                  );
                }
              },
            ),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('下载失败：${result.error}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      isDownloading = false;
      if (mounted) {
        try {
          Navigator.pop(context); // 关闭进度对话框
        } catch (navError) {
          // 忽略导航错误，可能是因为widget已经被销毁
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('下载出错：$e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  /// 启动Telegram消息轮询
  Future<void> _startTelegramPolling() async {
    if (_isPollingActive) return;
    
    // 从SharedPreferences加载最后处理的更新ID
    await _loadLastUpdateId();
    
    _isPollingActive = true;
    _telegramPollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _checkForNewMessages();
    });
    
    debugPrint('Telegram消息轮询已启动，最后更新ID: $_lastUpdateId');
  }
  
  /// 停止Telegram消息轮询
  Future<void> _stopTelegramPolling() async {
    _telegramPollingTimer?.cancel();
    _telegramPollingTimer = null;
    _isPollingActive = false;
    
    // 保存最后处理的更新ID
    await _saveLastUpdateId();
    
    debugPrint('Telegram消息轮询已停止，最后更新ID: $_lastUpdateId');
  }
  
  /// 加载最后处理的更新ID
  Future<void> _loadLastUpdateId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastUpdateId = prefs.getInt('telegram_last_update_id') ?? 0;
    } catch (e) {
      debugPrint('加载最后更新ID失败: $e');
      _lastUpdateId = 0;
    }
  }
  
  /// 保存最后处理的更新ID
  Future<void> _saveLastUpdateId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('telegram_last_update_id', _lastUpdateId);
    } catch (e) {
      debugPrint('保存最后更新ID失败: $e');
    }
  }
  
  /// 加载已下载的文件ID
  Future<void> _loadDownloadedFileIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final downloadedIds = prefs.getStringList(_downloadedFileIdsKey) ?? [];
      _downloadedFileIds.clear();
      _downloadedFileIds.addAll(downloadedIds);
      debugPrint('已加载${_downloadedFileIds.length}个已下载文件ID');
    } catch (e) {
      debugPrint('加载已下载文件ID失败: $e');
    }
  }
  
  /// 保存已下载的文件ID
  Future<void> _saveDownloadedFileIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_downloadedFileIdsKey, _downloadedFileIds.toList());
    } catch (e) {
      debugPrint('保存已下载文件ID失败: $e');
    }
  }
  
  /// 添加已下载的文件ID
  Future<void> _addDownloadedFileId(String fileId) async {
    if (fileId.isEmpty) return;
    
    if (_downloadedFileIds.add(fileId)) {
      // 只有当集合发生变化时才保存
      await _saveDownloadedFileIds();
    }
  }
  
  /// 检查新消息
  Future<void> _checkForNewMessages() async {
    try {
      if (!_telegramService.isConfigured) {
        await _stopTelegramPolling();
        return;
      }
      
      final updates = await _telegramService.getUpdates();
      bool hasNewUpdates = false;
      
      for (final update in updates) {
        final updateId = update['update_id'] as int;
        
        // 只处理新消息
        if (updateId > _lastUpdateId) {
          _lastUpdateId = updateId;
          hasNewUpdates = true;
          await _processUpdate(update);
        }
      }
      
      // 如果有新消息，保存最后更新ID
      if (hasNewUpdates) {
        await _saveLastUpdateId();
      }
    } catch (e) {
      debugPrint('检查新消息失败: $e');
    }
  }
  
  /// 处理单个更新
  Future<void> _processUpdate(Map<String, dynamic> update) async {
    try {
      final message = update['message'];
      if (message == null) return;
      
      // 检查是否有媒体文件
      final mediaFileId = _extractMediaFileId(message);
      if (mediaFileId != null) {
        await _downloadMediaFromBot(mediaFileId, message);
      }
    } catch (e) {
      debugPrint('处理更新失败: $e');
    }
  }
  
  /// 提取媒体文件ID
  String? _extractMediaFileId(Map<String, dynamic> message) {
    // 检查照片
    if (message['photo'] != null) {
      final photos = message['photo'] as List;
      if (photos.isNotEmpty) {
        // 获取最大尺寸的照片
        final largestPhoto = photos.reduce((a, b) => 
          (a['file_size'] ?? 0) > (b['file_size'] ?? 0) ? a : b);
        return largestPhoto['file_id'];
      }
    }
    
    // 检查视频
    if (message['video'] != null) {
      return message['video']['file_id'];
    }
    
    // 检查动画(GIF)
    if (message['animation'] != null) {
      return message['animation']['file_id'];
    }
    
    // 检查文档(可能是视频或图片)
    if (message['document'] != null) {
      final document = message['document'];
      final mimeType = document['mime_type'] ?? '';
      if (mimeType.startsWith('image/') || mimeType.startsWith('video/')) {
        return document['file_id'];
      }
    }
    
    return null;
  }
  
  /// 从Bot下载媒体文件
  Future<void> _downloadMediaFromBot(String fileId, Map<String, dynamic> message) async {
    // Determine media type before starting download to control progress indicator
    MediaType? mediaType;
    if (message['video'] != null || message['animation'] != null) {
      mediaType = MediaType.video;
    } else if (message['photo'] != null) {
      mediaType = MediaType.image;
    } else if (message['document'] != null) {
      final document = message['document'];
      final mimeType = document['mime_type'] ?? '';
      if (mimeType.startsWith('video/')) {
        mediaType = MediaType.video;
      } else if (mimeType.startsWith('image/')) {
        mediaType = MediaType.image;
      }
    }

    if (mediaType == MediaType.video) {
      _isDownloadingVideo.value = true;
      _videoDownloadProgress.value = 0.0;
    }

    try {
      // 检查文件ID是否已经下载过
      if (_downloadedFileIds.contains(fileId)) {
        debugPrint('文件已存在，跳过下载: $fileId');
        return;
      }
      
      debugPrint('开始下载媒体文件: $fileId');
      
      final result = await _telegramService.downloadFileById(
        fileId,
        onProgress: (progress) {
          debugPrint('下载进度: ${(progress * 100).toStringAsFixed(1)}%');
          if (mediaType == MediaType.video) { // Use the inferred mediaType
             _videoDownloadProgress.value = progress;
          }
        },
      );
      
      if (result.success && mounted) {
        // 如果是已存在的文件，显示不同的通知
        if (result.isExisting) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('文件已存在：${result.fileName}'),
              backgroundColor: Colors.blue,
            ),
          );
          debugPrint('媒体文件已存在: ${result.fileName}');
        } else {
          // 显示成功通知
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('自动下载成功：${result.fileName}'),
              backgroundColor: Colors.green,
              action: SnackBarAction(
                label: '查看',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const MediaManagerPage(),
                    ),
                  );
                },
              ),
            ),
          );
          
          // 刷新媒体库
          await _refreshMediaLibrary();
          
          debugPrint('媒体文件下载成功: ${result.fileName}');
        }
        
        // 将文件ID添加到已下载集合中
        await _addDownloadedFileId(fileId);
      } else {
        debugPrint('媒体文件下载失败: ${result.error}');
      }
    } catch (e) {
      debugPrint('下载媒体文件异常: $e');
    } finally {
      if (mediaType == MediaType.video) {
        _isDownloadingVideo.value = false;
        _videoDownloadProgress.value = null;
      }
    }
  }
  
  /// 刷新媒体库
  Future<void> _refreshMediaLibrary() async {
    try {
      // 这里可以添加刷新媒体库的逻辑
      // 例如通知MediaManagerPage刷新数据
    } catch (e) {
      debugPrint('刷新媒体库失败: $e');
    }
  }
}

