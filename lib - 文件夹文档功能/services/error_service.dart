// lib/services/error_service.dart
// 错误管理服务 - 处理应用错误收集和报告

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/app_state.dart';

class ErrorService {
  static final ErrorService _instance = ErrorService._internal();
  factory ErrorService() => _instance;
  ErrorService._internal();

  bool _isInitialized = false;
  final List<AppError> _errors = [];
  final StreamController<AppError> _errorController = StreamController.broadcast();
  
  // 错误配置
  static const int _maxErrorHistory = 200;
  static const Duration _errorRetentionPeriod = Duration(days: 7);
  
  bool get isInitialized => _isInitialized;
  List<AppError> get errors => List.unmodifiable(_errors);
  Stream<AppError> get errorStream => _errorController.stream;
  
  /// 处理错误
  void handleError(dynamic error, {StackTrace? stackTrace, String? context}) {
    final appError = AppError(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: context ?? 'Application Error',
      message: error.toString(),
      timestamp: DateTime.now(),
      severity: ErrorSeverity.medium,
      stackTrace: stackTrace ?? StackTrace.current,
    );
    
    _logError(appError);
  }

  /// 记录错误日志
  void _logError(AppError appError) {
    if (kDebugMode) {
      debugPrint('ErrorService: ${appError.severity.name.toUpperCase()} - ${appError.title}');
      debugPrint('Message: ${appError.message}');
      if (appError.stackTrace != null) {
        debugPrint('StackTrace: ${appError.stackTrace}');
      }
    }
    
    // 这里可以添加其他日志记录逻辑，比如写入文件或发送到远程服务器
  }
  
  /// 初始化错误服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 设置全局错误处理
      _setupGlobalErrorHandling();
      
      // 清理过期错误
      await _cleanupOldErrors();
      
      _isInitialized = true;
      
      if (kDebugMode) {
        debugPrint('ErrorService: 初始化完成，错误保留期: ${_errorRetentionPeriod.inDays}天');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ErrorService 初始化失败: $e');
      }
      rethrow;
    }
  }

  /// 设置全局错误处理
  void _setupGlobalErrorHandling() {
    // Flutter错误处理
    FlutterError.onError = (FlutterErrorDetails details) {
      recordError(
        details.exception,
        details.stack,
        context: 'Flutter Framework',
        severity: ErrorSeverity.high,
        additionalInfo: {
          'library': details.library,
          'context': details.context?.toString(),
        },
      );
    };
    
    // Dart错误处理
    PlatformDispatcher.instance.onError = (error, stack) {
      recordError(
        error,
        stack,
        context: 'Dart Runtime',
        severity: ErrorSeverity.critical,
      );
      return true;
    };
  }

  /// 记录错误
  void recordError(
    dynamic error,
    StackTrace? stackTrace, {
    String? context,
    ErrorSeverity severity = ErrorSeverity.medium,
    Map<String, dynamic>? additionalInfo,
  }) {
    try {
      final appError = AppError(
        id: _generateErrorId(),
        title: context ?? 'Application Error',
        message: error.toString(),
        timestamp: DateTime.now(),
        severity: severity ?? ErrorSeverity.medium,
        stackTrace: stackTrace,
      );
      
      // 添加到错误列表
      _errors.add(appError);
      
      // 保持错误历史在限制范围内
      if (_errors.length > _maxErrorHistory) {
        _errors.removeAt(0);
      }
      
      // 发送到流
      _errorController.add(appError);
      
      // 在调试模式下打印错误
      if (kDebugMode) {
        debugPrint('[$severity] 错误记录: ${appError.message}');
        if (context != null) {
          debugPrint('上下文: $context');
        }
        if (stackTrace != null) {
          debugPrint('堆栈跟踪: $stackTrace');
        }
      }
      
      // 处理严重错误
      _handleSevereError(appError);
      
    } catch (e) {
      if (kDebugMode) {
        debugPrint('记录错误失败: $e');
      }
    }
  }

  /// 记录网络错误
  void recordNetworkError(
    String url,
    int? statusCode,
    String? message, {
    Map<String, dynamic>? additionalInfo,
  }) {
    recordError(
      'Network Error: $message',
      StackTrace.current,
      context: 'Network Request',
      severity: ErrorSeverity.medium,
      additionalInfo: {
        'url': url,
        'status_code': statusCode,
        'type': 'network',
        ...?additionalInfo,
      },
    );
  }

  /// 记录数据库错误
  void recordDatabaseError(
    String operation,
    String? message, {
    Map<String, dynamic>? additionalInfo,
  }) {
    recordError(
      'Database Error: $message',
      StackTrace.current,
      context: 'Database Operation',
      severity: ErrorSeverity.high,
      additionalInfo: {
        'operation': operation,
        'type': 'database',
        ...?additionalInfo,
      },
    );
  }

  /// 记录文件系统错误
  void recordFileSystemError(
    String operation,
    String? path,
    String? message, {
    Map<String, dynamic>? additionalInfo,
  }) {
    recordError(
      'FileSystem Error: $message',
      StackTrace.current,
      context: 'File System',
      severity: ErrorSeverity.medium,
      additionalInfo: {
        'operation': operation,
        'path': path,
        'type': 'filesystem',
        ...?additionalInfo,
      },
    );
  }

  /// 记录用户操作错误
  void recordUserError(
    String action,
    String? message, {
    Map<String, dynamic>? additionalInfo,
  }) {
    recordError(
      'User Error: $message',
      StackTrace.current,
      context: 'User Action',
      severity: ErrorSeverity.low,
      additionalInfo: {
        'action': action,
        'type': 'user',
        ...?additionalInfo,
      },
    );
  }

  /// 处理严重错误
  void _handleSevereError(AppError error) {
    if (error.severity == ErrorSeverity.critical) {
      // 严重错误处理逻辑
      if (kDebugMode) {
        print('CRITICAL ERROR DETECTED: ${error.error}');
      }
      
      // 这里可以添加崩溃报告、用户通知等逻辑
    }
  }

  /// 生成错误ID
  String _generateErrorId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = (timestamp % 10000).toString().padLeft(4, '0');
    return 'ERR_${timestamp}_$random';
  }

  /// 获取错误统计
  Map<String, dynamic> getErrorStatistics({Duration? period}) {
    List<AppError> relevantErrors;
    
    if (period != null) {
      final cutoffTime = DateTime.now().subtract(period);
      relevantErrors = _errors.where((e) => e.timestamp.isAfter(cutoffTime)).toList();
    } else {
      relevantErrors = _errors;
    }
    
    if (relevantErrors.isEmpty) {
      return {
        'total_errors': 0,
        'by_severity': {},
        'by_context': {},
        'by_type': {},
        'recent_errors': [],
      };
    }
    
    // 按严重程度统计
    final bySeverity = <String, int>{};
    for (final error in relevantErrors) {
      final severity = error.severity.toString().split('.').last;
      bySeverity[severity] = (bySeverity[severity] ?? 0) + 1;
    }
    
    // 按上下文统计
    final byContext = <String, int>{};
    for (final error in relevantErrors) {
      final context = error.context ?? 'Unknown';
      byContext[context] = (byContext[context] ?? 0) + 1;
    }
    
    // 按类型统计
    final byType = <String, int>{};
    for (final error in relevantErrors) {
      final type = error.additionalInfo['type'] ?? 'unknown';
      byType[type] = (byType[type] ?? 0) + 1;
    }
    
    // 最近的错误
    final recentErrors = relevantErrors
        .take(10)
        .map((e) => {
              'id': e.id,
              'timestamp': e.timestamp.toIso8601String(),
              'error': e.error,
              'severity': e.severity.toString().split('.').last,
              'context': e.context,
            })
        .toList();
    
    return {
      'total_errors': relevantErrors.length,
      'by_severity': bySeverity,
      'by_context': byContext,
      'by_type': byType,
      'recent_errors': recentErrors,
      'period_hours': period?.inHours,
    };
  }

  /// 获取错误报告
  Map<String, dynamic> getErrorReport() {
    final now = DateTime.now();
    final last24Hours = getErrorStatistics(period: const Duration(hours: 24));
    final last7Days = getErrorStatistics(period: const Duration(days: 7));
    final allTime = getErrorStatistics();
    
    return {
      'timestamp': now.toIso8601String(),
      'last_24_hours': last24Hours,
      'last_7_days': last7Days,
      'all_time': allTime,
      'error_retention_days': _errorRetentionPeriod.inDays,
      'max_error_history': _maxErrorHistory,
    };
  }

  /// 根据ID获取错误详情
  AppError? getErrorById(String id) {
    try {
      return _errors.firstWhere((error) => error.id == id);
    } catch (e) {
      return null;
    }
  }

  /// 获取特定严重程度的错误
  List<AppError> getErrorsBySeverity(ErrorSeverity severity) {
    return _errors.where((error) => error.severity == severity).toList();
  }

  /// 获取特定上下文的错误
  List<AppError> getErrorsByContext(String context) {
    return _errors.where((error) => error.context == context).toList();
  }

  /// 搜索错误
  List<AppError> searchErrors(String query) {
    final lowerQuery = query.toLowerCase();
    return _errors.where((error) {
      return error.error.toLowerCase().contains(lowerQuery) ||
             (error.context?.toLowerCase().contains(lowerQuery) ?? false) ||
             error.id.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// 导出错误数据
  String exportErrors({ErrorSeverity? minSeverity, Duration? period}) {
    List<AppError> errorsToExport = _errors;
    
    // 按时间过滤
    if (period != null) {
      final cutoffTime = DateTime.now().subtract(period);
      errorsToExport = errorsToExport.where((e) => e.timestamp.isAfter(cutoffTime)).toList();
    }
    
    // 按严重程度过滤
    if (minSeverity != null) {
      errorsToExport = errorsToExport.where((e) => e.severity.index >= minSeverity.index).toList();
    }
    
    final exportData = {
      'export_timestamp': DateTime.now().toIso8601String(),
      'total_errors': errorsToExport.length,
      'filters': {
        'min_severity': minSeverity?.toString(),
        'period_hours': period?.inHours,
      },
      'errors': errorsToExport.map((e) => e.toMap()).toList(),
    };
    
    return jsonEncode(exportData);
  }

  /// 清理过期错误
  Future<void> _cleanupOldErrors() async {
    try {
      final cutoffTime = DateTime.now().subtract(_errorRetentionPeriod);
      final initialCount = _errors.length;
      
      _errors.removeWhere((error) => error.timestamp.isBefore(cutoffTime));
      
      final removedCount = initialCount - _errors.length;
      if (kDebugMode && removedCount > 0) {
        debugPrint('清理过期错误: $removedCount 条');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('清理过期错误失败: $e');
      }
    }
  }

  /// 清空所有错误
  void clearAllErrors() {
    _errors.clear();
    if (kDebugMode) {
      debugPrint('所有错误记录已清空');
    }
  }

  /// 清空特定严重程度的错误
  void clearErrorsBySeverity(ErrorSeverity severity) {
    final initialCount = _errors.length;
    _errors.removeWhere((error) => error.severity == severity);
    final removedCount = initialCount - _errors.length;
    
    if (kDebugMode) {
      debugPrint('清空 $severity 级别错误: $removedCount 条');
    }
  }

  /// 手动触发错误清理
  Future<void> cleanupErrors() async {
    await _cleanupOldErrors();
  }

  /// 释放资源
  Future<void> dispose() async {
    _errors.clear();
    await _errorController.close();
    _isInitialized = false;
    
    if (kDebugMode) {
      debugPrint('ErrorService: 资源已释放');
    }
  }
}