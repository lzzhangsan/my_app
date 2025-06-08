import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:teledart/teledart.dart';
import 'package:teledart/telegram.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:mime/mime.dart';
import 'package:html/parser.dart' as html;
import 'database_service.dart';
import '../models/media_type.dart';

class TelegramDownloadService {
  static const String _botTokenKey = 'telegram_bot_token';
  static TelegramDownloadService? _instance;
  
  TeleDart? _teledart;
  Dio? _dio;
  String? _botToken;
  
  static TelegramDownloadService get instance {
    _instance ??= TelegramDownloadService._();
    return _instance!;
  }
  
  TelegramDownloadService._() {
    _dio = Dio();
  }
  
  /// 初始化服务
  Future<void> initialize() async {
    await _loadBotToken();
    if (_botToken != null && _botToken!.isNotEmpty) {
      await _initializeTelegramBot();
    }
  }
  
  /// 加载保存的 Bot Token
  Future<void> _loadBotToken() async {
    final prefs = await SharedPreferences.getInstance();
    _botToken = prefs.getString(_botTokenKey);
  }
  
  /// 保存 Bot Token
  Future<bool> saveBotToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_botTokenKey, token);
      _botToken = token;
      await _initializeTelegramBot();
      return true;
    } catch (e) {
      print('保存 Bot Token 失败: $e');
      return false;
    }
  }
  
  /// 获取当前 Bot Token
  String? get botToken => _botToken;
  
  /// 检查是否已配置 Bot Token
  bool get isConfigured => _botToken != null && _botToken!.isNotEmpty;
  
  /// 初始化 Telegram Bot
  Future<void> _initializeTelegramBot() async {
    if (_botToken == null || _botToken!.isEmpty) return;
    
    try {
      _teledart = TeleDart(_botToken!, Event());
      print('Telegram Bot 初始化成功');
    } catch (e) {
      print('Telegram Bot 初始化失败: $e');
      _teledart = null;
    }
  }
  
  /// 验证 Bot Token 是否有效
  Future<bool> validateBotToken(String token) async {
    try {
      final dio = Dio();
      final response = await dio.get(
        'https://api.telegram.org/bot$token/getMe',
      );
      return response.statusCode == 200 && response.data['ok'] == true;
    } catch (e) {
      print('验证 Bot Token 失败: $e');
      return false;
    }
  }
  
  /// 解析 Telegram 消息链接
  TelegramMessageInfo? parseMessageUrl(String url) {
    // 支持多种 Telegram URL 格式
    final patterns = [
      RegExp(r'https?://t\.me/([^/]+)/(\d+)'),
      RegExp(r'https?://telegram\.me/([^/]+)/(\d+)'),
      RegExp(r'https?://web\.telegram\.org/[^#]*#/im\?p=([^&]+)'),
    ];
    
    for (final pattern in patterns) {
      final match = pattern.firstMatch(url);
      if (match != null) {
        if (pattern.pattern.contains('web.telegram.org')) {
          // 处理 Web Telegram URL
          final param = match.group(1)!;
          final parts = param.split('_');
          if (parts.length >= 2) {
            return TelegramMessageInfo(
              chatId: parts[0],
              messageId: int.tryParse(parts[1]) ?? 0,
            );
          }
        } else {
          // 处理标准 t.me URL
          return TelegramMessageInfo(
            chatId: match.group(1)!,
            messageId: int.tryParse(match.group(2)!) ?? 0,
          );
        }
      }
    }
    
    return null;
  }
  
  /// 下载 Telegram 消息中的媒体文件
  Future<DownloadResult> downloadFromMessage(String messageUrl, {
    Function(double)? onProgress,
  }) async {
    try {
      if (_teledart == null) {
        return DownloadResult.error('Telegram Bot 未初始化，请先配置 Bot Token');
      }
      
      final messageInfo = parseMessageUrl(messageUrl);
      if (messageInfo == null) {
        return DownloadResult.error('无效的 Telegram 消息链接');
      }
      
      // 获取消息内容
      final message = await _getMessageContent(messageInfo);
      if (message == null) {
        return DownloadResult.error('无法获取消息内容，请检查链接和权限');
      }
      
      // 提取媒体文件信息
      final mediaInfo = _extractMediaInfo(message);
      if (mediaInfo == null) {
        return DownloadResult.error('消息中没有找到可下载的媒体文件');
      }
      
      // 下载文件
      return await _downloadMediaFile(mediaInfo, onProgress: onProgress);
      
    } catch (e) {
      print('下载失败: $e');
      return DownloadResult.error('下载失败: ${e.toString()}');
    }
  }
  
  /// 获取消息内容
  Future<Message?> _getMessageContent(TelegramMessageInfo messageInfo) async {
    try {
      // 尝试通过不同方式获取消息
      final chatId = messageInfo.chatId;
      final messageId = messageInfo.messageId;
      
      // 如果是频道或群组，尝试直接获取
      if (chatId.startsWith('@') || chatId.startsWith('-')) {
        return await _teledart!.telegram.getUpdates();
      }
      
      // 对于私聊，可能需要特殊处理
      return null;
    } catch (e) {
      print('获取消息内容失败: $e');
      return null;
    }
  }
  
  /// 提取媒体信息
  MediaFileInfo? _extractMediaInfo(dynamic message) {
    // 这里需要根据实际的 Telegram API 响应结构来解析
    // 由于 TeleDart 的限制，我们可能需要使用其他方法
    return null;
  }
  
  /// 下载媒体文件
  Future<DownloadResult> _downloadMediaFile(MediaFileInfo mediaInfo, {
    Function(double)? onProgress,
  }) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final mediaDir = Directory(path.join(directory.path, 'media'));
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }
      
      final fileName = mediaInfo.fileName ?? 'telegram_media_${DateTime.now().millisecondsSinceEpoch}';
      final filePath = path.join(mediaDir.path, fileName);
      
      // 使用 Dio 下载文件
      await _dio!.download(
        mediaInfo.downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            onProgress(received / total);
          }
        },
      );
      
      // 保存到数据库
      final file = File(filePath);
      final fileSize = await file.length();
      final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
      
      await DatabaseService.instance.insertMedia(
        fileName,
        filePath,
        _getMediaTypeFromMime(mimeType),
        fileSize,
      );
      
      return DownloadResult.success(filePath, fileName);
      
    } catch (e) {
      print('下载媒体文件失败: $e');
      return DownloadResult.error('下载失败: ${e.toString()}');
    }
  }
  
  /// 根据 MIME 类型确定媒体类型
  MediaType _getMediaTypeFromMime(String mimeType) {
    if (mimeType.startsWith('image/')) {
      return MediaType.image;
    } else if (mimeType.startsWith('video/')) {
      return MediaType.video;
    } else if (mimeType.startsWith('audio/')) {
      return MediaType.audio;
    } else {
      return MediaType.document;
    }
  }
  
  /// 清理资源
  void dispose() {
    _teledart = null;
    _dio?.close();
  }
}

/// Telegram 消息信息
class TelegramMessageInfo {
  final String chatId;
  final int messageId;
  
  TelegramMessageInfo({
    required this.chatId,
    required this.messageId,
  });
}

/// 媒体文件信息
class MediaFileInfo {
  final String downloadUrl;
  final String? fileName;
  final String? mimeType;
  final int? fileSize;
  
  MediaFileInfo({
    required this.downloadUrl,
    this.fileName,
    this.mimeType,
    this.fileSize,
  });
}

/// 下载结果
class DownloadResult {
  final bool success;
  final String? filePath;
  final String? fileName;
  final String? error;
  
  DownloadResult._({required this.success, this.filePath, this.fileName, this.error});
  
  factory DownloadResult.success(String filePath, String fileName) {
    return DownloadResult._(
      success: true,
      filePath: filePath,
      fileName: fileName,
    );
  }
  
  factory DownloadResult.error(String error) {
    return DownloadResult._(
      success: false,
      error: error,
    );
  }
}