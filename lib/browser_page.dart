import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
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

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'models/media_item.dart';
import 'models/media_type.dart';
import 'main.dart'; // 添加导入以访问MainScreen

class BrowserPage extends StatefulWidget {
  // Define the callback parameter
  final ValueChanged<bool>? onBrowserHomePageChanged;

  const BrowserPage({Key? key, this.onBrowserHomePageChanged}) : super(key: key);

  @override
  _BrowserPageState createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> with AutomaticKeepAliveClientMixin {
  // Add mixin for state persistence
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
  
  // 控制是否显示首页（常用网站列表）
  bool _showHomePage = true;
  
  // 添加状态变量，记录是否正在浏览具体网页
  bool _isBrowsingWebPage = false;
  
  // 添加状态变量，记录是否应该保持网页状态
  bool _shouldKeepWebPageState = false;
  
  // 添加状态变量，记录上次浏览的URL，用于恢复
  String? _lastBrowsedUrl;
  
  // 常用网站列表数据
  final List<Map<String, dynamic>> _commonWebsites = [
    {'name': 'Google', 'url': 'https://www.google.com', 'icon': Icons.search},
    {'name': 'Edge', 'url': 'https://www.microsoft.com/edge', 'icon': Icons.web},
    {'name': 'X', 'url': 'https://twitter.com', 'icon': Icons.chat},
    {'name': 'Facebook', 'url': 'https://www.facebook.com', 'icon': Icons.facebook},
    {'name': 'Telegram', 'url': 'https://web.telegram.org', 'icon': Icons.send},
    {'name': '百度', 'url': 'https://www.baidu.com', 'icon': Icons.search},
  ];
  
  // 是否处于编辑模式
  bool _isEditMode = false;
  
  // 添加、删除和重新排序网站的方法
  Future<void> _toggleEditMode() async {
    final wasInEditMode = _isEditMode;
    setState(() {
      _isEditMode = !_isEditMode;
    });
    
    // 如果从编辑模式退出，确保保存网站列表
    if (wasInEditMode && !_isEditMode) {
      debugPrint('从编辑模式退出，保存网站列表');
      // 显示保存中提示
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在保存常用网站...')),
      );
      
      await _saveCommonWebsites();
      
      // 显示保存成功提示
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('常用网站已保存')),
      );
    }
  }

  // 删除网站并确保保存成功
  Future<void> _removeWebsite(int index) async {
    final removedSite = _commonWebsites[index]['name'];
    setState(() {
      _commonWebsites.removeAt(index);
    });
    // 确保等待保存完成
    await _saveCommonWebsites();
    debugPrint('已删除并保存网站: $removedSite');
  }

  // 移动网站并确保保存成功
  Future<void> _reorderWebsites(int oldIndex, int newIndex) async {
    setState(() {
      if (oldIndex < newIndex) {
        newIndex -= 1;
      }
      final item = _commonWebsites.removeAt(oldIndex);
      _commonWebsites.insert(newIndex, item);
    });
    // 确保等待保存完成
    await _saveCommonWebsites();
    debugPrint('已移动并保存网站从位置 $oldIndex 到 $newIndex');
  }

  // 添加网站并确保保存成功
  Future<void> _addWebsite(String name, String url, IconData icon) async {
    setState(() {
      // 存储图标的代码点而不是IconData对象
      _commonWebsites.add({'name': name, 'url': url, 'iconCode': icon.codePoint});
    });
    // 确保等待保存完成
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
      // 设置移动版用户代理，使网站默认显示为手机版
      ..setUserAgent('Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.162 Mobile Safari/537.36')
      // 启用JavaScript和DOM存储
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // 配置WebView设置
      ..setBackgroundColor(const Color(0x00000000))
      // 禁用水平滚动，只允许垂直滚动
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
              _showHomePage = false; // 页面开始加载时隐藏首页
            });
          },
          onPageFinished: (url) {
            setState(() {
              _isLoading = false;
              _currentUrl = url;
            });
            // 注入JavaScript以启用表单自动填充和Cookie支持
            _controller.runJavaScript('''
              document.querySelectorAll('input').forEach(function(input) {
                input.autocomplete = 'on';
              });
            ''');
            
            // 为电报网站注入特殊的JavaScript，以增强媒体下载功能
            if (url.contains('telegram.org') || url.contains('t.me') || url.contains('web.telegram.org')) {
              _injectTelegramDownloadHandlers();
            }
          },
          onWebResourceError: (error) {
            debugPrint('WebView错误: ${error.description}');
            // 不再显示错误信息给用户
            // 只保留日志记录，去除错误提示
          },
          // 使用onNavigationRequest处理下载请求
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            debugPrint('导航请求: $url');
            
            // 检查URL是否为可能的下载链接
            if (_isDownloadableLink(url)) {
              debugPrint('检测到可能的下载链接: $url');
              _handleDownload(url, '', _guessMimeType(url));
              return NavigationDecision.prevent; // 阻止WebView导航，由我们处理下载
            }
            
            // 特殊处理电报媒体链接
            if (_isTelegramMediaLink(url)) {
              debugPrint('检测到电报媒体链接: $url');
              _handleDownload(url, '', _guessMimeType(url));
              return NavigationDecision.prevent; // 阻止WebView导航，由我们处理下载
            }
            
            return NavigationDecision.navigate; // 允许WebView导航
          },
        ),
      )
      // 启用本地存储
      ..addJavaScriptChannel(
        'Flutter', 
        onMessageReceived: (JavaScriptMessage message) {
          debugPrint('来自JavaScript的消息: ${message.message}');
          // 处理从JavaScript发送的消息，特别是媒体下载请求
          _handleJavaScriptMessage(message.message);
        },
      );
    // 不再在初始化时立即加载URL
  }
  
  // 检查URL是否为电报媒体链接
  bool _isTelegramMediaLink(String url) {
    // 电报媒体链接通常包含这些模式
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
      if (url.contains(pattern)) {
        return true;
      }
    }
    
    // 检查URL是否包含常见媒体文件扩展名
    if (url.contains('telegram') || url.contains('t.me')) {
      final mediaExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.mp4', '.webp', '.webm'];
      for (final ext in mediaExtensions) {
        if (url.toLowerCase().contains(ext)) {
          return true;
        }
      }
    }
    
    return false;
  }
  
  // 为电报网站注入特殊的JavaScript，以增强媒体下载功能
  void _injectTelegramDownloadHandlers() {
    debugPrint('为电报网站注入媒体下载处理程序');
    _controller.runJavaScript('''
      // 监听所有图片点击事件
      document.addEventListener('click', function(e) {
        // 查找点击事件路径中的图片元素
        let target = e.target;
        while (target != null) {
          if (target.tagName === 'IMG') {
            let imgSrc = target.src;
            if (imgSrc) {
              // 发送图片URL到Flutter
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: 'image',
                url: imgSrc
              }));
            }
            break;
          } else if (target.tagName === 'VIDEO') {
            let videoSrc = target.src || (target.querySelector('source') ? target.querySelector('source').src : null);
            if (videoSrc) {
              // 发送视频URL到Flutter
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: 'video',
                url: videoSrc
              }));
            }
            break;
          }
          target = target.parentElement;
        }
      }, true);
      
      // 监听所有媒体元素的右键菜单
      document.addEventListener('contextmenu', function(e) {
        let target = e.target;
        if (target.tagName === 'IMG' || target.tagName === 'VIDEO') {
          let mediaUrl = target.src || (target.querySelector('source') ? target.querySelector('source').src : null);
          if (mediaUrl) {
            // 发送媒体URL到Flutter
            Flutter.postMessage(JSON.stringify({
              type: 'media',
              mediaType: target.tagName === 'IMG' ? 'image' : 'video',
              url: mediaUrl
            }));
          }
        }
      }, true);
      
      // 查找并监听所有下载按钮
      setInterval(function() {
        document.querySelectorAll('a[download], a[href*="/file/"], a[href*="/media/"], button:contains("Download"), button:contains("下载")').forEach(function(element) {
          if (!element.hasAttribute('data-download-monitored')) {
            element.setAttribute('data-download-monitored', 'true');
            element.addEventListener('click', function(e) {
              let url = element.href || element.getAttribute('data-url') || element.getAttribute('data-src');
              if (url) {
                Flutter.postMessage(JSON.stringify({
                  type: 'download',
                  url: url
                }));
              }
            });
          }
        });
      }, 1000);
    ''');
  }
  
  // 处理从JavaScript发送的消息
  void _handleJavaScriptMessage(String message) {
    try {
      final data = jsonDecode(message);
      if (data is Map && data.containsKey('type')) {
        final type = data['type'];
        if (type == 'media' || type == 'download') {
          final url = data['url'];
          if (url != null && url is String) {
            debugPrint('从JavaScript接收到媒体URL: $url');
            final mediaType = data['mediaType'] ?? '';
            String mimeType = 'application/octet-stream';
            if (mediaType == 'image') {
              mimeType = 'image/jpeg';
            } else if (mediaType == 'video') {
              mimeType = 'video/mp4';
            }
            _handleDownload(url, '', mimeType);
          }
        }
      }
    } catch (e) {
      debugPrint('处理JavaScript消息时出错: $e');
    }
  }

  // 修改加载URL的方法
  void _loadUrl(String url) {
    String processedUrl = url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      processedUrl = 'https://$url';
    }
    
    // 为电报网站设置特殊处理，强制使用移动版
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
    // Notify parent about the state change: no longer home page
    widget.onBrowserHomePageChanged?.call(_showHomePage);
    debugPrint('[_loadUrl] Called onBrowserHomePageChanged(${_showHomePage})');
  }

  // 修改返回首页的方法
  Future<void> _goToHomePage() async {
    debugPrint('[_goToHomePage] Called. Current _showHomePage: $_showHomePage');
    // Only go to home page if not already there
    if (!_showHomePage) {
      // Save current common websites state
      await _saveCommonWebsites();
      debugPrint('[_goToHomePage] 已保存常用网站');

      // Reload bookmarks and common websites
      await _loadBookmarks();
      await _loadCommonWebsites();
      debugPrint('[_goToHomePage] 已重新加载书签和常用网站');

      // Switch to common websites home view, keep web view instance state
      setState(() {
        _showHomePage = true; // Show common websites home view
        debugPrint('[_goToHomePage] setState _showHomePage = true');
        // _isBrowsingWebPage and _shouldKeepWebPageState keep current value
      });

      // Notify parent about the state change: now home page
      widget.onBrowserHomePageChanged?.call(_showHomePage);
      debugPrint('[_goToHomePage] Called onBrowserHomePageChanged(${_showHomePage})');

      debugPrint('[_goToHomePage] 已返回常用网站首页视图，保持网页实例状态');
    }
  }

  // 修改恢复网页浏览的方法 (called by the floating action button)
  void _restoreWebPage() {
    debugPrint('[_restoreWebPage] Called. Current _showHomePage: $_showHomePage, _isBrowsingWebPage: $_isBrowsingWebPage, _shouldKeepWebPageState: $_shouldKeepWebPageState');
    // Only restore if currently on home page and a web page was previously browsed and kept
    if (_showHomePage && _isBrowsingWebPage && _shouldKeepWebPageState) {
      setState(() {
        _showHomePage = false; // Switch back to web view
        debugPrint('[_restoreWebPage] setState _showHomePage = false');
      });
      // Notify parent about the state change: no longer home page
      widget.onBrowserHomePageChanged?.call(_showHomePage);
      debugPrint('[_restoreWebPage] Called onBrowserHomePageChanged(${_showHomePage})');
      debugPrint('[_restoreWebPage] 恢复网页浏览状态');
    } else {
      debugPrint('[_restoreWebPage] Cannot restore web page. State: _showHomePage: $_showHomePage, _isBrowsingWebPage: $_isBrowsingWebPage, _shouldKeepWebPageState: $_shouldKeepWebPageState');
    }
  }

  // 修改完全退出网页的方法 (called by the red X button)
  void _exitWebPage() {
    debugPrint('[_exitWebPage] Called.');
    // Clean up web view state and return to common websites home view
    setState(() {
      _showHomePage = true; // Show common websites home
      _isBrowsingWebPage = false; // Not browsing a specific web page anymore
      _shouldKeepWebPageState = false; // No need to keep web view state
      _lastBrowsedUrl = null; // Clear last browsed URL

      // Clear WebView history, cache, and local storage to ensure full reset
      _controller.clearCache();
      _controller.clearLocalStorage();
      debugPrint('[_exitWebPage] setState _showHomePage = true, states reset');
      // Reset current URL and address bar text
      _currentUrl = 'https://www.baidu.com'; // Or other default URL
      _urlController.text = _currentUrl;
    });
    // Notify parent about the state change: now home page
    widget.onBrowserHomePageChanged?.call(_showHomePage);
    debugPrint('[_exitWebPage] Called onBrowserHomePageChanged(${_showHomePage})');
    debugPrint('[_exitWebPage] Completely exited web view and returned to common websites home view');
  }

  // 构建常用网站列表页面
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
                           // 显示加载指示器
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

                            // 切换编辑模式并等待完成
                            await _toggleEditMode();

                            // 关闭加载指示器
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
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(                        crossAxisCount: 3,
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
        // 添加返回网页的浮动操作按钮，只在有未退出网页时显示
        if (_isBrowsingWebPage && _shouldKeepWebPageState)
          Positioned(
            bottom: 16.0, // 调整位置
            right: 16.0,
            child: FloatingActionButton(
              onPressed: () {
                _restoreWebPage(); // 切换回网页视图
              },
              tooltip: '返回上次浏览的网页',
              child: const Icon(Icons.arrow_right_alt), // 修改图标为向右的箭头
            ),
          ),
      ],
    );
  }

  // 显示添加网站对话框
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
                // 显示加载指示器
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
                
                // 等待添加网站完成
                await _addWebsite(nameController.text, urlController.text, Icons.web);
                
                // 立即保存网站列表
                await _saveCommonWebsites();
                debugPrint('网站已添加并立即保存');
                
                // 关闭加载指示器和对话框
                Navigator.of(context).pop(); // 关闭加载指示器
                Navigator.of(context).pop(); // 关闭添加网站对话框
                
                // 显示成功消息
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('网站已添加并保存')),
                );
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  // 修改构建可编辑的网站列表项的方法，统一图标
  Widget _buildEditableWebsiteItem(Map<String, dynamic> website, int index) {
    // 使用统一的网络图标
    IconData iconData = Icons.public; // 统一使用网络图标

    return ListTile(
      key: ValueKey(website['url']),
      leading: Icon(iconData),
      title: Text(website['name']),
      subtitle: Text(website['url']),
      trailing: IconButton(
        icon: const Icon(Icons.delete, color: Colors.red),
        onPressed: () async {
          // 显示确认对话框
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
            // 显示加载指示器
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

            // 等待删除网站完成
            await _removeWebsite(index);

            // 关闭加载指示器
            Navigator.of(context).pop();

            // 显示成功消息
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('网站已删除')),
            );
          }
        },
      ),
    );
  }

  // 修改构建网站卡片的方法，统一图标
  Widget _buildWebsiteCard(Map<String, dynamic> website) {
    // 使用统一的网络图标
    IconData iconData = Icons.public; // 统一使用网络图标

    return InkWell(
      onTap: () => _loadUrl(website['url']),
      child: Card(
        elevation: 4.0,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              iconData,
              size: 40,
              color: Theme.of(context).primaryColor,
            ),
            const SizedBox(height: 8),
            Text(
              website['name'],
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // 修改加载常用网站的方法
  Future<void> _loadBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookmarksList = prefs.getStringList('bookmarks');

      setState(() {
        if (bookmarksList != null && bookmarksList.isNotEmpty) {
          _bookmarks.clear();
          _bookmarks.addAll(bookmarksList);
        } else if (_bookmarks.isEmpty) {
          // 默认书签
          _bookmarks.addAll(['https://www.baidu.com', 'https://www.bilibili.com']);
          _saveBookmarks(); // 保存默认书签
        }
      });

      debugPrint('Successfully loaded ${_bookmarks.length} bookmarks');

      // Load common websites is now in _loadCommonWebsites method

    } catch (e) {
      debugPrint('Error loading bookmarks: $e');
    }
  }

  // 修改保存常用网站的方法
  Future<void> _saveCommonWebsites() async {
    try {
      debugPrint('Starting to save common websites...');
      final prefs = await SharedPreferences.getInstance();

      // Ensure all website data format is consistent, save only necessary fields, and unify iconCode
      final cleanedWebsites = _commonWebsites.map((site) {
        return {
          'name': site['name'],
          'url': site['url'],
          'iconCode': Icons.public.codePoint, // Unify to public web icon code point
        };
      }).toList();

      final jsonString = jsonEncode(cleanedWebsites);
      debugPrint('Common websites JSON: $jsonString');

      // Clear old data first, then save new data
      await prefs.remove('common_websites');
      final result = await prefs.setString('common_websites', jsonString);

      if (result) {
        debugPrint('Common websites saved successfully');
      } else {
        debugPrint('Common websites save failed: SharedPreferences returned false');
      }
    } catch (e) {
      debugPrint('Error saving common websites: $e');
      debugPrintStack(label: 'Save common websites error stack');
    }
  }

  Future<void> _handleDownload(String url, String contentDisposition, String mimeType) async {
    try {
      debugPrint('开始处理下载: $url, MIME类型: $mimeType');
      
      // 处理电报特殊URL
      String processedUrl = url;
      if (url.contains('telegram.org') || url.contains('t.me')) {
        if (!url.startsWith('http')) {
          if (url.startsWith('//')) {
            processedUrl = 'https:$url';
          } else {
            processedUrl = 'https://$url';
          }
        }
        debugPrint('处理后的电报URL: $processedUrl');
      }
      
      // 显示下载选项对话框
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => _buildDownloadDialog(processedUrl, mimeType),
      );

      if (result != null) {
        final bool shouldDownload = result['download'];
        final MediaType mediaType = result['mediaType'];

        if (shouldDownload) {
          // 显示一个简单的提示，表明下载已开始
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('开始下载，将在后台进行...'),
              duration: Duration(seconds: 2),
            ),
          );

          // 在后台执行下载
          unawaited(_performBackgroundDownload(processedUrl, mediaType));
        }
      }
    } catch (e, stackTrace) {
      debugPrint('处理下载时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载出错: $e')),
        );
      }
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
              onChanged: (value) {
                setState(() => selectedType = value!);
              },
            ),
            RadioListTile<MediaType>(
              title: const Text('视频'),
              value: MediaType.video,
              groupValue: selectedType,
              onChanged: (value) {
                setState(() => selectedType = value!);
              },
            ),
            RadioListTile<MediaType>(
              title: const Text('音频'),
              value: MediaType.audio,
              groupValue: selectedType,
              onChanged: (value) {
                setState(() => selectedType = value!);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop({
              'download': true,
              'mediaType': selectedType,
            }),
            child: const Text('下载'),
          ),
        ],
      ),
    );
  }

  MediaType _determineMediaType(String mimeType) {
    if (mimeType.startsWith('image/')) {
      return MediaType.image;
    } else if (mimeType.startsWith('video/')) {
      return MediaType.video;
    } else if (mimeType.startsWith('audio/')) {
      return MediaType.audio;
    }
    // 默认为图片
    return MediaType.image;
  }
  
  // 检查URL是否为可能的下载链接
  bool _isDownloadableLink(String url) {
    debugPrint('检查URL是否为可下载链接: $url');
    
    // 检查文件扩展名
    final fileExtensions = [
      // 图片
      '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico',
      // 视频
      '.mp4', '.avi', '.mov', '.wmv', '.flv', '.mkv', '.webm', '.m3u8', '.ts',
      // 音频
      '.mp3', '.wav', '.ogg', '.aac', '.flac', '.m4a',
      // 文档
      '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt',
      // 压缩文件
      '.zip', '.rar', '.7z', '.tar', '.gz',
      // 其他常见下载文件
      '.exe', '.apk', '.dmg', '.iso'
    ];
    
    final lowercaseUrl = url.toLowerCase();
    for (final ext in fileExtensions) {
      if (lowercaseUrl.endsWith(ext)) {
        debugPrint('URL以文件扩展名结尾: $ext');
        return true;
      }
    }
    
    // 检查URL中是否包含明确的下载相关关键词（更严格的条件）
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
    
    // 检查URL参数中是否包含明确的下载相关参数
    final downloadParams = ['download=true', 'dl=1', 'attachment=1'];
    final uri = Uri.parse(url);
    final queryString = uri.query.toLowerCase();
    for (final param in downloadParams) {
      if (queryString.contains(param)) {
        debugPrint('URL参数中包含明确的下载相关参数: $param');
        return true;
      }
    }
    
    // 特殊处理电报链接
    if (url.contains('telegram.org') || url.contains('t.me')) {
      // 检查电报特定的媒体链接模式（更精确的模式）
      final telegramMediaPatterns = [
        '/file/', '/photo/size', '/video/size', '/document/'
      ];
      
      for (final pattern in telegramMediaPatterns) {
        if (lowercaseUrl.contains(pattern)) {
          debugPrint('检测到电报媒体链接模式: $pattern');
          return true;
        }
      }
    }
    
    return false;
  }
  
  // 根据URL猜测MIME类型
  String _guessMimeType(String url) {
    final uri = Uri.parse(url);
    final path = uri.path.toLowerCase();
    
    // 图片
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.gif')) return 'image/gif';
    if (path.endsWith('.bmp')) return 'image/bmp';
    if (path.endsWith('.webp')) return 'image/webp';
    
    // 视频
    if (path.endsWith('.mp4')) return 'video/mp4';
    if (path.endsWith('.avi')) return 'video/x-msvideo';
    if (path.endsWith('.mov')) return 'video/quicktime';
    if (path.endsWith('.wmv')) return 'video/x-ms-wmv';
    if (path.endsWith('.flv')) return 'video/x-flv';
    if (path.endsWith('.mkv')) return 'video/x-matroska';
    if (path.endsWith('.webm')) return 'video/webm';
    
    // 音频
    if (path.endsWith('.mp3')) return 'audio/mpeg';
    if (path.endsWith('.wav')) return 'audio/wav';
    if (path.endsWith('.ogg')) return 'audio/ogg';
    if (path.endsWith('.aac')) return 'audio/aac';
    if (path.endsWith('.flac')) return 'audio/flac';
    
    // 默认返回二进制流
    return 'application/octet-stream';
  }

  Future<File?> _downloadFile(String url) async {
    try {
      debugPrint('开始下载文件，URL: $url');
      final dio = Dio();
      
      // 设置Dio选项，增加超时时间和特殊的用户代理
      dio.options.connectTimeout = const Duration(seconds: 30);
      dio.options.receiveTimeout = const Duration(seconds: 60);
      dio.options.headers = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
        'Accept': '*/*',
      };
      
      // 如果是电报网站，添加特殊的请求头
      if (url.contains('telegram.org') || url.contains('t.me')) {
        dio.options.headers['Referer'] = 'https://web.telegram.org/';
        dio.options.headers['Origin'] = 'https://web.telegram.org';
      }
      
      // 创建媒体目录
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }

      // 生成唯一文件名
      final uuid = const Uuid().v4();
      final uri = Uri.parse(url);
      String extension = _getFileExtension(uri.path);
      
      // 如果没有扩展名，根据URL或MIME类型猜测
      if (extension.isEmpty) {
        final mimeType = _guessMimeType(url);
        if (mimeType.startsWith('image/')) {
          extension = '.jpg';
        } else if (mimeType.startsWith('video/')) {
          extension = '.mp4';
        } else if (mimeType.startsWith('audio/')) {
          extension = '.mp3';
        } else {
          extension = '.bin'; // 默认二进制文件扩展名
        }
        debugPrint('URL没有扩展名，根据MIME类型猜测为: $extension');
      }
      
      final filePath = '${mediaDir.path}/$uuid$extension';
      debugPrint('将下载到文件路径: $filePath');

      // 执行下载
      final response = await dio.download(
        url, 
        filePath,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            final progress = received / total;
            debugPrint('下载进度: ${(progress * 100).toStringAsFixed(2)}%');
          }
        },
      );
      
      debugPrint('下载响应状态码: ${response.statusCode}');
      
      // 验证文件是否存在且大小大于0
      final file = File(filePath);
      if (await file.exists()) {
        final fileSize = await file.length();
        debugPrint('文件下载完成，大小: ${fileSize} 字节');
        if (fileSize > 0) {
          return file;
        } else {
          debugPrint('文件大小为0，下载可能失败');
          await file.delete();
          return null;
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
    if (lastDot != -1) {
      return path.substring(lastDot);
    }
    return ''; // 如果没有扩展名
  }

  Future<void> _saveToMediaLibrary(File file, MediaType mediaType) async {
    try {
      final fileName = file.path.split('/').last;
      final fileHash = await _calculateFileHash(file);

      // 检查是否存在重复文件
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
        directory: 'root', // 保存到根目录
        dateAdded: DateTime.now(),
      );

      // 将文件哈希值添加到数据库记录中
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
      final hash = md5.convert(bytes);
      return hash.toString();
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
      _saveBookmarks(); // 保存书签
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已添加书签')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书签已存在')),
      );
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
                _saveBookmarks(); // 保存更改
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已删除书签')),
                );
              },
            ),
          );
        },
      ),
    );
  }

  // Add _saveBookmarks method - Attempting to re-add this missing method
  Future<void> _saveBookmarks() async {
    try {
      debugPrint('Starting to save bookmarks...');
      final prefs = await SharedPreferences.getInstance();
      final result = await prefs.setStringList('bookmarks', _bookmarks);
      if (result) {
        debugPrint('Bookmarks saved successfully');
      } else {
        debugPrint('Bookmark save failed: SharedPreferences returned false');
      }
    } catch (e) {
      debugPrint('Error saving bookmarks: $e');
      debugPrintStack(label: 'Bookmark save error stack');
    }
  }

  // Add _loadCommonWebsites method
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
            'iconCode': Icons.public.codePoint, // Ensure a default iconCode is present
          }).toList());
        });
        debugPrint('Successfully loaded ${_commonWebsites.length} common websites');
      } else if (_commonWebsites.isEmpty) { // Use default if nothing loaded and list is empty
        debugPrint('No common websites found, using defaults.');
         setState(() {
          _commonWebsites.clear();
          // Use code points instead of IconData objects, but unify to public web icon
          _commonWebsites.addAll([
            {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
            {'name': 'Edge', 'url': 'https://www.bing.com', 'iconCode': Icons.public.codePoint},
            {'name': 'X', 'url': 'https://twitter.com', 'iconCode': Icons.public.codePoint},
            {'name': 'Facebook', 'url': 'https://www.facebook.com', 'iconCode': Icons.public.codePoint},
            {'name': 'Telegram', 'url': 'https://web.telegram.org', 'iconCode': Icons.public.codePoint},
            {'name': '百度', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint}
          ]);
        });
        await _saveCommonWebsites(); // Save the default list
        debugPrint('Saved default common websites.');
      }
    } catch (e) {
      debugPrint('Error loading common websites: $e');
       // Clear potentially corrupted data on error
       final prefs = await SharedPreferences.getInstance();
       await prefs.remove('common_websites');
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[_BrowserPage.build] _showHomePage: $_showHomePage, _isBrowsingWebPage: $_isBrowsingWebPage, _shouldKeepWebPageState: $_shouldKeepWebPageState');

    super.build(context); // Required for AutomaticKeepAliveClientMixin

    return WillPopScope(
      // Handle Android physical back button events
      onWillPop: () async {
        debugPrint('[_WillPopScope] onWillPop called. Current _showHomePage: $_showHomePage');
        if (!_showHomePage) {
          // If currently in web view
          // Try to go back within the web view
          if (await _controller.canGoBack()) {
            debugPrint('[_WillPopScope] canGoBack is true, going back in webview.');
            _controller.goBack();
            return false; // Intercept back event, stay on current web page
          } else {
            // If cannot go back within web view, go to common websites home view
            debugPrint('[_WillPopScope] canGoBack is false, going to home page.');
            _goToHomePage();
            return false; // Intercept back event, stay on BrowserPage but switch view
          }
        }
        // If currently on common websites home view, allow WillPopScope event to continue, exiting this PageView page
        debugPrint('[_WillPopScope] On home page, allowing pop.');
        return true;
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          titleSpacing: 0, // Remove title padding
          title: _showHomePage
              ? const Text('网页浏览器') // Show title on home page
              : const SizedBox.shrink(), // Hide title when browsing web
          leading: _showHomePage
              ? null // Hide Home button on home page as per user request
              : IconButton(
                  icon: const Icon(Icons.home), // Show Home button when browsing web
                  onPressed: () async {
                    debugPrint('[_AppBar] Home button pressed.');
                    // Clicking Home button always goes to common websites home view, keeping web view instance state
                    _goToHomePage();
                  },
                  tooltip: '回到主页',
                ),
          centerTitle: true, // Center title or red X button
          actions: [
            // Bookmark button always visible
            IconButton(
              icon: const Icon(Icons.bookmark),
              onPressed: () => _showBookmarks(),
              tooltip: '显示书签',
            ),
            // Show Add Bookmark button when browsing web
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.bookmark_add),
                onPressed: () => _addBookmark(_currentUrl),
                tooltip: '添加书签',
              ),
            // Show red X button when browsing web
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red), // Red X button
                onPressed: () {
                  debugPrint('[_AppBar] Close button pressed.');
                  // Clicking red X button completely exits current web page and returns to common websites home view
                  _exitWebPage();
                },
                tooltip: '退出网页',
              ),
            // Edit and Add buttons are now only within the _buildHomePage content
            // Removed from AppBar actions as per user request
          ],
        ),
        body: _showHomePage
            ? _buildHomePage() // Show common websites home view (GridView/ListView)
            : Column(// When _showHomePage is false, show web view
                children: [
                  // Web toolbar - includes address bar and navigation buttons, only shown when browsing a web page
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      children: [
                         // Back button
                        IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () async {
                            debugPrint('[_Toolbar] Back button pressed.');
                            if (await _controller.canGoBack()) {
                              _controller.goBack();
                            }
                          },
                          tooltip: '后退',
                        ),
                        // Forward button
                        IconButton(
                          icon: const Icon(Icons.arrow_forward),
                          onPressed: () async {
                            debugPrint('[_Toolbar] Forward button pressed.');
                            if (await _controller.canGoForward()) {
                              _controller.goForward();
                            }
                          },
                          tooltip: '前进',
                        ),
                        // Refresh button
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: () {
                            debugPrint('[_Toolbar] Refresh button pressed.');
                            _controller.reload();
                          },
                          tooltip: '刷新',
                        ),
                        // Address bar
                        Expanded(
                          child: TextField(
                            controller: _urlController,
                            decoration: const InputDecoration(
                              hintText: '输入网址',
                              contentPadding: EdgeInsets.symmetric(horizontal: 8),
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.url, // Set keyboard type to URL
                            onSubmitted: (url) {
                              debugPrint('[_Toolbar] Address bar submitted: $url');
                              _loadUrl(url);
                            },
                          ),
                        ),
                        // Search/Go button
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
                  if (_isLoading) LinearProgressIndicator(value: _loadingProgress), // Show loading indicator
                  Expanded(
                    child: WebViewWidget(controller: _controller), // Display WebView
                  ),
                ],
              ),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    // Ensure all data is saved before exiting
    _saveBookmarks().then((_) {
      debugPrint('书签保存完成');
    }).catchError((error) {
      debugPrint('保存书签时出错: $error');
    });

    _saveCommonWebsites().then((_) {
      debugPrint('常用网站保存完成');
    }).catchError((error) {
      debugPrint('保存常用网站时出错: $error');
    });

    // Notify parent that BrowserPage is exiting and should be considered home page for PageView physics
    // This is important if the app is closed while on a web page view
    widget.onBrowserHomePageChanged?.call(true); // Assume exiting to a state where horizontal swipe is allowed from this position

    super.dispose();
  }

  // 在后台执行下载
  Future<void> _performBackgroundDownload(String url, MediaType mediaType) async {
    try {
      final file = await _downloadFile(url);
      if (file != null) {
        debugPrint('文件下载成功: ${file.path}');
        // 保存到媒体库
        await _saveToMediaLibrary(file, mediaType);
        // 显示成功消息
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('媒体已成功保存到媒体库: ${file.path.split('/').last}'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: '查看',
                onPressed: () {
                  // 跳转到媒体管理页面
                  Navigator.pushNamed(context, '/media_manager');
                },
              ),
            ),
          );
        }
      } else {
        debugPrint('文件下载失败');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('下载失败，请重试')),
          );
        }
      }
    } catch (e) {
      debugPrint('后台下载出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载出错: $e')),
        );
      }
    }
  }
}