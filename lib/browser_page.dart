import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'models/media_item.dart';
import 'models/media_type.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage({Key? key}) : super(key: key);

  @override
  _BrowserPageState createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
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
      await _saveCommonWebsites();
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
          },
          onWebResourceError: (error) {
            debugPrint('WebView错误: ${error.description}');
            // 显示错误信息给用户
            if (!_showHomePage) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('加载页面时出错: ${error.description}')),
              );
            }
          },
          // 使用onNavigationRequest处理下载请求
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            // 检查URL是否为可能的下载链接
            if (_isDownloadableLink(url)) {
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
        },
      );
    // 不再在初始化时立即加载URL
  }

  // 加载指定URL并隐藏首页
  void _loadUrl(String url) {
    String processedUrl = url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      processedUrl = 'https://$url';
    }
    
    // 为电报网站设置特殊处理，强制使用移动版
    if (processedUrl.contains('telegram.org') || processedUrl.contains('t.me') || processedUrl.contains('web.telegram.org')) {
      debugPrint('检测到电报网站，强制使用移动版');
      // 如果是电报网站，使用特殊的移动版用户代理
      _controller.setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1');
      
      // 如果是web.telegram.org，重定向到移动版URL
      if (processedUrl.contains('web.telegram.org')) {
        processedUrl = 'https://web.telegram.org/a/';
      }
    } else {
      // 恢复默认的移动版用户代理
      _controller.setUserAgent('Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.162 Mobile Safari/537.36');
    }
    
    _controller.loadRequest(Uri.parse(processedUrl));
    setState(() {
      _showHomePage = false;
      _currentUrl = processedUrl;
      _urlController.text = processedUrl;
    });
  }

  // 返回首页
  Future<void> _goToHomePage() async {
    setState(() {
      _showHomePage = true;
    });
    // 确保在返回首页时保存常用网站列表并等待完成
    await _saveCommonWebsites();
    debugPrint('已返回首页并保存常用网站');
  }

  // 构建常用网站列表页面
  Widget _buildHomePage() {
    return Column(
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
                      icon: Icon(Icons.add),
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
    );
  }

  // 显示添加网站对话框
  void _showAddWebsiteDialog(BuildContext context) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('添加网站'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(labelText: '网站名称'),
            ),
            TextField(
              controller: urlController,
              decoration: InputDecoration(labelText: '网站地址'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
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
                          Text("保存中..."),
                        ],
                      ),
                    );
                  },
                );
                
                // 等待添加网站完成
                await _addWebsite(nameController.text, urlController.text, Icons.web);
                
                // 关闭加载指示器和对话框
                Navigator.of(context).pop(); // 关闭加载指示器
                Navigator.of(context).pop(); // 关闭添加网站对话框
                
                // 显示成功消息
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('网站已添加并保存')),
                );
              }
            },
            child: Text('添加'),
          ),
        ],
      ),
    );
  }

  // 构建可编辑的网站列表项
  Widget _buildEditableWebsiteItem(Map<String, dynamic> website, int index) {
    // 从代码点创建IconData或使用默认图标
    IconData iconData;
    if (website.containsKey('iconCode')) {
      iconData = IconData(website['iconCode'], fontFamily: 'MaterialIcons');
    } else if (website.containsKey('icon') && website['icon'] is IconData) {
      iconData = website['icon'];
    } else {
      iconData = Icons.web;
    }
    
    return ListTile(
      key: ValueKey(website['url']),
      leading: Icon(iconData),
      title: Text(website['name']),
      subtitle: Text(website['url']),
      trailing: IconButton(
        icon: Icon(Icons.delete, color: Colors.red),
        onPressed: () async {
          // 显示确认对话框
          final shouldDelete = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('删除网站'),
              content: Text('确定要删除 ${website['name']} 吗？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text('删除'),
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
              SnackBar(content: Text('网站已删除')),
            );
          }
        },
      ),
    );
  }

  // 构建网站卡片
  Widget _buildWebsiteCard(Map<String, dynamic> website) {
    // 从代码点创建IconData或使用默认图标
    IconData iconData;
    if (website.containsKey('iconCode')) {
      iconData = IconData(website['iconCode'], fontFamily: 'MaterialIcons');
    } else if (website.containsKey('icon') && website['icon'] is IconData) {
      iconData = website['icon'];
    } else {
      iconData = Icons.web;
    }
    
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
      
      // 加载常用网站
      final commonWebsitesJson = prefs.getString('common_websites');
      if (commonWebsitesJson != null) {
        final List<dynamic> decoded = jsonDecode(commonWebsitesJson);
        setState(() {
          _commonWebsites.clear();
          _commonWebsites.addAll(decoded.map((item) => Map<String, dynamic>.from(item)).toList());
        });
      } else if (_commonWebsites.isEmpty) {
        // 如果没有保存的常用网站，使用默认值
        setState(() {
          _commonWebsites.clear();
          // 使用代码点而不是IconData对象
          _commonWebsites.addAll([
            {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.search.codePoint},
            {'name': '百度', 'url': 'https://www.baidu.com', 'iconCode': Icons.search.codePoint}
          ]);
        });
        _saveCommonWebsites(); // 保存默认常用网站
      }
    } catch (e) {
      debugPrint('加载书签和常用网站时出错: $e');
    }
  }
  
  // 保存书签到SharedPreferences
  Future<void> _saveBookmarks() async {
    try {
      debugPrint('开始保存书签...');
      final prefs = await SharedPreferences.getInstance();
      final result = await prefs.setStringList('bookmarks', _bookmarks);
      if (result) {
        debugPrint('书签保存成功');
      } else {
        debugPrint('书签保存失败: SharedPreferences返回false');
      }
    } catch (e) {
      debugPrint('保存书签时出错: $e');
      // 在调试模式下显示错误堆栈跟踪
      debugPrintStack(label: '保存书签错误堆栈');
    }
  }
  
  // 保存常用网站到SharedPreferences
  Future<void> _saveCommonWebsites() async {
    try {
      debugPrint('开始保存常用网站...');
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(_commonWebsites);
      debugPrint('常用网站JSON: $jsonString');
      final result = await prefs.setString('common_websites', jsonString);
      if (result) {
        debugPrint('常用网站保存成功');
      } else {
        debugPrint('常用网站保存失败: SharedPreferences返回false');
      }
    } catch (e) {
      debugPrint('保存常用网站时出错: $e');
      // 在调试模式下显示错误堆栈跟踪
      debugPrintStack(label: '保存常用网站错误堆栈');
    }
  }

  Future<void> _handleDownload(String url, String contentDisposition, String mimeType) async {
    try {
      // 显示下载选项对话框
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => _buildDownloadDialog(url, mimeType),
      );

      if (result != null) {
        final bool shouldDownload = result['download'];
        final MediaType mediaType = result['mediaType'];

        if (shouldDownload) {
          // 显示下载进度对话框
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在下载媒体文件...')
                ],
              ),
            ),
          );

          // 下载文件
          final file = await _downloadFile(url);
          if (file != null) {
            // 保存到媒体库
            await _saveToMediaLibrary(file, mediaType);
            // 关闭进度对话框
            if (mounted) Navigator.of(context).pop();
            // 显示成功消息
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('媒体已成功保存到媒体库')),
              );
            }
          } else {
            // 关闭进度对话框
            if (mounted) Navigator.of(context).pop();
            // 显示错误消息
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('下载失败，请重试')),
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('处理下载时出错: $e');
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
    // 检查文件扩展名
    final fileExtensions = [
      // 图片
      '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp',
      // 视频
      '.mp4', '.avi', '.mov', '.wmv', '.flv', '.mkv', '.webm',
      // 音频
      '.mp3', '.wav', '.ogg', '.aac', '.flac',
      // 文档
      '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
      // 压缩文件
      '.zip', '.rar', '.7z', '.tar', '.gz',
      // 其他常见下载文件
      '.exe', '.apk', '.dmg', '.iso'
    ];
    
    final lowercaseUrl = url.toLowerCase();
    for (final ext in fileExtensions) {
      if (lowercaseUrl.endsWith(ext)) {
        return true;
      }
    }
    
    // 检查URL中是否包含下载相关关键词
    final downloadKeywords = ['download', 'dl', 'attachment', 'file'];
    for (final keyword in downloadKeywords) {
      if (lowercaseUrl.contains(keyword)) {
        return true;
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
      final dio = Dio();
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }

      final uuid = const Uuid().v4();
      final uri = Uri.parse(url);
      final extension = _getFileExtension(uri.path);
      final filePath = '${mediaDir.path}/$uuid$extension';

      await dio.download(url, filePath);
      final file = File(filePath);
      if (await file.exists()) {
        return file;
      }
      return null;
    } catch (e) {
      debugPrint('下载文件时出错: $e');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text('网页浏览器'),
        leading: _showHomePage ? null : IconButton(
          icon: const Icon(Icons.home),
          onPressed: () async {
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
                      Text("保存中..."),
                    ],
                  ),
                );
              },
            );
            
            // 等待返回首页并保存完成
            await _goToHomePage();
            
            // 关闭加载指示器
            Navigator.of(context).pop();
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark),
            onPressed: () => _showBookmarks(),
          ),
          if (!_showHomePage) IconButton(
            icon: const Icon(Icons.bookmark_add),
            onPressed: () => _addBookmark(_currentUrl),
          ),
          if (_showHomePage) IconButton(
            icon: Icon(_isEditMode ? Icons.done : Icons.edit),
            onPressed: _toggleEditMode,
            tooltip: _isEditMode ? '完成编辑' : '编辑常用网站',
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
                      if (await _controller.canGoBack()) {
                        _controller.goBack();
                      } else {
                        _goToHomePage();
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: () async {
                      if (await _controller.canGoForward()) {
                        _controller.goForward();
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () => _controller.reload(),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        hintText: '输入网址',
                        contentPadding: EdgeInsets.symmetric(horizontal: 8),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (url) {
                        _loadUrl(url);
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () {
                      _loadUrl(_urlController.text);
                    },
                  ),
                ],
              ),
            ),
            if (_isLoading) LinearProgressIndicator(value: _loadingProgress),
            Expanded(
              child: WebViewWidget(controller: _controller),
            ),
          ],
        ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    // 确保在退出前保存所有数据
    // 注意：在dispose中不能使用await，所以我们使用then来处理异步操作
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
    
    super.dispose();
  }
}