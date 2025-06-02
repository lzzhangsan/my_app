import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:record/record.dart';  // 重新启用record依赖
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:math' as math;

class ResizableAudioBox extends StatefulWidget {
  final String audioPath;
  final Function(bool) onIsRecording;
  final Function() onSettingsPressed;
  final Function(String)? onPathUpdated;
  final bool? startRecording; // 添加控制是否开始录音的标志

  const ResizableAudioBox({
    super.key,
    required this.audioPath,
    required this.onIsRecording,
    required this.onSettingsPressed,
    this.onPathUpdated,
    this.startRecording,
  });

  @override
  _ResizableAudioBoxState createState() => _ResizableAudioBoxState();
}

class _ResizableAudioBoxState extends State<ResizableAudioBox> with SingleTickerProviderStateMixin {
  bool _isPlaying = false;
  bool _isRecording = false;
  late AnimationController _animationController;
  final AudioRecorder _recorder = AudioRecorder();  // 使用AudioRecorder类
  final AudioPlayer _player = AudioPlayer();
  String _recordedPath = '';
  List<double> _soundWaves = List.generate(5, (_) => 0.2);
  bool _hasAudio = false;
  bool? _previousStartRecording;
  
  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 600),
    )..repeat(reverse: true);
    
    // 检查传入的音频路径
    _checkAudioPath();
    
    // 监听播放状态
    _player.onPlayerComplete.listen((event) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
        });
      }
    });
    
    _previousStartRecording = widget.startRecording;
    // 如果初始化时就需要开始录音
    if (widget.startRecording == true && !_isRecording) {
      _startRecording();
    }
  }
  
  void _checkAudioPath() {
    if (widget.audioPath.isNotEmpty && widget.audioPath != '/simulated_path/') {
      setState(() {
        _hasAudio = true;
        _recordedPath = widget.audioPath;
      });
    }
  }
  
  @override
  void didUpdateWidget(ResizableAudioBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // 检查音频路径变化
    if (widget.audioPath != oldWidget.audioPath) {
      _checkAudioPath();
    }
    
    // 检查录音状态变化
    if (widget.startRecording != _previousStartRecording) {
      _previousStartRecording = widget.startRecording;
      if (widget.startRecording == true && !_isRecording) {
        // 如果父组件要求开始录音
        _startRecording();
      } else if (widget.startRecording == false && _isRecording) {
        // 如果父组件要求停止录音
        _stopRecording();
      }
    }
  }
  
  @override
  void dispose() {
    _animationController.dispose();
    _recorder.dispose();  // 释放录音资源
    _player.dispose();
    super.dispose();
  }
  
  // 播放音频
  Future<void> _togglePlay() async {
    try {
      if (_isPlaying) {
        await _player.stop();
        setState(() {
          _isPlaying = false;
        });
      } else {
        if (_recordedPath.isNotEmpty && File(_recordedPath).existsSync()) {
          HapticFeedback.mediumImpact();
          
          // 更新为使用新版AudioPlayer API
          final source = DeviceFileSource(_recordedPath);
          await _player.play(source);
          
          setState(() {
            _isPlaying = true;
            // 生成随机波形
            _generateRandomWaves();
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('找不到音频文件或路径无效')),
          );
        }
      }
    } catch (e) {
      print('播放音频时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('播放失败: $e')),
      );
    }
  }
  
  // 生成随机波形数据（用于视觉效果）
  void _generateRandomWaves() {
    if (_soundWaves.isEmpty || !_isPlaying) return;
    
    setState(() {
      for (int i = 0; i < _soundWaves.length; i++) {
        _soundWaves[i] = math.Random().nextDouble() * 0.8 + 0.2;
      }
    });
    
    if (_isPlaying) {
      Future.delayed(Duration(milliseconds: 150), () {
        if (mounted) _generateRandomWaves();
      });
    }
  }
  
  // 录音相关功能
  Future<void> _toggleRecord() async {
    if (_isRecording) {
      // 停止录音
      await _stopRecording();
    } else {
      // 开始录音
      await _startRecording();
    }
  }
  
  Future<void> _startRecording() async {
    try {
      // 获取音频目录
      final appDir = await getApplicationDocumentsDirectory();
      final audioDir = Directory('${appDir.path}/audio');
      if (!await audioDir.exists()) {
        await audioDir.create(recursive: true);
      }
      
      _recordedPath = '${audioDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      
      // 启用实际录音功能
      if (await _recorder.hasPermission()) {
        // 设置录音配置
        await _recorder.start(
          RecordConfig(
            encoder: AudioEncoder.aacLc, // AAC编码
            bitRate: 128000, // 128kbps
            sampleRate: 44100, // 44.1kHz
          ), 
          path: _recordedPath,
        );
        
        HapticFeedback.heavyImpact();
        setState(() {
          _isRecording = true;
          _hasAudio = true;
        });
        
        // 告知父组件录音状态
        widget.onIsRecording(true);
        
        // 开始显示波形
        _startWaveAnimation();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('需要录音权限')),
        );
      }
    } catch (e) {
      print('开始录音时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法开始录音: $e')),
      );
    }
  }
  
  Future<void> _stopRecording() async {
    try {
      // 启用实际录音功能
      final path = await _recorder.stop();
      
      setState(() {
        _isRecording = false;
        if (path != null) {
          _recordedPath = path;
          if (widget.onPathUpdated != null) {
            widget.onPathUpdated!(_recordedPath);
          }
        }
      });
      
      // 告知父组件录音停止
      widget.onIsRecording(false);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('录音已保存')),
      );
    } catch (e) {
      print('停止录音时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('停止录音时出错')),
      );
      setState(() {
        _isRecording = false;
      });
      widget.onIsRecording(false);
    }
  }
  
  // 音波动画
  void _startWaveAnimation() {
    if (!_isRecording) return;
    
    setState(() {
      for (int i = 0; i < _soundWaves.length; i++) {
        _soundWaves[i] = math.Random().nextDouble() * 0.8 + 0.2;
      }
    });
    
    Future.delayed(Duration(milliseconds: 150), () {
      if (mounted && _isRecording) {
        _startWaveAnimation();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 37.3,
      height: 37.3,
      decoration: BoxDecoration(
        color: _isRecording 
            ? Colors.red.withOpacity(0.7) 
            : _isPlaying
                ? Colors.green.withOpacity(0.7)
                : Colors.blue.withOpacity(0.7),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 4.0,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        children: [
          // 音波动画层
          if (_isRecording || _isPlaying)
            Center(
              child: SizedBox(
                width: 30,
                height: 15,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(_soundWaves.length, (index) {
                    return AnimatedContainer(
                      duration: Duration(milliseconds: 150),
                      width: 3,
                      height: 15 * _soundWaves[index],
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    );
                  }),
                ),
              ),
            ),
          
          // 主体按钮
          GestureDetector(
            onTap: _hasAudio ? _togglePlay : _toggleRecord,
            onLongPress: _toggleRecord,
            child: Center(
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: 200),
                child: _isRecording 
                    ? Icon(
                        Icons.stop,
                        color: Colors.white,
                        size: 20,
                        key: ValueKey('recording'),
                      )
                    : _isPlaying
                        ? Icon(
                            Icons.pause,
                            color: Colors.white,
                            size: 20,
                            key: ValueKey('playing'),
                          )
                        : _hasAudio
                            ? Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 20,
                                key: ValueKey('play'),
                              )
                            : Icon(
                                Icons.mic,
                                color: Colors.white,
                                size: 20,
                                key: ValueKey('mic'),
                              ),
              ),
            ),
          ),
          
          // 设置按钮
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              onTap: widget.onSettingsPressed,
              child: Container(
                padding: EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.settings,
                  color: Colors.white,
                  size: 8,
                ),
              ),
            ),
          ),
          
          // 录制状态指示器
          if (_isRecording)
            Positioned(
              left: 0,
              top: 0,
              child: AnimatedBuilder(
                animation: _animationController,
                builder: (context, child) {
                  return Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: _animationController.value > 0.5
                          ? Colors.red
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
} 