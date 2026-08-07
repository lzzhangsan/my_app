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
import 'services/browser_session_preview.dart';
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
import 'widgets/move_to_folder_sheet.dart';
import 'widgets/image_layout_utils.dart'
    show
        ImageLetterboxFill,
        containDisplaySize,
        fitWidthDisplaySize,
        measureImageFileSize;

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
  bool _foregroundVideoMuted = false;
  int _sequentialIndex = 0;

  /// 每次成功切到下一条媒体递增，避免同一视频再次播放时 ValueKey 不变导致 onVideoEnd 永不触发。
  int _playbackNonce = 0;

  /// 防止自动模式下定时器/动画结束/视频结束在 [await] 间隙重入 [_showNextMedia]，导致顺序游标连跳两次、漏播。
  bool _showNextMediaInProgress = false;

  /// 每条成功展示的媒体递增；自动切换回调仅当 [sessionForAutoAdvance] 仍等于当前值时才执行，避免过期定时器/重复动画结束误切下一条。
  int _mediaSessionId = 0;

  /// 「当前的浏览页面」是否正在文档底栏托管真实 WebView（loan）。
  bool _browserLivePreviewActive = false;

  bool get _isBrowserLiveSource =>
      _selectedDirectory == kMediaSourceBrowserLive;

  String _sequentialIndexPrefsKey() {
    final d = _selectedDirectory ?? 'root';
    final f = _favoriteFilter.storageValue;
    return 'media_player_seq_idx_${Uri.encodeComponent(d)}_${Uri.encodeComponent(f)}';
  }

  String _scopePrefsKeyForDirectory(String directory) {
    return '${kMediaSourceFavoriteFilterPrefsKey}_${Uri.encodeComponent(directory)}';
  }

  Future<MediaSourceFavoriteFilter> _loadScopeForDirectory(
    String directory,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_scopePrefsKeyForDirectory(directory));
    return parseMediaSourceFavoriteFilter(raw);
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
    if (c == null ||
        !c.value.isInitialized ||
        c.value.duration <= Duration.zero) {
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
      _foregroundVideoMuted = settings.foregroundVideoMuted;
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
        foregroundVideoMuted: _foregroundVideoMuted,
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
          _foregroundVideoMuted = snap.foregroundVideoMuted;
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
    await prefs.setString(
      _scopePrefsKeyForDirectory(directory),
      filter.storageValue,
    );
    Logger.i(
      'Saved media source: directory=$directory, scope=${filter.storageValue}',
    );
  }

  Future<void> _loadMediaList({bool restartPlaybackIfActive = true}) async {
    if (_isBrowserLiveSource) {
      _mediaList = [];
      if (_mediaMode != MediaMode.none && restartPlaybackIfActive) {
        _startBrowserLivePreview();
      } else if (mounted) {
        setState(() {
          _mediaWidget = null;
          _currentPlayingMedia = null;
        });
      }
      Logger.i('媒体来源为当前浏览页面（WebView loan 预览，不加载本地库）');
      return;
    }

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
    if (_isBrowserLiveSource) return [];
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
        final typeIdx = DatabaseService.mediaTypeIndex(item);
        if (_favoriteFilter == MediaSourceFavoriteFilter.videoOnly &&
            typeIdx != 1) {
          continue;
        }
        if (_favoriteFilter == MediaSourceFavoriteFilter.imageOnly &&
            typeIdx != 0) {
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
    if (_isBrowserLiveSource) {
      setState(() {
        _mediaMode = MediaMode.manual;
      });
      _startBrowserLivePreview();
      return;
    }
    _sequentialToolbarPlayExplicitNextVideoIfPlaying();
    setState(() {
      _mediaMode = MediaMode.manual;
    });
    _showNextMedia();
  }

  void playAuto() {
    if (_isBrowserLiveSource) {
      setState(() {
        _mediaMode = MediaMode.auto;
      });
      _startBrowserLivePreview();
      return;
    }
    _sequentialToolbarPlayExplicitNextVideoIfPlaying();
    setState(() {
      _mediaMode = MediaMode.auto;
    });
    _showNextMedia();
  }

  void stop() {
    _flushSequentialVideoResumeProgress();
    _stopBrowserLivePreview();
    setState(() {
      _mediaMode = MediaMode.none;
      _mediaWidget = null;
      _currentVideoWidget = null;
      _currentPlayingMedia = null; // 清除当前播放媒体
      _mediaTimer?.cancel();
      _mediaTimer = null;
    });
  }

  void _startBrowserLivePreview() {
    final preview = BrowserSessionPreview.instance;
    if (!preview.isAvailable) {
      _browserLivePreviewActive = false;
      preview.setLoaned(false);
      setState(() {
        _mediaWidget = const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '浏览器会话不可用。请先在浏览器打开网页，再通过「目录」进入文档后选择「当前的浏览页面」。',
              textAlign: TextAlign.center,
            ),
          ),
        );
        _currentPlayingMedia = null;
      });
      return;
    }

    _currentPlayingMedia = {
      'id': kMediaSourceBrowserLive,
      'name': '当前的浏览页面',
      'type': -1,
      'path': preview.pageUrl ?? '',
    };
    _mediaSessionId++;
    // 同一帧内：BrowserPage 让出 GlobalKey WebView，底栏接管（无截图轮询）。
    // 先记下真实 URL：Android Hybrid Composition 归还时经常 remount 成 about:blank。
    preview.rememberBrowsingUrl(preview.pageUrl ?? preview.lastBrowsingUrl);
    _browserLivePreviewActive = true;
    preview.setLoaned(true);
    setState(() {
      _mediaWidget = null; // build() 直接绘制 loan 面板，避免缓存旧树
    });
  }

  void _stopBrowserLivePreview() {
    _browserLivePreviewActive = false;
    // 先归还 BrowserPage，再由 stop()/setState 卸下底栏宿主，保证同帧只有一处挂载。
    BrowserSessionPreview.instance.setLoaned(false);
  }

  /// 退出文档前归还 WebView；返回是否曾占用 loan（调用方应 await endOfFrame）。
  bool releaseBrowserLiveLoan() {
    if (!_browserLivePreviewActive &&
        !BrowserSessionPreview.instance.isLoaned) {
      return false;
    }
    _browserLivePreviewActive = false;
    BrowserSessionPreview.instance.setLoaned(false);
    if (mounted) {
      setState(() {
        if (_isBrowserLiveSource) {
          _mediaMode = MediaMode.none;
          _mediaWidget = null;
          _currentPlayingMedia = null;
        }
      });
    }
    return true;
  }

  Widget _buildBrowserLivePreviewPanel() {
    final preview = BrowserSessionPreview.instance;
    final webView = preview.buildLoanedWebView();

    return ColoredBox(
      color: Colors.black,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 真实 WebView；IgnorePointer 避免与文档编辑抢焦点/手势。
                if (webView != null)
                  Positioned.fill(child: IgnorePointer(child: webView))
                else
                  const Center(
                    child: Text(
                      '浏览器画面暂不可用',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                Positioned(
                  left: 8,
                  right: 8,
                  top: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.language,
                            color: Colors.tealAccent,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: ValueListenableBuilder<String?>(
                              valueListenable: preview.pageUrlNotifier,
                              builder: (context, url, _) {
                                return Text(
                                  url != null && url.isNotEmpty
                                      ? url
                                      : '当前的浏览页面（观看模式，文档可继续编辑）',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _buildBrowserDownloadProgressStrip(),
        ],
      ),
    );
  }

  Widget _buildBrowserDownloadProgressStrip() {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: BrowserSessionPreview.instance.downloadTasks,
      builder: (context, tasks, _) {
        final active =
            tasks.where((t) {
              final status = (t['status'] ?? '').toString();
              return status == 'downloading' ||
                  status == 'paused' ||
                  status == 'failed';
            }).toList();
        // 无进行中任务时仍展示最近若干条，便于查看已完成/失败。
        final shown =
            active.isNotEmpty
                ? active.take(4).toList()
                : tasks.take(3).toList();

        return Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 160),
          color: const Color(0xE6121212),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child:
              shown.isEmpty
                  ? const Text(
                    '暂无浏览器下载任务',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  )
                  : ListView.separated(
                    shrinkWrap: true,
                    itemCount: shown.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final task = shown[index];
                      final name =
                          (task['displayName'] ?? task['url'] ?? '下载任务')
                              .toString();
                      final status = (task['status'] ?? '').toString();
                      final progress =
                          (task['progress'] as num?)?.toDouble() ?? 0.0;
                      final detail = (task['progressDetail'] ?? '').toString();
                      final transferStatus =
                          (task['transferStatus'] ?? '').toString();
                      final statusLabel = _browserDownloadStatusLabel(status);
                      final smartCompleted =
                          (task['smartBatchCompleted'] as num?)?.toInt();
                      final smartTarget =
                          (task['smartBatchTarget'] as num?)?.toInt();
                      final smartProgressLabel =
                          smartCompleted != null &&
                                  smartTarget != null &&
                                  smartTarget > 0
                              ? '$smartCompleted/$smartTarget'
                              : '';
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (smartProgressLabel.isNotEmpty) ...[
                                Text(
                                  smartProgressLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Text(
                                statusLabel,
                                style: TextStyle(
                                  color: _browserDownloadStatusColor(status),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value:
                                  status == 'completed'
                                      ? 1.0
                                      : progress.clamp(0.0, 1.0),
                              minHeight: 4,
                              backgroundColor: Colors.white12,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                _browserDownloadStatusColor(status),
                              ),
                            ),
                          ),
                          if (detail.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 10,
                              ),
                            ),
                          ],
                          if (transferStatus.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              transferStatus,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
        );
      },
    );
  }

  String _browserDownloadStatusLabel(String status) {
    switch (status) {
      case 'downloading':
        return '下载中';
      case 'paused':
        return '已暂停';
      case 'completed':
        return '已完成';
      case 'cancelled':
        return '已取消';
      case 'failed':
        return '失败';
      default:
        return status.isEmpty ? '未知' : status;
    }
  }

  Color _browserDownloadStatusColor(String status) {
    switch (status) {
      case 'downloading':
        return Colors.lightBlueAccent;
      case 'paused':
        return Colors.orangeAccent;
      case 'completed':
        return Colors.greenAccent;
      case 'cancelled':
        return Colors.white54;
      case 'failed':
        return Colors.redAccent;
      default:
        return Colors.white70;
    }
  }

  Future<MediaItem?> getCurrentMedia() async {
    if (_currentPlayingMedia == null) return null;
    return MediaItem.fromMap(Map<String, dynamic>.from(_currentPlayingMedia!));
  }

  /// 当前浮层视频播放进度（非视频或未初始化时为 null）。供进入全屏调整页续播使用。
  Duration? getCurrentVideoPlaybackPosition() {
    if (_currentPlayingMedia == null) return null;
    if (DatabaseService.mediaTypeIndex(_currentPlayingMedia!) != 1) {
      return null;
    }
    final c = _currentVideoWidget?.controller;
    if (c == null || !c.value.isInitialized) return null;
    return c.value.position;
  }

  void pausePlaybackForExternalPreview() {
    _flushSequentialVideoResumeProgress();
    _mediaTimer?.cancel();
    _mediaTimer = null;
    _currentVideoWidget?.controller?.pause();
  }

  Future<void> reloadCurrentMediaFromDatabase({
    Duration? preferResumeVideoPosition,
  }) async {
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
      final params = await _docBarDefaultViewParamsForImage(
        refreshedMap,
        mediaFile,
      );
      setState(() {
        _currentVideoWidget = null;
        if (_imageMode == MediaImageDisplayMode.kenBurns) {
          _mediaWidget = _wrapImageWithStoredView(
            _buildKenBurnsForPlaying(refreshedMap, mediaFile, _mediaSessionId),
            refreshedMap,
            initialOverride: params,
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
            initialOverride: params,
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
            initialOverride: params,
          );
        }
      });
      return;
    }

    if (typeIdx == 1) {
      final bool sequential = _playbackOrder == MediaPlaybackOrder.sequential;
      final String vid = currentId;
      Duration? initialSeek;
      var seqResumeActive = false;
      final prefer = preferResumeVideoPosition;
      if (prefer != null && prefer > Duration.zero) {
        initialSeek = prefer;
        seqResumeActive = false;
      } else if (sequential && vid.isNotEmpty) {
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
          defaultVerticalFillWhenPristine: true,
          documentMediaBarMuted: _foregroundVideoMuted,
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

  bool _isPureDefaultPresentation(Map<String, dynamic> mediaMap) {
    final p = VideoViewParams.fromMediaMap(mediaMap);
    final bool hasKenBurnsCenter =
        (mediaMap['ken_burns_center_x'] as num?) != null ||
        (mediaMap['ken_burns_center_y'] as num?) != null;
    return p.isLikelyIdentityTransform &&
        p.basisW == null &&
        p.basisH == null &&
        p.anchorXNorm == null &&
        p.anchorYNorm == null &&
        !hasKenBurnsCenter;
  }

  Size _basisSizeForQuarterTurns(Size viewport, int quarterTurns) {
    final q = quarterTurns % 4;
    if (q == 1 || q == 3) {
      return Size(viewport.height, viewport.width);
    }
    return viewport;
  }

  Future<VideoViewParams> _docBarDefaultViewParamsForImage(
    Map<String, dynamic> mediaMap,
    File imageFile,
  ) async {
    final p = VideoViewParams.fromMediaMap(mediaMap);
    if (_imageMode != MediaImageDisplayMode.fitWidth) {
      return p;
    }
    if (!_isPureDefaultPresentation(mediaMap)) {
      return p;
    }
    final viewport = MediaQuery.of(context).size;
    if (viewport.width <= 1 || viewport.height <= 1) return p;
    final q = p.quarterTurns % 4;
    if (q != 0) return p;
    final basis = _basisSizeForQuarterTurns(viewport, q);
    final imageSize = await measureImageFileSize(imageFile);
    final sideways = q == 1 || q == 3;
    final baseDisplay =
        sideways
            ? containDisplaySize(imageSize, viewport.width, viewport.height)
            : fitWidthDisplaySize(imageSize, viewport.width);
    if (baseDisplay.height <= 1) return p;
    final targetScale = (viewport.height / baseDisplay.height).clamp(1.0, 6.0);
    return VideoViewParams(
      scale: targetScale,
      txNorm: 0.0,
      tyNorm: 0.0,
      quarterTurns: q,
      basisW: basis.width,
      basisH: basis.height,
    );
  }

  /// 与 [VideoPlayerWidget] 一致：套用媒体页已保存的缩放/平移/旋转（只读）。
  Widget _wrapImageWithStoredView(
    Widget child,
    Map<String, dynamic> mediaMap, {
    VideoViewParams? initialOverride,
  }) {
    final p = initialOverride ?? VideoViewParams.fromMediaMap(mediaMap);
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
    if (_isBrowserLiveSource) {
      _startBrowserLivePreview();
      return;
    }
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
            final params = await _docBarDefaultViewParamsForImage(
              nextMedia,
              mediaFile,
            );
            setState(() {
              _mediaWidget = _wrapImageWithStoredView(
                _buildKenBurnsForPlaying(
                  nextMedia,
                  mediaFile,
                  sessionThisMedia,
                ),
                nextMedia,
                initialOverride: params,
              );
            });
          } else if (_imageMode == MediaImageDisplayMode.zoomPanEdge) {
            final sideways =
                VideoViewParams.fromMediaMap(nextMedia).quarterTurns % 2 == 1;
            final params = await _docBarDefaultViewParamsForImage(
              nextMedia,
              mediaFile,
            );
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
                initialOverride: params,
              );
            });
          } else {
            final sideways =
                VideoViewParams.fromMediaMap(nextMedia).quarterTurns % 2 == 1;
            final params = await _docBarDefaultViewParamsForImage(
              nextMedia,
              mediaFile,
            );
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
                initialOverride: params,
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
              initialSeek = Duration(milliseconds: max(0, saved - 5000));
              seqResumeActive = true;
            }
          }
          if (!mounted) return;
          setState(() {
            _currentVideoWidget = VideoPlayerWidget(
              key: ValueKey('vp_${nextMedia['path']}_$_playbackNonce'),
              file: File(nextMedia['path']!),
              viewParams: VideoViewParams.fromMediaMap(nextMedia),
              defaultVerticalFillWhenPristine: true,
              documentMediaBarMuted: _foregroundVideoMuted,
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
    unawaited(
      showMediaSourceSelectionSheet(
        context: context,
        selectedDirectory: _selectedDirectory,
        panelOpacity: 0.8,
      ).then((directory) async {
        Logger.d('Dialog closed, selected: $directory');
        if (directory == null || !mounted) return;

        final MediaSourceFavoriteFilter scope;
        if (directory == kMediaSourceBrowserLive) {
          // 浏览页面预览不区分收藏范围
          scope = MediaSourceFavoriteFilter.all;
        } else {
          final presetScope = await _loadScopeForDirectory(directory);
          final picked = await _showFavoriteScopeDialog(initialScope: presetScope);
          if (!mounted || picked == null) return;
          scope = picked;
        }

        final changed =
            directory != _selectedDirectory || scope != _favoriteFilter;
        if (!changed) return;

        _stopBrowserLivePreview();
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
          directory == kMediaSourceBrowserLive
              ? '已选择媒体来源: 当前的浏览页面'
              : '已选择媒体来源: $directory，范围: ${scope.displayLabel}',
        );
      }),
    );
  }

  /// 选定目录/整个媒体库后，再选「全部 / 已收藏 / 未收藏」。
  Future<MediaSourceFavoriteFilter?> _showFavoriteScopeDialog({
    MediaSourceFavoriteFilter? initialScope,
  }) {
    return showDialog<MediaSourceFavoriteFilter>(
      context: context,
      builder: (ctx) {
        final selected = initialScope ?? _favoriteFilter;
        Widget buildScopeTile({
          required IconData icon,
          Color? iconColor,
          required MediaSourceFavoriteFilter value,
          required String subtitle,
        }) {
          final isSelected = selected == value;
          return ListTile(
            leading: Icon(icon, color: iconColor),
            title: Text(value.displayLabel),
            subtitle: Text(subtitle),
            selected: isSelected,
            trailing:
                isSelected
                    ? const Icon(Icons.check_circle, color: Colors.blue)
                    : null,
            onTap: () => Navigator.of(ctx).pop(value),
          );
        }

        return AlertDialog(
          title: const Text('选择媒体范围'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                buildScopeTile(
                  icon: Icons.perm_media_outlined,
                  value: MediaSourceFavoriteFilter.all,
                  subtitle: '包含当前来源下全部图片与视频',
                ),
                buildScopeTile(
                  icon: Icons.favorite,
                  iconColor: Colors.pink.withValues(alpha: 0.85),
                  value: MediaSourceFavoriteFilter.favoriteOnly,
                  subtitle: '仅播放或展示已星标收藏的项',
                ),
                buildScopeTile(
                  icon: Icons.favorite_border,
                  value: MediaSourceFavoriteFilter.notFavoriteOnly,
                  subtitle: '排除已星标收藏的项',
                ),
                buildScopeTile(
                  icon: Icons.ondemand_video,
                  value: MediaSourceFavoriteFilter.videoOnly,
                  subtitle: '仅播放或展示视频',
                ),
                buildScopeTile(
                  icon: Icons.image_outlined,
                  value: MediaSourceFavoriteFilter.imageOnly,
                  subtitle: '仅播放或展示图片',
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
    _stopBrowserLivePreview();
    _mediaTimer?.cancel();
    super.dispose();
  }

  // 新增方法: 移动当前媒体到指定目录（使用和媒体页一致的半透明底部面板）
  Future<bool> moveCurrentMedia(BuildContext context) async {
    if (_currentPlayingMedia == null) {
      _showMessage(context, '没有正在播放的媒体文件');
      return false;
    }

    try {
      final String currentDirectory =
          _currentPlayingMedia!['directory']?.toString() ?? 'root';

      // —— 和媒体页一致：先弹出加载中遮罩 ——
      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder:
              (ctx) => const AlertDialog(
                content: Row(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(width: 20),
                    Text('加载中...'),
                  ],
                ),
              ),
        );
      }

      // 加载所有文件夹（排除系统文件夹：回收站/收藏夹），并过滤掉当前目录
      List<MediaItem> folders;
      try {
        final raw = await _getAllAvailableFolders();
        folders =
            raw
                .map((m) {
                  try {
                    return MediaItem.fromMap(m);
                  } catch (_) {
                    return null;
                  }
                })
                .whereType<MediaItem>()
                .where((f) => f.id != currentDirectory)
                .where(
                  (f) => f.id != 'recycle_bin' && f.id != 'favorites',
                )
                .toList();
      } catch (_) {
        if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有可用的目标文件夹。')),
          );
        }
        return false;
      }

      if (!context.mounted) return false;
      Navigator.of(context, rootNavigator: true).pop(); // 关闭 loading

      // —— 和媒体页一致：调用统一的 showMoveToFolderSheet 面板 ——
      final chosen = await showMoveToFolderSheet(
        context: context,
        folders: folders,
        includeRoot: true,
        rootEnabled: currentDirectory != 'root',
        // 和媒体页保持一致透明度：80% 不透明，减轻缩略图透出混淆
        panelOpacity: 0.8,
      );
      if (!context.mounted || chosen == null) return false;
      final String targetDirectory = chosen.id == 'root' ? 'root' : chosen.id;

      // 检查目标是否与当前目录相同
      if (_currentPlayingMedia!['directory']?.toString() == targetDirectory) {
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

      // 更新数据库记录：调用专用 moveMediaItemToDirectory，保证：
      // 1) 在目标目录同类(fav/unfav)区最前面；
      // 2) 若新目录无人工排序，则 date_added 更新为 now，兜底按最新排最前；
      // 3) 若新目录有 sort_order，旧项全体 +1，新项 sort_order = 0。
      final mediaId = currentMedia['id']?.toString() ?? '';
      if (mediaId.isEmpty) {
        throw StateError('当前媒体没有 id，无法移动');
      }
      await _databaseService.moveMediaItemToDirectory(mediaId, targetDirectory);

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
        (media) => media['id']?.toString() == mediaId,
      );

      String? successorId;
      if (_playbackOrder == MediaPlaybackOrder.sequential &&
          _mediaList.length > 1 &&
          currentIndex >= 0) {
        final oldIds =
            _mediaList
                .map((m) => m['id']?.toString() ?? '')
                .where((s) => s.isNotEmpty)
                .toList();
        final curIdx = oldIds.indexOf(mediaId);
        if (curIdx >= 0) {
          successorId = oldIds[(curIdx + 1) % oldIds.length];
        }
      }

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
        if (_mediaList.isEmpty) {
          _sequentialIndex = 0;
          await _persistSequentialIndex();
        } else if (_playbackOrder == MediaPlaybackOrder.sequential) {
          if (successorId != null) {
            final nextIdx = _mediaList.indexWhere(
              (m) => m['id']?.toString() == successorId,
            );
            if (nextIdx >= 0) {
              _sequentialIndex = nextIdx;
              await _persistSequentialIndex();
            } else {
              _adjustSequentialAfterRemove(removedIndex: currentIndex);
            }
          } else {
            _adjustSequentialAfterRemove(removedIndex: currentIndex);
          }
        }
      }

      if (!context.mounted) return false;

      // 如果列表为空，停止播放
      if (_mediaList.isEmpty) {
        stop();
        return true;
      }

      // 如果删除的是当前播放的媒体，立即播放下一个
      if (_currentPlayingMedia != null &&
          _currentPlayingMedia!['id']?.toString() == mediaId) {
        _showNextMediaInProgress = false;
        await _showNextMedia();
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
  /// 用于文档编辑界面等场景：外部已更新数据库（如移动到回收站）后，
  /// 从内存列表去掉该项并自动播放下一条。
  ///
  /// **顺序模式**下与 [refreshMediaListAndAdvanceToNext]（单击收藏）一致：在移除前的列表上
  /// 取「当前下一条」的 id，移除后将 [_sequentialIndex] 设为该条在新列表中的下标，避免与
  /// 仅依赖 [_adjustSequentialAfterRemove] 时出现偏差。
  ///
  /// 另：若此时仍有未结束的 [_showNextMedia]（例如卡在 `await`），其 [ _showNextMediaInProgress ]
  /// 会阻止新的切换；此处会清零该标志以便用户操作（删除/回收）能立刻生效。
  Future<void> removeCurrentAndPlayNext() async {
    if (_currentPlayingMedia == null) return;
    final String currentId = _currentPlayingMedia!['id']?.toString() ?? '';
    if (currentId.isNotEmpty) {
      unawaited(_clearVideoResumeForId(currentId));
    }

    String? successorId;
    if (_playbackOrder == MediaPlaybackOrder.sequential &&
        _mediaList.length > 1) {
      final oldIds =
          _mediaList
              .map((m) => m['id']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList();
      final curIdx = oldIds.indexOf(currentId);
      if (curIdx >= 0) {
        successorId = oldIds[(curIdx + 1) % oldIds.length];
      }
    }

    final int currentIndex = _mediaList.indexWhere(
      (media) => media['id']?.toString() == currentId,
    );
    if (currentIndex == -1) return;

    setState(() {
      _mediaList.removeAt(currentIndex);
    });

    if (_mediaList.isEmpty) {
      _sequentialIndex = 0;
      await _persistSequentialIndex();
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
        } else {
          _adjustSequentialAfterRemove(removedIndex: currentIndex);
        }
      } else {
        _adjustSequentialAfterRemove(removedIndex: currentIndex);
      }
    }

    _showNextMediaInProgress = false;
    await _showNextMedia();
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
      final idx = _mediaList.indexWhere(
        (m) => m['id']?.toString() == currentId,
      );
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
    final browserLivePlaying =
        _browserLivePreviewActive &&
        _mediaMode != MediaMode.none &&
        _isBrowserLiveSource;
    final sync = widget.syncForegroundObscuringBackground;
    if (sync != null) {
      final obscuring =
          _mediaMode != MediaMode.none &&
          (_mediaWidget != null || browserLivePlaying);
      if (sync.value != obscuring) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final live =
              _browserLivePreviewActive &&
              _mediaMode != MediaMode.none &&
              _isBrowserLiveSource;
          final o =
              _mediaMode != MediaMode.none && (_mediaWidget != null || live);
          if (sync.value != o) {
            sync.value = o;
          }
        });
      }
    }
    if (browserLivePlaying) {
      return SizedBox.expand(child: _buildBrowserLivePreviewPanel());
    }
    return _mediaWidget != null
        ? SizedBox.expand(child: _mediaWidget!)
        : Container();
  }
}
