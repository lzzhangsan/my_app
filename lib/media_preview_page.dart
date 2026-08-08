import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'models/media_item.dart';
import 'models/media_type.dart';
import 'media_player_settings.dart';
import 'widgets/fit_width_blur_static_image.dart';
import 'widgets/image_layout_utils.dart'
    show
        ImageLetterboxFill,
        containDisplaySize,
        fitWidthDisplaySize,
        measureImageFileSize;
import 'widgets/ken_burns_image_display.dart';
import 'widgets/zoom_pan_edge_image_display.dart';
import 'models/video_view_params.dart';
import 'widgets/video_interactive_surface.dart';
import 'widgets/image_interactive_surface.dart';
import 'widgets/floating_ui_shadows.dart';
import 'widgets/move_to_folder_sheet.dart';
import 'utils/background_video_volume_prefs.dart';

enum MediaMode { none, manual, auto }

/// [Navigator.pop] 返回值：从文档编辑栏「调整当前视频」返回时携带续播时间。
class MediaPreviewPagePopResult {
  final Duration? resumeVideoPosition;
  const MediaPreviewPagePopResult({this.resumeVideoPosition});
}

class MediaPreviewPage extends StatefulWidget {
  final List<MediaItem> mediaItems;
  final int initialIndex;
  final bool openedFromRecycleBin;
  final String? standaloneBackgroundFilePath;

  /// 非 null 时：进入全屏调整页后从该时间点续播（文档编辑栏浮层视频）；退出时通过 [MediaPreviewPagePopResult] 回传进度。
  final Duration? initialResumeVideoPosition;

  /// 背景调整入口传入的本地文件路径。与 [mediaItems] 中来自媒体库的 `path` 可能不同（同文件不同路径），
  /// 音量须与该路径一致，否则返回后 [StoredViewVideoBackgroundLayer] 读不到静音设置。
  final String? volumePersistencePath;

  const MediaPreviewPage({
    required this.mediaItems,
    required this.initialIndex,
    this.openedFromRecycleBin = false,
    this.standaloneBackgroundFilePath,
    this.initialResumeVideoPosition,
    this.volumePersistencePath,
    super.key,
  });

  @override
  _MediaPreviewPageState createState() => _MediaPreviewPageState();
}

class _MediaPreviewPageState extends State<MediaPreviewPage> {
  late PageController _pageController;
  int _currentIndex = 0;
  final Map<int, VideoPlayerController> _videoControllers = {};
  final Map<int, ChewieController> _chewieControllers = {};
  /// Indexes whose [VideoPlayerController.initialize] failed (timeout/codec).
  final Set<int> _videoInitFailed = <int>{};
  final Map<int, String> _videoInitFailureDetail = <int, String>{};
  final Set<int> _videoInitInFlight = <int>{};
  final bool _isFullScreen = false;
  late final DatabaseService _dbService;
  MediaMode _mediaMode = MediaMode.none;

  /// 与文档编辑页媒体栏共用 SharedPreferences，行为一致。
  Duration _imageDuration = const Duration(seconds: 5);
  MediaImageDisplayMode _imageMode = MediaImageDisplayMode.fitWidth;
  double _zoomMax = 3.0;
  MediaPlaybackOrder _playbackOrder = MediaPlaybackOrder.random;
  bool _panClockwise = true;
  double _imagePanRoamCoverage = 0.28;
  ImageLetterboxFill _letterboxFill = ImageLetterboxFill.transparent;
  bool _foregroundVideoMuted = false;

  /// 双击更新渐进放大中心后递增，强制 Ken Burns 立即重播。
  int _kenBurnsReplayTick = 0;

  /// 静态模式下双击保存中心后，临时用 Ken Burns 播完一轮再恢复静态。
  bool _staticKenBurnsDemo = false;
  String? _staticDemoItemId;
  Timer? _mediaTimer;
  bool _skipNextPageChanged = false; // 删除/收藏/移动后忽略一次 onPageChanged，避免跳回第一项
  int _activePreviewPointers = 0;
  bool _transformOnlyMode = false;

  /// 背景视频音量：避免每帧写盘，仅在 [VideoPlayerValue.volume] 变化时持久化。
  final Map<int, double> _lastKnownVolumeForPrefs = {};
  final Map<int, void Function()> _bgVolumePersistListeners = {};

  final Map<String, Timer> _pendingCenterCommitTimers = {};
  DateTime? _ignoreCenterTapUntil;
  Future<void> _pendingViewPersist = Future<void>.value();
  bool _allowPreviewPop = false;
  bool _isFlushingBeforePop = false;
  bool get _isStandaloneBackgroundMode =>
      (widget.standaloneBackgroundFilePath ?? '').isNotEmpty;

  bool get _documentEmbeddedResumeMode =>
      widget.initialResumeVideoPosition != null;

  /// 背景视频音量读写键：优先 [volumePersistencePath]（与封面/目录等页 [File.path] 一致）。
  String _volumePrefsKeyForIndex(int index) {
    final override = widget.volumePersistencePath;
    if (override != null && override.isNotEmpty) return override;
    if (index >= 0 && index < widget.mediaItems.length) {
      return widget.mediaItems[index].path;
    }
    return '';
  }

  Duration? _videoPositionForDocumentResumePop() {
    if (!_documentEmbeddedResumeMode) return null;
    if (_currentIndex < 0 || _currentIndex >= widget.mediaItems.length) {
      return null;
    }
    if (widget.mediaItems[_currentIndex].type != MediaType.video) return null;
    final c = _videoControllers[_currentIndex];
    if (c == null || !c.value.isInitialized) return null;
    return c.value.position;
  }

  /// [shouldReloadListHint] 为 false 时与非文档模式下系统返回键一致（结果为 null）。
  void _popMediaPreview({bool shouldReloadListHint = true}) {
    if (!mounted) return;
    if (_documentEmbeddedResumeMode) {
      Navigator.of(context).pop(
        MediaPreviewPagePopResult(
          resumeVideoPosition: _videoPositionForDocumentResumePop(),
        ),
      );
    } else {
      Navigator.of(context).pop(shouldReloadListHint ? true : null);
    }
  }

  bool get _isCurrentInRecycleBin {
    if (_currentIndex < 0 || _currentIndex >= widget.mediaItems.length) {
      return widget.openedFromRecycleBin;
    }
    return widget.openedFromRecycleBin ||
        widget.mediaItems[_currentIndex].directory == 'recycle_bin';
  }

  @override
  void initState() {
    super.initState();
    _dbService = getService<DatabaseService>();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    unawaited(_loadMediaPreviewSettings());

    // 预初始化当前页和相邻页的视频控制器
    _initializeVideoControllerAt(_currentIndex);
    if (_currentIndex > 0) {
      _initializeVideoControllerAt(_currentIndex - 1);
    }
    if (_currentIndex < widget.mediaItems.length - 1) {
      _initializeVideoControllerAt(_currentIndex + 1);
    }

    // 设置状态栏为透明
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    for (final idx in _videoControllers.keys.toList()) {
      _persistBackgroundVideoVolumeAt(idx);
    }
    for (final e in _videoControllers.entries.toList()) {
      _detachBgVolumePersistListener(e.key, e.value);
    }
    unawaited(_dbService.flushStagedVideoViewParamsToDisk());
    _removeVideoCompleteListener();
    _pageController.dispose();
    _mediaTimer?.cancel();
    for (final t in _pendingCenterCommitTimers.values) {
      t.cancel();
    }
    _pendingCenterCommitTimers.clear();

    // 释放所有视频控制器
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    for (final controller in _chewieControllers.values) {
      controller.dispose();
    }

    // 恢复状态栏
    super.dispose();
  }

  void _onTripleTapResetGesture(MediaItem item) {
    _ignoreCenterTapUntil = DateTime.now().add(
      const Duration(milliseconds: 900),
    );
    final timer = _pendingCenterCommitTimers.remove(item.id);
    timer?.cancel();
    unawaited(_resetMediaPresentationToPristine(item));
  }

  Future<void> _resetMediaPresentationToPristine(MediaItem item) async {
    try {
      if (_isStandaloneBackgroundMode) {
        await _dbService.clearVideoViewParamsForFilePath(item.path);
      } else {
        const clearedView = VideoViewParams();
        _dbService.stageVideoViewParamsForDisk(item.id, clearedView);
        await _dbService.updateMediaItem({
          'id': item.id,
          'ken_burns_center_x': null,
          'ken_burns_center_y': null,
          'video_view_scale': 1.0,
          'video_view_tx': 0.0,
          'video_view_ty': 0.0,
          'video_view_rot': 0,
          'video_view_basis_w': null,
          'video_view_basis_h': null,
          'video_view_anchor_x': null,
          'video_view_anchor_y': null,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
      if (!mounted) return;
      final idx = widget.mediaItems.indexWhere((e) => e.id == item.id);
      if (idx < 0) return;
      setState(() {
        _staticKenBurnsDemo = false;
        _staticDemoItemId = null;
        _kenBurnsReplayTick++;
        widget.mediaItems[idx] = widget.mediaItems[idx].copyWith(
          clearKenBurnsCenter: true,
          clearVideoViewParams: true,
        );
      });
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已恢复媒体初始状态，所有展示设置已清空'),
          duration: Duration(milliseconds: 2200),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('恢复媒体初始状态失败: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    }
  }

  bool _shouldIgnoreCenterTap(MediaItem item) {
    final until = _ignoreCenterTapUntil;
    if (until == null) return false;
    final ignore = DateTime.now().isBefore(until);
    if (ignore) {
      final timer = _pendingCenterCommitTimers.remove(item.id);
      timer?.cancel();
    }
    return ignore;
  }

  void _schedulePersistKenBurnsCenter(MediaItem item, double nx, double ny) {
    if (_isStandaloneBackgroundMode) return;
    if (_shouldIgnoreCenterTap(item)) return;
    _pendingCenterCommitTimers[item.id]?.cancel();
    _pendingCenterCommitTimers[item.id] = Timer(
      const Duration(milliseconds: 360),
      () {
        _pendingCenterCommitTimers.remove(item.id);
        if (_shouldIgnoreCenterTap(item)) return;
        unawaited(_persistKenBurnsCenter(item, nx, ny));
      },
    );
  }

  void _schedulePersistKenBurnsCenterAndStartStaticDemo(
    MediaItem item,
    double nx,
    double ny,
  ) {
    if (_isStandaloneBackgroundMode) return;
    if (_shouldIgnoreCenterTap(item)) return;
    _pendingCenterCommitTimers[item.id]?.cancel();
    _pendingCenterCommitTimers[item.id] = Timer(
      const Duration(milliseconds: 360),
      () {
        _pendingCenterCommitTimers.remove(item.id);
        if (_shouldIgnoreCenterTap(item)) return;
        unawaited(_persistKenBurnsCenterAndStartStaticDemo(item, nx, ny));
      },
    );
  }

  /// 双击设置渐进放大中心；归一化坐标写入数据库并更新当前列表项，并立即重播动画。
  Future<void> _persistKenBurnsCenter(
    MediaItem item,
    double nx,
    double ny,
  ) async {
    try {
      await _dbService.updateMediaItem({
        'id': item.id,
        'ken_burns_center_x': nx,
        'ken_burns_center_y': ny,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      if (!mounted) return;
      final idx = widget.mediaItems.indexWhere((e) => e.id == item.id);
      if (idx < 0) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: const Text('已保存放大中心，画面将重新播放'),
          duration: const Duration(milliseconds: 2200),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
      setState(() {
        _kenBurnsReplayTick++;
        widget.mediaItems[idx] = widget.mediaItems[idx].copyWith(
          kenBurnsCenterX: nx,
          kenBurnsCenterY: ny,
        );
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存中心点失败: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    }
  }

  /// 保存视频/图片视窗（缩放/平移/旋转），持久化到 `media_items`，文档栏与预览会套用。
  /*
  Future<void> _persistMediaViewParams(
    MediaItem item,
    VideoViewParams p,
  ) async {
    final idx = widget.mediaItems.indexWhere((e) => e.id == item.id);
    if (idx >= 0 && widget.mediaItems[idx].videoViewParams != p && mounted) {
      setState(() {
        widget.mediaItems[idx] = widget.mediaItems[idx].copyWith(
          videoViewParams: p,
        );
      });
    }
    final payload = {
      'id': item.id,
      ...p.toDbUpdateMap(),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    final future = _pendingViewPersist.then((_) async {
      try {
        await _dbService.updateMediaItem(payload);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存显示方式失败: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    }
  }

  Size _basisSizeForQuarterTurns(Size viewport, int quarterTurns) {
    final q = quarterTurns % 4;
    if (q == 1 || q == 3) {
      return Size(viewport.height, viewport.width);
    }
    return viewport;
  }

  Future<void> _applyVerticalFillPreset(
    MediaItem item,
    int index,
    Size viewport,
  ) async {
    if (viewport.width <= 1 || viewport.height <= 1) return;
    try {
      final q = item.videoViewParams.quarterTurns % 4;
      final basis = _basisSizeForQuarterTurns(viewport, q);
      double? baseDisplayHeight;

      if (item.type == MediaType.image) {
        final imageSize = await measureImageFileSize(File(item.path));
        final sideways = q == 1 || q == 3;
        final baseDisplay =
            sideways
                ? containDisplaySize(imageSize, viewport.width, viewport.height)
                : fitWidthDisplaySize(imageSize, viewport.width);
        baseDisplayHeight = baseDisplay.height;
      } else if (item.type == MediaType.video) {
        final controller = _videoControllers[index];
        if (controller == null || !controller.value.isInitialized) return;
        final videoSize = controller.value.size;
        if (videoSize.width <= 1 || videoSize.height <= 1) return;
        final baseDisplay = containDisplaySize(
          videoSize,
          viewport.width,
          viewport.height,
        );
        baseDisplayHeight = baseDisplay.height;
      } else {
        return;
      }

      if (baseDisplayHeight == null || baseDisplayHeight <= 1) return;
      final targetScale = (viewport.height / baseDisplayHeight).clamp(1.0, 6.0);

      final target = VideoViewParams(
        scale: targetScale,
        txNorm: 0.0,
        tyNorm: 0.0,
        quarterTurns: q,
        basisW: basis.width,
        basisH: basis.height,
      );

      await _persistMediaViewParams(item, target);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已一键设为纵向铺满（横向居中），并自动保存'),
          duration: Duration(milliseconds: 1800),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('设置纵向铺满失败: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    }
  }

  /// 静态预览：双击后保存中心并进入一轮 Ken Burns 演示（与渐进放大模式参数一致）。
  */

  Future<void> _persistMediaViewParams(
    MediaItem item,
    VideoViewParams p,
  ) async {
    final idx = widget.mediaItems.indexWhere((e) => e.id == item.id);
    if (idx >= 0 && widget.mediaItems[idx].videoViewParams != p && mounted) {
      setState(() {
        widget.mediaItems[idx] = widget.mediaItems[idx].copyWith(
          videoViewParams: p,
        );
      });
    }
    try {
      if (_isStandaloneBackgroundMode) {
        await _dbService.upsertVideoViewParamsForFilePath(item.path, p);
      } else {
        _dbService.stageVideoViewParamsForDisk(item.id, p);
        await _dbService.updateMediaItem({
          'id': item.id,
          ...p.toDbUpdateMap(),
          if (p.anchorXNorm == null) 'video_view_anchor_x': null,
          if (p.anchorYNorm == null) 'video_view_anchor_y': null,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存显示方式失败: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    }
  }

  Size _basisSizeForQuarterTurns(Size viewport, int quarterTurns) {
    final q = quarterTurns % 4;
    if (q == 1 || q == 3) {
      return Size(viewport.height, viewport.width);
    }
    return viewport;
  }

  Future<void> _applyVerticalFillPreset(
    MediaItem item,
    int index,
    Size viewport,
  ) async {
    if (viewport.width <= 1 || viewport.height <= 1) return;
    try {
      final q = item.videoViewParams.quarterTurns % 4;
      final basis = _basisSizeForQuarterTurns(viewport, q);
      double? baseDisplayHeight;

      if (item.type == MediaType.image) {
        final imageSize = await measureImageFileSize(File(item.path));
        final sideways = q == 1 || q == 3;
        final baseDisplay =
            sideways
                ? containDisplaySize(imageSize, viewport.width, viewport.height)
                : fitWidthDisplaySize(imageSize, viewport.width);
        baseDisplayHeight = baseDisplay.height;
      } else if (item.type == MediaType.video) {
        final controller = _videoControllers[index];
        if (controller == null || !controller.value.isInitialized) return;
        final videoSize = controller.value.size;
        if (videoSize.width <= 1 || videoSize.height <= 1) return;
        final baseDisplay = containDisplaySize(
          videoSize,
          viewport.width,
          viewport.height,
        );
        baseDisplayHeight = baseDisplay.height;
      } else {
        return;
      }

      if (baseDisplayHeight == null || baseDisplayHeight <= 1) return;
      final targetScale = (viewport.height / baseDisplayHeight).clamp(1.0, 6.0);

      final target = VideoViewParams(
        scale: targetScale,
        txNorm: 0.0,
        tyNorm: 0.0,
        quarterTurns: q,
        basisW: basis.width,
        basisH: basis.height,
      );

      await _persistMediaViewParams(item, target);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已一键设为纵向铺满（横向居中），并自动保存'),
          duration: Duration(milliseconds: 1800),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('设置纵向铺满失败: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    }
  }

  Future<void> _applyFitWidthVerticalAlignPreset(
    MediaItem item,
    int index,
    Size viewport, {
    required bool alignTop,
  }) async {
    if (viewport.width <= 1 || viewport.height <= 1) return;
    try {
      final q = item.videoViewParams.quarterTurns % 4;
      final basis = _basisSizeForQuarterTurns(viewport, q);
      double? baseDisplayWidth;
      double? baseDisplayHeight;

      if (item.type == MediaType.image) {
        final imageSize = await measureImageFileSize(File(item.path));
        final sideways = q == 1 || q == 3;
        final baseDisplay =
            sideways
                ? containDisplaySize(imageSize, viewport.width, viewport.height)
                : fitWidthDisplaySize(imageSize, viewport.width);
        baseDisplayWidth = baseDisplay.width;
        baseDisplayHeight = baseDisplay.height;
      } else if (item.type == MediaType.video) {
        final controller = _videoControllers[index];
        if (controller == null || !controller.value.isInitialized) return;
        final videoSize = controller.value.size;
        if (videoSize.width <= 1 || videoSize.height <= 1) return;
        final baseDisplay = containDisplaySize(
          videoSize,
          viewport.width,
          viewport.height,
        );
        baseDisplayWidth = baseDisplay.width;
        baseDisplayHeight = baseDisplay.height;
      } else {
        return;
      }

      if (baseDisplayWidth == null ||
          baseDisplayWidth <= 1 ||
          baseDisplayHeight == null ||
          baseDisplayHeight <= 1) {
        return;
      }
      final targetScale = (viewport.width / baseDisplayWidth).clamp(1.0, 6.0);
      final scaledDisplayHeight = baseDisplayHeight * targetScale;
      final double shiftY;
      if (scaledDisplayHeight >= viewport.height) {
        final overflowY = (scaledDisplayHeight - viewport.height) / 2;
        shiftY = alignTop ? overflowY : -overflowY;
      } else {
        final gapY = (viewport.height - scaledDisplayHeight) / 2;
        shiftY = alignTop ? -gapY : gapY;
      }
      final anchorYNorm = basis.height > 1 ? (shiftY / basis.height) : 0.0;
      final target = VideoViewParams(
        scale: targetScale,
        txNorm: 0.0,
        tyNorm: 0.0,
        quarterTurns: q,
        basisW: basis.width,
        basisH: basis.height,
        anchorXNorm: 0.0,
        anchorYNorm: anchorYNorm,
      );

      await _persistMediaViewParams(item, target);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            alignTop
                ? '已一键设为横向铺满并置顶，并自动保存'
                : '已一键设为横向铺满并置底，并自动保存',
          ),
          duration: const Duration(milliseconds: 1800),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(alignTop ? '设置横向铺满置顶失败: $e' : '设置横向铺满置底失败: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    }
  }

  Future<void> _persistKenBurnsCenterAndStartStaticDemo(
    MediaItem item,
    double nx,
    double ny,
  ) async {
    try {
      await _dbService.updateMediaItem({
        'id': item.id,
        'ken_burns_center_x': nx,
        'ken_burns_center_y': ny,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      if (!mounted) return;
      final idx = widget.mediaItems.indexWhere((e) => e.id == item.id);
      if (idx < 0) return;
      _mediaTimer?.cancel();
      _mediaTimer = null;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: const Text('已保存放大中心，正在演示渐进放大效果'),
          duration: const Duration(milliseconds: 2200),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
      setState(() {
        _kenBurnsReplayTick++;
        _staticKenBurnsDemo = true;
        _staticDemoItemId = item.id;
        widget.mediaItems[idx] = widget.mediaItems[idx].copyWith(
          kenBurnsCenterX: nx,
          kenBurnsCenterY: ny,
        );
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存中心点失败: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        ),
      );
    }
  }

  void _finishStaticKenBurnsDemo() {
    if (!mounted) return;
    setState(() {
      _staticKenBurnsDemo = false;
      _staticDemoItemId = null;
    });
    if (_mediaMode == MediaMode.auto &&
        _currentIndex >= 0 &&
        _currentIndex < widget.mediaItems.length &&
        widget.mediaItems[_currentIndex].type == MediaType.image &&
        _imageMode == MediaImageDisplayMode.fitWidth) {
      _mediaTimer?.cancel();
      _mediaTimer = Timer(_imageDuration, _onMediaComplete);
    }
  }

  Future<void> _loadMediaPreviewSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final s = await loadMediaPlayerSettings(prefs);
    if (!mounted) return;
    setState(() {
      _imageDuration = s.imageDuration;
      _imageMode = s.imageMode;
      _zoomMax = s.zoomMaxScale;
      _playbackOrder = s.playbackOrder;
      _panClockwise = s.panClockwise;
      _imagePanRoamCoverage = s.imagePanRoamCoverage;
      _letterboxFill = s.letterboxFill;
      _foregroundVideoMuted = s.foregroundVideoMuted;
    });
  }

  void _showMediaPlaybackSettings() {
    showMediaPlayerSettingsDialog(
      context: context,
      initial: MediaPlayerSettingsSnapshot(
        imageDuration: _imageDuration,
        imageMode: _imageMode,
        zoomMaxScale: _zoomMax,
        playbackOrder: _playbackOrder,
        panClockwise: _panClockwise,
        imagePanRoamCoverage: _imagePanRoamCoverage,
        letterboxFill: _letterboxFill,
        foregroundVideoMuted: _foregroundVideoMuted,
      ),
      onSettingsChanged: (snap) async {
        if (!mounted) return;
        setState(() {
          _imageDuration = snap.imageDuration;
          _imageMode = snap.imageMode;
          _zoomMax = snap.zoomMaxScale;
          _playbackOrder = snap.playbackOrder;
          _panClockwise = snap.panClockwise;
          _imagePanRoamCoverage = snap.imagePanRoamCoverage;
          _letterboxFill = snap.letterboxFill;
          _foregroundVideoMuted = snap.foregroundVideoMuted;
          if (snap.imageMode != MediaImageDisplayMode.fitWidth) {
            _staticKenBurnsDemo = false;
            _staticDemoItemId = null;
          }
        });
        // 自动播放 + 当前为图片：静态模式用定时器；动画模式由组件 key 重建触发新动画
        if (_mediaMode == MediaMode.auto &&
            _currentIndex >= 0 &&
            _currentIndex < widget.mediaItems.length) {
          final cur = widget.mediaItems[_currentIndex];
          if (cur.type == MediaType.image) {
            _mediaTimer?.cancel();
            _mediaTimer = null;
            if (snap.imageMode == MediaImageDisplayMode.fitWidth) {
              _mediaTimer = Timer(snap.imageDuration, _onMediaComplete);
            }
          }
        }
      },
    );
  }

  /// Large / HEVC Telegram files often need well over 10s to open moov + decoder.
  Duration _videoInitTimeoutForBytes(int fileSize) {
    if (fileSize <= 80 * 1024 * 1024) return const Duration(seconds: 15);
    if (fileSize <= 200 * 1024 * 1024) return const Duration(seconds: 35);
    if (fileSize <= 500 * 1024 * 1024) return const Duration(seconds: 60);
    return const Duration(seconds: 90);
  }

  Future<void> _initializeVideoControllerAt(int index) async {
    if (index < 0 || index >= widget.mediaItems.length) return;

    final item = widget.mediaItems[index];
    if (item.type != MediaType.video) return;
    if (_videoControllers.containsKey(index) &&
        _chewieControllers.containsKey(index)) {
      return;
    }
    if (_videoInitInFlight.contains(index)) return;
    _videoInitInFlight.add(index);

    try {
      if (!_videoControllers.containsKey(index)) {
        // 检查文件是否存在
        final File videoFile = File(item.path);
        if (!await videoFile.exists()) {
          _videoInitFailed.add(index);
          _videoInitFailureDetail[index] = '文件不存在';
          if (mounted) setState(() {});
          return;
        }

        // 验证文件大小
        final fileSize = await videoFile.length();
        if (fileSize <= 0) {
          _videoInitFailed.add(index);
          _videoInitFailureDetail[index] = '文件为空';
          if (mounted) setState(() {});
          return;
        }

        final controller = VideoPlayerController.file(videoFile);
        _videoControllers[index] = controller;

        // 添加错误监听器
        controller.addListener(() {
          if (controller.value.hasError) {}
        });

        // 大文件 / HEVC 打开 moov 与硬解初始化常超过旧的 10s 上限；
        // 超时后若静默丢掉 controller，界面会永远停在「正在加载视频」。
        final initTimeout = _videoInitTimeoutForBytes(fileSize);
        bool initializeSuccessful = false;
        Object? initError;
        try {
          debugPrint(
            'preview video init start index=$index '
            'sizeMB=${(fileSize / (1024 * 1024)).toStringAsFixed(1)} '
            'timeout=${initTimeout.inSeconds}s path=${item.path}',
          );
          await controller.initialize().timeout(initTimeout);
          initializeSuccessful = controller.value.isInitialized;
          if (!initializeSuccessful) {
            initError = controller.value.errorDescription ?? 'not initialized';
          }
        } catch (e) {
          initError = e;
        }

        if (!initializeSuccessful) {
          debugPrint(
            'preview video init FAILED index=$index '
            'sizeMB=${(fileSize / (1024 * 1024)).toStringAsFixed(1)} '
            'error=$initError',
          );
          if (_videoControllers.containsKey(index)) {
            _videoControllers[index]?.dispose();
            _videoControllers.remove(index);
          }
          _videoInitFailed.add(index);
          _videoInitFailureDetail[index] = initError == null
              ? '初始化失败'
              : initError.toString();
          if (mounted) setState(() {});
          return;
        }
        _videoInitFailed.remove(index);
        _videoInitFailureDetail.remove(index);
        debugPrint(
          'preview video init OK index=$index '
          'sizeMB=${(fileSize / (1024 * 1024)).toStringAsFixed(1)} '
          'size=${controller.value.size}',
        );

        if (widget.initialResumeVideoPosition != null &&
            index == widget.initialIndex &&
            widget.initialResumeVideoPosition! > Duration.zero) {
          var pos = widget.initialResumeVideoPosition!;
          final dur = controller.value.duration;
          if (dur > Duration.zero) {
            if (pos >= dur) {
              pos = dur - const Duration(milliseconds: 50);
            }
            if (pos < Duration.zero) pos = Duration.zero;
            await controller.seekTo(pos);
            if (!mounted) return;
          }
        }

        final volKey = _volumePrefsKeyForIndex(index);
        final bgVol = volKey.isEmpty
            ? 1.0
            : await BackgroundVideoVolumePrefs.volumeForPath(volKey);
        await controller.setVolume(bgVol);
        _lastKnownVolumeForPrefs[index] = bgVol;
        _attachBgVolumePersistListener(index, controller, item, volKey);

        // 自动播放当前视频
        final bool shouldAutoPlay = index == _currentIndex;

        try {
          final chewieController = ChewieController(
            videoPlayerController: controller,
            autoPlay: shouldAutoPlay,
            looping: false,
            allowFullScreen: false,
            allowMuting: true,
            showControls: true,
            showControlsOnInitialize: true,
            deviceOrientationsAfterFullScreen: [DeviceOrientation.portraitUp],
            placeholder: Container(
              color: Colors.transparent, // 将黑色背景改为透明
              child: const Center(child: CircularProgressIndicator()),
            ),
            errorBuilder: (context, errorMessage) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 42),
                    const SizedBox(height: 8),
                    Text(
                      '无法播放视频: $errorMessage',
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
            materialProgressColors: ChewieProgressColors(
              playedColor: Colors.red,
              handleColor: Colors.red,
              backgroundColor: Colors.white.withOpacity(0.3),
              bufferedColor: Colors.white.withOpacity(0.5),
            ),
            controlsSafeAreaMinimum: EdgeInsets.zero,
            showOptions: true,
            isLive: false,
            allowPlaybackSpeedChanging: true,
            draggableProgressBar: true,
            // 媒体页底栏进度条：约为默认一半粗细，更精致
            materialProgressBarHeight: 7,
            materialProgressHandleHeight: 9,
            useRootNavigator: false,
            customControls: const MaterialControls(
              showPlayButton: false,
              hideBottomBar: true,
              hideTopActionBar: true,
            ),
          );

          _chewieControllers[index] = chewieController;

          // 如果是当前页面，立即开始播放，并添加完成监听（手动/非自动模式下用于循环）
          if (shouldAutoPlay && controller.value.isInitialized) {
            final resumed =
                widget.initialResumeVideoPosition != null &&
                index == widget.initialIndex &&
                widget.initialResumeVideoPosition! > Duration.zero;
            if (!resumed) {
              try {
                await controller.seekTo(const Duration(milliseconds: 1));
              } catch (_) {}
            }
            await controller.play();
            _addVideoCompleteListenerFor(controller, index);
            unawaited(_unstickFrozenFirstFrameAt(index));
          }
        } catch (chewieError) {
          if (_videoControllers.containsKey(index)) {
            await _videoControllers[index]?.pause();
            await _videoControllers[index]?.dispose();
            _videoControllers.remove(index);
          }
          _videoInitFailed.add(index);
          _videoInitFailureDetail[index] = chewieError.toString();
          if (mounted) setState(() {});
          return;
        }

        if (mounted) setState(() {});
      }
    } catch (e) {
      if (_videoControllers.containsKey(index)) {
        _videoControllers[index]?.dispose();
        _videoControllers.remove(index);
      }
      if (_chewieControllers.containsKey(index)) {
        _chewieControllers[index]?.dispose();
        _chewieControllers.remove(index);
      }
      _videoInitFailed.add(index);
      _videoInitFailureDetail[index] = e.toString();
      if (mounted) setState(() {});
    } finally {
      _videoInitInFlight.remove(index);
    }
  }

  void _attachBgVolumePersistListener(
    int index,
    VideoPlayerController controller,
    MediaItem item,
    String volumePrefsPath,
  ) {
    if (item.type != MediaType.video) return;
    if (volumePrefsPath.isEmpty) return;
    void listener() {
      if (!controller.value.isInitialized) return;
      final v = controller.value.volume;
      final last = _lastKnownVolumeForPrefs[index];
      if (last != null && (v - last).abs() < 1e-5) return;
      _lastKnownVolumeForPrefs[index] = v;
      unawaited(BackgroundVideoVolumePrefs.setVolumeForPath(volumePrefsPath, v));
    }

    _bgVolumePersistListeners[index] = listener;
    controller.addListener(listener);
  }

  void _detachBgVolumePersistListener(int index, VideoPlayerController controller) {
    final fn = _bgVolumePersistListeners.remove(index);
    if (fn != null) {
      controller.removeListener(fn);
    }
    _lastKnownVolumeForPrefs.remove(index);
  }

  void _persistBackgroundVideoVolumeAt(int index) {
    final c = _videoControllers[index];
    if (c == null || !c.value.isInitialized) return;
    if (index < 0 || index >= widget.mediaItems.length) return;
    final mediaItem = widget.mediaItems[index];
    if (mediaItem.type != MediaType.video) return;
    final volKey = _volumePrefsKeyForIndex(index);
    if (volKey.isEmpty) return;
    unawaited(
      BackgroundVideoVolumePrefs.setVolumeForPath(volKey, c.value.volume),
    );
  }

  void _disposeVideoControllerAt(int index) {
    final c = _videoControllers[index];
    if (c != null) {
      _persistBackgroundVideoVolumeAt(index);
      _detachBgVolumePersistListener(index, c);
    }

    if (_videoControllers.containsKey(index)) {
      _videoControllers[index]?.pause();
    }

    if (_chewieControllers.containsKey(index)) {
      _chewieControllers[index]?.dispose();
      _chewieControllers.remove(index);
    }

    if (_videoControllers.containsKey(index)) {
      _videoControllers[index]?.dispose();
      _videoControllers.remove(index);
    }
  }

  void _cleanupUnusedControllers() {
    final List<int> indicesToKeep = [_currentIndex];
    if (_currentIndex > 0) indicesToKeep.add(_currentIndex - 1);
    if (_currentIndex < widget.mediaItems.length - 1)
      indicesToKeep.add(_currentIndex + 1);

    final List<int> indicesToRemove =
        _videoControllers.keys
            .where((index) => !indicesToKeep.contains(index))
            .toList();

    for (final index in indicesToRemove) {
      _disposeVideoControllerAt(index);
    }
  }

  /// 移除当前项后清空所有视频控制器（索引已变化，需重新初始化）
  void _disposeAllVideoControllers() {
    final indices = _videoControllers.keys.toList();
    for (final index in indices) {
      _disposeVideoControllerAt(index);
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });

    // 暂停上一页的视频
    if (_videoControllers.containsKey(_currentIndex - 1)) {
      _videoControllers[_currentIndex - 1]?.pause();
    }

    // 暂停下一页的视频
    if (_videoControllers.containsKey(_currentIndex + 1)) {
      _videoControllers[_currentIndex + 1]?.pause();
    }

    // 初始化相邻页面的视频控制器
    _initializeVideoControllerAt(index);
    if (index > 0) {
      _initializeVideoControllerAt(index - 1);
    }
    if (index < widget.mediaItems.length - 1) {
      _initializeVideoControllerAt(index + 1);
    }

    // 清理不需要的视频控制器
    _cleanupUnusedControllers();

    // 添加自动播放当前视频的逻辑
    _autoPlayCurrentVideo();
  }

  // 自动播放当前视频
  void _autoPlayCurrentVideo() {
    if (_currentIndex < 0 || _currentIndex >= widget.mediaItems.length) return;

    final currentItem = widget.mediaItems[_currentIndex];
    if (currentItem.type == MediaType.video) {
      // 确保视频控制器已初始化
      _initializeVideoControllerAt(_currentIndex).then((_) async {
        final controller = _videoControllers[_currentIndex];
        if (controller == null || !controller.value.isInitialized) return;
        try {
          if (controller.value.position <= const Duration(milliseconds: 1)) {
            await controller.seekTo(const Duration(milliseconds: 1));
          }
        } catch (_) {}
        await controller.play();
        unawaited(_unstickFrozenFirstFrameAt(_currentIndex));
      });
    }
  }

  /// Legacy MediaMuxer remux MP4s have crushed B-frame PTS and often stay at 0;
  /// a near-zero seek cannot repair them. New HLS downloads keep `.ts` instead.
  Future<void> _unstickFrozenFirstFrameAt(int index) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    final controller = _videoControllers[index];
    if (controller == null || index != _currentIndex) return;
    final v = controller.value;
    if (!v.isInitialized || v.duration <= const Duration(seconds: 1)) return;
    if (v.position > const Duration(milliseconds: 80)) return;
    try {
      // Kick past the near-zero PTS cluster on legacy remux files when possible.
      final kickMs = v.duration.inMilliseconds > 4000 ? 1000 : 200;
      await controller.seekTo(Duration(milliseconds: kickMs));
      if (!mounted || index != _currentIndex) return;
      await controller.play();
    } catch (_) {}
  }

  void _shareMediaItem() async {
    final item = widget.mediaItems[_currentIndex];
    try {
      await Share.shareXFiles([XFile(item.path)], subject: '分享: ${item.name}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('分享文件时出错: $e')));
      }
    }
  }

  /// 与 Chewie 原「三点」菜单一致：播放速度（顶栏内操作，避免与缩放层重叠或被挤出屏外）。
  Future<void> _showPlaybackSpeedMenu() async {
    if (_currentIndex < 0 || _currentIndex >= widget.mediaItems.length) return;
    if (widget.mediaItems[_currentIndex].type != MediaType.video) return;
    final vc = _videoControllers[_currentIndex];
    final cc = _chewieControllers[_currentIndex];
    if (vc == null || cc == null || !vc.value.isInitialized) return;
    if (!cc.allowPlaybackSpeedChanging) return;
    final chosen = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: cc.useRootNavigator,
      builder:
          (context) => PlaybackSpeedDialog(
            speeds: cc.playbackSpeeds,
            selected: vc.value.playbackSpeed,
          ),
    );
    if (chosen != null && mounted) {
      await vc.setPlaybackSpeed(chosen);
      setState(() {});
    }
  }

  // 删除当前媒体项 - 无需确认
  Future<void> _deleteCurrentMediaItem() async {
    final item = widget.mediaItems[_currentIndex];

    try {
      // 1. 从数据库中删除
      try {
        await _dbService.deleteMediaItem(item.id);
      } catch (e) {}

      // 2. 尝试删除实际文件
      try {
        final file = File(item.path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {}

      // 3. 从当前列表中移除
      if (!mounted) return;

      // 判断是否还有媒体项
      if (widget.mediaItems.length <= 1) {
        // 如果当前是最后一个媒体项，则关闭预览页面
        _popMediaPreview(shouldReloadListHint: true);
        return;
      }

      // 保存当前索引，确定是移动到下一个还是前一个
      int nextIndex = _currentIndex;
      if (_currentIndex >= widget.mediaItems.length - 1) {
        // 如果删除的是最后一项，则移到前一项
        nextIndex = _currentIndex - 1;
      }
      // 否则保持当前索引，因为删除后当前索引会对应下一项

      _disposeAllVideoControllers(); // 索引变化，清空控制器以便重新初始化
      _skipNextPageChanged = true; // 防止新 PageView 触发 onPageChanged(0) 覆盖索引
      setState(() {
        widget.mediaItems.removeAt(_currentIndex);
        _currentIndex = nextIndex;
        _pageController.jumpToPage(_currentIndex);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _pageController.jumpToPage(_currentIndex);
          _autoPlayCurrentVideo();
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
    }
  }

  // 移动当前媒体项 - 完全使用媒体管理页面中的移动功能实现
  Future<void> _moveCurrentMediaItem() async {
    final item = widget.mediaItems[_currentIndex];
    List<MediaItem> folders = [];

    try {
      // 获取根目录下的文件夹
      final rootItems = await _dbService.getMediaItems('root');
      final rootFolders =
          rootItems
              .where((item) => item['type'] == MediaType.folder.index)
              .map((item) => MediaItem.fromMap(item))
              .toList();

      folders = rootFolders;

      // 递归获取子文件夹（如果需要）
      for (var folder in rootFolders) {
        try {
          final subItems = await _dbService.getMediaItems(folder.id);
          final subFolders =
              subItems
                  .where((item) => item['type'] == MediaType.folder.index)
                  .map((item) => MediaItem.fromMap(item))
                  .toList();
          if (subFolders.isNotEmpty) {
            folders.addAll(subFolders);
          }
        } catch (e) {}
      }
    } catch (e) {}

    final MediaItem? targetFolder = await showMoveToFolderSheet(
      context: context,
      folders: folders,
      includeRoot: true,
      rootEnabled: true,
    );

    // 如果用户取消，则不执行任何操作
    if (targetFolder == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            backgroundColor: Colors.white.withOpacity(0.8),
            content: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 20),
                Text('正在移动媒体...', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
    );

    try {
      // 使用媒体管理页面中的移动方法
      final updatedItem = item.copyWith(directory: targetFolder.id);

      final result = await _dbService.updateMediaItem(updatedItem.toMap());
      if (result <= 0) {
        throw Exception('媒体项更新失败');
      }

      if (mounted) {
        Navigator.of(context).pop();
      }

      // 从当前列表中移除
      if (!mounted) return;
      int nextIndex = _currentIndex;
      if (_currentIndex >= widget.mediaItems.length - 1) {
        nextIndex = _currentIndex - 1;
      }
      _disposeAllVideoControllers();
      _skipNextPageChanged = true;
      setState(() {
        widget.mediaItems.removeAt(_currentIndex);
        if (widget.mediaItems.isEmpty) {
          _popMediaPreview(shouldReloadListHint: true);
          return;
        }
        _currentIndex = nextIndex;
        _pageController.jumpToPage(_currentIndex);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.mediaItems.isNotEmpty) {
          _pageController.jumpToPage(_currentIndex);
          _autoPlayCurrentVideo();
        }
      });
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // 关闭进度对话框
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移动失败: $e')));
      }
    }
  }

  /// 静态横向填满：双击根据触点写入中心点并触发一轮渐进放大演示。
  Widget _buildStaticFitWidthWithDoubleTap(MediaItem item) {
    final file = File(item.path);
    final sideways = item.videoViewParams.quarterTurns % 2 == 1;
    return FutureBuilder<Size>(
      future: measureImageFileSize(file),
      builder: (context, snapshot) {
        if (snapshot.hasError || !snapshot.hasData) {
          return FitWidthBlurStaticImage(
            key: ValueKey('${item.path}_fit_loading'),
            file: file,
            letterboxFill: _letterboxFill,
            fitContainInViewport: sideways,
            zoomCenterX: item.kenBurnsCenterX,
            zoomCenterY: item.kenBurnsCenterY,
          );
        }
        final pixelSize = snapshot.data!;
        return LayoutBuilder(
          builder: (context, constraints) {
            final vw = constraints.maxWidth;
            final vh = constraints.maxHeight;
            final disp =
                sideways
                    ? containDisplaySize(pixelSize, vw, vh)
                    : fitWidthDisplaySize(pixelSize, vw);
            final dw = disp.width;
            final dh = disp.height;
            // 与 Ken Burns 一致：归一化坐标相对「图片矩形」左上角。静态图在 Stack 内垂直居中，
            // localPosition 相对整页，须减去图片顶边偏移，否则 ny 会系统性偏大（小黄点落在手指下方）。
            final imageTopY = (vh - dh) / 2;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTapDown: (TapDownDetails d) {
                final lp = d.localPosition;
                final nx = (lp.dx / dw).clamp(0.0, 1.0);
                final ny = ((lp.dy - imageTopY) / dh).clamp(0.0, 1.0);
                _schedulePersistKenBurnsCenterAndStartStaticDemo(item, nx, ny);
              },
              child: FitWidthBlurStaticImage(
                key: ValueKey(
                  '${item.path}_fit_${_imageDuration.inMilliseconds}_${_letterboxFill.index}_'
                  'r${item.videoViewParams.quarterTurns % 4}',
                ),
                file: file,
                letterboxFill: _letterboxFill,
                fitContainInViewport: sideways,
                zoomCenterX: item.kenBurnsCenterX,
                zoomCenterY: item.kenBurnsCenterY,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildImagePreview(MediaItem item, Size viewportSize) {
    final file = File(item.path);
    final loopAnim = _mediaMode != MediaMode.auto;
    final sideways = item.videoViewParams.quarterTurns % 2 == 1;

    void onAnimComplete() {
      if (_mediaMode == MediaMode.auto && mounted) {
        _onMediaComplete();
      }
    }

    Widget inner;
    switch (_imageMode) {
      case MediaImageDisplayMode.kenBurns:
        inner = KenBurnsImageDisplay(
          key: ValueKey(
            '${item.path}_ken_${_mediaMode}_${_imageDuration.inMilliseconds}_'
            '${_zoomMax.toStringAsFixed(1)}_${_letterboxFill.index}_'
            '${item.kenBurnsCenterX?.toStringAsFixed(3) ?? 'c'}_'
            '${item.kenBurnsCenterY?.toStringAsFixed(3) ?? 'c'}_'
            'r${item.videoViewParams.quarterTurns % 4}_'
            '$_kenBurnsReplayTick',
          ),
          imageFile: file,
          animationDuration: _imageDuration,
          maxScale: _zoomMax,
          letterboxFill: _letterboxFill,
          fitContainInViewport: sideways,
          zoomCenterX: item.kenBurnsCenterX,
          zoomCenterY: item.kenBurnsCenterY,
          enableDoubleTapToSetZoomCenter: !_isStandaloneBackgroundMode,
          onZoomCenterSet: (nx, ny) async {
            _schedulePersistKenBurnsCenter(item, nx, ny);
          },
          loop: loopAnim,
          onAnimationComplete: loopAnim ? null : onAnimComplete,
        );
        break;
      case MediaImageDisplayMode.zoomPanEdge:
        inner = ZoomPanEdgeImageDisplay(
          key: ValueKey(
            '${item.path}_zpan_${_mediaMode}_${_imageDuration.inMilliseconds}_'
            '${_zoomMax.toStringAsFixed(1)}_${_imagePanRoamCoverage.toStringAsFixed(2)}_'
            '${_panClockwise}_${_letterboxFill.index}_'
            'r${item.videoViewParams.quarterTurns % 4}_'
            '$_kenBurnsReplayTick',
          ),
          imageFile: file,
          totalDuration: _imageDuration,
          maxScale: _zoomMax,
          clockwise: _panClockwise,
          panPathCoverage: _imagePanRoamCoverage,
          letterboxFill: _letterboxFill,
          fitContainInViewport: sideways,
          loop: loopAnim,
          onAnimationComplete: loopAnim ? null : onAnimComplete,
        );
        break;
      case MediaImageDisplayMode.fitWidth:
        if (_staticKenBurnsDemo && _staticDemoItemId == item.id) {
          inner = KenBurnsImageDisplay(
            key: ValueKey(
              'static_demo_${item.path}_${_imageDuration.inMilliseconds}_'
              '${_zoomMax.toStringAsFixed(1)}_${_letterboxFill.index}_'
              '${item.kenBurnsCenterX?.toStringAsFixed(3) ?? 'c'}_'
              '${item.kenBurnsCenterY?.toStringAsFixed(3) ?? 'c'}_'
              'r${item.videoViewParams.quarterTurns % 4}_'
              '$_kenBurnsReplayTick',
            ),
            imageFile: file,
            animationDuration: _imageDuration,
            maxScale: _zoomMax,
            letterboxFill: _letterboxFill,
            fitContainInViewport: sideways,
            zoomCenterX: item.kenBurnsCenterX,
            zoomCenterY: item.kenBurnsCenterY,
            enableDoubleTapToSetZoomCenter: !_isStandaloneBackgroundMode,
            onZoomCenterSet: (nx, ny) async {
              _schedulePersistKenBurnsCenter(item, nx, ny);
            },
            loop: false,
            onAnimationComplete: _finishStaticKenBurnsDemo,
          );
        } else {
          inner = _buildStaticFitWidthWithDoubleTap(item);
        }
        break;
    }

    // 与视频一致：双指缩放、单指平移、「7」字旋转；持久化到 media_items.video_view_*。
    return ImageInteractiveSurface(
      key: ValueKey('img_isurf_${item.id}'),
      initial: item.videoViewParams,
      editable: true,
      singleFingerPanEnabled: _transformOnlyMode,
      // 必须与 InteractiveViewer 实际视口 (LayoutBuilder) 一致，勿用整屏尺寸，
      // 否则退出再进入会因基准不一致出现系统性偏移（常见左上）。
      useScreenSizeForNormalization: false,
      onTripleTapReset: () => _onTripleTapResetGesture(item),
      onSingleFingerSwipeUp:
          () => unawaited(
            _applyFitWidthVerticalAlignPreset(
              item,
              _currentIndex,
              viewportSize,
              alignTop: true,
            ),
          ),
      onSingleFingerSwipeDown:
          () => unawaited(
            _applyFitWidthVerticalAlignPreset(
              item,
              _currentIndex,
              viewportSize,
              alignTop: false,
            ),
          ),
      onChanged: (p) => _persistMediaViewParams(item, p),
      child: inner,
    );
  }

  Widget _buildVideoPreview(MediaItem item, int index, Size viewportSize) {
    if (!_videoControllers.containsKey(index) ||
        !_chewieControllers.containsKey(index)) {
      if (_videoInitFailed.contains(index)) {
        final detail = (_videoInitFailureDetail[index] ?? '').trim();
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.orange, size: 48),
                const SizedBox(height: 10),
                const Text(
                  '视频加载失败',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  detail.isEmpty
                      ? '大文件或特殊编码（如 HEVC）可能需要更久；也可点重试。'
                      : detail,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                TextButton(
                  onPressed: () {
                    _videoInitFailed.remove(index);
                    _videoInitFailureDetail.remove(index);
                    setState(() {});
                    unawaited(
                      _initializeVideoControllerAt(index).then((_) {
                        if (!mounted) return;
                        if (index == _currentIndex) _playCurrentMedia();
                      }),
                    );
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      }
      // 视频控制器尚未初始化，显示加载中
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 8),
            Text('正在加载视频...', style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }

    final videoController = _videoControllers[index]!;
    final chewieController = _chewieControllers[index]!;

    if (videoController.value.hasError) {
      // 视频加载出错
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error, color: Colors.red, size: 48),
            const SizedBox(height: 8),
            Text(
              '视频加载失败: ${videoController.value.errorDescription}',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final themedStack = Theme(
      data: Theme.of(context).copyWith(platform: TargetPlatform.iOS),
      child: ChewieFullscreenHost(
        controller: chewieController,
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoInteractiveSurface(
              key: ValueKey(item.id),
              videoController: videoController,
              videoChild: const PlayerWithControls(),
              initial: item.videoViewParams,
              editable: true,
              singleFingerPanEnabled: _transformOnlyMode,
              // 必须与 InteractiveViewer 实际视口 (LayoutBuilder) 一致，勿用整屏尺寸，
              // 否则退出再进入会因基准不一致出现系统性偏移（常见左上）。
              useScreenSizeForNormalization: false,
              onTripleTapReset: () => _onTripleTapResetGesture(item),
              onSingleFingerSwipeUp:
                  () => unawaited(
                    _applyFitWidthVerticalAlignPreset(
                      item,
                      index,
                      viewportSize,
                      alignTop: true,
                    ),
                  ),
              onSingleFingerSwipeDown:
                  () => unawaited(
                    _applyFitWidthVerticalAlignPreset(
                      item,
                      index,
                      viewportSize,
                      alignTop: false,
                    ),
                  ),
              onChanged: (p) => _persistMediaViewParams(item, p),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MaterialControls(
                showPlayButton: false,
                bottomBarOnly: true,
                replaceFullscreenWithPlayPause: true,
              ),
            ),
          ],
        ),
      ),
    );

    return Center(
      child: ColoredBox(
        color: Colors.transparent,
        child: SizedBox.expand(child: themedStack),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final bool pageSwipeLocked =
        _transformOnlyMode || _activePreviewPointers >= 2;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        if (_activePreviewPointers != 0) return;
        if (!mounted) return;
        _popMediaPreview(shouldReloadListHint: false);
      },
      child: Scaffold(
        // 与「透明留白」配合：上下未铺满处透出黑底，白色顶栏图标可见；图片区仍由内容层绘制。
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 主内容 - 媒体预览
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                setState(() {
                  _activePreviewPointers += 1;
                });
              },
              onPointerUp: (_) {
                setState(() {
                  _activePreviewPointers = (_activePreviewPointers - 1).clamp(
                    0,
                    10,
                  );
                });
              },
              onPointerCancel: (_) {
                setState(() {
                  _activePreviewPointers = (_activePreviewPointers - 1).clamp(
                    0,
                    10,
                  );
                });
              },
              child: PageView.builder(
                key: ValueKey(widget.mediaItems.length), // 列表变更时强制重建，确保视频正确切换
                controller: _pageController,
                physics:
                    pageSwipeLocked
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                itemCount: widget.mediaItems.length,
                onPageChanged: (index) {
                  if (_skipNextPageChanged) {
                    _skipNextPageChanged = false;
                    return;
                  }
                  setState(() {
                    _currentIndex = index;
                    _staticKenBurnsDemo = false;
                    _staticDemoItemId = null;
                  });

                  // 确保当前页面的视频控制器已初始化，然后立即播放（手动/自动模式一致）
                  _initializeVideoControllerAt(index).then((_) {
                    if (!mounted) return;
                    _cleanupUnusedControllers();
                    _playCurrentMedia();
                  });
                  // 预加载相邻页面的视频
                  if (index > 0) {
                    _initializeVideoControllerAt(index - 1);
                  }
                  if (index < widget.mediaItems.length - 1) {
                    _initializeVideoControllerAt(index + 1);
                  }
                },
                itemBuilder: (context, index) {
                  final item = widget.mediaItems[index];
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final mediaChild =
                          item.type == MediaType.video
                              ? _buildVideoPreview(
                                item,
                                index,
                                Size(
                                  constraints.maxWidth,
                                  constraints.maxHeight,
                                ),
                              )
                              : _buildImagePreview(
                                item,
                                Size(
                                  constraints.maxWidth,
                                  constraints.maxHeight,
                                ),
                              );
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onLongPress: () {
                          unawaited(
                            _applyVerticalFillPreset(
                              item,
                              index,
                              Size(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              ),
                            ),
                          );
                        },
                        child: mediaChild,
                      );
                    },
                  );
                },
              ),
            ),

            // 顶部工具栏 - 始终显示
            Positioned(
              top: MediaQuery.of(context).padding.top,
              left: 0,
              right: 0,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                color: Colors.transparent,
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.arrow_back,
                        color: Colors.white,
                        shadows: FloatingUiShadows.whiteIcon,
                      ),
                      onPressed: () => _popMediaPreview(shouldReloadListHint: true),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: Icon(
                        Icons.share,
                        color: Colors.white,
                        shadows: FloatingUiShadows.whiteIcon,
                      ),
                      onPressed: _shareMediaItem,
                    ),
                    const Spacer(),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                          icon: Icon(
                            Icons.settings,
                            color: Colors.white,
                            shadows: FloatingUiShadows.whiteIcon,
                          ),
                          tooltip: '媒体播放设置',
                          onPressed: _showMediaPlaybackSettings,
                        ),
                        IconButton(
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                          icon: Icon(
                            _mediaMode == MediaMode.auto
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                            shadows: FloatingUiShadows.whiteIcon,
                          ),
                          onPressed: () {
                            if (_mediaMode == MediaMode.auto) {
                              stop();
                            } else {
                              playAuto();
                            }
                          },
                          tooltip:
                              _mediaMode == MediaMode.auto
                                  ? '暂停自动播放'
                                  : '开始自动播放',
                        ),
                        if (widget.mediaItems.isNotEmpty &&
                            _currentIndex < widget.mediaItems.length &&
                            widget.mediaItems[_currentIndex].type ==
                                MediaType.video)
                          IconButton(
                            padding: const EdgeInsets.all(8),
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            icon: Icon(
                              Icons.more_vert,
                              color: Colors.white,
                              shadows: FloatingUiShadows.whiteIcon,
                            ),
                            tooltip: '播放速度',
                            onPressed: _showPlaybackSpeedMenu,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // 收藏、删除、移动按钮 - 始终显示
            Positioned(
              right: 16,
              bottom: 160,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!_isStandaloneBackgroundMode &&
                      _currentIndex >= 0 &&
                      _currentIndex < widget.mediaItems.length &&
                      (widget.mediaItems[_currentIndex].type ==
                              MediaType.image ||
                          widget.mediaItems[_currentIndex].type ==
                              MediaType.video) &&
                      !_isCurrentInRecycleBin)
                    _buildActionButton(
                      icon:
                          widget.mediaItems[_currentIndex].isFavorite
                              ? Icons.favorite
                              : Icons.favorite_border,
                      tooltip:
                          widget.mediaItems[_currentIndex].isFavorite
                              ? '取消收藏'
                              : '收藏',
                      onPressed: _toggleFavorite,
                      iconColor:
                          widget.mediaItems[_currentIndex].isFavorite
                              ? Colors.pink.withValues(alpha: 0.4)
                              : null,
                      useIconShadow:
                          !widget.mediaItems[_currentIndex].isFavorite,
                    ),
                  if (!_isStandaloneBackgroundMode) const SizedBox(height: 8),
                  if (!_isStandaloneBackgroundMode)
                    _buildActionButton(
                      icon: Icons.delete_outline,
                      tooltip: _isCurrentInRecycleBin ? '彻底删除' : '删除',
                      onPressed:
                          _isCurrentInRecycleBin
                              ? _deleteCurrentMediaItem
                              : _moveToTrash,
                    ),
                  if (!_isStandaloneBackgroundMode) const SizedBox(height: 8),
                  if (!_isStandaloneBackgroundMode)
                    _buildActionButton(
                      icon: Icons.drive_file_move_outline,
                      tooltip: '移动',
                      onPressed: _moveCurrentMediaItem,
                    ),
                  if (!_isStandaloneBackgroundMode) const SizedBox(height: 8),
                  _buildActionButton(
                    icon:
                        _transformOnlyMode
                            ? Icons.pan_tool
                            : Icons.zoom_out_map,
                    tooltip: _transformOnlyMode ? '关闭缩放/移动模式' : '开启缩放/移动模式',
                    onPressed: () {
                      setState(() {
                        _transformOnlyMode = !_transformOnlyMode;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            _transformOnlyMode
                                ? '已开启缩放/移动模式（禁用左右翻页）'
                                : '已关闭缩放/移动模式（恢复左右翻页）',
                          ),
                          duration: const Duration(milliseconds: 1500),
                          behavior: SnackBarBehavior.floating,
                          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 星标收藏：不移动目录，仅更新排序与缩略图标识。
  Future<void> _toggleFavorite() async {
    if (_currentIndex < 0 || _currentIndex >= widget.mediaItems.length) {
      return;
    }
    final item = widget.mediaItems[_currentIndex];
    try {
      await _dbService.toggleMediaItemFavorite(item.id);
      final row = await _dbService.getMediaItemById(item.id);
      if (!mounted || row == null) return;
      final n = widget.mediaItems.length;
      final from = _currentIndex;
      setState(() {
        widget.mediaItems[from] = MediaItem.fromMap(row);
      });
      if (n > 1) {
        final next = (from + 1) % n;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _pageController.jumpToPage(next);
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('收藏操作失败: $e')));
    }
  }

  // 移动到回收站
  Future<void> _moveToTrash() async {
    if (_isCurrentInRecycleBin) {
      await _deleteCurrentMediaItem();
      return;
    }
    final item = widget.mediaItems[_currentIndex];
    try {
      // 获取所有文件夹以找到回收站文件夹
      final rootItems = await _dbService.getMediaItems('root');
      final trashFolder =
          rootItems
              .where(
                (item) =>
                    item['type'] == MediaType.folder.index &&
                    item['name'] == '回收站',
              )
              .map((item) => MediaItem.fromMap(item))
              .firstOrNull;

      if (trashFolder == null) {
        throw Exception('找不到回收站文件夹');
      }

      // 更新媒体项到回收站目录
      final updatedItem = item.copyWith(directory: trashFolder.id);

      final result = await _dbService.updateMediaItem(updatedItem.toMap());
      if (result <= 0) {
        throw Exception('移动到回收站失败');
      }

      if (!mounted) return;
      _disposeAllVideoControllers();
      final nextIndex =
          _currentIndex >= widget.mediaItems.length - 1
              ? widget.mediaItems.length - 2
              : _currentIndex;
      _skipNextPageChanged = true;
      setState(() {
        widget.mediaItems.removeAt(_currentIndex);
        if (widget.mediaItems.isEmpty) {
          _popMediaPreview(shouldReloadListHint: true);
          return;
        }
        _currentIndex = nextIndex;
        _pageController.jumpToPage(_currentIndex);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.mediaItems.isNotEmpty) {
          _pageController.jumpToPage(_currentIndex);
          _autoPlayCurrentVideo();
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('移动到回收站失败: $e')));
    }
  }

  Widget _buildActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? iconColor,
    bool useIconShadow = true,
  }) {
    final color = iconColor ?? Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(22.5),
        child: Tooltip(
          message: tooltip,
          child: Container(
            width: 45,
            height: 45,
            decoration: const BoxDecoration(
              color: Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: color,
              size: 24,
              shadows: useIconShadow ? FloatingUiShadows.whiteIcon : null,
            ),
          ),
        ),
      ),
    );
  }

  void _toggleControls() {
    // 如果当前项是视频且控制器存在，则切换视频播放状态
    if (_currentIndex >= 0 &&
        _currentIndex < widget.mediaItems.length &&
        widget.mediaItems[_currentIndex].type == MediaType.video &&
        _videoControllers.containsKey(_currentIndex)) {
      final controller = _videoControllers[_currentIndex];
      if (controller != null) {
        if (controller.value.isPlaying) {
          controller.pause();
        } else {
          controller.play();
        }
      }
    }
  }

  void playManual() {
    setState(() {
      _mediaMode = MediaMode.manual;
    });
    _playCurrentMedia();
  }

  void playAuto() {
    setState(() {
      _mediaMode = MediaMode.auto;
    });
    _playCurrentMedia();
  }

  void stop() {
    setState(() {
      _mediaMode = MediaMode.none;
    });
    _mediaTimer?.cancel();
    _mediaTimer = null;
  }

  VoidCallback? _videoCompleteListener;
  int? _videoCompleteListenerIndex;

  /// 为视频添加播放完成监听（手动/非自动模式下用于循环；自动模式下用于切换下一项）
  void _addVideoCompleteListenerFor(
    VideoPlayerController controller,
    int index,
  ) {
    _removeVideoCompleteListener();
    void listener() {
      final pos = controller.value.position;
      final dur = controller.value.duration;
      if (dur > Duration.zero &&
          pos >= dur - const Duration(milliseconds: 200)) {
        _removeVideoCompleteListener();
        _onMediaComplete();
      }
    }

    _videoCompleteListener = listener;
    _videoCompleteListenerIndex = index;
    controller.addListener(listener);
  }

  Future<void> _playCurrentMedia() async {
    final currentItem = widget.mediaItems[_currentIndex];

    if (currentItem.type == MediaType.video) {
      final controller = _videoControllers[_currentIndex];
      if (controller != null && controller.value.isInitialized) {
        _removeVideoCompleteListener();
        // 自动模式从最后一页回到第一页等：控制器可能仍停在片尾，需先 seek 才能再次触发「播放完成」
        if (_mediaMode == MediaMode.auto) {
          final dur = controller.value.duration;
          final pos = controller.value.position;
          if (dur > Duration.zero &&
              pos >= dur - const Duration(milliseconds: 200)) {
            await controller.seekTo(Duration.zero);
          }
        }
        // 片头附近：轻量 seek，避免 HLS remux 卡在第一帧。
        if (controller.value.position <= const Duration(milliseconds: 1)) {
          try {
            await controller.seekTo(const Duration(milliseconds: 1));
          } catch (_) {}
        }
        await controller.play();
        _addVideoCompleteListenerFor(controller, _currentIndex);
        unawaited(_unstickFrozenFirstFrameAt(_currentIndex));
      }
    } else if (currentItem.type == MediaType.image) {
      _mediaTimer?.cancel();
      _mediaTimer = null;
      if (_mediaMode != MediaMode.auto) {
        return;
      }
      // 静态横向填满：用定时器切换；渐进放大 / 边沿巡游由组件 onAnimationComplete 切换
      if (_imageMode == MediaImageDisplayMode.fitWidth) {
        _mediaTimer = Timer(_imageDuration, _onMediaComplete);
      }
    }
  }

  void _removeVideoCompleteListener() {
    if (_videoCompleteListener != null && _videoCompleteListenerIndex != null) {
      final controller = _videoControllers[_videoCompleteListenerIndex!];
      if (controller != null) {
        controller.removeListener(_videoCompleteListener!);
      }
      _videoCompleteListener = null;
      _videoCompleteListenerIndex = null;
    }
  }

  /// 自动播放且仅一条时：当前项再播一轮（避免停在最后无下一页）。
  void _restartCurrentAutoPlayback() {
    if (_currentIndex < 0 || _currentIndex >= widget.mediaItems.length) return;
    final item = widget.mediaItems[_currentIndex];
    if (item.type == MediaType.video) {
      final controller = _videoControllers[_currentIndex];
      if (controller != null && controller.value.isInitialized) {
        _removeVideoCompleteListener();
        controller.seekTo(Duration.zero);
        controller.play();
        _addVideoCompleteListenerFor(controller, _currentIndex);
      }
    } else if (item.type == MediaType.image) {
      if (_imageMode == MediaImageDisplayMode.fitWidth &&
          !(_staticKenBurnsDemo && _staticDemoItemId == item.id)) {
        _mediaTimer?.cancel();
        _mediaTimer = Timer(_imageDuration, _onMediaComplete);
      } else {
        setState(() => _kenBurnsReplayTick++);
      }
    }
  }

  void _onMediaComplete() {
    if (_mediaMode == MediaMode.auto) {
      if (widget.mediaItems.isEmpty) return;
      if (widget.mediaItems.length == 1) {
        _restartCurrentAutoPlayback();
        return;
      }
      if (_currentIndex < widget.mediaItems.length - 1) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      } else {
        _pageController.animateToPage(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
      return;
    }
    // 手动/非自动模式：仅视频循环当前条
    final controller = _videoControllers[_currentIndex];
    if (controller != null && controller.value.isInitialized) {
      controller.seekTo(Duration.zero);
      controller.play();
      _addVideoCompleteListenerFor(controller, _currentIndex);
    }
  }
}
