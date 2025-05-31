// lib/core/service_locator.dart
// 服务定位器和依赖注入管理

import 'package:flutter/foundation.dart';
import '../services/database_service.dart';
import '../services/media_service.dart';
import '../services/file_service.dart';
import '../services/cache_service.dart';
import '../services/performance_service.dart';
import '../services/error_service.dart';
import '../services/backup_service.dart';
import 'app_state.dart';

/// 服务定位器 - 管理所有服务的单例实例
class ServiceLocator {
  static final ServiceLocator _instance = ServiceLocator._internal();
  factory ServiceLocator() => _instance;
  ServiceLocator._internal();

  final Map<Type, dynamic> _services = {};
  bool _isInitialized = false;

  /// 初始化所有服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 注册状态管理
      registerSingleton<AppThemeState>(AppThemeState());
      registerSingleton<AppPerformanceState>(AppPerformanceState());
      registerSingleton<AppErrorState>(AppErrorState());

      // 注册核心服务
      registerSingleton<ErrorService>(ErrorService());
      registerSingleton<PerformanceService>(PerformanceService());
      registerSingleton<CacheService>(CacheService());
      
      // 初始化缓存服务
      await get<CacheService>().initialize();
      
      // 注册数据库服务
      registerSingleton<DatabaseService>(DatabaseService());
      await get<DatabaseService>().initialize();
      
      // 注册文件服务
      registerSingleton<FileService>(FileService());
      await get<FileService>().initialize();
      
      // 注册媒体服务
      registerSingleton<MediaService>(MediaService());
      await get<MediaService>().initialize();
      
      // 注册备份服务
      registerSingleton<BackupService>(BackupService());
      
      _isInitialized = true;
      
      if (kDebugMode) {
        print('ServiceLocator: 所有服务初始化完成');
      }
    } catch (e, stackTrace) {
      get<ErrorService>().handleError(
        AppError(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: '服务初始化失败',
          message: e.toString(),
          timestamp: DateTime.now(),
          severity: ErrorSeverity.critical,
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }

  /// 注册单例服务
  void registerSingleton<T>(T instance) {
    _services[T] = instance;
  }

  /// 注册工厂服务
  void registerFactory<T>(T Function() factory) {
    _services[T] = factory;
  }

  /// 获取服务实例
  T get<T>() {
    final service = _services[T];
    if (service == null) {
      throw Exception('Service of type $T is not registered');
    }
    
    if (service is Function) {
      return service() as T;
    }
    
    return service as T;
  }

  /// 检查服务是否已注册
  bool isRegistered<T>() {
    return _services.containsKey(T);
  }

  /// 移除服务
  void unregister<T>() {
    _services.remove(T);
  }

  /// 清理所有服务
  Future<void> dispose() async {
    try {
      // 按依赖顺序清理服务
      if (isRegistered<MediaService>()) {
        await get<MediaService>().dispose();
      }
      
      if (isRegistered<DatabaseService>()) {
        await get<DatabaseService>().dispose();
      }
      
      if (isRegistered<FileService>()) {
        await get<FileService>().dispose();
      }
      
      if (isRegistered<CacheService>()) {
        await get<CacheService>().dispose();
      }
      
      _services.clear();
      _isInitialized = false;
      
      if (kDebugMode) {
        print('ServiceLocator: 所有服务已清理');
      }
    } catch (e) {
      if (kDebugMode) {
        print('ServiceLocator dispose error: $e');
      }
    }
  }

  /// 重新初始化服务
  Future<void> reinitialize() async {
    await dispose();
    await initialize();
  }
}

/// 全局服务定位器实例
final serviceLocator = ServiceLocator();

/// 便捷的获取服务方法
T getService<T>() => serviceLocator.get<T>();