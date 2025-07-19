// video_memory_manager.dart
import 'dart:async';  // 添加 Timer 导入
import 'package:flutter/foundation.dart';  // debugPrint
import 'video_config_helper.dart';  // 引用 VideoConfigHelper

class VideoMemoryManager {
  static final VideoMemoryManager _instance = VideoMemoryManager._();
  static VideoMemoryManager get instance => _instance;
  VideoMemoryManager._();

  Timer? _memoryPressureTimer;

  void startMemoryMonitoring() {
    _memoryPressureTimer?.cancel();
    _memoryPressureTimer = Timer.periodic(
      const Duration(seconds: 30),
      (timer) => _checkMemoryPressure(),
    );
  }

  void stopMemoryMonitoring() {
    _memoryPressureTimer?.cancel();
  }

  void _checkMemoryPressure() {
    // 简单的内存压力检测
    final videoControllerCount = VideoConfigHelper.instance.activeVideoControllerCount;
    if (videoControllerCount > 2) {
      debugPrint('[MemoryManager] 检测到内存压力，建议清理视频控制器');
      // 这里可以发送事件通知应用清理不需要的视频控制器
    }
  }

  // 在内存压力时调用
  void onMemoryPressure() {
    debugPrint('[MemoryManager] 内存压力事件，清理视频控制器');
    VideoConfigHelper.instance.clearAllVideoControllers();
  }
}