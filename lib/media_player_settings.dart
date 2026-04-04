import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 媒体栏随机/顺序播放
enum MediaPlaybackOrder {
  random,
  sequential,
}

/// 图片展现：静态填满 / 渐进放大 / 放大后边沿巡游
enum MediaImageDisplayMode {
  fitWidth,
  kenBurns,
  zoomPanEdge,
}

class MediaPlayerPrefsKeys {
  MediaPlayerPrefsKeys._();

  static const String imageDurationMs = 'media_player_image_duration_ms';
  static const String imageDisplayMode = 'media_player_image_display_mode';
  static const String zoomMaxScale = 'media_player_zoom_max_scale';
  static const String playbackOrder = 'media_player_playback_order';
  static const String panClockwise = 'media_player_pan_clockwise';
}

Future<MediaPlayerSettingsSnapshot> loadMediaPlayerSettings(
  SharedPreferences prefs,
) async {
  final ms = (prefs.getInt(MediaPlayerPrefsKeys.imageDurationMs) ?? 5000)
      .clamp(1000, 600000);
  final modeIndex =
      (prefs.getInt(MediaPlayerPrefsKeys.imageDisplayMode) ?? 0).clamp(0, 2);
  final zoom = (prefs.getInt(MediaPlayerPrefsKeys.zoomMaxScale) ?? 30) /
      10.0; // 存 20–50 表示 2.0–5.0
  final orderIndex =
      (prefs.getInt(MediaPlayerPrefsKeys.playbackOrder) ?? 0).clamp(0, 1);
  final panCw = prefs.getBool(MediaPlayerPrefsKeys.panClockwise) ?? true;

  return MediaPlayerSettingsSnapshot(
    imageDuration: Duration(milliseconds: ms),
    imageMode: MediaImageDisplayMode.values[modeIndex],
    zoomMaxScale: zoom.clamp(2.0, 5.0),
    playbackOrder: MediaPlaybackOrder.values[orderIndex],
    panClockwise: panCw,
  );
}

Future<void> saveMediaPlayerSettings(
  SharedPreferences prefs,
  MediaPlayerSettingsSnapshot s,
) async {
  await prefs.setInt(
    MediaPlayerPrefsKeys.imageDurationMs,
    s.imageDuration.inMilliseconds,
  );
  await prefs.setInt(
    MediaPlayerPrefsKeys.imageDisplayMode,
    s.imageMode.index,
  );
  await prefs.setInt(
    MediaPlayerPrefsKeys.zoomMaxScale,
    (s.zoomMaxScale * 10).round(),
  );
  await prefs.setInt(
    MediaPlayerPrefsKeys.playbackOrder,
    s.playbackOrder.index,
  );
  await prefs.setBool(MediaPlayerPrefsKeys.panClockwise, s.panClockwise);
}

class MediaPlayerSettingsSnapshot {
  const MediaPlayerSettingsSnapshot({
    required this.imageDuration,
    required this.imageMode,
    required this.zoomMaxScale,
    required this.playbackOrder,
    this.panClockwise = true,
  });

  final Duration imageDuration;
  final MediaImageDisplayMode imageMode;
  final double zoomMaxScale;
  final MediaPlaybackOrder playbackOrder;
  /// 边沿巡游方向：true 顺时针，false 逆时针
  final bool panClockwise;
}

/// 底部红键三连击打开：调整自动连播图片停留时间、展现方式、随机/顺序
Future<void> showMediaPlayerSettingsDialog({
  required BuildContext context,
  required MediaPlayerSettingsSnapshot initial,
  required void Function(MediaPlayerSettingsSnapshot saved) onApply,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      return _MediaPlayerSettingsDialogBody(
        initial: initial,
        onApply: onApply,
      );
    },
  );
}

class _MediaPlayerSettingsDialogBody extends StatefulWidget {
  const _MediaPlayerSettingsDialogBody({
    required this.initial,
    required this.onApply,
  });

  final MediaPlayerSettingsSnapshot initial;
  final void Function(MediaPlayerSettingsSnapshot saved) onApply;

  @override
  State<_MediaPlayerSettingsDialogBody> createState() =>
      _MediaPlayerSettingsDialogBodyState();
}

class _MediaPlayerSettingsDialogBodyState
    extends State<_MediaPlayerSettingsDialogBody> {
  late final TextEditingController _secondsController;
  late MediaImageDisplayMode _mode;
  late double _zoomMax;
  late MediaPlaybackOrder _order;
  late bool _panClockwise;

  String? _secondsError;

  static const int _minSec = 1;
  static const int _maxSec = 600;

  @override
  void initState() {
    super.initState();
    final sec = widget.initial.imageDuration.inSeconds.clamp(_minSec, _maxSec);
    _secondsController = TextEditingController(text: '$sec');
    _mode = widget.initial.imageMode;
    _zoomMax = widget.initial.zoomMaxScale;
    _order = widget.initial.playbackOrder;
    _panClockwise = widget.initial.panClockwise;
  }

  @override
  void dispose() {
    _secondsController.dispose();
    super.dispose();
  }

  int? _parseSeconds() {
    final raw = _secondsController.text.trim();
    if (raw.isEmpty) {
      setState(() => _secondsError = '请输入数字');
      return null;
    }
    final v = int.tryParse(raw);
    if (v == null) {
      setState(() => _secondsError = '请输入有效整数');
      return null;
    }
    if (v < _minSec || v > _maxSec) {
      setState(() => _secondsError = '须在 $_minSec～$_maxSec 秒之间');
      return null;
    }
    setState(() => _secondsError = null);
    return v;
  }

  Future<void> _save() async {
    final sec = _parseSeconds();
    if (sec == null) return;

    final prefs = await SharedPreferences.getInstance();
    final snap = MediaPlayerSettingsSnapshot(
      imageDuration: Duration(seconds: sec),
      imageMode: _mode,
      zoomMaxScale: _zoomMax,
      playbackOrder: _order,
      panClockwise: _panClockwise,
    );
    await saveMediaPlayerSettings(prefs, snap);
    if (!mounted) return;
    widget.onApply(snap);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('媒体播放设置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '自动/连续模式下每张图片展示时长请用下方数字精确输入（1 秒～10 分钟）。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _secondsController,
              decoration: InputDecoration(
                labelText: '展示时长（秒）',
                hintText: '$_minSec～$_maxSec',
                errorText: _secondsError,
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
              onChanged: (_) => setState(() => _secondsError = null),
            ),
            const SizedBox(height: 12),
            Text('播放顺序', style: Theme.of(context).textTheme.titleSmall),
            RadioListTile<MediaPlaybackOrder>(
              title: const Text('随机'),
              value: MediaPlaybackOrder.random,
              groupValue: _order,
              onChanged: (v) => setState(() => _order = v!),
            ),
            RadioListTile<MediaPlaybackOrder>(
              title: const Text('按顺序（加入时间，相同则按路径）'),
              value: MediaPlaybackOrder.sequential,
              groupValue: _order,
              onChanged: (v) => setState(() => _order = v!),
            ),
            const SizedBox(height: 8),
            Text('图片展现', style: Theme.of(context).textTheme.titleSmall),
            RadioListTile<MediaImageDisplayMode>(
              title: const Text('居中横向填满（静态）'),
              value: MediaImageDisplayMode.fitWidth,
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v!),
            ),
            RadioListTile<MediaImageDisplayMode>(
              title: const Text('渐进放大（从全屏放大到设定倍数）'),
              value: MediaImageDisplayMode.kenBurns,
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v!),
            ),
            RadioListTile<MediaImageDisplayMode>(
              title: const Text('放大后边沿巡游（放大后沿边平移浏览四周）'),
              value: MediaImageDisplayMode.zoomPanEdge,
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v!),
            ),
            if (_mode == MediaImageDisplayMode.zoomPanEdge) ...[
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('巡游方向'),
                subtitle: Text(_panClockwise ? '顺时针' : '逆时针'),
                value: _panClockwise,
                onChanged: (v) => setState(() => _panClockwise = v),
              ),
            ],
            if (_mode == MediaImageDisplayMode.kenBurns ||
                _mode == MediaImageDisplayMode.zoomPanEdge) ...[
              const SizedBox(height: 4),
              Text(
                '最大放大：${_zoomMax.toStringAsFixed(1)} 倍',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Slider(
                value: _zoomMax,
                min: 2,
                max: 5,
                divisions: 30,
                label: '${_zoomMax.toStringAsFixed(1)}×',
                onChanged: (v) => setState(() => _zoomMax = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
