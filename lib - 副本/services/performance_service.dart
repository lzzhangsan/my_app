// lib/services/performance_service.dart
// 性能监控服务 - 监控应用性能指标

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PerformanceService {
  static final PerformanceService _instance = PerformanceService._internal();
  factory PerformanceService() => _instance;
  PerformanceService._internal();

  bool _isInitialized = false;
  Timer? _monitoringTimer;
  final List<PerformanceMetric> _metrics = [];
  final StreamController<PerformanceMetric> _metricsController = StreamController.broadcast();
  
  // 性能阈值
  static const int _maxMetricsHistory = 100;
  static const Duration _monitoringInterval = Duration(seconds: 5);
  static const double _memoryWarningThreshold = 0.8; // 80%
  static const double _memoryDangerThreshold = 0.9; // 90%
  
  bool get isInitialized => _isInitialized;
  List<PerformanceMetric> get metrics => List.unmodifiable(_metrics);
  Stream<PerformanceMetric> get metricsStream => _metricsController.stream;
  
  /// 初始化性能监控服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 开始性能监控
      _startMonitoring();
      
      _isInitialized = true;
      
      if (kDebugMode) {
        print('PerformanceService: 初始化完成');
        print('监控间隔: ${_monitoringInterval.inSeconds}秒');
      }
    } catch (e) {
      if (kDebugMode) {
        print('PerformanceService 初始化失败: $e');
      }
      rethrow;
    }
  }

  /// 开始性能监控
  void _startMonitoring() {
    _monitoringTimer?.cancel();
    _monitoringTimer = Timer.periodic(_monitoringInterval, (timer) {
      _collectMetrics();
    });
  }

  /// 收集性能指标
  Future<void> _collectMetrics() async {
    try {
      final metric = await _getCurrentMetrics();
      
      // 添加到历史记录
      _metrics.add(metric);
      
      // 保持历史记录在限制范围内
      if (_metrics.length > _maxMetricsHistory) {
        _metrics.removeAt(0);
      }
      
      // 发送到流
      _metricsController.add(metric);
      
      // 检查性能警告
      _checkPerformanceWarnings(metric);
      
    } catch (e) {
      if (kDebugMode) {
        print('收集性能指标失败: $e');
      }
    }
  }

  /// 获取当前性能指标
  Future<PerformanceMetric> _getCurrentMetrics() async {
    final timestamp = DateTime.now();
    
    // 获取内存使用情况
    final memoryInfo = await _getMemoryInfo();
    
    // 获取CPU使用情况（简化版）
    final cpuUsage = await _getCpuUsage();
    
    // 获取帧率信息
    final frameRate = await _getFrameRate();
    
    return PerformanceMetric(
      timestamp: timestamp,
      memoryUsage: memoryInfo['used'] ?? 0,
      memoryTotal: memoryInfo['total'] ?? 0,
      memoryPercentage: memoryInfo['percentage'] ?? 0.0,
      cpuUsage: cpuUsage,
      frameRate: frameRate,
      batteryLevel: await _getBatteryLevel(),
    );
  }

  /// 获取内存信息
  Future<Map<String, dynamic>> _getMemoryInfo() async {
    try {
      if (Platform.isAndroid) {
        // Android内存信息
        const platform = MethodChannel('performance_service');
        final result = await platform.invokeMethod('getMemoryInfo');
        return Map<String, dynamic>.from(result);
      } else if (Platform.isIOS) {
        // iOS内存信息
        const platform = MethodChannel('performance_service');
        final result = await platform.invokeMethod('getMemoryInfo');
        return Map<String, dynamic>.from(result);
      } else {
        // 其他平台的模拟数据
        return {
          'used': 100 * 1024 * 1024, // 100MB
          'total': 1024 * 1024 * 1024, // 1GB
          'percentage': 0.1,
        };
      }
    } catch (e) {
      // 返回默认值
      return {
        'used': 0,
        'total': 1024 * 1024 * 1024,
        'percentage': 0.0,
      };
    }
  }

  /// 获取CPU使用率
  Future<double> _getCpuUsage() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        const platform = MethodChannel('performance_service');
        final result = await platform.invokeMethod('getCpuUsage');
        return (result as num).toDouble();
      } else {
        // 其他平台返回模拟数据
        return 0.1; // 10%
      }
    } catch (e) {
      return 0.0;
    }
  }

  /// 获取帧率
  Future<double> _getFrameRate() async {
    try {
      // 这里可以集成更复杂的帧率监控
      // 目前返回默认值
      return 60.0;
    } catch (e) {
      return 0.0;
    }
  }

  /// 获取电池电量
  Future<double> _getBatteryLevel() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        const platform = MethodChannel('performance_service');
        final result = await platform.invokeMethod('getBatteryLevel');
        return (result as num).toDouble();
      } else {
        return 1.0; // 100%
      }
    } catch (e) {
      return 1.0;
    }
  }

  /// 检查性能警告
  void _checkPerformanceWarnings(PerformanceMetric metric) {
    // 内存使用警告
    if (metric.memoryPercentage >= _memoryDangerThreshold) {
      _logPerformanceWarning(
        'DANGER: 内存使用率过高',
        '当前使用率: ${(metric.memoryPercentage * 100).toStringAsFixed(1)}%',
        PerformanceWarningLevel.danger,
      );
    } else if (metric.memoryPercentage >= _memoryWarningThreshold) {
      _logPerformanceWarning(
        'WARNING: 内存使用率较高',
        '当前使用率: ${(metric.memoryPercentage * 100).toStringAsFixed(1)}%',
        PerformanceWarningLevel.warning,
      );
    }
    
    // CPU使用警告
    if (metric.cpuUsage >= 0.8) {
      _logPerformanceWarning(
        'WARNING: CPU使用率较高',
        '当前使用率: ${(metric.cpuUsage * 100).toStringAsFixed(1)}%',
        PerformanceWarningLevel.warning,
      );
    }
    
    // 帧率警告
    if (metric.frameRate < 30) {
      _logPerformanceWarning(
        'WARNING: 帧率较低',
        '当前帧率: ${metric.frameRate.toStringAsFixed(1)} FPS',
        PerformanceWarningLevel.warning,
      );
    }
  }

  /// 记录性能警告
  void _logPerformanceWarning(String title, String message, PerformanceWarningLevel level) {
    if (kDebugMode) {
      print('[$level] $title: $message');
    }
    
    // 这里可以集成到错误报告系统
  }

  /// 获取平均性能指标
  PerformanceMetric? getAverageMetrics({Duration? period}) {
    if (_metrics.isEmpty) return null;
    
    List<PerformanceMetric> relevantMetrics;
    
    if (period != null) {
      final cutoffTime = DateTime.now().subtract(period);
      relevantMetrics = _metrics.where((m) => m.timestamp.isAfter(cutoffTime)).toList();
    } else {
      relevantMetrics = _metrics;
    }
    
    if (relevantMetrics.isEmpty) return null;
    
    final avgMemoryUsage = relevantMetrics.map((m) => m.memoryUsage).reduce((a, b) => a + b) / relevantMetrics.length;
    final avgMemoryTotal = relevantMetrics.map((m) => m.memoryTotal).reduce((a, b) => a + b) / relevantMetrics.length;
    final avgMemoryPercentage = relevantMetrics.map((m) => m.memoryPercentage).reduce((a, b) => a + b) / relevantMetrics.length;
    final avgCpuUsage = relevantMetrics.map((m) => m.cpuUsage).reduce((a, b) => a + b) / relevantMetrics.length;
    final avgFrameRate = relevantMetrics.map((m) => m.frameRate).reduce((a, b) => a + b) / relevantMetrics.length;
    final avgBatteryLevel = relevantMetrics.map((m) => m.batteryLevel).reduce((a, b) => a + b) / relevantMetrics.length;
    
    return PerformanceMetric(
      timestamp: DateTime.now(),
      memoryUsage: avgMemoryUsage.round(),
      memoryTotal: avgMemoryTotal.round(),
      memoryPercentage: avgMemoryPercentage,
      cpuUsage: avgCpuUsage,
      frameRate: avgFrameRate,
      batteryLevel: avgBatteryLevel,
    );
  }

  /// 获取性能报告
  Map<String, dynamic> getPerformanceReport() {
    if (_metrics.isEmpty) {
      return {
        'status': 'no_data',
        'message': '暂无性能数据',
      };
    }
    
    final latest = _metrics.last;
    final average = getAverageMetrics();
    
    return {
      'status': 'ok',
      'timestamp': DateTime.now().toIso8601String(),
      'latest': latest.toMap(),
      'average': average?.toMap(),
      'metrics_count': _metrics.length,
      'monitoring_duration': _metrics.isNotEmpty 
          ? DateTime.now().difference(_metrics.first.timestamp).inMinutes
          : 0,
    };
  }

  /// 强制收集一次性能指标
  Future<PerformanceMetric> collectMetricsOnce() async {
    return await _getCurrentMetrics();
  }

  /// 清空性能历史
  void clearMetrics() {
    _metrics.clear();
    if (kDebugMode) {
      print('性能指标历史已清空');
    }
  }

  /// 暂停监控
  void pauseMonitoring() {
    _monitoringTimer?.cancel();
    if (kDebugMode) {
      print('性能监控已暂停');
    }
  }

  /// 恢复监控
  void resumeMonitoring() {
    if (_isInitialized) {
      _startMonitoring();
      if (kDebugMode) {
        print('性能监控已恢复');
      }
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    _monitoringTimer?.cancel();
    _metrics.clear();
    await _metricsController.close();
    _isInitialized = false;
    
    if (kDebugMode) {
      print('PerformanceService: 资源已释放');
    }
  }
}

/// 性能指标数据类
class PerformanceMetric {
  final DateTime timestamp;
  final int memoryUsage; // 字节
  final int memoryTotal; // 字节
  final double memoryPercentage; // 0.0 - 1.0
  final double cpuUsage; // 0.0 - 1.0
  final double frameRate; // FPS
  final double batteryLevel; // 0.0 - 1.0

  const PerformanceMetric({
    required this.timestamp,
    required this.memoryUsage,
    required this.memoryTotal,
    required this.memoryPercentage,
    required this.cpuUsage,
    required this.frameRate,
    required this.batteryLevel,
  });

  Map<String, dynamic> toMap() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'memory_usage': memoryUsage,
      'memory_total': memoryTotal,
      'memory_percentage': memoryPercentage,
      'cpu_usage': cpuUsage,
      'frame_rate': frameRate,
      'battery_level': batteryLevel,
    };
  }

  factory PerformanceMetric.fromMap(Map<String, dynamic> map) {
    return PerformanceMetric(
      timestamp: DateTime.parse(map['timestamp']),
      memoryUsage: map['memory_usage'],
      memoryTotal: map['memory_total'],
      memoryPercentage: map['memory_percentage'],
      cpuUsage: map['cpu_usage'],
      frameRate: map['frame_rate'],
      batteryLevel: map['battery_level'],
    );
  }

  @override
  String toString() {
    return 'PerformanceMetric(memory: ${(memoryPercentage * 100).toStringAsFixed(1)}%, '
           'cpu: ${(cpuUsage * 100).toStringAsFixed(1)}%, '
           'fps: ${frameRate.toStringAsFixed(1)}, '
           'battery: ${(batteryLevel * 100).toStringAsFixed(1)}%)';
  }
}

/// 性能警告级别
enum PerformanceWarningLevel {
  info,
  warning,
  danger,
}