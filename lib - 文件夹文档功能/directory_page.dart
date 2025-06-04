import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'core/service_locator.dart';
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
import 'services/image_picker_service.dart';

class DirectoryPage extends StatefulWidget {
  final Function(String) onDocumentOpen;

  static final GlobalKey<_DirectoryPageState> directoryKey = GlobalKey<_DirectoryPageState>();

  DirectoryPage({Key? key, required this.onDocumentOpen})
      : super(key: key ?? directoryKey);

  @override
  _DirectoryPageState createState() => _DirectoryPageState();

  static void refresh() {
    if (directoryKey.currentState != null) {
      directoryKey.currentState!.forceRefresh();
    }
  }
}

class _DirectoryPageState extends State<DirectoryPage> with WidgetsBindingObserver {

  void _showWebUnsupportedDialog() {
    if (!mounted || !kIsWeb) return; // Also check kIsWeb to be sure
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
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
  Color? _backgroundColor;
  List<Map<String, dynamic>> _templateDocuments = [];
  String? _lastCreatedItemName;
  ItemType? _lastCreatedItemType;
  Timer? _highlightTimer;
  bool _isHighlightingNewItem = false;
  bool _isMultiSelectMode = false;
  final List<DirectoryItem> _selectedItems = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb) {
      _loadData();
      _loadBackgroundSettings();
      _loadTemplateDocuments();
    } else {
      print("Web environment detected: Database-dependent features in initState are skipped.");
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadBackgroundSettings();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (mounted && state == AppLifecycleState.resumed) {
      _loadBackgroundSettings();
      _loadData();
    }
  }

  @override
  void didPushNext() {
    print('DirectoryPage被覆盖 - 保存当前状态');
    _saveCurrentBackgroundState();
  }

  @override
  void didPopNext() {
    print('DirectoryPage重新显示 - 重新加载设置');
    if (mounted) {
      _loadBackgroundSettings();
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请先选择要删除的项目')),
        );
      }
      return;
    }

    bool confirmDelete = await _showDeleteConfirmationDialog("选中的项目", "这些项目");
    if (confirmDelete) {
      try {
        for (var item in _selectedItems) {
          if (item.type == ItemType.document) {
            await getService<DatabaseService>().deleteDocument(item.name, parentFolder: _currentParentFolder ?? '');
            await getService<DatabaseService>().deleteDocument(item.name, parentFolder: _currentParentFolder);
          } else if (item.type == ItemType.folder) {
            await getService<DatabaseService>().deleteFolder(item.name, parentFolder: _currentParentFolder);
          }
        }
        _selectedItems.clear();
        _isMultiSelectMode = false;
        if (mounted) {
          await _loadData();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已删除选中的项目')),
          );
        }
      } catch (e) {
        print('批量删除出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('批量删除出错，请重试')),
          );
        }
      }
    }
  }

  void _moveSelectedItemsToFolder() async {
    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请先选择要移动的项目')),
        );
      }
      return;
    }

    String? targetFolderName = await _selectFolder();
    if (targetFolderName != null) {
      try {
        // 检查是否存在循环依赖
        for (var item in _selectedItems) {
          if (item.type == ItemType.folder) {
            // 不能将文件夹移动到自身
            if (item.name == targetFolderName) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('不能将文件夹移动到自身')),
                );
              }
              return;
            }
            
            // 不能将文件夹移动到其子文件夹中
            String itemPath = await _getDirectoryFolderPath(targetFolderName);
            if (itemPath.contains('${item.name}/') || itemPath.endsWith('/${item.name}')) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('不能将文件夹移动到其子文件夹中')),
                );
              }
              return;
            }
          }
        }

        // 批量移动操作
        final dbService = getService<DatabaseService>();
        
        // 获取目标文件夹信息
        print('获取目标文件夹信息: $targetFolderName');
        Map<String, dynamic>? targetFolder = await dbService.getFolderByName(targetFolderName);
        if (targetFolder == null) {
          throw Exception('目标文件夹不存在: $targetFolderName');
        }
        
        for (var item in _selectedItems) {
          if (item.type == ItemType.document) {
            print('移动文档 ${item.name} 到文件夹 $targetFolderName');
            await dbService.updateDocumentParentFolder(item.name, targetFolderName);
          } else if (item.type == ItemType.folder) {
            print('移动文件夹 ${item.name} 到文件夹 $targetFolderName');
            await dbService.updateFolderParentFolder(item.name, targetFolderName);
          }
        }
        
        _selectedItems.clear();
        _isMultiSelectMode = false;
        if (mounted) {
          print('移动完成，重新加载数据...');
          await _loadData();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已将选中的项目移动到 $targetFolderName')),
          );
        }
      } catch (e) {
        print('批量移动出错: $e');
        if (mounted) {
          String errorMsg = '批量移动出错，请重试';
          if (e.toString().isNotEmpty) {
            // 截取错误信息的前50个字符，避免过长
            String errorDetails = e.toString();
            if (errorDetails.length > 50) {
              errorDetails = '${errorDetails.substring(0, 50)}...';
            }
            errorMsg = '批量移动出错: $errorDetails';
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(errorMsg)),
          );
        }
      }
    }
  }

  void _moveSelectedItemsToDirectory() async {
    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请先选择要移动的项目')),
        );
      }
      return;
    }

    bool confirmMove = await _showMoveConfirmationDialog("选中的项目", "这些项目", "目录");
    if (confirmMove) {
      try {
        final dbService = getService<DatabaseService>();
        
        for (var item in _selectedItems) {
          if (item.type == ItemType.document) {
            print('移动文档 ${item.name} 到根目录');
            await dbService.updateDocumentParentFolder(item.name, null);
          } else if (item.type == ItemType.folder) {
            print('移动文件夹 ${item.name} 到根目录');
            await dbService.updateFolderParentFolder(item.name, null);
          }
        }
        _selectedItems.clear();
        _isMultiSelectMode = false;
        if (mounted) {
          print('移动到根目录完成，重新加载数据...');
          await _loadData();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已将选中的项目移动到目录')),
          );
        }
      } catch (e) {
        print('批量移动到目录出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('批量移动到目录出错，请重试')),
          );
        }
      }
    }
  }

  Future<void> _loadBackgroundSettings() async {
    if (kIsWeb) {
      print("Web environment: Skipping background settings load from database.");
      if (mounted) {
        setState(() {
          _backgroundImage = null;
          _backgroundColor = Colors.white; // Default for web
        });
      }
      return;
    }
    try {
      print('开始加载背景设置 for folder: $_currentParentFolder');
      Map<String, dynamic>? settings = await getService<DatabaseService>().getDirectorySettings(_currentParentFolder ?? '');

      if (settings != null) {
        String? imagePath = settings['background_image_path'];
        int? colorValue = settings['background_color'];

        print('从数据库加载设置 - 图片路径: ${imagePath ?? "空"}, 颜色值: ${colorValue ?? "空"}');

        if (mounted) {
          setState(() {
            if (colorValue != null) {
              _backgroundColor = Color(colorValue);
              print('已加载背景颜色: $colorValue');
            } else {
              _backgroundColor = null;
              print('背景颜色为空');
            }
          });
        }

        if (imagePath != null && imagePath.isNotEmpty) {
          File imageFile = File(imagePath);
          bool exists = await imageFile.exists();
          print('检查图片文件: $imagePath, 是否存在: $exists');

          if (exists && mounted) {
            setState(() {
              _backgroundImage = imageFile;
              print('已加载背景图片: $imagePath');
            });
          } else {
            print('背景图片文件不存在: $imagePath');
            if (mounted) {
              setState(() {
                _backgroundImage = null;
              });
            }
            await getService<DatabaseService>().deleteDirectoryBackgroundImage(_currentParentFolder ?? '');
          }
        } else if (mounted) {
          setState(() {
            _backgroundImage = null;
            print('背景图片路径为空');
          });
        }
      } else if (mounted) {
        setState(() {
          _backgroundImage = null;
          _backgroundColor = null;
        });
        print('未找到目录设置');
      }
    } catch (e) {
      print('加载背景设置时出错: $e');
      if (mounted) {
        setState(() {
          _backgroundImage = null;
          _backgroundColor = Colors.white;
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
      final imagePath = await ImagePickerService.pickImage(context);

      if (imagePath != null) {
        final Directory appDocDir = await getApplicationDocumentsDirectory();
        final String backgroundImagesPath = '${appDocDir.path}/background_images';

        final Directory backgroundDir = Directory(backgroundImagesPath);
        if (!await backgroundDir.exists()) {
          await backgroundDir.create(recursive: true);
        }

        final String fileName = 'background_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final String permanentPath = '$backgroundImagesPath/$fileName';

        final File newImage = await File(imagePath).copy(permanentPath);

        Map<String, dynamic>? settings = await getService<DatabaseService>().getDirectorySettings(_currentParentFolder ?? '');
        int? colorValue = settings != null ? settings['background_color'] : null;

        if (mounted) {
          setState(() {
            _backgroundImage = newImage;
          });
        }

        await getService<DatabaseService>().insertOrUpdateDirectorySettings(
          _currentParentFolder ?? '',
          imagePath: imagePath,
          colorValue: colorValue,
        );

        print('已持久化保存背景图片: $permanentPath');
      }
    } catch (e) {
      print('选择背景图片出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择背景图像出错。请重试。')),
        );
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
        Map<String, dynamic>? settings = await getService<DatabaseService>().getDirectorySettings(_currentParentFolder ?? '');
        int? colorValue = settings != null ? settings['background_color'] : null;

        await getService<DatabaseService>().deleteDirectoryBackgroundImage(_currentParentFolder ?? '');

        await getService<DatabaseService>().insertOrUpdateDirectorySettings(
          _currentParentFolder ?? '',
          imagePath: null,
          colorValue: colorValue,
        );

        if (mounted) {
          setState(() {
            _backgroundImage = null;
          });
        }

        print('背景图片已删除');
      } catch (e) {
        print('移除背景图片出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('移除背景图像出错。请重试。')),
          );
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

        Map<String, dynamic>? settings = await getService<DatabaseService>().getDirectorySettings(_currentParentFolder ?? '');
        String? currentImagePath = settings != null ? settings['background_image_path'] : null;

        await getService<DatabaseService>().insertOrUpdateDirectorySettings(
          _currentParentFolder ?? '',
          imagePath: currentImagePath,
          colorValue: _backgroundColor!.value,
        );

        print('成功更新背景颜色: ${_backgroundColor!.value}');
      } catch (e) {
        print('设置背景颜色时出错: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('设置背景颜色出错。请重试。')),
          );
        }
      }
    }
  }

  Future<Color?> _showColorPickerDialog() async {
    Color tempColor = _backgroundColor ?? Colors.white;
    return showDialog<Color>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('选择背景颜色'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: tempColor,
              onColorChanged: (Color color) {
                tempColor = color;
              },
              colorPickerWidth: 300.0,
              pickerAreaHeightPercent: 0.7,
              enableAlpha: false,
              displayThumbColor: true,
              paletteType: PaletteType.hsv,
            ),
          ),
          actions: [
            TextButton(
              child: Text('取消'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: Text('确定'),
              onPressed: () => Navigator.of(context).pop(tempColor),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadTemplateDocuments() async {
    if (kIsWeb) {
      print("Web environment: Skipping template documents load from database.");
      if (mounted) {
        setState(() {
          _templateDocuments = [];
        });
      }
      return;
    }
    try {
      _templateDocuments = await getService<DatabaseService>().getTemplateDocuments();
    } catch (e) {
      print('加载模板文档出错: $e');
    }
  }

  Future<void> _loadData() async {
    if (kIsWeb) {
      print("Web environment: Skipping data load from database.");
      if (mounted) {
        setState(() {
          _items.clear();
          // _isLoading = false; // Assuming _isLoading is handled elsewhere or not critical for web if no data loads
        });
      }
      return;
    }
    try {
      _items.clear();
      print('清除项目列表，开始加载数据...');
      List<Map<String, dynamic>> folders = await getService<DatabaseService>().getFolders(parentFolder: _currentParentFolder ?? '');
      print('从数据库加载了 ${folders.length} 个文件夹');

      for (var folder in folders) {
        print('加载文件夹: ${folder['name']}, 顺序: ${folder['order_index']}');
        _items.add(DirectoryItem(
          name: folder['name'],
          type: ItemType.folder,
          order: folder['order_index'] ?? 0,
          isTemplate: false,
          isSelected: false,
        ));
      }

      List<Map<String, dynamic>> documents = await getService<DatabaseService>().getDocuments(parentFolder: _currentParentFolder ?? '');
      print('从数据库加载了 ${documents.length} 个文档');

      for (var document in documents) {
        print('加载文档: ${document['name']}, 顺序: ${document['order_index']}');
        _items.add(DirectoryItem(
          name: document['name'],
          type: ItemType.document,
          order: document['order_index'] ?? 0,
          isTemplate: document['is_template'] == 1,
          isSelected: false,
        ));
      }

      _items.sort((a, b) => a.order.compareTo(b.order));

      print('已加载 ${_items.length} 个项目，正在更新界面...');
      if (mounted) {
        setState(() {});
      }

      _loadTemplateDocuments();
    } catch (e) {
      print('Error loading data: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载数据时出错。请重试。')),
        );
      }
    }
  }

  void _openFolder(String folderName) {
    if (mounted) {
      setState(() {
        _currentParentFolder = folderName;
        _isMultiSelectMode = false;
        _selectedItems.clear();
        for (var item in _items) {
          item.isSelected = false;
        }
      });

      _loadData();
    }
  }

  void _goBack() {
    if (_currentParentFolder != null) {
      _getParentFolder(_currentParentFolder!).then((parent) {
        if (mounted) {
          setState(() {
            _currentParentFolder = parent;
            _isMultiSelectMode = false;
            _selectedItems.clear();
            for (var item in _items) {
              item.isSelected = false;
            }
          });
          _loadData();
        }
      });
    }
  }

  Future<String?> _getParentFolder(String folderName) async {
    try {
      // getFolderByName returns Map<String, dynamic>? not List<Map<String, dynamic>>
      Map<String, dynamic>? folderData = await getService<DatabaseService>().getFolderByName(folderName);
      if (folderData != null && folderData.containsKey('parentFolder')) {
        return folderData['parentFolder'] as String?;
      }
      return null;
    } catch (e) {
      print('Error getting parent folder: $e');
      return null;
    }
  }

  void _exportDocument(String documentName) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final exportPath = '${tempDir.path}/$documentName.zip';
      await getService<DatabaseService>().exportDocument(documentName, exportPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文档已导出到 $exportPath')),
        );
      }
      await Share.shareXFiles([XFile(exportPath)], text: '文档备份文件');
    } catch (e) {
      print('Error exporting document: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出文档出错：$e')),
        );
      }
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

  void _addFolder() async {
    try {
      String? folderName = await _showFolderNameDialog(hintText: "文件夹名称");
      if (folderName != null && folderName.isNotEmpty) {
        if (!await getService<DatabaseService>().doesNameExist(folderName)) {
          String? parentFolder = _currentParentFolder;

          await getService<DatabaseService>().insertFolder(
            folderName,
            parentFolder: parentFolder,
          );

          if (mounted) {
            await _loadData();
            _highlightNewItem(folderName, ItemType.folder);
          }
        } else {
          _showDuplicateNameWarning();
          if (mounted) {
            await _loadData(); // Refresh data even if name is duplicate
          }
        }
      }
    } catch (e) {
      print('Error adding folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加文件夹出错。请重试。')),
        );
      }
    }
  }

  void _addDocument() async {
    try {
      String? documentName = await _showFolderNameDialog(hintText: "文档名称");
      if (documentName != null && documentName.isNotEmpty) {
        if (!await getService<DatabaseService>().doesNameExist(documentName)) {
          String? parentFolder = _currentParentFolder;

          await getService<DatabaseService>().insertDocument(
            documentName,
            parentFolder: parentFolder,
          );

          if (mounted) {
            await _loadData();
            _highlightNewItem(documentName, ItemType.document);
          }
        } else {
          _showDuplicateNameWarning();
          if (mounted) {
            await _loadData(); // Refresh data even if name is duplicate
          }
        }
      }
    } catch (e) {
      print('Error adding document: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加文档出错。请重试。')),
        );
      }
    }
  }

  void _importDocument() async {
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
          builder: (context) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text('正在导入文档...')
              ],
            ),
          ),
        );

        List<String> successFiles = [];
        List<String> failedFiles = [];

        for (var file in result.files) {
          if (file.path != null) {
            String zipPath = file.path!;
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
              );
              successFiles.add(originalName);
            } catch (e) {
              print('导入文档 $originalName 时出错: $e');
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
            message += '导入失败 ${failedFiles.length} 个文档：${failedFiles.join(", ")}';
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未选择备份文件')),
          );
        }
      }
    } catch (e) {
      print('批量导入文档时出错: $e');
      if (mounted) {
        Navigator.of(context).pop(); // 确保关闭进度对话框
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入文档时出错：$e')),
        );
      }
    }
  }

  void _deleteDocument(String documentName) async {
    bool confirmDelete = await _showDeleteConfirmationDialog("文档", documentName);
    if (confirmDelete) {
      try {
        String? parentFolder = _currentParentFolder;
        await getService<DatabaseService>().deleteDocument(documentName, parentFolder: parentFolder);
        if (mounted) {
          setState(() {
            _items.removeWhere((item) => item.type == ItemType.document && item.name == documentName);
          });
        }
      } catch (e) {
        print('Error deleting document: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('删除文档出错。请重试。')),
          );
        }
      }
    }
  }

  void _deleteFolder(String folderName) async {
    bool confirmDelete = await _showDeleteConfirmationDialog("文件夹", folderName);
    if (confirmDelete) {
      try {
        String? parentFolder = _currentParentFolder;
        await getService<DatabaseService>().deleteFolder(folderName, parentFolder: parentFolder);
        if (mounted) {
          setState(() {
            _items.removeWhere((item) => item.type == ItemType.folder && item.name == folderName);
          });
        }
      } catch (e) {
        print('Error deleting folder: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('删除文件夹出错。请重试。')),
          );
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
    ) ?? false;
  }

  void _renameDocument(String oldName) async {
    String? newName = await _showFolderNameDialog(hintText: "新文档名称", initialValue: oldName);
    if (newName != null && newName.isNotEmpty) {
      final now = DateTime.now();
      final dateStr = "${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}";
      newName = "$newName-$dateStr";

      if (!await getService<DatabaseService>().doesNameExist(newName)) {
        try {
          await getService<DatabaseService>().renameDocument(oldName, newName);
          if (mounted) {
            await _loadData();
          }
        } catch (e) {
          print('Error renaming document: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('重命名文档出错。请重试。')),
            );
          }
        }
      } else {
        _showDuplicateNameWarning();
      }
    }
  }

  void _renameFolder(String oldName) async {
    String? newName = await _showFolderNameDialog(hintText: "新文件夹名称", initialValue: oldName);
    if (newName != null && newName.isNotEmpty) {
      final now = DateTime.now();
      final dateStr = "${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}";
      newName = "$newName-$dateStr";

      if (!await getService<DatabaseService>().doesNameExist(newName)) {
        try {
          await getService<DatabaseService>().renameFolder(oldName, newName);
          if (mounted) {
            await _loadData();
          }
        } catch (e) {
          print('Error renaming folder: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('重命名文件夹出错。请重试。')),
            );
          }
        }
      } else {
        _showDuplicateNameWarning();
      }
    }
  }

  void _moveDocumentToDirectory(String documentName) async {
    try {
      await getService<DatabaseService>().updateDocumentParentFolder(documentName, null);
      if (mounted) {
        await _loadData();
      }
    } catch (e) {
      print('Error moving document to directory: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移动文档到目录出错。请重试。')),
        );
      }
    }
  }

  void _moveFolderToDirectory(String folderName) async {
    try {
      await getService<DatabaseService>().updateFolderParentFolder(folderName, null);
      if (mounted) {
        await _loadData();
      }
    } catch (e) {
      print('Error moving folder to directory: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移动文件夹到目录出错。请重试。')),
        );
      }
    }
  }

  void _moveDocumentToDirectoryOption(String documentName) async {
    bool confirmMove = await _showMoveConfirmationDialog("文档", documentName, "目录");
    if (confirmMove) {
      _moveDocumentToDirectory(documentName);
    }
  }

  void _moveFolderToDirectoryOption(String folderName) async {
    bool confirmMove = await _showMoveConfirmationDialog("文件夹", folderName, "目录");
    if (confirmMove) {
      _moveFolderToDirectory(folderName);
    }
  }

  void _moveFolderToFolder(String folderName) async {
    String? targetFolderName = await _selectFolder();
    if (targetFolderName != null) {
      try {
        await getService<DatabaseService>().updateFolderParentFolder(folderName, targetFolderName);
        if (mounted) {
          await _loadData();
        }
      } catch (e) {
        print('Error moving folder to another folder: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('移动文件夹到另一个文件夹出错。请重试。')),
          );
        }
      }
    }
  }

  Future<bool> _showMoveConfirmationDialog(String type, String name, String target) async {
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
    ) ?? false;
  }

  Future<String?> _selectFolder() async {
    try {
      List<Map<String, dynamic>> allFolders = await getService<DatabaseService>().getAllDirectoryFolders();
      if (allFolders.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('没有可选择的文件夹。')),
          );
        }
        return null;
      }

      List<String> folderPaths = [];
      for (var folder in allFolders) {
        String path = await _getDirectoryFolderPath(folder['name']);
        folderPaths.add(path);
      }

      String? selectedFolderPath = await showDialog<String>(
        context: context,
        builder: (BuildContext context) {
          return SimpleDialog(
            title: Text('选择文件夹'),
            children: folderPaths.map((folderPath) => SimpleDialogOption(
              child: Text(folderPath),
              onPressed: () => Navigator.pop(context, folderPath),
            )).toList(),
          );
        },
      );

      if (selectedFolderPath != null) {
        String folderName = selectedFolderPath.split('/').last;
        return folderName;
      }

      return null;
    } catch (e) {
      print('Error selecting folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件夹出错。请重试。')),
        );
      }
      return null;
    }
  }

  Future<String> _getDirectoryFolderPath(String folderName) async {
    final dbService = getService<DatabaseService>();
    String currentPath = folderName;
    
    try {
      // getFolderByName returns Map<String, dynamic>? not List<Map<String, dynamic>>
      Map<String, dynamic>? currentFolderData = await dbService.getFolderByName(folderName);
      String? parentFolderName = (currentFolderData != null && currentFolderData.containsKey('parent_folder')) 
          ? currentFolderData['parent_folder'] as String? 
          : null;
      
      while (parentFolderName != null) {
        currentPath = '$parentFolderName/$currentPath';
        currentFolderData = await dbService.getFolderByName(parentFolderName);
        parentFolderName = (currentFolderData != null && currentFolderData.containsKey('parent_folder')) 
            ? currentFolderData['parent_folder'] as String? 
            : null;
      }
      
      return currentPath;
    } catch (e) {
      print('获取文件夹路径出错: $e');
      return folderName; // 出错时至少返回文件夹名称
    }
  }

  Future<String?> _showFolderNameDialog({String? hintText, String? initialValue}) async {
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

  void _showDuplicateNameWarning() {
    showDialog(
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
          await getService<DatabaseService>().updateFolderOrder([item.name]);
        } else if (item.type == ItemType.document) {
          await getService<DatabaseService>().updateDocumentOrder([item.name]);
        }
      }
    } catch (e) {
      print('Error updating order: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新顺序出错。请重试。')),
        );
      }
    }
  }

  void _moveDocumentToFolder(String documentName) async {
    String? folderName = await _selectFolder();
    if (folderName != null) {
      try {
        await getService<DatabaseService>().updateDocumentParentFolder(documentName, folderName);
        if (mounted) {
          await _loadData();
        }
      } catch (e) {
        print('Error moving document: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('移动文档出错。请重试。')),
          );
        }
      }
    }
  }

  void _openDocument(String documentName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DocumentEditorPage(
          documentName: documentName,
          onSave: (updatedTextBoxes) {},
        ),
      ),
    ).then((_) {
      print('从文档编辑页面返回');
      if (mounted) {
        _loadBackgroundSettings();
        _loadData();
      }
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
      await getService<DatabaseService>().copyDocument(
        documentName, 
        parentFolder: _currentParentFolder
      );
      if (mounted) {
        await _loadData();
        _highlightNewItem(documentName, ItemType.document);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文档已复制为: $documentName')),
        );
      }
    } catch (e) {
      print('复制文档出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('复制文档出错，请重试。')),
        );
      }
    }
  }

  void _showDocumentOptions(String documentName) async {
    bool isTemplate = await _isDocumentTemplate(documentName);

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: SingleChildScrollView(
            child: Wrap(
              children: [
                ListTile(
                  leading: Icon(Icons.delete),
                  title: Text('删除'),
                  contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
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
                  contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
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
                  contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
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
                  contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
                  dense: true,
                  onTap: () async {
                    Navigator.pop(context);
                    await getService<DatabaseService>().setDocumentAsTemplate(documentName, !isTemplate);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(isTemplate ? '已取消设为模板' : '已设为模板')),
                      );
                      _loadData();
                    }
                  },
                ),
                Divider(height: 1.0, thickness: 0.5),
                ListTile(
                  leading: Icon(Icons.folder),
                  title: Text('移动到文件夹'),
                  contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
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
                  contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
                  dense: true,
                  onTap: () {
                    Navigator.pop(context);
                    _moveDocumentToDirectoryOption(documentName);
                  },
                ),
                Divider(height: 1.0, thickness: 0.5),
                ListTile(
                  leading: Icon(Icons.share),
                  title: Text('导出'),
                  contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
                  dense: true,
                  onTap: () {
                    Navigator.pop(context);
                    _exportDocument(documentName);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFolderOptions(String folderName) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.edit),
              title: Text('重命名'),
              onTap: () {
                Navigator.pop(context);
                _renameFolder(folderName);
              },
            ),
            ListTile(
              leading: Icon(Icons.folder_open),
              title: Text('移动到文件夹'),
              onTap: () {
                Navigator.pop(context);
                _moveFolderToFolder(folderName);
              },
            ),
            ListTile(
              leading: Icon(Icons.drive_file_move),
              title: Text('移动到目录'),
              onTap: () {
                Navigator.pop(context);
                _moveFolderToDirectoryOption(folderName);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete),
              title: Text('删除'),
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

  void _showDirectorySettings() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
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
              leading: Icon(Icons.color_lens),
              title: Text('设置背景颜色'),
              onTap: () {
                Navigator.pop(context);
                _pickBackgroundColor();
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
            Divider(),
            ListTile(
              leading: Icon(Icons.backup),
              title: Text('导出所有数据'),
              onTap: () {
                Navigator.pop(context);
                _exportAllData();
              },
            ),
            ListTile(
              leading: Icon(Icons.restore),
              title: Text('导入所有数据'),
              onTap: () {
                Navigator.pop(context);
                _importAllData();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showTemplateSelectionDialog() async {
    if (_templateDocuments.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('没有可用的模板文档。请先将文档设置为模板。')),
        );
      }
      return;
    }

    if (_templateDocuments.length == 1) {
      await _createDocumentFromTemplate(_templateDocuments[0]['name']);
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
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
      await getService<DatabaseService>().createDocumentFromTemplate(
        templateName, 
        newName, 
        parentFolder: _currentParentFolder
      );

      if (mounted) {
        await _loadData();
        _highlightNewItem(newName, ItemType.document);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已从模板创建文档: $newName')),
        );
      }
    } catch (e) {
      print('从模板创建文档时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建文档时出错，请重试。')),
        );
      }
    }
  }

  void _showAddOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.create_new_folder, color: Colors.amber),
              title: Text('新建文件夹'),
              onTap: () {
                Navigator.pop(context);
                _addFolder();
              },
            ),
            ListTile(
              leading: Icon(Icons.note_add, color: Colors.blue),
              title: Text('新建文档'),
              onTap: () {
                Navigator.pop(context);
                _addDocument();
              },
            ),
            ListTile(
              leading: Icon(Icons.file_upload),
              title: Text('导入文档'),
              onTap: () {
                Navigator.pop(context);
                _importDocument();
              },
            ),
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
      print("Web environment: Skipping save current background state.");
      return;
    }
    try {
      if (_backgroundImage != null) {
        print('保存当前背景图片: ${_backgroundImage!.path}');
      }
      if (_backgroundColor != null) {
        print('保存当前背景颜色: ${_backgroundColor!.value}');
      }
    } catch (e) {
      print('保存当前背景状态时出错: $e');
    }
  }

  Future<void> _checkAndRestoreBackgroundImage() async {
    if (kIsWeb) {
      print("Web environment: Skipping background image check/restore from database.");
      return;
    }
    try {
      Map<String, dynamic>? settings = await getService<DatabaseService>().getDirectorySettings(_currentParentFolder ?? '');
      if (settings != null) {
        String? imagePath = settings['background_image_path'];
        if (imagePath != null && imagePath.isNotEmpty) {
          File imageFile = File(imagePath);
          if (await imageFile.exists() && mounted) {
            setState(() {
              _backgroundImage = imageFile;
              print('恢复背景图片: $imagePath');
            });
          }
        }
      }
    } catch (e) {
      print('恢复背景图片时出错: $e');
    }
  }

  void forceRefresh() {
    if (mounted) {
      print('强制刷新页面状态');
      _loadBackgroundSettings();
      setState(() {});
    }
  }

  void _exportSelectedItems() async {
    if (_selectedItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先选择要导出的项目')),
        );
      }
      return;
    }

    try {
      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text('正在准备导出...')
            ],
          ),
        ),
      );

      // 收集所有选中的文件
      List<XFile> filesToShare = [];
      List<String> missingFiles = [];

      for (var item in _selectedItems) {
        if (item.type == ItemType.document) {
          try {
            final tempDir = await getTemporaryDirectory();
            final exportPath = '${tempDir.path}/$item.name.zip';
            await getService<DatabaseService>().exportDocument(item.name, exportPath);
            if (await File(exportPath).exists()) {
              filesToShare.add(XFile(exportPath));
            } else {
              missingFiles.add(item.name);
            }
          } catch (e) {
            print('导出文档 ${item.name} 时出错: $e');
            missingFiles.add(item.name);
          }
        }
      }

      // 关闭进度对话框
      if (mounted) {
        Navigator.pop(context);
      }

      if (filesToShare.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有找到可导出的文件')),
          );
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
            SnackBar(content: Text('以下文件导出失败：${missingFiles.join(", ")}')),
          );
        }
      }
    } catch (e) {
      // 确保关闭进度对话框
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出文件时出错: $e')),
        );
      }
    }
  }

  void _exportAllData() async {
    try {
      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text('正在导出所有数据...')
            ],
          ),
        ),
      );

      final String zipPath = await getService<DatabaseService>().exportAllData();

      // 关闭进度对话框
      if (mounted) {
        Navigator.pop(context);
      }

      // 分享文件
      await Share.shareXFiles(
        [XFile(zipPath)],
        subject: '目录完整备份',
      );
    } catch (e) {
      print('导出所有数据时出错: $e');
      if (mounted) {
        Navigator.pop(context); // 关闭进度对话框
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出数据时出错：$e')),
        );
      }
    }
  }

  void _importAllData() async {
    try {
      // 显示警告对话框
      bool? confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('警告'),
          content: Text('导入新数据将会清空当前所有数据，确定要继续吗？'),
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

      if (result != null && result.files.single.path != null) {
        // 显示进度对话框
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text('正在导入数据...')
              ],
            ),
          ),
        );

        await getService<DatabaseService>().importAllData(result.files.single.path!);

        // 关闭进度对话框
        if (mounted) {
          Navigator.pop(context);
        }

        // 刷新数据
        if (mounted) {
          await _loadData();
          await _loadBackgroundSettings();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('数据导入成功')),
          );
        }
      }
    } catch (e) {
      print('导入所有数据时出错: $e');
      if (mounted) {
        Navigator.pop(context); // 关闭进度对话框
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入数据时出错：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(Duration.zero, () {
        if (_backgroundImage == null && mounted) {
          _checkAndRestoreBackgroundImage();
        }
      });
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentParentFolder ?? '目录'),
        leading: _currentParentFolder != null
            ? IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: _goBack,
        )
            : null,
        actions: [
          if (_isMultiSelectMode) ...[
            IconButton(
              icon: Icon(_items.every((item) => item.isSelected) ? Icons.check_box : Icons.check_box_outline_blank),
              onPressed: _selectAllItems,
              tooltip: '全选/取消全选',
            ),
            IconButton(
              icon: Icon(Icons.cancel),
              onPressed: _toggleMultiSelectMode,
              tooltip: '取消多选',
            ),
          ] else ...[
            IconButton(
              icon: Icon(Icons.select_all),
              onPressed: _toggleMultiSelectMode,
              tooltip: '多选',
            ),
            IconButton(
              icon: Icon(Icons.settings),
              onPressed: _showDirectorySettings,
              tooltip: '设置',
            ),
            GestureDetector(
              onTap: () => _showAddOptions(),
              onDoubleTap: () => _showTemplateSelectionDialog(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Icon(Icons.add_circle),
              ),
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              image: _backgroundImage != null
                  ? DecorationImage(
                image: FileImage(_backgroundImage!),
                fit: BoxFit.cover,
              )
                  : null,
              color: _backgroundColor ?? Colors.white,
            ),
            child: _items.isEmpty
                ? Center(
              child: Text(
                '没有文件夹或文档\n点击右上角的 + 按钮添加',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, color: Colors.grey),
              ),
            )
                : ReorderableListView.builder(
              onReorder: _isMultiSelectMode ? (oldIndex, newIndex) {} : _onReorder,
              padding: EdgeInsets.symmetric(vertical: 4.0),
              itemCount: _items.length,
              buildDefaultDragHandles: false,
              itemBuilder: (context, index) {
                final item = _items[index];
                bool isHighlighted = _lastCreatedItemName == item.name &&
                    _lastCreatedItemType == item.type &&
                    _isHighlightingNewItem;

                Widget buildListItem(DirectoryItem item, int index, bool isHighlighted) {
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
                                item.isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                                color: Colors.blue,
                                size: 24,
                              ),
                            ),
                          Icon(
                            item.type == ItemType.folder
                                ? Icons.folder
                                : Icons.description,
                            size: 40,
                            color: item.type == ItemType.folder
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
                          if (draggedItem?.type == ItemType.folder && draggedItem?.name == item.name) {
                            return false;
                          }
                          return true;
                        },
                        onAccept: (DirectoryItem draggedItem) async {
                          if (draggedItem.type == ItemType.document) {
                            await getService<DatabaseService>().updateDocumentParentFolder(draggedItem.name, item.name);
                          } else if (draggedItem.type == ItemType.folder) {
                            await getService<DatabaseService>().updateFolderParentFolder(draggedItem.name, item.name);
                          }
                          if (mounted) {
                            await _loadData();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('已将 ${draggedItem.name} 移动到 ${item.name} 文件夹')),
                            );
                          }
                        },
                        builder: (context, candidateItems, rejectedItems) {
                          return Container(
                            decoration: BoxDecoration(
                              color: candidateItems.isNotEmpty 
                                ? Colors.blue.withOpacity(0.2) 
                                : null,
                              borderRadius: BorderRadius.circular(4.0),
                            ),
                            child: Icon(
                              Icons.folder,
                              size: 40,
                              color: Color(0xFFFFCA28),
                            ),
                          );
                        },
                      );
                    } else {
                      return Icon(
                        Icons.description,
                        size: 40,
                        color: Color(0xFF4CAF50),
                      );
                    }
                  }

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 0.0),
                        dense: false,
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isMultiSelectMode)
                              Padding(
                                padding: EdgeInsets.only(right: 8.0),
                                child: Icon(
                                  item.isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                                  color: Colors.blue,
                                  size: 24,
                                ),
                              ),
                            buildIcon(),
                            if (item.isTemplate)
                              Padding(
                                padding: EdgeInsets.only(left: 4.0),
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
                            color: item.type == ItemType.folder
                                ? Colors.blueAccent
                                : Colors.green,
                          ),
                        ),
                        trailing: ReorderableDragStartListener(
                          index: index,
                          child: Icon(Icons.drag_handle, color: Colors.grey),
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
                        tileColor: isHighlighted
                            ? Colors.blue.withOpacity(0.2)
                            : item.isSelected && _isMultiSelectMode
                            ? Colors.blue.withOpacity(0.1)
                            : null,
                        selectedTileColor: Colors.blue.withOpacity(0.15),
                        selected: item.isSelected,
                      ),
                      Divider(height: 5.0),
                    ],
                  );
                }

                return Container(
                  key: ValueKey('${item.type}_${item.name}'),
                  child: buildListItem(item, index, isHighlighted),
                );
              },
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
                      IconButton(
                        icon: const Icon(Icons.drive_folder_upload),
                        onPressed: _moveSelectedItemsToDirectory,
                        tooltip: '移动到目录',
                      ),
                      IconButton(
                        icon: const Icon(Icons.share),
                        onPressed: _exportSelectedItems,
                        tooltip: '导出',
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class DirectoryItem {
  final String name;
  final ItemType type;
  final int order;
  final bool isTemplate;
  double x;
  double y;
  bool isSelected;

  DirectoryItem({
    required this.name,
    required this.type,
    required this.order,
    required this.isTemplate,
    this.x = 0.0,
    this.y = 0.0,
    this.isSelected = false,
  });
}

enum ItemType { folder, document }

