import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:mime/mime.dart';
import '../core/service_locator.dart';
import 'database_service.dart';
import '../models/media_type.dart';

/// 简化版 Telegram 下载服务
/// 使用直接的 HTTP API 调用，避免 TeleDart 的复杂性
class TelegramDownloadServiceV2 {
  static const String _botTokenKey = 'telegram_bot_token';
  static TelegramDownloadServiceV2? _instance;
  
  final Dio _dio = Dio();
  String? _botToken;
  
  static TelegramDownloadServiceV2 get instance {
    _instance ??= TelegramDownloadServiceV2._();
    return _instance!;
  }
  
  TelegramDownloadServiceV2._();
  
  /// 初始化服务
  Future<void> initialize() async {
    await _loadBotToken();
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
  
  /// 验证 Bot Token 是否有效
  Future<bool> validateBotToken(String token) async {
    try {
      final response = await _dio.get(
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
      // 标准 t.me 链接
      RegExp(r'https?://t\.me/([^/]+)/(\d+)'),
      // telegram.me 链接
      RegExp(r'https?://telegram\.me/([^/]+)/(\d+)'),
      // Web Telegram 链接
      RegExp(r'https?://web\.telegram\.org.*[#&]p=([^&]+)'),
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
  /// 注意：这是一个演示版本，实际的 Telegram Bot API 有限制
  /// 机器人只能访问发送给它的消息，不能访问任意频道消息
  Future<DownloadResult> downloadFromMessage(String messageUrl, {
    Function(double)? onProgress,
  }) async {
    try {
      if (_botToken == null || _botToken!.isEmpty) {
        return DownloadResult.error('Bot Token 未配置');
      }
      
      final messageInfo = parseMessageUrl(messageUrl);
      if (messageInfo == null) {
        return DownloadResult.error('无效的 Telegram 消息链接');
      }
      
      // 由于 Telegram Bot API 的限制，我们需要提供一个替代方案
      // 这里我们返回一个说明性的错误，指导用户使用正确的方法
      return DownloadResult.error(
        '由于 Telegram Bot API 限制，机器人只能下载发送给它的消息。\n\n'
        '请尝试以下方法：\n'
        '1. 将要下载的媒体文件转发给您的机器人\n'
        '2. 或者使用其他下载方法\n\n'
        '解析到的信息：\n'
        '频道/群组: ${messageInfo.chatId}\n'
        '消息ID: ${messageInfo.messageId}'
      );
      
    } catch (e) {
      print('下载失败: $e');
      return DownloadResult.error('下载失败: ${e.toString()}');
    }
  }
  
  /// 获取机器人信息（用于测试）
  Future<Map<String, dynamic>?> getBotInfo() async {
    if (_botToken == null || _botToken!.isEmpty) {
      return null;
    }
    
    try {
      final response = await _dio.get(
        'https://api.telegram.org/bot$_botToken/getMe',
      );
      
      if (response.statusCode == 200 && response.data['ok'] == true) {
        return response.data['result'];
      }
    } catch (e) {
      print('获取机器人信息失败: $e');
    }
    
    return null;
  }
  
  /// 获取机器人的更新（消息）
  Future<List<Map<String, dynamic>>> getUpdates() async {
    if (_botToken == null || _botToken!.isEmpty) {
      return [];
    }
    
    try {
      final response = await _dio.get(
        'https://api.telegram.org/bot$_botToken/getUpdates',
      );
      
      if (response.statusCode == 200 && response.data['ok'] == true) {
        return List<Map<String, dynamic>>.from(response.data['result']);
      }
    } catch (e) {
      print('获取更新失败: $e');
    }
    
    return [];
  }
  
  /// 下载文件（通过 file_id）
  Future<DownloadResult> downloadFileById(String fileId, {
    Function(double)? onProgress,
  }) async {
    try {
      if (_botToken == null || _botToken!.isEmpty) {
        return DownloadResult.error('Bot Token 未配置');
      }
      
      // 1. 获取文件信息
      final fileInfoResponse = await _dio.get(
        'https://api.telegram.org/bot$_botToken/getFile',
        queryParameters: {'file_id': fileId},
      );
      
      if (fileInfoResponse.statusCode != 200 || fileInfoResponse.data['ok'] != true) {
        return DownloadResult.error('无法获取文件信息');
      }
      
      final fileInfo = fileInfoResponse.data['result'];
      final filePath = fileInfo['file_path'];
      final fileSize = fileInfo['file_size'] ?? 0;
      
      if (filePath == null) {
        return DownloadResult.error('文件路径为空');
      }
      
      // 2. 构建下载 URL
      final downloadUrl = 'https://api.telegram.org/file/bot$_botToken/$filePath';
      
      // 3. 下载文件
      final directory = await getApplicationDocumentsDirectory();
      final mediaDir = Directory(path.join(directory.path, 'media'));
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }
      
      final fileName = path.basename(filePath);
      final localFilePath = path.join(mediaDir.path, fileName);
      
      await _dio.download(
        downloadUrl,
        localFilePath,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            onProgress(received / total);
          }
        },
      );
      
      // 4. 保存到数据库
      final file = File(localFilePath);
      final actualFileSize = await file.length();
      final mimeType = lookupMimeType(localFilePath) ?? 'application/octet-stream';
      
      final databaseService = getService<DatabaseService>();
      await databaseService.insertMediaItem({
        'name': fileName,
        'path': localFilePath,
        'type': _getMediaTypeFromMime(mimeType).index,
        'file_size': actualFileSize,
        'file_hash': '', // 可以后续计算文件哈希
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      
      return DownloadResult.success(localFilePath, fileName);
      
    } catch (e) {
      print('下载文件失败: $e');
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
    _dio.close();
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
  
  @override
  String toString() {
    return 'TelegramMessageInfo(chatId: $chatId, messageId: $messageId)';
  }
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
  
  @override
  String toString() {
    if (success) {
      return 'DownloadResult.success(filePath: $filePath, fileName: $fileName)';
    } else {
      return 'DownloadResult.error(error: $error)';
    }
  }
}