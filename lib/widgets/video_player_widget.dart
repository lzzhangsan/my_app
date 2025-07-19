import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:async';  // 新增：Timer
import 'package:chewie/chewie.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';  // 新增：用于转码
import 'package:path_provider/path_provider.dart';  // 新增：getTemporaryDirectory

class VideoPlayerWidget extends StatefulWidget {
  final File file;
  final bool looping;
  final bool forceManualLoop;
  final VoidCallback? onVideoEnd;
  final VoidCallback? onVideoError;
  final BoxFit fit;

  VideoPlayerWidget({
    required this.file,
    this.looping = false,
    this.forceManualLoop = false,
    this.onVideoEnd,
    this.onVideoError,
    this.fit = BoxFit.contain,
    super.key,
  });

  @override
  _VideoPlayerWidgetState createState() => _VideoPlayerWidgetState();

  VideoPlayerController? get controller => _state?._controller;

  _VideoPlayerWidgetState? _state;
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late VideoPlayerController _controller;
  ChewieController? _chewieController;
  bool _isEnded = false;
  bool _hasError = false;
  Timer? _progressTimer;
  Size? _screenSize;
  bool _useCompatibilityMode = false;
  bool _useSoftwareDecoder = false;  // 新增：软件解码标志
  int _retryCount = 0;
  static const int maxRetries = 3;

  // 设备兼容性检查
  bool _isLowEndDevice = false;
  String _deviceModel = '';
  File? _transcodedFile;  // 新增：转码后的临时文件

  @override
  void initState() {
    super.initState();
    widget._state = this;
    _initializeDevice();
  }

  Future<void> _initializeDevice() async {
    try {
      if (Platform.isAndroid) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        _deviceModel = androidInfo.model;

        // 检查是否为低端设备或已知问题设备
        _isLowEndDevice = _checkIfLowEndDevice(androidInfo);

        debugPrint('[播放器] 设备信息: ${androidInfo.model}, API: ${androidInfo.version.sdkInt}, 低端设备: $_isLowEndDevice');
      }
    } catch (e) {
      debugPrint('[播放器] 获取设备信息失败: $e');
    }

    _initializeController();
  }

  bool _checkIfLowEndDevice(AndroidDeviceInfo androidInfo) {
    // 已知问题设备列表（基于搜索结果扩展）
    final problematicDevices = [
      'SM-J105H', 'POCO F1', 'beryllium', 'santoni', 'land', 'rolex', 'riva', // 从搜索扩展
      'Redmi', 'MTK', 'MediaTek', // 常见问题品牌/芯片
    ];

    // 检查Android版本（5.1及以下有已知问题）
    if (androidInfo.version.sdkInt <= 22) return true;

    // 检查设备型号
    for (String device in problematicDevices) {
      if (androidInfo.model.toLowerCase().contains(device.toLowerCase()) ||
          androidInfo.hardware.toLowerCase().contains(device.toLowerCase())) {
        return true;
      }
    }

    return false;
  }

  void _initializeController() {
    if (!widget.file.existsSync()) {
      _handleError('视频文件不存在');
      return;
    }

    _controller = VideoPlayerController.file(_transcodedFile ?? widget.file);  // 使用转码文件如果存在
    debugPrint('[播放器] 初始化controller: ${widget.file.path}, 兼容模式: $_useCompatibilityMode, 软件解码: $_useSoftwareDecoder');

    _controller.initialize().then((_) {
      if (!mounted) return;

      // 检查视频信息
      final videoSize = _controller.value.size;
      final duration = _controller.value.duration;
      debugPrint('[播放器] 视频信息: ${videoSize.width}x${videoSize.height}, 时长: ${duration.inSeconds}s');

      // 决定是否启用兼容/软件模式
      if (_shouldUseCompatibilityMode(videoSize)) {
        _useCompatibilityMode = true;
        _useSoftwareDecoder = true;  // 在兼容模式下启用软件解码
        debugPrint('[播放器] 启用兼容模式和软件解码');
      }

      _createChewieController();

      setState(() {});
      _controller.play();
      _controller.setLooping(widget.looping);

      debugPrint('[播放器] 初始化成功, isInitialized: ${_controller.value.isInitialized}, isPlaying: ${_controller.value.isPlaying}');

      // 使用更低频率的更新以减少性能开销
      _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    }).catchError((error) {
      debugPrint('[播放器] 初始化失败: $error');
      _handleInitializationError(error);
    });

    _controller.addListener(_videoListener);
  }

  bool _shouldUseCompatibilityMode(Size videoSize) {
    // 如果是低端设备，总是使用
    if (_isLowEndDevice) return true;

    // 如果视频分辨率过高（大于1080p），使用
    if (videoSize.width > 1920 || videoSize.height > 1080) return true;

    // 如果已经重试过，使用
    if (_retryCount > 0) return true;

    return false;
  }

  void _createChewieController() {
    _chewieController = ChewieController(
      videoPlayerController: _controller,
      autoPlay: true,
      looping: widget.looping,
      allowFullScreen: !_useCompatibilityMode, // 兼容模式下禁用全屏
      allowMuting: true,
      showControls: true,
      showControlsOnInitialize: true,
      deviceOrientationsAfterFullScreen: [DeviceOrientation.portraitUp],

      // 兼容模式下的优化设置
      progressIndicatorDelay: _useCompatibilityMode
          ? const Duration(days: 1) // 禁用进度指示器
          : null,

      materialProgressColors: ChewieProgressColors(
        playedColor: Colors.red,
        handleColor: Colors.red,
        backgroundColor: Colors.white.withOpacity(0.3),
        bufferedColor: Colors.white.withOpacity(0.5),
      ),

      errorBuilder: (context, errorMessage) {
        debugPrint('[播放器] Chewie错误: $errorMessage');
        return _buildErrorWidget(errorMessage);
      },

      // 添加自定义控制器以减少UI开销
      customControls: _useCompatibilityMode
          ? const MaterialControls(showPlayButton: false)
          : null,
    );
  }

  Widget _buildErrorWidget(String errorMessage) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              '视频播放失败\n$errorMessage',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _retryInitialization,
              child: Text(_retryCount < maxRetries ? '重试' : '使用兼容模式'),
            ),
            if (_retryCount < maxRetries) ...[
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () {
                  _useCompatibilityMode = true;
                  _useSoftwareDecoder = true;  // 启用软件解码
                  _retryInitialization();
                },
                child: const Text('兼容模式'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () async {
                  await _transcodeVideo();  // 新增：转码按钮
                  _retryInitialization();
                },
                child: const Text('转码视频'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _transcodeVideo() async {
    try {
      // 使用 FFmpegKit 转码为兼容格式
      final tempDir = await getTemporaryDirectory();
      final outputPath = '${tempDir.path}/${widget.file.path.split('/').last}_transcoded.mp4';

      // 执行转码命令（基于Claude的建议）
      final session = await FFmpegKit.execute(
          '-i "${widget.file.path}" '
              '-vcodec libx264 -profile:v baseline -level 3.1 '
              '-preset medium -crf 23 -maxrate 1500k -bufsize 3000k '
              '-vf "scale=1280:720:force_original_aspect_ratio=decrease" '
              '-r 30 -acodec aac -b:a 128k -movflags +faststart '
              '"$outputPath"'
      );

      final returnCode = await session.getReturnCode();
      if (returnCode!.isValueSuccess()) {
        _transcodedFile = File(outputPath);
        debugPrint('[播放器] 视频转码成功: $outputPath');
      } else {
        debugPrint('[播放器] 转码失败: ${await session.getOutput()}');
      }
    } catch (e) {
      debugPrint('[播放器] 转码错误: $e');
    }
  }

  void _retryInitialization() {
    if (_retryCount >= maxRetries) {
      _useCompatibilityMode = true;
      _useSoftwareDecoder = true;
    }

    _retryCount++;
    debugPrint('[播放器] 重试初始化 (第${_retryCount}次), 兼容模式: $_useCompatibilityMode, 软件解码: $_useSoftwareDecoder');

    // 清理旧的控制器
    _progressTimer?.cancel();
    _chewieController?.dispose();
    _controller.pause();
    _controller.dispose();

    // 重置状态
    _hasError = false;
    _isEnded = false;

    // 重新初始化
    _initializeController();
  }

  void _handleInitializationError(dynamic error) {
    debugPrint('[播放器] 初始化错误: $error');

    // 检查是否是硬件解码器错误
    String errorString = error.toString();
    if (errorString.contains('MediaCodecRenderer') ||
        errorString.contains('DecoderInitializationException') ||
        errorString.contains('OMX.') ||
        errorString.contains('EXCEEDS_CAPABILITIES') ||
        errorString.contains('NO_EXCEEDS_CAPABILITIES')) {

      debugPrint('[播放器] 检测到硬件解码器错误，切换到软件模式');

      if (_retryCount < maxRetries && !_useSoftwareDecoder) {
        _useCompatibilityMode = true;
        _useSoftwareDecoder = true;
        Timer(const Duration(milliseconds: 500), _retryInitialization);
        return;
      }

      // 如果重试失败，尝试转码
      if (_retryCount >= maxRetries && _transcodedFile == null) {
        _transcodeVideo().then((_) => _retryInitialization());
        return;
      }
    }

    _handleError('初始化失败: $errorString');
  }

  void _videoListener() {
    if (!mounted) return;

    debugPrint('[播放器] 状态监听 isInitialized: ${_controller.value.isInitialized}, isPlaying: ${_controller.value.isPlaying}, position: ${_controller.value.position}');

    if (_controller.value.hasError && !_hasError) {
      String errorDescription = _controller.value.errorDescription ?? '未知错误';
      debugPrint('[播放器] 播放错误: $errorDescription');

      // 检查是否是硬件解码器错误
      if (errorDescription.contains('MediaCodecRenderer') ||
          errorDescription.contains('DecoderInitializationException') ||
          errorDescription.contains('EXCEEDS_CAPABILITIES')) {

        if (_retryCount < maxRetries && !_useSoftwareDecoder) {
          debugPrint('[播放器] 检测到硬件解码器错误，尝试软件模式');
          _useCompatibilityMode = true;
          _useSoftwareDecoder = true;
          Timer(const Duration(milliseconds: 500), _retryInitialization);
          return;
        }

        // 转码 fallback
        if (_transcodedFile == null) {
          _transcodeVideo().then((_) => _retryInitialization());
          return;
        }
      }

      _handleError(errorDescription);
      return;
    }

    if (_controller.value.isInitialized &&
        _controller.value.position >= _controller.value.duration &&
        !_isEnded &&
        !widget.looping) {
      _isEnded = true;
      widget.onVideoEnd?.call();
      if (widget.forceManualLoop) {
        _controller.seekTo(Duration.zero).then((_) {
          _controller.play();
          _isEnded = false;
        });
      }
    }
  }

  void _handleError(String error) {
    debugPrint('视频播放错误: ${widget.file.path}, 错误: $error, 设备: $_deviceModel');
    _hasError = true;
    if (mounted) setState(() {});
    widget.onVideoError?.call();
  }

  @override
  void dispose() {
    debugPrint('销毁视频播放器: ${widget.file.path}');
    _progressTimer?.cancel();
    _chewieController?.dispose();
    _controller.pause();
    _controller.dispose();
    // 清理转码临时文件
    _transcodedFile?.delete();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path ||
        oldWidget.looping != widget.looping ||
        oldWidget.forceManualLoop != widget.forceManualLoop) {
      debugPrint('视频播放器更新: ${oldWidget.file.path} -> ${widget.file.path}');
      _progressTimer?.cancel();
      _chewieController?.dispose();
      _controller.pause();
      _controller.dispose();
      _isEnded = false;
      _hasError = false;
      _retryCount = 0; // 重置重试计数
      _useCompatibilityMode = _isLowEndDevice; // 重置兼容模式
      _useSoftwareDecoder = false; // 重置软件解码
      _transcodedFile?.delete(); // 清理旧临时文件
      _transcodedFile = null;
      _initializeController();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.file.existsSync()) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 48),
            SizedBox(height: 16),
            Text('视频文件不存在', style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }

    if (_hasError) {
      return _buildErrorWidget('视频无法播放');
    }

    if (!_controller.value.isInitialized || _chewieController == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在加载视频...', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }

    Widget videoWidget = Chewie(controller: _chewieController!);

    // 在兼容模式下使用简化的布局
    if (_useCompatibilityMode) {
      return Container(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: _controller.value.aspectRatio,
            child: videoWidget,
          ),
        ),
      );
    }

    return Center(
      child: Container(
        color: Colors.transparent,
        child: SizedBox.expand(
          child: FittedBox(
            fit: widget.fit,
            alignment: Alignment.center,
            child: SizedBox(
              width: _controller.value.size.width,
              height: _controller.value.size.height,
              child: videoWidget,
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}