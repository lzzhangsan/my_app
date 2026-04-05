import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widgets/image_layout_utils.dart' show ImageLetterboxFill;

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
  /// 边沿巡游单段内沿路径前进比例 ×100（10～100 → 0.10～1.00），越小越舒缓。
  static const String imagePanRoamCoveragePct =
      'media_player_image_pan_roam_coverage_pct';
  /// 图片未铺满屏幕时，上下（或左右）留白的填充方式。
  static const String imageLetterboxFill = 'media_player_image_letterbox_fill';
}

Future<MediaPlayerSettingsSnapshot> loadMediaPlayerSettings(
  SharedPreferences prefs,
) async {
  final ms = (prefs.getInt(MediaPlayerPrefsKeys.imageDurationMs) ?? 5000)
      .clamp(1000, 600000);
  final modeIndex =
      (prefs.getInt(MediaPlayerPrefsKeys.imageDisplayMode) ?? 0).clamp(0, 2);
  final zoom = (prefs.getInt(MediaPlayerPrefsKeys.zoomMaxScale) ?? 30) /
      10.0; // 存 20–100 表示 2.0–10.0
  final orderIndex =
      (prefs.getInt(MediaPlayerPrefsKeys.playbackOrder) ?? 0).clamp(0, 1);
  final panCw = prefs.getBool(MediaPlayerPrefsKeys.panClockwise) ?? true;
  final roamPct =
      (prefs.getInt(MediaPlayerPrefsKeys.imagePanRoamCoveragePct) ?? 28)
          .clamp(10, 100);
  final roamCov = roamPct / 100.0;
  final letterboxIndex =
      (prefs.getInt(MediaPlayerPrefsKeys.imageLetterboxFill) ?? 0).clamp(0, 3);

  return MediaPlayerSettingsSnapshot(
    imageDuration: Duration(milliseconds: ms),
    imageMode: MediaImageDisplayMode.values[modeIndex],
    zoomMaxScale: zoom.clamp(2.0, 10.0),
    playbackOrder: MediaPlaybackOrder.values[orderIndex],
    panClockwise: panCw,
    imagePanRoamCoverage: roamCov,
    letterboxFill: ImageLetterboxFill.values[letterboxIndex],
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
  await prefs.setInt(
    MediaPlayerPrefsKeys.imagePanRoamCoveragePct,
    (s.imagePanRoamCoverage * 100).round().clamp(10, 100),
  );
  await prefs.setInt(
    MediaPlayerPrefsKeys.imageLetterboxFill,
    s.letterboxFill.index,
  );
}

class MediaPlayerSettingsSnapshot {
  const MediaPlayerSettingsSnapshot({
    required this.imageDuration,
    required this.imageMode,
    required this.zoomMaxScale,
    required this.playbackOrder,
    this.panClockwise = true,
    this.imagePanRoamCoverage = 0.28,
    this.letterboxFill = ImageLetterboxFill.white,
  });

  final Duration imageDuration;
  final MediaImageDisplayMode imageMode;
  final double zoomMaxScale;
  final MediaPlaybackOrder playbackOrder;
  /// 边沿巡游方向：true 顺时针，false 逆时针
  final bool panClockwise;
  /// 单段动画内沿巡游路径前进的比例 0.10～1.00；越小越舒缓，不必跑完整条路径。
  final double imagePanRoamCoverage;
  /// 图片未铺满屏幕时，留白区域填充（与文档媒体栏、媒体预览共用）。
  final ImageLetterboxFill letterboxFill;
}

/// 底部红键三连击打开：调整自动连播图片停留时间、展现方式、随机/顺序
/// [onSettingsChanged]：任意项变更后自动写入 SharedPreferences 并回调（便于持久化与同步状态）。
Future<void> showMediaPlayerSettingsDialog({
  required BuildContext context,
  required MediaPlayerSettingsSnapshot initial,
  required Future<void> Function(MediaPlayerSettingsSnapshot snap)
      onSettingsChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      return _MediaPlayerSettingsDialogBody(
        initial: initial,
        onSettingsChanged: onSettingsChanged,
      );
    },
  );
}

class _MediaPlayerSettingsDialogBody extends StatefulWidget {
  const _MediaPlayerSettingsDialogBody({
    required this.initial,
    required this.onSettingsChanged,
  });

  final MediaPlayerSettingsSnapshot initial;
  final Future<void> Function(MediaPlayerSettingsSnapshot snap) onSettingsChanged;

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
  late double _panRoamCoverage;
  late ImageLetterboxFill _letterboxFill;

  String? _secondsError;
  Timer? _secondsDebounce;

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
    _panRoamCoverage = widget.initial.imagePanRoamCoverage.clamp(0.10, 1.0);
    _letterboxFill = widget.initial.letterboxFill;
  }

  @override
  void dispose() {
    _secondsDebounce?.cancel();
    _secondsController.dispose();
    super.dispose();
  }

  MediaPlayerSettingsSnapshot _buildSnapshot() {
    final raw = _secondsController.text.trim();
    final parsed = int.tryParse(raw);
    final duration = (parsed != null &&
            parsed >= _minSec &&
            parsed <= _maxSec)
        ? Duration(seconds: parsed)
        : widget.initial.imageDuration;
    return MediaPlayerSettingsSnapshot(
      imageDuration: duration,
      imageMode: _mode,
      zoomMaxScale: _zoomMax,
      playbackOrder: _order,
      panClockwise: _panClockwise,
      imagePanRoamCoverage: _panRoamCoverage,
      letterboxFill: _letterboxFill,
    );
  }

  Future<void> _persistAndNotify() async {
    final prefs = await SharedPreferences.getInstance();
    final snap = _buildSnapshot();
    await saveMediaPlayerSettings(prefs, snap);
    if (!mounted) return;
    await widget.onSettingsChanged(snap);
  }

  void _scheduleSecondsPersist() {
    _secondsDebounce?.cancel();
    _secondsDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      final sec = _parseSeconds(silent: true);
      if (sec == null) return;
      unawaited(_persistAndNotify());
    });
  }

  int? _parseSeconds({bool silent = false}) {
    final raw = _secondsController.text.trim();
    if (raw.isEmpty) {
      if (!silent) setState(() => _secondsError = '请输入数字');
      return null;
    }
    final v = int.tryParse(raw);
    if (v == null) {
      if (!silent) setState(() => _secondsError = '请输入有效整数');
      return null;
    }
    if (v < _minSec || v > _maxSec) {
      if (!silent) setState(() => _secondsError = '须在 $_minSec～$_maxSec 秒之间');
      return null;
    }
    if (!silent) setState(() => _secondsError = null);
    return v;
  }

  Future<void> _confirmClose() async {
    final sec = _parseSeconds();
    if (sec == null) return;

    final prefs = await SharedPreferences.getInstance();
    final snap = MediaPlayerSettingsSnapshot(
      imageDuration: Duration(seconds: sec),
      imageMode: _mode,
      zoomMaxScale: _zoomMax,
      playbackOrder: _order,
      panClockwise: _panClockwise,
      imagePanRoamCoverage: _panRoamCoverage,
      letterboxFill: _letterboxFill,
    );
    await saveMediaPlayerSettings(prefs, snap);
    if (!mounted) return;
    await widget.onSettingsChanged(snap);
    if (!mounted) return;
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
            const SizedBox(height: 4),
            Text(
              '此处修改会立即自动保存，下次打开将沿用当前设置。',
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
              onChanged: (_) {
                setState(() => _secondsError = null);
                _scheduleSecondsPersist();
              },
            ),
            const SizedBox(height: 12),
            Text('上下留白区域', style: Theme.of(context).textTheme.titleSmall),
            Text(
              '图片较矮或较窄未铺满屏幕时，周围区域的底纹。默认推荐「纯白」以免干扰主体。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            RadioListTile<ImageLetterboxFill>(
              title: const Text('纯白'),
              value: ImageLetterboxFill.white,
              groupValue: _letterboxFill,
              onChanged: (v) {
                setState(() => _letterboxFill = v!);
                unawaited(_persistAndNotify());
              },
            ),
            RadioListTile<ImageLetterboxFill>(
              title: const Text('透明（透出页面背景）'),
              value: ImageLetterboxFill.transparent,
              groupValue: _letterboxFill,
              onChanged: (v) {
                setState(() => _letterboxFill = v!);
                unawaited(_persistAndNotify());
              },
            ),
            RadioListTile<ImageLetterboxFill>(
              title: const Text('同图铺满并暗化（旧版效果）'),
              value: ImageLetterboxFill.softCover,
              groupValue: _letterboxFill,
              onChanged: (v) {
                setState(() => _letterboxFill = v!);
                unawaited(_persistAndNotify());
              },
            ),
            RadioListTile<ImageLetterboxFill>(
              title: const Text('同图强模糊'),
              value: ImageLetterboxFill.blurHeavy,
              groupValue: _letterboxFill,
              onChanged: (v) {
                setState(() => _letterboxFill = v!);
                unawaited(_persistAndNotify());
              },
            ),
            const SizedBox(height: 8),
            Text('播放顺序', style: Theme.of(context).textTheme.titleSmall),
            RadioListTile<MediaPlaybackOrder>(
              title: const Text('随机'),
              value: MediaPlaybackOrder.random,
              groupValue: _order,
              onChanged: (v) {
                setState(() => _order = v!);
                unawaited(_persistAndNotify());
              },
            ),
            RadioListTile<MediaPlaybackOrder>(
              title: const Text('按顺序（加入时间，相同则按路径）'),
              value: MediaPlaybackOrder.sequential,
              groupValue: _order,
              onChanged: (v) {
                setState(() => _order = v!);
                unawaited(_persistAndNotify());
              },
            ),
            const SizedBox(height: 8),
            Text('图片展现', style: Theme.of(context).textTheme.titleSmall),
            RadioListTile<MediaImageDisplayMode>(
              title: const Text('居中横向填满（静态）'),
              value: MediaImageDisplayMode.fitWidth,
              groupValue: _mode,
              onChanged: (v) {
                setState(() => _mode = v!);
                unawaited(_persistAndNotify());
              },
            ),
            RadioListTile<MediaImageDisplayMode>(
              title: const Text('渐进放大（从全屏放大到设定倍数）'),
              value: MediaImageDisplayMode.kenBurns,
              groupValue: _mode,
              onChanged: (v) {
                setState(() => _mode = v!);
                unawaited(_persistAndNotify());
              },
            ),
            RadioListTile<MediaImageDisplayMode>(
              title: const Text('放大后边沿巡游（放大后沿边平移浏览四周）'),
              value: MediaImageDisplayMode.zoomPanEdge,
              groupValue: _mode,
              onChanged: (v) {
                setState(() => _mode = v!);
                unawaited(_persistAndNotify());
              },
            ),
            if (_mode == MediaImageDisplayMode.kenBurns) ...[
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
                child: Text(
                  '在媒体库全屏预览中：「静态」或「渐进放大」下双击可设缩放中心（静态会先演示一轮放大）；数据写入媒体项，备份可带走。文档编辑页内嵌媒体栏不启用双击，以免干扰排版。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            if (_mode == MediaImageDisplayMode.zoomPanEdge) ...[
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('巡游方向'),
                subtitle: Text(_panClockwise ? '顺时针' : '逆时针'),
                value: _panClockwise,
                onChanged: (v) {
                  setState(() => _panClockwise = v);
                  unawaited(_persistAndNotify());
                },
              ),
              const SizedBox(height: 4),
              Text('图片巡游速度', style: Theme.of(context).textTheme.titleSmall),
              Text(
                '舒缓 ← → 较快。数值越小画面移动越平缓；设定时间内未走完整段路径也可以。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Slider(
                value: _panRoamCoverage,
                min: 0.10,
                max: 1.0,
                divisions: 18,
                label:
                    '${(_panRoamCoverage * 100).round()}% 路径',
                onChanged: (v) {
                  setState(() => _panRoamCoverage = v);
                  unawaited(_persistAndNotify());
                },
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
                max: 10,
                divisions: 80,
                label: '${_zoomMax.toStringAsFixed(1)}×',
                onChanged: (v) {
                  setState(() => _zoomMax = v);
                  unawaited(_persistAndNotify());
                },
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
          onPressed: _confirmClose,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
