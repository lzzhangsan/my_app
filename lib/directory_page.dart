import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier;
import 'package:flutter/material.dart';
import 'core/service_locator.dart';
import 'services/logger.dart';
import 'services/database_service.dart';
import 'document_editor_page.dart';
import 'package:flutter/services.dart'; // For haptic feedback
import 'dart:io';
import 'package:flutter_colorpicker/flutter_colorpicker.dart'; // For color picker
import 'package:file_picker/file_picker.dart'; // For file picker
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async'; // For Timer
import 'package:path/path.dart' as path;
import 'utils/background_physical_file.dart';
import 'models/background_media_origin.dart';
import 'utils/background_layer_defaults.dart';
import 'services/image_picker_service.dart';
import 'services/file_cleanup_service.dart';
import 'services/test_data_generator_service.dart';
import 'package:archive/archive_io.dart';
import 'services/export_import_utils.dart';
import 'services/document_visual_export_service.dart';
import 'utils/export_import_error_utils.dart';
import 'widgets/stored_view_image_layer.dart';
import 'widgets/stored_view_video_background_layer.dart';
import 'widgets/floating_ui_shadows.dart';
import 'widgets/safe_modal_sheet_body.dart';
import 'widgets/move_to_folder_sheet.dart';
import 'widgets/directory_last_visited_frame.dart';
import 'models/media_type.dart';
import 'utils/background_media_preview.dart';
import 'app_route_observer.dart';

class DirectoryPage extends StatefulWidget {
  final Function(String) onDocumentOpen;

  /// 从浏览器等路由 push 进入时为 true：根目录显示返回按钮，`Navigator.pop` 回到上一页。
  final bool showRouteBackButton;

  DirectoryPage({
    Key? key,
    required this.onDocumentOpen,
    this.showRouteBackButton = false,
  }) : super(key: key);

  @override
  _DirectoryPageState createState() => _DirectoryPageState();
}

class _DirectoryPageState extends State<DirectoryPage>
    with WidgetsBindingObserver, RouteAware {
  // 判断folderName是否是targetFolderName的子文件夹
  bool _isChildFolder(
    String folderName,
    String targetFolderName,
    List<DirectoryItem> folders,
  ) {
    DirectoryItem? current = folders.firstWhere(
      (f) => f.name == targetFolderName,
      orElse:
          () => DirectoryItem(
            name: '',
            type: ItemType.folder,
            order: 0,
            isTemplate: false,
          ),
    );
    while (current != null && current.name != '') {
      if (current.name == folderName) return true;
      final parentName = current.parentFolder ?? '';
      if (parentName == '') break;
      current = folders.firstWhere(
        (f) => f.name == parentName,
        orElse:
            () => DirectoryItem(
              name: '',
              type: ItemType.folder,
              order: 0,
              isTemplate: false,
            ),
      );
    }
    return false;
  }

  void _showWebUnsupportedDialog() {
    if (!mounted || !kIsWeb) return; // Also check kIsWeb to be sure
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('功能提示'),
            content: Text('此功能在Web版本中当前不可用或受限。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('确定'),
              ),
            ],
          ),
    );
  }

  List<DirectoryItem> _items = [];
  String? _currentParentFolder;
  File? _backgroundImage;
  File? _backgroundVideo;
  BackgroundMediaOrigin? _backgroundImageOrigin;
  BackgroundMediaOrigin? _backgroundVideoOrigin;
  Color? _backgroundColor;
  int _backgroundViewRefreshTick = 0;

  /// Navigator 上 push 了子页面（如文档编辑）时为 true，暂停目录背景视频与声音。
  final ValueNotifier<bool> _pauseDirectoryBgVideoForChildRoute =
      ValueNotifier<bool>(false);
  List<Map<String, dynamic>> _templateDocuments = [];
  String? _lastCreatedItemName;
  ItemType? _lastCreatedItemType;
  Timer? _highlightTimer;
  bool _isHighlightingNewItem = false;

  /// 从子文件夹返回或从文档编辑返回后，在当前列表中标示该项（与媒体页预览返回的蓝框一致）。
  String? _lastVisitedItemName;
  ItemType? _lastVisitedItemType;
  bool _isMultiSelectMode = false;
  final List<DirectoryItem> _selectedItems = [];
  List<String> _folderStack = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb) {
      _loadData();
      _loadBackgroundSettings();
      _loadTemplateDocuments();
      // 启动时检查数据完整性
      _checkDataIntegrityOnStartup();
    } else {
      Logger.log(
        "Web environment detected: Database-dependent features in initState are skipped.",
      );
      // Initialize with empty or default states for web
      if (mounted) {
        setState(() {
          _items = [];
          _templateDocuments = [];
          _backgroundColor = Colors.white; // Default background for web
        });
      }
    }
  }

  /// 启动时检查数据完整性
  Future<void> _checkDataIntegrityOnStartup() async {
    try {
      final report = await getService<DatabaseService>().checkDataIntegrity();
      if (!report['isValid']) {
        Logger.log('启动时发现数据完整性问题: ${report['issues']}');
        // 自动修复数据完整性问题
        await getService<DatabaseService>().repairDataIntegrity();
        Logger.log('已自动修复数据完整性问题');

        // 重新加载数据
        if (mounted) {
          await _loadData();
        }
      }
    } catch (e) {
      Logger.log('启动时数据完整性检查失败: $e');
    }
  }

  @override
  void dispose() {
    _saveCurrentBackgroundState();
    appRouteObserver.unsubscribe(this);
    _pauseDirectoryBgVideoForChildRoute.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
    _loadBackgroundSettings();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (mounted && state == AppLifecycleState.resumed) {
      _loadBackgroundSettings();
      _loadData();
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _saveCurrentBackgroundState();
    }
  }

  @override
  void didPushNext() {
    Logger.log('DirectoryPage被覆盖 - 保存当前状态');
    _saveCurrentBackgroundState();
    _pauseDirectoryBgVideoForChildRoute.value = true;
  }

  @override
  void didPopNext() {
    Logger.log('DirectoryPage重新显示 - 重新加载设置');
    _pauseDirectoryBgVideoForChildRoute.value = false;
    Logger.log('当前文件夹: $_currentParentFolder, 文件夹栈: $_folderStack');
    if (mounted) {
      _loadData();
    }
  }

  void _toggleMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = !_isMultiSelectMode;
      if (!_isMultiSelectMode) {
        _selectedItems.clear();
        for (var item in _items) {
          item.isSelected = false;
        }
      }
    });
  }

  void _toggleItemSelection(DirectoryItem item) {
    setState(() {
      item.isSelected = !item.isSelected;
      if (item.isSelected) {
        _selectedItems.add(item);
      } else {
        _selectedItems.remove(item);
      }
    });
  }

  void _selectAllItems() {
    setState(() {
      bool allSelected = _items.every((item) => item.isSelected);
      if (allSelected) {
        _selectedItems.clear();
        for (var item in _items) {
          item.isSelected = false;
        }
      } else {
        _selectedItems.clear();
        for (var item in _items) {
          item.isSelected = true;
          _selectedItems.add(item);
        }
      }
    });
  }

  void _deleteSelectedItems() async {
    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('请先选择要删除的项目')));
      }
      return;
    }

    bool confirmDelete = await _showDeleteConfirmationDialog("选中的项目", "这些项目");
    if (confirmDelete) {
      try {
        for (var item in _selectedItems) {
          if (item.type == ItemType.document) {
            await getService<DatabaseService>().deleteDocument(
              item.name,
              parentFolder: _currentParentFolder,
            );
          } else if (item.type == ItemType.folder) {
            await getService<DatabaseService>().deleteFolder(
              item.name,
              parentFolder: _currentParentFolder,
            );
          }
        }
        _selectedItems.clear();
        _isMultiSelectMode = false;
        if (mounted) {
          await _loadData();
        }
      } catch (e) {
        Logger.log('批量删除出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('批量删除出错，请重试')));
        }
      }
    }
  }

  void _moveSelectedItemsToFolder() async {
    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('请先选择要移动的项目')));
      }
      return;
    }
    final excludeIds = <String>{};
    final dbService = getService<DatabaseService>();
    final folders = await dbService.getAllDirectoryFolders();
    for (var item in _selectedItems) {
      if (item.type == ItemType.folder) {
        final folder = folders.firstWhere(
          (f) => f['name'] == item.name,
          orElse:
              () => <String, dynamic>{
                'id': '',
                'parent_folder': null,
                'name': '',
              },
        );
        if (folder['id'] != '') {
          excludeIds.add(folder['id'] as String);
          excludeIds.addAll(
            _getAllSubFolderIds(folder['id'] as String, folders),
          );
        }
      } else if (item.type == ItemType.document) {
        final doc = await dbService.getDocumentByName(item.name);
        if (doc != null && doc['parent_folder'] != null) {
          excludeIds.add(doc['parent_folder'] as String);
        }
      }
    }
    if (_currentParentFolder != null) {
      for (final f in folders) {
        if (f['name'] == _currentParentFolder && f['id'] != null) {
          excludeIds.add(f['id'] as String);
          break;
        }
      }
    }
    bool showRoot = _currentParentFolder != null;
    final targetFolderName = await _selectFolder(
      excludeFolderIds: excludeIds.toList(),
      showRoot: showRoot,
    );
    if (targetFolderName == null) return;
    try {
      for (var item in _selectedItems) {
        if (item.type == ItemType.document) {
          await dbService.updateDocumentParentFolder(
            item.name,
            targetFolderName.isEmpty ? null : targetFolderName,
          );
        } else if (item.type == ItemType.folder) {
          await dbService.updateFolderParentFolder(
            item.name,
            targetFolderName.isEmpty ? null : targetFolderName,
          );
        }
      }
      _selectedItems.clear();
      _isMultiSelectMode = false;
      if (mounted) {
        await _loadData();
      }
    } catch (e) {
      Logger.log('批量移动出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('批量移动出错，请重试')));
      }
    }
  }

  void _moveSelectedItemsToDirectory() async {
    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('请先选择要移动的项目')));
      }
      return;
    }

    bool confirmMove = await _showMoveConfirmationDialog("选中的项目", "这些项目", "目录");
    if (confirmMove) {
      try {
        final dbService = getService<DatabaseService>();

        for (var item in _selectedItems) {
          if (item.type == ItemType.document) {
            Logger.log('移动文档 ${item.name} 到根目录');
            await dbService.updateDocumentParentFolder(item.name, null);
          } else if (item.type == ItemType.folder) {
            Logger.log('移动文件夹 ${item.name} 到根目录');
            await dbService.updateFolderParentFolder(item.name, null);
          }
        }
        _selectedItems.clear();
        _isMultiSelectMode = false;
        if (mounted) {
          Logger.log('移动到根目录完成，重新加载数据...');
          await _loadData();
        }
      } catch (e) {
        Logger.log('批量移动到目录出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('批量移动到目录出错，请重试')));
        }
      }
    }
  }

  Future<void> _loadBackgroundSettings() async {
    if (kIsWeb) {
      Logger.log(
        "Web environment: Skipping background settings load from database.",
      );
      if (mounted) {
        setState(() {
          _backgroundImage = null;
          _backgroundVideo = null;
          _backgroundColor = Colors.white; // Default for web
        });
      }
      return;
    }
    try {
      Logger.log('开始加载背景设置 for folder: $_currentParentFolder');
      Map<String, dynamic>? settings = await getService<DatabaseService>()
          .getDirectorySettings(_currentParentFolder);

      if (settings != null) {
        String? imagePath = settings['background_image_path'] as String?;
        String? videoPath = settings['background_video_path'] as String?;
        int? colorValue = settings['background_color'];

        Logger.log(
          '从数据库加载设置 - 图片: ${imagePath ?? "空"}, 视频: ${videoPath ?? "空"}, 颜色: ${colorValue ?? "空"}',
        );

        if (mounted) {
          setState(() {
            if (colorValue != null) {
              _backgroundColor = Color(colorValue);
              Logger.log('已加载背景颜色: $colorValue');
            } else {
              _backgroundColor = null;
              Logger.log('背景颜色为空，使用默认白色');
            }
          });
        }

        File? nextImage;
        File? nextVideo;

        if (videoPath != null && videoPath.isNotEmpty) {
          final vf = File(videoPath);
          if (await vf.exists()) {
            nextVideo = vf;
            Logger.log('已加载背景视频: $videoPath');
          } else {
            Logger.log('背景视频文件不存在: $videoPath');
            await getService<DatabaseService>().deleteDirectoryBackgroundVideo(
              _currentParentFolder,
            );
          }
        }

        if (nextVideo == null && imagePath != null && imagePath.isNotEmpty) {
          final imageFile = File(imagePath);
          final exists = await imageFile.exists();
          Logger.log('检查图片文件: $imagePath, 是否存在: $exists');
          if (exists) {
            nextImage = imageFile;
            Logger.log('已加载背景图片: $imagePath');
          } else {
            Logger.log('背景图片文件不存在: $imagePath');
            await getService<DatabaseService>().deleteDirectoryBackgroundImage(
              _currentParentFolder,
            );
          }
        }

        if (mounted) {
          setState(() {
            _backgroundVideo = nextVideo;
            _backgroundImage = nextImage;
            _backgroundImageOrigin = BackgroundMediaOrigin.fromDbValue(
              settings['background_image_origin'] as int?,
            );
            _backgroundVideoOrigin = BackgroundMediaOrigin.fromDbValue(
              settings['background_video_origin'] as int?,
            );
          });
        }
      } else {
        Logger.log('未找到目录设置，使用默认背景');
        if (mounted) {
          setState(() {
            _backgroundImage = null;
            _backgroundVideo = null;
            _backgroundImageOrigin = null;
            _backgroundVideoOrigin = null;
            _backgroundColor = null; // 使用默认白色
          });
        }
      }
    } catch (e) {
      Logger.log('加载背景设置时出错: $e');
      if (mounted) {
        setState(() {
          _backgroundImage = null;
          _backgroundVideo = null;
          _backgroundImageOrigin = null;
          _backgroundVideoOrigin = null;
          _backgroundColor = null; // 使用默认白色
        });
      }
    }
  }

  Future<void> _pickBackgroundImage() async {
    if (kIsWeb) {
      _showWebUnsupportedDialog();
      return;
    }
    try {
      final picked = await ImagePickerService.pickImage(context);

      if (picked != null) {
        final Directory appDocDir = await getApplicationDocumentsDirectory();
        final String backgroundImagesPath =
            '${appDocDir.path}/background_images';

        final Directory backgroundDir = Directory(backgroundImagesPath);
        if (!await backgroundDir.exists()) {
          await backgroundDir.create(recursive: true);
        }

        final String fileName =
            'background_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final String permanentPath = '$backgroundImagesPath/$fileName';

        final File newImage = await File(picked.path).copy(permanentPath);

        if (mounted) {
          setState(() {
            _backgroundImage = newImage;
            _backgroundVideo = null;
            _backgroundImageOrigin = picked.origin;
            _backgroundVideoOrigin = null;
          });
        }

        await getService<DatabaseService>().insertOrUpdateDirectorySettings(
          folderName: _currentParentFolder,
          imagePath: permanentPath,
          backgroundImageOrigin: picked.origin,
        );

        Logger.log('已持久化保存背景图片: $permanentPath');
      }
    } catch (e) {
      Logger.log('选择背景图片出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择背景图像出错。请重试。')));
      }
    }
  }

  Future<void> _removeBackgroundImage() async {
    if (kIsWeb) {
      _showWebUnsupportedDialog();
      return;
    }
    final shouldDelete = await _showDeleteConfirmationDialog("背景图像", "目录的背景图像");
    if (shouldDelete) {
      try {
        final appDir = (await getApplicationDocumentsDirectory()).path;
        await deleteBackgroundPhysicalFileIfAllowed(
          _backgroundImage?.path,
          _backgroundImageOrigin,
          appDir,
        );
        await getService<DatabaseService>().deleteDirectoryBackgroundImage(
          _currentParentFolder,
        );

        if (mounted) {
          setState(() {
            _backgroundImage = null;
            _backgroundImageOrigin = null;
          });
        }

        Logger.log('背景图片已删除');
      } catch (e) {
        Logger.log('移除背景图片出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('移除背景图像出错。请重试。')));
        }
      }
    }
  }

  Future<void> _pickBackgroundVideo() async {
    if (kIsWeb) {
      _showWebUnsupportedDialog();
      return;
    }
    try {
      final picked = await ImagePickerService.pickVideo(context);
      if (picked == null) return;

      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String backgroundVideosPath = '${appDocDir.path}/background_videos';
      final Directory backgroundDir = Directory(backgroundVideosPath);
      if (!await backgroundDir.exists()) {
        await backgroundDir.create(recursive: true);
      }

      final ext =
          path.extension(picked.path).isNotEmpty
              ? path.extension(picked.path)
              : '.mp4';
      final String fileName =
          'background_${DateTime.now().millisecondsSinceEpoch}$ext';
      final String permanentPath = '$backgroundVideosPath/$fileName';

      final File newVideo = await File(picked.path).copy(permanentPath);

      if (mounted) {
        setState(() {
          _backgroundVideo = newVideo;
          _backgroundImage = null;
          _backgroundVideoOrigin = picked.origin;
          _backgroundImageOrigin = null;
        });
      }

      await getService<DatabaseService>().insertOrUpdateDirectorySettings(
        folderName: _currentParentFolder,
        videoPath: permanentPath,
        backgroundVideoOrigin: picked.origin,
      );

      Logger.log('已持久化保存背景视频: $permanentPath');
    } catch (e) {
      Logger.log('选择背景视频出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择背景视频出错。请重试。')));
      }
    }
  }

  Future<void> _removeBackgroundVideo() async {
    if (kIsWeb) {
      _showWebUnsupportedDialog();
      return;
    }
    final shouldDelete = await _showDeleteConfirmationDialog('背景视频', '目录的背景视频');
    if (shouldDelete) {
      try {
        final appDir = (await getApplicationDocumentsDirectory()).path;
        await deleteBackgroundPhysicalFileIfAllowed(
          _backgroundVideo?.path,
          _backgroundVideoOrigin,
          appDir,
        );
        await getService<DatabaseService>().deleteDirectoryBackgroundVideo(
          _currentParentFolder,
        );

        if (mounted) {
          setState(() {
            _backgroundVideo = null;
            _backgroundVideoOrigin = null;
          });
        }

        Logger.log('背景视频已删除');
      } catch (e) {
        Logger.log('移除背景视频出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('移除背景视频出错。请重试。')));
        }
      }
    }
  }

  Future<void> _pickBackgroundColor() async {
    if (kIsWeb) {
      _showWebUnsupportedDialog();
      return;
    }
    Color? pickedColor = await _showColorPickerDialog();
    if (pickedColor != null) {
      try {
        if (mounted) {
          setState(() {
            _backgroundColor = pickedColor;
          });
        }

        await getService<DatabaseService>().insertOrUpdateDirectorySettings(
          folderName: _currentParentFolder,
          colorValue: _backgroundColor!.value,
        );

        Logger.log('成功更新背景颜色: ${_backgroundColor!.value}');
      } catch (e) {
        Logger.log('设置背景颜色时出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('设置背景颜色出错。请重试。')));
        }
      }
    }
  }

  Future<Color?> _showColorPickerDialog() async {
    // 保存原始颜色，用于取消时恢复
    final originalColor = _backgroundColor;

    Color? pickedColor = await showDialog<Color>(
      context: context,
      builder: (context) {
        Color tempColor = backgroundColorPickerSeed(_backgroundColor);
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              contentPadding: EdgeInsets.all(8.0),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 颜色选择器，增加高度
                  ColorPicker(
                    pickerColor: tempColor,
                    onColorChanged: (Color color) {
                      tempColor = color;
                      // 实时预览：立即更新背景颜色
                      setState(() {
                        _backgroundColor = color;
                      });
                    },
                    colorPickerWidth: 280.0, // 加长滑块条
                    pickerAreaHeightPercent: 0.6, // 增加颜色选择区域高度
                    enableAlpha: true,
                    displayThumbColor: true,
                    showLabel: false,
                    paletteType: PaletteType.hsv,
                  ),
                  SizedBox(height: 2), // 进一步紧凑间距
                  // 按钮行，向上移动
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Expanded(
                        child: TextButton(
                          child: Text('取消', style: TextStyle(fontSize: 14)),
                          onPressed: () {
                            // 恢复原始颜色
                            setState(() {
                              _backgroundColor = originalColor;
                            });
                            Navigator.of(context).pop();
                          },
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: TextButton(
                          child: Text('确定', style: TextStyle(fontSize: 14)),
                          onPressed: () => Navigator.of(context).pop(tempColor),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    // 如果用户选择了颜色，保存到数据库
    if (pickedColor != null) {
      await _saveBackgroundColor(pickedColor);
    }

    return pickedColor;
  }

  /// 保存背景颜色到数据库
  Future<void> _openBackgroundImagePreviewEditor() async {
    final bg = _backgroundImage;
    if (bg == null) return;
    await pushBackgroundMediaAdjustPage(context, bg, MediaType.image);
    if (!mounted) return;
    setState(() {
      _backgroundViewRefreshTick++;
    });
  }

  Future<void> _openBackgroundVideoPreviewEditor() async {
    final v = _backgroundVideo;
    if (v == null) return;
    await pushBackgroundMediaAdjustPage(context, v, MediaType.video);
    if (!mounted) return;
    setState(() {
      _backgroundViewRefreshTick++;
    });
  }

  Future<void> _saveBackgroundColor(Color color) async {
    try {
      await getService<DatabaseService>().insertOrUpdateDirectorySettings(
        folderName: _currentParentFolder,
        colorValue: color.value,
      );

      setState(() {
        _backgroundColor = color;
      });

      Logger.log('目录背景颜色已保存: ${color.value}');
    } catch (e) {
      Logger.log('保存背景颜色时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存背景颜色失败: $e')));
      }
    }
  }

  Future<void> _loadTemplateDocuments() async {
    if (kIsWeb) {
      Logger.log(
        "Web environment: Skipping template documents load from database.",
      );
      if (mounted) {
        setState(() {
          _templateDocuments = [];
        });
      }
      return;
    }
    try {
      _templateDocuments =
          await getService<DatabaseService>().getTemplateDocuments();
    } catch (e) {
      Logger.log('加载模板文档出错: $e');
    }
  }

  /// [setLastVisitedName] / [setLastVisitedType]：与列表刷新同一帧写入，避免异步 [setState] 覆盖「上次访问」高亮。
  /// [clearLastVisited]：进入子文件夹等场景清空标记。
  Future<void> _loadData({
    String? setLastVisitedName,
    ItemType? setLastVisitedType,
    bool clearLastVisited = false,
  }) async {
    if (kIsWeb) {
      Logger.log("Web environment: Skipping data load from database.");
      if (mounted) {
        setState(() {
          _items = [];
          if (clearLastVisited) {
            _lastVisitedItemName = null;
            _lastVisitedItemType = null;
          }
        });
      }
      return;
    }
    try {
      Logger.log('开始加载数据 for folder: $_currentParentFolder');

      // 加载文件夹数据
      List<Map<String, dynamic>> folders = await getService<DatabaseService>()
          .getFolders(parentFolder: _currentParentFolder);
      Logger.log('从数据库加载了 ${folders.length} 个文件夹');

      // 加载文档数据
      List<Map<String, dynamic>> documents = await getService<DatabaseService>()
          .getDocuments(parentFolder: _currentParentFolder);
      Logger.log('从数据库加载了 ${documents.length} 个文档');

      List<DirectoryItem> directoryItems = [];

      // 处理文件夹数据
      for (var folder in folders) {
        if (folder['name'] != null && folder['name'].toString().isNotEmpty) {
          Logger.log('加载文件夹: ${folder['name']}, 顺序: ${folder['order_index']}');
          directoryItems.add(
            DirectoryItem(
              name: folder['name'].toString().trim(),
              type: ItemType.folder,
              order: folder['order_index'] ?? 0,
              isTemplate: false,
              parentFolder: folder['parent_folder'],
            ),
          );
        } else {
          Logger.log('警告：发现无效文件夹数据: $folder');
        }
      }

      // 处理文档数据
      for (var document in documents) {
        // 跳过封面页文档，不在目录页显示
        if (document['name'] == '__CoverPage__') {
          Logger.log('跳过封面页文档，不在目录页显示');
          continue;
        }

        if (document['name'] != null &&
            document['name'].toString().isNotEmpty) {
          Logger.log(
            '加载文档: ${document['name']}, 顺序: ${document['order_index']}',
          );
          directoryItems.add(
            DirectoryItem(
              name: document['name'].toString().trim(),
              type: ItemType.document,
              order: document['order_index'] ?? 0,
              isTemplate: document['is_template'] == 1,
              parentFolder: document['parent_folder'],
            ),
          );
        } else {
          Logger.log('警告：发现无效文档数据: $document');
        }
      }

      // 按order_index排序
      directoryItems.sort((a, b) => a.order.compareTo(b.order));

      if (mounted) {
        setState(() {
          _items = directoryItems;
          if (clearLastVisited) {
            _lastVisitedItemName = null;
            _lastVisitedItemType = null;
          } else if (setLastVisitedName != null &&
              setLastVisitedName.trim().isNotEmpty &&
              setLastVisitedType != null) {
            _lastVisitedItemName = setLastVisitedName.trim();
            _lastVisitedItemType = setLastVisitedType;
          }
        });
      }

      // 在数据加载完成后，重新加载背景设置
      await _loadBackgroundSettings();

      // 加载模板文档
      await _loadTemplateDocuments();

      Logger.log('数据加载完成，共 ${_items.length} 个项目');
    } catch (e) {
      Logger.log('加载数据时出错: $e');
      if (mounted) {
        setState(() {
          _items = [];
        });
      }
    }
  }

  void _openFolder(String folderName) {
    if (mounted) {
      setState(() {
        // 只有当前不是根目录时才入栈
        if (_currentParentFolder != null) {
          _folderStack.add(_currentParentFolder!);
        }
        _currentParentFolder = folderName;
        _isMultiSelectMode = false;
        _selectedItems.clear();
        for (var item in _items) {
          item.isSelected = false;
        }
      });
      // 与列表同一帧清空「上次访问」，避免仅 setState 后异步 load 覆盖高亮状态
      unawaited(_loadData(clearLastVisited: true));
    }
  }

  Future<void> _goBack() async {
    if (_folderStack.isNotEmpty) {
      final String exitedFolder = (_currentParentFolder ?? '').trim();
      setState(() {
        _currentParentFolder = _folderStack.removeLast();
        _isMultiSelectMode = false;
        _selectedItems.clear();
        for (var item in _items) {
          item.isSelected = false;
        }
      });
      await _loadData(
        setLastVisitedName: exitedFolder.isNotEmpty ? exitedFolder : null,
        setLastVisitedType: exitedFolder.isNotEmpty ? ItemType.folder : null,
      );
      return;
    }
    // 栈为空时才回到根目录
    final String exitedToRoot = (_currentParentFolder ?? '').trim();
    setState(() {
      _currentParentFolder = null;
      _folderStack.clear();
      _isMultiSelectMode = false;
      _selectedItems.clear();
      for (var item in _items) {
        item.isSelected = false;
      }
    });
    await _loadData(
      setLastVisitedName: exitedToRoot.isNotEmpty ? exitedToRoot : null,
      setLastVisitedType: exitedToRoot.isNotEmpty ? ItemType.folder : null,
    );
  }

  Future<String?> _getParentFolder(String folderName) async {
    try {
      // getFolderByName returns Map<String, dynamic>? not List<Map<String, dynamic>>
      Map<String, dynamic>? folderData = await getService<DatabaseService>()
          .getFolderByName(folderName);
      if (folderData != null && folderData.containsKey('parentFolder')) {
        return folderData['parentFolder'] as String?;
      }
      return null;
    } catch (e) {
      Logger.log('Error getting parent folder: $e');
      return null;
    }
  }

  void _exportDocument(String documentName) async {
    try {
      String exportPath = await getService<DatabaseService>().exportDocument(
        documentName,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('文档已导出到 $exportPath')));
      }
      await Share.shareXFiles([XFile(exportPath)], text: '文档备份文件');
    } catch (e) {
      Logger.log('Error exporting document: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出文档出错：$e')));
      }
    }
  }

  void _showDocumentExportOptions(String documentName) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('ZIP 原始文档'),
                subtitle: const Text('可在本应用中导入并继续编辑'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _exportDocument(documentName);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('图片（PNG）'),
                subtitle: const Text('按页导出文档内容，可直接查看'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _exportVisualDocument(
                    documentName,
                    DocumentVisualExportFormat.images,
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('PDF 文档'),
                subtitle: const Text('导出为无分页接缝的连续 PDF'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showPdfLayoutSheet(documentName);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPdfLayoutSheet(String documentName) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.fit_screen_outlined),
                title: const Text('铺满 A4 宽度'),
                subtitle: const Text('适合直接阅读，内容按整页宽度打印'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _exportVisualDocument(
                    documentName,
                    DocumentVisualExportFormat.pdf,
                    pdfLayout: DocumentPdfExportLayout.fullWidth,
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.view_column_outlined),
                title: const Text('A4 双栏半宽：左-右顺序'),
                subtitle: const Text('每页先排左栏，再排同一页右栏'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _exportVisualDocument(
                    documentName,
                    DocumentVisualExportFormat.pdf,
                    pdfLayout: DocumentPdfExportLayout.twoColumnLeftRight,
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.vertical_split_outlined),
                title: const Text('A4 双栏半宽：先左后右'),
                subtitle: const Text('先连续铺满各页左栏，再铺满各页右栏'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _exportVisualDocument(
                    documentName,
                    DocumentVisualExportFormat.pdf,
                    pdfLayout: DocumentPdfExportLayout.twoColumnTopBottom,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _exportVisualDocument(
    String documentName,
    DocumentVisualExportFormat format, {
    DocumentPdfExportLayout pdfLayout = DocumentPdfExportLayout.fullWidth,
  }) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          format == DocumentVisualExportFormat.pdf
              ? '正在生成 PDF...'
              : '正在生成文档图片...',
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final exporter = DocumentVisualExportService(
        getService<DatabaseService>(),
      );
      final paths = await exporter.export(
        context,
        documentName,
        format,
        pdfLayout: pdfLayout,
      );
      if (!mounted) return;
      final files = paths.map(XFile.new).toList();
      await Share.shareXFiles(
        files,
        subject: documentName,
        text:
            format == DocumentVisualExportFormat.pdf
                ? '$documentName PDF 文档'
                : '$documentName 文档图片',
      );
    } catch (e) {
      Logger.log('导出可视文档失败: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出文档失败：$e')));
    }
  }

  void _highlightNewItem(String name, ItemType type) {
    if (mounted) {
      setState(() {
        _lastCreatedItemName = name;
        _lastCreatedItemType = type;
        _isHighlightingNewItem = true;
      });

      _highlightTimer?.cancel();

      _highlightTimer = Timer(Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _lastCreatedItemName = null;
            _lastCreatedItemType = null;
            _isHighlightingNewItem = false;
          });
        }
      });
    }
  }

  Future<void> _addFolder() async {
    try {
      String? folderName = '';
      while (true) {
        folderName = await _showFolderNameDialog(
          hintText: "文件夹名称",
          initialValue: folderName,
        );
        if (folderName == null || folderName.isEmpty) return; // 用户取消或未输入
        if (!await getService<DatabaseService>().doesNameExist(folderName)) {
          String? parentFolder = _currentParentFolder;
          if (parentFolder == null || parentFolder.isEmpty) parentFolder = null;
          await getService<DatabaseService>().insertFolder(
            folderName,
            parentFolder: parentFolder,
          );
          if (mounted) {
            await _loadData();
            _highlightNewItem(folderName, ItemType.folder);
          }
          break;
        } else {
          await _showDuplicateNameWarning();
          // 循环继续，保留上次输入
        }
      }
    } catch (e) {
      Logger.log('Error adding folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('添加文件夹出错。请重试。')));
      }
    }
  }

  Future<void> _addDocument() async {
    try {
      String? documentName = '';
      while (true) {
        documentName = await _showFolderNameDialog(
          hintText: "文档名称",
          initialValue: documentName,
        );
        if (documentName == null || documentName.isEmpty) return; // 用户取消或未输入
        if (!await getService<DatabaseService>().doesNameExist(documentName)) {
          String? parentFolder = _currentParentFolder;
          if (parentFolder == null || parentFolder.isEmpty) parentFolder = null;
          await getService<DatabaseService>().insertDocument(
            documentName,
            parentFolder: parentFolder,
          );
          if (mounted) {
            await _loadData();
            _highlightNewItem(documentName, ItemType.document);
          }
          break;
        } else {
          await _showDuplicateNameWarning();
        }
      }
    } catch (e) {
      Logger.log('Error adding document: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('添加文档出错。请重试。')));
      }
    }
  }

  Future<void> _importDocument() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        allowMultiple: true, // 允许多选文件
      );

      if (result != null && result.files.isNotEmpty) {
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
                    Text('正在导入文档...'),
                  ],
                ),
              ),
        );

        List<String> successFiles = [];
        List<String> failedFiles = [];

        for (var file in result.files) {
          final fp = file.path;
          if (fp != null && fp.isNotEmpty) {
            String zipPath = fp;
            String fileName = path.basenameWithoutExtension(zipPath);

            // 自动去掉时间戳，保持原名
            // 匹配格式：文档名-YYYYMMDD-HHMM
            String originalName = fileName;
            RegExp timeStampPattern = RegExp(r'-\d{8}-\d{4}$');
            if (timeStampPattern.hasMatch(fileName)) {
              originalName = fileName.replaceAll(timeStampPattern, '');
            }

            try {
              // importDocument expects named parameters targetDocumentName and targetParentFolder
              await getService<DatabaseService>().importDocument(
                zipPath,
                targetDocumentName: originalName,
                targetParentFolder: _currentParentFolder,
              );
              successFiles.add(originalName);
            } catch (e) {
              Logger.log('导入文档 $originalName 时出错: $e');
              failedFiles.add(originalName);
            }
          }
        }

        // 关闭进度对话框
        if (mounted) {
          Navigator.pop(context);
        }

        // 刷新数据
        if (mounted) {
          await _loadData();

          // 高亮显示最后一个成功导入的文档
          if (successFiles.isNotEmpty) {
            _highlightNewItem(successFiles.last, ItemType.document);
          }

          // 显示导入结果
          String message = '';
          if (successFiles.isNotEmpty) {
            message += '成功导入 ${successFiles.length} 个文档\n';
          }
          if (failedFiles.isNotEmpty) {
            message +=
                '导入失败 ${failedFiles.length} 个文档：${failedFiles.join(", ")}';
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message), duration: Duration(seconds: 3)),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未选择备份文件')));
        }
      }
    } catch (e) {
      Logger.log('批量导入文档时出错: $e');
      if (mounted) {
        Navigator.of(context).pop(); // 确保关闭进度对话框
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入文档时出错：$e')));
      }
    }
  }

  void _deleteDocument(String documentName) async {
    bool confirmDelete = await _showDeleteConfirmationDialog(
      "文档",
      documentName,
    );
    if (confirmDelete) {
      try {
        String? parentFolder = _currentParentFolder;

        // 使用文件清理服务彻底删除文档文件
        try {
          final fileCleanupService = getService<FileCleanupService>();
          if (fileCleanupService.isInitialized) {
            await fileCleanupService.deleteDocumentCompletely(documentName);
          }
        } catch (e) {
          Logger.log('文件清理服务删除文档失败: $e');
        }

        // 从数据库中删除
        await getService<DatabaseService>().deleteDocument(
          documentName,
          parentFolder: parentFolder,
        );

        if (mounted) {
          setState(() {
            _items.removeWhere(
              (item) =>
                  item.type == ItemType.document && item.name == documentName,
            );
          });
        }
      } catch (e) {
        Logger.log('Error deleting document: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('删除文档出错。请重试。')));
        }
      }
    }
  }

  void _deleteFolder(String folderName) async {
    bool confirmDelete = await _showDeleteConfirmationDialog("文件夹", folderName);
    if (confirmDelete) {
      try {
        String? parentFolder = _currentParentFolder;

        // 使用文件清理服务彻底删除文件夹
        try {
          final fileCleanupService = getService<FileCleanupService>();
          if (fileCleanupService.isInitialized) {
            await fileCleanupService.deleteFolderCompletely(folderName);
          }
        } catch (e) {
          Logger.log('文件清理服务删除文件夹失败: $e');
        }

        // 从数据库中删除
        await getService<DatabaseService>().deleteFolder(
          folderName,
          parentFolder: parentFolder,
        );

        if (mounted) {
          await _loadData();
        }
      } catch (e) {
        Logger.log('Error deleting folder: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('删除文件夹出错。请重试。')));
        }
      }
    }
  }

  Future<bool> _showDeleteConfirmationDialog(String type, String name) async {
    return await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text('确认删除'),
              content: Text('您确定要删除$type "$name" 吗？这将删除其所有内容。'),
              actions: [
                TextButton(
                  child: Text('取消'),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                TextButton(
                  child: Text('删除', style: TextStyle(color: Colors.red)),
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  void _renameDocument(String oldName) async {
    String? newName = await _showFolderNameDialog(
      hintText: "新文档名称",
      initialValue: oldName,
    );
    if (newName != null && newName.isNotEmpty) {
      final now = DateTime.now();
      final dateStr =
          "${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}";
      newName = "$newName-$dateStr";

      if (!await getService<DatabaseService>().doesNameExist(newName)) {
        try {
          await getService<DatabaseService>().renameDocument(oldName, newName);
          if (mounted) {
            await _loadData();
          }
        } catch (e) {
          Logger.log('Error renaming document: $e');
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('重命名文档出错。请重试。')));
          }
        }
      } else {
        _showDuplicateNameWarning();
      }
    }
  }

  void _renameFolder(String oldName) async {
    String? newName = await _showFolderNameDialog(
      hintText: "新文件夹名称",
      initialValue: oldName,
    );
    if (newName != null && newName.isNotEmpty) {
      final now = DateTime.now();
      final dateStr =
          "${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}";
      newName = "$newName-$dateStr";

      if (!await getService<DatabaseService>().doesNameExist(newName)) {
        try {
          await getService<DatabaseService>().renameFolder(oldName, newName);
          if (mounted) {
            await _loadData();
          }
        } catch (e) {
          Logger.log('Error renaming folder: $e');
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('重命名文件夹出错。请重试。')));
          }
        }
      } else {
        _showDuplicateNameWarning();
      }
    }
  }

  void _moveDocumentToDirectory(String documentName) async {
    try {
      await getService<DatabaseService>().updateDocumentParentFolder(
        documentName,
        null,
      );
      if (mounted) {
        await _loadData();
      }
    } catch (e) {
      Logger.log('Error moving document to directory: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移动文档到目录出错。请重试。')));
      }
    }
  }

  void _moveFolderToDirectory(String folderName) async {
    try {
      await getService<DatabaseService>().updateFolderParentFolder(
        folderName,
        null,
      );
      if (mounted) {
        await _loadData();
      }
    } catch (e) {
      Logger.log('Error moving folder to directory: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移动文件夹到目录出错。请重试。')));
      }
    }
  }

  void _moveDocumentToDirectoryOption(String documentName) async {
    bool confirmMove = await _showMoveConfirmationDialog(
      "文档",
      documentName,
      "目录",
    );
    if (confirmMove) {
      _moveDocumentToDirectory(documentName);
    }
  }

  void _moveFolderToDirectoryOption(String folderName) async {
    bool confirmMove = await _showMoveConfirmationDialog(
      "文件夹",
      folderName,
      "目录",
    );
    if (confirmMove) {
      _moveFolderToDirectory(folderName);
    }
  }

  /// 获取文件夹完整路径
  String _getFolderFullPath(
    Map<String, dynamic> folder,
    List<Map<String, dynamic>> allFolders,
  ) {
    if (folder['parent_folder'] == null) return folder['name'] as String;
    final parent = allFolders.firstWhere(
      (f) => f['id'] == folder['parent_folder'],
      orElse:
          () => <String, dynamic>{'name': '', 'parent_folder': null, 'id': ''},
    );
    if (parent['name'] == '') return folder['name'] as String;
    return _getFolderFullPath(parent, allFolders) +
        '/' +
        (folder['name'] as String);
  }

  /// 递归获取所有子文件夹id
  List<String> _getAllSubFolderIds(
    String folderId,
    List<Map<String, dynamic>> allFolders,
  ) {
    List<String> result = [];
    void collect(String id) {
      for (var f in allFolders) {
        if (f['parent_folder'] == id) {
          result.add(f['id'] as String);
          collect(f['id'] as String);
        }
      }
    }

    collect(folderId);
    return result;
  }

  /// 选择目标文件夹，excludeFolderIds为需要排除的文件夹id列表，showRoot控制是否显示根目录
  Future<String?> _selectFolder({
    List<String>? excludeFolderIds,
    bool showRoot = true,
  }) async {
    try {
      final folders =
          await getService<DatabaseService>().getAllDirectoryFolders();
      // 排除指定id的文件夹
      final availableFolders =
          folders
              .where(
                (folder) =>
                    excludeFolderIds == null ||
                    !excludeFolderIds.contains(folder['id']),
              )
              .toList();
      if (availableFolders.isEmpty && !showRoot) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('没有可用的目标文件夹')));
        }
        return null;
      }
      // 生成路径映射
      final folderPaths =
          availableFolders
              .map((folder) => _getFolderFullPath(folder, folders))
              .toList();
      if (!mounted) return null;
      final choices = <MoveSheetChoice>[
        if (showRoot)
          const MoveSheetChoice(value: '', label: '根目录', isRoot: true),
        ...List.generate(
          availableFolders.length,
          (i) => MoveSheetChoice(
            value: availableFolders[i]['name'] as String,
            label: folderPaths[i],
          ),
        ),
      ];
      // 与媒体库「移动到」同风格：半透明底部面板；目录页保持单列，透明度 20%。
      return showMoveTargetSheet(
        context: context,
        choices: choices,
        crossAxisCount: 1,
        panelOpacity: 0.8,
      );
    } catch (e) {
      Logger.log('Error selecting folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择文件夹时出错')));
      }
      return null;
    }
  }

  void _moveFolderToFolder(String folderName) async {
    try {
      final dbService = getService<DatabaseService>();
      final folders = await dbService.getAllDirectoryFolders();
      final currentFolder = folders.firstWhere(
        (f) => f['name'] == folderName,
        orElse:
            () => <String, dynamic>{
              'id': '',
              'parent_folder': null,
              'name': '',
            },
      );
      if (currentFolder['id'] == '') return;
      // 递归排除自身和所有子文件夹
      final excludeIds = <String>[currentFolder['id'] as String];
      excludeIds.addAll(
        _getAllSubFolderIds(currentFolder['id'] as String, folders),
      );
      // 排除当前父文件夹
      if (currentFolder['parent_folder'] != null) {
        excludeIds.add(currentFolder['parent_folder'] as String);
      }
      // 根目录选项仅在当前文件夹不在根目录时显示
      final showRoot = currentFolder['parent_folder'] != null;
      final targetFolderName = await _selectFolder(
        excludeFolderIds: excludeIds,
        showRoot: showRoot,
      );
      if (targetFolderName == null) return; // 取消时不做任何操作
      if (targetFolderName.isEmpty) {
        await dbService.updateFolderParentFolder(folderName, null);
      } else {
        await dbService.updateFolderParentFolder(folderName, targetFolderName);
      }
      if (mounted) {
        await _loadData();
      }
    } catch (e) {
      Logger.log('Error moving folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  void _moveDocumentToFolder(String documentName) async {
    try {
      // 获取当前文档信息
      final dbService = getService<DatabaseService>();
      final doc = await dbService.getDocumentByName(documentName);
      String? currentFolderId;
      bool showRoot = true;
      if (doc != null && doc['parent_folder'] != null) {
        currentFolderId = doc['parent_folder'] as String;
      } else {
        // 文档在根目录，不显示根目录选项
        showRoot = false;
      }
      final targetFolderName = await _selectFolder(
        excludeFolderIds: currentFolderId != null ? [currentFolderId] : null,
        showRoot: showRoot,
      );
      if (targetFolderName == null) return; // 取消时不做任何操作
      if (targetFolderName.isEmpty) {
        // 移动到根目录
        await dbService.updateDocumentParentFolder(documentName, null);
      } else {
        await dbService.updateDocumentParentFolder(
          documentName,
          targetFolderName,
        );
      }
      if (mounted) {
        await _loadData();
      }
    } catch (e) {
      Logger.log('Error moving document: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<bool> _showMoveConfirmationDialog(
    String type,
    String name,
    String target,
  ) async {
    return await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text('确认移动'),
              content: Text('您确定要将$type "$name" 移动到$target 吗？'),
              actions: [
                TextButton(
                  child: Text('取消'),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                TextButton(
                  child: Text('移动', style: TextStyle(color: Colors.blue)),
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Future<String> _getDirectoryFolderPath(String folderName) async {
    final dbService = getService<DatabaseService>();
    String currentPath = folderName;

    try {
      // getFolderByName returns Map<String, dynamic>? not List<Map<String, dynamic>>
      Map<String, dynamic>? currentFolderData = await dbService.getFolderByName(
        folderName,
      );
      String? parentFolderName =
          (currentFolderData != null &&
                  currentFolderData.containsKey('parent_folder'))
              ? currentFolderData['parent_folder'] as String?
              : null;

      while (parentFolderName != null) {
        currentPath = '$parentFolderName/$currentPath';
        currentFolderData = await dbService.getFolderByName(parentFolderName);
        parentFolderName =
            (currentFolderData != null &&
                    currentFolderData.containsKey('parent_folder'))
                ? currentFolderData['parent_folder'] as String?
                : null;
      }

      return currentPath;
    } catch (e) {
      Logger.log('获取文件夹路径出错: $e');
      return folderName; // 出错时至少返回文件夹名称
    }
  }

  Future<String?> _showFolderNameDialog({
    String? hintText,
    String? initialValue,
  }) async {
    TextEditingController controller = TextEditingController();
    if (initialValue != null) {
      controller.text = initialValue;
    }
    String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('输入名称'),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(hintText: hintText ?? "名称"),
            autofocus: true,
            onSubmitted: (_) {
              Navigator.of(context).pop(controller.text.trim());
            },
          ),
          actions: <Widget>[
            TextButton(
              child: Text('取消'),
              onPressed: () {
                Navigator.of(context).pop(null);
              },
            ),
            TextButton(
              child: Text('确定'),
              onPressed: () {
                Navigator.of(context).pop(controller.text.trim());
              },
            ),
          ],
        );
      },
    );
    return result;
  }

  Future<void> _showDuplicateNameWarning() async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('名称重复'),
          content: Text('名称已存在。请使用其他名称。'),
          actions: <Widget>[
            TextButton(
              child: Text('确定'),
              onPressed: () {
                Navigator.pop(context);
              },
            ),
          ],
        );
      },
    );
  }

  void _onReorder(int oldIndex, int newIndex) {
    HapticFeedback.mediumImpact();

    if (!mounted) return;

    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }

      final DirectoryItem item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });

    _updateOrderInDatabase();
  }

  Future<void> _updateOrderInDatabase() async {
    try {
      for (int i = 0; i < _items.length; i++) {
        final DirectoryItem item = _items[i];
        if (item.type == ItemType.folder) {
          await getService<DatabaseService>().updateFolderOrder(item.name, i);
        } else if (item.type == ItemType.document) {
          await getService<DatabaseService>().updateDocumentOrder(item.name, i);
        }
      }
    } catch (e) {
      Logger.log('Error updating order: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新顺序出错。请重试。')));
      }
    }
  }

  void _openDocument(String documentName) {
    final trimmed = documentName.trim();
    if (mounted) {
      setState(() {
        _lastVisitedItemName = null;
        _lastVisitedItemType = null;
      });
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => DocumentEditorPage(
              documentName: documentName,
              onSave: (updatedTextBoxes) {},
            ),
      ),
    ).then((_) async {
      Logger.log('从文档编辑页面返回');
      if (!mounted) return;
      await _loadBackgroundSettings();
      await _loadData(
        setLastVisitedName: trimmed.isNotEmpty ? trimmed : null,
        setLastVisitedType: ItemType.document,
      );
    });
  }

  Future<bool> _isDocumentTemplate(String documentName) async {
    final db = await getService<DatabaseService>().database;
    List<Map<String, dynamic>> result = await db.query(
      'documents',
      columns: ['is_template'],
      where: 'name = ?',
      whereArgs: [documentName],
    );

    if (result.isNotEmpty) {
      return result.first['is_template'] == 1;
    }
    return false;
  }

  void _copyDocument(String documentName) async {
    try {
      // copyDocument expects sourceDocumentName as positional and parentFolder as named
      // and returns Future<String>
      String newDocName = await getService<DatabaseService>().copyDocument(
        documentName,
        parentFolder: _currentParentFolder,
      );
      if (mounted) {
        await _loadData();
        _highlightNewItem(newDocName, ItemType.document);
      }
    } catch (e) {
      Logger.log('复制文档出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('复制文档出错，请重试。')));
      }
    }
  }

  void _showDocumentOptions(String documentName) async {
    bool isTemplate = await _isDocumentTemplate(documentName);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeModalSheetScrollable(
          children: [
            ListTile(
              leading: Icon(Icons.delete),
              title: Text('删除'),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 2.0,
              ),
              dense: true,
              onTap: () {
                Navigator.pop(context);
                _deleteDocument(documentName);
              },
            ),
            Divider(height: 1.0, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.copy),
              title: Text('复制'),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 2.0,
              ),
              dense: true,
              onTap: () {
                Navigator.pop(context);
                _copyDocument(documentName);
              },
            ),
            Divider(height: 1.0, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.drive_file_rename_outline),
              title: Text('重命名'),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 2.0,
              ),
              dense: true,
              onTap: () {
                Navigator.pop(context);
                _renameDocument(documentName);
              },
            ),
            Divider(height: 1.0, thickness: 0.5),
            ListTile(
              leading: Icon(isTemplate ? Icons.star : Icons.star_border),
              title: Text(isTemplate ? '取消设为模板' : '设为模板'),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 2.0,
              ),
              dense: true,
              onTap: () async {
                Navigator.pop(context);
                await getService<DatabaseService>().setDocumentAsTemplate(
                  documentName,
                  !isTemplate,
                );
                if (mounted) {
                  _loadData();
                }
              },
            ),
            Divider(height: 1.0, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.folder),
              title: Text('移动到文件夹'),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 2.0,
              ),
              dense: true,
              onTap: () {
                Navigator.pop(context);
                _moveDocumentToFolder(documentName);
              },
            ),
            Divider(height: 1.0, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.drive_file_move),
              title: Text('移动到目录'),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 2.0,
              ),
              dense: true,
              onTap: () {
                Navigator.pop(context);
                _moveDocumentToDirectoryOption(documentName);
              },
            ),
            Divider(height: 1.0, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.share),
              title: Text('分享'),
              subtitle: Text('导出文档并分享'),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 2.0,
              ),
              dense: true,
              onTap: () {
                Navigator.pop(context);
                _showDocumentExportOptions(documentName);
              },
            ),
          ],
        );
      },
    );
  }

  void _showFolderOptions(String folderName) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeModalSheetScrollable(
          children: [
            ListTile(
              leading: Icon(Icons.edit),
              title: Text('重命名'),
              onTap: () {
                Navigator.pop(context);
                _renameFolder(folderName);
              },
            ),
            Divider(height: 1, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.folder_open),
              title: Text('移动到文件夹'),
              onTap: () {
                Navigator.pop(context);
                _moveFolderToFolder(folderName);
              },
            ),
            Divider(height: 1, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.drive_file_move),
              title: Text('移动到目录'),
              onTap: () {
                Navigator.pop(context);
                _moveFolderToDirectoryOption(folderName);
              },
            ),
            Divider(height: 1, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.copy),
              title: Text('复制'),
              onTap: () {
                Navigator.pop(context);
                _copyFolder(folderName);
              },
            ),
            Divider(height: 1, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.delete, color: Colors.red),
              title: Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _deleteFolder(folderName);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _clearDirectoryBackgroundToBlank() async {
    if (kIsWeb) {
      _showWebUnsupportedDialog();
      return;
    }
    try {
      await getService<DatabaseService>().clearDirectoryBackgroundToBlank(
        _currentParentFolder,
      );
      if (mounted) {
        final settings = await getService<DatabaseService>()
            .getDirectorySettings(_currentParentFolder);
        final int? cv = settings?['background_color'] as int?;
        setState(() {
          _backgroundImage = null;
          _backgroundVideo = null;
          _backgroundImageOrigin = null;
          _backgroundVideoOrigin = null;
          _backgroundColor = cv != null ? Color(cv) : null;
        });
      }
    } catch (e) {
      Logger.log('清空目录背景出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清空背景失败，请重试。')));
      }
    }
  }

  void _showDirectorySettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 8),
              child: SingleChildScrollView(
                controller: scrollController,
                child: Wrap(
                  children: [
                    ListTile(
                      leading: Icon(Icons.image),
                      title: Text('设置背景图片'),
                      onTap: () {
                        Navigator.pop(context);
                        _pickBackgroundImage();
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.videocam),
                      title: Text('设置背景视频'),
                      onTap: () {
                        Navigator.pop(context);
                        _pickBackgroundVideo();
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.color_lens),
                      title: Text('设置背景颜色'),
                      onTap: () {
                        Navigator.pop(context);
                        _pickBackgroundColor();
                      },
                    ),
                    if (_backgroundImage != null)
                      ListTile(
                        leading: Icon(Icons.tune),
                        title: Text('调整背景图片'),
                        onTap: () {
                          Navigator.pop(context);
                          _openBackgroundImagePreviewEditor();
                        },
                      ),
                    if (_backgroundVideo != null)
                      ListTile(
                        leading: Icon(Icons.tune),
                        title: Text('调整背景视频'),
                        onTap: () {
                          Navigator.pop(context);
                          _openBackgroundVideoPreviewEditor();
                        },
                      ),
                    if (_backgroundImage != null)
                      ListTile(
                        leading: Icon(Icons.delete),
                        title: Text('删除背景图片'),
                        onTap: () {
                          Navigator.pop(context);
                          _removeBackgroundImage();
                        },
                      ),
                    if (_backgroundVideo != null)
                      ListTile(
                        leading: Icon(Icons.delete),
                        title: Text('删除背景视频'),
                        onTap: () {
                          Navigator.pop(context);
                          _removeBackgroundVideo();
                        },
                      ),
                    if (_backgroundImage != null || _backgroundVideo != null)
                      ListTile(
                        leading: Icon(Icons.layers_clear),
                        title: Text('清空背景图/视频'),
                        onTap: () async {
                          Navigator.pop(context);
                          await _clearDirectoryBackgroundToBlank();
                        },
                      ),
                    Divider(),
                    ListTile(
                      leading: Icon(Icons.backup),
                      title: Text('导出目录数据'),
                      onTap: () {
                        Navigator.pop(context);
                        _exportDirectoryData();
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.restore),
                      title: Text('导入目录数据'),
                      onTap: () {
                        Navigator.pop(context);
                        _importDirectoryData();
                      },
                    ),
                    Divider(),
                    ListTile(
                      leading: Icon(Icons.health_and_safety),
                      title: Text('检查数据完整性'),
                      onTap: () {
                        Navigator.pop(context);
                        _checkDataIntegrity();
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.build),
                      title: Text('修复数据问题'),
                      onTap: () {
                        Navigator.pop(context);
                        _repairDataIntegrity();
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.science, color: Colors.orange),
                      title: Text('生成测试数据'),
                      subtitle: Text('用于验证导出/导入性能'),
                      onTap: () {
                        Navigator.pop(context);
                        _showGenerateTestDataDialog();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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
                  TestDataScale.directoryScales.map((s) {
                    final suffix =
                        s.formulaDir.substring(s.label.length) +
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
              content: Text('将生成约 10GB 测试数据，预计耗时数分钟。\n请确保设备有足够存储空间。\n\n继续？'),
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
      final result = await TestDataGeneratorService().generateDirectoryTestData(
        scale,
        progress: progress,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '测试数据已生成：${result['folders']} 文件夹、${result['documents']} 文档、'
            '${result['textBoxes']} 文本框、${result['imageBoxes']} 图片框、${result['audioBoxes']} 音频框，'
            '已生成约 ${result['actualSizeMB']} MB',
          ),
          duration: Duration(seconds: 5),
        ),
      );
      _loadData();
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('生成失败: $e')));
      }
    }
  }

  Future<void> _showTemplateSelectionDialog() async {
    if (_templateDocuments.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('没有可用的模板文档。请先将文档设置为模板。')));
      }
      return;
    }

    if (_templateDocuments.length == 1) {
      await _createDocumentFromTemplate(_templateDocuments[0]['name']);
      return;
    }

    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('选择模板'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _templateDocuments.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    title: Text(_templateDocuments[index]['name']),
                    leading: Icon(Icons.star, color: Colors.amber),
                    onTap: () {
                      Navigator.pop(context, _templateDocuments[index]['name']);
                    },
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('取消'),
              ),
            ],
          ),
    ).then((templateName) async {
      if (templateName != null && mounted) {
        await _createDocumentFromTemplate(templateName);
      }
    });
  }

  Future<void> _createDocumentFromTemplate(String templateName) async {
    try {
      // 生成一个更简洁的新文档名称，使用"模板名称-副本"的格式
      String newName = '$templateName-副本';
      // Ensure the generated name is unique if necessary, or let the service handle it if it's designed to.
      // For now, we assume the service might further refine the name if there's a conflict.

      // createDocumentFromTemplate now returns Future<String> and expects parentFolder as a named argument.
      String newDocName = await getService<DatabaseService>()
          .createDocumentFromTemplate(
            templateName,
            newName,
            parentFolder: _currentParentFolder,
          );

      if (mounted) {
        await _loadData();
        _highlightNewItem(newDocName, ItemType.document);
      }
    } catch (e) {
      Logger.log('从模板创建文档时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('创建文档时出错，请重试。')));
      }
    }
  }

  void _showAddOptions() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeModalSheetScrollable(
          children: [
            ListTile(
              leading: Icon(Icons.create_new_folder, color: Colors.amber),
              title: Text('新建文件夹'),
              onTap: () {
                Navigator.pop(context);
                _addFolder();
              },
            ),
            Divider(height: 1, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.note_add, color: Colors.blue),
              title: Text('新建文档'),
              onTap: () {
                Navigator.pop(context);
                _addDocument();
              },
            ),
            Divider(height: 1, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.file_upload),
              title: Text('导入文档'),
              onTap: () {
                Navigator.pop(context);
                _importDocument();
              },
            ),
            Divider(height: 1, thickness: 0.5),
            ListTile(
              leading: Icon(Icons.star, color: Colors.amber),
              title: Text('使用模板创建'),
              onTap: () {
                Navigator.pop(context);
                _showTemplateSelectionDialog();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveCurrentBackgroundState() async {
    if (kIsWeb) {
      Logger.log("Web environment: Skipping save current background state.");
      return;
    }
    try {
      await getService<DatabaseService>().insertOrUpdateDirectorySettings(
        folderName: _currentParentFolder,
        imagePath: _backgroundImage?.path,
        videoPath: _backgroundVideo?.path,
        colorValue: _backgroundColor?.value,
        commitBackgroundPaths: true,
        backgroundImageOrigin: _backgroundImageOrigin,
        backgroundVideoOrigin: _backgroundVideoOrigin,
      );
      if (_backgroundImage != null) {
        Logger.log('保存当前背景图片: ${_backgroundImage!.path}');
      }
      if (_backgroundVideo != null) {
        Logger.log('保存当前背景视频: ${_backgroundVideo!.path}');
      }
      if (_backgroundColor != null) {
        Logger.log('保存当前背景颜色: ${_backgroundColor!.value}');
      }
    } catch (e) {
      Logger.log('保存当前背景状态时出错: $e');
    }
  }

  Future<void> _checkAndRestoreBackgroundMedia() async {
    if (kIsWeb) {
      Logger.log(
        "Web environment: Skipping background media check/restore from database.",
      );
      return;
    }
    try {
      Map<String, dynamic>? settings = await getService<DatabaseService>()
          .getDirectorySettings(_currentParentFolder);
      if (settings == null) return;

      final String? videoPath = settings['background_video_path'] as String?;
      if (videoPath != null && videoPath.isNotEmpty) {
        final vf = File(videoPath);
        if (await vf.exists() && mounted) {
          setState(() {
            _backgroundVideo = vf;
            _backgroundImage = null;
            Logger.log('恢复背景视频: $videoPath');
          });
          return;
        }
      }

      final String? imagePath = settings['background_image_path'] as String?;
      if (imagePath != null && imagePath.isNotEmpty) {
        final imageFile = File(imagePath);
        if (await imageFile.exists() && mounted) {
          setState(() {
            _backgroundImage = imageFile;
            _backgroundVideo = null;
            Logger.log('恢复背景图片: $imagePath');
          });
        }
      }
    } catch (e) {
      Logger.log('恢复背景媒体时出错: $e');
    }
  }

  void forceRefresh() {
    if (mounted) {
      Logger.log('强制刷新页面状态');
      _loadBackgroundSettings();
      _loadData(); // 重新加载目录数据
      setState(() {});
    }
  }

  void _exportSelectedItems() async {
    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先选择要导出的项目')));
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
      // 1. 收集所有选中文档的导出路径
      List<String> exportPaths = [];
      for (var item in _selectedItems) {
        if (item.type == ItemType.document) {
          try {
            String exportPath = await getService<DatabaseService>()
                .exportDocument(item.name);
            if (await File(exportPath).exists()) {
              exportPaths.add(exportPath);
            }
          } catch (e) {
            Logger.log('导出文档 ${item.name} 时出错: $e');
          }
        }
      }
      // 2. 打包为ZIP
      if (exportPaths.isEmpty) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('没有找到可导出的文件')));
        }
        return;
      }
      final tempDir = await getTemporaryDirectory();
      final zipPath =
          '${tempDir.path}/exported_docs_${DateTime.now().millisecondsSinceEpoch}.zip';
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      for (final path in exportPaths) {
        encoder.addFile(File(path));
      }
      encoder.close();
      if (mounted) {
        Navigator.pop(context);
      }
      await Share.shareXFiles([XFile(zipPath)], subject: '批量导出文档');
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出文件时出错: $e')));
      }
    }
  }

  void _exportDirectoryData() async {
    try {
      // 使用默认位置（Downloads/外部存储），便于一键分享
      // 创建进度通知器
      final ValueNotifier<String> progressNotifier = ValueNotifier<String>(
        '准备导出...',
      );

      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => AlertDialog(
              content: ValueListenableBuilder<String>(
                valueListenable: progressNotifier,
                builder: (context, progress, child) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 20),
                      Text(
                        progress,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  );
                },
              ),
            ),
      );

      // 导出到默认目录（Downloads/外部存储），不写入 backups
      String zipPath = await getService<DatabaseService>().exportDirectoryData(
        progressNotifier: progressNotifier,
        outputDirectory: null,
      );

      // 关闭进度对话框
      if (mounted) {
        Navigator.pop(context);
      }

      // 小文件：仅原生分享；大文件(>500MB)：跳过分享，弹窗提供「直达」等（share_plus 大文件会 ANR）
      if (mounted) {
        final zipFile = File(zipPath);
        final size = await zipFile.exists() ? await zipFile.length() : 0;
        if (size <= kShareSizeLimitBytes) {
          try {
            await Share.shareXFiles([XFile(zipPath)], subject: '目录数据备份');
          } catch (_) {}
          // 小文件：分享后即完成，不再弹第二个界面
        } else {
          showExportResultDialog(
            context,
            zipPath,
            size,
            shareText: '目录数据备份',
            showShareButton: false,
            showSaveToFolderButton: true,
          );
        }
      }
    } catch (e, stack) {
      debugPrint('导出目录数据时出错: $e\n$stack');
      if (mounted) {
        Navigator.pop(context);
        final userMsg = formatExportImportError(e, '导出失败');
        showExportImportErrorDialog(context, '目录数据导出失败', userMsg);
      }
    }
  }

  void _importDirectoryData() async {
    try {
      // 显示警告对话框
      bool? confirm = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text('警告'),
              content: Text('导入新目录数据将会清空当前所有数据，确定要继续吗？'),
              actions: [
                TextButton(
                  child: Text('取消'),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                TextButton(
                  child: Text('确定'),
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
      );

      if (confirm != true) return;

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      final zipPath = result?.files.single.path;
      if (result != null && zipPath != null && zipPath.isNotEmpty) {
        // 创建进度通知器
        final ValueNotifier<String> progressNotifier = ValueNotifier<String>(
          '准备导入...',
        );

        // 显示进度对话框
        showDialog(
          context: context,
          barrierDismissible: false,
          builder:
              (context) => AlertDialog(
                content: ValueListenableBuilder<String>(
                  valueListenable: progressNotifier,
                  builder: (context, progress, child) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 20),
                        Text(
                          progress,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    );
                  },
                ),
              ),
        );

        await getService<DatabaseService>().importDirectoryData(
          zipPath,
          progressNotifier: progressNotifier,
        );

        // 关闭进度对话框
        if (mounted) {
          Navigator.pop(context);
        }

        // 刷新数据
        if (mounted) {
          await _loadData();
          await _loadBackgroundSettings();
          forceRefresh(); // 强制刷新页面，确保背景图片立即生效
        }
      }
    } catch (e, stack) {
      debugPrint('导入目录数据时出错: $e\n$stack');
      if (mounted) {
        Navigator.pop(context);
        final userMsg = formatExportImportError(e, '导入失败');
        showExportImportErrorDialog(context, '目录数据导入失败', userMsg);
      }
    }
  }

  /// 手动检查数据完整性
  Future<void> _checkDataIntegrity() async {
    try {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('正在检查数据完整性...')));
      }

      final report = await getService<DatabaseService>().checkDataIntegrity();

      if (!mounted) return;
      if (report['isValid']) {
        final folderCount = report['folderCount'] as int? ?? 0;
        final documentCount = report['documentCount'] as int? ?? 0;
        final mediaItemCount = report['mediaItemCount'] as int? ?? 0;
        final diaryEntryCount = report['diaryEntryCount'] as int? ?? 0;
        showDialog(
          context: context,
          builder:
              (ctx) => AlertDialog(
                title: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 28),
                    SizedBox(width: 8),
                    Text('检查完成'),
                  ],
                ),
                content: Text(
                  '数据完整性检查通过，未发现问题。\n\n'
                  '目录：$folderCount 个文件夹，$documentCount 个文档\n'
                  '媒体：$mediaItemCount 项\n'
                  '日记：$diaryEntryCount 条',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('确定'),
                  ),
                ],
              ),
        );
      } else {
        showDialog(
          context: context,
          builder:
              (ctx) => AlertDialog(
                title: const Text('发现数据完整性问题'),
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('发现 ${report['issues'].length} 个问题:'),
                      const SizedBox(height: 8),
                      ...(report['issues'] as List)
                          .map(
                            (issue) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '• $issue',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _repairDataIntegrity();
                    },
                    child: const Text('修复问题'),
                  ),
                ],
              ),
        );
      }
    } catch (e) {
      Logger.log('检查数据完整性时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('检查数据完整性时出错: $e')));
      }
    }
  }

  /// 手动修复数据完整性问题
  Future<void> _repairDataIntegrity() async {
    try {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('正在修复数据问题...')));
      }

      await getService<DatabaseService>().repairDataIntegrity();

      if (mounted) {
        await _loadData();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('修复完成，数据已更新'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      Logger.log('修复数据完整性问题时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('修复数据问题时出错: $e')));
      }
    }
  }

  /// 无边透明顶栏：目录各层统一白字+阴影，与背景图/浅色底都协调。
  Widget _buildDirectoryFloatingTopBar() {
    const lightFg = true;
    final pad = MediaQuery.paddingOf(context);
    final ic = FloatingUiBarStyle.iconColor(lightFg);
    final sh = FloatingUiBarStyle.iconShadow(lightFg);
    final ts = FloatingUiBarStyle.titleStyle(lightFg, fontSize: 18);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          color: Colors.transparent,
          child: Row(
            children: [
              if (_currentParentFolder != null)
                IconButton(
                  icon: Icon(Icons.arrow_back, color: ic, shadows: sh),
                  onPressed: () {
                    unawaited(_goBack());
                  },
                  tooltip: '返回上级',
                )
              else if (widget.showRouteBackButton)
                IconButton(
                  icon: Icon(Icons.arrow_back, color: ic, shadows: sh),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '返回浏览器',
                )
              else
                const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _currentParentFolder ?? '目录',
                  style: ts,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_isMultiSelectMode) ...[
                IconButton(
                  icon: Icon(
                    _items.every((item) => item.isSelected)
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    color: ic,
                    shadows: sh,
                  ),
                  onPressed: _selectAllItems,
                  tooltip: '全选/取消全选',
                ),
                IconButton(
                  icon: Icon(Icons.cancel, color: ic, shadows: sh),
                  onPressed: _toggleMultiSelectMode,
                  tooltip: '取消多选',
                ),
              ] else ...[
                IconButton(
                  icon: Icon(Icons.select_all, color: ic, shadows: sh),
                  onPressed: _toggleMultiSelectMode,
                  tooltip: '多选',
                ),
                IconButton(
                  icon: Icon(Icons.settings, color: ic, shadows: sh),
                  onPressed: _showDirectorySettings,
                  tooltip: '设置',
                ),
                GestureDetector(
                  onTap: () => _showAddOptions(),
                  onDoubleTap: () => _showTemplateSelectionDialog(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: Icon(Icons.add_circle, color: ic, shadows: sh),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(Duration.zero, () {
        if (_backgroundImage == null && _backgroundVideo == null && mounted) {
          _checkAndRestoreBackgroundMedia();
        }
      });
    });

    // 状态栏/系统 UI：仍按实际背景亮度切换；顶栏统一白字+阴影（见 _buildDirectoryFloatingTopBar）。
    final lightFgForSystemUi = FloatingUiBarStyle.preferLightForeground(
      hasBackgroundImage: _backgroundImage != null || _backgroundVideo != null,
      backgroundSolidColor: _backgroundColor,
    );
    final mq = MediaQuery.of(context);
    final contentTop = mq.padding.top + kToolbarHeight;
    final navBottom = mq.padding.bottom;
    const gapBelowLastRow = 28.0;
    final multiSelectBarExtra =
        (_isMultiSelectMode && _selectedItems.isNotEmpty) ? 56.0 : 0.0;
    final listBottomPadding = navBottom + gapBelowLastRow + multiSelectBarExtra;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          lightFgForSystemUi
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // 第一层：背景图/视频（最底层），复用媒体页视窗参数
            if (_backgroundVideo != null)
              Positioned.fill(
                child: StoredViewVideoBackgroundLayer(
                  key: ValueKey(
                    'dir_bgv_${_backgroundVideo!.path}_$_backgroundViewRefreshTick',
                  ),
                  file: _backgroundVideo!,
                  pauseWhenNotifier: _pauseDirectoryBgVideoForChildRoute,
                ),
              )
            else if (_backgroundImage != null)
              Positioned.fill(
                child: StoredViewImageLayer(
                  key: ValueKey(
                    'dir_bg_${_backgroundImage!.path}_$_backgroundViewRefreshTick',
                  ),
                  file: _backgroundImage!,
                ),
              ),

            // 第二层：背景颜色层（有图/视频时默认全透明）
            Container(
              color: backgroundTintLayerColor(
                stored: _backgroundColor,
                hasBackgroundMedia:
                    _backgroundImage != null || _backgroundVideo != null,
                fallbackWhenNoMedia: Colors.white,
              ),
            ),

            // 第三层：内容层
            Positioned.fill(
              child: Container(
                child:
                    _items.isEmpty
                        ? Padding(
                          padding: EdgeInsets.only(top: contentTop),
                          child: Center(
                            child: Text(
                              '没有文件夹或文档\n点击右上角的 + 按钮添加',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        )
                        : ReorderableListView.builder(
                          onReorder:
                              _isMultiSelectMode
                                  ? (oldIndex, newIndex) {}
                                  : _onReorder,
                          padding: EdgeInsets.fromLTRB(
                            0,
                            contentTop + 4.0,
                            0,
                            listBottomPadding,
                          ),
                          itemCount: _items.length,
                          buildDefaultDragHandles: false,
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            bool isHighlighted =
                                _lastCreatedItemName == item.name &&
                                _lastCreatedItemType == item.type &&
                                _isHighlightingNewItem;
                            final bool isLastVisited =
                                _lastVisitedItemName != null &&
                                _lastVisitedItemType == item.type &&
                                item.name.trim() ==
                                    _lastVisitedItemName!.trim();

                            Widget buildListItem(
                              DirectoryItem item,
                              int index,
                              bool isHighlighted,
                              bool isLastVisited,
                            ) {
                              final itemFeedback = Material(
                                elevation: 4.0,
                                child: Container(
                                  padding: EdgeInsets.all(8.0),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(4.0),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (_isMultiSelectMode)
                                        Padding(
                                          padding: EdgeInsets.only(right: 8.0),
                                          child: Icon(
                                            item.isSelected
                                                ? Icons.check_box
                                                : Icons.check_box_outline_blank,
                                            color: Colors.blue,
                                            size: 24,
                                          ),
                                        ),
                                      Icon(
                                        item.type == ItemType.folder
                                            ? Icons.folder
                                            : Icons.description,
                                        size: 40,
                                        color:
                                            item.type == ItemType.folder
                                                ? Color(0xFFFFCA28)
                                                : Color(0xFF4CAF50),
                                      ),
                                      SizedBox(width: 8.0),
                                      Text(
                                        item.name,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );

                              Widget buildIcon() {
                                if (item.type == ItemType.folder) {
                                  return DragTarget<DirectoryItem>(
                                    onWillAccept: (draggedItem) {
                                      if (draggedItem == null) return false;
                                      if (draggedItem.type == ItemType.folder &&
                                          draggedItem.name == item.name)
                                        return false;
                                      if (draggedItem.type == ItemType.folder) {
                                        final folders =
                                            _items
                                                .where(
                                                  (i) =>
                                                      i.type == ItemType.folder,
                                                )
                                                .toList();
                                        bool isChild = _isChildFolder(
                                          draggedItem.name,
                                          item.name,
                                          folders,
                                        );
                                        if (isChild) return false;
                                      }
                                      return true;
                                    },
                                    onAccept: (
                                      DirectoryItem draggedItem,
                                    ) async {
                                      if (draggedItem.type ==
                                          ItemType.document) {
                                        await getService<DatabaseService>()
                                            .updateDocumentParentFolder(
                                              draggedItem.name,
                                              item.name,
                                            );
                                      } else if (draggedItem.type ==
                                          ItemType.folder) {
                                        await getService<DatabaseService>()
                                            .updateFolderParentFolder(
                                              draggedItem.name,
                                              item.name,
                                            );
                                      }
                                      if (mounted) {
                                        await _loadData();
                                      }
                                    },
                                    builder: (
                                      context,
                                      candidateItems,
                                      rejectedItems,
                                    ) {
                                      return Draggable<DirectoryItem>(
                                        data: item,
                                        feedback: Material(
                                          elevation: 8.0,
                                          color: Colors.transparent,
                                          child: Icon(
                                            Icons.folder,
                                            size: 56,
                                            color: Colors.blueAccent,
                                            shadows: [
                                              Shadow(
                                                color: Colors.black26,
                                                blurRadius: 8,
                                              ),
                                            ],
                                          ),
                                        ),
                                        childWhenDragging: Opacity(
                                          opacity: 0.3,
                                          child: Icon(
                                            Icons.folder,
                                            size: 40,
                                            color: Colors.amber,
                                          ),
                                        ),
                                        child: AnimatedContainer(
                                          duration: Duration(milliseconds: 150),
                                          decoration: BoxDecoration(
                                            color:
                                                candidateItems.isNotEmpty
                                                    ? Colors.blue.withOpacity(
                                                      0.2,
                                                    )
                                                    : null,
                                            border:
                                                candidateItems.isNotEmpty
                                                    ? Border.all(
                                                      color: Colors.blue,
                                                      width: 2,
                                                    )
                                                    : null,
                                            borderRadius: BorderRadius.circular(
                                              4.0,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.folder,
                                            size: 40,
                                            color: Colors.amber,
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                } else {
                                  return Draggable<DirectoryItem>(
                                    data: item,
                                    feedback: Material(
                                      elevation: 8.0,
                                      color: Colors.transparent,
                                      child: Icon(
                                        Icons.description,
                                        size: 56,
                                        color: Colors.green,
                                        shadows: [
                                          Shadow(
                                            color: Colors.black26,
                                            blurRadius: 8,
                                          ),
                                        ],
                                      ),
                                    ),
                                    childWhenDragging: Opacity(
                                      opacity: 0.3,
                                      child: Icon(
                                        Icons.description,
                                        size: 40,
                                        color: Color(0xFF4CAF50),
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.description,
                                      size: 40,
                                      color: Color(0xFF4CAF50),
                                    ),
                                  );
                                }
                              }

                              return DirectoryLastVisitedFrame(
                                active: isLastVisited,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Material(
                                      color: Colors.transparent,
                                      child: ListTile(
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 16.0,
                                          vertical: 0.0,
                                        ),
                                        dense: false,
                                        leading: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (_isMultiSelectMode)
                                              Padding(
                                                padding: EdgeInsets.only(
                                                  right: 8.0,
                                                ),
                                                child: Icon(
                                                  item.isSelected
                                                      ? Icons.check_box
                                                      : Icons
                                                          .check_box_outline_blank,
                                                  color: Colors.blue,
                                                  size: 24,
                                                ),
                                              ),
                                            buildIcon(),
                                            if (item.isTemplate)
                                              Padding(
                                                padding: EdgeInsets.only(
                                                  left: 4.0,
                                                ),
                                                child: Icon(
                                                  Icons.star,
                                                  color: Colors.amber,
                                                  size: 16,
                                                ),
                                              ),
                                          ],
                                        ),
                                        title: Text(
                                          item.name,
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color:
                                                item.type == ItemType.folder
                                                    ? Colors.blueAccent
                                                    : Colors.green,
                                          ),
                                        ),
                                        trailing: ReorderableDragStartListener(
                                          index: index,
                                          child: Icon(
                                            Icons.drag_handle,
                                            color: Colors.grey,
                                          ),
                                        ),
                                        onTap: () {
                                          if (_isMultiSelectMode) {
                                            _toggleItemSelection(item);
                                          } else {
                                            if (item.type == ItemType.folder) {
                                              _openFolder(item.name);
                                            } else {
                                              _openDocument(item.name);
                                            }
                                          }
                                        },
                                        onLongPress: () {
                                          if (item.type == ItemType.folder) {
                                            _showFolderOptions(item.name);
                                          } else {
                                            _showDocumentOptions(item.name);
                                          }
                                        },
                                        tileColor:
                                            isHighlighted
                                                ? Colors.blue.withOpacity(0.2)
                                                : item.isSelected &&
                                                    _isMultiSelectMode
                                                ? Colors.blue.withOpacity(0.1)
                                                : null,
                                        selectedTileColor: Colors.blue
                                            .withOpacity(0.15),
                                        selected: item.isSelected,
                                      ),
                                    ),
                                    Divider(height: 5.0),
                                  ],
                                ),
                              );
                            }

                            return Container(
                              key: ValueKey('${item.type}_${item.name}'),
                              child: buildListItem(
                                item,
                                index,
                                isHighlighted,
                                isLastVisited,
                              ),
                            );
                          },
                        ),
              ),
            ),
            if (_isMultiSelectMode && _selectedItems.isNotEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.white,
                  child: SafeArea(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: _deleteSelectedItems,
                          tooltip: '删除',
                        ),
                        IconButton(
                          icon: const Icon(Icons.folder),
                          onPressed: _moveSelectedItemsToFolder,
                          tooltip: '移动到文件夹',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            _buildDirectoryFloatingTopBar(),
          ],
        ),
      ),
    );
  }

  Future<void> _copyFolder(String folderName) async {
    try {
      // 调用数据层复制，并保持在当前父级下创建副本
      final String newFolderName = await getService<DatabaseService>()
          .copyFolder(folderName);
      if (mounted) {
        await _loadData();
        _highlightNewItem(newFolderName, ItemType.folder);
      }
    } catch (e) {
      Logger.log('复制文件夹出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('复制文件夹出错，请重试。')));
      }
    }
  }
}

class DirectoryItem {
  final String name;
  final ItemType type;
  final int order;
  final bool isTemplate;
  final String? parentFolder;
  double x;
  double y;
  bool isSelected;

  DirectoryItem({
    required this.name,
    required this.type,
    required this.order,
    required this.isTemplate,
    this.parentFolder,
    this.x = 0.0,
    this.y = 0.0,
    this.isSelected = false,
  });
}

enum ItemType { folder, document }
