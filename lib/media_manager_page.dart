import 'dart:io';
import 'dart:math' as math;
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier;
import 'services/logger.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'services/file_cleanup_service.dart';
import 'models/media_item.dart';
import 'media_preview_page.dart';
import 'create_folder_dialog.dart';
import 'models/media_type.dart';
import 'media_player_settings.dart'
    show applyMediaSettingsImportMap, buildMediaSettingsExportMap;
import 'widgets/image_layout_utils.dart' show ZoomCenterMarkerCoverOverlay;
import 'widgets/safe_modal_sheet_body.dart';
import 'browser_page.dart';
import 'services/cache_service.dart';
import 'services/export_import_utils.dart'
    show
        getExportSaveDirectory,
        kExportChunkSize,
        kProgressUpdateInterval,
        kShareSizeLimitBytes,
        kStreamingThresholdBytes,
        copyFileWithStreamingToFile;
import 'utils/export_import_error_utils.dart';
import 'utils/safe_path_utils.dart';
import 'services/test_data_generator_service.dart';
import 'storage_management_page.dart';
import 'utils/photo_album_paths.dart';

/// 批量导入：按相册索引加载资源。0 = 合并全部相册并按拍摄时间从新到旧；1..n = 单个相册内同样按时间排序。
Future<List<AssetEntity>> _loadMediaAssetsForAlbumIndex(
  List<AssetPathEntity> paths,
  int albumIndex,
) async {
  if (albumIndex == 0) {
    final Set<String> mediaIds = {};
    final List<AssetEntity> allMedia = [];
    for (final pathEntity in paths) {
      final assets = await pathEntity.getAssetListRange(start: 0, end: 100000);
      for (final asset in assets) {
        if (asset.type != AssetType.image && asset.type != AssetType.video)
          continue;
        if (!mediaIds.contains(asset.id)) {
          allMedia.add(asset);
          mediaIds.add(asset.id);
        }
      }
    }
    allMedia.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    return allMedia;
  }
  final idx = albumIndex - 1;
  if (idx < 0 || idx >= paths.length) return [];
  final pathEntity = paths[idx];
  final assets = await pathEntity.getAssetListRange(start: 0, end: 100000);
  final list =
      assets
          .where((a) => a.type == AssetType.image || a.type == AssetType.video)
          .toList();
  list.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
  return list;
}

String _formatMediaPickerDuration(Duration duration) {
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  final minutes = twoDigits(duration.inMinutes.remainder(60));
  final seconds = twoDigits(duration.inSeconds.remainder(60));
  return '$minutes:$seconds';
}

/// 批量导入媒体：支持按相册切换；右上角显示已选图片/视频数量。
class _BatchMediaSelectionDialog extends StatefulWidget {
  const _BatchMediaSelectionDialog({required this.albums});

  final List<AssetPathEntity> albums;

  @override
  State<_BatchMediaSelectionDialog> createState() =>
      _BatchMediaSelectionDialogState();
}

class _BatchMediaSelectionDialogState
    extends State<_BatchMediaSelectionDialog> {
  List<AssetEntity> items = [];
  bool loading = true;
  int albumIndex = 0;

  final List<AssetEntity> selected = [];
  bool isDragSelecting = false;
  (int, int)? dragStartColRow;
  bool dragIsDeselectMode = false;
  Offset? dragStartPosition;
  bool hasDragMoved = false;
  String? gestureCommitted;
  double scrollOffsetBeforeGesture = 0;
  final GlobalKey gridKey = GlobalKey();
  final ScrollController scrollController = ScrollController();

  static const int crossAxisCount = 4;
  static const double childAspectRatio = 1;
  static const double crossAxisSpacing = 4;
  static const double mainAxisSpacing = 4;
  static const double padding = 4;
  static const double dragThreshold = 8;

  @override
  void initState() {
    super.initState();
    _reloadItems();
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  Future<void> _reloadItems() async {
    setState(() => loading = true);
    final list = await _loadMediaAssetsForAlbumIndex(widget.albums, albumIndex);
    if (!mounted) return;
    setState(() {
      items = list;
      loading = false;
    });
  }

  bool _isSelected(AssetEntity a) => selected.any((e) => e.id == a.id);

  void _toggle(AssetEntity a) {
    setState(() {
      final i = selected.indexWhere((e) => e.id == a.id);
      if (i >= 0) {
        selected.removeAt(i);
      } else {
        selected.add(a);
      }
    });
  }

  (int, int)? _getGridColRow(Offset globalPosition) {
    final box = gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(globalPosition);
    final w = box.size.width - padding * 2;
    final cellWidth =
        (w - (crossAxisCount - 1) * crossAxisSpacing) / crossAxisCount;
    final cellHeight = cellWidth / childAspectRatio;
    final contentX = local.dx - padding;
    final contentY = local.dy - padding + scrollController.offset;
    if (contentX < 0 || contentY < 0) return null;
    final col = (contentX / (cellWidth + crossAxisSpacing)).floor().clamp(
      0,
      crossAxisCount - 1,
    );
    final row = (contentY / (cellHeight + mainAxisSpacing)).floor().clamp(
      0,
      999999,
    );
    return (col, row);
  }

  List<int> _indicesInRectangle(
    int startCol,
    int startRow,
    int endCol,
    int endRow,
  ) {
    final minCol = startCol < endCol ? startCol : endCol;
    final maxCol = startCol > endCol ? startCol : endCol;
    final minRow = startRow < endRow ? startRow : endRow;
    final maxRow = startRow > endRow ? startRow : endRow;
    final list = <int>[];
    for (int r = minRow; r <= maxRow; r++) {
      for (int c = minCol; c <= maxCol; c++) {
        list.add(r * crossAxisCount + c);
      }
    }
    return list;
  }

  void _toggleSelectAllInCurrentAlbum() {
    if (loading || items.isEmpty) return;
    setState(() {
      final allSelected = items.every((a) => selected.any((e) => e.id == a.id));
      if (allSelected) {
        final ids = items.map((a) => a.id).toSet();
        selected.removeWhere((e) => ids.contains(e.id));
      } else {
        for (final a in items) {
          if (!selected.any((e) => e.id == a.id)) {
            selected.add(a);
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final imageSel = selected.where((e) => e.type == AssetType.image).length;
    final videoSel = selected.where((e) => e.type == AssetType.video).length;
    final allInViewSelected =
        !loading &&
        items.isNotEmpty &&
        items.every((a) => selected.any((e) => e.id == a.id));

    return Dialog(
      insetPadding: EdgeInsets.zero,
      child: SizedBox(
        width: screenSize.width,
        height: screenSize.height * 0.9,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: albumIndex,
                        isExpanded: true,
                        hint: const Text('选择相册'),
                        items: [
                          const DropdownMenuItem(
                            value: 0,
                            child: Text(
                              '全部（所有相册合并）',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ...List<DropdownMenuItem<int>>.generate(
                            widget.albums.length,
                            (i) => DropdownMenuItem(
                              value: i + 1,
                              child: Text(
                                widget.albums[i].name,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (v) async {
                          if (v == null || v == albumIndex) return;
                          setState(() => albumIndex = v);
                          await _reloadItems();
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed:
                        loading || items.isEmpty
                            ? null
                            : _toggleSelectAllInCurrentAlbum,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      allInViewSelected ? '取消全选' : '全选',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          '已选 $imageSel 图 · $videoSel 视频',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child:
                  loading
                      ? const Center(child: CircularProgressIndicator())
                      : Listener(
                        key: gridKey,
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (e) {
                          scrollOffsetBeforeGesture = scrollController.offset;
                          gestureCommitted = null;
                          final startCr = _getGridColRow(e.position);
                          if (startCr != null) {
                            final startIdx =
                                startCr.$2 * crossAxisCount + startCr.$1;
                            if (startIdx >= 0 && startIdx < items.length) {
                              final asset = items[startIdx];
                              hasDragMoved = false;
                              dragStartPosition = e.position;
                              dragStartColRow = startCr;
                              dragIsDeselectMode = _isSelected(asset);
                            }
                          }
                        },
                        onPointerMove: (e) {
                          if (dragStartColRow != null &&
                              dragStartPosition != null) {
                            final dx = e.position.dx - dragStartPosition!.dx;
                            final dy = e.position.dy - dragStartPosition!.dy;
                            if (gestureCommitted == null) {
                              final dist = math.sqrt(dx * dx + dy * dy);
                              if (dist > dragThreshold) {
                                if (dx.abs() > dy.abs()) {
                                  gestureCommitted = 'selection';
                                  isDragSelecting = true;
                                  hasDragMoved = true;
                                  setState(() {});
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (scrollController.hasClients) {
                                      scrollController.jumpTo(
                                        scrollOffsetBeforeGesture,
                                      );
                                    }
                                  });
                                } else {
                                  gestureCommitted = 'scroll';
                                }
                              }
                            }
                          }
                          if (isDragSelecting && dragStartColRow != null) {
                            if (!hasDragMoved) {
                              final dx =
                                  e.position.dx - (dragStartPosition?.dx ?? 0);
                              final dy =
                                  e.position.dy - (dragStartPosition?.dy ?? 0);
                              final dist = math.sqrt(dx * dx + dy * dy);
                              if (dist < dragThreshold) return;
                              hasDragMoved = true;
                            }
                            final curCr = _getGridColRow(e.position);
                            if (curCr != null) {
                              final indices = _indicesInRectangle(
                                dragStartColRow!.$1,
                                dragStartColRow!.$2,
                                curCr.$1,
                                curCr.$2,
                              );
                              setState(() {
                                for (final idx in indices) {
                                  if (idx >= 0 && idx < items.length) {
                                    final asset = items[idx];
                                    if (dragIsDeselectMode) {
                                      selected.removeWhere(
                                        (e) => e.id == asset.id,
                                      );
                                    } else if (!_isSelected(asset)) {
                                      selected.add(asset);
                                    }
                                  }
                                }
                              });
                            }
                          }
                        },
                        onPointerUp: (_) {
                          if (isDragSelecting) {
                            isDragSelecting = false;
                            gestureCommitted = null;
                            setState(() {});
                          } else {
                            gestureCommitted = null;
                          }
                        },
                        onPointerCancel: (_) {
                          if (isDragSelecting) {
                            isDragSelecting = false;
                            gestureCommitted = null;
                            setState(() {});
                          } else {
                            gestureCommitted = null;
                          }
                        },
                        child: Builder(
                          builder:
                              (ctx) => ScrollConfiguration(
                                behavior: ScrollConfiguration.of(ctx).copyWith(
                                  physics:
                                      isDragSelecting
                                          ? const NeverScrollableScrollPhysics()
                                          : const ClampingScrollPhysics(),
                                ),
                                child: GridView.builder(
                                  controller: scrollController,
                                  padding: const EdgeInsets.all(4.0),
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 4,
                                        childAspectRatio: 1,
                                        crossAxisSpacing: 4,
                                        mainAxisSpacing: 4,
                                      ),
                                  itemCount: items.length,
                                  itemBuilder: (context, index) {
                                    final asset = items[index];
                                    final isSelected = _isSelected(asset);
                                    final isVideo =
                                        asset.type == AssetType.video;
                                    return GestureDetector(
                                      onTap: () => _toggle(asset),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          FutureBuilder<Uint8List?>(
                                            future: asset.thumbnailDataWithSize(
                                              const ThumbnailSize(200, 200),
                                            ),
                                            builder: (context, snapshot) {
                                              if (snapshot.hasData &&
                                                  snapshot.data != null) {
                                                return Image.memory(
                                                  snapshot.data!,
                                                  fit: BoxFit.cover,
                                                  width: double.infinity,
                                                  height: double.infinity,
                                                );
                                              }
                                              return const Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              );
                                            },
                                          ),
                                          if (isSelected)
                                            const Positioned(
                                              top: 4,
                                              right: 4,
                                              child: Icon(
                                                Icons.check_circle,
                                                color: Colors.green,
                                                size: 24,
                                              ),
                                            ),
                                          if (isVideo)
                                            Positioned(
                                              bottom: 4,
                                              left: 4,
                                              child: Container(
                                                color: Colors.black54,
                                                padding: const EdgeInsets.all(
                                                  2,
                                                ),
                                                child: Text(
                                                  _formatMediaPickerDuration(
                                                    Duration(
                                                      seconds: asset.duration,
                                                    ),
                                                  ),
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                        ),
                      ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        () => Navigator.pop<List<AssetEntity>?>(context, null),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed:
                        () => Navigator.pop<List<AssetEntity>>(
                          context,
                          List<AssetEntity>.from(selected),
                        ),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MediaManagerPage extends StatefulWidget {
  const MediaManagerPage({super.key, this.onMultiSelectModeChanged});

  final void Function(bool isMultiSelectMode)? onMultiSelectModeChanged;

  @override
  _MediaManagerPageState createState() => _MediaManagerPageState();
}

class _FolderPropertiesStats {
  const _FolderPropertiesStats({
    required this.directChildCount,
    required this.totalItems,
    required this.fileCount,
    required this.subFolderCount,
    required this.totalBytes,
    required this.missingOrUnreadableFiles,
  });

  final int directChildCount;
  final int totalItems;
  final int fileCount;
  final int subFolderCount;
  final int totalBytes;
  final int missingOrUnreadableFiles;
}

class _MediaManagerPageState extends State<MediaManagerPage>
    with SingleTickerProviderStateMixin {
  final List<MediaItem> _mediaItems = [];
  bool _isLoading = true;
  String _currentDirectory = 'root';
  late final DatabaseService _databaseService;
  int _imageCount = 0;
  int _videoCount = 0;
  bool _mediaVisible = true;
  final Set<String> _selectedItems = {};
  bool _isMultiSelectMode = false;

  /// 复用同一路径的缩略图任务，避免 FutureBuilder 重建时重复触发生成。
  final Map<String, Future<File?>> _videoThumbnailFutureCache = {};
  final Map<String, File> _videoThumbnailFileCache = {};

  /// 对本次会话中已失败的路径不再反复重试，防止导入后触发“失败风暴”。
  final Set<String> _thumbnailGenerationFailed = <String>{};
  final Map<String, Timer> _thumbnailRetryCooldownTimers = {};
  final Set<String> _imageThumbnailPrefetching = <String>{};
  final ListQueue<String> _thumbnailPrefetchQueue = ListQueue<String>();
  final Set<String> _thumbnailPrefetchQueued = <String>{};
  Timer? _thumbnailPrefetchDebounce;
  Timer? _thumbnailUiRefreshDebounce;
  bool _isThumbnailPrefetchRunning = false;
  String? _lastViewedMediaId;
  final List<String> _availableDirectories = ['root'];
  final ScrollController _gridScrollController = ScrollController();
  bool _isDragSelecting = false;
  bool _hasDragMoved = false;
  bool _dragIsDeselectMode = false;
  Offset? _dragStartPosition;
  (int, int)? _dragStartColRow;
  DateTime? _dragSelectFinishedAt;
  final GlobalKey _gridContainerKey = GlobalKey();
  static const double _dragSelectThreshold = 8.0;

  /// 区分滑选与滚动：滑选有横向位移，滚动多为直上直下
  String? _gestureCommitted;
  double _scrollOffsetBeforeGesture = 0;

  // For automatic invalid media cleanup
  final Set<String> _itemsToCleanup = {};
  final Map<String, int> _invalidMediaRetryCounts = {};
  Timer? _cleanupTimer;

  /// 导入完成时间，导入后 30 秒内不触发自动清理，避免大量缩略图生成时的误判
  DateTime? _lastImportCompletedAt;

  /// 略缩图顶栏「设置」：单击延迟打开菜单，与快速双击切换收藏区分。
  Timer? _settingsIconSingleTapTimer;
  DateTime? _settingsIconLastTapTime;

  /// 略缩图卡片右上角圆形菜单（爱心/三点）：单击延迟弹出菜单，快速双击切换收藏。
  Timer? _thumbCornerMenuSingleTapTimer;
  MediaItem? _thumbCornerMenuPendingItem;
  DateTime? _thumbCornerMenuLastTapTime;
  BuildContext? _thumbCornerMenuAnchorContext;

  /// 启动时的媒体ID快照，仅用于自动导入逻辑
  Set<String> _initialAssetIds = {};

  /// 是否正在自动处理，防止重复
  bool _isAutoProcessing = false;

  /// 静默导入开关：true=自动检测并导入手机相册/视频中的新媒体，无需确认；false=完全关闭自动导入，不导入任何新媒体
  bool _autoImportSilentMode = true;

  /// 目录分页：单次加载上限，避免大目录内存压力
  static const int _mediaLoadBatchSize = 400;
  bool _hasMoreMediaItems = false;
  int _mediaItemsLoadOffset = 0;
  bool _isLoadingMore = false;
  static const int _gridCrossAxisCount = 5;
  static const double _gridChildAspectRatio = 0.7;
  static const double _gridCrossAxisSpacing = 4;
  static const double _gridMainAxisSpacing = 4;
  static const double _gridPadding = 4;
  static const int _thumbnailVisiblePrefetchPaddingRows = 2;
  static const int _thumbnailBackgroundBatchSize = 18;
  static const int _thumbnailQueueTrimSize = 1200;
  static const int _thumbnailWarmupLimit = 80;
  static const int _thumbnailPrefetchChunkPerRun = 12;
  static const int _invalidMediaRetryThreshold = 3;
  static const Duration _thumbnailRetryCooldown = Duration(seconds: 20);
  static const Duration _singleThumbnailAttemptTimeout = Duration(seconds: 3);

  /// 视频缩略图并发限制，避免同时生成过多导致内存飙升
  static int _activeThumbnailCount = 0;
  static const int _maxConcurrentThumbnails = 3;
  static final List<Completer<void>> _thumbnailWaitQueue = [];

  @override
  void initState() {
    super.initState();
    _gridScrollController.addListener(_handleGridScroll);

    if (!kIsWeb) {
      _databaseService = getService<DatabaseService>();
      _loadSettings();
      _checkPermissions().then((_) {
        _ensureMediaTable();
        _initPhotoAutoImport(); // 初始化自动导入监听
      });
    } else {
      Logger.log(
        "Web environment: Skipping database and permission operations in MediaManagerPage",
      );
      // 为Web环境设置默认状态
      if (mounted) {
        setState(() {
          _isLoading = false;
          _mediaVisible = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _videoThumbnailFutureCache.clear();
    _videoThumbnailFileCache.clear();
    _thumbnailGenerationFailed.clear();
    for (final timer in _thumbnailRetryCooldownTimers.values) {
      timer.cancel();
    }
    _thumbnailRetryCooldownTimers.clear();
    _invalidMediaRetryCounts.clear();
    _imageThumbnailPrefetching.clear();
    _thumbnailPrefetchQueue.clear();
    _thumbnailPrefetchQueued.clear();
    _thumbnailPrefetchDebounce?.cancel();
    _thumbnailUiRefreshDebounce?.cancel();
    _gridScrollController.removeListener(_handleGridScroll);
    _gridScrollController.dispose();
    _cleanupTimer?.cancel(); // Cancel the cleanup timer
    _settingsIconSingleTapTimer?.cancel();
    _thumbCornerMenuSingleTapTimer?.cancel();
    while (_thumbnailWaitQueue.isNotEmpty) {
      final c = _thumbnailWaitQueue.removeAt(0);
      if (!c.isCompleted) c.complete();
    }
    // 注销媒体库监听
    PhotoManager.removeChangeCallback(_onPhotoLibraryChanged);
    PhotoManager.stopChangeNotify();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    var photosStatus = await Permission.photos.status;
    var videosStatus = await Permission.videos.status;
    var storageStatus = await Permission.storage.status;

    List<Permission> permissionsToRequest = [];

    if (!photosStatus.isGranted) {
      permissionsToRequest.add(Permission.photos);
    }
    if (!videosStatus.isGranted) {
      permissionsToRequest.add(Permission.videos);
    }
    if (!storageStatus.isGranted) {
      permissionsToRequest.add(Permission.storage);
    }

    if (permissionsToRequest.isNotEmpty) {
      await permissionsToRequest.request(); // 只请求权限，不显示任何提示
    }
  }

  Future<void> _ensureMediaTable() async {
    try {
      await _databaseService.ensureMediaItemsTableExists();
      await _loadMediaItems();
      unawaited(_warmCurrentDirectoryVideoThumbnailsInBackground());
      unawaited(_warmAllVideoThumbnailsInBackground());
    } catch (e) {
      debugPrint('确保媒体表存在时出错: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMediaItems({bool append = false}) async {
    if (append && _isLoadingMore) return;
    if (append) {
      setState(() => _isLoadingMore = true);
    } else {
      setState(() => _isLoading = true);
    }

    try {
      if (!append) debugPrint('开始加载媒体项...');

      // 非追加模式：检查并创建回收站/收藏夹（仅首次加载根目录时）
      if (!append && _currentDirectory == 'root') {
        final recycleBinFolder = await _databaseService.getMediaItemById(
          'recycle_bin',
        );
        debugPrint('检查回收站文件夹: ${recycleBinFolder != null ? '存在' : '不存在'}');
        if (recycleBinFolder == null) {
          debugPrint('创建回收站文件夹...');
          await _databaseService.insertMediaItem({
            'id': 'recycle_bin',
            'name': '回收站',
            'path': '',
            'type': MediaType.folder.index,
            'directory': 'root',
            'date_added': DateTime.now().toIso8601String(),
          });
          debugPrint('回收站文件夹创建成功');
        } else if ((recycleBinFolder['directory'] ?? '').toString() != 'root') {
          debugPrint('修复回收站目录为 root');
          await _databaseService.updateMediaItemDirectory(
            'recycle_bin',
            'root',
          );
        }
        final favoritesFolder = await _databaseService.getMediaItemById(
          'favorites',
        );
        debugPrint('检查收藏夹: ${favoritesFolder != null ? '存在' : '不存在'}');
        if (favoritesFolder == null) {
          debugPrint('创建收藏夹...');
          await _databaseService.insertMediaItem({
            'id': 'favorites',
            'name': '收藏夹',
            'path': '',
            'type': MediaType.folder.index,
            'directory': 'root',
            'date_added': DateTime.now().toIso8601String(),
          });
          debugPrint('收藏夹创建成功');
        } else if ((favoritesFolder['directory'] ?? '').toString() != 'root') {
          debugPrint('修复收藏夹目录为 root');
          await _databaseService.updateMediaItemDirectory('favorites', 'root');
        }
        if (!_availableDirectories.contains('recycle_bin')) {
          setState(() => _availableDirectories.add('recycle_bin'));
        }
        if (!_availableDirectories.contains('favorites')) {
          setState(() => _availableDirectories.add('favorites'));
        }
      }

      // 分页加载：单次最多 _mediaLoadBatchSize 条，避免大目录内存压力
      final offset = append ? _mediaItemsLoadOffset : 0;
      final items = await _databaseService.getMediaItems(
        _currentDirectory,
        limit: _mediaLoadBatchSize,
        offset: offset,
      );
      final total = await _databaseService.getMediaItemCount(_currentDirectory);
      final hasMore = offset + items.length < total;
      debugPrint(
        '从目录 $_currentDirectory 加载了 ${items.length} 个项目 (offset=$offset, total=$total, hasMore=$hasMore)',
      );

      // 复用数据库中已存在的缩略图路径，避免页面重进后重复生成。
      for (final item in items) {
        final typeIndex = item['type'] as int? ?? 0;
        if (typeIndex != MediaType.video.index) continue;
        final videoPath = item['path']?.toString() ?? '';
        final thumbPath = item['thumbnail_path']?.toString();
        if (videoPath.isEmpty || thumbPath == null || thumbPath.isEmpty) {
          continue;
        }
        final thumbFile = File(thumbPath);
        if (await thumbFile.exists() && await thumbFile.length() > 100) {
          _videoThumbnailFileCache[videoPath] = thumbFile;
          _thumbnailGenerationFailed.remove(videoPath);
        }
      }

      // 路径修复：跨设备导入后 path 可能指向旧设备，若文件不存在则尝试 media 目录按文件名查找
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDirPath = path.join(appDir.path, 'media');
      final toRepair = <Map<String, dynamic>>[];
      for (var item in items) {
        final id = item['id']?.toString();
        if (id == null || id == 'recycle_bin' || id == 'favorites') continue;
        final typeIndex = item['type'] as int? ?? 0;
        if (typeIndex == MediaType.folder.index) continue;
        final oldPath = item['path']?.toString();
        if (oldPath == null || oldPath.isEmpty) continue;
        toRepair.add(item);
      }
      // 批量检查并修复，每批 30 个并行，避免超大量数据时阻塞
      const batchSize = 30;
      for (var i = 0; i < toRepair.length; i += batchSize) {
        final batch = toRepair.skip(i).take(batchSize).toList();
        final checks = await Future.wait(
          batch.map((item) async {
            final oldPath = item['path']?.toString() ?? '';
            final file = File(oldPath);
            if (await file.exists()) return null;
            final fileName = path.basename(oldPath);
            final candidatePath = path.join(mediaDirPath, fileName);
            if (await File(candidatePath).exists())
              return (item, candidatePath);
            return null;
          }),
        );
        for (var r in checks) {
          if (r != null) {
            await _databaseService.updateMediaItemPath(
              r.$1['id'] as String,
              r.$2,
            );
            r.$1['path'] = r.$2;
            debugPrint('路径已修复: ${r.$1['id']} -> ${r.$2}');
          }
        }
      }

      // 更新状态
      final newMediaItems =
          items.map((item) => MediaItem.fromMap(item)).toList();
      final validVideoPaths =
          newMediaItems
              .where((i) => i.type == MediaType.video)
              .map((i) => i.path)
              .toSet();
      _videoThumbnailFutureCache.removeWhere(
        (videoPath, _) => !validVideoPaths.contains(videoPath),
      );
      _videoThumbnailFileCache.removeWhere(
        (videoPath, _) => !validVideoPaths.contains(videoPath),
      );
      _thumbnailGenerationFailed.removeWhere(
        (videoPath) => !validVideoPaths.contains(videoPath),
      );
      final validImagePaths =
          newMediaItems
              .where((i) => i.type == MediaType.image)
              .map((i) => i.path)
              .toSet();
      _imageThumbnailPrefetching.removeWhere(
        (imagePath) => !validImagePaths.contains(imagePath),
      );
      if (!append) {
        _thumbnailPrefetchQueue.clear();
        _thumbnailPrefetchQueued.clear();
      }

      setState(() {
        if (append) {
          _mediaItems.addAll(newMediaItems);
          _isLoadingMore = false;
        } else {
          _mediaItems.clear();
          _mediaItems.addAll(newMediaItems);
          _isLoading = false;
        }
        _hasMoreMediaItems = hasMore;
        _mediaItemsLoadOffset = offset + items.length;
        // 图片/视频数量：从当前已加载列表统计
        _imageCount =
            _mediaItems.where((i) => i.type == MediaType.image).length;
        _videoCount =
            _mediaItems.where((i) => i.type == MediaType.video).length;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scheduleThumbnailPrefetch(includeBackground: true);
        if (_lastImportCompletedAt != null &&
            DateTime.now().difference(_lastImportCompletedAt!) <
                const Duration(minutes: 2)) {
          unawaited(_warmCurrentDirectoryVideoThumbnailsInBackground());
        }
      });
      debugPrint(
        '当前已加载 ${_mediaItems.length} 项，其中 $_imageCount 张图片、$_videoCount 个视频',
      );
    } catch (e) {
      debugPrint('加载媒体项时出错: $e');
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('加载媒体文件时出错。请重试。')));
      }
    }
  }

  void _handleGridScroll() {
    if (!_gridScrollController.hasClients || _isLoading) return;
    _scheduleThumbnailPrefetch(includeBackground: false);
  }

  void _scheduleThumbnailPrefetch({required bool includeBackground}) {
    _thumbnailPrefetchDebounce?.cancel();
    _thumbnailPrefetchDebounce = Timer(
      includeBackground
          ? const Duration(milliseconds: 30)
          : const Duration(milliseconds: 120),
      () {
        if (!mounted || _mediaItems.isEmpty) return;
        unawaited(
          _prefetchVisibleThumbnails(includeBackground: includeBackground),
        );
      },
    );
  }

  Future<void> _prefetchVisibleThumbnails({
    required bool includeBackground,
  }) async {
    final range = _computeVisibleItemRange();
    if (range == null) return;

    final visibleItems = _mediaItems
        .skip(range.$1)
        .take(range.$2 - range.$1 + 1)
        .toList(growable: false);
    _primeImageThumbnails(visibleItems);
    _enqueueVideoThumbnailPrefetch(visibleItems, prioritize: true);

    if (includeBackground) {
      final backgroundItems = <MediaItem>[];
      for (
        int i = range.$2 + 1;
        i < _mediaItems.length &&
            backgroundItems.length < _thumbnailBackgroundBatchSize;
        i++
      ) {
        backgroundItems.add(_mediaItems[i]);
      }
      if (backgroundItems.length < _thumbnailBackgroundBatchSize) {
        for (
          int i = 0;
          i < range.$1 &&
              backgroundItems.length < _thumbnailBackgroundBatchSize;
          i++
        ) {
          backgroundItems.add(_mediaItems[i]);
        }
      }
      _primeImageThumbnails(backgroundItems);
      _enqueueVideoThumbnailPrefetch(backgroundItems, prioritize: false);
    }

    unawaited(_drainThumbnailPrefetchQueue());
  }

  (int, int)? _computeVisibleItemRange() {
    if (_mediaItems.isEmpty) return null;

    final viewportWidth =
        _gridContainerKey.currentContext?.size?.width ??
        MediaQuery.of(context).size.width;
    final viewportHeight =
        _gridScrollController.hasClients
            ? _gridScrollController.position.viewportDimension
            : MediaQuery.of(context).size.height;
    if (viewportWidth <= 0 || viewportHeight <= 0) return null;

    final tileWidth =
        (viewportWidth -
            (_gridPadding * 2) -
            (_gridCrossAxisSpacing * (_gridCrossAxisCount - 1))) /
        _gridCrossAxisCount;
    if (tileWidth <= 0) return null;
    final tileHeight =
        (tileWidth / _gridChildAspectRatio) + _gridMainAxisSpacing;
    final scrollOffset =
        _gridScrollController.hasClients ? _gridScrollController.offset : 0.0;

    final startRow = math.max(
      0,
      (scrollOffset / tileHeight).floor() -
          _thumbnailVisiblePrefetchPaddingRows,
    );
    final endRow = math.max(
      startRow,
      ((scrollOffset + viewportHeight) / tileHeight).ceil() +
          _thumbnailVisiblePrefetchPaddingRows,
    );
    final startIndex = math.max(0, startRow * _gridCrossAxisCount);
    final endIndex = math.min(
      _mediaItems.length - 1,
      ((endRow + 1) * _gridCrossAxisCount) - 1,
    );
    return (startIndex, endIndex);
  }

  void _primeImageThumbnails(Iterable<MediaItem> items) {
    for (final item in items) {
      if (item.type != MediaType.image || item.path.isEmpty) continue;
      if (_imageThumbnailPrefetching.contains(item.path)) continue;
      _imageThumbnailPrefetching.add(item.path);
      final provider = _buildImageThumbnailProvider(item.path);
      unawaited(
        precacheImage(provider, context).catchError((_) {}).whenComplete(() {
          _imageThumbnailPrefetching.remove(item.path);
        }),
      );
    }
  }

  void _enqueueVideoThumbnailPrefetch(
    Iterable<MediaItem> items, {
    required bool prioritize,
  }) {
    for (final item in items) {
      if (item.type != MediaType.video || item.path.isEmpty) continue;
      if (_videoThumbnailFileCache.containsKey(item.path)) continue;
      if (_thumbnailGenerationFailed.contains(item.path)) continue;
      if (_thumbnailPrefetchQueued.contains(item.path)) continue;
      if (_videoThumbnailFutureCache.containsKey(item.path)) continue;

      if (prioritize) {
        _thumbnailPrefetchQueue.addFirst(item.path);
      } else {
        _thumbnailPrefetchQueue.addLast(item.path);
      }
      _thumbnailPrefetchQueued.add(item.path);
    }

    while (_thumbnailPrefetchQueue.length > _thumbnailQueueTrimSize) {
      final removed = _thumbnailPrefetchQueue.removeLast();
      _thumbnailPrefetchQueued.remove(removed);
    }
  }

  void _enqueueVideoThumbnailPaths(
    Iterable<String> videoPaths, {
    required bool prioritize,
  }) {
    for (final videoPath in videoPaths) {
      if (videoPath.isEmpty) continue;
      if (_videoThumbnailFileCache.containsKey(videoPath)) continue;
      if (_thumbnailGenerationFailed.contains(videoPath)) continue;
      if (_thumbnailPrefetchQueued.contains(videoPath)) continue;
      if (_videoThumbnailFutureCache.containsKey(videoPath)) continue;
      if (prioritize) {
        _thumbnailPrefetchQueue.addFirst(videoPath);
      } else {
        _thumbnailPrefetchQueue.addLast(videoPath);
      }
      _thumbnailPrefetchQueued.add(videoPath);
    }
    while (_thumbnailPrefetchQueue.length > _thumbnailQueueTrimSize) {
      final removed = _thumbnailPrefetchQueue.removeLast();
      _thumbnailPrefetchQueued.remove(removed);
    }
  }

  Future<void> _drainThumbnailPrefetchQueue() async {
    if (_isThumbnailPrefetchRunning) return;
    _isThumbnailPrefetchRunning = true;
    try {
      int processed = 0;
      while (mounted &&
          _thumbnailPrefetchQueue.isNotEmpty &&
          processed < _thumbnailPrefetchChunkPerRun) {
        final videoPath = _thumbnailPrefetchQueue.removeFirst();
        _thumbnailPrefetchQueued.remove(videoPath);
        if (_videoThumbnailFileCache.containsKey(videoPath) ||
            _thumbnailGenerationFailed.contains(videoPath)) {
          continue;
        }
        await _getOrCreateVideoThumbnailFuture(videoPath);
        processed++;
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
    } finally {
      _isThumbnailPrefetchRunning = false;
      if (mounted && _thumbnailPrefetchQueue.isNotEmpty) {
        _thumbnailPrefetchDebounce?.cancel();
        _thumbnailPrefetchDebounce = Timer(
          const Duration(milliseconds: 80),
          () => unawaited(_drainThumbnailPrefetchQueue()),
        );
      }
    }
  }

  Future<bool> _checkFolderNameExists(String folderName) async {
    final items = await _databaseService.getMediaItems(_currentDirectory);
    return items.any((item) {
      final typeIndex = item['type'] as int;
      if (typeIndex >= MediaType.values.length) return false;
      return item['name'] == folderName &&
          MediaType.values[typeIndex] == MediaType.folder;
    });
  }

  Future<void> _createFolder(String folderName) async {
    try {
      if (await _checkFolderNameExists(folderName)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件夹 "$folderName" 已存在，请使用其他名称')),
          );
        }
        return;
      }

      final uuid = const Uuid().v4();
      final mediaItem = MediaItem(
        id: uuid,
        name: folderName,
        path: '',
        type: MediaType.folder,
        directory: _currentDirectory,
        dateAdded: DateTime.now(),
      );
      await _databaseService.insertMediaItem(mediaItem.toMap());
      await _loadMediaItems();
    } catch (e) {
      debugPrint('创建文件夹时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('创建文件夹时出错: $e')));
      }
    }
  }

  void _showCreateFolderDialog() {
    showDialog(
      context: context,
      builder:
          (context) => CreateFolderDialog(
            onCreate: (name) {
              _createFolder(name);
            },
          ),
    );
  }

  Future<List<(File, MediaType)>> _pickMultipleMedia() async {
    try {
      debugPrint('开始加载媒体文件（图片+视频）...');
      final List<AssetPathEntity> paths =
          await getMergedAlbumPathListForImport();
      debugPrint('找到 ${paths.length} 个媒体路径（已合并相册列表）');
      if (paths.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到媒体文件，请确保设备上有图片或视频并检查权限。')),
          );
        }
        return [];
      }

      if (!mounted) return [];
      final selected = await showDialog<List<AssetEntity>?>(
        context: context,
        builder: (context) => _BatchMediaSelectionDialog(albums: paths),
      );
      if (selected == null || selected.isEmpty) return [];

      final List<(File, MediaType)> result = [];
      for (final asset in selected) {
        final file = await asset.file;
        if (file != null) {
          final mediaType =
              asset.type == AssetType.image ? MediaType.image : MediaType.video;
          result.add((file, mediaType));
        }
      }
      return result;
    } catch (e) {
      debugPrint('选择媒体时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载媒体文件时出错: $e')));
      }
      return [];
    }
  }

  Future<List<File>> _pickMultipleImages() async {
    try {
      debugPrint('开始加载图片文件...');
      final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
      );
      debugPrint('找到 ${paths.length} 个图片路径');
      if (paths.isEmpty) {
        final picker = ImagePicker();
        final pickedFiles = await picker.pickMultiImage();
        return pickedFiles.map((xFile) => File(xFile.path)).toList();
      }

      List<AssetEntity> allImages = [];
      Set<String> imageIds = {};
      for (var path in paths) {
        final assets = await path.getAssetListRange(start: 0, end: 100000);
        for (var asset in assets) {
          if (!imageIds.contains(asset.id)) {
            allImages.add(asset);
            imageIds.add(asset.id);
          }
        }
      }
      allImages.sort((a, b) {
        final aDate = a.createDateTime;
        final bDate = b.createDateTime;
        if (aDate == null && bDate == null) return 0;
        if (aDate == null) return 1;
        if (bDate == null) return -1;
        return bDate.compareTo(aDate);
      });

      debugPrint('总共找到 ${allImages.length} 个唯一图片（按时间从新到旧）');
      List<AssetEntity> selectedImages = await _showImageSelectionDialog(
        allImages,
      );
      if (selectedImages.isEmpty) return [];

      List<File> imageFiles = [];
      for (var asset in selectedImages) {
        final file = await asset.file;
        if (file != null) imageFiles.add(file);
      }
      return imageFiles;
    } catch (e) {
      debugPrint('选择图片时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载图片时出错: $e')));
      }
      return [];
    }
  }

  Future<List<AssetEntity>> _showImageSelectionDialog(
    List<AssetEntity> images,
  ) async {
    List<AssetEntity> selected = [];
    bool isSelecting = false;
    bool isDragSelecting = false;
    (int, int)? dragStartColRow;
    bool dragIsDeselectMode = false;
    Offset? dragStartPosition;
    bool hasDragMoved = false;
    String? gestureCommitted;
    double scrollOffsetBeforeGesture = 0;
    final gridKey = GlobalKey();
    final scrollController = ScrollController();
    final screenSize = MediaQuery.of(context).size;
    const int crossAxisCount = 4;
    const double childAspectRatio = 1;
    const double crossAxisSpacing = 4;
    const double mainAxisSpacing = 4;
    const double padding = 4;
    const double dragThreshold = 8;

    (int, int)? getGridColRow(Offset globalPosition) {
      final box = gridKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return null;
      final local = box.globalToLocal(globalPosition);
      final w = box.size.width - padding * 2;
      final cellWidth =
          (w - (crossAxisCount - 1) * crossAxisSpacing) / crossAxisCount;
      final cellHeight = cellWidth / childAspectRatio;
      final contentX = local.dx - padding;
      final contentY = local.dy - padding + scrollController.offset;
      if (contentX < 0 || contentY < 0) return null;
      final col = (contentX / (cellWidth + crossAxisSpacing)).floor().clamp(
        0,
        crossAxisCount - 1,
      );
      final row = (contentY / (cellHeight + mainAxisSpacing)).floor().clamp(
        0,
        999999,
      );
      return (col, row);
    }

    List<int> getIndicesInRectangle(
      int startCol,
      int startRow,
      int endCol,
      int endRow,
    ) {
      final minCol = startCol < endCol ? startCol : endCol;
      final maxCol = startCol > endCol ? startCol : endCol;
      final minRow = startRow < endRow ? startRow : endRow;
      final maxRow = startRow > endRow ? startRow : endRow;
      final list = <int>[];
      for (int r = minRow; r <= maxRow; r++) {
        for (int c = minCol; c <= maxCol; c++) {
          list.add(r * crossAxisCount + c);
        }
      }
      return list;
    }

    await showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => Dialog(
                  insetPadding: EdgeInsets.zero,
                  child: SizedBox(
                    width: screenSize.width,
                    height: screenSize.height * 0.9,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text(
                            '选择图片（按时间从新到旧）',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Listener(
                            key: gridKey,
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: (e) {
                              scrollOffsetBeforeGesture =
                                  scrollController.offset;
                              gestureCommitted = null;
                              final startCr = getGridColRow(e.position);
                              if (startCr != null) {
                                final startIdx =
                                    startCr.$2 * crossAxisCount + startCr.$1;
                                if (startIdx >= 0 && startIdx < images.length) {
                                  final asset = images[startIdx];
                                  hasDragMoved = false;
                                  dragStartPosition = e.position;
                                  dragStartColRow = startCr;
                                  dragIsDeselectMode = selected.contains(asset);
                                }
                              }
                            },
                            onPointerMove: (e) {
                              if (dragStartColRow != null &&
                                  dragStartPosition != null) {
                                final dx =
                                    e.position.dx - dragStartPosition!.dx;
                                final dy =
                                    e.position.dy - dragStartPosition!.dy;
                                if (gestureCommitted == null) {
                                  final dist = math.sqrt(dx * dx + dy * dy);
                                  if (dist > dragThreshold) {
                                    if (dx.abs() > dy.abs()) {
                                      gestureCommitted = 'selection';
                                      isDragSelecting = true;
                                      hasDragMoved = true;
                                      setDialogState(() {});
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                            if (scrollController.hasClients) {
                                              scrollController.jumpTo(
                                                scrollOffsetBeforeGesture,
                                              );
                                            }
                                          });
                                    } else {
                                      gestureCommitted = 'scroll';
                                    }
                                  }
                                }
                              }
                              if (isDragSelecting && dragStartColRow != null) {
                                if (!hasDragMoved) {
                                  final dx =
                                      e.position.dx -
                                      (dragStartPosition?.dx ?? 0);
                                  final dy =
                                      e.position.dy -
                                      (dragStartPosition?.dy ?? 0);
                                  final dist = math.sqrt(dx * dx + dy * dy);
                                  if (dist < dragThreshold) return;
                                  hasDragMoved = true;
                                }
                                final curCr = getGridColRow(e.position);
                                if (curCr != null) {
                                  final indices = getIndicesInRectangle(
                                    dragStartColRow!.$1,
                                    dragStartColRow!.$2,
                                    curCr.$1,
                                    curCr.$2,
                                  );
                                  setDialogState(() {
                                    for (final idx in indices) {
                                      if (idx >= 0 && idx < images.length) {
                                        final asset = images[idx];
                                        if (dragIsDeselectMode) {
                                          selected.remove(asset);
                                        } else if (!selected.contains(asset)) {
                                          selected.add(asset);
                                        }
                                      }
                                    }
                                  });
                                }
                              }
                            },
                            onPointerUp: (_) {
                              if (isDragSelecting) {
                                isDragSelecting = false;
                                gestureCommitted = null;
                                setDialogState(() {});
                              } else {
                                gestureCommitted = null;
                              }
                            },
                            onPointerCancel: (_) {
                              if (isDragSelecting) {
                                isDragSelecting = false;
                                gestureCommitted = null;
                                setDialogState(() {});
                              } else {
                                gestureCommitted = null;
                              }
                            },
                            child: Builder(
                              builder:
                                  (ctx) => ScrollConfiguration(
                                    behavior: ScrollConfiguration.of(
                                      ctx,
                                    ).copyWith(
                                      physics:
                                          isDragSelecting
                                              ? const NeverScrollableScrollPhysics()
                                              : const ClampingScrollPhysics(),
                                    ),
                                    child: GridView.builder(
                                      controller: scrollController,
                                      padding: const EdgeInsets.all(4.0),
                                      gridDelegate:
                                          const SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 4,
                                            childAspectRatio: 1,
                                            crossAxisSpacing: 4,
                                            mainAxisSpacing: 4,
                                          ),
                                      itemCount: images.length,
                                      itemBuilder: (context, index) {
                                        final image = images[index];
                                        final isSelected = selected.contains(
                                          image,
                                        );
                                        return GestureDetector(
                                          onTap: () {
                                            setDialogState(() {
                                              if (isSelected) {
                                                selected.remove(image);
                                              } else {
                                                selected.add(image);
                                              }
                                            });
                                          },
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              FutureBuilder<Uint8List?>(
                                                future: image
                                                    .thumbnailDataWithSize(
                                                      const ThumbnailSize(
                                                        200,
                                                        200,
                                                      ),
                                                    ),
                                                builder: (context, snapshot) {
                                                  if (snapshot.hasData &&
                                                      snapshot.data != null) {
                                                    return Image.memory(
                                                      snapshot.data!,
                                                      fit: BoxFit.cover,
                                                      width: double.infinity,
                                                      height: double.infinity,
                                                    );
                                                  }
                                                  return const Center(
                                                    child:
                                                        CircularProgressIndicator(),
                                                  );
                                                },
                                              ),
                                              if (isSelected)
                                                const Positioned(
                                                  top: 4,
                                                  right: 4,
                                                  child: Icon(
                                                    Icons.check_circle,
                                                    color: Colors.green,
                                                    size: 24,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () {
                                  isSelecting = true;
                                  Navigator.pop(context);
                                },
                                child: const Text('确定'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ),
    );

    return isSelecting ? selected : [];
  }

  Future<List<File>> _pickMultipleVideos() async {
    try {
      debugPrint('开始加载视频文件...');
      final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
        type: RequestType.video,
      );
      debugPrint('找到 ${paths.length} 个视频路径');
      if (paths.isEmpty) {
        // 如果 photo_manager 失败，尝试使用 file_picker 作为备用
        FilePickerResult? result = await FilePicker.platform.pickFiles(
          type: FileType.video,
          allowMultiple: true,
        );
        if (result == null || result.files.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('未找到视频文件，请确保设备上有视频或检查权限。')),
            );
          }
          return [];
        }
        return result.files
            .where((f) => f.path != null && f.path!.isNotEmpty)
            .map((f) => File(f.path!))
            .toList();
      }

      List<AssetEntity> allVideos = [];
      Set<String> videoIds = {};
      for (var path in paths) {
        final assets = await path.getAssetListRange(start: 0, end: 100000);
        debugPrint('路径 ${path.name} 中找到 ${assets.length} 个视频资产');
        for (var asset in assets) {
          if (!videoIds.contains(asset.id)) {
            allVideos.add(asset);
            videoIds.add(asset.id);
          }
        }
      }

      debugPrint('总共找到 ${allVideos.length} 个唯一视频');

      List<AssetEntity> selectedVideos = await _showVideoSelectionDialog(
        allVideos,
      );
      debugPrint('用户选择了 ${selectedVideos.length} 个视频');
      if (selectedVideos.isEmpty) return [];

      List<File> videoFiles = [];
      for (var asset in selectedVideos) {
        final file = await asset.file;
        if (file != null) {
          debugPrint('成功加载视频文件: ${file.path}');
          videoFiles.add(file);
        } else {
          debugPrint('无法加载视频文件: ${asset.id}');
        }
      }

      debugPrint('最终返回 ${videoFiles.length} 个视频文件');
      return videoFiles;
    } catch (e) {
      debugPrint('选择视频时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载视频文件时出错: $e')));
      }
      return [];
    }
  }

  Future<List<AssetEntity>> _showVideoSelectionDialog(
    List<AssetEntity> videos,
  ) async {
    List<AssetEntity> selected = [];
    bool isSelecting = false;
    bool isDragSelecting = false;
    (int, int)? dragStartColRow;
    bool dragIsDeselectMode = false;
    Offset? dragStartPosition;
    bool hasDragMoved = false;
    String? gestureCommitted;
    double scrollOffsetBeforeGesture = 0;
    final gridKey = GlobalKey();
    final scrollController = ScrollController();
    final screenSize = MediaQuery.of(context).size;
    const int crossAxisCount = 4;
    const double childAspectRatio = 1;
    const double crossAxisSpacing = 4;
    const double mainAxisSpacing = 4;
    const double padding = 4;
    const double dragThreshold = 8;

    (int, int)? getGridColRow(Offset globalPosition) {
      final box = gridKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return null;
      final local = box.globalToLocal(globalPosition);
      final w = box.size.width - padding * 2;
      final cellWidth =
          (w - (crossAxisCount - 1) * crossAxisSpacing) / crossAxisCount;
      final cellHeight = cellWidth / childAspectRatio;
      final contentX = local.dx - padding;
      final contentY = local.dy - padding + scrollController.offset;
      if (contentX < 0 || contentY < 0) return null;
      final col = (contentX / (cellWidth + crossAxisSpacing)).floor().clamp(
        0,
        crossAxisCount - 1,
      );
      final row = (contentY / (cellHeight + mainAxisSpacing)).floor().clamp(
        0,
        999999,
      );
      return (col, row);
    }

    List<int> getIndicesInRectangle(
      int startCol,
      int startRow,
      int endCol,
      int endRow,
    ) {
      final minCol = startCol < endCol ? startCol : endCol;
      final maxCol = startCol > endCol ? startCol : endCol;
      final minRow = startRow < endRow ? startRow : endRow;
      final maxRow = startRow > endRow ? startRow : endRow;
      final list = <int>[];
      for (int r = minRow; r <= maxRow; r++) {
        for (int c = minCol; c <= maxCol; c++) {
          list.add(r * crossAxisCount + c);
        }
      }
      return list;
    }

    await showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => Dialog(
                  insetPadding: EdgeInsets.zero,
                  child: SizedBox(
                    width: screenSize.width,
                    height: screenSize.height * 0.9,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text(
                            '选择视频',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Listener(
                            key: gridKey,
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: (e) {
                              scrollOffsetBeforeGesture =
                                  scrollController.offset;
                              gestureCommitted = null;
                              final startCr = getGridColRow(e.position);
                              if (startCr != null) {
                                final startIdx =
                                    startCr.$2 * crossAxisCount + startCr.$1;
                                if (startIdx >= 0 && startIdx < videos.length) {
                                  final asset = videos[startIdx];
                                  hasDragMoved = false;
                                  dragStartPosition = e.position;
                                  dragStartColRow = startCr;
                                  dragIsDeselectMode = selected.contains(asset);
                                }
                              }
                            },
                            onPointerMove: (e) {
                              if (dragStartColRow != null &&
                                  dragStartPosition != null) {
                                final dx =
                                    e.position.dx - dragStartPosition!.dx;
                                final dy =
                                    e.position.dy - dragStartPosition!.dy;
                                if (gestureCommitted == null) {
                                  final dist = math.sqrt(dx * dx + dy * dy);
                                  if (dist > dragThreshold) {
                                    if (dx.abs() > dy.abs()) {
                                      gestureCommitted = 'selection';
                                      isDragSelecting = true;
                                      hasDragMoved = true;
                                      setDialogState(() {});
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                            if (scrollController.hasClients) {
                                              scrollController.jumpTo(
                                                scrollOffsetBeforeGesture,
                                              );
                                            }
                                          });
                                    } else {
                                      gestureCommitted = 'scroll';
                                    }
                                  }
                                }
                              }
                              if (isDragSelecting && dragStartColRow != null) {
                                if (!hasDragMoved) {
                                  final dx =
                                      e.position.dx -
                                      (dragStartPosition?.dx ?? 0);
                                  final dy =
                                      e.position.dy -
                                      (dragStartPosition?.dy ?? 0);
                                  final dist = math.sqrt(dx * dx + dy * dy);
                                  if (dist < dragThreshold) return;
                                  hasDragMoved = true;
                                }
                                final curCr = getGridColRow(e.position);
                                if (curCr != null) {
                                  final indices = getIndicesInRectangle(
                                    dragStartColRow!.$1,
                                    dragStartColRow!.$2,
                                    curCr.$1,
                                    curCr.$2,
                                  );
                                  setDialogState(() {
                                    for (final idx in indices) {
                                      if (idx >= 0 && idx < videos.length) {
                                        final asset = videos[idx];
                                        if (dragIsDeselectMode) {
                                          selected.remove(asset);
                                        } else if (!selected.contains(asset)) {
                                          selected.add(asset);
                                        }
                                      }
                                    }
                                  });
                                }
                              }
                            },
                            onPointerUp: (_) {
                              if (isDragSelecting) {
                                isDragSelecting = false;
                                gestureCommitted = null;
                                setDialogState(() {});
                              } else {
                                gestureCommitted = null;
                              }
                            },
                            onPointerCancel: (_) {
                              if (isDragSelecting) {
                                isDragSelecting = false;
                                gestureCommitted = null;
                                setDialogState(() {});
                              } else {
                                gestureCommitted = null;
                              }
                            },
                            child: Builder(
                              builder:
                                  (ctx) => ScrollConfiguration(
                                    behavior: ScrollConfiguration.of(
                                      ctx,
                                    ).copyWith(
                                      physics:
                                          isDragSelecting
                                              ? const NeverScrollableScrollPhysics()
                                              : const ClampingScrollPhysics(),
                                    ),
                                    child: GridView.builder(
                                      controller: scrollController,
                                      padding: const EdgeInsets.all(4.0),
                                      gridDelegate:
                                          const SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 4,
                                            childAspectRatio: 1,
                                            crossAxisSpacing: 4,
                                            mainAxisSpacing: 4,
                                          ),
                                      itemCount: videos.length,
                                      itemBuilder: (context, index) {
                                        final video = videos[index];
                                        final isSelected = selected.contains(
                                          video,
                                        );
                                        return GestureDetector(
                                          onTap: () {
                                            setDialogState(() {
                                              if (isSelected) {
                                                selected.remove(video);
                                              } else {
                                                selected.add(video);
                                              }
                                            });
                                          },
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              FutureBuilder<Uint8List?>(
                                                future: video
                                                    .thumbnailDataWithSize(
                                                      const ThumbnailSize(
                                                        200,
                                                        200,
                                                      ),
                                                    ),
                                                builder: (context, snapshot) {
                                                  if (snapshot.hasData &&
                                                      snapshot.data != null) {
                                                    return Image.memory(
                                                      snapshot.data!,
                                                      fit: BoxFit.cover,
                                                      width: double.infinity,
                                                      height: double.infinity,
                                                    );
                                                  }
                                                  return const Center(
                                                    child:
                                                        CircularProgressIndicator(),
                                                  );
                                                },
                                              ),
                                              if (isSelected)
                                                const Positioned(
                                                  top: 4,
                                                  right: 4,
                                                  child: Icon(
                                                    Icons.check_circle,
                                                    color: Colors.green,
                                                    size: 24,
                                                  ),
                                                ),
                                              Positioned(
                                                bottom: 4,
                                                left: 4,
                                                child: Container(
                                                  color: Colors.black54,
                                                  padding: const EdgeInsets.all(
                                                    2,
                                                  ),
                                                  child: Text(
                                                    _formatDuration(
                                                      Duration(
                                                        seconds: video.duration,
                                                      ),
                                                    ),
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () {
                                  isSelecting = true;
                                  Navigator.pop(context);
                                },
                                child: const Text('确定'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ),
    );

    return isSelecting ? selected : [];
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  /// 计算文件 MD5 哈希，大文件使用流式避免 OOM（支持数 GB 级视频）
  Future<String> _calculateFileHash(File file) async {
    try {
      final digest = await md5.bind(file.openRead()).first;
      return digest.toString();
    } catch (e) {
      debugPrint('计算文件哈希值时出错: $e');
      return '';
    }
  }

  Future<void> _saveMultipleMediaToAppDirectory(
    List<File> sourceFiles,
    MediaType type, {
    bool silent = false,
  }) async {
    final items = sourceFiles.map((f) => (f, type)).toList();
    await _saveMultipleMediaWithTypes(items, silent: silent);
  }

  Future<void> _saveMultipleMediaWithTypes(
    List<(File, MediaType)> items, {
    bool silent = false,
  }) async {
    if (items.isEmpty) return;

    final showUi = !silent;
    ValueNotifier<bool>? cancelRef;
    ValueNotifier<double>? progRef;
    ValueNotifier<String>? msgRef;
    if (showUi) {
      cancelRef = ValueNotifier(false);
      progRef = ValueNotifier(0.0);
      msgRef = ValueNotifier('准备导入…');
      showCancellableProgressDialog(
        context,
        progress: progRef,
        message: msgRef,
        cancelRequested: cancelRef,
        title: '导入媒体',
      );
    }

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

      int importedCount = 0;
      int skippedCount = 0;
      final importedVideoPaths = <String>[];

      final total = items.length;
      for (var index = 0; index < items.length; index++) {
        if (showUi && cancelRef!.value) {
          msgRef!.value = '正在停止…';
          break;
        }
        final item = items[index];
        final sourceFile = item.$1;
        final type = item.$2;
        final fileName = path.basename(sourceFile.path);
        if (showUi) {
          msgRef!.value = '(${index + 1}/$total) $fileName\n正在计算哈希…';
          progRef!.value = index / math.max(total, 1);
        }
        final fileHash = await _calculateFileHash(sourceFile);
        // 无法计算哈希时跳过，避免无法查重导致重复导入
        if (fileHash.isEmpty) {
          debugPrint('无法计算文件哈希，跳过导入: $fileName');
          skippedCount++;
          if (showUi) progRef!.value = (index + 1) / math.max(total, 1);
          continue;
        }

        // 检查是否存在重复文件（file_hash 优先，可识别同内容不同文件名）
        final duplicate = await _databaseService.findDuplicateMediaItem(
          fileHash,
          fileName,
        );
        if (duplicate != null) {
          debugPrint('发现重复文件: ${duplicate['name']}');
          skippedCount++;
          if (showUi) progRef!.value = (index + 1) / math.max(total, 1);
          continue;
        }

        final uuid = const Uuid().v4();
        final extension = path.extension(sourceFile.path);
        final destinationPath = '${mediaDir.path}/$uuid$extension';
        if (showUi) {
          msgRef!.value = '(${index + 1}/$total) $fileName\n正在复制到应用目录…';
        }
        await sourceFile.copy(destinationPath);

        // 插入前再次查重，防止并发导入时的竞态
        final duplicateBeforeInsert = await _databaseService
            .findDuplicateMediaItem(fileHash, fileName);
        if (duplicateBeforeInsert != null) {
          try {
            await File(destinationPath).delete();
          } catch (_) {}
          debugPrint('插入前发现重复，已跳过: $fileName');
          skippedCount++;
          if (showUi) progRef!.value = (index + 1) / math.max(total, 1);
          continue;
        }

        final mediaItem = MediaItem(
          id: uuid,
          name: fileName,
          path: destinationPath,
          type: type,
          directory: _currentDirectory,
          dateAdded: DateTime.now(),
        );

        // 将文件哈希值添加到数据库记录中
        final mediaItemMap = mediaItem.toMap();
        mediaItemMap['file_hash'] = fileHash;

        await _databaseService.insertMediaItem(mediaItemMap);
        importedCount++;
        if (type == MediaType.video) {
          importedVideoPaths.add(destinationPath);
        }
        if (showUi) progRef!.value = (index + 1) / math.max(total, 1);
      }

      if (mounted) {
        if (!silent) Navigator.of(context).pop();
        await _loadMediaItems();
        if (importedVideoPaths.isNotEmpty) {
          _enqueueVideoThumbnailPaths(importedVideoPaths, prioritize: true);
          unawaited(_drainThumbnailPrefetchQueue());
        }
        if (!silent) {
          final cancelled = showUi && (cancelRef?.value ?? false);
          final parts = <String>[];
          if (importedCount > 0) parts.add('成功导入 $importedCount 个');
          if (skippedCount > 0) {
            parts.add(
              cancelled ? '已跳过 $skippedCount 个' : '因重复跳过 $skippedCount 个',
            );
          }
          final msg =
              cancelled
                  ? (parts.isEmpty ? '导入已取消' : '导入已取消：${parts.join('，')}')
                  : (parts.isEmpty
                      ? '无新文件导入（全部为重复）'
                      : '导入完成：${parts.join('，')}');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        if (!silent) Navigator.of(context).pop();
        debugPrint('批量导入媒体时出错: $e');
        if (!silent) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('导入媒体文件时出错: $e')));
        }
      }
    }
  }

  String _getMediaTypeName(MediaType type) {
    switch (type) {
      case MediaType.image:
        return '图片';
      case MediaType.video:
        return '视频';
      case MediaType.audio:
        return '音频';

      case MediaType.folder:
        return '文件夹';
    }
  }

  Future<void> _deleteMediaItem(MediaItem item) async {
    final shouldDelete =
        await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                title: const Text('删除媒体'),
                content: Text('确定要删除 "${item.name}" 吗？此操作不可撤销。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text(
                      '删除',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
        ) ??
        false;

    if (shouldDelete) {
      try {
        // 使用文件清理服务彻底删除文件
        final fileCleanupService = getService<FileCleanupService>();
        if (fileCleanupService.isInitialized) {
          await fileCleanupService.deleteMediaFileCompletely(item.path);
        } else {
          // 如果清理服务未初始化，使用传统方法删除
          final file = File(item.path);
          if (await file.exists()) await file.delete();
        }

        // 从数据库中删除
        await _databaseService.deleteMediaItem(item.id);

        await _loadMediaItems();
        _invalidMediaRetryCounts.remove(item.id);
        _invalidMediaRetryCounts.remove(item.id);
      } catch (e) {
        debugPrint('删除媒体项时出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('删除媒体项时出错: $e')));
        }
      }
    }
  }

  Future<void> _renameMediaItem(MediaItem item) async {
    TextEditingController renameController = TextEditingController(
      text: item.name,
    );

    final newName = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('重命名'),
            content: TextField(
              controller: renameController,
              decoration: const InputDecoration(
                labelText: '新名称',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  final name = renameController.text.trim();
                  if (name.isNotEmpty) {
                    Navigator.pop(context, name);
                  }
                },
                child: const Text('确定'),
              ),
            ],
          ),
    );

    if (newName != null && newName.isNotEmpty && newName != item.name) {
      try {
        final items = await _databaseService.getMediaItems(_currentDirectory);
        if (items.any(
          (existingItem) =>
              existingItem['name'] == newName && existingItem['id'] != item.id,
        )) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('名称 "$newName" 已存在，请使用其他名称')),
            );
          }
          return;
        }

        final updatedItem = MediaItem(
          id: item.id,
          name: newName,
          path: item.path,
          type: item.type,
          directory: item.directory,
          dateAdded: item.dateAdded,
        );
        await _databaseService.updateMediaItem(updatedItem.toMap());
        await _loadMediaItems();
        if (mounted) {}
      } catch (e) {
        debugPrint('重命名媒体项时出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('重命名时出错: $e')));
        }
      }
    }
  }

  String _formatPropertyBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 略缩图菜单「属性」：导入时间、大小、格式等。
  Future<void> _showMediaItemProperties(MediaItem item) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('属性'),
          content: SizedBox(
            width: double.maxFinite,
            child: FutureBuilder<Map<String, String>>(
              future: _collectMediaItemProperties(item),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final rows = snapshot.data ?? {};
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final e in rows.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 88,
                                child: Text(
                                  e.key,
                                  style: TextStyle(
                                    color: Colors.grey[700],
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              Expanded(
                                child:
                                    e.key == '存储路径'
                                        ? SelectableText(
                                          e.value,
                                          style: const TextStyle(fontSize: 13),
                                        )
                                        : Text(
                                          e.value,
                                          style: const TextStyle(fontSize: 14),
                                        ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<Map<String, String>> _collectMediaItemProperties(
    MediaItem item,
  ) async {
    final df = DateFormat('yyyy-MM-dd HH:mm:ss');

    Future<String> locationLabel() async {
      if (item.directory == 'root') return '根目录';
      final parentRow = await _databaseService.getMediaItemById(item.directory);
      if (parentRow != null) {
        final n = parentRow['name'] as String?;
        if (n != null && n.isNotEmpty) return n;
      }
      return item.directory;
    }

    if (item.type == MediaType.folder) {
      final loc = await locationLabel();
      final stats = await _collectFolderPropertiesStats(item.id);
      final ordered = <String, String>{'名称': item.name, '类型': '文件夹'};
      try {
        ordered['当前层级项数'] = '${stats.directChildCount}';
        ordered['总项数(含子级)'] = '${stats.totalItems}';
        ordered['文件数量(含子级)'] = '${stats.fileCount}';
        ordered['子文件夹数量(含子级)'] = '${stats.subFolderCount}';
        ordered['总大小'] = _formatPropertyBytes(stats.totalBytes);
        if (stats.missingOrUnreadableFiles > 0) {
          ordered['异常文件'] = '${stats.missingOrUnreadableFiles} (缺失/不可读)';
        }
      } catch (_) {
        ordered['当前层级项数'] = '—';
        ordered['总项数(含子级)'] = '—';
        ordered['文件数量(含子级)'] = '—';
        ordered['子文件夹数量(含子级)'] = '—';
        ordered['总大小'] = '—';
      }
      ordered['导入时间'] = df.format(item.dateAdded);
      ordered['所在位置'] = loc;
      if (item.path.isNotEmpty) {
        ordered['存储路径'] = item.path;
      }
      return ordered;
    }

    final ext = path.extension(item.name).toLowerCase();
    final fmt = ext.isEmpty ? '无扩展名' : ext.replaceFirst('.', '').toUpperCase();
    String sizeText = '—';
    String? modifiedText;
    try {
      final f = File(item.path);
      if (await f.exists()) {
        sizeText = _formatPropertyBytes(await f.length());
        modifiedText = df.format((await f.stat()).modified);
      } else {
        sizeText = '文件不存在或已被移动';
      }
    } catch (_) {
      sizeText = '无法读取';
    }

    final loc = await locationLabel();
    return <String, String>{
      '名称': item.name,
      '类型': item.type == MediaType.image ? '图片' : '视频',
      '格式': fmt,
      '大小': sizeText,
      '导入时间': df.format(item.dateAdded),
      if (modifiedText != null) '修改时间': modifiedText,
      '所在位置': loc,
      if (item.path.isNotEmpty) '存储路径': item.path,
    };
  }

  Future<_FolderPropertiesStats> _collectFolderPropertiesStats(
    String rootFolderId,
  ) async {
    int directChildCount = 0;
    int totalItems = 0;
    int fileCount = 0;
    int subFolderCount = 0;
    int totalBytes = 0;
    int missingOrUnreadableFiles = 0;

    final Queue<String> pendingFolders = Queue<String>()..add(rootFolderId);
    bool isRootLevel = true;

    while (pendingFolders.isNotEmpty) {
      final currentFolderId = pendingFolders.removeFirst();
      final rows = await _databaseService.getMediaItems(currentFolderId);

      if (isRootLevel) {
        directChildCount = rows.length;
        isRootLevel = false;
      }

      for (final row in rows) {
        totalItems++;
        final type = row['type'];
        final typeIndex =
            type is int ? type : int.tryParse(type?.toString() ?? '') ?? -1;
        final isFolder = typeIndex == MediaType.folder.index;

        if (isFolder) {
          subFolderCount++;
          final childFolderId = row['id']?.toString();
          if (childFolderId != null && childFolderId.isNotEmpty) {
            pendingFolders.add(childFolderId);
          }
          continue;
        }

        fileCount++;
        final filePath = row['path']?.toString();
        if (filePath == null || filePath.isEmpty) {
          missingOrUnreadableFiles++;
          continue;
        }

        try {
          final file = File(filePath);
          if (await file.exists()) {
            totalBytes += await file.length();
          } else {
            missingOrUnreadableFiles++;
          }
        } catch (_) {
          missingOrUnreadableFiles++;
        }
      }
    }

    return _FolderPropertiesStats(
      directChildCount: directChildCount,
      totalItems: totalItems,
      fileCount: fileCount,
      subFolderCount: subFolderCount,
      totalBytes: totalBytes,
      missingOrUnreadableFiles: missingOrUnreadableFiles,
    );
  }

  Future<void> _moveMediaItem(MediaItem item, String targetDirectory) async {
    if (item.id == 'recycle_bin' || item.id == 'favorites') {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('回收站和收藏夹为系统文件夹，不可移动')));
      }
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text('正在移动媒体...'),
              ],
            ),
          ),
    );

    try {
      final updatedItem = MediaItem(
        id: item.id,
        name: item.name,
        path: item.path,
        type: item.type,
        directory: targetDirectory,
        dateAdded: item.dateAdded,
      );
      await _databaseService.updateMediaItem(updatedItem.toMap());

      if (mounted) {
        Navigator.of(context).pop();
        await _loadMediaItems();
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        debugPrint('移动媒体项时出错: $e');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移动媒体项时出错: $e')));
      }
    }
  }

  Future<void> _navigateToFolder(MediaItem folder) async {
    setState(() {
      _currentDirectory = folder.id;
      _selectedItems.clear();
      _isMultiSelectMode = false;
    });
    widget.onMultiSelectModeChanged?.call(false);
    await _loadMediaItems();
  }

  Future<void> _navigateUp() async {
    if (_currentDirectory != 'root') {
      final parentDir = await _databaseService.getMediaItemParentDirectory(
        _currentDirectory,
      );
      setState(() {
        _currentDirectory = parentDir ?? 'root';
        _selectedItems.clear();
        _isMultiSelectMode = false;
      });
      widget.onMultiSelectModeChanged?.call(false);
      await _loadMediaItems();
    }
  }

  void _toggleMediaVisibility() {
    setState(() => _mediaVisible = !_mediaVisible);
    _saveSettings();
  }

  void _toggleMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = !_isMultiSelectMode;
      if (!_isMultiSelectMode) _selectedItems.clear();
    });
    widget.onMultiSelectModeChanged?.call(_isMultiSelectMode);
  }

  void _selectAll() {
    setState(() {
      _isMultiSelectMode = true;
      final selectableIds =
          _mediaItems
              .where((item) => item.type != MediaType.folder)
              .map((item) => item.id)
              .toSet();
      if (selectableIds.isNotEmpty &&
          selectableIds.every((id) => _selectedItems.contains(id))) {
        // 已全选，再次点击则取消全选
        _selectedItems.clear();
      } else {
        // 未全选，则全选
        _selectedItems.clear();
        _selectedItems.addAll(selectableIds);
      }
    });
    widget.onMultiSelectModeChanged?.call(true);
  }

  Future<void> _moveSelectedItems(String targetDirectory) async {
    if (_selectedItems.isEmpty) return;
    // 排除系统文件夹，不可移动
    final idsToMove =
        _selectedItems
            .where((id) => id != 'recycle_bin' && id != 'favorites')
            .toSet();
    if (idsToMove.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('回收站和收藏夹为系统文件夹，不可移动')));
      }
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text('正在移动媒体...'),
              ],
            ),
          ),
    );

    try {
      for (var id in idsToMove) {
        final item = _mediaItems.firstWhere((item) => item.id == id);
        final updatedItem = MediaItem(
          id: item.id,
          name: item.name,
          path: item.path,
          type: item.type,
          directory: targetDirectory,
          dateAdded: item.dateAdded,
        );
        await _databaseService.updateMediaItem(updatedItem.toMap());
      }

      if (mounted) {
        final movedCount = _selectedItems.length;
        Navigator.of(context).pop();
        setState(() {
          _selectedItems.clear();
          _isMultiSelectMode = false;
        });
        widget.onMultiSelectModeChanged?.call(false);
        await _loadMediaItems();
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        debugPrint('移动媒体项时出错: $e');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移动媒体项时出错: $e')));
      }
    }
  }

  Future<void> _showMoveDialog({MediaItem? item}) async {
    if (item != null && (item.id == 'recycle_bin' || item.id == 'favorites')) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('回收站和收藏夹为系统文件夹，不可移动')));
      }
      return;
    }
    String? excludeId;
    if (item != null && item.type == MediaType.folder) {
      excludeId = item.id;
    } else if (_isMultiSelectMode && _selectedItems.isNotEmpty) {
      // If multiple items are selected, and any of them is a folder,
      // exclude the first selected folder and its subfolders.
      // For simplicity, we just take the first selected item that is a folder.
      for (var selectedId in _selectedItems) {
        final selectedItem = _mediaItems.firstWhere((i) => i.id == selectedId);
        if (selectedItem.type == MediaType.folder) {
          excludeId = selectedItem.id;
          break;
        }
      }
    }

    showDialog(
      context: context,
      builder:
          (context) => FutureBuilder<List<MediaItem>>(
            future: _getAllAvailableFolders(
              excludeFolderId: excludeId,
              excludeCurrentDirectoryId: _currentDirectory,
            ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const AlertDialog(
                  content: Row(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(width: 20),
                      Text('加载中...'),
                    ],
                  ),
                );
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return AlertDialog(
                  title: const Text('移动到'),
                  content: const Text('没有可用的目标文件夹。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                  ],
                );
              }

              final folders = snapshot.data!;
              return AlertDialog(
                title: const Text('移动到'),
                content: SingleChildScrollView(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('根目录'),
                        enabled: _currentDirectory != 'root',
                        onTap:
                            _currentDirectory != 'root'
                                ? () {
                                  Navigator.of(context).pop();
                                  if (item != null) {
                                    _moveMediaItem(item, 'root');
                                  } else {
                                    _moveSelectedItems('root');
                                  }
                                }
                                : null,
                      ),
                      ...folders.map((folder) {
                        return ListTile(
                          title: Text(folder.name),
                          onTap: () {
                            Navigator.of(context).pop();
                            if (item != null) {
                              _moveMediaItem(item, folder.id);
                            } else {
                              _moveSelectedItems(folder.id);
                            }
                          },
                        );
                      }),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ],
              );
            },
          ),
    );
  }

  Future<List<MediaItem>> _getAllAvailableFolders({
    String? excludeFolderId,
    String? excludeCurrentDirectoryId,
  }) async {
    try {
      final rootItems = await _databaseService.getMediaItems('root');
      final rootFolders =
          rootItems
              .where((item) => item['type'] == MediaType.folder.index)
              .map((item) => MediaItem.fromMap(item))
              .toList();

      final currentFolders =
          _currentDirectory != 'root'
              ? (await _databaseService.getMediaItems(_currentDirectory))
                  .where((item) => item['type'] == MediaType.folder.index)
                  .map((item) => MediaItem.fromMap(item))
                  .toList()
              : <MediaItem>[];

      // Remove Recycle Bin and Favorites from fetched folders if they are already there
      final filteredRootFolders =
          rootFolders
              .where(
                (folder) =>
                    folder.id != 'recycle_bin' && folder.id != 'favorites',
              )
              .toList();
      final filteredCurrentFolders =
          currentFolders
              .where(
                (folder) =>
                    folder.id != 'recycle_bin' && folder.id != 'favorites',
              )
              .toList();

      // Explicitly add Recycle Bin and Favorites, ensuring they are always available
      final recycleBin =
          await _databaseService.getMediaItemById('recycle_bin') ??
          <String, dynamic>{
            'id': 'recycle_bin',
            'name': '回收站',
            'path': '',
            'type': MediaType.folder.index,
            'directory': 'root',
            'date_added': DateTime.now().toIso8601String(),
          };
      final favorites =
          await _databaseService.getMediaItemById('favorites') ??
          <String, dynamic>{
            'id': 'favorites',
            'name': '收藏夹',
            'path': '',
            'type': MediaType.folder.index,
            'directory': 'root',
            'date_added': DateTime.now().toIso8601String(),
          };

      final allFolders =
          <MediaItem>{}
            ..addAll(filteredRootFolders)
            ..addAll(filteredCurrentFolders)
            ..add(MediaItem.fromMap(recycleBin))
            ..add(MediaItem.fromMap(favorites));

      // 排除正在移动的文件夹及其所有子文件夹（避免移入自身或子级导致循环）
      if (excludeFolderId != null) {
        final excludedSubfolders = await _getAllSubfolderIds(excludeFolderId);
        allFolders.removeWhere(
          (folder) =>
              folder.id == excludeFolderId ||
              excludedSubfolders.contains(folder.id),
        );
      }

      // 排除当前所在文件夹（项目已在此文件夹内，无需再选）
      if (excludeCurrentDirectoryId != null &&
          excludeCurrentDirectoryId != 'root') {
        allFolders.removeWhere(
          (folder) => folder.id == excludeCurrentDirectoryId,
        );
      }

      return allFolders.toList();
    } catch (e) {
      debugPrint('获取可用文件夹时出错: $e');
      return [];
    }
  }

  // Helper method to get all subfolder IDs recursively
  Future<Set<String>> _getAllSubfolderIds(String parentFolderId) async {
    Set<String> subfolderIds = {};
    try {
      final itemsInParent = await _databaseService.getMediaItems(
        parentFolderId,
      );
      for (var item in itemsInParent) {
        if (item['type'] == MediaType.folder.index) {
          subfolderIds.add(item['id']);
          subfolderIds.addAll(await _getAllSubfolderIds(item['id']));
        }
      }
    } catch (e) {
      debugPrint('递归获取子文件夹ID时出错: $e');
    }
    return subfolderIds;
  }

  Future<void> _deleteSelectedItems() async {
    if (_selectedItems.isEmpty) return;

    final shouldDelete =
        await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                title: const Text('删除选定项'),
                content: Text('确定要删除 ${_selectedItems.length} 个选定项吗？此操作不可撤销。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text(
                      '删除',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
        ) ??
        false;

    if (shouldDelete) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('正在删除...'),
                ],
              ),
            ),
      );

      try {
        final fileCleanupService = getService<FileCleanupService>();
        for (var id in _selectedItems) {
          final item = _mediaItems.firstWhereOrNull((i) => i.id == id);
          if (item == null) continue;
          if (fileCleanupService.isInitialized) {
            await fileCleanupService.deleteMediaFileCompletely(item.path);
          } else {
            final file = File(item.path);
            if (await file.exists()) await file.delete();
          }
          await _databaseService.deleteMediaItem(id);
        }

        if (mounted) {
          final deletedCount = _selectedItems.length;
          Navigator.of(context).pop();
          setState(() {
            _selectedItems.clear();
            _isMultiSelectMode = false;
          });
          widget.onMultiSelectModeChanged?.call(false);
          await Future<void>.delayed(const Duration(milliseconds: 900));
          await _loadMediaItems();
        }
      } catch (e) {
        if (mounted) {
          Navigator.of(context).pop();
          debugPrint('删除选定项时出错: $e');
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('删除选定项时出错: $e')));
        }
      }
    }
  }

  Widget _buildMediaGrid() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_mediaItems.isEmpty) {
      return const Center(
        child: Text(
          '没有媒体文件',
          style: TextStyle(fontSize: 18, color: Colors.grey),
        ),
      );
    }

    if (!_mediaVisible) return Container();

    const int crossAxisCount = _gridCrossAxisCount;
    const double childAspectRatio = _gridChildAspectRatio;
    const double crossAxisSpacing = _gridCrossAxisSpacing;
    const double mainAxisSpacing = _gridMainAxisSpacing;
    const double padding = _gridPadding;
    final bottomSafeInset = MediaQuery.viewPaddingOf(context).bottom;
    final bottomOverlayHeight =
        _selectedItems.isNotEmpty ? 56.0 : (_isMultiSelectMode ? 72.0 : 0.0);
    final bottomContentPadding =
        padding + bottomSafeInset + bottomOverlayHeight + 12;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (_isMultiSelectMode && !_isDragSelecting) {
          _scrollOffsetBeforeGesture = _gridScrollController.offset;
          _gestureCommitted = null;
          final startCr = _getGridColRow(
            e.position,
            crossAxisCount,
            childAspectRatio,
            crossAxisSpacing,
            mainAxisSpacing,
            padding,
          );
          if (startCr != null) {
            final startIdx = startCr.$2 * crossAxisCount + startCr.$1;
            if (startIdx >= 0 && startIdx < _mediaItems.length) {
              final item = _mediaItems[startIdx];
              if (item.id != 'recycle_bin' && item.id != 'favorites') {
                setState(() {
                  _hasDragMoved = false;
                  _dragStartPosition = e.position;
                  _dragStartColRow = startCr;
                  _dragIsDeselectMode = _selectedItems.contains(item.id);
                });
              }
            }
          }
        }
      },
      onPointerMove: (e) {
        if (!_isMultiSelectMode ||
            _dragStartColRow == null ||
            _dragStartPosition == null)
          return;
        final dx = e.position.dx - _dragStartPosition!.dx;
        final dy = e.position.dy - _dragStartPosition!.dy;
        if (_gestureCommitted == null) {
          final dist = math.sqrt(dx * dx + dy * dy);
          if (dist > _dragSelectThreshold) {
            if (dx.abs() > dy.abs()) {
              _gestureCommitted = 'selection';
              setState(() {
                _isDragSelecting = true;
                _hasDragMoved = true;
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_gridScrollController.hasClients) {
                  _gridScrollController.jumpTo(_scrollOffsetBeforeGesture);
                }
              });
            } else {
              _gestureCommitted = 'scroll';
            }
          }
        }
        if (_isMultiSelectMode &&
            _isDragSelecting &&
            _dragStartColRow != null) {
          if (!_hasDragMoved) {
            final dist = math.sqrt(dx * dx + dy * dy);
            if (dist < _dragSelectThreshold) return;
            _hasDragMoved = true;
          }
          final curCr = _getGridColRow(
            e.position,
            crossAxisCount,
            childAspectRatio,
            crossAxisSpacing,
            mainAxisSpacing,
            padding,
          );
          if (curCr != null) {
            final indices = _getIndicesInRectangle(
              _dragStartColRow!.$1,
              _dragStartColRow!.$2,
              curCr.$1,
              curCr.$2,
              crossAxisCount,
            );
            setState(() {
              for (final idx in indices) {
                final item = _mediaItems[idx];
                if (_dragIsDeselectMode) {
                  _selectedItems.remove(item.id);
                } else {
                  _selectedItems.add(item.id);
                }
              }
            });
          }
        }
      },
      onPointerUp: (e) {
        if (_isDragSelecting) {
          setState(() {
            _isDragSelecting = false;
            _gestureCommitted = null;
            if (_hasDragMoved) _dragSelectFinishedAt = DateTime.now();
          });
        } else {
          _gestureCommitted = null;
        }
      },
      onPointerCancel: (e) {
        if (_isDragSelecting) {
          setState(() {
            _isDragSelecting = false;
            _gestureCommitted = null;
          });
        } else {
          _gestureCommitted = null;
        }
      },
      child: GestureDetector(
        key: _gridContainerKey,
        onTap: () {
          if (_isMultiSelectMode && !_isDragSelecting) {
            _toggleMultiSelectMode();
          }
        },
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            physics:
                _isDragSelecting
                    ? const NeverScrollableScrollPhysics()
                    : const ClampingScrollPhysics(),
          ),
          child: GridView.builder(
            controller: _gridScrollController,
            padding: EdgeInsets.only(
              left: padding,
              right: padding,
              top: padding,
              bottom: bottomContentPadding,
            ),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: childAspectRatio,
              crossAxisSpacing: crossAxisSpacing,
              mainAxisSpacing: mainAxisSpacing,
            ),
            itemCount: _mediaItems.length + (_hasMoreMediaItems ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _mediaItems.length) {
                return _buildLoadMoreButton();
              }
              final item = _mediaItems[index];
              return _buildMediaItem(item, index);
            },
          ),
        ),
      ),
    );
  }

  /// 根据触摸位置计算网格项索引，用于划选多选
  int? _getGridIndexAtPosition(
    Offset globalPosition,
    int crossAxisCount,
    double childAspectRatio,
    double crossAxisSpacing,
    double mainAxisSpacing,
    double padding,
  ) {
    final cr = _getGridColRow(
      globalPosition,
      crossAxisCount,
      childAspectRatio,
      crossAxisSpacing,
      mainAxisSpacing,
      padding,
    );
    if (cr == null) return null;
    final idx = cr.$2 * crossAxisCount + cr.$1;
    return idx < _mediaItems.length ? idx : null;
  }

  /// 返回 (col, row)，用于矩形区域计算
  (int, int)? _getGridColRow(
    Offset globalPosition,
    int crossAxisCount,
    double childAspectRatio,
    double crossAxisSpacing,
    double mainAxisSpacing,
    double padding,
  ) {
    final box =
        _gridContainerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(globalPosition);
    final w = box.size.width - padding * 2;
    final cellWidth =
        (w - (crossAxisCount - 1) * crossAxisSpacing) / crossAxisCount;
    final cellHeight = cellWidth / childAspectRatio;
    final contentX = local.dx - padding;
    final contentY = local.dy - padding + _gridScrollController.offset;
    if (contentX < 0 || contentY < 0) return null;
    final col = (contentX / (cellWidth + crossAxisSpacing)).floor().clamp(
      0,
      crossAxisCount - 1,
    );
    final row = (contentY / (cellHeight + mainAxisSpacing)).floor().clamp(
      0,
      999999,
    );
    return (col, row);
  }

  /// 获取矩形区域内所有可选的网格索引（7字形划选）
  List<int> _getIndicesInRectangle(
    int startCol,
    int startRow,
    int endCol,
    int endRow,
    int crossAxisCount,
  ) {
    final minCol = startCol < endCol ? startCol : endCol;
    final maxCol = startCol > endCol ? startCol : endCol;
    final minRow = startRow < endRow ? startRow : endRow;
    final maxRow = startRow > endRow ? startRow : endRow;
    final list = <int>[];
    for (int r = minRow; r <= maxRow; r++) {
      for (int c = minCol; c <= maxCol; c++) {
        final idx = r * crossAxisCount + c;
        if (idx >= 0 && idx < _mediaItems.length) {
          final item = _mediaItems[idx];
          if (item.id != 'recycle_bin' && item.id != 'favorites') {
            list.add(idx);
          }
        }
      }
    }
    return list;
  }

  Widget _buildLoadMoreButton() {
    return GestureDetector(
      onTap: _isLoadingMore ? null : () => _loadMediaItems(append: true),
      child: Card(
        elevation: 2,
        margin: const EdgeInsets.all(0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        child: Center(
          child:
              _isLoadingMore
                  ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                  : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_circle_outline,
                        size: 32,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '加载更多',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
        ),
      ),
    );
  }

  Widget _buildMediaItem(MediaItem item, int index) {
    final isSystemFolder = item.id == 'recycle_bin' || item.id == 'favorites';
    bool isSelected = _selectedItems.contains(item.id);
    bool isLastViewed = item.id == _lastViewedMediaId;
    final showFavThumbnailBadge =
        item.isFavorite &&
        (item.type == MediaType.image || item.type == MediaType.video);

    return GestureDetector(
      key: ValueKey(item.id),
      onTap:
          isSystemFolder
              ? () => _navigateToFolder(item)
              : (_isMultiSelectMode
                  ? () => _toggleItemSelection(item.id)
                  : () {
                    if (item.type == MediaType.folder) {
                      _navigateToFolder(item);
                    } else {
                      _previewMediaItem(item);
                    }
                  }),
      onLongPress:
          isSystemFolder
              ? () => _navigateToFolder(item)
              : () {
                if (!_isMultiSelectMode) {
                  setState(() => _isMultiSelectMode = true);
                  widget.onMultiSelectModeChanged?.call(true);
                }
                _toggleItemSelection(item.id);
              },
      child: Card(
        elevation: isLastViewed ? 6 : 2,
        margin: const EdgeInsets.all(0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side:
              isLastViewed
                  ? const BorderSide(color: Colors.blue, width: 2.0)
                  : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _buildMediaThumbnail(item)),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 2,
                    ),
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
              if (_isMultiSelectMode && !isSystemFolder)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    constraints: const BoxConstraints(
                      maxWidth: 24,
                      maxHeight: 24,
                    ),
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (value) => _toggleItemSelection(item.id),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              if (!_isMultiSelectMode && !isSystemFolder)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Builder(
                    builder: (anchorCtx) {
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _onThumbnailCornerTap(item, anchorCtx),
                          child: Container(
                            width: 28,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color:
                                  showFavThumbnailBadge
                                      ? Colors.pink.withValues(alpha: 0.4)
                                      : Colors.black45,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              showFavThumbnailBadge
                                  ? Icons.favorite
                                  : Icons.more_vert,
                              size: 20,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 文件夹缩略图底部显示媒体数量
  Widget _buildFolderThumbnailWithCount({
    required Widget child,
    required String folderId,
  }) {
    final isSystemFolder = folderId == 'recycle_bin' || folderId == 'favorites';
    final countColor =
        isSystemFolder ? Colors.white : Colors.lightBlue.shade400;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 4,
          child: Center(
            child: FutureBuilder<int>(
              future: _databaseService
                  .getMediaItems(folderId)
                  .then((list) => list.length),
              builder: (context, snapshot) {
                if (snapshot.hasData && snapshot.data != null) {
                  return Text(
                    '${snapshot.data}',
                    style: TextStyle(
                      fontSize: 14,
                      color: countColor,
                      fontWeight: FontWeight.w500,
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMediaThumbnail(MediaItem item) {
    switch (item.type) {
      case MediaType.image:
        final hasKbCenter =
            item.kenBurnsCenterX != null && item.kenBurnsCenterY != null;
        final imgRot = item.videoViewParams.quarterTurns % 4;
        return Transform.rotate(
          angle: imgRot * math.pi / 2,
          alignment: Alignment.center,
          filterQuality: FilterQuality.low,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              Image(
                image: _buildImageThumbnailProvider(item.path),
                filterQuality: FilterQuality.low,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (frame != null || wasSynchronouslyLoaded) {
                    _invalidMediaRetryCounts.remove(item.id);
                  }
                  return child;
                },
                errorBuilder: (context, error, stackTrace) {
                  _scheduleCleanup(item.id); // 加载失败时安排清理（文件缺失或损坏）
                  return const Icon(Icons.image, size: 32);
                },
              ),
              if (hasKbCenter)
                Positioned.fill(
                  child: ZoomCenterMarkerCoverOverlay(
                    file: File(item.path),
                    nx: item.kenBurnsCenterX!,
                    ny: item.kenBurnsCenterY!,
                  ),
                ),
            ],
          ),
        );
      case MediaType.video:
        // 已缓存的缩略图走同步展示，避免 FutureBuilder 在父级 setState 后拿到新 Future 而短暂回到 waiting 造成闪屏。
        final readyThumb = _syncVideoThumbnailFileIfReady(item.path);
        if (readyThumb != null) {
          return _buildVideoThumbnailLoadedStack(readyThumb, item.path);
        }
        return FutureBuilder<File?>(
          future: _getOrCreateVideoThumbnailFuture(item.path),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done &&
                snapshot.hasData &&
                snapshot.data != null) {
              return _buildVideoThumbnailLoadedStack(snapshot.data!, item.path);
            } else if (snapshot.connectionState == ConnectionState.waiting) {
              return _buildVideoThumbnailGeneratingStack();
            } else {
              // 缩略图失败不代表视频文件无效；仅显示占位，避免误清理造成“导入后文件消失”。
              return _buildVideoPlaceholder();
            }
          },
        );
      case MediaType.audio:
        return Container(
          color: Colors.lightBlue.shade100,
          child: const Icon(Icons.audio_file, size: 32, color: Colors.blue),
        );

      case MediaType.folder:
        if (item.id == 'recycle_bin') {
          return _buildFolderThumbnailWithCount(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.grey.shade400, Colors.grey.shade600],
                ),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.delete_outline,
                size: 40,
                color: Colors.white,
              ),
            ),
            folderId: item.id,
          );
        }
        if (item.id == 'favorites') {
          return _buildFolderThumbnailWithCount(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.pink.shade100, Colors.pink.shade200],
                ),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.pink.shade200.withOpacity(0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.favorite, size: 40, color: Colors.white),
            ),
            folderId: item.id,
          );
        }
        return _buildFolderThumbnailWithCount(
          child: Container(
            color: Colors.amber.shade100,
            child: const Icon(Icons.folder, size: 32, color: Colors.amber),
          ),
          folderId: item.id,
        );
      default:
        return Container();
    }
  }

  ImageProvider _buildImageThumbnailProvider(String imagePath) {
    return ResizeImage(FileImage(File(imagePath)), width: 360);
  }

  /// 内存缓存中已有有效缩略图文件时同步返回，供网格重建时直接 [Image.file]，避免 FutureBuilder 闪屏。
  File? _syncVideoThumbnailFileIfReady(String videoPath) {
    final f = _videoThumbnailFileCache[videoPath];
    if (f == null) return null;
    try {
      if (f.existsSync()) {
        final len = f.lengthSync();
        if (len > 100) return f;
      }
    } catch (_) {}
    _videoThumbnailFileCache.remove(videoPath);
    return null;
  }

  Widget _buildVideoThumbnailLoadedStack(
    File file,
    String videoPathForErrorLog,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            debugPrint('加载视频缩略图显示失败（缩略图文件已存在）: $videoPathForErrorLog');
            return _buildVideoPlaceholder();
          },
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.play_arrow, size: 16, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoThumbnailGeneratingStack() {
    return Stack(
      children: [
        _buildVideoPlaceholder(),
        const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.blueGrey.shade900, Colors.black],
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.videocam, size: 36, color: Colors.white70),
                SizedBox(height: 4),
                Text(
                  '视频',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.play_arrow,
                size: 16,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<File?> _generateVideoThumbnail(String videoPath) async {
    try {
      // 文件不存在则直接返回，避免无意义尝试
      final videoFile = File(videoPath);
      if (!await videoFile.exists()) {
        debugPrint('视频文件不存在: $videoPath');
        return null;
      }

      final cacheKey = '${videoPath.hashCode.abs()}_${videoPath.length}';
      final thumbnailDir = await _getVideoThumbnailCacheDirectory();
      final thumbnailPath = path.join(
        thumbnailDir.path,
        '${cacheKey}_thumbnail.jpg',
      );
      final thumbnailFile = File(thumbnailPath);
      _videoThumbnailFileCache[videoPath] = thumbnailFile;

      // 检查缓存：命中则直接返回，不占用并发槽位
      if (await thumbnailFile.exists() && await thumbnailFile.length() > 100) {
        return thumbnailFile;
      }

      // 并发限制：最多同时生成 3 个缩略图，避免快速滑动时内存飙升
      while (_activeThumbnailCount >= _maxConcurrentThumbnails) {
        final completer = Completer<void>();
        _thumbnailWaitQueue.add(completer);
        await completer.future;
      }
      _activeThumbnailCount++;
      try {
        // 1. 优先尝试 thumbnailFile（直接写文件，部分机型更稳定）
        if (Platform.isAndroid || Platform.isIOS) {
          final fileAttempts = <({int timeMs, int? maxWidth, int? maxHeight})>[
            (timeMs: 0, maxWidth: 220, maxHeight: null),
            (timeMs: 0, maxWidth: null, maxHeight: 220),
            (timeMs: 1000, maxWidth: 220, maxHeight: null),
            (timeMs: 1000, maxWidth: null, maxHeight: 220),
          ];
          for (final attempt in fileAttempts) {
            try {
              final outPath = path.join(
                thumbnailDir.path,
                '${cacheKey}_t${attempt.timeMs}'
                '_${attempt.maxWidth ?? 0}x${attempt.maxHeight ?? 0}.jpg',
              );
              final resultPath =
                  (attempt.maxHeight != null)
                      ? await VideoThumbnail.thumbnailFile(
                        video: videoPath,
                        thumbnailPath: outPath,
                        imageFormat: ImageFormat.JPEG,
                        maxHeight: attempt.maxHeight!,
                        quality: 70,
                        timeMs: attempt.timeMs,
                      ).timeout(_singleThumbnailAttemptTimeout)
                      : await VideoThumbnail.thumbnailFile(
                        video: videoPath,
                        thumbnailPath: outPath,
                        imageFormat: ImageFormat.JPEG,
                        maxWidth: attempt.maxWidth!,
                        quality: 70,
                        timeMs: attempt.timeMs,
                      ).timeout(_singleThumbnailAttemptTimeout);
              if (resultPath != null) {
                final f = File(resultPath);
                if (await f.exists() && await f.length() > 100) {
                  await f.copy(thumbnailPath);
                  try {
                    await f.delete();
                  } catch (_) {}
                  debugPrint(
                    'thumbnailFile 成功 '
                    '(timeMs=${attempt.timeMs}, '
                    'w=${attempt.maxWidth}, h=${attempt.maxHeight})',
                  );
                  unawaited(_persistThumbnailPath(videoPath, thumbnailPath));
                  return thumbnailFile;
                }
              }
            } catch (e) {
              if (attempt == fileAttempts.last) {
                debugPrint('thumbnailFile 失败: $e');
              }
            }
          }
        }

        // 2. 备选：thumbnailData + 多时间点
        if (Platform.isAndroid || Platform.isIOS) {
          final dataAttempts = <({int timeMs, int? maxWidth, int? maxHeight})>[
            (timeMs: 0, maxWidth: 220, maxHeight: null),
            (timeMs: 0, maxWidth: null, maxHeight: 220),
            (timeMs: 1000, maxWidth: 220, maxHeight: null),
          ];
          for (final attempt in dataAttempts) {
            try {
              final thumbnailBytes =
                  (attempt.maxHeight != null)
                      ? await VideoThumbnail.thumbnailData(
                        video: videoPath,
                        imageFormat: ImageFormat.JPEG,
                        maxHeight: attempt.maxHeight!,
                        quality: 70,
                        timeMs: attempt.timeMs,
                      ).timeout(_singleThumbnailAttemptTimeout)
                      : await VideoThumbnail.thumbnailData(
                        video: videoPath,
                        imageFormat: ImageFormat.JPEG,
                        maxWidth: attempt.maxWidth!,
                        quality: 70,
                        timeMs: attempt.timeMs,
                      ).timeout(_singleThumbnailAttemptTimeout);
              if (thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
                await thumbnailFile.writeAsBytes(thumbnailBytes);
                if (await thumbnailFile.exists()) {
                  debugPrint(
                    'thumbnailData 成功 '
                    '(timeMs=${attempt.timeMs}, '
                    'w=${attempt.maxWidth}, h=${attempt.maxHeight})',
                  );
                  unawaited(_persistThumbnailPath(videoPath, thumbnailPath));
                  return thumbnailFile;
                }
              }
            } catch (e) {
              if (attempt == dataAttempts.last) {
                debugPrint('thumbnailData 失败: $e');
              }
            }
          }
        }

        debugPrint('标准方法失败，尝试彩色占位缩略图');
        final fallbackThumbnail = await _generateColoredThumbnail(videoPath);
        if (fallbackThumbnail != null) {
          unawaited(_persistThumbnailPath(videoPath, fallbackThumbnail.path));
        }
        return fallbackThumbnail;
      } finally {
        _activeThumbnailCount--;
        if (_thumbnailWaitQueue.isNotEmpty) {
          _thumbnailWaitQueue.removeAt(0).complete();
        }
      }
    } catch (e) {
      debugPrint('缩略图生成异常: $videoPath, 错误: $e');
      return null;
    }
  }

  Future<File?> _getOrCreateVideoThumbnailFuture(String videoPath) {
    final cachedFile = _videoThumbnailFileCache[videoPath];
    if (cachedFile != null) {
      try {
        if (cachedFile.existsSync()) {
          final len = cachedFile.lengthSync();
          if (len > 100) {
            _clearVideoThumbnailFailure(videoPath);
            final itemId = _findMediaItemIdByPath(videoPath);
            if (itemId != null) {
              _invalidMediaRetryCounts.remove(itemId);
            }
            return Future<File?>.value(cachedFile);
          }
        }
      } catch (_) {}
      _videoThumbnailFileCache.remove(videoPath);
    }
    final cachedFuture = _videoThumbnailFutureCache[videoPath];
    if (cachedFuture != null) {
      return cachedFuture;
    }
    if (_thumbnailGenerationFailed.contains(videoPath)) {
      return Future<File?>.value(null);
    }

    final future = _generateVideoThumbnail(videoPath).then((file) {
      if (file == null) {
        _markVideoThumbnailFailure(videoPath);
        _videoThumbnailFileCache.remove(videoPath);
        _scheduleThumbnailUiRefresh();
        _videoThumbnailFutureCache.remove(videoPath);
      } else {
        _clearVideoThumbnailFailure(videoPath);
        _thumbnailGenerationFailed.remove(videoPath);
        _videoThumbnailFileCache[videoPath] = file;
        final itemId = _findMediaItemIdByPath(videoPath);
        if (itemId != null) {
          _invalidMediaRetryCounts.remove(itemId);
        }
        _scheduleThumbnailUiRefresh();
        // 保留已完成的 Future，避免 FutureBuilder 在 setState 后拿到「新 Future」而 connectionState 回到 waiting 闪屏。
        _videoThumbnailFutureCache[videoPath] = Future<File?>.value(file);
      }
      return file;
    });

    _videoThumbnailFutureCache[videoPath] = future;
    if (_videoThumbnailFutureCache.length > 1200) {
      final staleKeys = _videoThumbnailFutureCache.keys.take(300).toList();
      for (final key in staleKeys) {
        if (!_videoThumbnailFileCache.containsKey(key)) {
          _videoThumbnailFutureCache.remove(key);
        }
      }
    }
    return future;
  }

  void _markVideoThumbnailFailure(String videoPath) {
    _thumbnailGenerationFailed.add(videoPath);
    _thumbnailRetryCooldownTimers.remove(videoPath)?.cancel();
    _thumbnailRetryCooldownTimers[videoPath] = Timer(
      _thumbnailRetryCooldown,
      () {
        _thumbnailGenerationFailed.remove(videoPath);
        _thumbnailRetryCooldownTimers.remove(videoPath);
        _videoThumbnailFutureCache.remove(videoPath);
        if (!mounted) return;
        _scheduleThumbnailUiRefresh();
        if (_findMediaItemIdByPath(videoPath) != null &&
            !_videoThumbnailFileCache.containsKey(videoPath)) {
          _enqueueVideoThumbnailPaths([videoPath], prioritize: true);
          unawaited(_drainThumbnailPrefetchQueue());
        }
      },
    );
  }

  void _scheduleThumbnailUiRefresh() {
    if (!mounted) return;
    _thumbnailUiRefreshDebounce?.cancel();
    _thumbnailUiRefreshDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() {});
    });
  }

  /// 在 [_loadMediaItems] 等重建网格后，将列表滚回关闭预览/刷新前的位置。
  void _scheduleGridScrollRestore(double? previousOffset) {
    if (previousOffset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_gridScrollController.hasClients) return;
      final max = _gridScrollController.position.maxScrollExtent;
      _gridScrollController.jumpTo(previousOffset.clamp(0.0, max));
    });
  }

  Future<void> _refreshMediaAndThumbnails() async {
    final double? previousOffset =
        _gridScrollController.hasClients ? _gridScrollController.offset : null;
    // 手动刷新时，允许立即重试之前失败的缩略图，无需退出目录。
    for (final timer in _thumbnailRetryCooldownTimers.values) {
      timer.cancel();
    }
    _thumbnailRetryCooldownTimers.clear();
    _thumbnailGenerationFailed.clear();
    _videoThumbnailFutureCache.clear();
    _thumbnailPrefetchQueue.clear();
    _thumbnailPrefetchQueued.clear();
    await _loadMediaItems();
    if (!mounted) return;
    _scheduleGridScrollRestore(previousOffset);
    _scheduleThumbnailPrefetch(includeBackground: true);
    unawaited(_drainThumbnailPrefetchQueue());
  }

  void _clearVideoThumbnailFailure(String videoPath) {
    _thumbnailGenerationFailed.remove(videoPath);
    _thumbnailRetryCooldownTimers.remove(videoPath)?.cancel();
  }

  String? _findMediaItemIdByPath(String mediaPath) {
    return _mediaItems.firstWhereOrNull((item) => item.path == mediaPath)?.id;
  }

  Future<Directory> _getVideoThumbnailCacheDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final thumbnailDir = Directory(
      path.join(supportDir.path, 'video_thumbnails'),
    );
    if (!await thumbnailDir.exists()) {
      await thumbnailDir.create(recursive: true);
    }
    return thumbnailDir;
  }

  Future<void> _persistThumbnailPath(
    String videoPath,
    String thumbnailPath,
  ) async {
    final itemId = _findMediaItemIdByPath(videoPath);
    if (itemId == null) return;
    try {
      await _databaseService.updateMediaItem({
        'id': itemId,
        'thumbnail_path': thumbnailPath,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // 缩略图路径持久化失败不影响展示，忽略。
    }
  }

  Future<File?> _generateColoredThumbnail(String videoPath) async {
    try {
      final cacheKey = '${videoPath.hashCode.abs()}_${videoPath.length}';
      final thumbnailDir = await _getVideoThumbnailCacheDirectory();
      final thumbnailPath = path.join(
        thumbnailDir.path,
        '${cacheKey}_color_thumbnail.jpg',
      );
      final thumbnailFile = File(thumbnailPath);

      // 检查缓存
      if (await thumbnailFile.exists() && await thumbnailFile.length() > 100) {
        return thumbnailFile;
      }

      // 创建基于视频路径的唯一颜色缩略图（不依赖文件可读性）
      final videoFileName = path.basename(videoPath);
      int colorSeed = videoFileName.hashCode;
      try {
        final f = File(videoPath);
        if (await f.exists()) colorSeed += await f.length();
      } catch (_) {}
      final colorMap = _generateUniqueColors(colorSeed);

      // 使用简单的位图方法生成缩略图，而不依赖Canvas
      final imageBytes = await _createSimpleBitmapThumbnail(
        const Size(250, 141), // 16:9宽高比
        videoFileName,
        colorMap['primary']!,
        colorMap['secondary']!,
      );

      await thumbnailFile.writeAsBytes(imageBytes);
      if (await thumbnailFile.exists()) {
        return thumbnailFile;
      }

      return null;
    } catch (e) {
      debugPrint('生成彩色缩略图失败: $e');
      return null;
    }
  }

  Map<String, Color> _generateUniqueColors(int seed) {
    final random = math.Random(seed);
    final List<Color> primaryColors = [
      Colors.blue.shade900,
      Colors.indigo.shade800,
      Colors.purple.shade800,
      Colors.teal.shade800,
      Colors.green.shade800,
      Colors.orange.shade900,
      Colors.red.shade900,
      Colors.pink.shade800,
    ];
    final List<Color> secondaryColors = [
      Colors.blue.shade300,
      Colors.indigo.shade400,
      Colors.purple.shade400,
      Colors.teal.shade400,
      Colors.green.shade400,
      Colors.orange.shade400,
      Colors.red.shade400,
      Colors.pink.shade400,
    ];
    final primaryIndex = random.nextInt(primaryColors.length);
    final secondaryIndex = random.nextInt(secondaryColors.length);
    return {
      'primary': primaryColors[primaryIndex],
      'secondary': secondaryColors[secondaryIndex],
    };
  }

  Future<Uint8List> _createSimpleBitmapThumbnail(
    Size size,
    String fileName,
    Color primaryColor,
    Color secondaryColor,
  ) async {
    final width = size.width.toInt().clamp(1, 300);
    final height = size.height.toInt().clamp(1, 300);
    const int bytesPerPixel = 4;
    final int rowStrideBytes = width * bytesPerPixel;
    final int totalBytes = rowStrideBytes * height;
    final Uint8List bytes = Uint8List(totalBytes);

    // 绘制渐变背景
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int pixelOffset = (y * rowStrideBytes) + (x * bytesPerPixel);

        // 计算当前位置的渐变颜色
        final double normalizedY = y / height;
        final double normalizedX = x / width;
        final double distanceFromCenter =
            math.sqrt(
              math.pow(normalizedX - 0.5, 2) + math.pow(normalizedY - 0.5, 2),
            ) *
            2;

        final double ratio = (normalizedY * 0.7) + (distanceFromCenter * 0.3);
        final double inverseRatio = 1 - ratio;

        // 混合两种颜色
        final int r =
            (primaryColor.red * inverseRatio + secondaryColor.red * ratio)
                .toInt();
        final int g =
            (primaryColor.green * inverseRatio + secondaryColor.green * ratio)
                .toInt();
        final int b =
            (primaryColor.blue * inverseRatio + secondaryColor.blue * ratio)
                .toInt();
        const int a = 255;

        bytes[pixelOffset] = r;
        bytes[pixelOffset + 1] = g;
        bytes[pixelOffset + 2] = b;
        bytes[pixelOffset + 3] = a;
      }
    }

    // 在中心绘制视频播放图标
    _drawPlayIcon(bytes, width, height, rowStrideBytes);

    // 在底部添加文件名
    _drawFileName(bytes, width, height, rowStrideBytes, fileName);

    return bytes;
  }

  // 绘制播放图标
  void _drawPlayIcon(
    Uint8List bytes,
    int width,
    int height,
    int rowStrideBytes,
  ) {
    final int centerX = width ~/ 2;
    final int centerY = height ~/ 2;
    final int iconSize = math.min(width, height) ~/ 5;

    // 绘制圆形背景
    for (int y = centerY - iconSize; y <= centerY + iconSize; y++) {
      if (y < 0 || y >= height) continue;
      for (int x = centerX - iconSize; x <= centerX + iconSize; x++) {
        if (x < 0 || x >= width) continue;

        final int dx = x - centerX;
        final int dy = y - centerY;
        final double distance = math.sqrt(dx * dx + dy * dy);

        if (distance <= iconSize) {
          final int pixelOffset =
              (y * rowStrideBytes) + (x * 4); // 使用固定值4代替bytesPerPixel

          // 圆形半透明背景
          bytes[pixelOffset] = (bytes[pixelOffset] * 0.3).toInt();
          bytes[pixelOffset + 1] = (bytes[pixelOffset + 1] * 0.3).toInt();
          bytes[pixelOffset + 2] = (bytes[pixelOffset + 2] * 0.3).toInt();

          // 播放三角形图标
          if (dx > -iconSize / 2 && distance < iconSize * 0.8) {
            const double slope = 1.2; // 控制三角形形状
            if (dy < slope * dx && dy > -slope * dx) {
              bytes[pixelOffset] = 255;
              bytes[pixelOffset + 1] = 255;
              bytes[pixelOffset + 2] = 255;
            }
          }
        }
      }
    }
  }

  // 绘制文件名
  void _drawFileName(
    Uint8List bytes,
    int width,
    int height,
    int rowStrideBytes,
    String fileName,
  ) {
    // 在底部创建一个半透明的条带
    final int startY = height - 20;
    final int endY = height;

    // 截断过长的文件名
    String displayName = fileName;
    if (displayName.length > 15) {
      displayName = '${displayName.substring(0, 12)}...';
    }

    // 创建半透明底部条带
    for (int y = startY; y < endY; y++) {
      if (y < 0 || y >= height) continue;
      for (int x = 0; x < width; x++) {
        final int pixelOffset =
            (y * rowStrideBytes) + (x * 4); // 使用固定值4代替bytesPerPixel
        bytes[pixelOffset] = (bytes[pixelOffset] * 0.3).toInt();
        bytes[pixelOffset + 1] = (bytes[pixelOffset + 1] * 0.3).toInt();
        bytes[pixelOffset + 2] = (bytes[pixelOffset + 2] * 0.3).toInt();
      }
    }

    // 由于无法直接在位图上绘制文本，我们只创建一个简单的标记
    // 实际应用中可以考虑使用第三方库处理文本绘制
  }

  Future<bool> _extractVideoFrameWithFFmpeg(
    String videoPath,
    String outputPath,
  ) async {
    try {
      debugPrint('使用 FFmpeg 提取视频帧: $videoPath -> $outputPath');
      final escapedVideoPath = videoPath.replaceAll('\\', '/');
      final escapedOutputPath = outputPath.replaceAll('\\', '/');

      // 创建临时目录，确保目标文件夹存在
      final outputDir = File(outputPath).parent;
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      // 临时禁用FFmpeg代码，直接返回false以使用备选方法
      debugPrint('FFmpeg功能临时禁用，使用备选方法生成缩略图');
      return false;

      /* 原FFmpeg代码已临时注释
      // 首先尝试视频序列的中间位置
      try {
        // 使用FFmpegKit执行命令获取视频时长
        String probCommand = '-i "$escapedVideoPath" -show_entries format=duration -v quiet -of csv="p=0"';
        final probeSession = await FFmpegKit.execute(probCommand);
        final probeReturnCode = await probeSession.getReturnCode();
        
        if (ReturnCode.isSuccess(probeReturnCode)) {
          ...更多FFmpeg代码...
        }
      } catch (probeError) {
        ...更多FFmpeg代码...
      }
      */
    } catch (e) {
      debugPrint('使用 FFmpeg 提取视频帧时出错: $e');
      return false;
    }
  }

  void _previewMediaItem(MediaItem item) {
    // 仅预览媒体文件（图片/视频），不包含文件夹，避免切换下一项时出现文件夹
    final mediaOnly =
        _mediaItems
            .where(
              (i) => i.type == MediaType.image || i.type == MediaType.video,
            )
            .toList();
    final index = mediaOnly.indexOf(item);
    if (index == -1) {
      debugPrint('错误：无法在媒体列表中找到该项目');
      return;
    }
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder:
                (context) => MediaPreviewPage(
                  mediaItems: mediaOnly,
                  initialIndex: index,
                  openedFromRecycleBin: _currentDirectory == 'recycle_bin',
                ),
          ),
        )
        .then((_) async {
          // 预览关闭后全量刷新会重建网格，需先记下滚动位置以免回到列表顶部。
          final double? scrollBeforeReload =
              _gridScrollController.hasClients
                  ? _gridScrollController.offset
                  : null;
          await _loadMediaItems();
          if (!mounted) return;
          // 预览页面关闭时刷新列表（删除/移动/收藏等操作后需同步显示）
          setState(() {
            _lastViewedMediaId = item.id;
          });
          _scheduleGridScrollRestore(scrollBeforeReload);
        });
  }

  void _showMultiSelectOptions() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder:
          (context) => SafeModalSheetScrollable(
            children: [
              ListTile(
                leading: const Icon(Icons.select_all),
                title: const Text('全选'),
                onTap: () {
                  Navigator.pop(context);
                  _selectAll();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.move_to_inbox),
                title: const Text('移动到'),
                onTap: () {
                  Navigator.pop(context);
                  _showMoveDialog();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('删除', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteSelectedItems();
                },
              ),
            ],
          ),
    );
  }

  Future<void> _clearRecycleBin() async {
    if (_currentDirectory != 'recycle_bin') return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                title: const Text('清空回收站'),
                content: const Text('将彻底删除回收站中的所有媒体文件，此操作不可撤销。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text(
                      '清空',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
        ) ??
        false;
    if (!confirmed) return;

    try {
      final itemsMap = await _databaseService.getMediaItems('recycle_bin');
      final items =
          itemsMap
              .map((m) => MediaItem.fromMap(m))
              .where((i) => i.type != MediaType.folder)
              .toList();
      final fileCleanupService = getService<FileCleanupService>();
      int deletedCount = 0;

      for (final item in items) {
        try {
          if (fileCleanupService.isInitialized) {
            await fileCleanupService.deleteMediaFileCompletely(item.path);
          } else {
            final file = File(item.path);
            if (await file.exists()) await file.delete();
          }
        } catch (_) {}
        try {
          await _databaseService.deleteMediaItem(item.id);
          deletedCount++;
          _invalidMediaRetryCounts.remove(item.id);
        } catch (_) {}
      }

      await _loadMediaItems();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deletedCount > 0 ? '已清空回收站，彻底删除 $deletedCount 项' : '回收站已是空的',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('清空回收站失败: $e')));
    }
  }

  void _showSettingsMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white.withOpacity(0.5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        final screenWidth = MediaQuery.of(context).size.width;
        final dialogWidth = screenWidth;

        final List<Map<String, dynamic>> options = [
          {
            'icon': Icons.photo_library,
            'color': Colors.indigo,
            'title': '批量导入媒体',
            'onTap': () async {
              Navigator.pop(context);
              final items = await _pickMultipleMedia();
              if (items.isNotEmpty) {
                await _saveMultipleMediaWithTypes(items);
              }
            },
          },
          {
            'icon': Icons.create_new_folder,
            'color': Colors.amber,
            'title': '创建文件夹',
            'onTap': () {
              Navigator.pop(context);
              _showCreateFolderDialog();
            },
          },
          {
            'icon': Icons.find_replace,
            'color': Colors.purple,
            'title': '扫描重复文件',
            'onTap': () async {
              Navigator.pop(context);
              await _showScanDuplicatesOptionsDialog();
            },
          },
          {
            'icon': Icons.upload_file,
            'color': Colors.teal,
            'title': '导出媒体数据',
            'onTap': () async {
              Navigator.pop(context);
              await _exportAllMediaData();
            },
          },
          if (_currentDirectory != 'root')
            {
              'icon': Icons.folder_outlined,
              'color': Colors.teal,
              'title': '导出当前文件夹',
              'onTap': () async {
                Navigator.pop(context);
                await _exportFolderData();
              },
            },
          {
            'icon': Icons.download,
            'color': Colors.indigo,
            'title': '导入媒体数据',
            'onTap': () async {
              Navigator.pop(context);
              await _importAllMediaData();
            },
          },
          {
            'icon': Icons.folder_open,
            'color': Colors.indigo,
            'title': '导入文件夹数据',
            'onTap': () async {
              Navigator.pop(context);
              await _importFolderData();
            },
          },
          {
            'icon': Icons.science,
            'color': Colors.orange,
            'title': '生成测试数据',
            'onTap': () async {
              Navigator.pop(context);
              await _showGenerateTestDataDialog();
            },
          },
        ];

        if (_isMultiSelectMode && _selectedItems.isNotEmpty) {
          options.add({
            'icon': Icons.move_to_inbox,
            'color': Colors.grey,
            'title': '移动选定项',
            'onTap': () {
              Navigator.pop(context);
              _showMoveDialog();
            },
          });
          options.add({
            'icon': Icons.ios_share,
            'color': Colors.teal,
            'title': '导出选定项',
            'onTap': () {
              Navigator.pop(context);
              _exportSelectedMediaItems();
            },
          });
          options.add({
            'icon': Icons.delete,
            'color': Colors.red,
            'title': '删除选定项',
            'onTap': () {
              Navigator.pop(context);
              _deleteSelectedItems();
            },
          });
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 460),
                child: Container(
                  width: dialogWidth,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 12),
                        child: SizedBox(
                          height: 48,
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              const Center(
                                child: Text(
                                  '媒体管理选项',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 0,
                                top: 0,
                                bottom: 0,
                                child: Center(
                                  child: Switch(
                                    value: _autoImportSilentMode,
                                    onChanged: (v) async {
                                      setState(() => _autoImportSilentMode = v);
                                      setModalState(() {});
                                      await _saveSettings();
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                childAspectRatio: 3.5,
                                crossAxisSpacing: 6,
                                mainAxisSpacing: 4,
                              ),
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final option = options[index];
                            return GestureDetector(
                              onTap: option['onTap'] as void Function(),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.grey[100],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      option['icon'] as IconData,
                                      size: 20,
                                      color: option['color'] as Color,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        option['title'] as String,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color:
                                              option['color'] == Colors.red
                                                  ? Colors.red
                                                  : Colors.black,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _mediaVisible = prefs.getBool('media_visible') ?? true;
        _autoImportSilentMode = prefs.getBool('auto_import_silent') ?? true;
      });
    } catch (e) {
      debugPrint('加载设置时出错: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('media_visible', _mediaVisible);
      await prefs.setBool('auto_import_silent', _autoImportSilentMode);
    } catch (e) {
      debugPrint('保存设置时出错: $e');
    }
  }

  void _toggleItemSelection(String id) {
    if (id == 'recycle_bin' || id == 'favorites') return;
    if (_dragSelectFinishedAt != null &&
        DateTime.now().difference(_dragSelectFinishedAt!) <
            const Duration(milliseconds: 300) &&
        _selectedItems.contains(id)) {
      return;
    }
    setState(() {
      if (_selectedItems.contains(id)) {
        _selectedItems.remove(id);
      } else {
        _selectedItems.add(id);
      }
    });
  }

  Future<void> _exportMediaItem(MediaItem item) async {
    try {
      final file = File(item.path);
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('文件不存在: ${item.path}')));
        }
        return;
      }

      // 直接分享文件，移除了保存到相册选项
      await Share.shareXFiles([XFile(item.path)], subject: '分享: ${item.name}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('分享文件时出错: $e')));
      }
    }
  }

  /// 选择扫描模式：仅扫描 / 扫描并清理
  Future<void> _showScanDuplicatesOptionsDialog() async {
    final autoRemove = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('扫描重复文件'),
            content: const Text(
              '请选择扫描模式：\n\n'
              '• 仅扫描：更新哈希并报告重复数量，不自动删除\n'
              '• 扫描并清理：将重复项移至回收站',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('仅扫描'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('扫描并清理'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
            ],
          ),
    );
    if (autoRemove != null && mounted) {
      await _scanAndUpdateFileHashes(autoRemove: autoRemove);
    }
  }

  Future<void> _scanAndUpdateFileHashes({bool autoRemove = true}) async {
    if (!mounted) return;
    final cancelRef = ValueNotifier(false);
    final progRef = ValueNotifier(0.0);
    final msgRef = ValueNotifier('正在准备…');

    showCancellableProgressDialog(
      context,
      progress: progRef,
      message: msgRef,
      cancelRequested: cancelRef,
      title: '扫描重复文件',
    );

    try {
      msgRef.value = '正在枚举媒体库…';
      progRef.value = 0;

      final allMediaItems = await _getAllMediaItemsRecursively('root');
      if (!mounted) return;

      final totalPass1 = math.max(allMediaItems.length, 1);

      int processedCount = 0;
      int updatedCount = 0;
      int duplicateCount = 0;
      int errorCount = 0;
      final Map<String, List<Map<String, dynamic>>> hashGroups = {};

      for (
        var pass1Index = 0;
        pass1Index < allMediaItems.length;
        pass1Index++
      ) {
        if (cancelRef.value) {
          msgRef.value = '正在停止…';
          break;
        }
        final item = allMediaItems[pass1Index];
        final name = item['name']?.toString() ?? '';
        msgRef.value = '阶段 1/2 计算哈希 (${pass1Index + 1}/$totalPass1)\n$name';
        progRef.value = (pass1Index / totalPass1) * 0.88;

        try {
          if (item['type'] == MediaType.folder.index) {
            processedCount++;
            continue;
          }

          final file = File(item['path'] as String? ?? '');
          if (!await file.exists()) {
            errorCount++;
            processedCount++;
            continue;
          }

          final fileHash = await _calculateFileHash(file);
          if (fileHash.isEmpty) {
            errorCount++;
            processedCount++;
            continue;
          }

          await _databaseService.updateMediaItemHash(item['id'], fileHash);

          hashGroups.putIfAbsent(fileHash, () => []).add(item);

          updatedCount++;
          processedCount++;
        } catch (e) {
          Logger.log('处理文件时出错: ${item['name']}, 错误: $e');
          errorCount++;
          processedCount++;
        }
      }

      if (!cancelRef.value) {
        final keys = hashGroups.keys.toList();
        final totalPass2 = math.max(keys.length, 1);
        outerScanDup:
        for (var k = 0; k < keys.length; k++) {
          if (cancelRef.value) {
            msgRef.value = '正在停止…';
            break;
          }
          final hash = keys[k];
          final files = hashGroups[hash]!;
          progRef.value = 0.88 + ((k + 1) / totalPass2) * 0.12;
          msgRef.value = '阶段 2/2 检查重复 (${k + 1}/$totalPass2)';

          if (files.length > 1) {
            final label = files.map((f) => f['name']).join(', ');
            msgRef.value = '阶段 2/2 处理重复\n$label';
            duplicateCount += files.length - 1;
            if (autoRemove) {
              final duplicates = files.skip(1).toList();
              for (final duplicate in duplicates) {
                if (cancelRef.value) {
                  msgRef.value = '正在停止…';
                  break outerScanDup;
                }
                try {
                  await _databaseService.updateMediaItemDirectory(
                    duplicate['id'],
                    'recycle_bin',
                  );
                } catch (e) {
                  Logger.log('移动重复文件到回收站时出错: ${duplicate['name']}, 错误: $e');
                  errorCount++;
                }
              }
            }
          }
        }
      }

      if (!cancelRef.value) {
        progRef.value = 1.0;
      }

      if (mounted) Navigator.of(context).pop();

      if (mounted) {
        if (cancelRef.value) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '扫描已取消\n'
                '已处理条目: $processedCount\n'
                '更新哈希: $updatedCount\n'
                '错误: $errorCount',
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        } else {
          final removedNote =
              autoRemove && duplicateCount > 0
                  ? '\n已移至回收站: $duplicateCount 个'
                  : (duplicateCount > 0 ? '\n(未删除，请手动处理)' : '');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '扫描完成\n'
                '处理文件: $processedCount\n'
                '更新哈希: $updatedCount\n'
                '发现重复: $duplicateCount 个$removedNote\n'
                '错误: $errorCount',
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        }
        await _loadMediaItems();
      }
    } catch (e) {
      Logger.log('扫描文件哈希时出错: $e');
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫描失败: $e')));
      }
    }
  }

  /// 当前目录一键查重并删除：仅处理当前页面的媒体文件，重复项移至回收站
  Future<void> _deduplicateCurrentFolder() async {
    try {
      final items = await _databaseService.getMediaItems(_currentDirectory);
      final mediaFiles =
          items
              .where((item) => item['type'] != MediaType.folder.index)
              .toList();
      if (mediaFiles.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前目录没有媒体文件')));
        }
        return;
      }

      if (!mounted) return;
      final cancelRef = ValueNotifier(false);
      final progRef = ValueNotifier(0.0);
      final msgRef = ValueNotifier('准备查重…');
      final locLabel = _currentDirectory == 'root' ? '根目录' : _currentDirectory;

      showCancellableProgressDialog(
        context,
        progress: progRef,
        message: msgRef,
        cancelRequested: cancelRef,
        title: '当前目录查重',
      );

      final Map<String, List<Map<String, dynamic>>> hashGroups = {};
      int errorCount = 0;

      final totalPass1 = math.max(mediaFiles.length, 1);
      for (var i = 0; i < mediaFiles.length; i++) {
        if (cancelRef.value) {
          msgRef.value = '正在停止…';
          break;
        }
        final item = mediaFiles[i];
        final n = item['name']?.toString() ?? '';
        msgRef.value = '阶段 1/2 计算哈希 ($locLabel)\n(${i + 1}/$totalPass1) $n';
        progRef.value = ((i + 1) / totalPass1) * 0.85;

        try {
          final file = File(item['path']?.toString() ?? '');
          if (!await file.exists()) {
            errorCount++;
            continue;
          }
          final fileHash = await _calculateFileHash(file);
          if (fileHash.isEmpty) {
            errorCount++;
            continue;
          }
          await _databaseService.updateMediaItemHash(item['id'], fileHash);
          hashGroups.putIfAbsent(fileHash, () => []).add(item);
        } catch (e) {
          errorCount++;
        }
      }

      int duplicateCount = 0;
      int dupStep = 0;
      int dupTotal = 0;
      for (final files in hashGroups.values) {
        if (files.length > 1) dupTotal += files.length - 1;
      }
      dupTotal = math.max(dupTotal, 1);

      if (!cancelRef.value) {
        outerDedup:
        for (final files in hashGroups.values) {
          if (files.length <= 1) continue;
          duplicateCount += files.length - 1;
          for (final dup in files.skip(1)) {
            if (cancelRef.value) {
              msgRef.value = '正在停止…';
              break outerDedup;
            }
            dupStep++;
            progRef.value = 0.85 + (dupStep / dupTotal) * 0.15;
            msgRef.value = '阶段 2/2 移至回收站 ($dupStep/$dupTotal)\n${dup['name']}';
            try {
              await _databaseService.updateMediaItemDirectory(
                dup['id'],
                'recycle_bin',
              );
            } catch (e) {
              errorCount++;
            }
          }
        }
      }

      if (!cancelRef.value) {
        progRef.value = 1.0;
      }

      if (mounted) Navigator.of(context).pop();

      if (mounted) {
        await _loadMediaItems();
        if (cancelRef.value) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('查重已取消（错误: $errorCount）'),
              duration: const Duration(seconds: 3),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                duplicateCount > 0
                    ? '查重完成：发现 $duplicateCount 个重复文件，已移至回收站'
                    : '查重完成：当前目录无重复文件',
              ),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('查重失败: $e')));
      }
    }
  }

  // 递归获取所有媒体项的辅助方法
  Future<List<Map<String, dynamic>>> _getAllMediaItemsRecursively(
    String directory,
  ) async {
    List<Map<String, dynamic>> allItems = [];

    try {
      // 获取当前目录下的所有项目
      final items = await _databaseService.getMediaItems(directory);

      for (var item in items) {
        if (item['type'] == MediaType.folder.index) {
          // 如果是文件夹，递归获取其中的项目
          final subItems = await _getAllMediaItemsRecursively(item['id']);
          allItems.addAll(subItems);
        } else {
          // 只添加非文件夹的媒体文件
          allItems.add(item);
        }
      }
    } catch (e) {
      Logger.log('递归获取媒体项时出错: $e');
    }

    return allItems;
  }

  // 批量导出选中的媒体文件
  Future<void> _exportSelectedMediaItems() async {
    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先选择要导出的媒体文件')));
      }
      return;
    }

    try {
      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('正在准备导出...'),
                ],
              ),
            ),
      );

      // 收集所有选中的文件
      List<XFile> filesToShare = [];
      List<String> missingFiles = [];

      for (String id in _selectedItems) {
        final item = _mediaItems.firstWhere((item) => item.id == id);
        // 跳过文件夹
        if (item.type == MediaType.folder) continue;

        final file = File(item.path);
        if (await file.exists()) {
          filesToShare.add(XFile(item.path));
        } else {
          missingFiles.add(item.name);
        }
      }

      // 关闭进度对话框
      if (mounted) {
        Navigator.pop(context);
      }

      if (filesToShare.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('没有找到可导出的文件')));
        }
        return;
      }

      // 分享文件
      await Share.shareXFiles(
        filesToShare,
        subject: '分享: ${filesToShare.length} 个文件',
      );

      // 如果有文件丢失，显示提示
      if (missingFiles.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('以下文件不存在，已跳过：${missingFiles.join(", ")}')),
          );
        }
      }
    } catch (e) {
      // 确保关闭进度对话框
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出文件时出错: $e')));
      }
    }
  }

  // New method for scheduling cleanup
  void _scheduleCleanup(String itemId) {
    // 导入后 30 秒内不触发清理，避免大量缩略图并发生成时的误判
    if (_lastImportCompletedAt != null &&
        DateTime.now().difference(_lastImportCompletedAt!) <
            const Duration(seconds: 30)) {
      return;
    }
    final retryCount = (_invalidMediaRetryCounts[itemId] ?? 0) + 1;
    _invalidMediaRetryCounts[itemId] = retryCount;
    if (retryCount < _invalidMediaRetryThreshold) {
      return;
    }
    _itemsToCleanup.add(itemId);
    _cleanupTimer?.cancel(); // Cancel any existing timer
    _cleanupTimer = Timer(const Duration(seconds: 10), () {
      // 10秒防抖，给缩略图生成更多重试机会
      _performCleanup();
    });
  }

  // New method to perform the cleanup
  // 图片加载失败：直接删除（多为损坏/垃圾文件）
  // 视频缩略图失败：移至回收站，给用户自行处理或再次尝试的机会
  Future<void> _performCleanup() async {
    if (_itemsToCleanup.isEmpty) return;

    debugPrint('开始自动清理无效媒体文件: ${_itemsToCleanup.length} 个');
    final cleanedItems = Set<String>.from(_itemsToCleanup);
    _itemsToCleanup.clear();

    for (var id in cleanedItems) {
      try {
        final matches = _mediaItems.where((i) => i.id == id).toList();
        if (matches.isEmpty) continue;
        final item = matches.first;

        // 清理前尝试路径修复：跨设备导入后 path 可能错误，文件实际在 media 目录
        final appDir = await getApplicationDocumentsDirectory();
        final mediaDirPath = path.join(appDir.path, 'media');
        final fileName = path.basename(item.path);
        final candidatePath = path.join(mediaDirPath, fileName);
        if (!await File(item.path).exists() &&
            await File(candidatePath).exists()) {
          await _databaseService.updateMediaItemPath(item.id, candidatePath);
          _invalidMediaRetryCounts.remove(item.id);
          debugPrint('清理前路径已修复，跳过: ${item.name}');
          continue;
        }

        if (item.directory != 'recycle_bin') {
          // 视频：移至回收站，不删除文件，让用户自行处理
          await _databaseService.updateMediaItemDirectory(
            item.id,
            'recycle_bin',
          );
          debugPrint('视频缩略图生成失败，已移至回收站: ${item.name}');
        } else {
          // 图片等：直接删除（多为损坏文件）
          await _databaseService.updateMediaItemDirectory(
            item.id,
            'recycle_bin',
          );
          debugPrint('已自动清理无效文件: ${item.name}');
        }
      } catch (e) {
        debugPrint('自动清理文件时出错 ($id): $e');
      }
    }

    await _loadMediaItems();
    debugPrint('无效媒体文件自动清理完成。');
  }

  // New method to delete media item silently (without confirmation dialog)
  Future<void> _deleteMediaItemSilently(MediaItem item) async {
    try {
      final fileCleanupService = getService<FileCleanupService>();
      if (fileCleanupService.isInitialized) {
        await fileCleanupService.deleteMediaFileCompletely(item.path);
      } else {
        final file = File(item.path);
        if (await file.exists()) await file.delete();
      }
      await _databaseService.deleteMediaItem(item.id);
    } catch (e) {
      debugPrint('静默删除媒体项时出错: ${item.name}, 错误: $e');
      rethrow;
    }
  }

  Future<void> _warmCurrentDirectoryVideoThumbnailsInBackground() async {
    try {
      final warmVideos = _mediaItems
          .where((item) => item.type == MediaType.video)
          .take(_thumbnailWarmupLimit)
          .toList(growable: false);
      if (warmVideos.isEmpty) return;
      _enqueueVideoThumbnailPrefetch(warmVideos, prioritize: false);
      unawaited(_drainThumbnailPrefetchQueue());
    } catch (e) {
      debugPrint('鍚庡彴棰勭儹褰撳墠鐩綍瑙嗛缂╃暐鍥惧け璐? $e');
    }
  }

  Future<void> _warmAllVideoThumbnailsInBackground({
    int maxVideos = 2000,
  }) async {
    try {
      final allItems = await _databaseService.getAllMediaItems();
      final allVideoPaths = allItems
          .where(
            (item) => (item['type'] as int? ?? -1) == MediaType.video.index,
          )
          .map((item) => item['path']?.toString() ?? '')
          .where((p) => p.isNotEmpty)
          .take(maxVideos)
          .toList(growable: false);
      if (allVideoPaths.isEmpty) return;
      _enqueueVideoThumbnailPaths(allVideoPaths, prioritize: false);
      unawaited(_drainThumbnailPrefetchQueue());
    } catch (e) {
      debugPrint('后台预热全库视频缩略图失败: $e');
    }
  }

  // 声明全量导出/导入方法（后续补充实现）
  Future<void> _exportAllMediaData() async {
    final progress = ValueNotifier<double>(0);
    final message = ValueNotifier<String>('准备中...');

    ZipFileEncoder? encoder;
    String currentPhase = '准备';
    try {
      // 1. 获取所有媒体项的数据库记录（分批处理）
      currentPhase = '查询媒体列表';
      message.value = '正在查询媒体文件...';
      final allMediaItems = await _databaseService.getAllMediaItems();
      if (allMediaItems.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('没有可导出的媒体文件。')));
        }
        return;
      }

      // 2. 使用默认保存位置（优先公共下载目录，用户可在文件管理器中找到）
      currentPhase = '选择保存位置';
      final Directory saveDir = await getExportSaveDirectory();
      await saveDir.create(recursive: true);
      if (!mounted) return;
      final String timestamp =
          DateTime.now()
              .toIso8601String()
              .replaceAll(':', '-')
              .split('.')
              .first;
      final zipFilePath = path.join(
        saveDir.path,
        'media_backup_$timestamp.zip',
      );

      showProgressDialog(context, progress, message);

      // 3. 使用流式ZIP处理，避免内存溢出（7GB/15GB+ 大容量导出需严格控制内存）
      currentPhase = '压缩媒体文件';
      message.value = '正在创建压缩包...';
      encoder = ZipFileEncoder();
      encoder.create(zipFilePath);

      int totalFiles = allMediaItems.length;
      int processedFiles = 0;
      int totalSize = 0;

      // 仅当文件数较少时预计算总大小，避免超大库（如7GB）的 O(n) 预扫描导致卡顿
      const int kSkipTotalSizeThreshold = 500;
      if (totalFiles <= kSkipTotalSizeThreshold) {
        for (final item in allMediaItems) {
          final mediaFile = File(item['path']);
          if (await mediaFile.exists()) {
            totalSize += await mediaFile.length();
          }
        }
      }

      int processedSize = 0;

      // 大容量导出：按数据量动态调整批次，level=0 不压缩（媒体文件已压缩），减少内存占用
      final batchSize = totalFiles > 3000 ? 1 : (totalFiles > 1000 ? 2 : 3);
      const int level = 0; // 0=仅存储，不压缩，大幅降低内存和CPU
      for (int i = 0; i < allMediaItems.length; i += batchSize) {
        final endIndex = math.min(i + batchSize, allMediaItems.length);
        final batch = allMediaItems.sublist(i, endIndex);

        for (final item in batch) {
          try {
            final mediaFile = File(item['path']);
            if (await mediaFile.exists()) {
              final fileName = path.basename(item['path']);
              final relativePath = 'media/$fileName';

              await encoder.addFile(mediaFile, relativePath, level);

              processedFiles++;
              if (totalSize > 0) {
                processedSize += await mediaFile.length();
                progress.value = (processedSize / totalSize) * 0.8;
              } else {
                progress.value = (processedFiles / totalFiles) * 0.8;
              }
              message.value =
                  totalSize > 0
                      ? '正在压缩: $processedFiles/$totalFiles (${_formatFileSize(processedSize)}/${_formatFileSize(totalSize)})'
                      : '正在压缩: $processedFiles/$totalFiles';

              // 按数据量调整暂停频率，避免 7GB/15GB 级导出 OOM
              if (processedFiles % 50 == 0) {
                await Future.delayed(
                  Duration(milliseconds: totalFiles > 2000 ? 400 : 300),
                );
              } else if (processedFiles % 10 == 0) {
                await Future.delayed(
                  Duration(milliseconds: totalFiles > 2000 ? 120 : 80),
                );
              }
            } else {
              debugPrint('警告: 文件不存在，跳过导出: ${item['path']}');
            }
          } catch (e) {
            debugPrint('导出文件失败: ${item['path']}, 错误: $e');
          }
        }

        if (endIndex < allMediaItems.length) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }

      // 4. 导出数据库 - 分块写入避免单一大JSON (5000条/文件)
      currentPhase = '导出数据库';
      message.value = '正在导出数据库...';
      for (
        int chunkIdx = 0;
        chunkIdx < allMediaItems.length;
        chunkIdx += kExportChunkSize
      ) {
        final end = math.min(chunkIdx + kExportChunkSize, allMediaItems.length);
        final chunk = allMediaItems.sublist(chunkIdx, end);
        final fileName = 'media_items_${chunkIdx ~/ kExportChunkSize}.json';
        final bytes = utf8.encode(jsonEncode(chunk));
        encoder.addArchiveFile(ArchiveFile(fileName, bytes.length, bytes));
        if ((chunkIdx + kExportChunkSize) % (kProgressUpdateInterval * 10) ==
                0 ||
            end == allMediaItems.length) {
          message.value = '正在导出数据库: $end/${allMediaItems.length}';
        }
      }
      if (allMediaItems.isEmpty) {
        encoder.addArchiveFile(
          ArchiveFile('media_items.json', 2, utf8.encode('[]')),
        );
      }
      progress.value = 0.85;

      message.value = '正在导出设置...';
      final prefs = await SharedPreferences.getInstance();
      final settingsJson = jsonEncode(await buildMediaSettingsExportMap(prefs));
      final settingsBytes = utf8.encode(settingsJson);
      final settingsFile = ArchiveFile(
        'media_settings.json',
        settingsBytes.length,
        settingsBytes,
      );
      encoder.addArchiveFile(settingsFile);
      progress.value = 0.9;

      // 5. 完成打包
      currentPhase = '完成打包';
      message.value = '正在完成...';
      await Future.delayed(const Duration(milliseconds: 500)); // 缓解大容量导出时的内存压力
      encoder.close();
      progress.value = 1.0;

      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        final zipFile = File(zipFilePath);
        final zipSizeBytes =
            await zipFile.exists() ? await zipFile.length() : 0;
        final bool isTooLarge = zipSizeBytes > kShareSizeLimitBytes;
        if (!isTooLarge) {
          try {
            await Share.shareXFiles([XFile(zipFilePath)], text: '媒体数据导出');
          } catch (shareErr) {
            debugPrint('分享失败: $shareErr');
          }
          // 小文件：分享后即完成，不再弹第二个界面
        } else {
          showExportResultDialog(
            context,
            zipFilePath,
            zipSizeBytes,
            shareText: '媒体数据导出',
            showShareButton: false,
            showSaveToFolderButton: true,
          );
        }
      }
    } catch (e, stack) {
      try {
        encoder?.close();
      } catch (_) {}
      if (mounted) Navigator.of(context).pop();
      debugPrint('导出媒体数据时出错 [$currentPhase]: $e\n$stack');
      if (mounted) {
        final userMsg = formatExportImportError(e, '导出失败');
        showExportImportErrorDialog(
          context,
          '媒体导出失败',
          '出错阶段：$currentPhase\n\n$userMsg',
        );
      }
    }
  }

  // 格式化文件大小的辅助方法
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  /// 导出当前文件夹（含子文件夹内所有媒体文件），格式与全量导出兼容，可被「导入文件夹数据」合并导入
  Future<void> _exportFolderData() async {
    if (_currentDirectory == 'root') return;
    final folderItem = await _databaseService.getMediaItemById(
      _currentDirectory,
    );
    final folderName = folderItem?['name'] as String? ?? '未命名文件夹';

    final progress = ValueNotifier<double>(0);
    final message = ValueNotifier<String>('准备中...');
    ZipFileEncoder? encoder;
    String currentPhase = '准备';
    try {
      currentPhase = '查询文件夹内容';
      message.value = '正在收集媒体文件...';
      final folderMediaItems = await _getAllMediaItemsRecursively(
        _currentDirectory,
      );
      if (folderMediaItems.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前文件夹内没有可导出的媒体文件。')));
        }
        return;
      }

      currentPhase = '选择保存位置';
      final Directory saveDir = await getExportSaveDirectory();
      await saveDir.create(recursive: true);
      if (!mounted) return;
      final String safeName = folderName.replaceAll(
        RegExp(r'[^\w\s\u4e00-\u9fff-]'),
        '_',
      );
      final String timestamp =
          DateTime.now()
              .toIso8601String()
              .replaceAll(':', '-')
              .split('.')
              .first;
      final zipFilePath = path.join(
        saveDir.path,
        'media_folder_${safeName}_$timestamp.zip',
      );

      showProgressDialog(context, progress, message);

      currentPhase = '压缩媒体文件';
      message.value = '正在创建压缩包...';
      encoder = ZipFileEncoder();
      encoder.create(zipFilePath);

      int totalFiles = folderMediaItems.length;
      int processedFiles = 0;
      int totalSize = 0;
      const int kSkipTotalSizeThreshold = 500;
      if (totalFiles <= kSkipTotalSizeThreshold) {
        for (final item in folderMediaItems) {
          final mediaFile = File(item['path']);
          if (await mediaFile.exists()) totalSize += await mediaFile.length();
        }
      }
      int processedSize = 0;

      final batchSize = totalFiles > 3000 ? 1 : (totalFiles > 1000 ? 2 : 3);
      const int level = 0;
      for (int i = 0; i < folderMediaItems.length; i += batchSize) {
        final endIndex = math.min(i + batchSize, folderMediaItems.length);
        final batch = folderMediaItems.sublist(i, endIndex);
        for (final item in batch) {
          try {
            final mediaFile = File(item['path']);
            if (await mediaFile.exists()) {
              final fileName = path.basename(item['path']);
              await encoder.addFile(mediaFile, 'media/$fileName', level);
              processedFiles++;
              if (totalSize > 0) {
                processedSize += await mediaFile.length();
                progress.value = (processedSize / totalSize) * 0.8;
              } else {
                progress.value = (processedFiles / totalFiles) * 0.8;
              }
              message.value =
                  totalSize > 0
                      ? '正在压缩: $processedFiles/$totalFiles (${_formatFileSize(processedSize)}/${_formatFileSize(totalSize)})'
                      : '正在压缩: $processedFiles/$totalFiles';
              if (processedFiles % 50 == 0) {
                await Future.delayed(
                  Duration(milliseconds: totalFiles > 2000 ? 400 : 300),
                );
              } else if (processedFiles % 10 == 0) {
                await Future.delayed(
                  Duration(milliseconds: totalFiles > 2000 ? 120 : 80),
                );
              }
            } else {
              debugPrint('警告: 文件不存在，跳过导出: ${item['path']}');
            }
          } catch (e) {
            debugPrint('导出文件失败: ${item['path']}, 错误: $e');
          }
        }
        if (endIndex < folderMediaItems.length) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }

      currentPhase = '导出数据库';
      message.value = '正在导出元数据...';
      final manifest = {'type': 'folder', 'folder_name': folderName};
      encoder.addArchiveFile(
        ArchiveFile(
          'folder_manifest.json',
          utf8.encode(jsonEncode(manifest)).length,
          utf8.encode(jsonEncode(manifest)),
        ),
      );
      if (folderMediaItems.length > kExportChunkSize) {
        for (
          int chunkIdx = 0;
          chunkIdx < folderMediaItems.length;
          chunkIdx += kExportChunkSize
        ) {
          final end = math.min(
            chunkIdx + kExportChunkSize,
            folderMediaItems.length,
          );
          final chunk = folderMediaItems.sublist(chunkIdx, end);
          final fileName = 'media_items_${chunkIdx ~/ kExportChunkSize}.json';
          final bytes = utf8.encode(jsonEncode(chunk));
          encoder.addArchiveFile(ArchiveFile(fileName, bytes.length, bytes));
        }
      } else {
        final itemsJson = utf8.encode(jsonEncode(folderMediaItems));
        encoder.addArchiveFile(
          ArchiveFile('media_items.json', itemsJson.length, itemsJson),
        );
      }
      message.value = '正在导出设置...';
      final folderExportPrefs = await SharedPreferences.getInstance();
      final folderSettingsBytes = utf8.encode(
        jsonEncode(await buildMediaSettingsExportMap(folderExportPrefs)),
      );
      encoder.addArchiveFile(
        ArchiveFile(
          'media_settings.json',
          folderSettingsBytes.length,
          folderSettingsBytes,
        ),
      );
      progress.value = 0.9;

      currentPhase = '完成打包';
      message.value = '正在完成...';
      await Future.delayed(const Duration(milliseconds: 500));
      encoder.close();
      progress.value = 1.0;

      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        final zipFile = File(zipFilePath);
        final zipSizeBytes =
            await zipFile.exists() ? await zipFile.length() : 0;
        final bool isTooLarge = zipSizeBytes > kShareSizeLimitBytes;
        if (!isTooLarge) {
          try {
            await Share.shareXFiles([
              XFile(zipFilePath),
            ], text: '文件夹导出: $folderName');
          } catch (shareErr) {
            debugPrint('分享失败: $shareErr');
          }
        } else {
          showExportResultDialog(
            context,
            zipFilePath,
            zipSizeBytes,
            shareText: '文件夹导出: $folderName',
            showShareButton: false,
            showSaveToFolderButton: true,
          );
        }
      }
    } catch (e, stack) {
      try {
        encoder?.close();
      } catch (_) {}
      if (mounted) Navigator.of(context).pop();
      debugPrint('导出文件夹时出错 [$currentPhase]: $e\n$stack');
      if (mounted) {
        final userMsg = formatExportImportError(e, '导出失败');
        showExportImportErrorDialog(
          context,
          '文件夹导出失败',
          '出错阶段：$currentPhase\n\n$userMsg',
        );
      }
    }
  }

  /// 导入文件夹数据（合并模式，不覆盖现有媒体库）
  Future<void> _importFolderData() async {
    final progress = ValueNotifier<double>(0.0);
    final message = ValueNotifier<String>('准备中...');
    final Directory appDir = await getApplicationDocumentsDirectory();
    final String tempImportPath = path.join(
      appDir.path,
      'temp_folder_import_${const Uuid().v4()}',
    );
    final Directory tempImportDir = Directory(tempImportPath);
    String currentPhase = '准备';
    try {
      await tempImportDir.create(recursive: true);

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;

      showProgressDialog(context, progress, message);
      final p = result.files.single.path;
      if (p == null || p.isEmpty) {
        throw Exception('无法获取所选文件路径');
      }
      final zipFile = File(p);
      if (!await zipFile.exists()) {
        throw Exception('所选文件不存在或无法访问');
      }

      currentPhase = '解压压缩包';
      message.value = '正在解压数据...';
      final tempMediaDir = Directory(path.join(tempImportDir.path, 'media'));
      final inputStream = InputFileStream(zipFile.path);
      try {
        final archive = ZipDecoder().decodeStream(inputStream);

        int done = 0;
        final total = archive.files.length;
        if (!await tempMediaDir.exists())
          await tempMediaDir.create(recursive: true);

        for (final file in archive.files) {
          final outPath = resolveSafeExtractPath(tempImportDir.path, file.name);
          if (file.isFile) {
            final outFile = File(outPath);
            await outFile.parent.create(recursive: true);
            final outputStream = OutputFileStream(outFile.path);
            file.writeContent(outputStream);
            await outputStream.close();
          } else {
            await Directory(outPath).create(recursive: true);
          }
          done++;
          progress.value = (done / total) * 0.5;
          message.value = '解压: $done/$total';
          if (total > 500 && done % 100 == 0) {
            await Future.delayed(const Duration(milliseconds: 50));
          }
        }
      } finally {
        await inputStream.close();
      }

      final manifestFile = File(
        path.join(tempImportDir.path, 'folder_manifest.json'),
      );
      final chunk0File = File(
        path.join(tempImportDir.path, 'media_items_0.json'),
      );
      final jsonFile = File(path.join(tempImportDir.path, 'media_items.json'));
      if (!await manifestFile.exists()) {
        throw Exception('该压缩包不是有效的文件夹导出文件，请选择由「导出当前文件夹」生成的 ZIP 包。');
      }
      if (!await chunk0File.exists() && !await jsonFile.exists()) {
        throw Exception('该压缩包不是有效的文件夹导出文件，缺少媒体元数据。');
      }

      final manifest =
          jsonDecode(await manifestFile.readAsString())
              as Map<String, dynamic>?;
      if ((manifest?['type'] ?? '') != 'folder') {
        throw Exception('该压缩包不是有效的文件夹导出文件。');
      }

      final folderName = manifest?['folder_name']?.toString() ?? '导入的文件夹';
      List<dynamic> mediaItemsToImport = [];
      if (await chunk0File.exists()) {
        int chunkIdx = 0;
        while (true) {
          final f = File(
            path.join(tempImportDir.path, 'media_items_$chunkIdx.json'),
          );
          if (!await f.exists()) break;
          mediaItemsToImport.addAll(
            jsonDecode(await f.readAsString()) as List<dynamic>? ?? [],
          );
          chunkIdx++;
        }
      } else {
        mediaItemsToImport =
            jsonDecode(await jsonFile.readAsString()) as List<dynamic>? ?? [];
      }

      currentPhase = '创建文件夹';
      message.value = '正在创建目标文件夹...';
      String targetFolderName = folderName;
      int suffix = 0;
      while (await _checkFolderNameExists(targetFolderName)) {
        suffix++;
        targetFolderName = '$folderName($suffix)';
      }

      final newFolderId = const Uuid().v4();
      final newFolder = MediaItem(
        id: newFolderId,
        name: targetFolderName,
        path: '',
        type: MediaType.folder,
        directory: _currentDirectory,
        dateAdded: DateTime.now(),
      );
      await _databaseService.insertMediaItem(newFolder.toMap());

      currentPhase = '导入媒体文件';
      final mediaDirPath = path.join(appDir.path, 'media');
      int importedCount = 0;
      int skippedCount = 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final importedVideoPaths = <String>[];

      for (int i = 0; i < mediaItemsToImport.length; i++) {
        final item = mediaItemsToImport[i];
        if (item is! Map<String, dynamic>) continue;
        final typeIndex = item['type'] as int? ?? 0;
        if (typeIndex == MediaType.folder.index) continue;

        final oldPath = item['path']?.toString();
        if (oldPath == null || oldPath.isEmpty) continue;

        final fileName = path.basename(oldPath);
        final sourceFile = File(
          path.join(tempImportDir.path, 'media', fileName),
        );
        if (!await sourceFile.exists()) {
          debugPrint('跳过：文件不存在 $fileName');
          skippedCount++;
          continue;
        }

        final fileHash = await _calculateFileHash(sourceFile);
        if (fileHash.isEmpty) {
          skippedCount++;
          continue;
        }

        final duplicate = await _databaseService.findDuplicateMediaItem(
          fileHash,
          fileName,
        );
        if (duplicate != null) {
          // 原样导入：将重复项从其他位置移入本文件夹，保证导出多少导入多少
          await _databaseService.updateMediaItemDirectory(
            duplicate['id'] as String,
            newFolderId,
          );
          importedCount++;
          continue;
        }

        final uuid = const Uuid().v4();
        final extension = path.extension(sourceFile.path);
        final destinationPath = path.join(mediaDirPath, '$uuid$extension');
        await Directory(mediaDirPath).create(recursive: true);
        await copyFileWithStreamingToFile(sourceFile, File(destinationPath));

        final newItem = Map<String, dynamic>.from(item);
        newItem['id'] = uuid;
        newItem['path'] = destinationPath;
        newItem['directory'] = newFolderId;
        newItem['thumbnail_path'] = null;
        newItem['created_at'] = now;
        newItem['updated_at'] = now;
        newItem['file_hash'] = fileHash;
        await _databaseService.insertMediaItem(newItem);
        importedCount++;
        if ((newItem['type'] as int? ?? -1) == MediaType.video.index) {
          importedVideoPaths.add(destinationPath);
        }

        progress.value = 0.5 + (i + 1) / mediaItemsToImport.length * 0.45;
        message.value = '正在导入: ${i + 1}/${mediaItemsToImport.length}';
        final totalItems = mediaItemsToImport.length;
        if (totalItems > 500 && (i + 1) % 100 == 0) {
          await Future.delayed(const Duration(milliseconds: 50));
        } else if ((i + 1) % 10 == 0) {
          await Future.delayed(const Duration(milliseconds: 30));
        }
      }

      final folderSettingsImport = File(
        path.join(tempImportDir.path, 'media_settings.json'),
      );
      if (await folderSettingsImport.exists()) {
        try {
          final raw = jsonDecode(await folderSettingsImport.readAsString());
          if (raw is Map<String, dynamic>) {
            final fprefs = await SharedPreferences.getInstance();
            await applyMediaSettingsImportMap(fprefs, raw);
          }
        } catch (e) {
          debugPrint('导入文件夹：恢复 media_settings.json 失败（已跳过）: $e');
        }
      }

      progress.value = 0.98;
      message.value = '导入完成，正在刷新...';
      _lastImportCompletedAt = DateTime.now();
      await _loadMediaItems();
      if (importedVideoPaths.isNotEmpty) {
        _enqueueVideoThumbnailPaths(importedVideoPaths, prioritize: true);
      }
      unawaited(_warmCurrentDirectoryVideoThumbnailsInBackground());
      unawaited(_drainThumbnailPrefetchQueue());
      progress.value = 1.0;

      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        String msg = '已导入 $importedCount 个文件到「$targetFolderName」';
        if (skippedCount > 0) msg += '（$skippedCount 个因文件缺失或无法读取已跳过）';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e, stack) {
      debugPrint('导入文件夹数据失败 [$currentPhase]: $e\n$stack');
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        final userMsg = formatExportImportError(e, '导入失败');
        showExportImportErrorDialog(
          context,
          '文件夹导入失败',
          '出错阶段：$currentPhase\n\n$userMsg',
        );
      }
    } finally {
      if (await tempImportDir.exists()) {
        try {
          await tempImportDir.delete(recursive: true);
        } catch (e) {
          debugPrint('清理临时目录失败: $e');
        }
      }
    }
  }

  Future<void> _importAllMediaData() async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('导入全部媒体数据'),
            content: const Text(
              '将仅替换「媒体库」目录（应用文档下的 media 文件夹）及媒体库数据库；'
              '日记本专属目录 diary_media、日记录音目录 audio、拍照/相册的 images 与 videos 等不会被此操作删除。\n\n'
              '若压缩包中缺少某些文件，仍会自动保留其它模块仍引用的 media 内文件；'
              '若压缩包内存在同名文件，则以压缩包为准覆盖。\n\n'
              '请确认已备份重要数据，或确定要执行此操作。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确认导入', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    final progress = ValueNotifier<double>(0.0);
    final message = ValueNotifier<String>('准备中...');

    // 1. 创建一个唯一的临时目录用于解压
    final Directory appDir = await getApplicationDocumentsDirectory();
    final String tempImportPath = path.join(
      appDir.path,
      'temp_media_import_${const Uuid().v4()}',
    );
    final Directory tempImportDir = Directory(tempImportPath);

    String currentPhase = '准备';
    bool importHadError = false;
    try {
      await tempImportDir.create(recursive: true);

      // 2. 选择zip包
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;

      showProgressDialog(context, progress, message);

      final p = result.files.single.path;
      if (p == null || p.isEmpty) {
        throw Exception('无法获取所选文件路径');
      }
      final zipFile = File(p);
      if (!await zipFile.exists()) {
        throw Exception('所选文件不存在或无法访问');
      }

      // 3. 用流式InputFileStream解压zip到临时目录
      currentPhase = '解压压缩包';
      message.value = '正在解压数据...';
      final tempMediaDir = Directory(path.join(tempImportDir.path, 'media'));
      final inputStream = InputFileStream(zipFile.path);
      try {
        final archive = ZipDecoder().decodeStream(inputStream);

        int total = archive.files.length;
        int done = 0;

        if (!await tempMediaDir.exists()) {
          await tempMediaDir.create(recursive: true);
        }

        for (final file in archive.files) {
          final outPath = resolveSafeExtractPath(tempImportDir.path, file.name);
          if (file.isFile) {
            final outFile = File(outPath);
            await outFile.parent.create(recursive: true);
            final outputStream = OutputFileStream(outFile.path);
            file.writeContent(outputStream);
            await outputStream.close();
          } else {
            await Directory(outPath).create(recursive: true);
          }

          done++;
          progress.value = (done / total) * 0.7;
          message.value = '解压: $done/$total';
          if (total > 500 && done % 100 == 0) {
            await Future.delayed(const Duration(milliseconds: 50));
          }
        }
      } finally {
        await inputStream.close();
      }

      // 4. 从临时目录中读取元数据 - 支持分块格式与旧版media_items.json
      currentPhase = '恢复数据库';
      Map<String, dynamic>? settingsToImport;

      final chunk0File = File(
        path.join(tempImportDir.path, 'media_items_0.json'),
      );
      final jsonFile = File(path.join(tempImportDir.path, 'media_items.json'));
      if (!await chunk0File.exists() && !await jsonFile.exists()) {
        throw Exception(
          "关键错误: 压缩包中未找到 'media_items.json' 或 'media_items_0.json' 文件。",
        );
      }

      // 路径重映射与数据规范化：跨设备导入时 path 需映射到当前设备，并补全必要字段
      final mediaDirPath = path.join(appDir.path, 'media');
      final now = DateTime.now().millisecondsSinceEpoch;
      void remapMediaItemPath(Map<String, dynamic> item) {
        final typeIndex = item['type'] as int? ?? 0;
        if (typeIndex == MediaType.folder.index) return;
        final oldPath = item['path']?.toString();
        if (oldPath != null && oldPath.isNotEmpty) {
          final fileName = path.basename(oldPath);
          item['path'] = path.join(mediaDirPath, fileName);
        }
        item['thumbnail_path'] = null;
        item['created_at'] ??= now;
        item['updated_at'] ??= now;
      }

      final settingsFile = File(
        path.join(tempImportDir.path, 'media_settings.json'),
      );
      if (await settingsFile.exists()) {
        settingsToImport = jsonDecode(await settingsFile.readAsString());
      }

      // 5. 先复制媒体文件到新目录，再替换旧目录，最后才写 DB（避免数据丢失）
      progress.value = 0.75;
      currentPhase = '迁移媒体文件';
      final Directory finalMediaDir = Directory(
        path.join(appDir.path, 'media'),
      );
      final Directory mediaNewDir = Directory(
        path.join(appDir.path, 'media_new_import'),
      );
      try {
        if (await mediaNewDir.exists())
          await mediaNewDir.delete(recursive: true);
        await mediaNewDir.create(recursive: true);
        await _copyDirectory(
          tempMediaDir,
          mediaNewDir,
          onProgress: (p, t, msg) {
            message.value = msg;
            progress.value = 0.75 + (t > 0 ? (p / t) * 0.15 : 0);
          },
        );
        final Set<String> importBasenames = {};
        if (await tempMediaDir.exists()) {
          await for (final entity in tempMediaDir.list(recursive: true)) {
            if (entity is File) importBasenames.add(path.basename(entity.path));
          }
        }
        final pathsToPreserve = await _databaseService.getAllValidFilePaths();
        message.value = '正在保留日记等引用的媒体文件...';
        await _mergePreservedMediaFilesIntoDir(
          sourceMediaDir: finalMediaDir,
          targetDir: mediaNewDir,
          importBasenames: importBasenames,
          validPathsAbsolute: pathsToPreserve,
        );
        if (await finalMediaDir.exists()) {
          await finalMediaDir.delete(recursive: true);
        }
        await mediaNewDir.rename(finalMediaDir.path);
      } finally {
        if (await mediaNewDir.exists()) {
          try {
            await mediaNewDir.delete(recursive: true);
          } catch (_) {}
        }
      }
      progress.value = 0.9;

      // 6. 媒体文件已就位，使用分块 API 恢复数据库（避免大容量导入 OOM）
      currentPhase = '恢复数据库';
      message.value = '正在恢复数据库...';
      final useChunkFormat = await chunk0File.exists();
      int chunkIdx = 0;
      List<Map<String, dynamic>>? singleFormatData;
      Future<List<dynamic>?> getNextChunk() async {
        if (useChunkFormat) {
          while (true) {
            final f = File(
              path.join(tempImportDir.path, 'media_items_$chunkIdx.json'),
            );
            if (!await f.exists()) return null;
            message.value = '正在导入: media_items_$chunkIdx.json';
            final chunk =
                (jsonDecode(await f.readAsString()) as List<dynamic>)
                    .whereType<Map<String, dynamic>>()
                    .map((item) {
                      remapMediaItemPath(item);
                      return item;
                    })
                    .toList();
            chunkIdx++;
            if (chunk.isNotEmpty) return chunk;
          }
        } else {
          if (singleFormatData == null) {
            final data =
                jsonDecode(await jsonFile.readAsString()) as List<dynamic>? ??
                [];
            singleFormatData =
                data.whereType<Map<String, dynamic>>().map((item) {
                  remapMediaItemPath(item);
                  return item;
                }).toList();
          }
          const batchSize = 500;
          final start = chunkIdx * batchSize;
          if (start >= singleFormatData!.length) return null;
          final end = math.min(start + batchSize, singleFormatData!.length);
          chunkIdx++;
          return singleFormatData!.sublist(start, end);
        }
      }

      await _databaseService.replaceAllMediaItemsFromChunks(getNextChunk);

      // 7. 恢复设置（含媒体栏/预览播放偏好，与导出 zip 一致）
      message.value = '正在恢复设置...';
      if (settingsToImport != null) {
        final prefs = await SharedPreferences.getInstance();
        await applyMediaSettingsImportMap(prefs, settingsToImport);
      }
      progress.value = 0.95;

      // 8. 刷新界面和设置
      message.value = '导入完成，正在刷新...';
      await _loadSettings();
      _itemsToCleanup.clear();
      _lastImportCompletedAt = DateTime.now(); // 30 秒内不触发自动清理
      await _loadMediaItems();
      unawaited(_warmAllVideoThumbnailsInBackground());
      progress.value = 1.0;

      if (mounted) Navigator.of(context).pop(); // 关闭进度对话框

      // 导入成功后自动清理大缓存文件
      try {
        final cacheService = CacheService();
        final result = await cacheService.cleanLargeCacheFiles(maxSizeMB: 10);
        if (result['success'] == true && result['deletedCount'] > 0) {
          final deletedCount = result['deletedCount'] as int;
          final freedSize = result['freedSizeMB'] as String;
          debugPrint('导入后自动清理完成: 删除 $deletedCount 个大文件，释放 $freedSize MB 空间');
        }
      } catch (e) {
        debugPrint('导入后自动清理失败: $e');
      }
    } catch (e, stack) {
      importHadError = true;
      debugPrint('导入媒体数据失败 [$currentPhase]: $e\n$stack');
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        final userMsg = formatExportImportError(e, '导入失败');
        showExportImportErrorDialog(
          context,
          '媒体导入失败',
          '出错阶段：$currentPhase\n\n$userMsg',
        );
      }
    } finally {
      // 关键：无论成功或失败，都强制彻底清理本次导入的临时目录
      if (await tempImportDir.exists()) {
        try {
          await tempImportDir.delete(recursive: true);
          debugPrint('已彻底清理媒体导入临时目录: ${tempImportDir.path}');
        } catch (e) {
          debugPrint('警告：清理媒体导入临时目录失败: $e');
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('警告：部分临时导入文件未能清理: $e')));
          }
        }
      }
    }
  }

  Future<void> _showGenerateTestDataDialog() async {
    final scale = await showDialog<TestDataScale>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text('选择测试数据规模'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children:
                  TestDataScale.mediaScales.map((s) {
                    final suffix =
                        s.formulaMedia.substring(s.label.length) +
                        (s.isPeakTarget ? '（需数分钟）' : '');
                    return ListTile(
                      dense: true,
                      title: RichText(
                        text: TextSpan(
                          style: TextStyle(
                            color:
                                Theme.of(ctx).brightness == Brightness.dark
                                    ? Colors.white
                                    : Colors.black87,
                            fontSize: 14,
                          ),
                          children: [
                            TextSpan(
                              text: s.label,
                              style: TextStyle(
                                color: Colors.blue,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            TextSpan(text: suffix),
                          ],
                        ),
                      ),
                      onTap: () => Navigator.pop(ctx, s),
                    );
                  }).toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('取消'),
              ),
            ],
          ),
    );
    if (scale == null || !mounted) return;
    if (scale.isPeakTarget) {
      final confirm = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: Text('确认峰值测试'),
              content: Text('将生成约 15GB 测试数据，预计耗时数分钟。\n请确保设备有足够存储空间。\n\n继续？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text('继续'),
                ),
              ],
            ),
      );
      if (confirm != true || !mounted) return;
    }
    final progress = ValueNotifier<String>('准备中...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                ValueListenableBuilder<String>(
                  valueListenable: progress,
                  builder: (_, v, __) => Text(v),
                ),
              ],
            ),
          ),
    );
    try {
      final result = await TestDataGeneratorService().generateMediaTestData(
        scale,
        progress: progress,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '测试数据已生成：${result['count']} 条媒体，已生成约 ${result['actualSizeMB']} MB',
          ),
          duration: Duration(seconds: 4),
        ),
      );
      await _loadMediaItems();
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('生成失败: $e')));
      }
    }
  }

  /// 在删除旧 `media` 目录前，将仍被日记/文档/封面等引用、且压缩包中**没有同名文件**的现有文件复制到导入目标目录。
  /// 避免「整目录替换」误删日记本等媒体（此前仅替换 `media_items` 表，物理文件却被删光）。
  Future<void> _mergePreservedMediaFilesIntoDir({
    required Directory sourceMediaDir,
    required Directory targetDir,
    required Set<String> importBasenames,
    required Set<String> validPathsAbsolute,
  }) async {
    if (!await sourceMediaDir.exists()) return;
    final sourceRoot = path.normalize(path.absolute(sourceMediaDir.path));
    for (final abs in validPathsAbsolute) {
      final normalized = path.normalize(path.absolute(abs));
      String rel;
      try {
        rel = path.relative(normalized, from: sourceRoot);
      } catch (_) {
        continue;
      }
      if (rel.startsWith('..')) continue;
      final f = File(normalized);
      if (!await f.exists()) continue;
      final bn = path.basename(normalized);
      if (importBasenames.contains(bn)) continue;
      final dest = File(path.join(targetDir.path, bn));
      if (!await dest.exists()) {
        try {
          await copyFileWithStreamingToFile(f, dest);
        } catch (e) {
          debugPrint('保留非导入媒体文件失败: $normalized -> $e');
        }
      }
    }
  }

  // 优化后的递归拷贝目录方法 - 使用流式处理避免内存溢出，支持大文件
  /// [onProgress] 可选，用于导入时显示进度 (processed, total, message)
  Future<void> _copyDirectory(
    Directory src,
    Directory dst, {
    void Function(int processed, int total, String msg)? onProgress,
  }) async {
    if (!await dst.exists()) await dst.create(recursive: true);

    int totalFiles = 0;
    int processedFiles = 0;

    // 首先计算总文件数
    await for (var entity in src.list(recursive: true)) {
      if (entity is File) totalFiles++;
    }

    // 然后执行实际的复制操作
    await for (var entity in src.list(recursive: true)) {
      final relativePath = path.relative(entity.path, from: src.path);
      final newPath = path.join(dst.path, relativePath);

      if (entity is Directory) {
        await Directory(newPath).create(recursive: true);
      } else if (entity is File) {
        try {
          await File(newPath).create(recursive: true);

          // 使用流式复制，避免内存溢出
          final sourceFile = File(entity.path);
          final targetFile = File(newPath);

          if (await sourceFile.exists()) {
            final fileSize = await sourceFile.length();

            // 对于大文件（超过2MB），使用流式复制
            if (fileSize > kStreamingThresholdBytes) {
              await _copyLargeFile(sourceFile, targetFile);
            } else {
              // 小文件直接复制
              await sourceFile.copy(newPath);
            }
          }

          processedFiles++;
          if (onProgress != null &&
              (processedFiles % 25 == 0 || processedFiles == totalFiles)) {
            onProgress(
              processedFiles,
              totalFiles,
              '迁移媒体: $processedFiles/$totalFiles',
            );
          }

          // 每处理10个文件后稍作延迟，让系统有时间进行内存管理
          if (processedFiles % 10 == 0) {
            await Future.delayed(Duration(milliseconds: 50));
          }
        } catch (e) {
          Logger.log('复制文件失败: ${entity.path} -> $newPath, 错误: $e');
          // 继续处理其他文件
        }
      }
    }
  }

  // 分块复制大文件，避免内存溢出
  Future<void> _copyLargeFile(File source, File target) async {
    const int chunkSize = 64 * 1024; // 64KB chunks
    final sourceStream = source.openRead();
    final targetStream = target.openWrite();

    try {
      await for (final chunk in sourceStream) {
        targetStream.add(chunk);

        // 每处理一定大小的数据后稍作延迟
        if (chunk.length > 0) {
          await Future.delayed(Duration(milliseconds: 1));
        }
      }
    } finally {
      await targetStream.close();
    }
  }

  /// 初始化自动导入监听。相册列表与批量导入一致（MediaStore bucket + 合并补全）。
  Future<void> _initPhotoAutoImport() async {
    try {
      final List<AssetPathEntity> paths =
          await getMergedAlbumPathListForImport();
      final List<AssetEntity> allAssets = [];
      for (final p in paths) {
        allAssets.addAll(await p.getAssetListRange(start: 0, end: 100000));
      }
      _initialAssetIds = allAssets.map((e) => e.id).toSet();

      // 注册媒体库变化监听
      PhotoManager.addChangeCallback(_onPhotoLibraryChanged);
      PhotoManager.startChangeNotify(); // 必须调用，确保监听生效
      Logger.log('已注册媒体库变更监听，初始媒体数量: ${_initialAssetIds.length}');
    } catch (e) {
      Logger.log('初始化自动导入监听失败: $e');
    }
  }

  /// 媒体库变更回调
  Future<void> _onPhotoLibraryChanged([MethodCall? call]) async {
    Logger.log('[自动导入] 媒体库变更回调被触发');
    if (!_autoImportSilentMode) return; // 静默导入关闭时，不导入任何新媒体
    if (_isAutoProcessing) return;
    _isAutoProcessing = true;
    try {
      final List<AssetPathEntity> paths =
          await getMergedAlbumPathListForImport();
      final List<AssetEntity> allAssets = [];
      for (final p in paths) {
        allAssets.addAll(await p.getAssetListRange(start: 0, end: 100000));
      }
      final Set<String> currentIds = allAssets.map((e) => e.id).toSet();
      // 找出新增的assetId
      final Set<String> newIds = currentIds.difference(_initialAssetIds);
      if (newIds.isNotEmpty) {
        Logger.log('检测到新增媒体: ${newIds.length} 个');
        // 按 id 去重：同一图片可能出现在多个相册（Recent/Camera/Screenshots），避免重复导入
        for (final id in newIds) {
          final asset = allAssets.firstWhere((e) => e.id == id);
          await _autoImportAndDeleteAsset(asset);
        }
        // 更新快照，只保留应用打开期间的新增
        _initialAssetIds = currentIds;
      }
    } catch (e) {
      Logger.log('自动导入处理异常: $e');
    } finally {
      _isAutoProcessing = false;
    }
  }

  /// 自动导入媒体。静默导入开启时仅复制到应用媒体库，不删除原件（无确认框）
  Future<void> _autoImportAndDeleteAsset(AssetEntity asset) async {
    try {
      // 先检查 asset_id 是否已导入（与后台服务共享去重，防止重复导入）
      final alreadyImported = await _databaseService.isAssetImported(asset.id);
      if (alreadyImported) {
        Logger.log('自动导入跳过（已导入）: ${asset.id}');
        return;
      }
      final file = await asset.file;
      if (file == null) return;
      // 仅处理图片/视频
      if (asset.type != AssetType.image && asset.type != AssetType.video)
        return;
      // 导入到应用媒体库（静默：无进度框、无成功提示，原件保留）
      await _saveMultipleMediaToAppDirectory(
        [file],
        asset.type == AssetType.image ? MediaType.image : MediaType.video,
        silent: true,
      );
      await _databaseService.markAssetImported(asset.id);
      Logger.log('自动导入（静默）: ${file.path}，原件已保留');
    } catch (e) {
      Logger.log('自动导入媒体失败: $e');
    }
  }

  /// 底部操作栏：选中时显示计数+移动+删除+查重，未选中时仅显示查重按钮
  Widget _buildBottomActionBar() {
    final hasSelection = _selectedItems.isNotEmpty;
    int imageCount = 0;
    int videoCount = 0;
    int folderCount = 0;
    if (hasSelection) {
      for (var item in _mediaItems) {
        if (!_selectedItems.contains(item.id)) continue;
        if (item.type == MediaType.image)
          imageCount++;
        else if (item.type == MediaType.video)
          videoCount++;
        else if (item.type == MediaType.folder)
          folderCount++;
      }
    }

    if (!hasSelection) {
      // 多选模式下显示退出按钮，否则不显示（查重已移至 AppBar）
      if (!_isMultiSelectMode) return const SizedBox.shrink();
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 16, bottom: 8),
          child: FloatingActionButton.small(
            onPressed: _toggleMultiSelectMode,
            tooltip: '退出多选',
            heroTag: 'deduplicate_current',
            child: const Icon(Icons.close),
          ),
        ),
      );
    }

    final parts = <String>[];
    if (imageCount > 0) parts.add('$imageCount张图片');
    if (videoCount > 0) parts.add('$videoCount个视频');
    if (folderCount > 0) parts.add('$folderCount个文件夹');
    final countText =
        parts.isEmpty ? '${_selectedItems.length}项' : parts.join(' ');

    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '已选 $countText',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(
                _mediaItems
                            .where((i) => i.type != MediaType.folder)
                            .every((i) => _selectedItems.contains(i)) &&
                        _mediaItems.any((i) => i.type != MediaType.folder)
                    ? Icons.deselect
                    : Icons.select_all,
              ),
              onPressed: _selectAll,
              tooltip: '全选/取消全选',
            ),
            IconButton(
              icon: const Icon(Icons.drive_file_move_outline),
              onPressed: () => _showMoveDialog(),
              tooltip: '移动选定项',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteSelectedItems,
              tooltip: '删除选定项',
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _toggleMultiSelectMode,
              tooltip: '退出多选',
            ),
          ],
        ),
      ),
    );
  }

  /// 略缩图顶栏齿轮：单击延迟打开设置菜单；约 320ms 内再点一次视为双击，在多选且已勾选时批量切换收藏。
  void _onSettingsGearTapForSingleOrDouble() {
    final now = DateTime.now();
    if (_settingsIconLastTapTime != null &&
        now.difference(_settingsIconLastTapTime!) <=
            const Duration(milliseconds: 320)) {
      _settingsIconSingleTapTimer?.cancel();
      _settingsIconSingleTapTimer = null;
      _settingsIconLastTapTime = null;
      unawaited(_toggleFavoriteFromSettingsDoubleTap());
      return;
    }
    _settingsIconLastTapTime = now;
    _settingsIconSingleTapTimer?.cancel();
    _settingsIconSingleTapTimer = Timer(const Duration(milliseconds: 360), () {
      _settingsIconSingleTapTimer = null;
      _settingsIconLastTapTime = null;
      if (mounted) _showSettingsMenu();
    });
  }

  /// 双击顶栏齿轮：仅在「多选模式且已勾选媒体（含全选）」时，对所选图/视频逐条切换收藏。
  Future<void> _toggleFavoriteFromSettingsDoubleTap() async {
    if (_currentDirectory == 'recycle_bin') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('回收站中的媒体无法标星收藏')),
        );
      }
      return;
    }

    if (!_isMultiSelectMode) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '请先长按略缩图进入多选，勾选或使用底部「全选」，再快速连点两次齿轮',
            ),
          ),
        );
      }
      return;
    }

    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '请勾选要切换收藏的略缩图，或使用底部「全选」，再快速连点两次齿轮',
            ),
          ),
        );
      }
      return;
    }

    final List<String> ids =
        _selectedItems
            .where((id) => id != 'recycle_bin' && id != 'favorites')
            .toList();

    int ok = 0;
    String? lastError;
    for (final id in ids) {
      final idx = _mediaItems.indexWhere((e) => e.id == id);
      if (idx < 0) {
        lastError = '当前列表中找不到该媒体';
        continue;
      }
      final item = _mediaItems[idx];
      if (item.type != MediaType.image && item.type != MediaType.video) {
        continue;
      }
      try {
        await _databaseService.toggleMediaItemFavorite(id);
        ok++;
      } catch (e) {
        lastError = e.toString();
      }
    }

    if (!mounted) return;
    if (ok > 0) {
      await _loadMediaItems();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok > 1 ? '已切换 $ok 个媒体的收藏状态' : '已切换收藏状态'),
        ),
      );
    } else {
      final bool missingInGrid = ids.any(
        (id) => _mediaItems.indexWhere((e) => e.id == id) < 0,
      );
      final String msg =
          missingInGrid
              ? '所选条目在当前列表中不存在，请刷新后重试'
              : (lastError != null
                  ? '收藏失败: $lastError'
                  : '所选中没有可对图/视频标星的项（文件夹等已跳过）');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  List<PopupMenuEntry<String>> _thumbnailOverflowMenuEntries(MediaItem item) {
    return [
      const PopupMenuItem(value: 'rename', child: Text('重命名')),
      const PopupMenuItem(value: 'properties', child: Text('属性')),
      const PopupMenuItem(value: 'move', child: Text('移动到')),
      if (item.type != MediaType.folder)
        const PopupMenuItem(value: 'export', child: Text('导出')),
      const PopupMenuItem(
        value: 'delete',
        child: Text('删除', style: TextStyle(color: Colors.red)),
      ),
      const PopupMenuItem(value: 'multi_select', child: Text('多选')),
      const PopupMenuItem(value: 'select_all', child: Text('全选')),
    ];
  }

  void _handleThumbnailOverflowMenuResult(String? value, MediaItem item) {
    if (value == null) return;
    if (value == 'delete') {
      _deleteMediaItem(item);
    } else if (value == 'move') {
      _showMoveDialog(item: item);
    } else if (value == 'rename') {
      _renameMediaItem(item);
    } else if (value == 'multi_select') {
      _toggleMultiSelectMode();
    } else if (value == 'select_all') {
      _selectAll();
    } else if (value == 'export') {
      _exportMediaItem(item);
    } else if (value == 'properties') {
      _showMediaItemProperties(item);
    }
  }

  Future<void> _showThumbnailOverflowMenu(
    BuildContext anchorContext,
    MediaItem item,
  ) async {
    final overlay = Overlay.maybeOf(anchorContext);
    if (overlay == null) return;
    final box = anchorContext.findRenderObject() as RenderBox?;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        box.size.width,
        box.size.height,
      ),
      Offset.zero & overlayBox.size,
    );
    final choice = await showMenu<String>(
      context: anchorContext,
      position: position,
      items: _thumbnailOverflowMenuEntries(item),
    );
    if (!mounted) return;
    _handleThumbnailOverflowMenuResult(choice, item);
  }

  /// 略缩图右上角爱心/三点：快速双击切换收藏；单击约 360ms 后弹出原溢出菜单。
  void _onThumbnailCornerTap(MediaItem item, BuildContext anchorContext) {
    final now = DateTime.now();
    final pending = _thumbCornerMenuPendingItem;
    if (pending != null &&
        pending.id == item.id &&
        _thumbCornerMenuLastTapTime != null &&
        now.difference(_thumbCornerMenuLastTapTime!) <=
            const Duration(milliseconds: 320)) {
      _thumbCornerMenuSingleTapTimer?.cancel();
      _thumbCornerMenuSingleTapTimer = null;
      _thumbCornerMenuPendingItem = null;
      _thumbCornerMenuLastTapTime = null;
      _thumbCornerMenuAnchorContext = null;
      unawaited(_toggleFavoriteForThumbnailItem(item));
      return;
    }
    if (pending != null && pending.id != item.id) {
      _thumbCornerMenuSingleTapTimer?.cancel();
    }
    _thumbCornerMenuPendingItem = item;
    _thumbCornerMenuLastTapTime = now;
    _thumbCornerMenuAnchorContext = anchorContext;
    _thumbCornerMenuSingleTapTimer?.cancel();
    _thumbCornerMenuSingleTapTimer = Timer(const Duration(milliseconds: 360), () {
      final ctx = _thumbCornerMenuAnchorContext;
      final it = _thumbCornerMenuPendingItem;
      _thumbCornerMenuSingleTapTimer = null;
      _thumbCornerMenuPendingItem = null;
      _thumbCornerMenuLastTapTime = null;
      _thumbCornerMenuAnchorContext = null;
      if (!mounted || ctx == null || !ctx.mounted || it == null) return;
      unawaited(_showThumbnailOverflowMenu(ctx, it));
    });
  }

  Future<void> _toggleFavoriteForThumbnailItem(MediaItem item) async {
    if (_currentDirectory == 'recycle_bin') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('回收站中的媒体无法标星收藏')),
        );
      }
      return;
    }
    if (item.type != MediaType.image && item.type != MediaType.video) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件夹无法标星收藏')),
        );
      }
      return;
    }
    try {
      await _databaseService.toggleMediaItemFavorite(item.id);
      if (!mounted) return;
      await _loadMediaItems();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('收藏失败: $e')),
        );
      }
    }
  }

  /// 显示存储管理页面
  void _showStorageManagement() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const StorageManagementPage()),
    );
  }

  /// 无边透明顶栏：媒体页主界面用纯黑字/图标、无阴影（浅色 Scaffold 底上可读）
  Widget _buildMediaFloatingTopBar() {
    const Color fg = Color(0xDE000000);
    final pad = MediaQuery.paddingOf(context);
    const ts = TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w500,
      color: fg,
    );
    const countStyle = TextStyle(fontSize: 11, color: fg);

    final bool showRootTitle =
        !Navigator.of(context).canPop() && _currentDirectory == 'root';
    const titleText = '媒体';

    final iconBtnStyle = IconButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      minimumSize: const Size(36, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
    );

    Widget leadingSlot;
    if (Navigator.of(context).canPop()) {
      leadingSlot = IconButton(
        icon: const Icon(Icons.arrow_back, color: fg),
        onPressed: () => Navigator.of(context).pop(),
        tooltip: '返回',
        style: iconBtnStyle,
      );
    } else if (_currentDirectory != 'root') {
      leadingSlot = IconButton(
        icon: const Icon(Icons.arrow_upward, color: fg),
        onPressed: _navigateUp,
        tooltip: '返回上级',
        style: iconBtnStyle,
      );
    } else {
      leadingSlot = const SizedBox(width: 2);
    }

    final countsChip = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image, size: 18, color: fg),
          const SizedBox(width: 2),
          Text(
            '$_imageCount',
            style: countStyle.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.videocam, size: 18, color: fg),
          const SizedBox(width: 2),
          Text(
            '$_videoCount',
            style: countStyle.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          color: Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              leadingSlot,
              const SizedBox(width: 2),
              if (_currentDirectory == 'recycle_bin')
                IconButton(
                  icon: const Icon(
                    Icons.delete_forever,
                    size: 24,
                    color: Colors.redAccent,
                  ),
                  onPressed: _clearRecycleBin,
                  tooltip: '清空回收站',
                  style: iconBtnStyle,
                )
              else if (showRootTitle)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    titleText,
                    style: ts,
                    maxLines: 1,
                    textAlign: TextAlign.left,
                  ),
                ),
              const SizedBox(width: 2),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    countsChip,
                    IconButton(
                      icon: Icon(
                        _mediaVisible ? Icons.visibility : Icons.visibility_off,
                        size: 18,
                        color: fg,
                      ),
                      onPressed: _toggleMediaVisibility,
                      tooltip: '切换媒体可见性',
                      style: iconBtnStyle,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.storage,
                        size: 18,
                        color: fg,
                      ),
                      onPressed: _showStorageManagement,
                      tooltip: '存储管理',
                      style: iconBtnStyle,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.settings,
                        size: 18,
                        color: fg,
                      ),
                      onPressed: _onSettingsGearTapForSingleOrDouble,
                      tooltip:
                          '设置（多选并勾选后，连点两次齿轮可批量切换收藏）',
                      style: iconBtnStyle,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.refresh,
                        size: 18,
                        color: fg,
                      ),
                      onPressed: () => unawaited(_refreshMediaAndThumbnails()),
                      tooltip: '刷新',
                      style: iconBtnStyle,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.find_replace,
                        size: 18,
                        color: fg,
                      ),
                      onPressed: _deduplicateCurrentFolder,
                      tooltip: '当前目录查重',
                      style: iconBtnStyle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        // 媒体主页面固定浅色底，避免从浏览器/预览返回时透出下层黑色路由
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(top: topInset),
                child: _buildMediaGrid(),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(child: _buildBottomActionBar()),
            ),
            _buildMediaFloatingTopBar(),
          ],
        ),
      ),
    );
  }
}

// 进度弹窗组件
Future<void> showProgressDialog(
  BuildContext context,
  ValueNotifier<double> progress,
  ValueNotifier<String> message,
) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder:
        (context) => AlertDialog(
          content: SizedBox(
            width: 260,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder:
                      (context, value, _) =>
                          LinearProgressIndicator(value: value),
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder:
                      (context, value, _) => Text(
                        '${(value * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 16),
                      ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<String>(
                  valueListenable: message,
                  builder:
                      (context, value, _) =>
                          Text(value, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
  );
}

/// 带百分比进度与「取消」的阻塞式进度框。业务在循环中检查 [cancelRequested]，
/// 结束时由调用方 [Navigator.pop] 关闭。
void showCancellableProgressDialog(
  BuildContext context, {
  required ValueNotifier<double> progress,
  required ValueNotifier<String> message,
  required ValueNotifier<bool> cancelRequested,
  String title = '请稍候',
}) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder:
                      (_, v, __) =>
                          LinearProgressIndicator(value: v.clamp(0.0, 1.0)),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder:
                      (_, v, __) => Text(
                        '${(v.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<String>(
                  valueListenable: message,
                  builder:
                      (_, msg, __) =>
                          Text(msg, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelRequested.value = true;
                message.value = '正在停止…';
              },
              child: const Text('取消'),
            ),
          ],
        ),
      );
    },
  );
}
