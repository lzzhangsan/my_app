// lib/core/app_state.dart
// 全局应用状态管理

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 应用主题状态
class AppThemeState extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  Color _primaryColor = Colors.blue;
  bool _isDarkMode = false;

  ThemeMode get themeMode => _themeMode;
  Color get primaryColor => _primaryColor;
  bool get isDarkMode => _isDarkMode;

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    _isDarkMode = mode == ThemeMode.dark;
    notifyListeners();
  }

  void setPrimaryColor(Color color) {
    _primaryColor = color;
    notifyListeners();
  }

  ThemeData get lightTheme => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _primaryColor,
      brightness: Brightness.light,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
    ),
    cardTheme: CardThemeData(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      filled: true,
    ),
  );

  ThemeData get darkTheme => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _primaryColor,
      brightness: Brightness.dark,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
    ),
    cardTheme: CardThemeData(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      filled: true,
    ),
  );
}

/// 应用性能监控状态
class AppPerformanceState extends ChangeNotifier {
  int _memoryUsage = 0;
  double _frameRate = 60.0;
  List<String> _performanceLogs = [];
  bool _isMonitoring = false;

  int get memoryUsage => _memoryUsage;
  double get frameRate => _frameRate;
  List<String> get performanceLogs => List.unmodifiable(_performanceLogs);
  bool get isMonitoring => _isMonitoring;

  void updateMemoryUsage(int usage) {
    _memoryUsage = usage;
    notifyListeners();
  }

  void updateFrameRate(double rate) {
    _frameRate = rate;
    notifyListeners();
  }

  void addPerformanceLog(String log) {
    _performanceLogs.add('${DateTime.now()}: $log');
    if (_performanceLogs.length > 100) {
      _performanceLogs.removeAt(0);
    }
    notifyListeners();
  }

  void startMonitoring() {
    _isMonitoring = true;
    notifyListeners();
  }

  void stopMonitoring() {
    _isMonitoring = false;
    notifyListeners();
  }

  void clearLogs() {
    _performanceLogs.clear();
    notifyListeners();
  }
}

/// 应用错误状态管理
class AppErrorState extends ChangeNotifier {
  List<AppError> _errors = [];
  bool _hasUnreadErrors = false;

  List<AppError> get errors => List.unmodifiable(_errors);
  bool get hasUnreadErrors => _hasUnreadErrors;

  void addError(AppError error) {
    _errors.add(error);
    _hasUnreadErrors = true;
    if (_errors.length > 50) {
      _errors.removeAt(0);
    }
    notifyListeners();
  }

  void markErrorsAsRead() {
    _hasUnreadErrors = false;
    notifyListeners();
  }

  void clearErrors() {
    _errors.clear();
    _hasUnreadErrors = false;
    notifyListeners();
  }

  void removeError(String id) {
    _errors.removeWhere((error) => error.id == id);
    notifyListeners();
  }
}

/// 错误信息类
class AppError {
  final String id;
  final String title;
  final String message;
  final DateTime timestamp;
  final ErrorSeverity severity;
  final StackTrace? stackTrace;
  final String? context;
  final String error;
  final Map<String, dynamic> additionalInfo;

  AppError({
    required this.id,
    required this.title,
    required this.message,
    required this.timestamp,
    required this.severity,
    this.stackTrace,
    this.context,
    String? error,
    Map<String, dynamic>? additionalInfo,
  }) : error = error ?? message,
       additionalInfo = additionalInfo ?? {};

  factory AppError.fromException(Exception exception, {ErrorSeverity? severity}) {
    return AppError(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: '应用错误',
      message: exception.toString(),
      timestamp: DateTime.now(),
      severity: severity ?? ErrorSeverity.medium,
      stackTrace: StackTrace.current,
    );
  }

  /// 将错误对象转换为Map，用于序列化
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'message': message,
      'timestamp': timestamp.toIso8601String(),
      'severity': severity.toString(),
      'stackTrace': stackTrace?.toString(),
      'context': context,
      'error': error,
      'additionalInfo': additionalInfo,
    };
  }
}

enum ErrorSeverity { low, medium, high, critical }