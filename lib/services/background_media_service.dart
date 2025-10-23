// lib/services/background_media_service.dart
// 后台媒体服务 - 实现全局媒体库监听和自动导入

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/service_locator.dart';
import 'database_service.dart';
import 'media_service.dart';
import '../models/media_item.dart';
import '../models/media_type.dart';

@pragma('vm:entry-point')
/// 后台媒体服务 - 全局媒体库监听和自动导入
class BackgroundMediaService {
  static final BackgroundMediaService _instance = BackgroundMediaService._internal();
  factory BackgroundMediaService() => _instance;
  BackgroundMediaService._internal();

  bool _isInitialized = false;
  bool _isRunning = false;
  Set<String> _initialAssetIds = {};
  Timer? _healthCheckTimer;
  
  bool get isInitialized => _isInitialized;
  bool get isRunning => _isRunning;

  /// 初始化后台媒体服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 请求必要权限
      await _requestPermissions();
      
      // 初始化后台服务
      await _initializeBackgroundService();
      
      _isInitialized = true;
      
      if (kDebugMode) {
        print('BackgroundMediaService: 初始化完成');
      }
    } catch (e) {
      if (kDebugMode) {
        print('BackgroundMediaService 初始化失败: $e');
      }
      rethrow;
    }
  }

  /// 请求必要权限
  Future<void> _requestPermissions() async {
    try {
      // 请求存储权限
      var storageStatus = await Permission.storage.request();
      if (kDebugMode) {
        print('存储权限状态: $storageStatus');
      }
      
      // 请求媒体库权限
      var photosStatus = await Permission.photos.request();
      if (kDebugMode) {
        print('媒体库权限状态: $photosStatus');
      }
      
      // 请求管理外部存储权限（Android 11+）
      if (Platform.isAndroid) {
        var manageStorageStatus = await Permission.manageExternalStorage.request();
        if (kDebugMode) {
          print('管理外部存储权限状态: $manageStorageStatus');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('请求权限失败: $e');
      }
    }
  }

  /// 初始化后台服务
  Future<void> _initializeBackgroundService() async {
    try {
      final service = FlutterBackgroundService();
      
      // 配置后台服务
      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          autoStart: true,
          isForegroundMode: false, // 暂时禁用前台服务模式
        ),
        iosConfiguration: IosConfiguration(
          autoStart: true,
          onForeground: onStart,
          onBackground: onIosBackground,
        ),
      );
      
      // 启动后台服务
      await service.startService();
      
      if (kDebugMode) {
        print('后台服务已启动');
      }
    } catch (e) {
      if (kDebugMode) {
        print('初始化后台服务失败: $e');
      }
      rethrow;
    }
  }

  /// 后台服务启动回调
  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    if (kDebugMode) {
      print('后台媒体服务启动');
    }
    
    try {
      // 初始化服务定位器（如果未初始化）
      if (!serviceLocator.isInitialized) {
        await serviceLocator.initialize();
      }
      
      // 开始媒体库监听
      await _startMediaLibraryMonitoring(service);
      
      // 启动健康检查定时器
      _startHealthCheck(service);
      
    } catch (e) {
      if (kDebugMode) {
        print('后台服务启动失败: $e');
      }
    }
  }

  /// iOS后台回调
  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    if (kDebugMode) {
      print('iOS后台服务运行');
    }
    return true;
  }

  /// 开始媒体库监听
  static Future<void> _startMediaLibraryMonitoring(ServiceInstance service) async {
    try {
      // 获取当前所有媒体ID快照
      await _captureInitialMediaSnapshot();
      
      // 注册媒体库变化监听
      PhotoManager.addChangeCallback(_onPhotoLibraryChanged);
      PhotoManager.startChangeNotify();
      
      if (kDebugMode) {
        print('媒体库监听已启动，初始媒体数量: ${_instance._initialAssetIds.length}');
      }
      
      _instance._isRunning = true;
      
    } catch (e) {
      if (kDebugMode) {
        print('启动媒体库监听失败: $e');
      }
    }
  }

  /// 捕获初始媒体快照
  static Future<void> _captureInitialMediaSnapshot() async {
    try {
      final List<AssetPathEntity> imgPaths = await PhotoManager.getAssetPathList(type: RequestType.image);
      final List<AssetPathEntity> vidPaths = await PhotoManager.getAssetPathList(type: RequestType.video);
      
      final List<AssetEntity> allAssets = [];
      for (final path in [...imgPaths, ...vidPaths]) {
        allAssets.addAll(await path.getAssetListRange(start: 0, end: 100000));
      }
      
      _instance._initialAssetIds = allAssets.map((e) => e.id).toSet();
      
      if (kDebugMode) {
        print('已捕获初始媒体快照，共 ${_instance._initialAssetIds.length} 个媒体');
      }
    } catch (e) {
      if (kDebugMode) {
        print('捕获初始媒体快照失败: $e');
      }
    }
  }

  /// 媒体库变化回调
  static Future<void> _onPhotoLibraryChanged([MethodCall? call]) async {
    if (kDebugMode) {
      print('[后台服务] 媒体库变更回调被触发');
    }
    
    try {
      // 获取当前所有媒体
      final List<AssetPathEntity> imgPaths = await PhotoManager.getAssetPathList(type: RequestType.image);
      final List<AssetPathEntity> vidPaths = await PhotoManager.getAssetPathList(type: RequestType.video);
      
      final List<AssetEntity> allAssets = [];
      for (final path in [...imgPaths, ...vidPaths]) {
        allAssets.addAll(await path.getAssetListRange(start: 0, end: 100000));
      }
      
      final Set<String> currentAssetIds = allAssets.map((e) => e.id).toSet();
      
      // 找出新增的媒体
      final Set<String> newAssetIds = currentAssetIds.difference(_instance._initialAssetIds);
      
      if (newAssetIds.isNotEmpty) {
        if (kDebugMode) {
          print('[后台服务] 检测到 ${newAssetIds.length} 个新增媒体');
        }
        
        // 处理新增媒体
        await _processNewMedia(newAssetIds, allAssets);
        
        // 更新快照
        _instance._initialAssetIds = currentAssetIds;
      }
    } catch (e) {
      if (kDebugMode) {
        print('[后台服务] 处理媒体库变化失败: $e');
      }
    }
  }

  /// 处理新增媒体
  static Future<void> _processNewMedia(Set<String> newAssetIds, List<AssetEntity> allAssets) async {
    try {
      final mediaService = getService<MediaService>();
      
      for (final assetId in newAssetIds) {
        try {
          final asset = allAssets.firstWhere((e) => e.id == assetId);
          
          if (kDebugMode) {
            print('[后台服务] 处理新增媒体: ${asset.title}');
          }
          
          // 导入媒体到应用媒体库
          final mediaItem = await _importMediaToApp(asset, mediaService);
          
          if (mediaItem != null) {
            // 尝试彻底删除本地媒体
            await _deleteLocalMedia(asset);
            
            if (kDebugMode) {
              print('[后台服务] 成功导入并删除媒体: ${asset.title}');
            }
          }
        } catch (e) {
          if (kDebugMode) {
            print('[后台服务] 处理单个媒体失败: $e');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[后台服务] 批量处理新增媒体失败: $e');
      }
    }
  }

  /// 导入媒体到应用媒体库
  static Future<MediaItem?> _importMediaToApp(AssetEntity asset, MediaService mediaService) async {
    try {
      // 获取媒体文件
      final File? mediaFile = await asset.file;
      if (mediaFile == null || !await mediaFile.exists()) {
        if (kDebugMode) {
          print('[后台服务] 媒体文件不存在: ${asset.title}');
        }
        return null;
      }
      
      // 确定媒体类型
      if (asset.type != AssetType.image && asset.type != AssetType.video) {
        if (kDebugMode) {
          print('[后台服务] 不支持的媒体类型: ${asset.type}');
        }
        return null;
      }
      
      // 导入到应用媒体库
      final mediaItem = await mediaService.addMediaFile(mediaFile);
      
      if (kDebugMode) {
        print('[后台服务] 成功导入媒体: ${mediaItem?.name}');
      }
      
      return mediaItem;
    } catch (e) {
      if (kDebugMode) {
        print('[后台服务] 导入媒体失败: $e');
      }
      return null;
    }
  }

  /// 彻底删除本地媒体
  static Future<void> _deleteLocalMedia(AssetEntity asset) async {
    try {
      // 尝试删除媒体文件
      final result = await PhotoManager.editor.deleteWithIds([asset.id]);
      
      if (result.isNotEmpty) {
        if (kDebugMode) {
          print('[后台服务] 成功删除本地媒体: ${asset.title}');
        }
      } else {
        if (kDebugMode) {
          print('[后台服务] 删除本地媒体失败: ${asset.title}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[后台服务] 删除本地媒体异常: $e');
      }
    }
  }

  /// 启动健康检查定时器
  static void _startHealthCheck(ServiceInstance service) {
    _instance._healthCheckTimer?.cancel();
    _instance._healthCheckTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      if (kDebugMode) {
        print('[后台服务] 健康检查 - 服务运行正常');
      }
    });
  }

  /// 停止后台服务
  Future<void> stop() async {
    try {
      _isRunning = false;
      _healthCheckTimer?.cancel();
      
      // 停止媒体库监听
      PhotoManager.removeChangeCallback(_onPhotoLibraryChanged);
      PhotoManager.stopChangeNotify();
      
      // 停止后台服务
      final service = FlutterBackgroundService();
      service.invoke('stopService');
      
      if (kDebugMode) {
        print('后台媒体服务已停止');
      }
    } catch (e) {
      if (kDebugMode) {
        print('停止后台服务失败: $e');
      }
    }
  }

  /// 检查服务状态
  Future<bool> isServiceRunning() async {
    try {
      final service = FlutterBackgroundService();
      final isRunning = await service.isRunning();
      return isRunning;
    } catch (e) {
      if (kDebugMode) {
        print('检查服务状态失败: $e');
      }
      return false;
    }
  }

  /// 重启服务
  Future<void> restart() async {
    try {
      await stop();
      await Future.delayed(const Duration(seconds: 2));
      await _initializeBackgroundService();
      
      if (kDebugMode) {
        print('后台媒体服务已重启');
      }
    } catch (e) {
      if (kDebugMode) {
        print('重启后台服务失败: $e');
      }
    }
  }
}
