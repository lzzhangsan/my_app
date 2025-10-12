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
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';

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
  String _currentUserAgent =
      'Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.162 Mobile Safari/537.36';
  late final DatabaseService _databaseService;
  List<Map<String, String>> _bookmarks = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TelegramDownloadServiceV2 _telegramService = TelegramDownloadServiceV2.instance;
  
  // 娣诲姞杞鐩稿叧鍙橀噺
  Timer? _telegramPollingTimer;
  int _lastUpdateId = 0;
  bool _isPollingActive = false;
  
  // 娣诲姞宸蹭笅杞芥枃浠禝D闆嗗悎
  final Set<String> _downloadedFileIds = <String>{};
  static const String _downloadedFileIdsKey = 'telegram_downloaded_file_ids';

  bool _showHomePage = true;
  bool _isBrowsingWebPage = false;

  // 娣诲姞瑙嗛涓嬭浇杩涘害鍜岀姸鎬佺殑ValueNotifier
  ValueNotifier<double?> _videoDownloadProgress = ValueNotifier(null);
  ValueNotifier<bool> _isDownloadingVideo = ValueNotifier(false);

  // 1. 鏂板鍘嗗彶璁板綍鍙橀噺
  List<Map<String, dynamic>> _history = [];

  Future<void> _launchExternalApp(String url) async {
    debugPrint('灏濊瘯鍚姩澶栭儴搴旂敤: $url');
    try {
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        debugPrint('鎴愬姛鍚姩澶栭儴搴旂敤');
      } else {
        debugPrint('鏃犳硶鍚姩澶栭儴搴旂敤: $url');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('鏃犳硶鎵撳紑: $url')),
        );
      }
    } catch (e) {
      debugPrint('鍚姩澶栭儴搴旂敤鏃跺嚭閿? $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('鎵撳紑閾炬帴鏃跺嚭閿? $e')),
      );
    }
  }
  bool _shouldKeepWebPageState = false;
  String? _lastBrowsedUrl;

  final List<Map<String, dynamic>> _commonWebsites = [
    {'name': 'Google', 'url': 'https://www.google.com', 'icon': Icons.search},
    {'name': 'Telegram', 'url': 'https://web.telegram.org', 'icon': Icons.send},
    {'name': '鐧惧害', 'url': 'https://www.baidu.com', 'icon': Icons.search},
  ];

  // 绉婚櫎缂栬緫妯″紡鐘舵€佸彉閲?  // bool _isEditMode = false;

  // 淇濈暀姝ゆ柟娉曚絾绠€鍖栧姛鑳斤紝鍥犱负鎴戜滑宸茬Щ闄ょ紪杈戞ā寮?  Future<void> _saveWebsites() async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('姝ｅ湪淇濆瓨甯哥敤缃戠珯...')));
    await _saveCommonWebsites();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('甯哥敤缃戠珯宸蹭繚瀛?)));
  }

  Future<void> _removeWebsite(int index) async {
    final removedSite = _commonWebsites[index]['name'];
    setState(() => _commonWebsites.removeAt(index));
    await _saveCommonWebsites();
    debugPrint('宸插垹闄ゅ苟淇濆瓨缃戠珯: $removedSite');
  }

  Future<void> _reorderWebsites(int oldIndex, int newIndex) async {
    // 濡傛灉鏄坊鍔犵綉绔欐寜閽紝涓嶅厑璁告嫋鍔?    if (oldIndex >= _commonWebsites.length || newIndex > _commonWebsites.length) {
      return;
    }
    
    // 璋冩暣newIndex锛屽洜涓篟eorderableGridView鐨刵ewIndex璁＄畻鏂瑰紡涓嶳eorderableListView涓嶅悓
    if (newIndex > _commonWebsites.length) newIndex = _commonWebsites.length;
    
    setState(() {
      if (oldIndex < newIndex) newIndex -= 1;
      final item = _commonWebsites.removeAt(oldIndex);
      _commonWebsites.insert(newIndex, item);
    });
    await _saveCommonWebsites();
    debugPrint('宸茬Щ鍔ㄥ苟淇濆瓨缃戠珯浠庝綅缃?$oldIndex 鍒?$newIndex');
  }

  Future<void> _addWebsite(String name, String url, IconData icon) async {
    setState(() => _commonWebsites.add({'name': name, 'url': url, 'iconCode': icon.codePoint}));
    await _saveCommonWebsites();
    debugPrint('宸叉坊鍔犲苟绔嬪嵆淇濆瓨缃戠珯: $name');
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
    _loadHistory();
  }
  
  /// 鍒濆鍖?Telegram 鏈嶅姟
  Future<void> _initializeTelegramService() async {
    await _telegramService.initialize();
    
    // 鍔犺浇宸蹭笅杞界殑鏂囦欢ID鍜屾渶鍚庢洿鏂癐D
    await _loadDownloadedFileIds();
    await _loadLastUpdateId();
    
    // 濡傛灉宸查厤缃瓸ot Token锛屽惎鍔ㄨ疆璇?    if (_telegramService.isConfigured) {
      await _startTelegramPolling();
    }
  }

  Future<void> _initializeDownloader() async {
    await FlutterDownloader.initialize();
    await _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    var storageStatus = await Permission.storage.request();
    debugPrint('瀛樺偍鏉冮檺鐘舵€? $storageStatus');
    if (Platform.isAndroid) {
      var manageStorageStatus = await Permission.manageExternalStorage.request();
      debugPrint('绠＄悊澶栭儴瀛樺偍鏉冮檺鐘舵€? $manageStorageStatus');
    }
    var recordStatus = await Permission.microphone.request();
    debugPrint('褰曢煶鏉冮檺鐘舵€? $recordStatus');
  }

  void _initializeWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_currentUserAgent)
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
          onPageFinished: _onPageFinished,
          onWebResourceError: (error) => debugPrint('WebView閿欒: ${error.description}'),
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            debugPrint('瀵艰埅璇锋眰: $url');
            if (_isDownloadableLink(url) || _isTelegramMediaLink(url) || _isYouTubeLink(url)) {
              debugPrint('妫€娴嬪埌鍙兘鐨勪笅杞介摼鎺? $url');
              _handleDownload(url, '', _guessMimeType(url));
              return NavigationDecision.prevent;
            }
            // 澶勭悊鑷畾涔塙RL鍗忚
            if (!url.startsWith('http://') && !url.startsWith('https://')) {
              debugPrint('妫€娴嬪埌鑷畾涔塙RL鍗忚: $url');
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
          debugPrint('鏉ヨ嚜JavaScript鐨勬秷鎭? ${message.message}');
          _handleJavaScriptMessage(message.message);
        },
      );
  }

  void _setUserAgent(String ua) {
    _currentUserAgent = ua;
    _controller.setUserAgent(ua);
  }

  bool _isTelegramMediaLink(String url) {
    // 鎺掗櫎blob閾炬帴锛岃鍏剁敱JavaScript澶勭悊
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
    debugPrint('涓烘墍鏈夌綉绔欐敞鍏ヨ秴寮哄獟浣撲笅杞藉鐞嗙▼搴?- 95%鎴愬姛鐜囩増鏈?);
    _controller.runJavaScript('''
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

      // 澧炲己鐨凚lob URL妫€娴?      function isBlobUrl(url) {
        return url && typeof url === 'string' && url.startsWith('blob:');
      }

      // 澧炲己鐨勫獟浣揢RL妫€娴?- 鏀寔鏇村鏍煎紡鍜屾ā寮?      function isMediaUrl(url) {
        if (!url) return false;
        
        // 鎵╁睍鐨勫獟浣撴枃浠舵墿灞曞悕
        const mediaExtensions = [
          // 鍥剧墖鏍煎紡
          '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg', '.ico', '.tiff', '.tif', '.heic', '.heif',
          // 瑙嗛鏍煎紡
          '.mp4', '.webm', '.mov', '.avi', '.mkv', '.flv', '.wmv', '.m3u8', '.ts', '.m4v', '.3gp', '.ogv',
          // 闊抽鏍煎紡
          '.mp3', '.wav', '.ogg', '.m4a', '.aac', '.flac', '.wma', '.opus'
        ];
        
        const lowerUrl = url.toLowerCase();
        
        // 妫€鏌ユ枃浠舵墿灞曞悕
        if (mediaExtensions.some(ext => lowerUrl.includes(ext))) return true;
        
        // 妫€鏌RL妯″紡
        const mediaPatterns = [
          'image', 'video', 'audio', 'media', 'photo', 'picture', 'thumbnail', 'preview',
          'cdn', 'static', 'assets', 'uploads', 'files', 'content', 'stream', 'play',
          'youtube.com', 'youtu.be', 'vimeo.com', 'dailymotion.com', 'bilibili.com',
          'instagram.com', 'facebook.com', 'twitter.com', 'tiktok.com'
        ];
        
        if (mediaPatterns.some(pattern => lowerUrl.includes(pattern))) return true;
        
        // 妫€鏌ユ煡璇㈠弬鏁?        const mediaParams = ['image', 'video', 'audio', 'media', 'file', 'download'];
        const urlParams = new URLSearchParams(url.split('?')[1] || '');
        for (const param of mediaParams) {
          if (urlParams.has(param)) return true;
        }
        
        return false;
      }

      // 澧炲己鐨凚lob URL瑙ｆ瀽
      async function resolveBlobUrl(blobUrl, mediaType) {
        try {
          console.log('姝ｅ湪瑙ｆ瀽Blob URL:', blobUrl);
          
          // 灏濊瘯澶氱鏂规硶鑾峰彇blob鍐呭
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
            console.log('Fetch澶辫触锛屽皾璇昘MLHttpRequest:', fetchError);
            // 澶囩敤鏂规硶锛氫娇鐢╔MLHttpRequest
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

      // 娣卞害鎵弿DOM鏍戞煡鎵惧獟浣撳厓绱?      function deepScanForMediaElements(root = document) {
        const mediaElements = [];
        
        // 閫掑綊鎵弿鍑芥暟
        function scanNode(node) {
          if (!node) return;
          
          // 妫€鏌hadow DOM
          if (node.shadowRoot) {
            scanNode(node.shadowRoot);
          }
          
          // 妫€鏌frame鍐呭
          if (node.tagName === 'IFRAME' && node.contentDocument) {
            try {
              scanNode(node.contentDocument);
            } catch (e) {
              console.log('鏃犳硶璁块棶iframe鍐呭:', e);
            }
          }
          
          // 妫€鏌ュ綋鍓嶈妭鐐?          const tagName = node.tagName ? node.tagName.toLowerCase() : '';
          const nodeName = node.nodeName ? node.nodeName.toLowerCase() : '';
          
          // 濯掍綋鍏冪礌妫€娴?          if (['img', 'video', 'audio', 'source', 'picture'].includes(tagName)) {
            mediaElements.push(node);
          }
          
          // 閾炬帴鍏冪礌妫€娴?          if (tagName === 'a' && node.href && isMediaUrl(node.href)) {
            mediaElements.push(node);
          }
          
          // 鑳屾櫙鍥剧墖妫€娴嬶紙computed style锛?          try {
            const style = window.getComputedStyle(node);
            const bgImage = style && style.backgroundImage;
            if (bgImage && bgImage !== 'none' && bgImage.includes('url(')) {
              const urlMatch = bgImage.match(/url\(['"]?([^'"\)]+)['"]?\)/);
              if (urlMatch && isMediaUrl(urlMatch[1])) {
                mediaElements.push({ tagName: 'div', href: urlMatch[1] });
              }
            }
          } catch (_) {}
          
          // 閫掑綊鎵弿瀛愯妭鐐?          if (node.childNodes) {
            for (const child of node.childNodes) {
              scanNode(child);
            }
          }
        }
        
        scanNode(root);
        return mediaElements;
      }

      // 鐩戝惉鍔ㄦ€佸唴瀹瑰彉鍖?      function observeDynamicContent() {
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

      // 鍙栨秷鍏ㄥ眬XHR鎷︽埅锛岄伩鍏嶈鍒ゅ拰鎬ц兘闂

      // 鍙栨秷鍏ㄥ眬Fetch鎷︽埅锛岄伩鍏嶈鍒ゅ拰鎬ц兘闂

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
        feedbackElement.innerText = '姝ｅ湪妫€娴嬪獟浣?..';
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

      // 澧炲己鐨勯暱鎸夋娴?- 鏀寔鏇村濯掍綋鍏冪礌绫诲瀷
      document.addEventListener('touchstart', function(e) {
        // 瓒呭叏闈㈢殑濯掍綋鍏冪礌閫夋嫨鍣?- 95%鎴愬姛鐜?        const mediaSelectors = [
          // 鐩存帴濯掍綋鍏冪礌
          'img[src]', 'video[src]', 'audio[src]', 'source[src]', 'picture source[srcset]',
          
          // 閾炬帴鍏冪礌 - 鎵╁睍妯″紡鍖归厤
          'a[href*="progressive/document"]', 'a[href*="media"]', 'a[href*="video"]', 
          'a[href*="image"]', 'a[href*="photo"]', 'a[href*="picture"]', 'a[href*="download"]',
          'a[href*=".jpg"]', 'a[href*=".jpeg"]', 'a[href*=".png"]', 'a[href*=".gif"]', 
          'a[href*=".webp"]', 'a[href*=".bmp"]', 'a[href*=".svg"]', 'a[href*=".ico"]',
          'a[href*=".mp4"]', 'a[href*=".webm"]', 'a[href*=".mov"]', 'a[href*=".avi"]', 
          'a[href*=".mkv"]', 'a[href*=".flv"]', 'a[href*=".wmv"]', 'a[href*=".m3u8"]',
          'a[href*=".mp3"]', 'a[href*=".wav"]', 'a[href*=".ogg"]', 'a[href*=".m4a"]',
          'a[href*=".aac"]', 'a[href*=".flac"]', 'a[href*=".wma"]', 'a[href*=".opus"]',
          
          // 绫诲悕鍖归厤
          '[class*="download"]', '[class*="media"]', '[class*="video"]', '[class*="image"]', 
          '[class*="photo"]', '[class*="picture"]', '[class*="thumbnail"]', '[class*="preview"]',
          '[class*="player"]', '[class*="stream"]', '[class*="content"]', '[class*="asset"]',
          
          // ID鍖归厤
          '[id*="download"]', '[id*="media"]', '[id*="video"]', '[id*="image"]', 
          '[id*="photo"]', '[id*="picture"]', '[id*="player"]', '[id*="stream"]',
          
          // 鏁版嵁灞炴€у尮閰?          '[data-src]', '[data-href]', '[data-url]', '[data-media]', '[data-video]', '[data-image]',
          '[data-original]', '[data-lazy-src]', '[data-srcset]', '[data-poster]',
          
          // 瑙掕壊鍜屾爣绛惧尮閰?          'div[role="menuitem"][aria-label*="download"]', 'div[role="button"][aria-label*="download"]',
          'button[aria-label*="download"]', 'button[aria-label*="media"]', 'button[aria-label*="video"]',
          
          // 鐗规畩缃戠珯閫傞厤
          '[data-testid*="media"]', '[data-testid*="video"]', '[data-testid*="image"]',
          '[aria-label*="media"]', '[aria-label*="video"]', '[aria-label*="image"]',
          '[title*="download"]', '[title*="media"]', '[title*="video"]', '[title*="image"]',
          
          // 鑳屾櫙鍥剧墖鍏冪礌
          'div[style*="background-image"]', 'div[style*="background: url"]',
          'span[style*="background-image"]', 'span[style*="background: url"]',
          
          // 绀句氦濯掍綋鐗瑰畾閫夋嫨鍣?          '[data-testid="tweetPhoto"]', '[data-testid="tweetVideo"]',
          '[data-testid="instagram-media"]', '[data-testid="ig-media"]',
          '[data-testid="fb-media"]', '[data-testid="fb-video"]',
          
          // 閫氱敤濯掍綋瀹瑰櫒
          '.media-container', '.video-container', '.image-container', '.photo-container',
          '.player-container', '.stream-container', '.content-container'
        ];
        
        // 灏濊瘯鎵惧埌濯掍綋鍏冪礌
        let foundElement = null;
        
        // 鏂规硶1: 浣跨敤closest鏌ユ壘鏈€杩戠殑濯掍綋鍏冪礌
        for (const selector of mediaSelectors) {
          foundElement = e.target.closest(selector);
          if (foundElement) break;
        }
        
        // 鏂规硶2: 濡傛灉娌℃壘鍒帮紝妫€鏌ュ綋鍓嶅厓绱犲強鍏剁埗鍏冪礌
        if (!foundElement) {
          let currentElement = e.target;
          while (currentElement && currentElement !== document.body) {
            // 妫€鏌ュ厓绱犲睘鎬?            const hasMediaAttr = currentElement.src || currentElement.href || 
                               currentElement.getAttribute('data-src') || 
                               currentElement.getAttribute('data-href') ||
                               currentElement.getAttribute('data-url') ||
                               currentElement.getAttribute('data-original');
            
            // 妫€鏌ユ牱寮?            const hasMediaStyle = currentElement.style && 
                                (currentElement.style.backgroundImage || 
                                 currentElement.style.background);
            
            // 妫€鏌ョ被鍚嶅拰ID
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
        
        // 鏂规硶3: 娣卞害鎵弿鍛ㄥ洿鍖哄煙
        if (!foundElement) {
          const rect = e.target.getBoundingClientRect();
          const centerX = rect.left + rect.width / 2;
          const centerY = rect.top + rect.height / 2;
          
          // 鎵弿鐐瑰嚮浣嶇疆鍛ㄥ洿鐨勫厓绱?          const nearbyElements = document.elementsFromPoint(centerX, centerY);
          for (const element of nearbyElements) {
            if (element === e.target) continue;
            
            // 妫€鏌ユ槸鍚︽槸濯掍綋鍏冪礌
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

      // 娣诲姞鐐瑰嚮浜嬩欢鐩戝惉鍣ㄥ鐞哹lob URL
      document.addEventListener('click', function(e) {
        const target = e.target;
        const link = target.closest('a');
        if (link && link.href && isBlobUrl(link.href)) {
          e.preventDefault();
          console.log('妫€娴嬪埌blob URL鐐瑰嚮:', link.href);
          resolveBlobUrl(link.href, 'video').then(resolved => {
            if (resolved) {
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: resolved.mediaType || 'video',
                url: resolved.resolvedUrl,
                isBase64: resolved.isBase64,
                action: 'download'
              }));
              console.log('宸插彂閫乥lob URL涓嬭浇璇锋眰');
            } else {
              console.error('瑙ｆ瀽blob URL澶辫触');
            }
          });
        }
      }, true);

      // 澧炲己鐨勫獟浣撲笅杞藉鐞?- 杩?00%鎴愬姛鐜?      function handleMediaDownload(target, e) {
        if (!target) {
          updateFeedbackStatus('鏈壘鍒板獟浣撳厓绱?, false);
          return;
        }
        
        // 鎳掑姞杞借嚜鍔ㄨЕ鍙?        try {
          if (typeof target.loading !== 'undefined') target.loading = 'eager';
          if (typeof target.decode === 'function') target.decode();
          if (typeof target.scrollIntoView === 'function') target.scrollIntoView({block: 'center'});
        } catch (err) { console.log('鎳掑姞杞借Е鍙戝け璐?, err); }
        
        // canvas鎴浘鍏滃簳
        if (target.tagName && target.tagName.toLowerCase() === 'canvas') {
          try {
            const dataUrl = target.toDataURL('image/png');
            if (dataUrl && dataUrl.startsWith('data:image/')) {
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: 'image',
                url: dataUrl.split(',')[1],
                isBase64: true,
                pageUrl: window.location.href,
                action: 'download'
              }));
              updateFeedbackStatus('宸叉埅鍥句繚瀛榗anvas', true);
              return;
            }
          } catch (err) {
            updateFeedbackStatus('canvas鎴浘澶辫触', false);
          }
        }
        
        // 绮惧噯URL鎻愬彇閫昏緫
        let url = null;
        const tag = target.tagName ? target.tagName.toLowerCase() : '';
        const urlSources = [
          () => (tag === 'img' || tag === 'video') ? (target.currentSrc || target.src) : null,
          () => target.href,
          () => target.getAttribute && target.getAttribute('src'),
          () => target.getAttribute && target.getAttribute('data-src'),
          () => target.getAttribute && target.getAttribute('data-original'),
          () => target.getAttribute && target.getAttribute('poster'),
          () => {
            try {
              const style = window.getComputedStyle(target);
              const bg = style && style.backgroundImage;
              if (bg && bg !== 'none') {
                const m = bg.match(/url\(['"]?([^'"\)]+)['"]?\)/);
                return m ? m[1] : null;
              }
            } catch (_) {}
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
          } catch (e) { console.log('URL鎻愬彇澶辫触:', e); }
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
          try { url = new URL(url, window.location.href).href; } catch (e) { console.log('URL瑙ｆ瀽澶辫触:', e); }
        }
        if (!url) {
          updateFeedbackStatus('鏈壘鍒颁笅杞介摼鎺?, false);
          return;
        }
        // 澶氶噸澶勭悊blob/data url
        function tryBlobOrDataUrl(url, mediaType) {
          if (isBlobUrl(url)) {
            updateFeedbackStatus('姝ｅ湪澶勭悊blob...', true);
            resolveBlobUrl(url, mediaType).then(resolved => {
              if (resolved) {
                window.processedMediaUrls.add(url);
                Flutter.postMessage(JSON.stringify({
                  type: 'media',
                  mediaType: resolved.mediaType || mediaType,
                  url: resolved.resolvedUrl,
                  isBase64: resolved.isBase64,
                  pageUrl: window.location.href,
                  action: 'download'
                }));
                updateFeedbackStatus('宸插彂閫佷笅杞借姹?, true);
              } else {
                // blob澶辫触锛屽皾璇昪anvas鎴浘鍏滃簳
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
                      updateFeedbackStatus('宸叉埅鍥句繚瀛榗anvas', true);
                      return;
                    }
                  } catch (err) { updateFeedbackStatus('canvas鎴浘澶辫触', false); }
                }
                updateFeedbackStatus('blob瑙ｆ瀽澶辫触', false);
              }
            });
            return true;
          } else if (url.startsWith('data:image/') || url.startsWith('data:video/')) {
            // data url鐩存帴base64瑙ｇ爜
            try {
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: url.startsWith('data:image/') ? 'image' : 'video',
                url: url.split(',')[1],
                isBase64: true,
                pageUrl: window.location.href,
                action: 'download'
              }));
              updateFeedbackStatus('宸蹭繚瀛榙ata url', true);
              return true;
            } catch (err) { updateFeedbackStatus('data url瑙ｆ瀽澶辫触', false); }
          }
          return false;
        }
        let mediaType = (tagName === 'img' || (url && url.match(/\.(png|jpe?g|gif|webp|bmp|svg|ico|tiff?|heic|heif)(\?|$)/i))) ? 'image' : 'video';
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
          Flutter.postMessage(JSON.stringify({
            type: 'media',
            mediaType: mediaType,
            url: url,
            isBase64: false,
            pageUrl: window.location.href,
            action: 'download'
          }));
          updateFeedbackStatus('宸插彂閫佷笅杞借姹?, true);
          e.preventDefault();
        } else {
          updateFeedbackStatus('璇ュ獟浣撳凡鍦ㄥ鐞嗕腑', false);
        }
      }

      // 鍚姩鍔ㄦ€佸唴瀹圭洃鍚?      const dynamicObserver = observeDynamicContent();
      
      // 鍒濆鎵弿椤甸潰濯掍綋鍏冪礌
      setTimeout(() => {
        const initialMediaElements = deepScanForMediaElements();
        initialMediaElements.forEach(element => {
          window.MediaInterceptor.mediaElements.add(element);
        });
        console.log('鍒濆鎵弿瀹屾垚锛屾壘鍒?, initialMediaElements.length, '涓獟浣撳厓绱?);
      }, 1000);
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
          final pageUrl = data['pageUrl'] as String?;

        if (url != null && url is String) {
          if (_processedUrls.contains(url)) return;
          _processedUrls.add(url);

          if (action == 'download') {
            debugPrint('Received URL from JavaScript with download action: $url, type: $mediaType, isBase64: $isBase64');
            if (isBase64) {
              _handleBlobUrl(url, mediaType);
            } else {
              MediaType selectedType = _determineMediaType(_guessMimeType(url));
              if (pageUrl != null && pageUrl.isNotEmpty) {
                _currentUrl = pageUrl;
              }
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
      debugPrint('澶勭悊Base64鏁版嵁浠ョ洿鎺ヤ繚瀛? $mediaType');
      final bytes = base64Decode(base64Data);
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final uuid = const Uuid().v4();
      final extension = mediaType == 'image' ? '.jpg' : '.mp4';
      final filePath = '${mediaDir.path}/$uuid$extension';
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      debugPrint('宸蹭粠Base64淇濆瓨鏂囦欢: $filePath');
      await _saveToMediaLibrary(file, mediaType == 'image' ? MediaType.image : MediaType.video);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('濯掍綋宸叉垚鍔熶繚瀛樺埌濯掍綋搴? ${file.path.split('/').last}'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(label: '鏌ョ湅', onPressed: () => Navigator.pushNamed(context, '/media_manager')),
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('澶勭悊Base64鏁版嵁鏃跺嚭閿? $e');
      debugPrint('閿欒鍫嗘爤: $stackTrace');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('涓嬭浇澶辫触: $e')));
    }
  }

  void _loadUrl(String url) {
    String processedUrl = url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) processedUrl = 'https://$url';
    if (processedUrl.contains('telegram.org') || processedUrl.contains('t.me') || processedUrl.contains('web.telegram.org')) {
      _setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1');
      if (processedUrl.contains('web.telegram.org')) processedUrl = 'https://web.telegram.org/a/';
    } else if (processedUrl.contains('youtube.com') || processedUrl.contains('youtu.be')) {
      _setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36');
    } else {
      _setUserAgent('Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.162 Mobile Safari/537.36');
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
      
      // 纭繚甯哥敤缃戠珯鍒楄〃琚纭姞杞?      await _loadCommonWebsites();
      
      // 濡傛灉甯哥敤缃戠珯鍒楄〃涓虹┖锛屽己鍒跺姞杞介粯璁ょ綉绔?      if (_commonWebsites.isEmpty) {
        debugPrint('甯哥敤缃戠珯鍒楄〃涓虹┖锛屽姞杞介粯璁ょ綉绔?);
        setState(() {
          _commonWebsites.addAll([
            {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
            {'name': 'Edge', 'url': 'https://www.bing.com', 'iconCode': Icons.public.codePoint},
            {'name': 'X', 'url': 'https://twitter.com', 'iconCode': Icons.public.codePoint},
            {'name': 'Facebook', 'url': 'https://www.facebook.com', 'iconCode': Icons.public.codePoint},
            {'name': 'Telegram', 'url': 'https://web.telegram.org', 'iconCode': Icons.public.codePoint},
            {'name': '鐧惧害', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint}
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
    // 纭繚_commonWebsites涓嶄负绌?    if (_commonWebsites.isEmpty) {
      debugPrint('鏋勫缓涓婚〉鏃跺彂鐜板父鐢ㄧ綉绔欏垪琛ㄤ负绌猴紝鍔犺浇榛樿缃戠珯');
      _loadCommonWebsites();
    }
    
    return Stack(
      children: [
        Column(
          children: [
            // 绉婚櫎浜嗛《閮ㄥ伐鍏锋爮
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
                    // 娣诲姞鏂扮綉绔欑殑鎸夐挳
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
                            Text('娣诲姞缃戠珯', style: TextStyle(fontSize: 16), textAlign: TextAlign.center),
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
                // 绉婚櫎 dragEnabled 鍑芥暟鍙傛暟锛屾敼涓哄湪 _reorderWebsites 鏂规硶涓鐞?                // 绉婚櫎 onReorderStart 鍙傛暟锛屽洜涓?ReorderableGridView 涓嶆敮鎸佹鍙傛暟
              ),
            ),
          ],
        ),
        // 绉婚櫎搴曢儴娴姩鎸夐挳锛屾敼涓哄湪椤堕儴鏄剧ず
      ],
    );
  }

  void _showAddWebsiteDialog(BuildContext context) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    // 璁剧疆榛樿URL锛堝鏋滃湪娴忚缃戦〉锛屽垯浣跨敤褰撳墠URL锛?    if (!_showHomePage && _isBrowsingWebPage) {
      urlController.text = _currentUrl;
    }

    // 鍏堟樉绀哄璇濇锛岀劧鍚庡紓姝ヨ幏鍙栨爣棰?    showDialog(
      context: context,
      builder: (dialogContext) {
        // 濡傛灉鍦ㄦ祻瑙堢綉椤碉紝寮傛鑾峰彇缃戦〉鏍囬
        if (!_showHomePage && _isBrowsingWebPage) {
          // 鏄剧ず"鑾峰彇涓?.."浣滀负涓存椂鏍囬
          nameController.text = "鑾峰彇涓?..";

          // 寮傛鑾峰彇缃戦〉鏍囬
          _controller.getTitle().then((title) {
            if (title != null && title.isNotEmpty && nameController.text == "鑾峰彇涓?..") {
              // 鐩存帴鏇存柊鏂囨湰鎺у埗鍣紝鑰屼笉浣跨敤setState
              nameController.text = title;
              // 鑷姩閫変腑鏂囨湰锛屾柟渚跨敤鎴风紪杈?              nameController.selection = TextSelection(
                baseOffset: 0,
                extentOffset: title.length,
              );
            }
          }).catchError((error) {
            debugPrint('鑾峰彇缃戦〉鏍囬鍑洪敊: $error');
            if (nameController.text == "鑾峰彇涓?..") {
              nameController.text = "";
            }
          });
        }

        return AlertDialog(
          title: const Text('娣诲姞缃戠珯鍒版爣绛?),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '缃戠珯鍚嶇О',
                  hintText: '杈撳叆鑷畾涔夊悕绉?,
                  helperText: '涓虹綉绔欒缃竴涓畝鐭槗璁扮殑鍚嶇О',
                ),
                autofocus: true,
              ),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '缃戠珯鍦板潃',
                  hintText: '渚嬪锛歨ttps://www.google.com',
                ),
                enabled: !_isBrowsingWebPage, // 濡傛灉鍦ㄦ祻瑙堢綉椤碉紝鍒欑鐢║RL杈撳叆妗?              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('鍙栨秷'),
            ),
            TextButton(
              onPressed: () async {
                if (nameController.text.isNotEmpty &&
                    urlController.text.isNotEmpty &&
                    nameController.text != "鑾峰彇涓?..") {

                  // 鍒涘缓涓€涓彉閲忓瓨鍌ㄥ姞杞藉璇濇鐨刢ontext
                  BuildContext? loadingDialogContext;

                  // 鏄剧ず鍔犺浇瀵硅瘽妗嗗苟淇濆瓨context
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
                            Text('娣诲姞涓?..'),
                          ],
                        ),
                      );
                    },
                  );

                  await _addWebsite(nameController.text, urlController.text, Icons.web);
                  await _saveCommonWebsites();

                  // 瀹夊叏鍦板叧闂姞杞藉璇濇
                  if (loadingDialogContext != null && Navigator.canPop(loadingDialogContext!)) {
                    Navigator.pop(loadingDialogContext!);
                  }

                  // 鍏抽棴涓诲璇濇
                  Navigator.of(dialogContext).pop();

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('宸插皢"${nameController.text}"娣诲姞鍒版爣绛炬爮'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                } else if (nameController.text == "鑾峰彇涓?..") {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('璇风瓑寰呯綉椤垫爣棰樿幏鍙栧畬鎴愶紝鎴栬緭鍏ヨ嚜瀹氫箟鍚嶇О'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('璇疯緭鍏ョ綉绔欏悕绉板拰鍦板潃'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: const Text('娣诲姞'),
            ),
          ],
        );
      },
    );
  }

  // 绉婚櫎_buildEditableWebsiteItem鏂规硶锛屽洜涓烘垜浠凡缁忕Щ闄や簡缂栬緫妯″紡

  void _showRenameWebsiteDialog(BuildContext context, Map<String, dynamic> website, int index) {
    final nameController = TextEditingController(text: website['name']);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('閲嶅懡鍚嶇綉绔?),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '缃戠珯鍚嶇О', hintText: '杈撳叆鏂扮殑缃戠珯鍚嶇О'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text('褰撳墠URL: ${website['url']}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('鍙栨秷')),
          TextButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && nameController.text != website['name']) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const AlertDialog(
                    content: Row(
                      children: [CircularProgressIndicator(), SizedBox(width: 20), Text('淇濆瓨涓?..')],
                    ),
                  ),
                );
                setState(() => _commonWebsites[index]['name'] = nameController.text);
                await _saveCommonWebsites();
                Navigator.of(context).pop();
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('缃戠珯鍚嶇О宸叉洿鏂?)));
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('淇濆瓨'),
          ),
        ],
      ),
    );
  }

  Widget _buildWebsiteCard(Map<String, dynamic> website, int index) {
    // 鏍规嵁 iconCode 鑾峰彇瀵瑰簲鐨勫浘鏍?    IconData iconData = _getIconFromCode(website['iconCode']);
    
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
  
  void _showWebsiteOptionsDialog(BuildContext context, Map<String, dynamic> website, int index) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit, color: Colors.blue),
            title: const Text('閲嶅懡鍚?),
            onTap: () {
              Navigator.pop(context);
              _showRenameWebsiteDialog(context, website, index);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text('鍒犻櫎'),
            onTap: () async {
              Navigator.pop(context);
              final shouldDelete = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('鍒犻櫎缃戠珯'),
                  content: Text('纭畾瑕佸垹闄?${website['name']} 鍚楋紵'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('鍙栨秷')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('鍒犻櫎')),
                  ],
                ),
              ) ?? false;
              if (shouldDelete) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const AlertDialog(
                    content: Row(
                      children: [CircularProgressIndicator(), SizedBox(width: 20), Text('鍒犻櫎涓?..')],
                    ),
                  ),
                );
                await _removeWebsite(index);
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('缃戠珯宸插垹闄?)));
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
            {'name': '鐧惧害', 'url': 'https://www.baidu.com'},
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
      // 纭繚_commonWebsites涓嶄负绌?      if (_commonWebsites.isEmpty) {
        debugPrint('璀﹀憡锛氬皾璇曚繚瀛樼┖鐨勫父鐢ㄧ綉绔欏垪琛紝灏嗗姞杞介粯璁ょ綉绔?);
        _commonWebsites.addAll([
          {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
          {'name': 'Telegram', 'url': 'https://web.telegram.org', 'iconCode': Icons.public.codePoint},
          {'name': '鐧惧害', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint}
        ]);
      }
      
      final prefs = await SharedPreferences.getInstance();
      final cleanedWebsites = _commonWebsites.map((site) => {
        'name': site['name'],
        'url': site['url'],
        'iconCode': Icons.public.codePoint,
      }).toList();
      final jsonString = jsonEncode(cleanedWebsites);
      
      // 鍏堣幏鍙栨棫鏁版嵁浣滀负澶囦唤
      final oldJsonString = prefs.getString('common_websites');
      
      // 鐩存帴璁剧疆鏂版暟鎹紝涓嶅厛绉婚櫎
      final success = await prefs.setString('common_websites', jsonString);
      
      if (success) {
        debugPrint('鎴愬姛淇濆瓨浜?{cleanedWebsites.length}涓父鐢ㄧ綉绔?);
      } else {
        debugPrint('淇濆瓨甯哥敤缃戠珯澶辫触锛屽皾璇曟仮澶嶆棫鏁版嵁');
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
      debugPrint('寮€濮嬪鐞嗕笅杞? $url, MIME绫诲瀷: $mimeType');
      if (_downloadingUrls.contains(url)) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('璇ユ枃浠舵鍦ㄤ笅杞戒腑锛岃绋嶅€?..')));
        return;
      }

      String processedUrl = url;
      if (url.startsWith('blob:https://web.telegram.org/')) {
        // Blob URL 鐢?JavaScript 澶勭悊锛屼笉鐩存帴涓嬭浇
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
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('寮€濮嬩笅杞斤紝灏嗗湪鍚庡彴杩涜...'), duration: Duration(seconds: 2)));
            unawaited(_performBackgroundDownload(processedUrl, mediaType));
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('寮€濮嬩笅杞斤紝灏嗗湪鍚庡彴杩涜...'), duration: Duration(seconds: 2)));
        unawaited(_performBackgroundDownload(processedUrl, selectedType));
      }
    } catch (e, stackTrace) {
      debugPrint('澶勭悊涓嬭浇鏃跺嚭閿? $e');
      debugPrint('閿欒鍫嗘爤: $stackTrace');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('涓嬭浇鍑洪敊: $e')));
    }
  }

  Future<String> _resolveYouTubeUrl(String url) async {
    return url; // 鍗犱綅绗︼紝闇€闆嗘垚 youtube_explode_dart
  }

  Widget _buildDownloadDialog(String url, String mimeType) {
    MediaType selectedType = _determineMediaType(mimeType);
    return StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('涓嬭浇濯掍綋'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('鎮ㄦ兂涓嬭浇杩欎釜鏂囦欢鍚楋紵'),
            const SizedBox(height: 8),
            Text('URL: $url', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 16),
            const Text('閫夋嫨濯掍綋绫诲瀷:'),
            RadioListTile<MediaType>(
              title: const Text('鍥剧墖'),
              value: MediaType.image,
              groupValue: selectedType,
              onChanged: (value) => setState(() => selectedType = value!),
            ),
            RadioListTile<MediaType>(
              title: const Text('瑙嗛'),
              value: MediaType.video,
              groupValue: selectedType,
              onChanged: (value) => setState(() => selectedType = value!),
            ),
            RadioListTile<MediaType>(
              title: const Text('闊抽'),
              value: MediaType.audio,
              groupValue: selectedType,
              onChanged: (value) => setState(() => selectedType = value!),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('鍙栨秷')),
          TextButton(
            onPressed: () => Navigator.of(context).pop({'download': true, 'mediaType': selectedType}),
          child: const Text('瑙ｆ瀽娴嬭瘯'),
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
    debugPrint('妫€鏌RL鏄惁涓哄彲涓嬭浇閾炬帴: $url');
    if (url.startsWith('blob:https://web.telegram.org/')) return false; // Blob URL 鐢?JavaScript 澶勭悊
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

  static const MethodChannel _cookieChannel = MethodChannel('browser_cookies');

  Future<String?> _getCookiesForUrl(String url) async {
    try {
      final cookies = await _cookieChannel.invokeMethod<String>('getCookies', {'url': url});
      return cookies;
    } catch (e) {
      debugPrint('鑾峰彇Cookies澶辫触: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _headInfo(String url, Map<String, String> headers) async {
    try {
      final dio = Dio();
      dio.options.followRedirects = true;
      dio.options.maxRedirects = 5;
      final response = await dio.request(
        url,
        options: Options(method: 'HEAD', headers: headers, validateStatus: (s) => s != null && s < 500),
      );
      return {
        'url': response.realUri.toString(),
        'contentType': response.headers['content-type']?.first,
        'contentDisposition': response.headers['content-disposition']?.first,
      };
    } catch (_) {
      return null;
    }
  }

  String? _filenameFromContentDisposition(String? cd) {
    if (cd == null) return null;
    final lower = cd.toLowerCase();
    final filenameStar = RegExp(r"filename\*=['"]?[^']*'[^']*'([^;'"]+)").firstMatch(lower);
    if (filenameStar != null) return Uri.decodeFull(filenameStar.group(1)!);
    final filename = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
    if (filename != null) return filename.group(1);
    return null;
  }

  Future<File?> _downloadFile(String url, MediaType mediaType) async { // Added mediaType parameter
    try {
      debugPrint('寮€濮嬩笅杞芥枃浠讹紝URL: $url');
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 60);
      dio.options.receiveTimeout = const Duration(seconds: 300);
      dio.options.sendTimeout = const Duration(seconds: 60);

      dio.options.headers = {
        'User-Agent': _currentUserAgent,
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
      };

      // Attach Referer of the current page when available
      if (_currentUrl.isNotEmpty) {
        dio.options.headers['Referer'] = _currentUrl;
      }
      // Attach cookies from webview if possible
      try {
        final cookies = await _getCookiesForUrl(_currentUrl);
        if (cookies != null && cookies.isNotEmpty) {
          dio.options.headers['Cookie'] = cookies;
        }
      } catch (_) {}

      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

      final uuid = const Uuid().v4();
      final uri = Uri.parse(url);
      String extension = _getFileExtension(uri.path);

      // HEAD to refine filename/extension
      final head = await _headInfo(url, Map<String, String>.from(dio.options.headers));
      String? serverFilename = _filenameFromContentDisposition(head?['contentDisposition']);
      String? contentType = head?['contentType'];

      if (extension.isEmpty) {
        final mimeType = contentType ?? _guessMimeType(url);
        extension = mimeType.startsWith('image/') ? '.jpg' :
                    mimeType.startsWith('video/') || mimeType == 'application/x-mpegURL' ? '.mp4' :
                    mimeType.startsWith('audio/') ? '.mp3' : '.bin';
      }

      String fileName = serverFilename ?? '$uuid$extension';
      if (!fileName.toLowerCase().endsWith(extension.toLowerCase())) {
        fileName = '$fileName$extension';
      }
      final filePath = '${mediaDir.path}/$fileName';
      debugPrint('灏嗕笅杞藉埌鏂囦欢璺緞: $filePath');

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
                debugPrint('涓嬭浇杩涘害: ${(progress * 100).toStringAsFixed(2)}%');
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
          debugPrint('涓嬭浇澶辫触 (灏濊瘯 $retryCount/$maxRetries): $e');
          if (e is DioException) {
            if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout || e.type == DioExceptionType.sendTimeout) {
              debugPrint('涓嬭浇瓒呮椂閿欒: $e');
              if (retryCount >= maxRetries) throw Exception('涓嬭浇瓒呮椂锛岃妫€鏌ョ綉缁滆繛鎺ユ垨绋嶅悗閲嶈瘯');
            } else if (e.type == DioExceptionType.badResponse) {
              debugPrint('涓嬭浇鍝嶅簲閿欒: 鐘舵€佺爜 ${e.response?.statusCode}, 閿欒: ${e.response?.data}');
              if (e.response?.statusCode == 400) {
                if (retryCount >= maxRetries) throw Exception('涓嬭浇澶辫触: 鏂囦欢鏃犳硶璁块棶鎴朆ot鏉冮檺涓嶈冻');
              } else {
                if (retryCount >= maxRetries) throw Exception('涓嬭浇澶辫触: 鏈嶅姟鍣ㄨ繑鍥為敊璇?${e.response?.statusCode}');
              }
            } else if (e.type == DioExceptionType.unknown) {
              debugPrint('涓嬭浇鏈煡閿欒 (鍙兘鏄綉缁滈棶棰?: $e');
              if (retryCount >= maxRetries) throw Exception('涓嬭浇澶辫触: 缃戠粶杩炴帴寮傚父鎴栨湭鐭ラ敊璇?);
            } else {
              if (retryCount >= maxRetries) throw Exception('涓嬭浇澶辫触: ${e.message}');
            }
          } else {
            if (retryCount >= maxRetries) throw Exception('涓嬭浇澶辫触: $e');
          }
          await Future.delayed(Duration(seconds: retryCount * 3)); // Increased delay
        }
      }

      final file = File(filePath);
      if (await file.exists() && await file.length() > 0) return file;
      await file.delete();
      return null;
    } catch (e, stackTrace) {
      debugPrint('涓嬭浇鏂囦欢鏃跺嚭閿? $e');
      debugPrint('閿欒鍫嗘爤: $stackTrace');
      return null;
    }
  }

  Future<void> _handleM3u8Download(String m3u8Path, String url) async {
    final dio = Dio();
    final response = await dio.get(url);
    final segments = response.data.toString().split('\n').where((line) => line.startsWith('http')).toList();
    if (segments.isNotEmpty) {
      final outputPath = m3u8Path.replaceAll('.m3u8', '.ts');
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
      if (duplicate != null) throw Exception('鏂囦欢宸插瓨鍦ㄤ簬濯掍綋搴撲腑');
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
      debugPrint('淇濆瓨鍒板獟浣撳簱鏃跺嚭閿? $e');
      rethrow;
    }
  }

  Future<String> _calculateFileHash(File file) async {
    try {
      final bytes = await file.readAsBytes();
      return md5.convert(bytes).toString();
    } catch (e) {
      debugPrint('璁＄畻鏂囦欢鍝堝笇鍊兼椂鍑洪敊: $e');
      return '';
    }
  }

  void _addBookmark(String url) {
    // 妫€鏌ユ槸鍚﹀凡瀛樺湪鐩稿悓URL鐨勪功绛?    if (_bookmarks.any((bookmark) => bookmark['url'] == url)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('涔︾宸插瓨鍦?)));
      return;
    }

    // 鍒涘缓涓€涓枃鏈帶鍒跺櫒锛屽垵濮嬪€艰涓哄綋鍓嶇綉椤电殑鏍囬鎴朥RL
    final nameController = TextEditingController();
    
    // 濡傛灉鍦ㄦ祻瑙堢綉椤碉紝灏濊瘯鑾峰彇缃戦〉鏍囬
    if (!_showHomePage && _isBrowsingWebPage) {
      nameController.text = "鑾峰彇涓?..";
      _controller.getTitle().then((title) {
        if (title != null && title.isNotEmpty && nameController.text == "鑾峰彇涓?..") {
          nameController.text = title;
          // 鑷姩閫変腑鏂囨湰锛屾柟渚跨敤鎴风紪杈?          nameController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: title.length,
          );
        }
      }).catchError((error) {
        debugPrint('鑾峰彇缃戦〉鏍囬鍑洪敊: $error');
        if (nameController.text == "鑾峰彇涓?..") {
          nameController.text = "";
        }
      });
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('娣诲姞涔︾'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '涔︾鍚嶇О',
                hintText: '杈撳叆鑷畾涔夊悕绉?,
                helperText: '涓轰功绛捐缃竴涓畝鐭槗璁扮殑鍚嶇О',
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
            child: const Text('鍙栨秷'),
          ),
          TextButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && nameController.text != "鑾峰彇涓?..") {
                // 鍒涘缓涓€涓彉閲忓瓨鍌ㄥ姞杞藉璇濇鐨刢ontext
                BuildContext? loadingDialogContext;

                // 鏄剧ず鍔犺浇瀵硅瘽妗嗗苟淇濆瓨context
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
                          Text('娣诲姞涓?..'),
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

                // 瀹夊叏鍦板叧闂姞杞藉璇濇
                if (loadingDialogContext != null && Navigator.canPop(loadingDialogContext!)) {
                  Navigator.pop(loadingDialogContext!);
                }

                // 鍏抽棴涓诲璇濇
                Navigator.of(context).pop();

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('宸插皢"${nameController.text}"娣诲姞鍒颁功绛?),
                    duration: const Duration(seconds: 2),
                  ),
                );
              } else if (nameController.text == "鑾峰彇涓?..") {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('璇风瓑寰呯綉椤垫爣棰樿幏鍙栧畬鎴愶紝鎴栬緭鍏ヨ嚜瀹氫箟鍚嶇О'),
                    duration: Duration(seconds: 2),
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('璇疯緭鍏ヤ功绛惧悕绉?),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text('娣诲姞'),
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
                          tooltip: '閲嶅懡鍚?,
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () async {
                            final shouldDelete = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('鍒犻櫎涔︾'),
                                content: Text('纭畾瑕佸垹闄や功绛?"${_bookmarks[index]['name']}" 鍚楋紵'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('鍙栨秷')),
                                  TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('鍒犻櫎')),
                                ],
                              ),
                            ) ?? false;
                            if (shouldDelete) {
                              modalSetState(() {
                                _bookmarks.removeAt(index);
                              });
                              await _saveBookmarks();
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('宸插垹闄や功绛?)));
                            }
                          },
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
        title: const Text('閲嶅懡鍚嶄功绛?),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '涔︾鍚嶇О', hintText: '杈撳叆鏂扮殑涔︾鍚嶇О'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text('URL: ${bookmark['url']}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('鍙栨秷')),
          TextButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && nameController.text != bookmark['name']) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const AlertDialog(
                    content: Row(
                      children: [CircularProgressIndicator(), SizedBox(width: 20), Text('淇濆瓨涓?..')],
                    ),
                  ),
                );
                setState(() => _bookmarks[index]['name'] = nameController.text);
                await _saveBookmarks();
                Navigator.of(context).pop();
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('涔︾鍚嶇О宸叉洿鏂?)));
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('淇濆瓨'),
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
          debugPrint('浠嶴haredPreferences鍔犺浇浜?{_commonWebsites.length}涓父鐢ㄧ綉绔?);
          return;
        }
      }
      
      // 濡傛灉娌℃湁浠嶴haredPreferences鍔犺浇鍒版暟鎹紝鎴栬€呭姞杞界殑鏁版嵁涓虹┖锛屽垯鍔犺浇榛樿缃戠珯
      setState(() {
        _commonWebsites.clear();
        _commonWebsites.addAll([
          {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
          {'name': 'Telegram', 'url': 'https://web.telegram.org', 'iconCode': Icons.public.codePoint},
          {'name': '鐧惧害', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint}
        ]);
      });
      debugPrint('鍔犺浇浜嗛粯璁ゅ父鐢ㄧ綉绔?);
      await _saveCommonWebsites();
    } catch (e) {
      debugPrint('Error loading common websites: $e');
      // 鍑洪敊鏃跺姞杞介粯璁ょ綉绔?      setState(() {
        _commonWebsites.clear();
        _commonWebsites.addAll([
          {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
          {'name': 'Telegram', 'url': 'https://web.telegram.org', 'iconCode': Icons.public.codePoint},
          {'name': '鐧惧害', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint}
        ]);
      });
      debugPrint('鍔犺浇鍑洪敊锛屼娇鐢ㄩ粯璁ゅ父鐢ㄧ綉绔?);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('common_websites');
    }
  }

  // 2. 鍔犺浇鍘嗗彶璁板綍
  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final historyString = prefs.getString('browser_history');
    if (historyString != null) {
      _history = List<Map<String, dynamic>>.from(json.decode(historyString));
    }
  }

  // 3. 淇濆瓨鍘嗗彶璁板綍
  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('browser_history', json.encode(_history));
  }

  // 4. 娣诲姞鍘嗗彶璁板綍锛堝湪缃戦〉鍔犺浇鎴愬姛鏃惰皟鐢級
  Future<void> _addHistory(String title, String url) async {
    if (url.isEmpty) return;
    // 鍘婚噸锛氬鏋滃凡瀛樺湪鍒欏厛绉婚櫎
    _history.removeWhere((item) => item['url'] == url);
    _history.insert(0, {
      'title': title,
      'url': url,
      'datetime': DateTime.now().toIso8601String(),
    });
    // 闄愬埗鏈€澶ф潯鏁?    if (_history.length > 200) _history = _history.sublist(0, 200);
    await _saveHistory();
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
          title: _showHomePage ? const Text('娴忚鍣?) : const SizedBox.shrink(),
          leading: _showHomePage
              ? null
              : IconButton(
                  icon: const Icon(Icons.home),
                  onPressed: _goToHomePage,
                  tooltip: '鍥炲埌涓婚〉',
                ),
          centerTitle: true,
          actions: [
            // 娣诲姞濯掍綋搴撴寜閽埌actions鍒楄〃鐨勭涓€涓綅缃?            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.photo_library),
                onPressed: () {
                  print('[BrowserPage] 濯掍綋搴撴寜閽鐐瑰嚮');
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const MediaManagerPage()),
                  );
                },
                tooltip: '濯掍綋搴?,
              ),
            if (_isBrowsingWebPage && _shouldKeepWebPageState && _showHomePage)
              IconButton(
                icon: const Icon(Icons.arrow_right_alt),
                onPressed: _restoreWebPage,
                tooltip: '杩斿洖涓婃娴忚鐨勭綉椤?,
              ),
            IconButton(
              icon: const Icon(Icons.bookmark),
              onPressed: _showBookmarks,
              tooltip: '鏄剧ず涔︾',
            ),
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.bookmark_add),
                onPressed: () => _addBookmark(_currentUrl),
                tooltip: '娣诲姞涔︾',
              ),
            if (_showHomePage) ...[
              IconButton(
                icon: const Icon(Icons.import_export),
                onPressed: _showExportImportMenu,
                tooltip: '瀵煎叆/瀵煎嚭鏁版嵁',
              ),
              IconButton(
                icon: const Icon(Icons.telegram),
                onPressed: _showTelegramDownloadDialog,
                tooltip: 'Telegram 涓嬭浇',
              ),
            ],
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red),
                onPressed: _exitWebPage,
                tooltip: '閫€鍑虹綉椤?,
              ),
            IconButton(
              icon: const Icon(Icons.history),
              onPressed: _showHistory,
              tooltip: '鍘嗗彶璁板綍',
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
                              tooltip: '鍚庨€€',
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_forward),
                              onPressed: () async {
                                if (await _controller.canGoForward()) _controller.goForward();
                              },
                              tooltip: '鍓嶈繘',
                            ),
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              onPressed: () => _controller.reload(),
                              tooltip: '鍒锋柊',
                            ),
                            Expanded(
                              child: TextField(
                                controller: _urlController,
                                decoration: const InputDecoration(
                                  hintText: '杈撳叆缃戝潃',
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
                              tooltip: '鍓嶅線',
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
    _saveBookmarks().then((_) => debugPrint('涔︾淇濆瓨瀹屾垚')).catchError((error) => debugPrint('淇濆瓨涔︾鏃跺嚭閿? $error'));
    _saveCommonWebsites().then((_) => debugPrint('甯哥敤缃戠珯淇濆瓨瀹屾垚')).catchError((error) => debugPrint('淇濆瓨甯哥敤缃戠珯鏃跺嚭閿? $error'));
    widget.onBrowserHomePageChanged?.call(true);
    super.dispose();
  }

  Future<void> _performBackgroundDownload(String url, MediaType mediaType) async {
    _downloadingUrls.add(url);
    try {
      debugPrint('寮€濮嬪悗鍙颁笅杞? $url, 濯掍綋绫诲瀷: $mediaType');
      
      if (mediaType == MediaType.video) {
        _isDownloadingVideo.value = true;
        _videoDownloadProgress.value = 0.0;
      }

      final file = await _downloadFile(url, mediaType);

      if (file != null) {
        debugPrint('鏂囦欢涓嬭浇鎴愬姛: ${file.path}');
        await _saveToMediaLibrary(file, mediaType);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${mediaType == MediaType.video ? "瑙嗛" : mediaType == MediaType.image ? "鍥剧墖" : "闊抽"}宸叉垚鍔熶繚瀛樺埌濯掍綋搴? ${file.path.split('/').last}'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(label: '鏌ョ湅', onPressed: () => Navigator.pushNamed(context, '/media_manager')),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${mediaType == MediaType.video ? "瑙嗛" : mediaType == MediaType.image ? "鍥剧墖" : "闊抽"}涓嬭浇澶辫触锛岃妫€鏌ョ綉缁滆繛鎺ユ垨绋嶅悗閲嶈瘯'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('鍚庡彴涓嬭浇鍑洪敊: $url, 閿欒: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${mediaType == MediaType.video ? "瑙嗛" : mediaType == MediaType.image ? "鍥剧墖" : "闊抽"}涓嬭浇鍑洪敊: $e'),
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
  
  /// 鏄剧ず Telegram 涓嬭浇瀵硅瘽妗?  void _showTelegramDownloadDialog() {
    if (!_telegramService.isConfigured) {
      _showBotTokenConfigDialog();
    } else {
      _showTelegramUrlInputDialog();
    }
  }
  
  /// 鏄剧ず Bot Token 閰嶇疆瀵硅瘽妗?  void _showBotTokenConfigDialog() {
    final tokenController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('閰嶇疆 Telegram Bot'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '璇峰厛閰嶇疆 Telegram Bot Token 浠ヤ娇鐢ㄤ笅杞藉姛鑳斤細\n\n'
              '1. 鍦?Telegram 涓壘鍒?@BotFather\n'
              '2. 鍙戦€?/newbot 鍒涘缓鏂版満鍣ㄤ汉\n'
              '3. 鎸夋彁绀鸿缃満鍣ㄤ汉鍚嶇О\n'
              '4. 澶嶅埗鑾峰緱鐨?Token 骞剁矘璐村埌涓嬫柟',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: tokenController,
              decoration: const InputDecoration(
                labelText: 'Bot Token',
                hintText: '渚嬪: 123456789:ABCdefGHIjklMNOpqrSTUVwxyz',
                border: OutlineInputBorder(),
                // 纭繚鍐呭鍙互鑷姩鎹㈣
                helperMaxLines: 3,
                errorMaxLines: 3,
              ),
              // 澧炲姞鏈€澶ц鏁帮紝闃叉婧㈠嚭
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('鍙栨秷'),
          ),
          ElevatedButton(
            onPressed: () async {
              final token = tokenController.text.trim();
              if (token.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('璇疯緭鍏?Bot Token')),
                );
                return;
              }
              
              // 鍏抽棴褰撳墠閰嶇疆瀵硅瘽妗?              Navigator.pop(dialogContext);
              // 娣诲姞鐭殏寤惰繜锛岀‘淇濆璇濇宸插畬鍏ㄥ叧闂?              await Future.delayed(const Duration(milliseconds: 100));
              if (!mounted) return; // 濡傛灉缁勪欢宸插嵏杞斤紝鐩存帴杩斿洖

              // 鍒涘缓涓€涓彉閲忓瓨鍌ㄥ姞杞藉璇濇鐨刢ontext
              BuildContext? loadingDialogContext;

              // 鏄剧ず鍔犺浇瀵硅瘽妗嗗苟淇濆瓨context
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
                        Text('楠岃瘉 Bot Token...'),
                      ],
                    ),
                  );
                },
              );
              
              bool isValid = false;
              try {
                // 娣诲姞瓒呮椂澶勭悊
                isValid = await _telegramService.validateBotToken(token).timeout(
                  const Duration(seconds: 15),
                  onTimeout: () {
                    print('楠岃瘉 Bot Token 瓒呮椂');
                    return false;
                  },
                );
              } catch (e) {
                print('楠岃瘉 Bot Token 杩囩▼涓彂鐢熼敊璇? $e');
                isValid = false;
              }

              // 瀹夊叏鍦板叧闂姞杞藉璇濇
              if (loadingDialogContext != null && mounted) {
                try {
                  Navigator.pop(loadingDialogContext!); // 鍏抽棴鍔犺浇瀵硅瘽妗?                } catch (e) {
                  // 蹇界暐瀵艰埅閿欒锛屽彲鑳芥槸鍥犱负widget宸茬粡琚攢姣?                }
              }
              
              if (mounted) { // 纭繚缁勪欢浠嶇劧鎸傝浇
                // 鏄剧ず楠岃瘉缁撴灉瀵硅瘽妗?                showDialog(
                  context: context, // Use the main context for this dialog
                  builder: (context) => AlertDialog(
                    title: Text(isValid ? '楠岃瘉鎴愬姛' : '楠岃瘉澶辫触'),
                    content: Text(isValid ? 'Bot Token 楠岃瘉閫氳繃锛? : '鏃犳晥鐨?Bot Token锛岃妫€鏌ュ悗閲嶈瘯'),
                    actions: [
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(context); // 鍏抽棴楠岃瘉缁撴灉瀵硅瘽妗?                          if (isValid) {
                            final success = await _telegramService.saveBotToken(token);
                            if (mounted) {
                              if (success) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Bot Token 閰嶇疆鎴愬姛锛?),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                                // 鍚姩杞
                                _startTelegramPolling();
                                if (mounted) {
                                  _showTelegramUrlInputDialog();
                                }
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('淇濆瓨 Bot Token 澶辫触'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          } else {
                            _showBotTokenConfigDialog(); // 閲嶆柊鏄剧ず閰嶇疆瀵硅瘽妗?                          }
                        },
                        child: Text('纭畾'),
                      ),
                    ],
                  ),
                );
              }
            },
            child: const Text('淇濆瓨'),
          ),
        ],
      ),
    );
  }
  
  /// 鏄剧ず Telegram URL 杈撳叆瀵硅瘽妗?  void _showTelegramUrlInputDialog() {
    final urlController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Telegram 濯掍綋涓嬭浇'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
               'Telegram Bot 涓嬭浇鍔熻兘璇存槑锛歕n\n'
               '鐢变簬 Telegram Bot API 闄愬埗锛屾満鍣ㄤ汉鍙兘涓嬭浇鍙戦€佺粰瀹冪殑娑堟伅銆俓n\n'
               '浣跨敤鏂规硶锛歕n'
               '1. 鍦?Telegram 涓壘鍒版偍鐨勬満鍣ㄤ汉\n'
               '2. 灏嗚涓嬭浇鐨勫獟浣撴枃浠惰浆鍙戠粰鏈哄櫒浜篭n'
               '3. 鏈哄櫒浜轰細鑷姩澶勭悊骞朵笅杞芥枃浠禱n\n'
               '鎴栬€呰緭鍏ユ秷鎭摼鎺ヨ繘琛岃В鏋愭祴璇曪細',
               style: TextStyle(fontSize: 14),
             ),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                 labelText: 'Telegram 娑堟伅閾炬帴锛堟祴璇曡В鏋愶級',
                 hintText: '渚嬪: https://t.me/channel/123',
                 border: OutlineInputBorder(),
               ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('鍙栨秷'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _showBotTokenConfigDialog();
            },
            child: const Text('閲嶆柊閰嶇疆 Bot'),
          ),
          ElevatedButton(
            onPressed: () async {
              final url = urlController.text.trim();
              if (url.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('璇疯緭鍏?Telegram 娑堟伅閾炬帴')),
                );
                return;
              }
              
              Navigator.pop(context);
              if (mounted) {
                await _downloadFromTelegram(url);
              }
            },
            child: const Text('瑙ｆ瀽娴嬭瘯'),
          ),
        ],
      ),
    );
  }
  
  /// 浠?Telegram 涓嬭浇濯掍綋
  Future<void> _downloadFromTelegram(String url) async {
    // 鏄剧ず涓嬭浇杩涘害瀵硅瘽妗?    double progress = 0.0;
    bool isDownloading = true;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('姝ｅ湪涓嬭浇'),
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
                    child: const Text('纭畾'),
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
            // 鏇存柊杩涘害
            progress = p;
            // 杩欓噷闇€瑕佹洿鏂板璇濇鐘舵€侊紝浣嗙敱浜?StatefulBuilder 鐨勯檺鍒讹紝
            // 鎴戜滑鍙兘闇€瑕佷娇鐢ㄥ叾浠栨柟娉曟潵鏇存柊杩涘害
          }
        },
      );
      
      isDownloading = false;
      if (mounted) {
        try {
          Navigator.pop(context); // 鍏抽棴杩涘害瀵硅瘽妗?        } catch (e) {
          // 蹇界暐瀵艰埅閿欒锛屽彲鑳芥槸鍥犱负widget宸茬粡琚攢姣?        }
      }
      
      if (result.success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('涓嬭浇鎴愬姛锛?{result.fileName}'),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: '鏌ョ湅',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const MediaManagerPage()),
                );
              },
            ),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('涓嬭浇澶辫触锛?{result.error}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      isDownloading = false;
      if (mounted) {
        try {
          Navigator.pop(context); // 鍏抽棴杩涘害瀵硅瘽妗?        } catch (navError) {
          // 蹇界暐瀵艰埅閿欒锛屽彲鑳芥槸鍥犱负widget宸茬粡琚攢姣?        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('涓嬭浇鍑洪敊锛?e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  /// 鍚姩Telegram娑堟伅杞
  Future<void> _startTelegramPolling() async {
    if (_isPollingActive) return;
    
    // 浠嶴haredPreferences鍔犺浇鏈€鍚庡鐞嗙殑鏇存柊ID
    await _loadLastUpdateId();
    
    _isPollingActive = true;
    _telegramPollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _checkForNewMessages();
    });
    
    debugPrint('Telegram娑堟伅杞宸插惎鍔紝鏈€鍚庢洿鏂癐D: $_lastUpdateId');
  }
  
  /// 鍋滄Telegram娑堟伅杞
  Future<void> _stopTelegramPolling() async {
    _telegramPollingTimer?.cancel();
    _telegramPollingTimer = null;
    _isPollingActive = false;
    
    // 淇濆瓨鏈€鍚庡鐞嗙殑鏇存柊ID
    await _saveLastUpdateId();
    
    debugPrint('Telegram娑堟伅杞宸插仠姝紝鏈€鍚庢洿鏂癐D: $_lastUpdateId');
  }
  
  /// 鍔犺浇鏈€鍚庡鐞嗙殑鏇存柊ID
  Future<void> _loadLastUpdateId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastUpdateId = prefs.getInt('telegram_last_update_id') ?? 0;
    } catch (e) {
      debugPrint('鍔犺浇鏈€鍚庢洿鏂癐D澶辫触: $e');
      _lastUpdateId = 0;
    }
  }
  
  /// 淇濆瓨鏈€鍚庡鐞嗙殑鏇存柊ID
  Future<void> _saveLastUpdateId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('telegram_last_update_id', _lastUpdateId);
    } catch (e) {
      debugPrint('淇濆瓨鏈€鍚庢洿鏂癐D澶辫触: $e');
    }
  }
  
  /// 鍔犺浇宸蹭笅杞界殑鏂囦欢ID
  Future<void> _loadDownloadedFileIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final downloadedIds = prefs.getStringList(_downloadedFileIdsKey) ?? [];
      _downloadedFileIds.clear();
      _downloadedFileIds.addAll(downloadedIds);
      debugPrint('宸插姞杞?{_downloadedFileIds.length}涓凡涓嬭浇鏂囦欢ID');
    } catch (e) {
      debugPrint('鍔犺浇宸蹭笅杞芥枃浠禝D澶辫触: $e');
    }
  }
  
  /// 淇濆瓨宸蹭笅杞界殑鏂囦欢ID
  Future<void> _saveDownloadedFileIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_downloadedFileIdsKey, _downloadedFileIds.toList());
    } catch (e) {
      debugPrint('淇濆瓨宸蹭笅杞芥枃浠禝D澶辫触: $e');
    }
  }
  
  /// 娣诲姞宸蹭笅杞界殑鏂囦欢ID
  Future<void> _addDownloadedFileId(String fileId) async {
    if (fileId.isEmpty) return;
    
    if (_downloadedFileIds.add(fileId)) {
      // 鍙湁褰撻泦鍚堝彂鐢熷彉鍖栨椂鎵嶄繚瀛?      await _saveDownloadedFileIds();
    }
  }
  
  /// 妫€鏌ユ柊娑堟伅
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
        
        // 鍙鐞嗘柊娑堟伅
        if (updateId > _lastUpdateId) {
          _lastUpdateId = updateId;
          hasNewUpdates = true;
          await _processUpdate(update);
        }
      }
      
      // 濡傛灉鏈夋柊娑堟伅锛屼繚瀛樻渶鍚庢洿鏂癐D
      if (hasNewUpdates) {
        await _saveLastUpdateId();
      }
    } catch (e) {
      debugPrint('妫€鏌ユ柊娑堟伅澶辫触: $e');
    }
  }
  
  /// 澶勭悊鍗曚釜鏇存柊
  Future<void> _processUpdate(Map<String, dynamic> update) async {
    try {
      final message = update['message'];
      if (message == null) return;
      
      // 妫€鏌ユ槸鍚︽湁濯掍綋鏂囦欢
      final mediaFileId = _extractMediaFileId(message);
      if (mediaFileId != null) {
        await _downloadMediaFromBot(mediaFileId, message);
      }
    } catch (e) {
      debugPrint('澶勭悊鏇存柊澶辫触: $e');
    }
  }
  
  /// 鎻愬彇濯掍綋鏂囦欢ID
  String? _extractMediaFileId(Map<String, dynamic> message) {
    // 妫€鏌ョ収鐗?    if (message['photo'] != null) {
      final photos = message['photo'] as List;
      if (photos.isNotEmpty) {
        // 鑾峰彇鏈€澶у昂瀵哥殑鐓х墖
        final largestPhoto = photos.reduce((a, b) => 
          (a['file_size'] ?? 0) > (b['file_size'] ?? 0) ? a : b);
        return largestPhoto['file_id'];
      }
    }
    
    // 妫€鏌ヨ棰?    if (message['video'] != null) {
      return message['video']['file_id'];
    }
    
    // 妫€鏌ュ姩鐢?GIF)
    if (message['animation'] != null) {
      return message['animation']['file_id'];
    }
    
    // 妫€鏌ユ枃妗?鍙兘鏄棰戞垨鍥剧墖)
    if (message['document'] != null) {
      final document = message['document'];
      final mimeType = document['mime_type'] ?? '';
      if (mimeType.startsWith('image/') || mimeType.startsWith('video/')) {
        return document['file_id'];
      }
    }
    
    return null;
  }
  
  /// 浠嶣ot涓嬭浇濯掍綋鏂囦欢
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
      // 妫€鏌ユ枃浠禝D鏄惁宸茬粡涓嬭浇杩?      if (_downloadedFileIds.contains(fileId)) {
        debugPrint('鏂囦欢宸插瓨鍦紝璺宠繃涓嬭浇: $fileId');
        return;
      }
      
      debugPrint('寮€濮嬩笅杞藉獟浣撴枃浠? $fileId');
      
      final result = await _telegramService.downloadFileById(
        fileId,
        onProgress: (progress) {
          debugPrint('涓嬭浇杩涘害: ${(progress * 100).toStringAsFixed(1)}%');
          if (mediaType == MediaType.video) { // Use the inferred mediaType
             _videoDownloadProgress.value = progress;
          }
        },
      );
      
      if (result.success && mounted) {
        // 濡傛灉鏄凡瀛樺湪鐨勬枃浠讹紝鏄剧ず涓嶅悓鐨勯€氱煡
        if (result.isExisting) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('鏂囦欢宸插瓨鍦細${result.fileName}'),
              backgroundColor: Colors.blue,
            ),
          );
          debugPrint('濯掍綋鏂囦欢宸插瓨鍦? ${result.fileName}');
        } else {
          // 鏄剧ず鎴愬姛閫氱煡
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('鑷姩涓嬭浇鎴愬姛锛?{result.fileName}'),
              backgroundColor: Colors.green,
              action: SnackBarAction(
                label: '鏌ョ湅',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const MediaManagerPage()),
                  );
                },
              ),
            ),
          );
          
          // 鍒锋柊濯掍綋搴?          await _refreshMediaLibrary();
          
          debugPrint('濯掍綋鏂囦欢涓嬭浇鎴愬姛: ${result.fileName}');
        }
        
        // 灏嗘枃浠禝D娣诲姞鍒板凡涓嬭浇闆嗗悎涓?        await _addDownloadedFileId(fileId);
      } else {
        debugPrint('濯掍綋鏂囦欢涓嬭浇澶辫触: ${result.error}');
      }
    } catch (e) {
      debugPrint('涓嬭浇濯掍綋鏂囦欢寮傚父: $e');
    } finally {
      if (mediaType == MediaType.video) {
        _isDownloadingVideo.value = false;
        _videoDownloadProgress.value = null;
      }
    }
  }
  
  /// 鍒锋柊濯掍綋搴?  Future<void> _refreshMediaLibrary() async {
    try {
      // 杩欓噷鍙互娣诲姞鍒锋柊濯掍綋搴撶殑閫昏緫
      // 渚嬪閫氱煡MediaManagerPage鍒锋柊鏁版嵁
    } catch (e) {
      debugPrint('鍒锋柊濯掍綋搴撳け璐? $e');
    }
  }

  /// 鏄剧ず瀵煎叆瀵煎嚭鑿滃崟
  void _showExportImportMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('瀵煎嚭娴忚鍣ㄦ暟鎹?),
              subtitle: const Text('瀵煎嚭涔︾鍜屽父鐢ㄧ綉绔?),
              onTap: () {
                Navigator.pop(context);
                _exportBrowserData();
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('瀵煎叆娴忚鍣ㄦ暟鎹?),
              subtitle: const Text('瀵煎叆涔︾鍜屽父鐢ㄧ綉绔?),
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

  /// 瀵煎嚭娴忚鍣ㄦ暟鎹?  Future<void> _exportBrowserData() async {
    try {
      // 鍒涘缓杩涘害閫氱煡鍣?      final ValueNotifier<String> progressNotifier = ValueNotifier<String>('鍑嗗瀵煎嚭娴忚鍣ㄦ暟鎹?..');
      
      // 鏄剧ず杩涘害瀵硅瘽妗?      showDialog(
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

      // 鑾峰彇瀵煎嚭鐩綍
      final Directory? externalDir = await getExternalStorageDirectory();
      if (externalDir == null) {
        throw Exception('鏃犳硶璁块棶澶栭儴瀛樺偍鐩綍');
      }

      final String exportDir = '${externalDir.path}/browser_backups';
      final Directory backupDir = Directory(exportDir);
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      progressNotifier.value = '鏀堕泦娴忚鍣ㄦ暟鎹?..';

      // 鏀堕泦娴忚鍣ㄦ暟鎹?      final Map<String, dynamic> browserData = {
        'bookmarks': _bookmarks,
        'common_websites': _commonWebsites,
        'export_time': DateTime.now().toIso8601String(),
        'version': '1.0',
      };

      progressNotifier.value = '鍒涘缓鏁版嵁鏂囦欢...';

      // 鍒涘缓JSON鏂囦欢
      final String jsonPath = '$exportDir/browser_data.json';
      final File jsonFile = File(jsonPath);
      await jsonFile.writeAsString(jsonEncode(browserData));

      progressNotifier.value = '鍒涘缓ZIP鏂囦欢...';

      // 鍒涘缓ZIP鏂囦欢
      final String zipPath = '$exportDir/browser_backup_${DateTime.now().millisecondsSinceEpoch}.zip';
      final Archive archive = Archive();
      archive.addFile(ArchiveFile('browser_data.json', jsonFile.lengthSync(), jsonFile.readAsBytesSync()));
      final List<int> zipData = ZipEncoder().encode(archive);

      if (zipData == null) {
        throw Exception('鍒涘缓ZIP鏂囦欢澶辫触');
      }

      final File zipFile = File(zipPath);
      await zipFile.writeAsBytes(zipData);

      // 鍒犻櫎涓存椂JSON鏂囦欢
      await jsonFile.delete();

      progressNotifier.value = '导出完成';

      // 鍏抽棴杩涘害瀵硅瘽妗?      if (mounted) {
        Navigator.pop(context);
      }

      // 鍒嗕韩鏂囦欢
      await Share.shareXFiles(
        [XFile(zipPath)],
        subject: '浏览器数据备份',
        text: '浏览器数据备份文件，包含书签和常用网站数据',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('娴忚鍣ㄦ暟鎹鍑烘垚鍔燂紒鏂囦欢宸蹭繚瀛樺埌: ${zipPath.split('/').last}'),
            action: SnackBarAction(
              label: '鎵撳紑鏂囦欢',
              onPressed: () async {
                // 鎵撳紑鏂囦欢绠＄悊鍣ㄥ埌瀵煎嚭鐩綍
                final result = await FilePicker.platform.clearTemporaryFiles();
                debugPrint('娓呯悊涓存椂鏂囦欢缁撴灉: $result');
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('瀵煎嚭娴忚鍣ㄦ暟鎹椂鍑洪敊: $e');
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出浏览器数据时出错: ')),
        );
      }
    }
  }

  /// 瀵煎叆娴忚鍣ㄦ暟鎹?  Future<void> _importBrowserData() async {
    try {
      // 鏄剧ず璀﹀憡瀵硅瘽妗?      bool? confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: const Text('导入浏览器数据将会覆盖当前的书签和常用网站，确定要继续吗？'),
          
          actions: [
            TextButton(
              child: const Text('鍙栨秷'),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: const Text('纭畾'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      // 閫夋嫨ZIP鏂囦欢
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (result != null && result.files.single.path != null) {
        // 鍒涘缓杩涘害閫氱煡鍣?        final ValueNotifier<String> progressNotifier = ValueNotifier<String>('鍑嗗瀵煎叆...');
        
        // 鏄剧ず杩涘害瀵硅瘽妗?        showDialog(
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

        progressNotifier.value = '瑙ｅ帇鏂囦欢...';

        // 璇诲彇ZIP鏂囦欢
        final File zipFile = File(result.files.single.path!);
        final List<int> zipBytes = await zipFile.readAsBytes();
        final Archive? archive = ZipDecoder().decodeBytes(zipBytes);

        if (archive == null) {
          throw Exception('鏃犳硶瑙ｆ瀽ZIP鏂囦欢');
        }

        progressNotifier.value = '瑙ｆ瀽鏁版嵁...';

        // 鏌ユ壘骞惰В鏋怞SON鏂囦欢
        ArchiveFile? jsonFile;
        for (final file in archive) {
          if (file.name == 'browser_data.json') {
            jsonFile = file;
            break;
          }
        }

        if (jsonFile == null) {
          throw Exception('ZIP鏂囦欢涓湭鎵惧埌娴忚鍣ㄦ暟鎹枃浠?);
        }

        // 瑙ｆ瀽JSON鏁版嵁
        final String jsonContent = utf8.decode(jsonFile.content as List<int>);
        final Map<String, dynamic> browserData = jsonDecode(jsonContent);

        progressNotifier.value = '瀵煎叆鏁版嵁...';

        // 楠岃瘉鏁版嵁鏍煎紡
        if (browserData['version'] == null) {
          throw Exception('鏁版嵁鏍煎紡涓嶆敮鎸侊紝缂哄皯鐗堟湰淇℃伅');
        }

        // 瀵煎叆涔︾
        if (browserData['bookmarks'] != null) {
          final List<dynamic> bookmarksData = browserData['bookmarks'];
          setState(() {
            _bookmarks = bookmarksData.map((item) => Map<String, String>.from(item)).toList();
          });
          await _saveBookmarks();
        }

        // 瀵煎叆甯哥敤缃戠珯
        if (browserData['common_websites'] != null) {
          final List<dynamic> websitesData = browserData['common_websites'];
          setState(() {
            _commonWebsites.clear();
            for (final item in websitesData) {
              final Map<String, dynamic> website = Map<String, dynamic>.from(item);
              // 鍙繚瀛?iconCode锛屼笉鍔ㄦ€佸垱寤?IconData 瀹炰緥
              if (website['iconCode'] == null) {
                website['iconCode'] = Icons.public.codePoint;
              }
              _commonWebsites.add(website);
            }
          });
          await _saveCommonWebsites();
        }

        progressNotifier.value = '导入完成';

        // 鍏抽棴杩涘害瀵硅瘽妗?        if (mounted) {
          Navigator.pop(context);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('娴忚鍣ㄦ暟鎹鍏ユ垚鍔燂紒'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('瀵煎叆娴忚鍣ㄦ暟鎹椂鍑洪敊: $e');
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入浏览器数据时出错: ')),
        );
      }
    }
  }

  // 8. 鍘嗗彶璁板綍寮圭獥
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
                title: const Text('娓呯┖鍏ㄩ儴鍘嗗彶璁板綍'),
                onTap: () async {
                  Navigator.pop(context);
                  _history.clear();
                  await _saveHistory();
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('历史记录已清空')));
                },
              ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final item = _history[index];
                    return ListTile(
                      title: Text(item['title'] ?? item['url']),
                      subtitle: Text(item['url']),
                      trailing: Text(item['datetime']?.substring(0, 19).replaceAll('T', ' ') ?? ''),
                      onTap: () {
                        Navigator.pop(context);
                        _loadUrl(item['url']);
                      },
                      onLongPress: () async {
                        _history.removeAt(index);
                        await _saveHistory();
                        setState(() {});
                      },
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

  // 鏍规嵁 iconCode 鑾峰彇瀵瑰簲鐨勫浘鏍囷紙浣跨敤甯搁噺鏄犲皠閬垮厤鍔ㄦ€佸垱寤猴級
  IconData _getIconFromCode(int? iconCode) {
    if (iconCode == null) return Icons.public;
    
    // 浣跨敤甯搁噺鍥炬爣鏄犲皠锛岄伩鍏嶅姩鎬佸垱寤?IconData
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
      default: return Icons.public; // 榛樿鍥炬爣
    }
  }

  // 椤甸潰鍔犺浇瀹屾垚鍚庣殑澶勭悊
  void _onPageFinished(String url) async {
    try {
      // 娉ㄥ叆濯掍綋涓嬭浇澶勭悊绋嬪簭
      _injectDownloadHandlers();
      
      // 娣诲姞鍘嗗彶璁板綍
      String title = await _controller.getTitle() ?? url;
      await _addHistory(title, url);
      
      // 鏇存柊鐘舵€?      setState(() {
        _isLoading = false;
        _currentUrl = url;
        _urlController.text = url;
        _showHomePage = false;
      });
      
      // 閫氱煡鐖剁粍浠舵祻瑙堝櫒鐘舵€佸彉鍖?      widget.onBrowserHomePageChanged?.call(_showHomePage);
      
      debugPrint('椤甸潰鍔犺浇瀹屾垚: $url, 鏍囬: $title');
    } catch (e) {
      debugPrint('椤甸潰鍔犺浇瀹屾垚澶勭悊鏃跺嚭閿? $e');
    }
  }
}



