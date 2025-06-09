import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;
import '../models/media_type.dart';

/// 媒体信息类
class MediaInfo {
  final String url;
  final String name;
  final String format;
  final String? size;
  final String? quality;
  final MediaType type;
  final double downloadProbability; // 下载可能性评分 (0.0 - 1.0)
  final Map<String, dynamic> metadata;

  MediaInfo({
    required this.url,
    required this.name,
    required this.format,
    this.size,
    this.quality,
    required this.type,
    required this.downloadProbability,
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
    'url': url,
    'name': name,
    'format': format,
    'size': size,
    'quality': quality,
    'type': type.toString(),
    'downloadProbability': downloadProbability,
    'metadata': metadata,
  };
}

/// 媒体嗅探服务 - 提供强大的媒体链接检测和提取功能
class MediaSnifferService {
  static final MediaSnifferService _instance = MediaSnifferService._internal();
  factory MediaSnifferService() => _instance;
  MediaSnifferService._internal();

  final Dio _dio = Dio();
  final Set<String> _processedUrls = {};

  /// 初始化嗅探服务
  void initialize() {
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
      maxRedirects: 3,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Accept-Encoding': 'gzip, deflate, br',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      },
    );
    
    // 添加拦截器处理错误
    _dio.interceptors.add(InterceptorsWrapper(
      onError: (error, handler) {
        debugPrint('网络请求错误: ${error.message}');
        if (error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.receiveTimeout) {
          debugPrint('网络超时，可能是CORS问题或网络连接问题');
        }
        handler.next(error);
      },
    ));
  }

  /// 主要的媒体嗅探方法 - 从网页URL中提取所有可能的媒体链接
  Future<List<MediaInfo>> sniffMediaFromPage(String pageUrl) async {
    try {
      debugPrint('开始嗅探页面媒体: $pageUrl');
      
      final List<MediaInfo> allMedia = [];
      
      // 1. 直接分析页面HTML
      final htmlMedia = await _extractFromHtml(pageUrl);
      allMedia.addAll(htmlMedia);
      
      // 2. 特定网站的专门处理
      final siteSpecificMedia = await _extractSiteSpecific(pageUrl);
      allMedia.addAll(siteSpecificMedia);
      
      // 3. 通过JavaScript执行获取动态内容
      final dynamicMedia = await _extractDynamicContent(pageUrl);
      allMedia.addAll(dynamicMedia);
      
      // 4. 分析网络请求模式
      final networkMedia = await _analyzeNetworkPatterns(pageUrl);
      allMedia.addAll(networkMedia);
      
      // 去重并按下载可能性排序
      final uniqueMedia = _deduplicateAndSort(allMedia);
      
      debugPrint('嗅探完成，发现 ${uniqueMedia.length} 个媒体文件');
      return uniqueMedia;
      
    } catch (e, stackTrace) {
      debugPrint('媒体嗅探失败: $e');
      debugPrint('错误堆栈: $stackTrace');
      return [];
    }
  }

  /// 从HTML内容中提取媒体链接
  Future<List<MediaInfo>> _extractFromHtml(String url) async {
    try {
      debugPrint('尝试获取页面HTML: $url');
      final response = await _dio.get(url);
      debugPrint('成功获取页面HTML，状态码: ${response.statusCode}');
      final document = html.parse(response.data);
      final List<MediaInfo> media = [];
      
      // 提取图片
      final images = document.querySelectorAll('img[src], img[data-src], img[data-lazy-src]');
      for (final img in images) {
        final src = img.attributes['src'] ?? 
                   img.attributes['data-src'] ?? 
                   img.attributes['data-lazy-src'];
        if (src != null && src.isNotEmpty) {
          final mediaUrl = _resolveUrl(src, url);
          if (_isValidMediaUrl(mediaUrl)) {
            media.add(MediaInfo(
              url: mediaUrl,
              name: _extractFileName(mediaUrl) ?? 'image_${media.length + 1}',
              format: _getFileExtension(mediaUrl) ?? 'jpg',
              type: MediaType.image,
              downloadProbability: _calculateImageProbability(img, mediaUrl),
              metadata: {
                'alt': img.attributes['alt'] ?? '',
                'title': img.attributes['title'] ?? '',
                'width': img.attributes['width'],
                'height': img.attributes['height'],
              },
            ));
          }
        }
      }
      
      // 提取视频
      final videos = document.querySelectorAll('video[src], video source[src]');
      for (final video in videos) {
        final src = video.attributes['src'];
        if (src != null && src.isNotEmpty) {
          final mediaUrl = _resolveUrl(src, url);
          if (_isValidMediaUrl(mediaUrl)) {
            media.add(MediaInfo(
              url: mediaUrl,
              name: _extractFileName(mediaUrl) ?? 'video_${media.length + 1}',
              format: _getFileExtension(mediaUrl) ?? 'mp4',
              type: MediaType.video,
              downloadProbability: _calculateVideoProbability(video, mediaUrl),
              metadata: {
                'poster': video.attributes['poster'],
                'duration': video.attributes['duration'],
                'width': video.attributes['width'],
                'height': video.attributes['height'],
              },
            ));
          }
        }
      }
      
      // 提取音频
      final audios = document.querySelectorAll('audio[src], audio source[src]');
      for (final audio in audios) {
        final src = audio.attributes['src'];
        if (src != null && src.isNotEmpty) {
          final mediaUrl = _resolveUrl(src, url);
          if (_isValidMediaUrl(mediaUrl)) {
            media.add(MediaInfo(
              url: mediaUrl,
              name: _extractFileName(mediaUrl) ?? 'audio_${media.length + 1}',
              format: _getFileExtension(mediaUrl) ?? 'mp3',
              type: MediaType.audio,
              downloadProbability: _calculateAudioProbability(audio, mediaUrl),
              metadata: {
                'duration': audio.attributes['duration'],
              },
            ));
          }
        }
      }
      
      // 提取链接中的媒体文件
      final links = document.querySelectorAll('a[href]');
      for (final link in links) {
        final href = link.attributes['href'];
        if (href != null && href.isNotEmpty) {
          final mediaUrl = _resolveUrl(href, url);
          if (_isDirectMediaLink(mediaUrl)) {
            final type = determineMediaType(mediaUrl);
            media.add(MediaInfo(
              url: mediaUrl,
              name: _extractFileName(mediaUrl) ?? 'media_${media.length + 1}',
              format: _getFileExtension(mediaUrl) ?? 'unknown',
              type: type,
              downloadProbability: _calculateLinkProbability(link, mediaUrl),
              metadata: {
                'linkText': link.text.trim(),
                'title': link.attributes['title'] ?? '',
              },
            ));
          }
        }
      }
      
      debugPrint('从HTML中提取到 ${media.length} 个媒体文件');
      return media;
    } catch (e) {
      debugPrint('HTML提取失败: $e');
      if (e.toString().contains('CORS') || e.toString().contains('403') || e.toString().contains('401')) {
        debugPrint('可能遇到CORS限制或访问权限问题，这在浏览器环境中是正常的');
      }
      return [];
    }
  }

  /// 特定网站的专门处理
  Future<List<MediaInfo>> _extractSiteSpecific(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      // Telegram Web处理
      if (url.contains('web.telegram.org') || url.contains('t.me')) {
        media.addAll(await _extractTelegramMedia(url));
      }
      
      // YouTube处理
      if (url.contains('youtube.com') || url.contains('youtu.be')) {
        media.addAll(await _extractYouTubeMedia(url));
      }
      
      // Twitter/X处理
      if (url.contains('twitter.com') || url.contains('x.com')) {
        media.addAll(await _extractTwitterMedia(url));
      }
      
      // Instagram处理
      if (url.contains('instagram.com')) {
        media.addAll(await _extractInstagramMedia(url));
      }
      
      // Facebook处理
      if (url.contains('facebook.com')) {
        media.addAll(await _extractFacebookMedia(url));
      }
      
      // TikTok处理
      if (url.contains('tiktok.com')) {
        media.addAll(await _extractTikTokMedia(url));
      }
      
      // 百度图片处理
      if (url.contains('image.baidu.com') || url.contains('baidu.com')) {
        media.addAll(await _extractBaiduMedia(url));
      }
      
    } catch (e) {
      debugPrint('特定网站处理失败: $e');
    }
    
    return media;
  }

  /// Telegram媒体提取
  Future<List<MediaInfo>> _extractTelegramMedia(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      // 分析Telegram的API模式
      final telegramPatterns = [
        r'https://web\.telegram\.org/a/progressive/document\?[^"\s]+',
        r'https://cdn\d*\.telegram\.org/file/[^"\s]+',
        r'https://t\.me/[^/]+/\d+',
      ];
      
      final response = await _dio.get(url);
      final content = response.data.toString();
      
      for (final pattern in telegramPatterns) {
        final regex = RegExp(pattern);
        final matches = regex.allMatches(content);
        
        for (final match in matches) {
          final mediaUrl = match.group(0)!;
          if (!_processedUrls.contains(mediaUrl)) {
            _processedUrls.add(mediaUrl);
            
            media.add(MediaInfo(
              url: mediaUrl,
              name: 'telegram_media_${media.length + 1}',
              format: _getFileExtension(mediaUrl) ?? 'unknown',
              type: determineMediaType(mediaUrl),
              downloadProbability: 0.9, // Telegram链接通常很可靠
              metadata: {'source': 'telegram'},
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('Telegram媒体提取失败: $e');
    }
    
    return media;
  }

  /// YouTube媒体提取
  Future<List<MediaInfo>> _extractYouTubeMedia(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      // 提取YouTube视频ID
      final videoIdMatch = RegExp(r'(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]+)').firstMatch(url);
      if (videoIdMatch != null) {
        final videoId = videoIdMatch.group(1)!;
        
        // 构建可能的媒体URL
        final qualities = ['720p', '480p', '360p', '240p'];
        for (int i = 0; i < qualities.length; i++) {
          media.add(MediaInfo(
            url: 'https://www.youtube.com/watch?v=$videoId',
            name: 'youtube_video_$videoId',
            format: 'mp4',
            quality: qualities[i],
            type: MediaType.video,
            downloadProbability: 0.8 - (i * 0.1), // 高质量的可能性更高
            metadata: {
              'videoId': videoId,
              'source': 'youtube',
              'quality': qualities[i],
            },
          ));
        }
      }
    } catch (e) {
      debugPrint('YouTube媒体提取失败: $e');
    }
    
    return media;
  }

  /// Twitter媒体提取
  Future<List<MediaInfo>> _extractTwitterMedia(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      final response = await _dio.get(url);
      final content = response.data.toString();
      
      // Twitter图片模式
      final imagePattern = RegExp(r'https://pbs\.twimg\.com/media/[^"\s]+');
      final imageMatches = imagePattern.allMatches(content);
      
      for (final match in imageMatches) {
        final imageUrl = match.group(0)!;
        if (!_processedUrls.contains(imageUrl)) {
          _processedUrls.add(imageUrl);
          
          media.add(MediaInfo(
            url: imageUrl,
            name: 'twitter_image_${media.length + 1}',
            format: _getFileExtension(imageUrl) ?? 'jpg',
            type: MediaType.image,
            downloadProbability: 0.85,
            metadata: {'source': 'twitter'},
          ));
        }
      }
      
      // Twitter视频模式
      final videoPattern = RegExp(r'https://video\.twimg\.com/[^"\s]+');
      final videoMatches = videoPattern.allMatches(content);
      
      for (final match in videoMatches) {
        final videoUrl = match.group(0)!;
        if (!_processedUrls.contains(videoUrl)) {
          _processedUrls.add(videoUrl);
          
          media.add(MediaInfo(
            url: videoUrl,
            name: 'twitter_video_${media.length + 1}',
            format: _getFileExtension(videoUrl) ?? 'mp4',
            type: MediaType.video,
            downloadProbability: 0.85,
            metadata: {'source': 'twitter'},
          ));
        }
      }
    } catch (e) {
      debugPrint('Twitter媒体提取失败: $e');
    }
    
    return media;
  }

  /// Instagram媒体提取
  Future<List<MediaInfo>> _extractInstagramMedia(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      final response = await _dio.get(url);
      final content = response.data.toString();
      
      // Instagram图片和视频模式
      final mediaPattern = RegExp(r'https://[^"\s]*\.cdninstagram\.com/[^"\s]+');
      final matches = mediaPattern.allMatches(content);
      
      for (final match in matches) {
        final mediaUrl = match.group(0)!;
        if (!_processedUrls.contains(mediaUrl)) {
          _processedUrls.add(mediaUrl);
          
          final type = mediaUrl.contains('mp4') ? MediaType.video : MediaType.image;
          media.add(MediaInfo(
            url: mediaUrl,
            name: 'instagram_${type == MediaType.video ? 'video' : 'image'}_${media.length + 1}',
            format: _getFileExtension(mediaUrl) ?? (type == MediaType.video ? 'mp4' : 'jpg'),
            type: type,
            downloadProbability: 0.8,
            metadata: {'source': 'instagram'},
          ));
        }
      }
    } catch (e) {
      debugPrint('Instagram媒体提取失败: $e');
    }
    
    return media;
  }

  /// Facebook媒体提取
  Future<List<MediaInfo>> _extractFacebookMedia(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      final response = await _dio.get(url);
      final content = response.data.toString();
      
      // Facebook视频模式
      final videoPattern = RegExp(r'https://[^"\s]*\.fbcdn\.net/[^"\s]+');
      final matches = videoPattern.allMatches(content);
      
      for (final match in matches) {
        final mediaUrl = match.group(0)!;
        if (!_processedUrls.contains(mediaUrl)) {
          _processedUrls.add(mediaUrl);
          
          final type = determineMediaType(mediaUrl);
          media.add(MediaInfo(
            url: mediaUrl,
            name: 'facebook_media_${media.length + 1}',
            format: _getFileExtension(mediaUrl) ?? 'mp4',
            type: type,
            downloadProbability: 0.75,
            metadata: {'source': 'facebook'},
          ));
        }
      }
    } catch (e) {
      debugPrint('Facebook媒体提取失败: $e');
    }
    
    return media;
  }

  /// TikTok媒体提取
  Future<List<MediaInfo>> _extractTikTokMedia(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      final response = await _dio.get(url);
      final content = response.data.toString();
      
      // TikTok视频模式
      final videoPattern = RegExp(r'https://[^"\s]*\.tiktokcdn\.com/[^"\s]+');
      final matches = videoPattern.allMatches(content);
      
      for (final match in matches) {
        final mediaUrl = match.group(0)!;
        if (!_processedUrls.contains(mediaUrl)) {
          _processedUrls.add(mediaUrl);
          
          media.add(MediaInfo(
            url: mediaUrl,
            name: 'tiktok_video_${media.length + 1}',
            format: 'mp4',
            type: MediaType.video,
            downloadProbability: 0.8,
            metadata: {'source': 'tiktok'},
          ));
        }
      }
    } catch (e) {
      debugPrint('TikTok媒体提取失败: $e');
    }
    
    return media;
  }

  /// 提取动态内容（模拟JavaScript执行）
  Future<List<MediaInfo>> _extractDynamicContent(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      // 这里可以添加更复杂的动态内容分析
      // 例如分析AJAX请求、WebSocket连接等
      
      // 分析常见的动态加载模式
      final response = await _dio.get(url);
      final content = response.data.toString();
      
      // 查找JSON中的媒体URL
      final jsonPattern = RegExp(r'\{[^{}]*"[^"]*(?:url|src|href)[^"]*"\s*:\s*"([^"]+)"[^{}]*\}');
      final matches = jsonPattern.allMatches(content);
      
      for (final match in matches) {
        final potentialUrl = match.group(1);
        if (potentialUrl != null && _isValidMediaUrl(potentialUrl)) {
          final mediaUrl = _resolveUrl(potentialUrl, url);
          if (_isDirectMediaLink(mediaUrl)) {
            media.add(MediaInfo(
              url: mediaUrl,
              name: 'dynamic_media_${media.length + 1}',
              format: _getFileExtension(mediaUrl) ?? 'unknown',
              type: determineMediaType(mediaUrl),
              downloadProbability: 0.6, // 动态内容的可靠性稍低
              metadata: {'source': 'dynamic'},
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('动态内容提取失败: $e');
    }
    
    return media;
  }

  /// 分析网络请求模式
  Future<List<MediaInfo>> _analyzeNetworkPatterns(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      // 分析常见的CDN和媒体服务器模式
      final cdnPatterns = [
        r'https://[^"\s]*\.amazonaws\.com/[^"\s]+\.(jpg|jpeg|png|gif|mp4|webm|mp3|wav)',
        r'https://[^"\s]*\.cloudfront\.net/[^"\s]+\.(jpg|jpeg|png|gif|mp4|webm|mp3|wav)',
        r'https://[^"\s]*\.googleapis\.com/[^"\s]+\.(jpg|jpeg|png|gif|mp4|webm|mp3|wav)',
        r'https://[^"\s]*\.azureedge\.net/[^"\s]+\.(jpg|jpeg|png|gif|mp4|webm|mp3|wav)',
      ];
      
      final response = await _dio.get(url);
      final content = response.data.toString();
      
      for (final pattern in cdnPatterns) {
        final regex = RegExp(pattern, caseSensitive: false);
        final matches = regex.allMatches(content);
        
        for (final match in matches) {
          final mediaUrl = match.group(0)!;
          if (!_processedUrls.contains(mediaUrl)) {
            _processedUrls.add(mediaUrl);
            
            media.add(MediaInfo(
              url: mediaUrl,
              name: 'cdn_media_${media.length + 1}',
              format: _getFileExtension(mediaUrl) ?? 'unknown',
              type: determineMediaType(mediaUrl),
              downloadProbability: 0.85, // CDN链接通常很可靠
              metadata: {'source': 'cdn'},
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('网络模式分析失败: $e');
    }
    
    return media;
  }

  /// 去重并按下载可能性排序
  List<MediaInfo> _deduplicateAndSort(List<MediaInfo> media) {
    final Map<String, MediaInfo> uniqueMedia = {};
    
    for (final item in media) {
      final key = item.url;
      if (!uniqueMedia.containsKey(key) || 
          uniqueMedia[key]!.downloadProbability < item.downloadProbability) {
        uniqueMedia[key] = item;
      }
    }
    
    final result = uniqueMedia.values.toList();
    result.sort((a, b) => b.downloadProbability.compareTo(a.downloadProbability));
    
    return result;
  }

  /// 辅助方法
  String _resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    if (url.startsWith('//')) {
      return 'https:$url';
    }
    if (url.startsWith('/')) {
      final uri = Uri.parse(baseUrl);
      return '${uri.scheme}://${uri.host}$url';
    }
    return '$baseUrl/$url';
  }

  bool _isValidMediaUrl(String url) {
    if (url.isEmpty || url.length < 10) return false;
    if (!url.startsWith('http')) return false;
    return true;
  }

  bool _isDirectMediaLink(String url) {
    final mediaExtensions = [
      '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg',
      '.mp4', '.avi', '.mov', '.wmv', '.flv', '.mkv', '.webm', '.m4v',
      '.mp3', '.wav', '.ogg', '.aac', '.flac', '.m4a', '.wma',
    ];
    
    final lowercaseUrl = url.toLowerCase();
    return mediaExtensions.any((ext) => lowercaseUrl.contains(ext));
  }

  MediaType determineMediaType(String url) {
    final lowercaseUrl = url.toLowerCase();
    
    if (lowercaseUrl.contains('.jpg') || lowercaseUrl.contains('.jpeg') ||
        lowercaseUrl.contains('.png') || lowercaseUrl.contains('.gif') ||
        lowercaseUrl.contains('.bmp') || lowercaseUrl.contains('.webp') ||
        lowercaseUrl.contains('.svg')) {
      return MediaType.image;
    }
    
    if (lowercaseUrl.contains('.mp4') || lowercaseUrl.contains('.avi') ||
        lowercaseUrl.contains('.mov') || lowercaseUrl.contains('.wmv') ||
        lowercaseUrl.contains('.flv') || lowercaseUrl.contains('.mkv') ||
        lowercaseUrl.contains('.webm') || lowercaseUrl.contains('.m4v')) {
      return MediaType.video;
    }
    
    if (lowercaseUrl.contains('.mp3') || lowercaseUrl.contains('.wav') ||
        lowercaseUrl.contains('.ogg') || lowercaseUrl.contains('.aac') ||
        lowercaseUrl.contains('.flac') || lowercaseUrl.contains('.m4a') ||
        lowercaseUrl.contains('.wma')) {
      return MediaType.audio;
    }
    
    return MediaType.image; // 默认为图片
  }

  String? _extractFileName(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final lastSlash = path.lastIndexOf('/');
      if (lastSlash != -1 && lastSlash < path.length - 1) {
        return path.substring(lastSlash + 1);
      }
    } catch (e) {
      // 忽略解析错误
    }
    return null;
  }

  String? _getFileExtension(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final lastDot = path.lastIndexOf('.');
      if (lastDot != -1 && lastDot < path.length - 1) {
        return path.substring(lastDot + 1).toLowerCase();
      }
    } catch (e) {
      // 忽略解析错误
    }
    return null;
  }

  /// 计算各种媒体的下载可能性
  double _calculateImageProbability(dom.Element img, String url) {
    double probability = 0.5;
    
    // 检查图片尺寸
    final width = int.tryParse(img.attributes['width'] ?? '0') ?? 0;
    final height = int.tryParse(img.attributes['height'] ?? '0') ?? 0;
    if (width > 200 && height > 200) probability += 0.2;
    if (width > 500 && height > 500) probability += 0.1;
    
    // 检查alt和title属性
    if (img.attributes['alt']?.isNotEmpty == true) probability += 0.1;
    if (img.attributes['title']?.isNotEmpty == true) probability += 0.1;
    
    // 检查URL特征
    if (url.contains('original') || url.contains('full') || url.contains('large')) {
      probability += 0.2;
    }
    
    return probability.clamp(0.0, 1.0);
  }

  double _calculateVideoProbability(dom.Element video, String url) {
    double probability = 0.7; // 视频通常有较高的下载价值
    
    // 检查视频属性
    if (video.attributes['poster']?.isNotEmpty == true) probability += 0.1;
    if (video.attributes['duration']?.isNotEmpty == true) probability += 0.1;
    
    // 检查URL特征
    if (url.contains('hd') || url.contains('720p') || url.contains('1080p')) {
      probability += 0.1;
    }
    
    return probability.clamp(0.0, 1.0);
  }

  double _calculateAudioProbability(dom.Element audio, String url) {
    double probability = 0.6; // 音频有中等的下载价值
    
    // 检查音频属性
    if (audio.attributes['duration']?.isNotEmpty == true) probability += 0.1;
    
    // 检查URL特征
    if (url.contains('high') || url.contains('quality')) {
      probability += 0.1;
    }
    
    return probability.clamp(0.0, 1.0);
  }

  double _calculateLinkProbability(dom.Element link, String url) {
    double probability = 0.3; // 链接的基础概率较低
    
    // 检查链接文本
    final linkText = link.text.toLowerCase();
    if (linkText.contains('download') || linkText.contains('下载')) {
      probability += 0.4;
    }
    if (linkText.contains('save') || linkText.contains('保存')) {
      probability += 0.3;
    }
    
    // 检查URL特征
    if (url.contains('download') || url.contains('dl=')) {
      probability += 0.3;
    }
    
    return probability.clamp(0.0, 1.0);
  }

  /// 获取文件大小（如果可能）
  Future<String?> getFileSize(String url) async {
    try {
      final response = await _dio.head(url);
      final contentLength = response.headers.value('content-length');
      if (contentLength != null) {
        final bytes = int.parse(contentLength);
        return _formatFileSize(bytes);
      }
    } catch (e) {
      // 忽略错误
    }
    return null;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  /// 百度图片媒体提取
  Future<List<MediaInfo>> _extractBaiduMedia(String url) async {
    final List<MediaInfo> media = [];
    
    try {
      debugPrint('开始处理百度图片页面: $url');
      
      // 由于百度图片使用大量JavaScript动态加载，我们主要依赖前端JavaScript检测
      // 这里提供一些备用的URL模式匹配
      
      // 检查是否是百度图片的直接链接
      if (url.contains('hiphotos.baidu.com') || 
          url.contains('imgsrc.baidu.com') ||
          url.contains('ss0.bdstatic.com') ||
          url.contains('ss1.bdstatic.com') ||
          url.contains('ss2.bdstatic.com')) {
        
        final fileName = url.split('/').last.split('?').first;
        final format = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'jpg';
        
        media.add(MediaInfo(
          url: url,
          name: fileName.isNotEmpty ? fileName : 'baidu_image.$format',
          format: format,
          type: MediaType.image,
          downloadProbability: 0.8,
          metadata: {
            'source': 'baidu_direct',
            'site': 'baidu.com',
          },
        ));
      }
      
      debugPrint('百度图片处理完成，找到 ${media.length} 个媒体文件');
      
    } catch (e) {
      debugPrint('百度图片处理失败: $e');
    }
    
    return media;
  }

  /// 清理缓存
  void clearCache() {
    _processedUrls.clear();
  }
}