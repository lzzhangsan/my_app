import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'models/video_view_params.dart';
import 'widgets/video_player_widget.dart'; // 确保正确导入 VideoPlayerWidget
import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'media_selection_dialog.dart'; // 导入媒体选择对话框
import 'models/media_item.dart'; // 添加MediaItem类的导入
import 'services/logger.dart';
import 'media_player_settings.dart';
import 'media_source_favorite_filter.dart';
import 'video_sequential_resume_prefs.dart';
import 'widgets/ken_burns_image_display.dart';
import 'widgets/zoom_pan_edge_image_display.dart';
import 'widgets/fit_width_blur_static_image.dart';
import 'widgets/image_interactive_surface.dart';
import 'widgets/image_layout_utils.dart' show ImageLetterboxFill;

enum MediaMode { none, manual, auto }

class MediaPlayerContainer extends StatefulWidget {
  const MediaPlayerContainer({
    super.key,
    this.syncForegroundObscuringBackground,
  });

  /// 与文档页背景视频联动：有浮层图/视频时为 true，关闭浮层后为 false。
  final ValueNotifier<bool>? syncForegroundObscuringBackground;

  @override
  MediaPlayerContainerState createState() => MediaPlayerContainerState();
}

class MediaPlayerContainerState extends State<MediaPlayerContainer>
    with WidgetsBindingObserver {
  MediaMode _mediaMode = MediaMode.none;
  Timer? _mediaTimer;
  List<Map<String, dynamic>> _mediaList = [];
  final Random _random = Random();
  Widget? _mediaWidget;
  VideoPlayerWidget? _currentVideoWidget; // 保存当前的VideoPlayerWidget实例
  String? _selectedDirectory;
  MediaSourceFavoriteFilter _favoriteFilter = MediaSourceFavoriteFilter.all;
  late final DatabaseService _databaseService;
  Map<String, dynamic>? _currentPlayingMedia; // 添加当前正在播放的媒体项

  Duration _imageDuration = const Duration(seconds: 5);
  MediaImageDisplayMode _imageMode = MediaImageDisplayMode.fitWidth;
  double _zoomMax = 3.0;
  MediaPlaybackOrder _playbackOrder = MediaPlaybackOrder.random;
  bool _panClockwise = true;
  double _imagePanRoamCoverage = 0.28;
  ImageLetterboxFill _letterboxFill = ImageLetterboxFill.transparent;
  int _sequentialIndex = 0;

  /// 每次成功切到下一条媒体递增，避免同一视频再次播放时 ValueKey 不变导致 onVideoEnd 永不触发。
  int _playbackNonce = 0;

  /// 防止自动模式下定时器/动画结束/视频结束在 [await] 间隙重入 [_showNextMedia]，导致顺序游标连跳两次、漏播。
  bool _showNextMediaInProgress = false;

  /// 每条成功展示的媒体递增；自动切换回调仅当 [sessionForAutoAdvance] 仍等于当前值时才执行，避免过期定时器/重复动画结束误切下一条。
  int _mediaSessionId = 0;

  String _sequentialIndexPrefsKey() {
    final d = _selectedDirectory ?? 'root';
    final f = _favoriteFilter.storageValue;
    return 'media_player_seq_idx_${Uri.encodeComponent(d)}_${Uri.encodeComponent(f)}';
  }

  Future<void> _persistSequentialIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_sequentialIndexPrefsKey(), _sequentialIndex);
    } catch (e) {
      Logger.e('保存顺序播放游标失败', e);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _databaseService = getService<DatabaseService>();
    _loadSelectedDirectory();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _flushSequentialVideoResumeProgress();
    }
  }

  /// 顺序模式下前进游标（视频在「开始播放」时不再调用，仅在片尾/跳过/错误后调用）。
  void _advanceSequentialPlaybackCursor() {
    if (_playbackOrder != MediaPlaybackOrder.sequential || _mediaList.isEmpty) {
      return;
    }
    _sequentialIndex = (_sequentialIndex + 1) % _mediaList.length;
    unawaited(_persistSequentialIndex());
  }

  void _videoResumeSnapshotSave(String id, int positionMs, int durationMs) {
    if (id.isEmpty || durationMs <= 0) return;
    if (positionMs >= durationMs - 600) {
      unawaited(_clearVideoResumeForId(id));
      return;
    }
    unawaited(_writeVideoResumeForId(id, positionMs));
  }

  Future<void> _writeVideoResumeForId(String id, int ms) async {
    final prefs = await SharedPreferences.getInstance();
    await writeVideoResumePositionMs(prefs, id, ms);
  }

  Future<void> _clearVideoResumeForId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await clearVideoResumePositionMs(prefs, id);
  }

  void _flushSequentialVideoResumeProgress() {
    if (_playbackOrder != MediaPlaybackOrder.sequential) return;
    final id = _currentPlayingMedia?['id']?.toString();
    if (id == null || id.isEmpty) return;
    final c = _currentVideoWidget?.controller;
    if (c == null || !c.value.isInitialized || c.value.duration <= Duration.zero) {
      return;
    }
    _videoResumeSnapshotSave(
      id,
      c.value.position.inMilliseconds,
      c.value.duration.inMilliseconds,
    );
  }

  Future<void> _loadSelectedDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await loadMediaPlayerSettings(prefs);
    setState(() {
      _selectedDirectory =
          prefs.getString('selected_media_directory') ?? 'root';
      _favoriteFilter = parseMediaSourceFavoriteFilter(
        prefs.getString(kMediaSourceFavoriteFilterPrefsKey),
      );
      _imageDuration = settings.imageDuration;
      _imageMode = settings.imageMode;
      _zoomMax = settings.zoomMaxScale;
      _playbackOrder = settings.playbackOrder;
      _panClockwise = settings.panClockwise;
      _imagePanRoamCoverage = settings.imagePanRoamCoverage;
      _letterboxFill = settings.letterboxFill;
      Logger.i(
        'Loaded media source: dir=$_selectedDirectory, scope=${_favoriteFilter.storageValue}',
      );
    });
    await _loadMediaList(); // 确保加载目录后立即加载媒体列表
  }

  void showMediaPlayerSettings() {
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
      ),
      onSettingsChanged: (snap) async {
        final orderChanged = snap.playbackOrder != _playbackOrder;
        setState(() {
          _imageDuration = snap.imageDuration;
          _imageMode = snap.imageMode;
          _zoomMax = snap.zoomMaxScale;
          _playbackOrder = snap.playbackOrder;
          _panClockwise = snap.panClockwise;
          _imagePanRoamCoverage = snap.imagePanRoamCoverage;
          _letterboxFill = snap.letterboxFill;
        });
        if (orderChanged) {
          await _loadMediaList();
        }
      },
    );
  }

  Future<void> _saveMediaSourceSelection(
    String directory,
    MediaSourceFavoriteFilter filter,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_media_directory', directory);
    await prefs.setString(
      kMediaSourceFavoriteFilterPrefsKey,
      filter.storageValue,
    );
    Logger.i(
      'Saved media source: directory=$directory, scope=${filter.storageValue}',
    );
  }

  Future<void> _loadMediaList({bool restartPlaybackIfActive = true}) async {
    setState(() {
      _mediaList = []; // 先清空列表，避免在加载过程中显示旧的媒体
    });

    List<Map<String, dynamic>> mediaList = await _getMediaList();

    final prefs = await SharedPreferences.getInstance();
    if (mediaList.isNotEmpty) {
      final raw = prefs.getInt(_sequentialIndexPrefsKey()) ?? 0;
      _sequentialIndex = raw % mediaList.length;
    } else {
      _sequentialIndex = 0;
    }

    if (mounted) {
      setState(() {
        _mediaList = mediaList;
        Logger.i('加载了 ${_mediaList.length} 个媒体文件');

        // 仅在调试模式下打印媒体列表详情
        for (var media in _mediaList) {
          Logger.d('媒体文件: ${media['path']}, 类型: ${media['type']}');
        }
      });
      if (_mediaList.isEmpty) {
        Logger.w(
          '目录 $_selectedDirectory、范围 ${_favoriteFilter.displayLabel} 下没有可用媒体',
        );
        setState(() {
          _mediaWidget = Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '当前来源（${_selectedDirectory == 'root' ? '整个媒体库' : '文件夹'}）下，'
                '${_favoriteFilter.displayLabel}中没有可播放的图片或视频',
                textAlign: TextAlign.center,
              ),
            ),
          );
          _currentPlayingMedia = null;
        });
      } else if (_mediaMode != MediaMode.none && restartPlaybackIfActive) {
        // 如果之前在播放，重新开始播放
        _showNextMedia();
      }
    }
  }

  Future<List<Map<String, dynamic>>> _getMediaList() async {
    try {
      await _databaseService.ensureMediaItemsTableExists();
      final List<Map<String, dynamic>> mediaFiles = [];

      Logger.i(
        _selectedDirectory == 'root'
            ? '加载整个媒体库（与媒体库网格顺序一致），范围: ${_favoriteFilter.displayLabel}'
            : '加载目录 $_selectedDirectory 下的文件（与媒体库网格顺序一致），范围: ${_favoriteFilter.displayLabel}',
      );

      final raw = await _databaseService.getMediaFilesInGridOrder(
        _selectedDirectory ?? 'root',
      );

      for (final item in raw) {
        if (_favoriteFilter == MediaSourceFavoriteFilter.favoriteOnly &&
            !mediaRowIsFavorite(item)) {
          continue;
        }
        if (_favoriteFilter == MediaSourceFavoriteFilter.notFavoriteOnly &&
            mediaRowIsFavorite(item)) {
          continue;
        }
        final mutable = Map<String, dynamic>.from(item);
        await _databaseService.tryRepairMediaItemPath(mutable);
        final String pathStr = mutable['path']?.toString() ?? '';
        if (pathStr.isEmpty) continue;
        final File file = File(pathStr);

        if (await file.exists()) {
          mediaFiles.add(mutable);
        } else {
          Logger.w('路径修复后仍不存在，从数据库移除: $pathStr');
          try {
            await _databaseService.deleteMediaItem(mutable['id']);
          } catch (e) {
            Logger.w('清理数据库记录失败: $e');
          }
        }
      }

      Logger.i('找到 ${mediaFiles.length} 个有效媒体文件');
      return mediaFiles;
    } catch (e) {
      Logger.e('获取媒体列表时出错', e);
      return [];
    }
  }

  void playCurrentMedia() {
    Logger.d('playCurrentMedia called');
    playManual();
  }

  void stopMedia() {
    Logger.d('stopMedia called');
    // 底栏长按红色播放键：视为迫不得已关掉当前图/视频，写断点（视频）且不前进游标，下次单击/双击应续播。
    stop();
  }

  void playContinuously() {
    Logger.d('playContinuously called');
    playAuto();
  }

  /// 顺序模式下：仅当**视频正在播放**时，底栏单击/双击红色键才视为「进手动/自动并切下一条」。
  /// 长按已停、暂停、或从后台回来后再点播放 → 不调用本方法，走续播同一条。
  void _sequentialToolbarPlayExplicitNextVideoIfPlaying() {
    if (_playbackOrder != MediaPlaybackOrder.sequential) return;
    final cur = _currentPlayingMedia;
    if (cur == null) return;
    if (DatabaseService.mediaTypeIndex(cur) != 1) return;
    final c = _currentVideoWidget?.controller;
    if (c == null || !c.value.isInitialized) return;
    if (!c.value.isPlaying) return;
    final id = cur['id']?.toString();
    if (id != null && id.isNotEmpty) {
      unawaited(_clearVideoResumeForId(id));
    }
    _advanceSequentialPlaybackCursor();
  }

  void playManual() {
    _sequentialToolbarPlayExplicitNextVideoIfPlaying();
    setState(() {
      _mediaMode = MediaMode.manual;
    });
    _showNextMedia();
  }

  void playAuto() {
    _sequentialToolbarPlayExplicitNextVideoIfPlaying();
    setState(() {
      _mediaMode = MediaMode.auto;
    });
    _showNextMedia();
  }

  void stop() {
    _flushSequentialVideoResumeProgress();
    setState(() {
      _mediaMode = MediaMode.none;
      _mediaWidget = null;
      _currentVideoWidget = null;
      _currentPlayingMedia = null; // 清除当前播放媒体
      _mediaTimer?.cancel();
      _mediaTimer = null;
    });
  }

  Future<MediaItem?> getCurrentMedia() async {
    if (_currentPlayingMedia == null) return null;
    return MediaItem.fromMap(Map<String, dynamic>.from(_currentPlayingMedia!));
  }

  void pausePlaybackForExternalPreview() {
    _flushSequentialVideoResumeProgress();
    _mediaTimer?.cancel();
    _mediaTimer = null;
    _currentVideoWidget?.controller?.pause();
  }

  Future<void> reloadCurrentMediaFromDatabase() async {
    if (_currentPlayingMedia == null) return;
    final currentId = _currentPlayingMedia!['id']?.toString();
    if (currentId == null || currentId.isEmpty) return;

    final refreshed = await _databaseService.getMediaItemById(currentId);
    if (refreshed == null) {
      if (!mounted) return;
      stop();
      return;
    }

    final refreshedMap = Map<String, dynamic>.from(refreshed);
    await _databaseService.tryRepairMediaItemPath(refreshedMap);
    final mediaIndex = _mediaList.indexWhere(
      (media) => media['id']?.toString() == currentId,
    );
    if (mediaIndex < 0) return;

    final pathStr = refreshedMap['path']?.toString() ?? '';
    if (pathStr.isEmpty || !await File(pathStr).exists()) {
      if (!mounted) return;
      stop();
      return;
    }

    _mediaList[mediaIndex] = refreshedMap;
    _currentPlayingMedia = refreshedMap;
    _playbackNonce++;

    final int typeIdx = DatabaseService.mediaTypeIndex(refreshedMap);
    final mediaFile = File(pathStr);

    if (!mounted) return;
    if (typeIdx == 0) {
      final sideways =
          VideoViewParams.fromMediaMap(refreshedMap).quarterTurns % 2 == 1;
      setState(() {
        _currentVideoWidget = null;
        if (_imageMode == MediaImageDisplayMode.kenBurns) {
          _mediaWidget = _wrapImageWithStoredView(
            _buildKenBurnsForPlaying(refreshedMap, mediaFile, _mediaSessionId),
            refreshedMap,
          );
        } else if (_imageMode == MediaImageDisplayMode.zoomPanEdge) {
          _mediaWidget = _wrapImageWithStoredView(
            ZoomPanEdgeImageDisplay(
              key: ValueKey(
                '${refreshedMap['path']}_zpan_$_mediaMode'
                '_${_imagePanRoamCoverage.toStringAsFixed(2)}'
                '_${_letterboxFill.index}'
                '_rot${VideoViewParams.fromMediaMap(refreshedMap).quarterTurns % 4}'
                '_n$_playbackNonce',
              ),
              imageFile: mediaFile,
              totalDuration: _imageDuration,
              maxScale: _zoomMax,
              clockwise: _panClockwise,
              panPathCoverage: _imagePanRoamCoverage,
              letterboxFill: _letterboxFill,
              fitContainInViewport: sideways,
              loop: _mediaMode == MediaMode.manual,
              onAnimationComplete: null,
            ),
            refreshedMap,
          );
        } else {
          _mediaWidget = _wrapImageWithStoredView(
            FitWidthBlurStaticImage(
              key: ValueKey(
                'fw_${refreshedMap['path']}_rot${VideoViewParams.fromMediaMap(refreshedMap).quarterTurns % 4}_n$_playbackNonce',
              ),
              file: mediaFile,
              letterboxFill: _letterboxFill,
              fitContainInViewport: sideways,
              zoomCenterX:
                  (refreshedMap['ken_burns_center_x'] as num?)?.toDouble(),
              zoomCenterY:
                  (refreshedMap['ken_burns_center_y'] as num?)?.toDouble(),
            ),
            refreshedMap,
          );
        }
      });
      return;
    }

    if (typeIdx == 1) {
      final bool sequential =
          _playbackOrder == MediaPlaybackOrder.sequential;
      final String vid = currentId;
      Duration? initialSeek;
      var seqResumeActive = false;
      if (sequential && vid.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final saved = await readVideoResumePositionMs(prefs, vid);
        if (saved != null && saved > 0) {
          initialSeek = Duration(milliseconds: max(0, saved - 5000));
          seqResumeActive = true;
        }
      }
      final int reloadVideoSession = _mediaSessionId;
      if (!mounted) return;
      setState(() {
        _currentVideoWidget = VideoPlayerWidget(
          key: ValueKey('vp_${refreshedMap['path']}_$_playbackNonce'),
          file: mediaFile,
          viewParams: VideoViewParams.fromMediaMap(refreshedMap),
          initialSeekPosition: initialSeek,
          sequentialResumeActive: seqResumeActive,
          onSequentialResumeTooShort:
              seqResumeActive
                  ? () {
                    if (!mounted) return;
                    unawaited(_clearVideoResumeForId(vid));
                    _advanceSequentialPlaybackCursor();
                    unawaited(_showNextMedia());
                  }
                  : null,
          onProgressForResumeSave:
              sequential && vid.isNotEmpty
                  ? (pos, dur) => _videoResumeSnapshotSave(vid, pos, dur)
                  : null,
          onVideoEnd: () {
            if (_mediaSessionId != reloadVideoSession) return;
            if (vid.isNotEmpty && sequential) {
              unawaited(_clearVideoResumeForId(vid));
            }
            if (sequential) {
              _advanceSequentialPlaybackCursor();
            }
            if (_mediaMode != MediaMode.auto) return;
            unawaited(_showNextMedia());
          },
          onVideoError:
              _mediaMode == MediaMode.auto
                  ? () {
                    if (_mediaSessionId != reloadVideoSession) return;
                    if (sequential) {
                      _advanceSequentialPlaybackCursor();
                    }
                    unawaited(_showNextMedia());
                  }
                  : null,
          looping: false,
          forceManualLoop: _mediaMode == MediaMode.manual,
        );
        _mediaWidget = _currentVideoWidget;
      });
    }
  }

  // 获取当前的VideoPlayerWidget实例
  VideoPlayerWidget? getCurrentVideoWidget() {
    return _currentVideoWidget;
  }

  String _kenBurnsWidgetKey(Map<String, dynamic> nextMedia) {
    // 含 _playbackNonce：再次轮到同一张图时 Key 必须变化，否则会复用 State、动画不重启，自动模式无法切下一条。
    final rot = VideoViewParams.fromMediaMap(nextMedia).quarterTurns % 4;
    return '${nextMedia['path']}_ken_$_mediaMode'
        '_${_letterboxFill.index}'
        '_${(nextMedia['ken_burns_center_x'] as num?)?.toStringAsFixed(3) ?? 'c'}'
        '_${(nextMedia['ken_burns_center_y'] as num?)?.toStringAsFixed(3) ?? 'c'}'
        '_rot$rot'
        '_n$_playbackNonce';
  }

  /// 与 [VideoPlayerWidget] 一致：套用媒体页已保存的缩放/平移/旋转（只读）。
  Widget _wrapImageWithStoredView(Widget child, Map<String, dynamic> mediaMap) {
    final p = VideoViewParams.fromMediaMap(mediaMap);
    final id = mediaMap['id'];
    return ImageInteractiveSurface(
      key: ValueKey('img_doc_${id}_${p.hashCode}'),
      initial: p,
      editable: false,
      useScreenSizeForNormalization: false,
      readonlyTranslateYOffset: 0,
      child: child,
    );
  }

  Widget _buildKenBurnsForPlaying(
    Map<String, dynamic> nextMedia,
    File mediaFile,
    int sessionForAutoAdvance,
  ) {
    final sideways =
        VideoViewParams.fromMediaMap(nextMedia).quarterTurns % 2 == 1;
    return KenBurnsImageDisplay(
      key: ValueKey(_kenBurnsWidgetKey(nextMedia)),
      imageFile: mediaFile,
      animationDuration: _imageDuration,
      maxScale: _zoomMax,
      letterboxFill: _letterboxFill,
      fitContainInViewport: sideways,
      zoomCenterX: (nextMedia['ken_burns_center_x'] as num?)?.toDouble(),
      zoomCenterY: (nextMedia['ken_burns_center_y'] as num?)?.toDouble(),
      enableDoubleTapToSetZoomCenter: false,
      onZoomCenterSet: null,
      loop: _mediaMode == MediaMode.manual,
      onAnimationComplete:
          _mediaMode == MediaMode.auto
              ? () {
                if (_mediaMode != MediaMode.auto) return;
                if (sessionForAutoAdvance != _mediaSessionId) return;
                unawaited(_showNextMedia());
              }
              : null,
    );
  }

  Future<void> _removeMediaAtIndexAsync(
    int mediaIndex, {
    required bool deleteFromDb,
  }) async {
    if (mediaIndex < 0 || mediaIndex >= _mediaList.length) return;
    final id = _mediaList[mediaIndex]['id'];
    if (deleteFromDb && id != null) {
      try {
        await _databaseService.deleteMediaItem(id);
      } catch (e) {
        Logger.w('删除媒体库记录失败: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _mediaList.removeAt(mediaIndex);
    });
    _adjustSequentialAfterRemove(removedIndex: mediaIndex);
  }

  void _adjustSequentialAfterRemove({required int removedIndex}) {
    if (_playbackOrder != MediaPlaybackOrder.sequential) return;
    if (_mediaList.isEmpty) {
      _sequentialIndex = 0;
      unawaited(_persistSequentialIndex());
      return;
    }
    if (removedIndex < _sequentialIndex) {
      _sequentialIndex--;
    }
    _sequentialIndex %= _mediaList.length;
    unawaited(_persistSequentialIndex());
  }

  Future<void> _showNextMedia() async {
    if (_mediaList.isEmpty) {
      setState(() {
        _mediaWidget = Center(child: Text('没有可用的媒体文件'));
        _currentPlayingMedia = null; // 重置当前媒体
      });
      return;
    }

    if (_showNextMediaInProgress) {
      return;
    }
    _showNextMediaInProgress = true;

    try {
      int attempt = 0;
      const int maxAttempts = 48;
      while (_mediaList.isNotEmpty && attempt < maxAttempts) {
        attempt++;
        if (_mediaList.isEmpty) {
          setState(() {
            _mediaWidget = Center(child: Text('没有可用的媒体文件'));
            _currentPlayingMedia = null;
          });
          return;
        }

        final int mediaIndex =
            _playbackOrder == MediaPlaybackOrder.random
                ? _random.nextInt(_mediaList.length)
                : _sequentialIndex % _mediaList.length;
        final Map<String, dynamic> nextMedia = _mediaList[mediaIndex];

        await _databaseService.tryRepairMediaItemPath(nextMedia);

        // 先验证文件是否存在（与媒体管理页相同的路径修复已尝试）
        final String path = nextMedia['path']?.toString() ?? '';
        final File file = File(path);

        if (!await file.exists()) {
          Logger.w('选择的文件不存在，从列表中移除: $path');
          await _removeMediaAtIndexAsync(mediaIndex, deleteFromDb: true);
          continue;
        }

        // 文件存在，设置为当前播放媒体
        _currentPlayingMedia = nextMedia;
        File? mediaFile = await _getFileFromMediaItem(nextMedia);

        if (mediaFile == null) {
          Logger.w('无法访问媒体文件: $path');
          await _removeMediaAtIndexAsync(mediaIndex, deleteFromDb: false);
          continue;
        }

        // 每条成功展示的媒体都递增，使图片/视频 Key 在每一轮循环中唯一，避免同一路径复用组件导致无法无限轮播。
        _playbackNonce++;
        _mediaSessionId++;
        final int sessionThisMedia = _mediaSessionId;

        // 成功获取到文件，显示相应媒体
        final int typeIdx = DatabaseService.mediaTypeIndex(nextMedia);
        if (typeIdx == 0) {
          _advanceSequentialPlaybackCursor();
          // 图片
          if (_imageMode == MediaImageDisplayMode.kenBurns) {
            setState(() {
              _mediaWidget = _wrapImageWithStoredView(
                _buildKenBurnsForPlaying(
                  nextMedia,
                  mediaFile,
                  sessionThisMedia,
                ),
                nextMedia,
              );
            });
          } else if (_imageMode == MediaImageDisplayMode.zoomPanEdge) {
            final sideways =
                VideoViewParams.fromMediaMap(nextMedia).quarterTurns % 2 == 1;
            setState(() {
              _mediaWidget = _wrapImageWithStoredView(
                ZoomPanEdgeImageDisplay(
                  key: ValueKey(
                    '${nextMedia['path']}_zpan_$_mediaMode'
                    '_${_imagePanRoamCoverage.toStringAsFixed(2)}'
                    '_${_letterboxFill.index}'
                    '_rot${VideoViewParams.fromMediaMap(nextMedia).quarterTurns % 4}'
                    '_n$_playbackNonce',
                  ),
                  imageFile: mediaFile,
                  totalDuration: _imageDuration,
                  maxScale: _zoomMax,
                  clockwise: _panClockwise,
                  panPathCoverage: _imagePanRoamCoverage,
                  letterboxFill: _letterboxFill,
                  fitContainInViewport: sideways,
                  loop: _mediaMode == MediaMode.manual,
                  onAnimationComplete:
                      _mediaMode == MediaMode.auto
                          ? () {
                            if (_mediaMode != MediaMode.auto) return;
                            if (sessionThisMedia != _mediaSessionId) return;
                            unawaited(_showNextMedia());
                          }
                          : null,
                ),
                nextMedia,
              );
            });
          } else {
            final sideways =
                VideoViewParams.fromMediaMap(nextMedia).quarterTurns % 2 == 1;
            setState(() {
              _mediaWidget = _wrapImageWithStoredView(
                FitWidthBlurStaticImage(
                  key: ValueKey(
                    'fw_${nextMedia['path']}_rot${VideoViewParams.fromMediaMap(nextMedia).quarterTurns % 4}_n$_playbackNonce',
                  ),
                  file: mediaFile,
                  letterboxFill: _letterboxFill,
                  fitContainInViewport: sideways,
                  zoomCenterX:
                      (nextMedia['ken_burns_center_x'] as num?)?.toDouble(),
                  zoomCenterY:
                      (nextMedia['ken_burns_center_y'] as num?)?.toDouble(),
                ),
                nextMedia,
              );
            });

            if (_mediaMode == MediaMode.auto) {
              _mediaTimer?.cancel();
              final int scheduleSession = sessionThisMedia;
              _mediaTimer = Timer(_imageDuration, () {
                if (_mediaMode != MediaMode.auto) return;
                if (scheduleSession != _mediaSessionId) return;
                unawaited(_showNextMedia());
              });
            }
          }

          return;
        } else if (typeIdx == 1) {
          final bool sequential =
              _playbackOrder == MediaPlaybackOrder.sequential;
          if (!sequential) {
            _advanceSequentialPlaybackCursor();
          }
          final String vid = nextMedia['id']?.toString() ?? '';
          Duration? initialSeek;
          var seqResumeActive = false;
          if (sequential && vid.isNotEmpty) {
            final prefs = await SharedPreferences.getInstance();
            final saved = await readVideoResumePositionMs(prefs, vid);
            if (saved != null && saved > 0) {
              initialSeek = Duration(
                milliseconds: max(0, saved - 5000),
              );
              seqResumeActive = true;
            }
          }
          if (!mounted) return;
          setState(() {
            _currentVideoWidget = VideoPlayerWidget(
              key: ValueKey('vp_${nextMedia['path']}_$_playbackNonce'),
              file: File(nextMedia['path']!),
              viewParams: VideoViewParams.fromMediaMap(nextMedia),
              initialSeekPosition: initialSeek,
              sequentialResumeActive: seqResumeActive,
              onSequentialResumeTooShort:
                  seqResumeActive
                      ? () {
                        if (!mounted) return;
                        unawaited(_clearVideoResumeForId(vid));
                        _advanceSequentialPlaybackCursor();
                        unawaited(_showNextMedia());
                      }
                      : null,
              onProgressForResumeSave:
                  sequential && vid.isNotEmpty
                      ? (pos, dur) => _videoResumeSnapshotSave(vid, pos, dur)
                      : null,
              onVideoEnd: () {
                if (sessionThisMedia != _mediaSessionId) return;
                if (vid.isNotEmpty && sequential) {
                  unawaited(_clearVideoResumeForId(vid));
                }
                if (sequential) {
                  _advanceSequentialPlaybackCursor();
                }
                if (_mediaMode != MediaMode.auto) return;
                unawaited(_showNextMedia());
              },
              onVideoError:
                  _mediaMode == MediaMode.auto
                      ? () {
                        Logger.w('视频解码/播放失败，自动尝试下一条');
                        if (sessionThisMedia != _mediaSessionId) return;
                        if (sequential) {
                          _advanceSequentialPlaybackCursor();
                        }
                        unawaited(_showNextMedia());
                      }
                      : null,
              looping: false,
              forceManualLoop: _mediaMode == MediaMode.manual,
            );
            _mediaWidget = _currentVideoWidget;
          });

          return;
        }

        Logger.w('不支持的媒体类型: ${nextMedia['type']}');
        continue;
      }

      // 如果尝试多次后仍未成功，显示错误信息
      setState(() {
        _mediaWidget = Center(child: Text('无法加载媒体文件，请检查媒体库'));
        _currentPlayingMedia = null;
      });
    } catch (e) {
      Logger.e('显示媒体时出错', e);
      setState(() {
        _mediaWidget = Center(child: Text('加载媒体时出错'));
        _mediaTimer?.cancel();
        _currentPlayingMedia = null; // 出错时重置当前媒体
      });
    } finally {
      _showNextMediaInProgress = false;
    }
  }

  Future<File?> _getFileFromMediaItem(Map<String, dynamic> mediaItem) async {
    try {
      await _databaseService.tryRepairMediaItemPath(mediaItem);
      String path = mediaItem['path']?.toString() ?? '';
      if (path.isEmpty) return null;
      File file = File(path);

      if (await file.exists()) {
        try {
          // 尝试简单读取操作验证文件可读
          await file.openRead(0, 1).first;
          return file;
        } catch (readError) {
          Logger.w('文件读取权限问题: $readError');

          try {
            // 试图创建一个临时副本来访问只读文件
            return await _ensureFileAccessible(path);
          } catch (copyError) {
            Logger.w('无法创建临时副本: $copyError');
            return null;
          }
        }
      }

      Logger.w('文件不存在: $path');
      return null;
    } catch (e) {
      Logger.e('获取媒体文件时出错', e);
      return null;
    }
  }

  void selectMediaSource() {
    Logger.d('selectMediaSource called!');
    _showMediaSourceSelectionDialog();
  }

  void _showMediaSourceSelectionDialog() {
    Logger.d('Showing media source selection dialog');
    showDialog(
      context: context,
      barrierDismissible: true, // 允许点击外部关闭对话框
      builder:
          (BuildContext dialogContext) => MediaSelectionDialog(
            selectedDirectory: _selectedDirectory, // 传入当前选中的目录
            onDirectorySelected: (directory) async {
              Navigator.of(dialogContext).pop();
              if (!mounted) return;

              final scope = await _showFavoriteScopeDialog();
              if (!mounted || scope == null) return;

              final changed =
                  directory != _selectedDirectory || scope != _favoriteFilter;
              if (!changed) return;

              setState(() {
                _selectedDirectory = directory;
                _favoriteFilter = scope;
                _currentPlayingMedia = null;
                _mediaWidget = null;
                _currentVideoWidget = null;
                _mediaMode = MediaMode.none;
                _mediaTimer?.cancel();
              });

              await _saveMediaSourceSelection(directory, scope);
              await _loadMediaList();
              Logger.i(
                '已选择媒体来源: $directory，范围: ${scope.displayLabel}',
              );
            },
          ),
    ).then((_) {
      Logger.d('Dialog closed');
    });
  }

  /// 选定目录/整个媒体库后，再选「全部 / 已收藏 / 未收藏」。
  Future<MediaSourceFavoriteFilter?> _showFavoriteScopeDialog() {
    return showDialog<MediaSourceFavoriteFilter>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('选择媒体范围'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: const Icon(Icons.perm_media_outlined),
                  title: Text(MediaSourceFavoriteFilter.all.displayLabel),
                  subtitle: const Text('包含当前来源下全部图片与视频'),
                  onTap:
                      () => Navigator.of(ctx).pop(
                        MediaSourceFavoriteFilter.all,
                      ),
                ),
                ListTile(
                  leading: Icon(
                    Icons.favorite,
                    color: Colors.pink.withValues(alpha: 0.85),
                  ),
                  title: Text(
                    MediaSourceFavoriteFilter.favoriteOnly.displayLabel,
                  ),
                  subtitle: const Text('仅播放或展示已星标收藏的项'),
                  onTap:
                      () => Navigator.of(ctx).pop(
                        MediaSourceFavoriteFilter.favoriteOnly,
                      ),
                ),
                ListTile(
                  leading: const Icon(Icons.favorite_border),
                  title: Text(
                    MediaSourceFavoriteFilter.notFavoriteOnly.displayLabel,
                  ),
                  subtitle: const Text('排除已星标收藏的项'),
                  onTap:
                      () => Navigator.of(ctx).pop(
                        MediaSourceFavoriteFilter.notFavoriteOnly,
                      ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushSequentialVideoResumeProgress();
    _mediaTimer?.cancel();
    super.dispose();
  }

  // 新增方法: 移动当前媒体到指定目录
  Future<bool> moveCurrentMedia(BuildContext context) async {
    if (_currentPlayingMedia == null) {
      _showMessage(context, '没有正在播放的媒体文件');
      return false;
    }

    try {
      // 显示移动对话框
      final List<Map<String, dynamic>> availableFolders =
          await _getAllAvailableFolders();

      if (!context.mounted) return false;

      final String? targetDirectory = await showDialog<String>(
        context: context,
        builder:
            (context) => AlertDialog(
              backgroundColor: Colors.white.withAlpha(
                (0.6 * 255).round(),
              ), // 增加透明度（使用 withAlpha 以避免弃用警告）
              title: Container(
                padding: EdgeInsets.zero,
                height: 30,
                child: const Text('移动到', style: TextStyle(fontSize: 14)),
              ),
              titlePadding: const EdgeInsets.only(left: 12, top: 8, bottom: 0),
              contentPadding: const EdgeInsets.symmetric(
                vertical: 4,
                horizontal: 8,
              ),
              content: SizedBox(
                width: MediaQuery.of(context).size.width * 0.9, // 加宽面板
                height: MediaQuery.of(context).size.height * 0.7, // 加高面板
                child: Wrap(
                  spacing: 4, // 水平间距
                  runSpacing: 2, // 垂直间距
                  children: [
                    // 根目录选项
                    SizedBox(
                      width:
                          (MediaQuery.of(context).size.width * 0.9 - 20) /
                          2, // 计算每个项的宽度
                      height: 32, // 固定高度
                      child: ListTile(
                        dense: true,
                        visualDensity: VisualDensity(
                          horizontal: 0,
                          vertical: -4,
                        ), // 进一步压缩
                        contentPadding: EdgeInsets.symmetric(horizontal: 4),
                        title: const Text(
                          '根目录',
                          style: TextStyle(fontSize: 13),
                        ),
                        onTap: () => Navigator.of(context).pop('root'),
                      ),
                    ),
                    // 其他文件夹选项
                    ...availableFolders.map((folder) {
                      return SizedBox(
                        width:
                            (MediaQuery.of(context).size.width * 0.9 - 20) /
                            2, // 计算每个项的宽度
                        height: 32, // 固定高度
                        child: ListTile(
                          dense: true,
                          visualDensity: VisualDensity(
                            horizontal: 0,
                            vertical: -4,
                          ), // 进一步压缩
                          contentPadding: EdgeInsets.symmetric(horizontal: 4),
                          title: Text(
                            folder['name'],
                            style: const TextStyle(fontSize: 13),
                          ),
                          onTap: () => Navigator.of(context).pop(folder['id']),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('取消', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
      );

      if (targetDirectory == null) return false;

      // 检查目标是否与当前目录相同
      if (_currentPlayingMedia!['directory'] == targetDirectory) {
        if (context.mounted) {
          _showMessage(context, '媒体文件已在所选目录中');
        }
        return false;
      }

      // 获取当前媒体信息的完整副本和索引
      final currentMedia = Map<String, dynamic>.from(_currentPlayingMedia!);
      final int currentIndex = _mediaList.indexWhere(
        (media) => media['id'] == currentMedia['id'],
      );

      // 如果是只读文件，我们仍然可以更新数据库记录，但不能移动实际文件
      try {
        // 获取文件信息
        final File file = File(currentMedia['path']);
        if (await file.exists()) {
          // 检查文件是否可写（我们这里只是检测数据库记录）
          // 对于只读文件，我们只更新数据库记录
          Logger.i('文件存在: ${currentMedia['path']}，更新数据库记录');
        }
      } catch (fileError) {
        Logger.w('检查文件时出错: $fileError');
        // 我们仍然可以继续更新数据库记录
      }

      // 更新数据库记录
      await _databaseService.updateMediaItem({
        'id': currentMedia['id'],
        'name': currentMedia['name'],
        'path': currentMedia['path'],
        'type': currentMedia['type'],
        'directory': targetDirectory,
        'date_added':
            currentMedia['date_added'] ?? DateTime.now().millisecondsSinceEpoch,
      });

      // 立即从当前列表中移除该媒体
      if (currentIndex != -1) {
        setState(() {
          _mediaList.removeAt(currentIndex);
        });
        _adjustSequentialAfterRemove(removedIndex: currentIndex);
      }

      if (!context.mounted) return false;

      // 如果列表为空，停止播放
      if (_mediaList.isEmpty) {
        stop();
        return true;
      }

      // 如果删除的是当前播放的媒体，立即播放下一个
      if (_currentPlayingMedia != null &&
          _currentPlayingMedia!['id'] == currentMedia['id']) {
        _showNextMedia();
      }

      return true;
    } catch (e) {
      Logger.e('移动媒体文件时出错', e);
      if (context.mounted) {
        _showMessage(context, '移动媒体文件时出错: $e');
      }
      return false;
    }
  }

  // 获取所有可用的文件夹
  Future<List<Map<String, dynamic>>> _getAllAvailableFolders() async {
    try {
      final db = await _databaseService.database;

      // 获取所有文件夹
      final List<Map<String, dynamic>> allFolders = await db.query(
        'media_items',
        where: 'type = ?',
        whereArgs: [3], // 文件夹类型
      );

      return allFolders;
    } catch (e) {
      Logger.e('获取可用文件夹时出错', e);
      return [];
    }
  }

  // 辅助方法：处理文件读取权限问题并提供解决方案
  Future<File> _ensureFileAccessible(String filePath) async {
    final originalFile = File(filePath);

    try {
      // 仅读取前 8KB 检查权限，避免大文件 OOM
      await originalFile.openRead(0, 8192).first;
      return originalFile; // 如果能读取，直接返回原始文件
    } catch (e) {
      Logger.w('文件访问出错，创建临时副本: $e');

      // 创建临时文件副本（流式复制，避免大文件 OOM）
      final tempDir = await getTemporaryDirectory();
      final String fileName = path.basename(filePath);
      final String tempPath = '${tempDir.path}/$fileName';

      final tempFile = File(tempPath);

      try {
        await originalFile.openRead().pipe(tempFile.openWrite());
        return tempFile;
      } catch (copyError) {
        Logger.w('创建临时副本失败: $copyError');
        throw Exception('无法访问文件: $filePath，原因: $copyError');
      }
    }
  }

  // 新增方法: 导出当前媒体
  Future<bool> exportCurrentMedia(BuildContext context) async {
    if (_currentPlayingMedia == null) {
      _showMessage(context, '没有正在播放的媒体文件');
      return false;
    }

    try {
      // 获取文件路径
      final String filePath = _currentPlayingMedia!['path'];

      // 创建文件对象
      final File originalFile = File(filePath);

      if (!await originalFile.exists()) {
        _showMessage(context, '文件不存在: $filePath');
        return false;
      }

      // 确保文件可访问，可能需要创建临时副本
      File fileToShare = originalFile;
      bool needsCleanup = false;

      try {
        // 尝试直接分享原始文件
        await Share.shareXFiles([
          XFile(filePath),
        ], subject: '分享: ${_currentPlayingMedia!['name']}');
      } catch (shareError) {
        Logger.w('直接分享文件失败，尝试创建临时副本: $shareError');

        try {
          // 确保文件可访问
          fileToShare = await _ensureFileAccessible(filePath);
          needsCleanup = fileToShare.path != filePath;

          // 使用临时文件分享
          await Share.shareXFiles([
            XFile(fileToShare.path),
          ], subject: '分享: ${_currentPlayingMedia!['name']}');
        } catch (accessError) {
          Logger.w('文件访问错误: $accessError');
          // 分享失败时清理临时文件，避免堆积
          if (needsCleanup && fileToShare.path != filePath) {
            try {
              await fileToShare.delete();
            } catch (_) {}
          }
          if (!context.mounted) return false;
          _showMessage(context, '无法访问文件，导出失败');
          return false;
        }
      }

      // 如果使用了临时文件，在分享后清理
      if (needsCleanup) {
        try {
          await fileToShare.delete();
        } catch (e) {
          Logger.w('清理临时文件失败: $e');
          // 这不是关键错误，可以忽略
        }
      }

      if (!context.mounted) return false;
      return true;
    } catch (e) {
      Logger.e('导出媒体文件时出错', e);
      if (context.mounted) {
        _showMessage(context, '导出媒体文件时出错: $e');
      }
      return false;
    }
  }

  // 新增方法: 删除当前媒体 (无确认对话框直接删除)
  Future<bool> deleteCurrentMedia(BuildContext context) async {
    if (_currentPlayingMedia == null) {
      _showMessage(context, '没有正在播放的媒体文件');
      return false;
    }

    try {
      // 获取完整的媒体信息
      final String mediaId = _currentPlayingMedia!['id'];
      final String mediaName = _currentPlayingMedia!['name'];
      final String mediaPath = _currentPlayingMedia!['path'];
      final int currentIndex = _mediaList.indexWhere(
        (media) => media['id'] == mediaId,
      );

      // 先删除数据库记录
      await _databaseService.deleteMediaItem(mediaId);

      // 尝试删除文件
      try {
        final File file = File(mediaPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (fileError) {
        // 文件可能是只读的，但数据库项已经删除，所以我们继续
        Logger.w('删除媒体文件时出错 (仅文件删除失败): $fileError');
        // 如果我们无法删除文件，这可能是因为文件在系统位置或只读位置，但数据库记录已经删除
      }

      // 立即从当前列表中移除该媒体
      if (currentIndex != -1) {
        setState(() {
          _mediaList.removeAt(currentIndex);
        });
        _adjustSequentialAfterRemove(removedIndex: currentIndex);
      }

      if (!context.mounted) return false;

      // 如果列表为空，停止播放
      if (_mediaList.isEmpty) {
        stop();
        return true;
      }

      // 如果删除的是当前播放的媒体，立即播放下一个
      if (_currentPlayingMedia != null &&
          _currentPlayingMedia!['id'] == mediaId) {
        _showNextMedia();
      }

      return true;
    } catch (e) {
      Logger.e('删除媒体文件时出错', e);
      if (context.mounted) {
        _showMessage(context, '删除媒体文件时出错: $e');
      }
      return false;
    }
  }

  /// 从当前列表中移除当前播放的媒体并切换到下一个。
  /// 用于文档编辑界面等场景：外部已更新数据库（如移动到回收站/收藏夹）后，
  /// 需要从展示列表中移除该项并自动播放下一个，与媒体页面的删除/收藏/移动行为一致。
  void removeCurrentAndPlayNext() {
    if (_currentPlayingMedia == null) return;
    final String currentId = _currentPlayingMedia!['id']?.toString() ?? '';
    if (currentId.isNotEmpty) {
      unawaited(_clearVideoResumeForId(currentId));
    }
    final int currentIndex = _mediaList.indexWhere(
      (media) => media['id'] == currentId,
    );
    if (currentIndex == -1) return;

    setState(() {
      _mediaList.removeAt(currentIndex);
    });
    _adjustSequentialAfterRemove(removedIndex: currentIndex);

    if (_mediaList.isEmpty) {
      stop();
      return;
    }

    _showNextMedia();
  }

  // 辅助方法：显示消息
  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // 新增方法：刷新媒体列表
  Future<void> refreshMediaList() async {
    Logger.d('刷新媒体列表...');
    await _loadMediaList();
  }

  /// 标星/排序后刷新列表，但不打断当前正在展示的媒体。
  Future<void> refreshMediaListPreservingCurrent() async {
    final currentId = _currentPlayingMedia?['id']?.toString();
    final wasActive = _mediaMode != MediaMode.none;
    await _loadMediaList(restartPlaybackIfActive: false);
    if (!mounted) return;
    if (!wasActive || currentId == null || currentId.isEmpty) return;
    final idx = _mediaList.indexWhere((m) => m['id']?.toString() == currentId);
    if (idx < 0) {
      stop();
      return;
    }
    _currentPlayingMedia = Map<String, dynamic>.from(_mediaList[idx]);
    await reloadCurrentMediaFromDatabase();
  }

  /// 收藏/标星后自动播放下一条。
  ///
  /// **顺序模式**：与媒体预览页一致——在**刷新前的播放列表**上取 `(当前下标 + 1) % 长度`（循环到首条），
  /// 再在刷新数据库、顺序重排后按 **id** 定位该条播放；这样既避免用「新列表里的下标+1」误跳，
  /// 又与预览里 `jumpToPage((from + 1) % n)` 的「下一条」定义相同。
  ///
  /// **随机模式**：刷新列表后仍按原有随机逻辑切下一条。
  Future<void> refreshMediaListAndAdvanceToNext() async {
    final currentId = _currentPlayingMedia?['id']?.toString();
    final wasActive = _mediaMode != MediaMode.none;
    if (!wasActive || currentId == null || currentId.isEmpty) return;

    String? successorId;
    if (_playbackOrder == MediaPlaybackOrder.sequential &&
        _mediaList.isNotEmpty) {
      final oldIds =
          _mediaList
              .map((m) => m['id']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList();
      final curIdx = oldIds.indexOf(currentId);
      // 与 media_preview_page：`(from + 1) % n`，含末项回到第一项。
      if (curIdx >= 0 && oldIds.length > 1) {
        successorId = oldIds[(curIdx + 1) % oldIds.length];
      }
    }

    await _loadMediaList(restartPlaybackIfActive: false);
    if (!mounted) return;
    if (_mediaList.isEmpty) {
      stop();
      return;
    }

    if (_playbackOrder == MediaPlaybackOrder.sequential) {
      if (successorId != null) {
        final nextIdx = _mediaList.indexWhere(
          (m) => m['id']?.toString() == successorId,
        );
        if (nextIdx >= 0) {
          _sequentialIndex = nextIdx;
          await _persistSequentialIndex();
          await _showNextMedia();
          return;
        }
      }
      // 仅一条、找不到目标 id 等：只刷新当前条与游标。
      final idx = _mediaList.indexWhere((m) => m['id']?.toString() == currentId);
      if (idx < 0) {
        stop();
        return;
      }
      _sequentialIndex = idx;
      await _persistSequentialIndex();
      _currentPlayingMedia = Map<String, dynamic>.from(_mediaList[idx]);
      await reloadCurrentMediaFromDatabase();
      return;
    }

    // 随机模式
    final idx = _mediaList.indexWhere((m) => m['id']?.toString() == currentId);
    if (idx < 0) {
      stop();
      return;
    }
    if (_mediaList.length == 1) {
      _currentPlayingMedia = Map<String, dynamic>.from(_mediaList[0]);
      await reloadCurrentMediaFromDatabase();
      return;
    }
    await _showNextMedia();
  }

  @override
  Widget build(BuildContext context) {
    final sync = widget.syncForegroundObscuringBackground;
    if (sync != null) {
      final obscuring = _mediaMode != MediaMode.none && _mediaWidget != null;
      if (sync.value != obscuring) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final o = _mediaMode != MediaMode.none && _mediaWidget != null;
          if (sync.value != o) {
            sync.value = o;
          }
        });
      }
    }
    return _mediaWidget != null
        ? SizedBox.expand(child: _mediaWidget!)
        : Container();
  }
}
