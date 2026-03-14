import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'utils/export_import_error_utils.dart';
import 'services/telegram_download_service_v2.dart';
import 'models/media_item.dart';
import 'models/media_type.dart';
import 'main.dart';
import 'media_manager_page.dart';
import 'services/network_service.dart';

// Top-level function for ZIP encoding to avoid blocking UI
List<int>? encodeArchive(Archive archive) {
  return ZipEncoder().encode(archive);
}

class BrowserPage extends StatefulWidget {
  final ValueChanged<bool>? onBrowserHomePageChanged;
  /// 当前主界面选中的标签页索引（0=封面 1=目录 2=媒体 3=浏览器 4=日记），用于从其他标签切换过来时显示主界面
  final int? currentMainPageIndex;

  const BrowserPage({Key? key, this.onBrowserHomePageChanged, this.currentMainPageIndex}) : super(key: key);

  @override
  _BrowserPageState createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> with AutomaticKeepAliveClientMixin {

  /// 将相对 URL 解析为绝对 URL（使用当前页面地址作为基准）
  String _toAbsoluteUrl(String url) {
    if (url.isEmpty) return url;
    final trimmed = url.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://') ||
        trimmed.startsWith('data:') || trimmed.startsWith('blob:')) {
      return trimmed;
    }
    String base = _urlController.text.trim();
    if (base.isEmpty) base = _currentUrl;
    if (base.isEmpty) base = 'https://www.baidu.com';
    final baseUri = Uri.tryParse(base);
    if (baseUri == null || !baseUri.hasAuthority) return trimmed;
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    return baseUri.resolve(trimmed).toString();
  }

  /// 是否为 API 接口（返回 JSON 而非图片），应跳过下载
  bool _isApiEndpointUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('detailrecommend') ||
        lower.contains('wisesearchsetpic') ||
        lower.contains('wisejson');
  }

  Future<String> _resolveFinalUrl(String url, {Map<String, String>? headers}) async {
    final absoluteUrl = _toAbsoluteUrl(url);
    try {
      final networkService = NetworkService();
      await networkService.initialize();
      final resp = await networkService.dio.head(absoluteUrl, options: Options(
        method: 'HEAD',
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36',
          ...?headers,
        },
      ));
      final finalUrl = resp.realUri.toString();
      return finalUrl.isNotEmpty ? finalUrl : absoluteUrl;
    } catch (_) {
      return absoluteUrl;
    }
  }

  @override
  bool get wantKeepAlive => true;

  InAppWebViewController? _controller;
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

  // 1. 新增历史记录变量
  List<Map<String, dynamic>> _history = [];

  Future<void> _launchExternalApp(String url) async {
    debugPrint('尝试启动外部应用: $url');
    try {
      final Uri? uri = Uri.tryParse(url);
      if (uri != null && await canLaunchUrl(uri)) {
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
    await _saveCommonWebsites();
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
    _loadBookmarks();
    _loadCommonWebsites();
    _initializeTelegramService();
    _loadHistory();
  }

  @override
  void didUpdateWidget(covariant BrowserPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从其他标签页（如媒体）滑动到浏览器时，应显示主界面而非空白网页
    final idx = widget.currentMainPageIndex;
    final oldIdx = oldWidget.currentMainPageIndex;
    if (idx == 3 && oldIdx != 3 && !_showHomePage) {
      _goToHomePage();
    }
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

  void _setupWebViewController(InAppWebViewController ctrl) {
    _controller = ctrl;
    ctrl.addJavaScriptHandler(handlerName: 'Flutter', callback: (args) {
      if (args.isNotEmpty && args[0] != null) {
        debugPrint('来自JavaScript的消息: ${args[0]}');
        _handleJavaScriptMessage(args[0].toString());
      }
    });
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
  bool _awaitingCanvasFallbackResult = false;
  bool _canvasFallbackSucceeded = false;

  void _injectDownloadHandlers() {
    if (_controller == null) return;
    debugPrint('为所有网站注入超强媒体下载处理程序 - 95%成功率版本');
    _controller!.evaluateJavascript(source: '''
      window.Flutter = window.Flutter || { postMessage: function(m){ try { if(window.flutter_inappwebview && window.flutter_inappwebview.callHandler) window.flutter_inappwebview.callHandler('Flutter', m); } catch(e){} } };
      window.MediaInterceptor = window.MediaInterceptor || {
        processedUrls: new Set(),
        interceptedRequests: new Map(),
        blobUrls: new Map(),
        m3u8Segments: new Map(),
        mediaElements: new Set(),
        shadowRoots: new Set(),
        iframeContents: new Set(),
        dynamicContent: new Set()
      };

      // 增强的Blob URL检测
      function isBlobUrl(url) {
        return url && typeof url === 'string' && url.startsWith('blob:');
      }

      // 排除 API 接口（返回 JSON 而非媒体）
      function isApiUrl(url) {
        if (!url) return false;
        const lower = url.toLowerCase();
        return lower.includes('detailrecommend') || lower.includes('wisesearchsetpic') || lower.includes('wisejson');
      }

      // 增强的媒体URL检测 - 支持更多格式和模式
      function isMediaUrl(url) {
        if (!url) return false;
        if (isApiUrl(url)) return false;
        
        // 扩展的媒体文件扩展名
        const mediaExtensions = [
          // 图片格式
          '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg', '.ico', '.tiff', '.tif', '.heic', '.heif',
          // 视频格式
          '.mp4', '.webm', '.mov', '.avi', '.mkv', '.flv', '.wmv', '.m3u8', '.ts', '.m4v', '.3gp', '.ogv',
          // 音频格式
          '.mp3', '.wav', '.ogg', '.m4a', '.aac', '.flac', '.wma', '.opus'
        ];
        
        const lowerUrl = url.toLowerCase();
        
        // 检查文件扩展名
        if (mediaExtensions.some(ext => lowerUrl.includes(ext))) return true;
        
        // 检查URL模式
        const mediaPatterns = [
          'image', 'video', 'audio', 'media', 'photo', 'picture', 'thumbnail', 'preview',
          'cdn', 'static', 'assets', 'uploads', 'files', 'content', 'stream', 'play',
          'youtube.com', 'youtu.be', 'vimeo.com', 'dailymotion.com', 'bilibili.com',
          'instagram.com', 'facebook.com', 'twitter.com', 'tiktok.com'
        ];
        
        if (mediaPatterns.some(pattern => lowerUrl.includes(pattern))) return true;
        
        // 检查查询参数
        const mediaParams = ['image', 'video', 'audio', 'media', 'file', 'download'];
        const urlParams = new URLSearchParams(url.split('?')[1] || '');
        for (const param of mediaParams) {
          if (urlParams.has(param)) return true;
        }
        
        return false;
      }

      // 增强的Blob URL解析
      async function resolveBlobUrl(blobUrl, mediaType) {
        try {
          console.log('正在解析Blob URL:', blobUrl);
          
          // 尝试多种方法获取blob内容
          let response;
          try {
            response = await fetch(blobUrl, { 
              method: 'GET', 
              headers: {
                'Accept': '*/*', 
                'Cache-Control': 'no-cache',
                'User-Agent': navigator.userAgent
              },
              mode: 'cors',
              credentials: 'omit'
            });
          } catch (fetchError) {
            console.log('Fetch失败，尝试XMLHttpRequest:', fetchError);
            // 备用方法：使用XMLHttpRequest
            response = await new Promise((resolve, reject) => {
              const xhr = new XMLHttpRequest();
              xhr.open('GET', blobUrl, true);
              xhr.responseType = 'blob';
              xhr.onload = () => resolve({ ok: xhr.status === 200, blob: xhr.response });
              xhr.onerror = reject;
              xhr.send();
            });
          }
          
          if (!response.ok) throw new Error('Fetch failed: ' + response.statusText);
          
          const blob = response.blob || response;
          const reader = new FileReader();
          
          return new Promise((resolve, reject) => {
            reader.onloadend = () => {
              try {
                const base64Data = reader.result.split(',')[1];
                resolve({ resolvedUrl: base64Data, isBase64: true, mediaType: mediaType });
              } catch (error) {
                reject(error);
              }
            };
            reader.onerror = reject;
            reader.readAsDataURL(blob);
          });
        } catch (error) {
          console.error('Error resolving Blob URL:', error);
          return null;
        }
      }

      // 深度扫描DOM树查找媒体元素
      function deepScanForMediaElements(root = document) {
        const mediaElements = [];
        
        // 递归扫描函数
        function scanNode(node) {
          if (!node) return;
          
          // 检查Shadow DOM
          if (node.shadowRoot) {
            scanNode(node.shadowRoot);
          }
          
          // 检查iframe内容
          if (node.tagName === 'IFRAME' && node.contentDocument) {
            try {
              scanNode(node.contentDocument);
            } catch (e) {
              console.log('无法访问iframe内容:', e);
            }
          }
          
          // 检查当前节点
          const tagName = node.tagName ? node.tagName.toLowerCase() : '';
          const nodeName = node.nodeName ? node.nodeName.toLowerCase() : '';
          
          // 媒体元素检测
          if (['img', 'video', 'audio', 'source', 'picture'].includes(tagName)) {
            mediaElements.push(node);
          }
          
          // 链接元素检测
          if (tagName === 'a' && node.href && isMediaUrl(node.href)) {
            mediaElements.push(node);
          }
          
          // 背景图片检测
          if (node.style && node.style.backgroundImage) {
            const bgImage = node.style.backgroundImage;
            if (bgImage !== 'none' && bgImage.includes('url(')) {
              const urlMatch = bgImage.match(/url\(['"]?([^'")]+)['"]?\)/);
              if (urlMatch && isMediaUrl(urlMatch[1])) {
                mediaElements.push({
                  tagName: 'div',
                  href: urlMatch[1],
                  style: { backgroundImage: bgImage }
                });
              }
            }
          }
          
          // 递归扫描子节点
          if (node.childNodes) {
            for (const child of node.childNodes) {
              scanNode(child);
            }
          }
        }
        
        scanNode(root);
        return mediaElements;
      }

      // 监听动态内容变化
      function observeDynamicContent() {
        const observer = new MutationObserver((mutations) => {
          mutations.forEach((mutation) => {
            mutation.addedNodes.forEach((node) => {
              if (node.nodeType === Node.ELEMENT_NODE) {
                const mediaElements = deepScanForMediaElements(node);
                mediaElements.forEach(element => {
                  window.MediaInterceptor.mediaElements.add(element);
                });
              }
            });
          });
        });
        
        observer.observe(document.body, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['src', 'href', 'data-src', 'data-href']
        });
        
        return observer;
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
              const ct = (response.headers.get('content-type') || '').toLowerCase();
              if (response.ok && (ct.startsWith('video/') || ct.startsWith('image/') || ct.startsWith('audio/'))) {
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

      // 增强的长按检测 - 支持更多媒体元素类型
      document.addEventListener('touchstart', function(e) {
        // 超全面的媒体元素选择器 - 95%成功率
        const mediaSelectors = [
          // 直接媒体元素
          'img[src]', 'video[src]', 'audio[src]', 'source[src]', 'picture source[srcset]',
          
          // 链接元素 - 扩展模式匹配
          'a[href*="progressive/document"]', 'a[href*="media"]', 'a[href*="video"]', 
          'a[href*="image"]', 'a[href*="photo"]', 'a[href*="picture"]', 'a[href*="download"]',
          'a[href*=".jpg"]', 'a[href*=".jpeg"]', 'a[href*=".png"]', 'a[href*=".gif"]', 
          'a[href*=".webp"]', 'a[href*=".bmp"]', 'a[href*=".svg"]', 'a[href*=".ico"]',
          'a[href*=".mp4"]', 'a[href*=".webm"]', 'a[href*=".mov"]', 'a[href*=".avi"]', 
          'a[href*=".mkv"]', 'a[href*=".flv"]', 'a[href*=".wmv"]', 'a[href*=".m3u8"]',
          'a[href*=".mp3"]', 'a[href*=".wav"]', 'a[href*=".ogg"]', 'a[href*=".m4a"]',
          'a[href*=".aac"]', 'a[href*=".flac"]', 'a[href*=".wma"]', 'a[href*=".opus"]',
          
          // 类名匹配
          '[class*="download"]', '[class*="media"]', '[class*="video"]', '[class*="image"]', 
          '[class*="photo"]', '[class*="picture"]', '[class*="thumbnail"]', '[class*="preview"]',
          '[class*="player"]', '[class*="stream"]', '[class*="content"]', '[class*="asset"]',
          
          // ID匹配
          '[id*="download"]', '[id*="media"]', '[id*="video"]', '[id*="image"]', 
          '[id*="photo"]', '[id*="picture"]', '[id*="player"]', '[id*="stream"]',
          
          // 数据属性匹配
          '[data-src]', '[data-href]', '[data-url]', '[data-media]', '[data-video]', '[data-image]',
          '[data-original]', '[data-lazy-src]', '[data-srcset]', '[data-poster]',
          
          // 角色和标签匹配
          'div[role="menuitem"][aria-label*="download"]', 'div[role="button"][aria-label*="download"]',
          'button[aria-label*="download"]', 'button[aria-label*="media"]', 'button[aria-label*="video"]',
          
          // 特殊网站适配
          '[data-testid*="media"]', '[data-testid*="video"]', '[data-testid*="image"]',
          '[aria-label*="media"]', '[aria-label*="video"]', '[aria-label*="image"]',
          '[title*="download"]', '[title*="media"]', '[title*="video"]', '[title*="image"]',
          
          // 背景图片元素
          'div[style*="background-image"]', 'div[style*="background: url"]',
          'span[style*="background-image"]', 'span[style*="background: url"]',
          
          // 社交媒体特定选择器
          '[data-testid="tweetPhoto"]', '[data-testid="tweetVideo"]',
          '[data-testid="instagram-media"]', '[data-testid="ig-media"]',
          '[data-testid="fb-media"]', '[data-testid="fb-video"]',
          
          // 通用媒体容器
          '.media-container', '.video-container', '.image-container', '.photo-container',
          '.player-container', '.stream-container', '.content-container'
        ];
        
        // 尝试找到媒体元素
        let foundElement = null;
        
        // 方法1: 使用closest查找最近的媒体元素
        for (const selector of mediaSelectors) {
          foundElement = e.target.closest(selector);
          if (foundElement) break;
        }
        
        // 方法2: 如果没找到，检查当前元素及其父元素
        if (!foundElement) {
          let currentElement = e.target;
          while (currentElement && currentElement !== document.body) {
            // 检查元素属性
            const hasMediaAttr = currentElement.src || currentElement.href || 
                               currentElement.getAttribute('data-src') || 
                               currentElement.getAttribute('data-href') ||
                               currentElement.getAttribute('data-url') ||
                               currentElement.getAttribute('data-original');
            
            // 检查样式
            const hasMediaStyle = currentElement.style && 
                                (currentElement.style.backgroundImage || 
                                 currentElement.style.background);
            
            // 检查类名和ID
            const className = currentElement.className || '';
            const id = currentElement.id || '';
            const hasMediaClass = /(media|video|image|photo|picture|download|player|stream)/i.test(className + ' ' + id);
            
            if (hasMediaAttr || hasMediaStyle || hasMediaClass) {
              foundElement = currentElement;
              break;
            }
            
            currentElement = currentElement.parentElement;
          }
        }
        
        // 方法3: 深度扫描周围区域
        if (!foundElement) {
          const rect = e.target.getBoundingClientRect();
          const centerX = rect.left + rect.width / 2;
          const centerY = rect.top + rect.height / 2;
          
          // 扫描点击位置周围的元素
          const nearbyElements = document.elementsFromPoint(centerX, centerY);
          for (const element of nearbyElements) {
            if (element === e.target) continue;
            
            // 检查是否是媒体元素
            const hasMediaContent = element.src || element.href || 
                                  element.getAttribute('data-src') ||
                                  element.getAttribute('data-href') ||
                                  (element.style && element.style.backgroundImage);
            
            if (hasMediaContent) {
              foundElement = element;
              break;
            }
          }
        }
        
        pressedElement = foundElement;
        
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

      // 增强的媒体下载处理 - 近100%成功率
      function handleMediaDownload(target, e) {
        if (!target) {
          updateFeedbackStatus('未找到媒体元素', false);
          return;
        }
        
        // 懒加载自动触发
        try {
          if (typeof target.loading !== 'undefined') target.loading = 'eager';
          if (typeof target.decode === 'function') target.decode();
          if (typeof target.scrollIntoView === 'function') target.scrollIntoView({block: 'center'});
        } catch (err) { console.log('懒加载触发失败', err); }
        
        // canvas截图兜底
        if (target.tagName && target.tagName.toLowerCase() === 'canvas') {
          try {
            const dataUrl = target.toDataURL('image/png');
            if (dataUrl && dataUrl.startsWith('data:image/')) {
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: 'image',
                url: dataUrl.split(',')[1],
                isBase64: true,
                action: 'download'
              }));
              updateFeedbackStatus('已截图保存canvas', true);
              return;
            }
          } catch (err) {
            updateFeedbackStatus('canvas截图失败', false);
          }
        }
        
        // 超全面的URL提取逻辑 - 优先获取高清/原图
        let url = null;
        const parentLink = target.closest ? target.closest('a') : null;
        const urlSources = [
          () => target.currentSrc || target.src,
          () => target.href,
          () => {
            if (!parentLink || !parentLink.href) return null;
            const h = parentLink.href;
            if (h.includes('imgres') || h.includes('mediaurl=') || h.includes('images/search')) {
              try {
                const u = new URL(h);
                return u.searchParams.get('imgurl') || u.searchParams.get('mediaurl') || u.searchParams.get('surl') || null;
              } catch (e) { return null; }
            }
            return isMediaUrl(h) ? h : null;
          },
          () => target.src,
          () => target.srcset,
          () => target.getAttribute('data-src'),
          () => target.getAttribute('data-original'),
          () => target.getAttribute('data-full-url') || target.getAttribute('data-highres') || target.getAttribute('data-large-src'),
          () => target.getAttribute('data-href'),
          () => target.getAttribute('data-url'),
          () => target.getAttribute('data-lazy-src'),
          () => target.getAttribute('data-srcset'),
          () => target.getAttribute('data-poster'),
          () => target.getAttribute('data-media'),
          () => target.getAttribute('data-video'),
          () => target.getAttribute('data-image'),
          () => target.getAttribute('data-zoom-src') || target.getAttribute('data-imgsrc'),
          () => target.getAttribute('content'),
          () => target.getAttribute('value'),
          () => target.getAttribute('title'),
          () => {
            if (target.style && target.style.backgroundImage) {
              const match = target.style.backgroundImage.match(/url\(['"]?([^'")]+)['"]?\)/);
              return match ? match[1] : null;
            }
            return null;
          },
          () => {
            if (target.style && target.style.background) {
              const match = target.style.background.match(/url\(['"]?([^'")]+)['"]?\)/);
              return match ? match[1] : null;
            }
            return null;
          }
        ];
        for (const getUrl of urlSources) {
          try {
            url = getUrl();
            if (url && url.trim()) {
              url = url.trim();
              break;
            }
          } catch (e) { console.log('URL提取失败:', e); }
        }
        if (url && url.includes(',')) {
          const srcsetParts = url.split(',');
          let bestUrl = srcsetParts[0].trim().split(' ')[0];
          let bestWidth = 0;
          for (const part of srcsetParts) {
            const trimmed = part.trim();
            const urlPart = trimmed.split(' ')[0];
            const widthMatch = trimmed.match(/(\d+)w/);
            if (widthMatch) {
              const width = parseInt(widthMatch[1]);
              if (width > bestWidth) { bestWidth = width; bestUrl = urlPart; }
            }
          }
          url = bestUrl;
        }
        if (url && !url.startsWith('http') && !url.startsWith('blob:') && !url.startsWith('data:')) {
          try { url = new URL(url, window.location.href).href; } catch (e) { console.log('URL解析失败:', e); }
        }
        if (url && (url.includes('google.com/imgres') || url.includes('bing.com/images/search') || url.includes('imgres') || url.includes('mediaurl='))) {
          try {
            const u = new URL(url);
            const imgUrl = u.searchParams.get('imgurl') || u.searchParams.get('mediaurl') || u.searchParams.get('surl') || u.searchParams.get('imgrefurl');
            if (imgUrl && isMediaUrl(imgUrl)) { url = imgUrl; }
          } catch (e) { console.log('解析图片搜索URL失败:', e); }
        }
        if (!url) {
          updateFeedbackStatus('未找到下载链接', false);
          return;
        }
        if (isApiUrl(url)) {
          updateFeedbackStatus('该链接不是媒体文件', false);
          return;
        }
        // 多重处理blob/data url
        function tryBlobOrDataUrl(url, mediaType) {
          if (isBlobUrl(url)) {
            updateFeedbackStatus('正在处理blob...', true);
            resolveBlobUrl(url, mediaType).then(resolved => {
              if (resolved) {
                window.processedMediaUrls.add(url);
                Flutter.postMessage(JSON.stringify({
                  type: 'media',
                  mediaType: resolved.mediaType || mediaType,
                  url: resolved.resolvedUrl,
                  isBase64: resolved.isBase64,
                  action: 'download'
                }));
                updateFeedbackStatus('已发送下载请求', true);
              } else {
                // blob失败，尝试canvas截图兜底
                if (target.tagName && target.tagName.toLowerCase() === 'canvas') {
                  try {
                    const dataUrl = target.toDataURL('image/png');
                    if (dataUrl && dataUrl.startsWith('data:image/')) {
                      Flutter.postMessage(JSON.stringify({
                        type: 'media',
                        mediaType: 'image',
                        url: dataUrl.split(',')[1],
                        isBase64: true,
                        action: 'download'
                      }));
                      updateFeedbackStatus('已截图保存canvas', true);
                      return;
                    }
                  } catch (err) { updateFeedbackStatus('canvas截图失败', false); }
                }
                updateFeedbackStatus('blob解析失败', false);
              }
            });
            return true;
          } else if (url.startsWith('data:image/') || url.startsWith('data:video/')) {
            // data url直接base64解码
            try {
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: url.startsWith('data:image/') ? 'image' : 'video',
                url: url.split(',')[1],
                isBase64: true,
                action: 'download'
              }));
              updateFeedbackStatus('已保存data url', true);
              return true;
            } catch (err) { updateFeedbackStatus('data url解析失败', false); }
          }
          return false;
        }
        let mediaType = 'video';
        const tagName = target.tagName ? target.tagName.toLowerCase() : '';
        const urlLower = url.toLowerCase();
        const className = target.className ? target.className.toLowerCase() : '';
        const id = target.id ? target.id.toLowerCase() : '';
        
        if (!window.processedMediaUrls.has(url)) {
          if (tryBlobOrDataUrl(url, mediaType)) {
            window.processedMediaUrls.add(url);
            e.preventDefault();
            return;
          }
          window.processedMediaUrls.add(url);
          window._lastMediaTargetForFallback = target;
          Flutter.postMessage(JSON.stringify({
            type: 'media',
            mediaType: mediaType,
            url: url,
            isBase64: false,
            action: 'download'
          }));
          updateFeedbackStatus('已发送下载请求', true);
          e.preventDefault();
        } else {
          updateFeedbackStatus('该媒体已在处理中', false);
        }
      }

      function tryCanvasCaptureFallback() {
        const target = window._lastMediaTargetForFallback;
        window._lastMediaTargetForFallback = null;
        if (!target) return;
        const tag = target.tagName ? target.tagName.toLowerCase() : '';
        let w = target.naturalWidth || target.videoWidth || target.width || target.offsetWidth;
        let h = target.naturalHeight || target.videoHeight || target.height || target.offsetHeight;
        if (w <= 0 || h <= 0) { w = target.offsetWidth || 200; h = target.offsetHeight || 200; }
        const canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        function postCanvas() {
          try {
            const dataUrl = canvas.toDataURL('image/png');
            if (dataUrl && dataUrl.startsWith('data:image/')) {
              Flutter.postMessage(JSON.stringify({ type: 'media', mediaType: 'image', url: dataUrl.split(',')[1], isBase64: true, action: 'download' }));
            }
          } catch (e) { console.log('toDataURL failed:', e); }
        }
        function postBase64(base64) {
          if (base64) Flutter.postMessage(JSON.stringify({ type: 'media', mediaType: 'image', url: base64, isBase64: true, action: 'download' }));
        }
        function tryDrawImg(src) {
          const img = new Image();
          img.crossOrigin = 'anonymous';
          img.onload = function() {
            try { ctx.drawImage(img, 0, 0, w, h); postCanvas(); } catch (e) {
              try { ctx.drawImage(target, 0, 0, w, h); postCanvas(); } catch (e2) { tryFetchFallback(src); }
            }
          };
          img.onerror = function() {
            try { ctx.drawImage(target, 0, 0, w, h); postCanvas(); } catch (e) { tryFetchFallback(src); }
          };
          img.src = src;
        }
        function tryFetchFallback(src) {
          fetch(src, { mode: 'cors', credentials: 'omit' })
            .then(r => r.blob())
            .then(blob => {
              const fr = new FileReader();
              fr.onload = () => { const b64 = fr.result.split(',')[1]; if (b64) postBase64(b64); };
              fr.readAsDataURL(blob);
            })
            .catch(() => {});
        }
        if (tag === 'img') {
          const src = target.currentSrc || target.src;
          if (src) tryDrawImg(src);
        } else if (tag === 'video') {
          try {
            ctx.drawImage(target, 0, 0, w, h);
            postCanvas();
          } catch (e) {
            console.log('video canvas fallback failed:', e);
          }
        } else if (tag === 'canvas') {
          try {
            ctx.drawImage(target, 0, 0, w, h);
            postCanvas();
          } catch (e) { console.log('canvas fallback failed:', e); }
        } else if (target.style && target.style.backgroundImage) {
          const m = target.style.backgroundImage.match(/url\(['"]?([^'")]+)['"]?\)/);
          if (m && m[1]) tryDrawImg(m[1]);
        }
      }

      // 启动动态内容监听
      const dynamicObserver = observeDynamicContent();
      
      // 初始扫描页面媒体元素
      setTimeout(() => {
        const initialMediaElements = deepScanForMediaElements();
        initialMediaElements.forEach(element => {
          window.MediaInterceptor.mediaElements.add(element);
        });
        console.log('初始扫描完成，找到', initialMediaElements.length, '个媒体元素');
      }, 1000);
    ''');
  }

  Future<void> _handleJavaScriptMessage(String message) async {
    try {
      final data = jsonDecode(message);
      if (data is! Map || !data.containsKey('type')) return;

      final dynamic urlValue = data['url'];
      final bool isBase64 = data['isBase64'] ?? false;
      final String? action = data['action'];
      final String mediaType = data['mediaType'] ??
          (_guessMimeType(urlValue is String ? urlValue : '').startsWith('image/')
              ? 'image'
              : (_guessMimeType(urlValue is String ? urlValue : '').startsWith('video/') ? 'video' : 'audio'));

      if (urlValue is! String) return;
      if (_processedUrls.contains(urlValue)) return;
      _processedUrls.add(urlValue);

      if (action != 'download') return;

      debugPrint('Received URL from JavaScript with download action: $urlValue, type: $mediaType, isBase64: $isBase64');

      if (isBase64) {
        if (_awaitingCanvasFallbackResult) _canvasFallbackSucceeded = true;
        await _handleBlobUrl(urlValue, mediaType);
        return;
      }

      final absoluteUrl = _toAbsoluteUrl(urlValue);
      final referer = _getMediaReferer(absoluteUrl);
      final resolvedUrl = await _resolveFinalUrl(
        urlValue,
        headers: {
          'Referer': referer,
          'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept': '*/*',
        },
      );
      final mimeType = _guessMimeType(resolvedUrl);
      final MediaType selectedType = _determineMediaType(mimeType);
      final success = await _performBackgroundDownload(resolvedUrl, selectedType);
        if (!success && (selectedType == MediaType.image || selectedType == MediaType.video) && mounted) {
        try {
          final ctrl = _controller;
          if (ctrl != null) {
            _awaitingCanvasFallbackResult = true;
            _canvasFallbackSucceeded = false;
            await ctrl.evaluateJavascript(source: 'typeof tryCanvasCaptureFallback === "function" && tryCanvasCaptureFallback();');
            await Future.delayed(const Duration(milliseconds: 600));
            if (!_canvasFallbackSucceeded) await _tryScreenshotFallback(ctrl);
            _awaitingCanvasFallbackResult = false;
          }
        } catch (_) {
          _awaitingCanvasFallbackResult = false;
        }
      }
    } catch (e, stackTrace) {
      debugPrint('Error handling JavaScript message: $e');
      debugPrint('Trace: $stackTrace');
    }
  }

  Future<void> _handleBlobUrl(String base64Data, String mediaType) async {
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
            action: SnackBarAction(label: '查看', onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const MediaManagerPage()))),
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
    if (processedUrl.contains('web.telegram.org')) processedUrl = 'https://web.telegram.org/a/';
    final uri = Uri.tryParse(processedUrl);
    if (uri != null) {
      _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(processedUrl)));
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无效的URL: $processedUrl')),
        );
      }
      return;
    }
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
    _controller?.clearCache();
    setState(() {
      _showHomePage = true;
      _isBrowsingWebPage = false;
      _shouldKeepWebPageState = false;
      _lastBrowsedUrl = null;
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
          _controller?.getTitle().then((title) {
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
    // 根据 iconCode 获取对应的图标
    IconData iconData = _getIconFromCode(website['iconCode']);
    
    return InkWell(
      key: ValueKey(website['url']),
      onTap: () => _loadUrl(website['url']),
      onDoubleTap: () => _showWebsiteOptionsDialog(context, website, _commonWebsites.indexWhere((site) => site['url'] == website['url'])),
      child: Card(
        elevation: 4.0,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(iconData, size: 40, color: Colors.blue),
            const SizedBox(height: 8),
            Text(website['name'], style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
  
  void _showWebsiteOptionsDialog(BuildContext pageContext, Map<String, dynamic> website, int index) {
    showModalBottomSheet(
      context: pageContext,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit, color: Colors.blue),
            title: const Text('重命名'),
            onTap: () {
              Navigator.pop(sheetContext);
              _showRenameWebsiteDialog(pageContext, website, index);
            },
          ),
          ListTile(
            leading: const Icon(Icons.link, color: Colors.green),
            title: const Text('复制网址'),
            onTap: () {
              final url = website['url']?.toString() ?? '';
              if (url.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: url));
                Navigator.pop(sheetContext);
                if (pageContext.mounted) {
                  ScaffoldMessenger.of(pageContext).showSnackBar(
                    const SnackBar(content: Text('网址已复制到剪贴板'), duration: Duration(seconds: 1)),
                  );
                }
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text('删除'),
            onTap: () async {
              // 先显示确认对话框（此时 sheet 仍打开，sheetContext 有效）
              final shouldDelete = await showDialog<bool>(
                context: sheetContext,
                builder: (ctx) => AlertDialog(
                  title: const Text('删除网站'),
                  content: Text('确定要删除 ${website['name']} 吗？'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
                  ],
                ),
              ) ?? false;
              if (!shouldDelete) return;
              // 关闭底部面板后再执行删除，使用 pageContext 确保有效
              if (!pageContext.mounted) return;
              Navigator.pop(sheetContext);
              // 使用 pageContext 显示加载框并执行删除
              showDialog(
                context: pageContext,
                barrierDismissible: false,
                builder: (_) => const AlertDialog(
                  content: Row(
                    children: [CircularProgressIndicator(), SizedBox(width: 20), Text('删除中...')],
                  ),
                ),
              );
              // 若 index 可能失效，则按 url 重新查找
              int idx = index;
              if (idx < 0 || idx >= _commonWebsites.length) {
                idx = _commonWebsites.indexWhere((s) => s['url'] == website['url']);
              }
              if (idx >= 0) {
                await _removeWebsite(idx);
              }
              if (pageContext.mounted) {
                Navigator.of(pageContext).pop();
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
      final absoluteUrl = _toAbsoluteUrl(url);
      debugPrint('开始处理下载: $absoluteUrl, MIME类型: $mimeType');
      if (_downloadingUrls.contains(absoluteUrl)) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该文件正在下载中，请稍候...')));
        return;
      }

      String processedUrl = absoluteUrl;
      if (absoluteUrl.startsWith('blob:https://web.telegram.org/')) {
        // Blob URL 由 JavaScript 处理，不直接下载
        return;
      } else if (absoluteUrl.contains('telegram.org') || absoluteUrl.contains('t.me')) {
        if (!absoluteUrl.startsWith('http')) processedUrl = absoluteUrl.startsWith('//') ? 'https:$absoluteUrl' : 'https://$absoluteUrl';
        if (processedUrl.contains('/progressive/https://')) {
          processedUrl = processedUrl.substring(processedUrl.indexOf('/progressive/https://') + '/progressive/'.length);
        }
      } else if (absoluteUrl.contains('youtube.com') || absoluteUrl.contains('youtu.be')) {
        processedUrl = await _resolveYouTubeUrl(absoluteUrl);
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
            _performBackgroundDownload(processedUrl, mediaType);
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('开始下载，将在后台进行...'), duration: Duration(seconds: 2)));
  _performBackgroundDownload(processedUrl, selectedType);
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
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final queryString = uri.query.toLowerCase();
    for (final param in downloadParams) {
      if (queryString.contains(param)) return true;
    }
    if (url.contains('youtube.com') || url.contains('youtu.be')) return true;
    return false;
  }

  String _guessMimeType(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'application/octet-stream';
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

  /// 清理媒体 URL：移除会导致 400 的图片处理参数，获取原始媒体
  /// 网页中媒体常带 CDN 处理参数用于缩略/懒加载，参数不完整时返回 400
  String _getCleanMediaUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final q = uri.query.toLowerCase();
    if (q.isEmpty) return url;
    final stripParams = [
      'x-bce-process', 'image/resize', 'image/format', 'image/quality',
      'image/crop', 'image/watermark', 'imagemogr2', 'imageview2',
    ];
    if (stripParams.any((p) => q.contains(p))) {
      return uri.replace(query: '').toString();
    }
    return url;
  }

  /// 获取完全 stripped 的 URL（仅 path，用于 400/403 重试）
  String _getStrippedMediaUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.origin + uri.path;
  }

  /// 根据 URL 和当前页面返回合适的 Referer，用于绕过反盗链
  String _getMediaReferer(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('baidu.com') || lower.contains('bdstatic.com')) return 'https://www.baidu.com';
    if (lower.contains('gstatic.com') || lower.contains('googleusercontent.com') || lower.contains('google.com')) return 'https://www.google.com';
    if (lower.contains('bing.com') || lower.contains('bcbits.com')) return 'https://www.bing.com';
    if (lower.contains('twitter.com') || lower.contains('twimg.com')) return 'https://twitter.com';
    if (lower.contains('facebook.com') || lower.contains('fbcdn.net')) return 'https://www.facebook.com';
    if (lower.contains('instagram.com') || lower.contains('cdninstagram.com')) return 'https://www.instagram.com';
    if (lower.contains('zhihu.com')) return 'https://www.zhihu.com';
    if (lower.contains('weibo.com') || lower.contains('sinaimg.cn')) return 'https://weibo.com';
    final pageUrl = _urlController.text.trim().isNotEmpty ? _urlController.text.trim() : _currentUrl;
    if (pageUrl.startsWith('http')) return pageUrl;
    return Uri.tryParse(pageUrl)?.origin ?? 'https://www.google.com';
  }

  /// 验证图片字节是否有效（检查文件头 magic numbers）
  bool _isValidImageBytes(List<int> bytes) {
    if (bytes.length < 12) return false;
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return true;
    // GIF: 47 49 46 38
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) return true;
    // WebP: 52 49 46 46 ... 57 45 42 50
    if (bytes.length >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 &&
        bytes[3] == 0x46 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) return true;
    return false;
  }

  Future<File?> _downloadFile(String url, MediaType mediaType) async {
    try {
      final absoluteUrl = _toAbsoluteUrl(url);
      final downloadUrl = _getCleanMediaUrl(absoluteUrl);
      debugPrint('开始下载文件，URL: $downloadUrl');
      final networkService = NetworkService();
      await networkService.initialize();

      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

      final uuid = const Uuid().v4();
      final uri = Uri.tryParse(absoluteUrl);
      if (uri == null) throw Exception('Invalid URL: $absoluteUrl');
      String extension = _getFileExtension(uri.path);

      if (extension.isEmpty) {
        final mimeType = _guessMimeType(absoluteUrl);
        if (mimeType.startsWith('image/')) {
          extension = mimeType == 'image/png' ? '.png' : mimeType == 'image/gif' ? '.gif' :
              mimeType == 'image/webp' ? '.webp' : '.jpg';
        } else if (mimeType.startsWith('video/') || mimeType == 'application/x-mpegURL') {
          extension = '.mp4';
        } else if (mimeType.startsWith('audio/')) {
          extension = '.mp3';
        } else {
          extension = mediaType == MediaType.image ? '.jpg' :
              mediaType == MediaType.video ? '.mp4' : mediaType == MediaType.audio ? '.mp3' : '.bin';
        }
      }

      final filePath = '${mediaDir.path}/$uuid$extension';
      debugPrint('将下载到文件路径: $filePath');

      final referer = _getMediaReferer(absoluteUrl);
      const browserUA = 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

      int retryCount = 0;
      const maxRetries = 3;
      String urlToTry = downloadUrl;

      while (retryCount < maxRetries) {
        try {
          final response = await networkService.dio.download(
            urlToTry,
            filePath,
            deleteOnError: true,
            options: Options(
              followRedirects: true,
              maxRedirects: 5,
              validateStatus: (status) => status != null && status >= 200 && status < 300,
              responseType: ResponseType.bytes,
              headers: {
                'User-Agent': browserUA,
                'Referer': referer,
                'Accept': '*/*',
              },
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
          if (extension == '.m3u8') await _handleM3u8Download(filePath, downloadUrl);
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
              if (e.response?.statusCode == 400 || e.response?.statusCode == 403) {
                final stripped = _getStrippedMediaUrl(downloadUrl);
                if (stripped != urlToTry && urlToTry == downloadUrl) {
                  debugPrint('400/403，尝试去掉全部查询参数: $stripped');
                  urlToTry = stripped;
                  retryCount--;
                }
                if (retryCount >= maxRetries) throw Exception('该资源受保护，无法直接下载，请尝试其他图片或视频');
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
          await Future.delayed(Duration(milliseconds: (retryCount * 800).clamp(800, 3000)));
        }
      }

      final file = File(filePath);
      if (!await file.exists() || await file.length() == 0) {
        await file.delete();
        return null;
      }
      if (mediaType == MediaType.image) {
        final bytes = await file.readAsBytes();
        if (!_isValidImageBytes(bytes)) {
          debugPrint('下载内容不是有效图片格式，已丢弃');
          await file.delete();
          return null;
        }
      }
      return file;
    } catch (e, stackTrace) {
      debugPrint('下载文件时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      return null;
    }
  }

  Future<void> _handleM3u8Download(String m3u8Path, String url) async {
    final networkService = NetworkService();
    await networkService.initialize();
    final response = await networkService.dio.get(url);
    final segments = response.data.toString().split('\n').where((line) => line.startsWith('http')).toList();
    if (segments.isNotEmpty) {
      final outputPath = '${m3u8Path.replaceAll('.m3u8', '.mp4')}';
      final file = File(outputPath)..createSync();
      final sink = file.openWrite();
      for (final segmentUrl in segments) {
        final segmentResponse = await networkService.dio.get(segmentUrl, options: Options(responseType: ResponseType.bytes));
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

  Future<void> _tryScreenshotFallback(InAppWebViewController ctrl) async {
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      final screenshot = await ctrl.takeScreenshot();
      if (screenshot == null || screenshot.isEmpty || !mounted) return;
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final uuid = const Uuid().v4();
      final file = File('${mediaDir.path}/$uuid.png');
      await file.writeAsBytes(screenshot);
      await _saveToMediaLibrary(file, MediaType.image);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('已通过截屏保存到媒体库'),
            duration: const Duration(seconds: 3),
            action: SnackBarAction(label: '查看', onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const MediaManagerPage()))),
          ),
        );
      }
    } catch (e) {
      debugPrint('截屏兜底失败: $e');
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
      final c = _controller;
      if (c != null) c.getTitle().then((title) {
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
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.content_copy, color: Colors.blue),
                  title: const Text('复制当前网址'),
                  onTap: () {
                    final url = _urlController.text.trim().isNotEmpty
                        ? _urlController.text.trim()
                        : _currentUrl;
                    if (url.isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: url));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('当前网址已复制到剪贴板'), duration: Duration(seconds: 1)),
                        );
                      }
                    }
                  },
                ),
                const Divider(height: 1),
                Expanded(
                  child: ReorderableListView(
              onReorder: (oldIndex, newIndex) async {
                if (oldIndex < newIndex) newIndex -= 1;
                final item = _bookmarks.removeAt(oldIndex);
                _bookmarks.insert(newIndex, item);
                modalSetState(() {});
                await _saveBookmarks();
              },
              children: [
                for (int index = 0; index < _bookmarks.length; index++)
                  ListTile(
                    key: ValueKey('bookmark_$index'),
                    title: Text(_bookmarks[index]['name'] ?? _bookmarks[index]['url']!),
                    onTap: () {
                      _loadUrl(_bookmarks[index]['url']!);
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
                                content: Text('确定要删除书签 "${_bookmarks[index]['name']}" 吗？'),
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
                              await _saveBookmarks();
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.content_copy, color: Colors.green),
                          onPressed: () {
                            final url = _bookmarks[index]['url']?.toString() ?? '';
                            if (url.isNotEmpty) {
                              Clipboard.setData(ClipboardData(text: url));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('书签网址已复制到剪贴板'), duration: Duration(seconds: 1)),
                                );
                              }
                            }
                          },
                          tooltip: '复制网址',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
                ),
              ],
            ),
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

  // 2. 加载历史记录
  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final historyString = prefs.getString('browser_history');
    if (historyString != null) {
      _history = List<Map<String, dynamic>>.from(json.decode(historyString));
    }
  }

  // 3. 保存历史记录
  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('browser_history', json.encode(_history));
  }

  // 4. 添加历史记录（在网页加载成功时调用）
  Future<void> _addHistory(String title, String url) async {
    if (url.isEmpty) return;
    // 去重：如果已存在则先移除
    _history.removeWhere((item) => item['url'] == url);
    _history.insert(0, {
      'title': title,
      'url': url,
      'datetime': DateTime.now().toIso8601String(),
    });
    // 限制最大条数
    if (_history.length > 200) _history = _history.sublist(0, 200);
    await _saveHistory();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[_BrowserPage.build] _showHomePage: $_showHomePage, _isBrowsingWebPage: $_isBrowsingWebPage, _shouldKeepWebPageState: $_shouldKeepWebPageState');
    super.build(context);
    return WillPopScope(
      onWillPop: () async {
        if (!_showHomePage && _controller != null) {
          if (await _controller!.canGoBack()) {
            _controller!.goBack();
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
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const MediaManagerPage()),
                  );
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
            if (_showHomePage) ...[
              IconButton(
                icon: const Icon(Icons.import_export),
                onPressed: _showExportImportMenu,
                tooltip: '导入/导出数据',
              ),
              IconButton(
                icon: const Icon(Icons.telegram),
                onPressed: _showTelegramDownloadDialog,
                tooltip: 'Telegram 下载',
              ),
            ],
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red),
                onPressed: _exitWebPage,
                tooltip: '退出网页',
              ),
            IconButton(
              icon: const Icon(Icons.history),
              onPressed: _showHistory,
              tooltip: '历史记录',
            ),
          ],
        ),
        body: Stack(
          children: [
            Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back),
                              onPressed: () async {
                                if (_controller != null && await _controller!.canGoBack()) _controller!.goBack();
                              },
                              tooltip: '后退',
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_forward),
                              onPressed: () async {
                                if (_controller != null && await _controller!.canGoForward()) _controller!.goForward();
                              },
                              tooltip: '前进',
                            ),
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              onPressed: () => _controller?.reload(),
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
                            InAppWebView(
                              initialUrlRequest: URLRequest(url: WebUri('about:blank')),
                              initialSettings: InAppWebViewSettings(
                                javaScriptEnabled: true,
                                useHybridComposition: true,
                                useOnLoadResource: true,
                                allowFileAccess: true,
                                domStorageEnabled: true,
                                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                                userAgent: 'Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                              ),
                              initialUserScripts: UnmodifiableListView([]),
                              onWebViewCreated: (ctrl) => _setupWebViewController(ctrl),
                              shouldAllowDeprecatedTLS: (ctrl, challenge) async {
                                return ShouldAllowDeprecatedTLSAction.ALLOW;
                              },
                              // 注意：PROCEED 会跳过证书校验，存在中间人攻击风险。
                              // 若需更高安全性，可改为 DENY 或实现白名单校验。
                              onReceivedServerTrustAuthRequest: (ctrl, challenge) async {
                                return ServerTrustAuthResponse(
                                  action: ServerTrustAuthResponseAction.PROCEED,
                                );
                              },
                              onLoadStart: (ctrl, url) {
                                setState(() {
                                  _isLoading = true;
                                  if (url != null) {
                                    final urlStr = url.toString();
                                    _currentUrl = urlStr;
                                    _urlController.text = _currentUrl;
                                    // 仅当加载真实网页时切换到 WebView，about:blank 不切换（保持主界面）
                                    if (urlStr.startsWith('http://') || urlStr.startsWith('https://')) {
                                      _showHomePage = false;
                                      widget.onBrowserHomePageChanged?.call(false);
                                    }
                                  }
                                });
                              },
                              onProgressChanged: (ctrl, progress) {
                                setState(() {
                                  _loadingProgress = progress / 100;
                                  _isLoading = _loadingProgress < 1.0;
                                });
                              },
                              onLoadStop: (ctrl, url) {
                                if (url != null) _onPageFinished(url.toString());
                              },
                              onReceivedError: (ctrl, req, err) => debugPrint('WebView错误: ${err?.description}'),
                              shouldOverrideUrlLoading: (ctrl, nav) async {
                                final url = nav.request.url?.toString() ?? '';
                                debugPrint('导航请求: $url');
                                if (_isDownloadableLink(url) || _isTelegramMediaLink(url) || _isYouTubeLink(url)) {
                                  debugPrint('检测到可能的下载链接: $url');
                                  _handleDownload(url, '', _guessMimeType(url));
                                  return NavigationActionPolicy.CANCEL;
                                }
                                if (!url.startsWith('http://') && !url.startsWith('https://')) {
                                  debugPrint('检测到自定义URL协议: $url');
                                  _launchExternalApp(url);
                                  return NavigationActionPolicy.CANCEL;
                                }
                                return NavigationActionPolicy.ALLOW;
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
            if (_showHomePage)
              Positioned.fill(
                child: Container(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: _buildHomePage(),
                ),
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
    // Fire-and-forget saves to avoid awaiting in dispose
    Future.microtask(() async {
      try {
        await _saveBookmarks();
        debugPrint('书签保存完成');
      } catch (e) {
        debugPrint('保存书签时出错: $e');
      }
      try {
        await _saveCommonWebsites();
        debugPrint('常用网站保存完成');
      } catch (e) {
        debugPrint('保存常用网站时出错: $e');
      }
    });
    widget.onBrowserHomePageChanged?.call(true);
    super.dispose();
  }

  Future<bool> _performBackgroundDownload(String url, MediaType mediaType) async {
    final absoluteUrl = _toAbsoluteUrl(url);
    if (_isApiEndpointUrl(absoluteUrl)) {
      debugPrint('跳过 API 接口 URL（非媒体文件）: $absoluteUrl');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('该链接不是媒体文件，请长按图片或视频本身进行下载'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return false;
    }
    _downloadingUrls.add(absoluteUrl);
    try {
      debugPrint('开始后台下载: $absoluteUrl, 媒体类型: $mediaType');
      
      if (mediaType == MediaType.video) {
        _isDownloadingVideo.value = true;
        _videoDownloadProgress.value = 0.0;
      }

      final file = await _downloadFile(absoluteUrl, mediaType);

      if (file != null) {
        debugPrint('文件下载成功: ${file.path}');
        await _saveToMediaLibrary(file, mediaType);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${mediaType == MediaType.video ? "视频" : mediaType == MediaType.image ? "图片" : "音频"}已成功保存到媒体库: ${file.path.split('/').last}'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(label: '查看', onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const MediaManagerPage()))),
            ),
          );
        }
        return true;
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('下载失败，正在尝试截图保存...'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return false;
      }
    } catch (e) {
      debugPrint('后台下载出错: $absoluteUrl, 错误: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('下载失败，正在尝试截图保存...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return false;
    } finally {
      _downloadingUrls.remove(absoluteUrl);
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
        
        // 显示成功或失败通知
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.success ? '下载成功：${result.fileName}' : '下载失败：${result.error}'),
            backgroundColor: result.success ? Colors.green : Colors.red,
            action: result.success ? SnackBarAction(
              label: '查看',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const MediaManagerPage()),
                );
              },
            ) : null,
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
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const MediaManagerPage()),
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

  /// 显示导入导出菜单
  void _showExportImportMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('导出浏览器数据'),
              subtitle: const Text('导出书签和常用网站'),
              onTap: () {
                Navigator.pop(context);
                _exportBrowserData();
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('导入浏览器数据'),
              subtitle: const Text('导入书签和常用网站'),
              onTap: () {
                Navigator.pop(context);
                _importBrowserData();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 导出浏览器数据
  Future<void> _exportBrowserData() async {
    String currentPhase = '准备';
    try {
      // 创建进度通知器
      final ValueNotifier<String> progressNotifier = ValueNotifier<String>('准备导出浏览器数据...');
      
      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: ValueListenableBuilder<String>(
            valueListenable: progressNotifier,
            builder: (context, progress, child) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(
                    progress,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              );
            },
          ),
        ),
      );

      // 获取导出目录
      final Directory? externalDir = await getExternalStorageDirectory();
      if (externalDir == null) {
        throw Exception('无法访问外部存储目录');
      }

      final String exportDir = '${externalDir.path}/browser_backups';
      final Directory backupDir = Directory(exportDir);
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      currentPhase = '收集数据';
      progressNotifier.value = '收集浏览器数据...';

      // 收集浏览器数据
      final Map<String, dynamic> browserData = {
        'bookmarks': _bookmarks,
        'common_websites': _commonWebsites,
        'export_time': DateTime.now().toIso8601String(),
        'version': '1.0',
      };

      currentPhase = '创建数据文件';
      progressNotifier.value = '创建数据文件...';

      // 创建JSON文件
      final String jsonPath = '$exportDir/browser_data.json';
      final File jsonFile = File(jsonPath);
      await jsonFile.writeAsString(jsonEncode(browserData));

      currentPhase = '创建ZIP文件';
      progressNotifier.value = '创建ZIP文件...';

      // 创建ZIP文件
      final String zipPath = '$exportDir/browser_backup_${DateTime.now().millisecondsSinceEpoch}.zip';
      final Archive archive = Archive();
      final bytes = await jsonFile.readAsBytes();
      archive.addFile(ArchiveFile('browser_data.json', bytes.length, bytes));
      final List<int>? zipData = await compute(encodeArchive, archive);

      if (zipData == null) {
        throw Exception('创建ZIP文件失败');
      }

      final File zipFile = File(zipPath);
      await zipFile.writeAsBytes(zipData);

      // 删除临时JSON文件
      await jsonFile.delete();

      progressNotifier.value = '导出完成！';

      // 关闭进度对话框
      if (mounted) {
        Navigator.pop(context);
      }

      // 分享文件
      await Share.shareXFiles(
        [XFile(zipPath)],
        subject: '浏览器数据备份',
        text: '浏览器数据备份文件，包含书签和常用网站数据。',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('浏览器数据导出成功！文件已保存到: ${zipPath.split('/').last}'),
            action: SnackBarAction(
              label: '打开文件',
              onPressed: () async {
                // 打开文件管理器到导出目录
                final result = await FilePicker.platform.clearTemporaryFiles();
                debugPrint('清理临时文件结果: $result');
              },
            ),
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('导出浏览器数据时出错 [$currentPhase]: $e\n$stack');
      if (mounted) {
        Navigator.pop(context); // 关闭进度对话框
        final userMsg = formatExportImportError(e, '导出失败');
        showExportImportErrorDialog(context, '浏览器数据导出失败', '出错阶段：$currentPhase\n\n$userMsg');
      }
    }
  }

  /// 导入浏览器数据
  Future<void> _importBrowserData() async {
    String currentPhase = '准备';
    try {
      // 显示警告对话框
      bool? confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('警告'),
          content: const Text('导入浏览器数据将会覆盖当前的书签和常用网站，确定要继续吗？'),
          actions: [
            TextButton(
              child: const Text('取消'),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: const Text('确定'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      // 选择ZIP文件
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (result != null && result.files.single.path != null) {
        // 创建进度通知器
        final ValueNotifier<String> progressNotifier = ValueNotifier<String>('准备导入...');
        
        // 显示进度对话框
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            content: ValueListenableBuilder<String>(
              valueListenable: progressNotifier,
              builder: (context, progress, child) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(
                      progress,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                );
              },
            ),
          ),
        );

        currentPhase = '解压文件';
        progressNotifier.value = '解压文件...';

        // 读取ZIP文件
        final File zipFile = File(result.files.single.path!);
        final List<int> zipBytes = await zipFile.readAsBytes();
        final Archive? archive = ZipDecoder().decodeBytes(zipBytes);

        if (archive == null) {
          throw Exception('无法解析ZIP文件');
        }

        currentPhase = '解析数据';
        progressNotifier.value = '解析数据...';

        // 查找并解析JSON文件
        ArchiveFile? jsonFile;
        for (final file in archive) {
          if (file.name == 'browser_data.json') {
            jsonFile = file;
            break;
          }
        }

        if (jsonFile == null) {
          throw Exception('ZIP文件中未找到浏览器数据文件');
        }

        // 解析JSON数据
        final String jsonContent = utf8.decode(jsonFile.content as List<int>);
        final Map<String, dynamic> browserData = jsonDecode(jsonContent);

        currentPhase = '导入数据';
        progressNotifier.value = '导入数据...';

        // 验证数据格式
        if (browserData['version'] == null) {
          throw Exception('数据格式不支持，缺少版本信息');
        }

        // 导入书签
        if (browserData['bookmarks'] != null) {
          final List<dynamic> bookmarksData = browserData['bookmarks'];
          setState(() {
            _bookmarks = bookmarksData.map((item) => Map<String, String>.from(item)).toList();
          });
          await _saveBookmarks();
        }

        // 导入常用网站
        if (browserData['common_websites'] != null) {
          final List<dynamic> websitesData = browserData['common_websites'];
          setState(() {
            _commonWebsites.clear();
            for (final item in websitesData) {
              final Map<String, dynamic> website = Map<String, dynamic>.from(item);
              // 只保存 iconCode，不动态创建 IconData 实例
              if (website['iconCode'] == null) {
                website['iconCode'] = Icons.public.codePoint;
              }
              _commonWebsites.add(website);
            }
          });
          await _saveCommonWebsites();
        }

        progressNotifier.value = '导入完成！';

        // 关闭进度对话框
        if (mounted) {
          Navigator.pop(context);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('浏览器数据导入成功！'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e, stack) {
      debugPrint('导入浏览器数据时出错 [$currentPhase]: $e\n$stack');
      if (mounted) {
        Navigator.pop(context); // 关闭进度对话框
        final userMsg = formatExportImportError(e, '导入失败');
        showExportImportErrorDialog(context, '浏览器数据导入失败', '出错阶段：$currentPhase\n\n$userMsg');
      }
    }
  }

  /// 将长 URL 缩短为简洁显示（域名 + 路径摘要，单行友好）
  String _shortenUrlForDisplay(String url) {
    if (url.isEmpty) return '';
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return url.length > 45 ? '${url.substring(0, 42)}...' : url;
      final host = uri.host.isNotEmpty ? uri.host : url;
      final path = uri.path;
      if (path.isEmpty || path == '/') return host;
      // 路径过长时只保留前一段
      final pathDisplay = path.length > 25 ? '${path.substring(0, 22)}...' : path;
      return '$host$pathDisplay';
    } catch (_) {
      return url.length > 45 ? '${url.substring(0, 42)}...' : url;
    }
  }

  // 8. 历史记录弹窗
  void _showHistory() {
    showModalBottomSheet(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.delete_forever),
                title: const Text('清空全部历史记录'),
                onTap: () async {
                  Navigator.pop(context);
                  _history.clear();
                  await _saveHistory();
                  setState(() {});
                },
              ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final item = _history[index];
                    final title = item['title'] as String?;
                    final url = item['url'] as String? ?? '';
                    final timeStr = (item['datetime'] as String?)?.substring(0, 19).replaceAll('T', ' ') ?? '';
                    // 优先用标题，若标题过长或与 URL 相同则用缩短的 URL
                    final displayText = (title != null && title != url && title.length <= 50)
                        ? title
                        : _shortenUrlForDisplay(url);
                    return SizedBox(
                      height: 32,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(context);
                            _loadUrl(url);
                          },
                          onLongPress: () async {
                            _history.removeAt(index);
                            await _saveHistory();
                            setState(() {});
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    displayText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  timeStr,
                                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 根据 iconCode 获取对应的图标（使用常量映射避免动态创建）
  IconData _getIconFromCode(int? iconCode) {
    if (iconCode == null) return Icons.public;
    
    // 使用常量图标映射，避免动态创建 IconData
    switch (iconCode) {
      case 0xe3c3: return Icons.public; // public
      case 0xe3c4: return Icons.public_off; // public_off
      case 0xe3c5: return Icons.publish; // publish
      case 0xe3c6: return Icons.query_builder; // query_builder
      case 0xe3c7: return Icons.question_answer; // question_answer
      case 0xe3c8: return Icons.queue; // queue
      case 0xe3c9: return Icons.queue_music; // queue_music
      case 0xe3ca: return Icons.queue_play_next; // queue_play_next
      case 0xe3cb: return Icons.radio; // radio
      case 0xe3cc: return Icons.radio_button_checked; // radio_button_checked
      case 0xe3cd: return Icons.radio_button_unchecked; // radio_button_unchecked
      case 0xe3ce: return Icons.rate_review; // rate_review
      case 0xe3cf: return Icons.receipt; // receipt
      case 0xe3d0: return Icons.recent_actors; // recent_actors
      case 0xe3d1: return Icons.record_voice_over; // record_voice_over
      case 0xe3d2: return Icons.redeem; // redeem
      case 0xe3d3: return Icons.redo; // redo
      case 0xe3d4: return Icons.refresh; // refresh
      case 0xe3d5: return Icons.remove; // remove
      case 0xe3d6: return Icons.remove_circle; // remove_circle
      case 0xe3d7: return Icons.remove_circle_outline; // remove_circle_outline
      case 0xe3d8: return Icons.remove_from_queue; // remove_from_queue
      case 0xe3d9: return Icons.visibility; // visibility
      case 0xe3da: return Icons.visibility_off; // visibility_off
      case 0xe3db: return Icons.voice_chat; // voice_chat
      case 0xe3dc: return Icons.voicemail; // voicemail
      case 0xe3dd: return Icons.volume_down; // volume_down
      case 0xe3de: return Icons.volume_mute; // volume_mute
      case 0xe3df: return Icons.volume_off; // volume_off
      case 0xe3e0: return Icons.volume_up; // volume_up
      case 0xe3e1: return Icons.vpn_key; // vpn_key
      case 0xe3e2: return Icons.vpn_lock; // vpn_lock
      case 0xe3e3: return Icons.wallpaper; // wallpaper
      case 0xe3e4: return Icons.warning; // warning
      case 0xe3e5: return Icons.watch; // watch
      case 0xe3e6: return Icons.watch_later; // watch_later
      case 0xe3e7: return Icons.wb_auto; // wb_auto
      case 0xe3e8: return Icons.wb_incandescent; // wb_incandescent
      case 0xe3e9: return Icons.wb_iridescent; // wb_iridescent
      case 0xe3ea: return Icons.wb_sunny; // wb_sunny
      case 0xe3eb: return Icons.wc; // wc
      case 0xe3ec: return Icons.web; // web
      case 0xe3ed: return Icons.web_asset; // web_asset
      case 0xe3ee: return Icons.weekend; // weekend
      case 0xe3ef: return Icons.whatshot; // whatshot
      case 0xe3f0: return Icons.widgets; // widgets
      case 0xe3f1: return Icons.wifi; // wifi
      case 0xe3f2: return Icons.wifi_lock; // wifi_lock
      case 0xe3f3: return Icons.wifi_tethering; // wifi_tethering
      case 0xe3f4: return Icons.work; // work
      case 0xe3f5: return Icons.wrap_text; // wrap_text
      case 0xe3f6: return Icons.youtube_searched_for; // youtube_searched_for
      case 0xe3f7: return Icons.zoom_in; // zoom_in
      case 0xe3f8: return Icons.zoom_out; // zoom_out
      case 0xe3f9: return Icons.zoom_out_map; // zoom_out_map
      default: return Icons.public; // 默认图标
    }
  }

  // 页面加载完成后的处理
  void _onPageFinished(String url) async {
    try {
      // 注入媒体下载处理程序
      _injectDownloadHandlers();
      
      // 添加历史记录
      final ctrl = _controller;
      String title = ctrl != null ? (await ctrl.getTitle() ?? url) : url;
      await _addHistory(title, url);
      
      // 更新状态
      setState(() {
        _isLoading = false;
        _currentUrl = url;
        _urlController.text = url;
        _showHomePage = false;
      });
      
      // 通知父组件浏览器状态变化
      widget.onBrowserHomePageChanged?.call(_showHomePage);
      
      debugPrint('页面加载完成: $url, 标题: $title');
    } catch (e) {
      debugPrint('页面加载完成处理时出错: $e');
    }
  }
}

