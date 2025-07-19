// video_config_helper.dart
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';  // 新增：Timer（如果 VideoMemoryManager 已分离，此处可移除 Timer 相关）

class VideoConfigHelper {
  static VideoConfigHelper? _instance;
  static VideoConfigHelper get instance => _instance ??= VideoConfigHelper._();
  VideoConfigHelper._();

  // 设备兼容性配置
  bool _isLowEndDevice = false;
  String _deviceModel = '';
  int _androidSdkInt = 0;

  // 视频播放器实例管理
  static final Set<String> _activeVideoControllers = <String>{};
  static const int maxConcurrentVideos = 2; // 限制同时播放的视频数量

  Future<void> initialize() async {
    if (Platform.isAndroid) {
      try {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        _deviceModel = androidInfo.model;
        _androidSdkInt = androidInfo.version.sdkInt;
        _isLowEndDevice = _detectLowEndDevice(androidInfo);

        debugPrint('[VideoConfig] 设备初始化: $_deviceModel, API: $_androidSdkInt, 低端设备: $_isLowEndDevice');
      } catch (e) {
        debugPrint('[VideoConfig] 设备信息获取失败: $e');
      }
    }
  }

  bool _detectLowEndDevice(AndroidDeviceInfo androidInfo) {
    // 已知有硬件解码器问题的设备列表
    final problematicDevices = [
      'SM-J105H',     // Samsung Galaxy J1 Mini
      'POCO F1',      // Pocophone F1
      'beryllium',    // Xiaomi Mi 8
      'santoni',      // Redmi 4X
      'land',         // Redmi 3S
      'rolex',        // Redmi 4A
      'riva',         // Redmi 5A
    ];

    // 已知有问题的厂商和芯片组
    final problematicBrands = ['mtk', 'mediatek'];
    final problematicChipsets = ['mt6', 'mt8'];

    // Android 5.1 (API 22) 有已知的多实例解码器问题
    if (androidInfo.version.sdkInt == 22) {
      debugPrint('[VideoConfig] 检测到Android 5.1，标记为低端设备');
      return true;
    }

    // 检查设备型号
    String model = androidInfo.model.toLowerCase();
    String brand = androidInfo.brand.toLowerCase();
    String hardware = androidInfo.hardware.toLowerCase();

    for (String device in problematicDevices) {
      if (model.contains(device.toLowerCase())) {
        debugPrint('[VideoConfig] 检测到问题设备: $device');
        return true;
      }
    }

    // 检查品牌
    for (String problematicBrand in problematicBrands) {
      if (brand.contains(problematicBrand) || hardware.contains(problematicBrand)) {
        debugPrint('[VideoConfig] 检测到问题厂商: $problematicBrand');
        return true;
      }
    }

    // 检查芯片组
    for (String chipset in problematicChipsets) {
      if (hardware.contains(chipset)) {
        debugPrint('[VideoConfig] 检测到问题芯片组: $chipset');
        return true;
      }
    }

    // API 级别过低的设备
    if (androidInfo.version.sdkInt < 21) {
      return true;
    }

    return false;
  }

  // 获取推荐的视频播放配置
  VideoPlaybackConfig getRecommendedConfig({
    required int videoWidth,
    required int videoHeight,
    Duration? videoDuration,
  }) {
    bool forceCompatibilityMode = _isLowEndDevice;
    bool disableHardwareAcceleration = _isLowEndDevice;
    bool limitConcurrentVideos = true;
    bool reduceQuality = false;

    // 高分辨率视频处理
    if (videoWidth > 1920 || videoHeight > 1080) {
      if (_isLowEndDevice) {
        forceCompatibilityMode = true;
        disableHardwareAcceleration = true;
        reduceQuality = true;
      }
    }

    // 4K视频特殊处理
    if (videoWidth > 3840 || videoHeight > 2160) {
      forceCompatibilityMode = true;
      if (_androidSdkInt < 24) { // Android 7.0以下
        reduceQuality = true;
      }
    }

    // 长视频特殊处理
    if (videoDuration != null && videoDuration.inMinutes > 10) {
      limitConcurrentVideos = true;
    }

    return VideoPlaybackConfig(
      forceCompatibilityMode: forceCompatibilityMode,
      disableHardwareAcceleration: disableHardwareAcceleration,
      limitConcurrentVideos: limitConcurrentVideos,
      reduceQuality: reduceQuality,
      maxConcurrentVideos: _isLowEndDevice ? 1 : 2,
      enableProgressIndicator: !_isLowEndDevice,
      enableFullScreen: !_isLowEndDevice,
      bufferDuration: _isLowEndDevice
          ? const Duration(milliseconds: 500)
          : const Duration(seconds: 2),
    );
  }

  // 视频控制器实例管理
  bool canCreateNewVideoController(String controllerId) {
    if (_activeVideoControllers.length >= maxConcurrentVideos) {
      debugPrint('[VideoConfig] 达到最大视频控制器数量限制: ${_activeVideoControllers.length}');
      return false;
    }
    return true;
  }

  void registerVideoController(String controllerId) {
    _activeVideoControllers.add(controllerId);
    debugPrint('[VideoConfig] 注册视频控制器: $controllerId, 当前总数: ${_activeVideoControllers.length}');
  }

  void unregisterVideoController(String controllerId) {
    _activeVideoControllers.remove(controllerId);
    debugPrint('[VideoConfig] 注销视频控制器: $controllerId, 当前总数: ${_activeVideoControllers.length}');
  }

  // 清理所有视频控制器（在内存压力时使用）
  void clearAllVideoControllers() {
    _activeVideoControllers.clear();
    debugPrint('[VideoConfig] 清理所有视频控制器');
  }

  // Getters
  bool get isLowEndDevice => _isLowEndDevice;
  String get deviceModel => _deviceModel;
  int get androidSdkInt => _androidSdkInt;
  int get activeVideoControllerCount => _activeVideoControllers.length;
}

class VideoPlaybackConfig {
  final bool forceCompatibilityMode;
  final bool disableHardwareAcceleration;
  final bool limitConcurrentVideos;
  final bool reduceQuality;
  final int maxConcurrentVideos;
  final bool enableProgressIndicator;
  final bool enableFullScreen;
  final Duration bufferDuration;

  const VideoPlaybackConfig({
    required this.forceCompatibilityMode,
    required this.disableHardwareAcceleration,
    required this.limitConcurrentVideos,
    required this.reduceQuality,
    required this.maxConcurrentVideos,
    required this.enableProgressIndicator,
    required this.enableFullScreen,
    required this.bufferDuration,
  });

  @override
  String toString() {
    return 'VideoPlaybackConfig('
        'compatibility: $forceCompatibilityMode, '
        'disableHW: $disableHardwareAcceleration, '
        'limitConcurrent: $limitConcurrentVideos, '
        'maxConcurrent: $maxConcurrentVideos, '
        'enableProgress: $enableProgressIndicator, '
        'enableFullScreen: $enableFullScreen'
        ')';
  }
}

// 视频编码建议工具类
class VideoEncodingHelper {
  // 获取兼容性最好的视频编码参数
  static Map<String, dynamic> getCompatibleEncodingParams() {
    return {
      'codec': 'H.264', // 最兼容的编码格式
      'profile': 'baseline', // 使用baseline profile而不是high profile
      'level': '3.1', // 适合移动设备的level
      'max_width': 1920,
      'max_height': 1080,
      'max_bitrate': '2000k', // 降低码率以减少解码压力
      'frame_rate': 30,
      'keyframe_interval': 2, // 2秒一个关键帧
      'container': 'mp4', // 最兼容的容器格式
    };
  }

  // FFmpeg转换命令建议
  static String getFFmpegCommand(String inputPath, String outputPath) {
    return 'ffmpeg -i "$inputPath" '
        '-vcodec libx264 '
        '-profile:v baseline '
        '-level 3.1 '
        '-preset medium '
        '-crf 23 '
        '-maxrate 2000k '
        '-bufsize 4000k '
        '-vf "scale=1920:1080:force_original_aspect_ratio=decrease" '
        '-r 30 '
        '-g 60 '
        '-acodec aac '
        '-b:a 128k '
        '-ar 44100 '
        '-ac 2 '
        '-movflags +faststart '
        '"$outputPath"';
  }
}

// 使用示例和初始化建议
/*
// 在main.dart中初始化：
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化视频配置
  await VideoConfigHelper.instance.initialize();

  runApp(MyApp());
}

// 在视频播放器中使用：
final config = VideoConfigHelper.instance.getRecommendedConfig(
  videoWidth: 1920,
  videoHeight: 1080,
  videoDuration: Duration(minutes: 5),
);

debugPrint('推荐配置: $config');
*/