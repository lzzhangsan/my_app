// lib/core/logger.dart
// 统一的日志管理工具

import 'package:flutter/foundation.dart';

class Logger {
  static const String _tag = '[ChangeApp]';
  
  /// 调试日志 - 仅在调试模式下输出
  static void debug(String message, {String? context}) {
    if (kDebugMode) {
      final contextStr = context != null ? '[$context] ' : '';
      debugPrint('$_tag DEBUG $contextStr$message');
    }
  }
  
  /// 信息日志 - 仅在调试模式下输出
  static void info(String message, {String? context}) {
    if (kDebugMode) {
      final contextStr = context != null ? '[$context] ' : '';
      debugPrint('$_tag INFO $contextStr$message');
    }
  }
  
  /// 警告日志 - 仅在调试模式下输出
  static void warning(String message, {String? context}) {
    if (kDebugMode) {
      final contextStr = context != null ? '[$context] ' : '';
      debugPrint('$_tag WARNING $contextStr$message');
    }
  }
  
  /// 错误日志 - 仅在调试模式下输出
  static void error(String message, {String? context, Object? error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      final contextStr = context != null ? '[$context] ' : '';
      debugPrint('$_tag ERROR $contextStr$message');
      if (error != null) {
        debugPrint('$_tag ERROR Details: $error');
      }
      if (stackTrace != null) {
        debugPrint('$_tag ERROR StackTrace: $stackTrace');
      }
    }
  }
  
  /// 性能日志 - 仅在调试模式下输出
  static void performance(String message, {String? context}) {
    if (kDebugMode) {
      final contextStr = context != null ? '[$context] ' : '';
      debugPrint('$_tag PERFORMANCE $contextStr$message');
    }
  }
  
  /// 数据库日志 - 仅在调试模式下输出
  static void database(String message, {String? context}) {
    if (kDebugMode) {
      final contextStr = context != null ? '[$context] ' : '';
      debugPrint('$_tag DATABASE $contextStr$message');
    }
  }
  
  /// 文件系统日志 - 仅在调试模式下输出
  static void fileSystem(String message, {String? context}) {
    if (kDebugMode) {
      final contextStr = context != null ? '[$context] ' : '';
      debugPrint('$_tag FILESYSTEM $contextStr$message');
    }
  }
  
  /// 媒体日志 - 仅在调试模式下输出
  static void media(String message, {String? context}) {
    if (kDebugMode) {
      final contextStr = context != null ? '[$context] ' : '';
      debugPrint('$_tag MEDIA $contextStr$message');
    }
  }
  
  /// 用户操作日志 - 仅在调试模式下输出
  static void userAction(String message, {String? context}) {
    if (kDebugMode) {
      final contextStr = context != null ? '[$context] ' : '';
      debugPrint('$_tag USER_ACTION $contextStr$message');
    }
  }
} 