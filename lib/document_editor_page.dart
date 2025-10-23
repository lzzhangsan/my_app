import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'resizable_and_configurable_text_box.dart';
import 'resizable_image_box.dart';
import 'resizable_audio_box.dart';
import 'global_tool_bar.dart' as toolBar;
import 'media_player_container.dart';
import 'video_controls_overlay.dart';
import 'widgets/video_player_widget.dart';
import 'widgets/flippable_canvas_widget.dart'; // 新增：导入画布组件
import 'models/flippable_canvas.dart'; // 新增：导入画布模型
import 'dart:async';
import 'dart:math' as math;
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'services/image_picker_service.dart';
import 'models/media_type.dart'; // 导入MediaType枚举
import 'performance_monitor_page.dart';

class DocumentEditorPage extends StatefulWidget {
  final String documentName;
  final Function(List<Map<String, dynamic>>) onSave;
  const DocumentEditorPage({
    super.key,
    required this.documentName,
    required this.onSave,
  });

  @override
  _DocumentEditorPageState createState() => _DocumentEditorPageState();
}

class _DocumentEditorPageState extends State<DocumentEditorPage> {
  List<Map<String, dynamic>> _textBoxes = [];
  List<Map<String, dynamic>> _imageBoxes = [];
  List<Map<String, dynamic>> _audioBoxes = [];
  List<FlippableCanvas> _canvases = []; // 新增：画布列表
  List<String> _deletedTextBoxIds = [];
  List<String> _deletedImageBoxIds = [];
  List<String> _deletedAudioBoxIds = [];
  List<String> _deletedCanvasIds = []; // 新增：已删除的画布ID列表
  List<Map<String, dynamic>> _history = [];
  int _historyIndex = -1;
  late ScrollController _scrollController;
  double _currentScrollOffset = 0.0;
  double _scrollPercentage = 0.0;
  final GlobalKey<MediaPlayerContainerState> _mediaPlayerKey =
  GlobalKey<MediaPlayerContainerState>();
  File? _backgroundImage;
  Color? _backgroundColor;
  bool _isLoading = true;
  bool _isTemplate = false;
  Timer? _autoSaveTimer;
  Timer? _debounceTimer; // 防抖定时器
  bool _contentChanged = false;
  bool _textEnhanceMode = true;
  bool _isPositionLocked = true;
  String? _recordingAudioBoxId;
  bool _isSaving = false; // 添加保存状态标志，防止重复保存
  late final DatabaseService _databaseService;

  @override
  void initState() {
    super.initState();
    _databaseService = getService<DatabaseService>();
    _scrollController = ScrollController()
      ..addListener(() {
        setState(() {
          _currentScrollOffset = _scrollController.offset;
          _updateScrollPercentage();
        });
      });
    _loadBackgroundSettingsAndEnhanceMode().then((_) {
      _loadContent();
    });
    _checkIsTemplate();

    _databaseService.ensureAudioBoxesTableExists();

    // 优化自动保存：减少频率到30秒，并添加防抖机制
    _autoSaveTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      if (_contentChanged && !_isSaving) {
        print('自动保存文档内容...');
        _saveContent();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_contentChanged && !_isSaving) {
      print('依赖变化时保存文档内容...');
      _saveContent();
    }
  }

  void _updateScrollPercentage() {
    double maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll > 0) {
      _scrollPercentage = (_currentScrollOffset / maxScroll) * 100;
    } else {
      _scrollPercentage = 0;
    }
  }

  Future<void> _loadBackgroundSettingsAndEnhanceMode() async {
    try {
      Map<String, dynamic>? settings =
      await _databaseService.getDocumentSettings(widget.documentName);
      if (settings != null) {
        String? imagePath = settings['background_image_path'];
        int? colorValue = settings['background_color'];
        // 强制设置为true，确保所有文档都默认启用这两个功能
        bool textEnhanceMode = true;
        bool positionLocked = true;
        if (imagePath != null && imagePath.isNotEmpty && await File(imagePath).exists()) {
          setState(() {
            _backgroundImage = File(imagePath);
          });
        } else {
          setState(() {
            _backgroundImage = null;
          });
        }
        if (colorValue != null) {
          setState(() {
            _backgroundColor = Color(colorValue);
          });
        }
        setState(() {
          _textEnhanceMode = textEnhanceMode;
          _isPositionLocked = positionLocked;
        });
        
        // 保存默认值到数据库，确保所有文档都有统一的默认设置
        await _databaseService.insertOrUpdateDocumentSettings(
          widget.documentName,
          imagePath: imagePath,
          colorValue: colorValue,
          textEnhanceMode: textEnhanceMode,
          positionLocked: positionLocked,
        );
      } else {
        // 如果没有设置记录，创建默认设置
        setState(() {
          _textEnhanceMode = true;
          _isPositionLocked = true;
        });
        
        // 保存默认值到数据库
        await _databaseService.insertOrUpdateDocumentSettings(
          widget.documentName,
          textEnhanceMode: true,
          positionLocked: true,
        );
      }
    } catch (e) {
      print('加载背景设置和增强模式时出错: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _pickBackgroundImage() async {
    try {
      final imagePath = await ImagePickerService.pickImage(context);
      if (imagePath != null) {
        // 获取应用私有目录
        final appDir = await getApplicationDocumentsDirectory();
        final backgroundDir = Directory('${appDir.path}/backgrounds');
        if (!await backgroundDir.exists()) {
          await backgroundDir.create(recursive: true);
        }

        String finalImagePath;
        
        // 检查是否是媒体库中的图片（已经在应用目录中）
        if (imagePath.contains(appDir.path)) {
          // 媒体库图片，直接使用原路径
          finalImagePath = imagePath;
        } else {
          // 相机或相册图片，需要复制到backgrounds目录
          final uuid = const Uuid().v4();
          final extension = path.extension(imagePath);
          final fileName = '$uuid$extension';
          final destinationPath = '${backgroundDir.path}/$fileName';
          
          // 复制文件到应用私有目录
          await File(imagePath).copy(destinationPath);
          finalImagePath = destinationPath;
        }

        // 删除旧的背景图片文件
        if (_backgroundImage != null && _backgroundImage!.path != finalImagePath) {
          try {
            await _backgroundImage!.delete();
          } catch (e) {
            print('删除旧背景图片时出错: $e');
          }
        }

        // 直接设置背景图片并保存到数据库
        setState(() {
          _backgroundImage = File(finalImagePath);
          _contentChanged = true;
        });
        
        await _databaseService.insertOrUpdateDocumentSettings(
          widget.documentName,
          imagePath: finalImagePath,
          colorValue: _backgroundColor?.value,
        );
        _saveStateToHistory();
      }
    } catch (e) {
      print('选择背景图片时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择背景图片时出错，请重试。')),
      );
    }
  }

  Future<void> _removeBackgroundImage() async {
    // 删除背景图片文件
    if (_backgroundImage != null) {
      try {
        await _backgroundImage!.delete();
      } catch (e) {
        print('删除背景图片文件时出错: $e');
      }
    }

    setState(() {
      _backgroundImage = null;
      _contentChanged = true;
    });
    try {
      // Ensure the method name and signature match the DatabaseService definition
      await _databaseService.deleteDocumentBackgroundImage(widget.documentName);

      await _databaseService.insertOrUpdateDocumentSettings(
        widget.documentName,
        colorValue: _backgroundColor?.value,
      );

      _saveStateToHistory();
    } catch (e) {
      print('移除背景图片时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('移除背景图片时出错，请重试。')),
      );
    }
  }

  Future<void> _pickBackgroundColor() async {
    // 保存原始颜色，用于取消时恢复
    final originalColor = _backgroundColor;
    
    Color? pickedColor = await showDialog<Color>(
      context: context,
      builder: (context) {
        Color tempColor = _backgroundColor ?? Colors.white;
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

    if (pickedColor != null) {
      setState(() {
        _backgroundColor = pickedColor;
        _contentChanged = true;
      });
      try {
        await _databaseService.insertOrUpdateDocumentSettings(
          widget.documentName,
          imagePath: _backgroundImage?.path,
          colorValue: pickedColor.value,
        );
        _saveStateToHistory();
      } catch (e) {
        print('设置背景颜色时出错: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置背景颜色时出错，请重试。')),
        );
      }
    } else {
      // 如果用户没有确定选择，确保颜色已恢复到原始状态
      setState(() {
        _backgroundColor = originalColor;
      });
    }
  }

  Future<bool> _showDeleteConfirmationDialog() async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('确认删除'),
          content: Text('您确定要删除这个项目吗？'),
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

  Future<void> _loadContent() async {
    print('🔍 开始加载文档内容: ${widget.documentName}');
    try {
      print('📄 正在从数据库获取文本框数据...');
      List<Map<String, dynamic>> textBoxes =
      await _databaseService.getTextBoxesByDocument(widget.documentName);
      print('✅ 成功获取 ${textBoxes.length} 个文本框');

      for (var textBox in textBoxes) {
        print('🔧 处理文本框数据: ${textBox.keys.toList()}');
        if (!textBox.containsKey('positionX') && textBox.containsKey('left')) {
          textBox['positionX'] = textBox['left'];
        }
        if (!textBox.containsKey('positionY') && textBox.containsKey('top')) {
          textBox['positionY'] = textBox['top'];
        }
        if (!textBox.containsKey('positionX')) {
          textBox['positionX'] = 0.0;
        }
        if (!textBox.containsKey('positionY')) {
          textBox['positionY'] = 0.0;
        }
      }

      print('🖼️ 正在从数据库获取图片框数据...');
      List<Map<String, dynamic>> imageBoxes =
      await _databaseService.getImageBoxesByDocument(widget.documentName);
      print('✅ 成功获取 ${imageBoxes.length} 个图片框');

      for (var imageBox in imageBoxes) {
        print('🔧 处理图片框数据: ${imageBox.keys.toList()}');
        if (!imageBox.containsKey('positionX') && imageBox.containsKey('left')) {
          imageBox['positionX'] = imageBox['left'];
        }
        if (!imageBox.containsKey('positionY') && imageBox.containsKey('top')) {
          imageBox['positionY'] = imageBox['top'];
        }
        if (!imageBox.containsKey('positionX')) {
          imageBox['positionX'] = 0.0;
        }
        if (!imageBox.containsKey('positionY')) {
          imageBox['positionY'] = 0.0;
        }
      }

      print('🎵 正在从数据库获取音频框数据...');
      List<Map<String, dynamic>> audioBoxes =
      await _databaseService.getAudioBoxesByDocument(widget.documentName);
      print('✅ 成功获取 ${audioBoxes.length} 个音频框');

  // 新增：加载画布
  print('🖼️🔁 正在从数据库获取画布数据...');
  final canvasRows = await _databaseService.getCanvasesByDocument(widget.documentName);
  print('✅ 成功获取 ${canvasRows.length} 个画布');
  List<FlippableCanvas> canvases = canvasRows.map((row) => FlippableCanvas.fromMap(row)).toList();

      print('⚙️ 正在获取文档设置...');
      Map<String, dynamic>? docSettings =
      await _databaseService.getDocumentSettings(widget.documentName);
      print('✅ 文档设置: ${docSettings?.keys.toList() ?? "无设置"}');
      // 注意：textEnhanceMode已经在_loadBackgroundSettingsAndEnhanceMode中加载，这里不再重复加载
      print('📝 当前文本增强模式: $_textEnhanceMode');

      print('🔄 正在更新UI状态...');
      setState(() {
        _textBoxes = textBoxes;
        _imageBoxes = imageBoxes;
        _audioBoxes = audioBoxes;
        _canvases = canvases; // 新增：设置画布
        _deletedTextBoxIds.clear();
        _deletedImageBoxIds.clear();
        _deletedAudioBoxIds.clear();
        // 保持现有的_textEnhanceMode值，不覆盖
        _isLoading = false;
      });
      print('✅ UI状态更新完成');

      print('🔄 正在添加历史记录...');
      try {
        // 安全地复制数据，处理null值
        List<Map<String, dynamic>> safeTextBoxes = _textBoxes.map((map) {
          Map<String, dynamic> safeMap = {};
          map.forEach((key, value) {
            safeMap[key] = value; // 允许value为null
                    });
          return safeMap;
        }).toList();
        
        List<Map<String, dynamic>> safeImageBoxes = _imageBoxes.map((map) {
          Map<String, dynamic> safeMap = {};
          map.forEach((key, value) {
            safeMap[key] = value; // 允许value为null
                    });
          return safeMap;
        }).toList();
        
        List<Map<String, dynamic>> safeAudioBoxes = _audioBoxes.map((map) {
          Map<String, dynamic> safeMap = {};
          map.forEach((key, value) {
            safeMap[key] = value; // 允许value为null
                    });
          return safeMap;
        }).toList();
        
        print('📊 安全数据统计: 文本框${safeTextBoxes.length}个, 图片框${safeImageBoxes.length}个, 音频框${safeAudioBoxes.length}个');
        
        _history.add({
          'textBoxes': safeTextBoxes,
          'imageBoxes': safeImageBoxes,
          'audioBoxes': safeAudioBoxes,
          'canvases': canvases.map((c) => c.toMap()).toList(),
          'deletedTextBoxIds': List<String>.from(_deletedTextBoxIds.where((id) => id != null)),
          'deletedImageBoxIds': List<String>.from(_deletedImageBoxIds.where((id) => id != null)),
          'deletedAudioBoxIds': List<String>.from(_deletedAudioBoxIds.where((id) => id != null)),
          'deletedCanvasIds': List<String>.from(_deletedCanvasIds.where((id) => id != null)),
          'backgroundImage': _backgroundImage?.path,
          'backgroundColor': _backgroundColor?.value,
          'textEnhanceMode': _textEnhanceMode,
        });
        print('✅ 历史记录添加成功');
      } catch (e, stackTrace) {
        print('❌ 添加历史记录时发生错误: $e');
        print('📍 错误堆栈: $stackTrace');
        // 即使历史记录添加失败，也不影响文档加载
      }
      _historyIndex = 0;
    } catch (e, stackTrace) {
      print('❌ 加载文档内容时发生错误!');
      print('📄 文档名称: ${widget.documentName}');
      print('🚨 错误类型: ${e.runtimeType}');
      print('💥 错误详情: $e');
      print('📍 堆栈跟踪: $stackTrace');
      
      // 检查是否是类型转换错误
      if (e.toString().contains('type') && e.toString().contains('null')) {
        print('⚠️ 检测到空值类型转换错误，可能是数据库返回了null值');
      }
      
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载内容时出错: ${e.toString()}')),
      );
    }
  }

  // 防抖保存方法，避免频繁保存
  void _debouncedSave() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(Duration(milliseconds: 2000), () {
      if (_contentChanged && !_isSaving) {
        _saveContent();
      }
    });
  }

  Future<void> _saveContent() async {
    // 防重入机制：如果正在保存，则跳过本次保存
    if (_isSaving) {
      print('保存操作正在进行中，跳过本次保存请求');
      return;
    }
    
    _isSaving = true;
    try {
      print('正在保存文档内容...');
      await _databaseService.saveTextBoxes(List<Map<String, dynamic>>.from(_textBoxes), widget.documentName);
      await _databaseService.saveImageBoxes(List<Map<String, dynamic>>.from(_imageBoxes), widget.documentName);
      await _databaseService.saveAudioBoxes(List<Map<String, dynamic>>.from(_audioBoxes), widget.documentName);
      await _databaseService.saveCanvases(
        _canvases.map((c) => c.toMap()).toList(),
        _deletedCanvasIds,
        widget.documentName,
      );
      // 新增：保存画布
      await _databaseService.saveCanvases(
        _canvases.map((c) => c.toMap()).toList(),
        _deletedCanvasIds,
        widget.documentName,
      );
      if (mounted) {
        setState(() {
          _contentChanged = false;
        });
      } else {
        _contentChanged = false;
      }
      widget.onSave(List<Map<String, dynamic>>.from(_textBoxes));
      try {
        await _databaseService.backupDatabase();
      } catch (e) {
        print('保存内容时数据库备份出错: $e');
      }
      print('文档内容已保存');
    } catch (e) {
      print('保存内容时出错: $e');
      print('堆栈跟踪: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('保存失败: ${e.toString()}'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } finally {
      _isSaving = false; // 确保保存状态被重置
    }
  }

  void _addNewTextBox() {
    Future.microtask(() {
      setState(() {
        var uuid = Uuid();
        double positionX = 0.0;
        double positionY = 0.0;
        if (_textBoxes.isNotEmpty) {
          List<Map<String, dynamic>> textBoxesCopy = List.from(_textBoxes);
          Map<String, dynamic> bottomMostTextBox = textBoxesCopy.reduce((curr, next) {
            return (curr['positionY'] + curr['height'] > next['positionY'] + next['height']) ? curr : next;
          });
          double spacing = 2.5 * 3.779527559;
          positionY = bottomMostTextBox['positionY'] + bottomMostTextBox['height'] + spacing;
        }
        
        String textBoxId = uuid.v4();
        Map<String, dynamic> newTextBox = {
          'id': textBoxId,
          'documentName': widget.documentName,
          'positionX': positionX,
          'positionY': positionY,
          'width': 200.0,
          'height': 100.0,
          'text': '',
          'fontSize': 16.0,
          'fontColor': Colors.black.value,
        };
        
        if (_databaseService.validateTextBoxData(newTextBox)) {
          _textBoxes.add(newTextBox);
          
          // 新增：检查是否有画布包含这个位置，如果有则将文本框关联到画布
          _associateContentWithCanvas(textBoxId, positionX, positionY, 'text');
          
          _contentChanged = true;
          Future.microtask(() {
            _debouncedSave();
          });
          Future.microtask(() => _saveStateToHistory());
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文本框数据无效，无法添加。')),
          );
        }
      });
    });
  }

  void _addNewImageBox() async {
    var uuid = Uuid();
    double screenWidth = MediaQuery.of(context).size.width;
    double screenHeight = MediaQuery.of(context).size.height;
    double scrollOffset = _scrollController.offset;
    double positionX = screenWidth / 2 - 100;
    double positionY = scrollOffset + screenHeight / 2 - 50;
    
    String imageBoxId = uuid.v4();
    Map<String, dynamic> imageBox = {
      'id': imageBoxId,
      'documentName': widget.documentName,
      'positionX': positionX,
      'positionY': positionY,
      'width': 200.0,
      'height': 200.0,
      'imagePath': '',
    };
    setState(() {
      _imageBoxes.add(imageBox);
      
      // 新增：检查是否有画布包含这个位置
      _associateContentWithCanvas(imageBoxId, positionX, positionY, 'image');
      
      _contentChanged = true;
      _saveStateToHistory();
    });
    await _selectImageForBox(imageBox['id']);
  }

  Future<void> _selectImageForBox(String id) async {
    try {
      final imagePath = await ImagePickerService.pickImage(context);
      if (imagePath != null) {
        setState(() {
          int index = _imageBoxes.indexWhere((box) => box['id'] == id);
          if (index != -1) {
            _imageBoxes[index]['imagePath'] = imagePath;
            _debouncedSave();
            _saveStateToHistory();
          }
        });
      } else {
        setState(() {
          _imageBoxes.removeWhere((imageBox) => imageBox['id'] == id);
        });
        _debouncedSave();
        _saveStateToHistory();
      }
    } catch (e) {
      print('选择图片时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择图片时出错，请重试。')),
      );
    }
  }

  void _duplicateTextBox(String id) {
    Future.microtask(() {
      setState(() {
        int index = _textBoxes.indexWhere((textBox) => textBox['id'] == id);
        if (index != -1) {
          var uuid = Uuid();
          Map<String, dynamic> original = _textBoxes[index];
          // 复制的文本框出现在原文本框的正下方
          double positionX = 0.0; // 水平位置：文档最左边
          double positionY = original['positionY'] + original['height'] + 9.45; // 垂直位置：原文本框下方加9.45像素间距
          Map<String, dynamic> newTextBox = {
            'id': uuid.v4(),
            'documentName': widget.documentName,
            'positionX': positionX,
            'positionY': positionY,
            'width': original['width'],
            'height': original['height'],
            'text': original['text'],
            'fontSize': original['fontSize'],
            'fontColor': original['fontColor'],
            'fontWeight': original['fontWeight'],
            'isItalic': original['isItalic'],
            'backgroundColor': original['backgroundColor'],
            'textAlign': original['textAlign'],
          };
          if (_databaseService.validateTextBoxData(newTextBox)) {
            _textBoxes.add(newTextBox);
            Future.microtask(() {
              _debouncedSave();
            });
            Future.microtask(() => _saveStateToHistory());
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('文本框数据无效，无法复制。')),
            );
          }
        }
      });
    });
  }

  void _duplicateImageBox(String id) {
    Future.microtask(() {
      setState(() {
        int index = _imageBoxes.indexWhere((imageBox) => imageBox['id'] == id);
        if (index != -1) {
          var uuid = Uuid();
          Map<String, dynamic> original = _imageBoxes[index];
          // 获取 document_id
          final documentId = original['document_id'] ?? original['documentId'];
          // 复制时必须保证 imagePath 有效
          if (original['imagePath'] == null || original['imagePath'].toString().isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('图片框无图片，无法复制。')),
            );
            return;
          }
          Map<String, dynamic> newImageBox = {
            'id': uuid.v4(),
            'document_id': documentId,
            'documentName': widget.documentName,
            'position_x': (original['positionX'] ?? 0.0) + 20,
            'position_y': (original['positionY'] ?? 0.0) + 20,
            'positionX': (original['positionX'] ?? 0.0) + 20,
            'positionY': (original['positionY'] ?? 0.0) + 20,
            'width': original['width'],
            'height': original['height'],
            'image_path': original['imagePath'],
            'imagePath': original['imagePath'],
          };
          if (_databaseService.validateImageBoxData(newImageBox)) {
            _imageBoxes.add(newImageBox);
            Future.microtask(() {
              _debouncedSave();
            });
            Future.microtask(() => _saveStateToHistory());
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('图片框数据无效，无法复制。')),
            );
          }
        }
      });
    });
  }

  void _updateTextBoxPosition(String id, Offset position) {
    setState(() {
      int index = _textBoxes.indexWhere((textBox) => textBox['id'] == id);
      if (index != -1) {
        _textBoxes[index]['positionX'] = position.dx;
        _textBoxes[index]['positionY'] = position.dy;
        _contentChanged = true;
      }
    });
  }

  void _updateTextBox(
      String id, Size size, String text, CustomTextStyle textStyle) {
    print(
        '更新文本框：id=$id, 样式：粗体=${textStyle.fontWeight}, 斜体=${textStyle.isItalic}');

    setState(() {
      int index = _textBoxes.indexWhere((textBox) => textBox['id'] == id);
      if (index != -1) {
        _textBoxes[index]['width'] = size.width;
        _textBoxes[index]['height'] = size.height;
        _textBoxes[index]['text'] = text;
        _textBoxes[index]['fontSize'] = textStyle.fontSize;
        _textBoxes[index]['fontColor'] = textStyle.fontColor.value;
        _textBoxes[index]['fontWeight'] = textStyle.fontWeight.index;
        _textBoxes[index]['isItalic'] = textStyle.isItalic ? 1 : 0;
        _textBoxes[index]['backgroundColor'] = textStyle.backgroundColor?.value;
        _textBoxes[index]['textAlign'] = textStyle.textAlign.index;

        _contentChanged = true;

        print(
            '文本框数据更新成功: fontWeight=${_textBoxes[index]['fontWeight']}, isItalic=${_textBoxes[index]['isItalic']}');
      }
    });
  }

  void _deleteTextBox(String id) {
    setState(() {
      _textBoxes.removeWhere((textBox) => textBox['id'] == id);
      _deletedTextBoxIds.add(id);
      _contentChanged = true;
    });
  }

  void _updateImageBoxPosition(String id, Offset position) {
    setState(() {
      int index = _imageBoxes.indexWhere((imageBox) => imageBox['id'] == id);
      if (index != -1) {
        _imageBoxes[index]['positionX'] = position.dx;
        _imageBoxes[index]['positionY'] = position.dy;
        _contentChanged = true;
      }
    });
  }

  void _updateImageBox(String id, Size size) {
    setState(() {
      int index = _imageBoxes.indexWhere((imageBox) => imageBox['id'] == id);
      if (index != -1) {
        _imageBoxes[index]['width'] = size.width;
        _imageBoxes[index]['height'] = size.height;
        _contentChanged = true;
      }
    });
  }

  void _deleteImageBox(String id) {
    setState(() {
      _imageBoxes.removeWhere((imageBox) => imageBox['id'] == id);
      _deletedImageBoxIds.add(id);
      _contentChanged = true;
    });
  }

  void _addNewAudioBox() {
    setState(() {
      var uuid = Uuid();
      double screenWidth = MediaQuery.of(context).size.width;
      double screenHeight = MediaQuery.of(context).size.height;
      double scrollOffset = _scrollController.offset;
      double positionX = screenWidth / 2 - 28;
      double positionY = scrollOffset + screenHeight / 2 - 28;
      
      String audioBoxId = uuid.v4();
      Map<String, dynamic> newAudioBox = {
        'id': audioBoxId,
        'documentName': widget.documentName,
        'positionX': positionX,
        'positionY': positionY,
        'audioPath': '',
      };

      _audioBoxes.add(newAudioBox);
      
      // 新增：检查是否有画布包含这个位置
      _associateContentWithCanvas(audioBoxId, positionX, positionY, 'audio');
      
      _contentChanged = true;
      _debouncedSave();
      _saveStateToHistory();
    });
  }

  // 新增：添加新画布
  void _addNewCanvas() {
    setState(() {
      var uuid = Uuid();
      double screenWidth = MediaQuery.of(context).size.width;
      double screenHeight = MediaQuery.of(context).size.height;
      double scrollOffset = _scrollController.offset;
      
      FlippableCanvas newCanvas = FlippableCanvas(
        id: uuid.v4(),
        documentName: widget.documentName,
        positionX: screenWidth / 2 - 150, // 画布默认宽度300，居中显示
        positionY: scrollOffset + screenHeight / 2 - 100, // 画布默认高度200，居中显示
        width: 300.0,
        height: 200.0,
        isFlipped: false,
      );

      _canvases.add(newCanvas);
      _contentChanged = true;
      _debouncedSave();
      _saveStateToHistory();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('画布已创建！双击画布可翻转，长按可查看设置'),
          duration: Duration(seconds: 3),
        ),
      );
    });
  }

  void _updateAudioBoxPosition(String id, Offset position) {
    int index = _audioBoxes.indexWhere((audioBox) => audioBox['id'] == id);
    if (index != -1) {
      setState(() {
        _audioBoxes[index]['positionX'] = position.dx;
        _audioBoxes[index]['positionY'] = position.dy;
        _contentChanged = true;
      });
    }
  }

  void _showAudioBoxOptions(String id) {
    int index = _audioBoxes.indexWhere((audioBox) => audioBox['id'] == id);
    if (index == -1) return;

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.mic),
              title: Text('录制新语音'),
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  _recordingAudioBoxId = id;
                });
                _startRecordingForBox(id);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('开始录音...长按停止录音')),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete),
              title: Text('删除语音框'),
              onTap: () async {
                Navigator.pop(context);
                bool shouldDelete = await _showDeleteConfirmationDialog();
                if (shouldDelete) {
                  setState(() {
                    _deletedAudioBoxIds.add(_audioBoxes[index]['id']);
                    _audioBoxes.removeAt(index);
                    _contentChanged = true;
                  });
                  _debouncedSave();
                  _saveStateToHistory();
                }
              },
            ),
          ],
        );
      },
    );
  }

  void _startRecordingForBox(String id) {
    setState(() {
      _handleAudioRecordingState(id, true);
    });
  }

  void _handleAudioRecordingState(String id, bool isRecording) {
    if (isRecording) {
      setState(() {
        _recordingAudioBoxId = id;
      });
    } else {
      setState(() {
        if (_recordingAudioBoxId == id) {
          int index =
          _audioBoxes.indexWhere((audioBox) => audioBox['id'] == id);
          if (index != -1) {
            _contentChanged = true;
          }

          _recordingAudioBoxId = null;

          _debouncedSave();
          _saveStateToHistory();
        }
      });
    }
  }

  // 新增：更新画布
  void _updateCanvas(FlippableCanvas canvas) {
    setState(() {
      int index = _canvases.indexWhere((c) => c.id == canvas.id);
      if (index != -1) {
        _canvases[index] = canvas;
        _contentChanged = true;
      }
    });
  }

  // 新增：检查内容是否与画布重叠并关联
  void _associateContentWithCanvas(String contentId, double x, double y, String contentType) {
    for (var canvas in _canvases) {
      // 检查内容是否在画布范围内
      if (x >= canvas.positionX && 
          x <= canvas.positionX + canvas.width &&
          y >= canvas.positionY && 
          y <= canvas.positionY + canvas.height) {
        
        // 将内容关联到画布的当前面
        switch (contentType) {
          case 'text':
            canvas.addTextBoxToCurrentSide(contentId);
            break;
          case 'image':
            canvas.addImageBoxToCurrentSide(contentId);
            break;
          case 'audio':
            canvas.addAudioBoxToCurrentSide(contentId);
            break;
        }
        
        print('内容 $contentId 已关联到画布 ${canvas.id} 的${canvas.isFlipped ? "反面" : "正面"}');
        break; // 只关联到第一个匹配的画布
      }
    }
  }

  // 拖动结束后重新判断内容是否应归属某个画布（支持把现有内容拖入/拖出画布）
  void _reassociateContentWithCanvas(String contentId, String contentType) {
    // 先从所有画布移除该内容（保持前后面列表一致性）
    for (var canvas in _canvases) {
      canvas.frontTextBoxIds.remove(contentId);
      canvas.backTextBoxIds.remove(contentId);
      canvas.frontImageBoxIds.remove(contentId);
      canvas.backImageBoxIds.remove(contentId);
      canvas.frontAudioBoxIds.remove(contentId);
      canvas.backAudioBoxIds.remove(contentId);
    }

    // 获取当前内容位置与尺寸
    double x = 0, y = 0, w = 0, h = 0;
    switch (contentType) {
      case 'text':
        final box = _textBoxes.firstWhere((e) => e['id'] == contentId, orElse: () => {});
        if (box.isEmpty) return; 
        x = (box['positionX'] ?? 0).toDouble();
        y = (box['positionY'] ?? 0).toDouble();
        w = (box['width'] ?? 0).toDouble();
        h = (box['height'] ?? 0).toDouble();
        break;
      case 'image':
        final box = _imageBoxes.firstWhere((e) => e['id'] == contentId, orElse: () => {});
        if (box.isEmpty) return;
        x = (box['positionX'] ?? 0).toDouble();
        y = (box['positionY'] ?? 0).toDouble();
        w = (box['width'] ?? 0).toDouble();
        h = (box['height'] ?? 0).toDouble();
        break;
      case 'audio':
        final box = _audioBoxes.firstWhere((e) => e['id'] == contentId, orElse: () => {});
        if (box.isEmpty) return;
        x = (box['positionX'] ?? 0).toDouble();
        y = (box['positionY'] ?? 0).toDouble();
        w = 56.0; // 音频按钮假定宽高
        h = 56.0;
        break;
    }

    // 判定与画布框是否重叠（面积 > 0 即认为粘连）
    for (var canvas in _canvases) {
      bool overlap = !(x + w < canvas.positionX ||
                       x > canvas.positionX + canvas.width ||
                       y + h < canvas.positionY ||
                       y > canvas.positionY + canvas.height);
      if (overlap) {
        switch (contentType) {
          case 'text':
            canvas.addTextBoxToCurrentSide(contentId);
            break;
          case 'image':
            canvas.addImageBoxToCurrentSide(contentId);
            break;
          case 'audio':
            canvas.addAudioBoxToCurrentSide(contentId);
            break;
        }
        break; // 绑定到第一个重叠的画布
      }
    }
  }

  // 新增：检查内容是否应该显示（基于画布状态）
  bool _shouldShowContent(String contentId, String contentType) {
    for (var canvas in _canvases) {
      bool containsContent = false;
      bool isOnCurrentSide = false;
      
      switch (contentType) {
        case 'text':
          containsContent = canvas.containsTextBox(contentId);
          isOnCurrentSide = canvas.getCurrentTextBoxIds().contains(contentId);
          break;
        case 'image':
          containsContent = canvas.containsImageBox(contentId);
          isOnCurrentSide = canvas.getCurrentImageBoxIds().contains(contentId);
          break;
        case 'audio':
          containsContent = canvas.containsAudioBox(contentId);
          isOnCurrentSide = canvas.getCurrentAudioBoxIds().contains(contentId);
          break;
      }
      
      if (containsContent) {
        // 如果内容属于某个画布，只有在当前面时才显示
        return isOnCurrentSide;
      }
    }
    
    // 如果内容不属于任何画布，始终显示
    return true;
  }
  
  Future<void> _deleteCanvas(String canvasId) async {
    // 显示确认对话框
    bool shouldDelete = await _showDeleteConfirmationDialog();
    if (!shouldDelete) return;

    setState(() {
      // 找到要删除的画布
      FlippableCanvas? canvasToDelete;
      for (var canvas in _canvases) {
        if (canvas.id == canvasId) {
          canvasToDelete = canvas;
          break;
        }
      }

      if (canvasToDelete != null) {
        // 从画布的所有面移除关联的内容
        List<String> allTextBoxIds = [
          ...canvasToDelete.frontTextBoxIds,
          ...canvasToDelete.backTextBoxIds,
        ];
        List<String> allImageBoxIds = [
          ...canvasToDelete.frontImageBoxIds,
          ...canvasToDelete.backImageBoxIds,
        ];
        List<String> allAudioBoxIds = [
          ...canvasToDelete.frontAudioBoxIds,
          ...canvasToDelete.backAudioBoxIds,
        ];

        // 将关联的内容也删除（可选，也可以选择保留内容）
        _textBoxes.removeWhere((box) => allTextBoxIds.contains(box['id']));
        _imageBoxes.removeWhere((box) => allImageBoxIds.contains(box['id']));
        _audioBoxes.removeWhere((box) => allAudioBoxIds.contains(box['id']));

        // 添加到删除列表
        _deletedTextBoxIds.addAll(allTextBoxIds);
        _deletedImageBoxIds.addAll(allImageBoxIds);
        _deletedAudioBoxIds.addAll(allAudioBoxIds);

        // 删除画布
        _canvases.removeWhere((canvas) => canvas.id == canvasId);
        _deletedCanvasIds.add(canvasId);
        
        _contentChanged = true;
      }
    });

    _debouncedSave();
    _saveStateToHistory();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('画布及其内容已删除')),
    );
  }

  void _saveStateToHistory() {
    if (_historyIndex < _history.length - 1) {
      _history = _history.sublist(0, _historyIndex + 1);
    }
    
    try {
      // 安全地复制数据，处理null值
      List<Map<String, dynamic>> safeTextBoxes = _textBoxes.map((map) {
        Map<String, dynamic> safeMap = {};
        map.forEach((key, value) {
          safeMap[key] = value;
                });
        return safeMap;
      }).toList();
      
      List<Map<String, dynamic>> safeImageBoxes = _imageBoxes.map((map) {
        Map<String, dynamic> safeMap = {};
        map.forEach((key, value) {
          safeMap[key] = value;
                });
        return safeMap;
      }).toList();
      
      List<Map<String, dynamic>> safeAudioBoxes = _audioBoxes.map((map) {
        Map<String, dynamic> safeMap = {};
        map.forEach((key, value) {
          safeMap[key] = value;
                });
        return safeMap;
      }).toList();

      // 新增：安全地复制画布数据
      List<Map<String, dynamic>> safeCanvases = _canvases.map((canvas) {
        return canvas.toMap();
      }).toList();
      
      _history.add({
        'textBoxes': safeTextBoxes,
        'imageBoxes': safeImageBoxes,
        'audioBoxes': safeAudioBoxes,
        'canvases': safeCanvases, // 新增：画布数据
        'deletedTextBoxIds': List<String>.from(_deletedTextBoxIds.where((id) => id != null)),
        'deletedImageBoxIds': List<String>.from(_deletedImageBoxIds.where((id) => id != null)),
        'deletedAudioBoxIds': List<String>.from(_deletedAudioBoxIds.where((id) => id != null)),
        'deletedCanvasIds': List<String>.from(_deletedCanvasIds.where((id) => id != null)), // 新增：已删除画布ID
        'backgroundImage': _backgroundImage?.path,
        'backgroundColor': _backgroundColor?.value,
        'textEnhanceMode': _textEnhanceMode,
      });
    } catch (e) {
      print('❌ 保存历史状态时发生错误: $e');
      // 创建一个空的历史状态作为备用
      _history.add({
        'textBoxes': <Map<String, dynamic>>[],
        'imageBoxes': <Map<String, dynamic>>[],
        'audioBoxes': <Map<String, dynamic>>[],
        'canvases': <Map<String, dynamic>>[], // 新增：空画布列表
        'deletedTextBoxIds': <String>[],
        'deletedImageBoxIds': <String>[],
        'deletedAudioBoxIds': <String>[],
        'deletedCanvasIds': <String>[], // 新增：空删除画布列表
        'backgroundImage': null,
        'backgroundColor': null,
        'textEnhanceMode': false,
      });
    }
    _historyIndex = _history.length - 1;

    if (_history.length > 20) {
      _history.removeAt(0);
      _historyIndex--;
    }
  }

  void _loadStateFromHistory() {
    final historyState = _history[_historyIndex];
    _textBoxes = historyState['textBoxes']
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
        .toList();
    _imageBoxes = historyState['imageBoxes']
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
        .toList();
    _audioBoxes = historyState['audioBoxes'] != null
        ? historyState['audioBoxes']
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
        .toList()
        : [];
    
    // 新增：从历史记录加载画布数据
    _canvases = historyState['canvases'] != null
        ? historyState['canvases']
        .map<FlippableCanvas>((e) => FlippableCanvas.fromMap(Map<String, dynamic>.from(e)))
        .toList()
        : [];
    
    _deletedTextBoxIds = List<String>.from(historyState['deletedTextBoxIds']);
    _deletedImageBoxIds = List<String>.from(historyState['deletedImageBoxIds']);
    _deletedAudioBoxIds = historyState['deletedAudioBoxIds'] != null
        ? List<String>.from(historyState['deletedAudioBoxIds'])
        : [];
    
    // 新增：从历史记录加载已删除画布ID
    _deletedCanvasIds = historyState['deletedCanvasIds'] != null
        ? List<String>.from(historyState['deletedCanvasIds'])
        : [];

    if (historyState['backgroundImage'] != null) {
      _backgroundImage = File(historyState['backgroundImage']);
    } else {
      _backgroundImage = null;
    }

    if (historyState['backgroundColor'] != null) {
      _backgroundColor = Color(historyState['backgroundColor']);
    } else {
      _backgroundColor = null;
    }

    _textEnhanceMode = historyState['textEnhanceMode'] ?? false;
  }

  @override
  void dispose() {
    // 页面销毁前强制保存增强模式状态
    _databaseService.insertOrUpdateDocumentSettings(
      widget.documentName,
      imagePath: _backgroundImage?.path,
      colorValue: _backgroundColor?.value,
      textEnhanceMode: _textEnhanceMode,
      positionLocked: _isPositionLocked,
    );
    if (_contentChanged) {
      print('页面销毁前保存文档内容...');
      _saveContentOnDispose();
    }
    _autoSaveTimer?.cancel();
    _debounceTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // 页面销毁时的保存方法，不调用setState和UI相关方法
  Future<void> _saveContentOnDispose() async {
    // 防重入机制：如果正在保存，则等待当前保存完成
    if (_isSaving) {
      print('等待当前保存操作完成...');
      // 等待最多3秒，避免无限等待
      int waitCount = 0;
      while (_isSaving && waitCount < 30) {
        await Future.delayed(Duration(milliseconds: 100));
        waitCount++;
      }
      if (_isSaving) {
        print('等待保存超时，强制执行保存');
      } else {
        print('当前保存操作已完成，无需重复保存');
        return;
      }
    }
    
    _isSaving = true;
    try {
      print('正在保存文档内容...');
      await _databaseService.saveTextBoxes(List<Map<String, dynamic>>.from(_textBoxes), widget.documentName);
      await _databaseService.saveImageBoxes(List<Map<String, dynamic>>.from(_imageBoxes), widget.documentName);
      await _databaseService.saveAudioBoxes(List<Map<String, dynamic>>.from(_audioBoxes), widget.documentName);
      // 不调用setState，因为页面已经销毁
      _contentChanged = false;
      widget.onSave(List<Map<String, dynamic>>.from(_textBoxes));
      try {
        await _databaseService.backupDatabase();
      } catch (e) {
        print('保存内容时数据库备份出错: $e');
      }
      print('文档内容已保存');
    } catch (e) {
      print('保存内容时出错: $e');
      print('堆栈跟踪: $e');
      // 不显示SnackBar，因为页面已经销毁
    } finally {
      _isSaving = false;
    }
  }

  void _showSettingsMenu() {
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
              leading: Icon(Icons.format_color_fill),
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
            ListTile(
              leading: Icon(_isTemplate ? Icons.star : Icons.star_border),
              title: Text(_isTemplate ? '取消设为模板' : '设为模板'),
              onTap: () {
                Navigator.pop(context);
                _toggleTemplateStatus();
              },
            ),
            ListTile(
              leading: Icon(Icons.folder_open),
              title: Text('选择媒体来源'),
              onTap: () {
                Navigator.pop(context);
                _mediaPlayerKey.currentState?.selectMediaSource();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  // ...
  // 计算所有内容框中最下方的位置
  double _calculateBottomMostPosition() {
    double maxBottom = 0.0;
    
    // 检查所有文本框
    for (var textBox in _textBoxes) {
      double bottom = (textBox['positionY'] as double) + (textBox['height'] as double);
      if (bottom > maxBottom) {
        maxBottom = bottom;
      }
    }
    
    // 检查所有图片框
    for (var imageBox in _imageBoxes) {
      double bottom = (imageBox['positionY'] as double) + (imageBox['height'] as double);
      if (bottom > maxBottom) {
        maxBottom = bottom;
      }
    }
    
    // 检查所有音频框
    for (var audioBox in _audioBoxes) {
      // 音频框假设高度为56.0
      double bottom = (audioBox['positionY'] as double) + 56.0;
      if (bottom > maxBottom) {
        maxBottom = bottom;
      }
    }
    
    // 新增：检查所有画布
    for (var canvas in _canvases) {
      double bottom = canvas.positionY + canvas.height;
      if (bottom > maxBottom) {
        maxBottom = bottom;
      }
    }
    
    return maxBottom;
  }

  @override
  Widget build(BuildContext context) {
    // 计算最下方内容的位置
    double bottomMostPosition = _calculateBottomMostPosition();
    // 设置文档高度为最下方内容位置加上一个屏幕的高度
    double screenHeight = MediaQuery.of(context).size.height;
    double totalHeight = bottomMostPosition + screenHeight;
    
    // 确保总高度至少为屏幕高度的两倍
    totalHeight = totalHeight < screenHeight * 2 ? screenHeight * 2 : totalHeight;
    
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    return WillPopScope(
      onWillPop: () async {
        if (_contentChanged) {
          await _saveContent();
          print('退出页面前保存文档内容...');
        }
        return true;
      },
      child: Scaffold(
        extendBody: true,
        appBar: PreferredSize(
          preferredSize: Size.fromHeight(28.0),
          child: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: Colors.white,
            elevation: 0,
            flexibleSpace: SafeArea(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 8.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back,
                          size: 20, color: Colors.black),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        widget.documentName,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.black,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.save, size: 20, color: Colors.blue),
                          onPressed: () {
                            _saveContent().then((_) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('文档已保存')),
                              );
                            });
                          },
                        ),
                        // 保存状态指示器
                        if (_isSaving)
                          Container(
                            width: 16,
                            height: 16,
                            margin: EdgeInsets.only(right: 8),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                            ),
                          )
                        else if (_contentChanged)
                          Container(
                            width: 8,
                            height: 8,
                            margin: EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: Colors.orange,
                              shape: BoxShape.circle,
                            ),
                          )
                        else
                          Container(
                            width: 8,
                            height: 8,
                            margin: EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),

                    IconButton(
                      icon: Icon(
                        _isPositionLocked ? Icons.lock : Icons.lock_open,
                        size: 20,
                        color: _isPositionLocked ? Colors.blue : Colors.black,
                      ),
                      onPressed: _togglePositionLock,
                      tooltip: _isPositionLocked ? '解锁位置' : '锁定位置',
                    ),
                    IconButton(
                      icon: Icon(Icons.settings,
                          size: 20, color: Colors.black),
                      onPressed: _showSettingsMenu,
                    ),
                    SizedBox(width: 4),
                    Text(
                      '${_scrollPercentage.toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: Stack(
          key: ValueKey('main_stack'),
          children: [
            // 背景图片层（底层）
            if (_backgroundImage != null)
              Container(
                key: ValueKey('background_image_container'),
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: FileImage(_backgroundImage!),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            // 背景颜色层（上层）
            Container(
              key: ValueKey('background_color_container'),
              decoration: BoxDecoration(
                color: _backgroundColor ?? Colors.white,
              ),
            ),
            Positioned.fill(
              child: MediaPlayerContainer(key: _mediaPlayerKey),
            ),
            SingleChildScrollView(
              key: ValueKey('content_scroll_view'),
              controller: _scrollController,
              child: SizedBox(
                height: totalHeight,
                child: Stack(
                  key: ValueKey('content_stack'),
                  children: [
                    // 新增：画布组件（放在最底层，但在背景之上）
                    ..._canvases.map<Widget>((canvas) {
                      return Positioned(
                        key: ValueKey(canvas.id),
                        left: canvas.positionX,
                        top: canvas.positionY,
                        child: FlippableCanvasWidget(
                          canvas: canvas,
                          onCanvasUpdated: _updateCanvas,
                          onSettingsPressed: () => _deleteCanvas(canvas.id),
                          isPositionLocked: _isPositionLocked,
                        ),
                      );
                    }),
                    ...List<Map<String, dynamic>>.from(_imageBoxes).where((data) => _shouldShowContent(data['id'], 'image')).map<Widget>((data) {
                      // Determine whether this image belongs to a canvas
                      FlippableCanvas? ownerCanvas;
                      for (var c in _canvases) {
                        if (c.containsImageBox(data['id'])) {
                          ownerCanvas = c;
                          break;
                        }
                      }
                      // default values
                      double left = data['positionX'];
                      double top = data['positionY'];
                      Widget child = GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanUpdate: (details) {
                          if (_isPositionLocked) return;
                          setState(() {
                            double newDx = data['positionX'] + details.delta.dx;
                            double newDy = data['positionY'] + details.delta.dy;
                            double documentWidth = MediaQuery.of(context).size.width;
                            double documentHeight = totalHeight;
                            newDx = newDx.clamp(0.0, documentWidth - data['width']);
                            newDy = newDy.clamp(0.0, documentHeight - data['height']);
                            data['positionX'] = newDx;
                            data['positionY'] = newDy;
                            _updateImageBoxPosition(data['id'], Offset(newDx, newDy));
                          });
                        },
                          onPanEnd: (_) {
                            _reassociateContentWithCanvas(data['id'], 'image');
                            _contentChanged = true;
                            _debouncedSave();
                            _saveStateToHistory();
                          },
                        child: ResizableImageBox(
                          initialSize: Size(data['width'], data['height']),
                          imagePath: data['imagePath'],
                          onResize: (size) {
                            _updateImageBox(data['id'], size);
                            _debouncedSave();
                            _saveStateToHistory();
                          },
                          onSettingsPressed: () => _showImageBoxOptions(data['id']),
                        ),
                      );

                      // If it belongs to a canvas and that canvas is flipped, compute mirrored transform
                      // 保持内容正常方向（不镜像）

                      return Positioned(
                        key: ValueKey(data['id']),
                        left: left,
                        top: top,
                        child: child,
                      );
                    }),
                    ...List<Map<String, dynamic>>.from(_textBoxes).where((data) => _shouldShowContent(data['id'], 'text')).map<Widget>((data) {
                      FlippableCanvas? ownerCanvas;
                      for (var c in _canvases) {
                        if (c.containsTextBox(data['id'])) {
                          ownerCanvas = c;
                          break;
                        }
                      }

                      double left = data['positionX'];
                      double top = data['positionY'];
                      Widget child = GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanUpdate: (details) {
                          if (_isPositionLocked) return;
                          setState(() {
                            double newDx = data['positionX'] + details.delta.dx;
                            double newDy = data['positionY'] + details.delta.dy;
                            double documentWidth = MediaQuery.of(context).size.width;
                            double documentHeight = totalHeight;
                            newDx = newDx.clamp(0.0, documentWidth - data['width']);
                            newDy = newDy.clamp(0.0, documentHeight - data['height']);
                            data['positionX'] = newDx;
                            data['positionY'] = newDy;
                            _updateTextBoxPosition(data['id'], Offset(newDx, newDy));
                          });
                        },
                          onPanEnd: (_) {
                            _reassociateContentWithCanvas(data['id'], 'text');
                            _contentChanged = true;
                            _debouncedSave();
                            _saveStateToHistory();
                          },
                        child: _buildTextBox(data),
                      );

                      // 保持文本正常方向

                      return Positioned(
                        key: ValueKey(data['id']),
                        left: left,
                        top: top,
                        child: child,
                      );
                    }),
                    ..._audioBoxes.where((data) => _shouldShowContent(data['id'], 'audio')).map<Widget>((data) {
                      FlippableCanvas? ownerCanvas;
                      for (var c in _canvases) {
                        if (c.containsAudioBox(data['id'])) {
                          ownerCanvas = c;
                          break;
                        }
                      }

                      double left = data['positionX'];
                      double top = data['positionY'];
                      Widget child = GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanUpdate: (details) {
                          if (_isPositionLocked) return;
                          setState(() {
                            double newDx = data['positionX'] + details.delta.dx;
                            double newDy = data['positionY'] + details.delta.dy;
                            double documentWidth = MediaQuery.of(context).size.width;
                            double documentHeight = totalHeight;
                            newDx = newDx.clamp(0.0, documentWidth - 37.3);
                            newDy = newDy.clamp(0.0, documentHeight - 37.3);
                            data['positionX'] = newDx;
                            data['positionY'] = newDy;
                            _updateAudioBoxPosition(data['id'], Offset(newDx, newDy));
                          });
                        },
                          onPanEnd: (_) {
                            _reassociateContentWithCanvas(data['id'], 'audio');
                            if (!_isSaving) {
                              _debouncedSave();
                            }
                            _contentChanged = true;
                            _saveStateToHistory();
                          },
                        child: ResizableAudioBox(
                          audioPath: data['audioPath'] ?? '',
                          onIsRecording: (isRecording) => _handleAudioRecordingState(data['id'], isRecording),
                          onSettingsPressed: () => _showAudioBoxOptions(data['id']),
                          onPathUpdated: (path) => _updateAudioPath(data['id'], path),
                          startRecording: _recordingAudioBoxId == data['id'],
                        ),
                      );

                      // 保持音频控件正常方向

                      return Positioned(
                        key: ValueKey(data['id']),
                        left: left,
                        top: top,
                        child: child,
                      );
                    }),
                  ],
                ),
              ),
            ),
            // 视频控制覆盖层 - 显示在最上层
            StreamBuilder<Object?>(
              stream: Stream.periodic(Duration(milliseconds: 200)), // 降低检查频率
              builder: (context, snapshot) {
                final videoWidget = _mediaPlayerKey.currentState?.getCurrentVideoWidget();
                if (videoWidget == null) {
                  return SizedBox.shrink();
                }
                return VideoControlsOverlay(
                  videoPlayerWidget: videoWidget,
                  key: ValueKey('video_controls_${videoWidget.key}'), // 使用稳定的key
                );
              },
            ),
          ],
        ),
        bottomNavigationBar: toolBar.GlobalToolBar(
          onNewTextBox: _addNewTextBox,
          onNewImageBox: _addNewImageBox,
          onNewAudioBox: _addNewAudioBox,
          onNewCanvas: _addNewCanvas, // 新增：新建画布回调
          onUndo: _historyIndex > 0 ? _undo : null,
          onRedo: _historyIndex < _history.length - 1 ? _redo : null,
          onMediaPlay: () => _mediaPlayerKey.currentState?.playCurrentMedia(),
          onMediaStop: () => _mediaPlayerKey.currentState?.stopMedia(),
          onContinuousMediaPlay: () =>
              _mediaPlayerKey.currentState?.playContinuously(),
          onMediaMove: _handleMediaMove,
          onMediaDelete: _handleMediaDelete,
          onMediaFavorite: _handleMediaFavorite,
        ),
      ),
    );
  }

  void _showImageBoxOptions(String id) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.9),
            borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 10,
                offset: Offset(0, -1),
              ),
            ],
          ),
          child: Wrap(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    '图片框设置',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1),
              ListTile(
                leading: Icon(Icons.image, color: Colors.blue),
                title: Text('更换图片'),
                onTap: () {
                  Navigator.pop(context);
                  _selectImageForBox(id);
                },
              ),
              ListTile(
                leading: Icon(Icons.copy, color: Colors.green),
                title: Text('复制图片框'),
                onTap: () {
                  Navigator.pop(context);
                  _duplicateImageBox(id);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete, color: Colors.red),
                title: Text('删除图片框'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteImageBox(id);
                  _debouncedSave();
                  _saveStateToHistory();
                },
              ),
              Container(
                height: 4,
                width: 40,
                margin: EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
                alignment: Alignment.center,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTextBox(Map<String, dynamic> data) {
    final customTextStyle = CustomTextStyle(
      fontSize: (data['fontSize'] as num?)?.toDouble() ?? 16.0,
      fontColor:
      data['fontColor'] != null ? Color(data['fontColor']) : Colors.black,
      fontWeight: data['fontWeight'] != null
          ? FontWeight.values[(data['fontWeight'] as int?) ?? 0]
          : FontWeight.normal,
      isItalic: data['isItalic'] != null
          ? (data['isItalic'] as int?) == 1
          : false,
      backgroundColor: data['backgroundColor'] != null
          ? Color(data['backgroundColor'])
          : null,
      textAlign: data['textAlign'] != null
          ? TextAlign.values[(data['textAlign'] as int?) ?? 0]
          : TextAlign.left,
    );

    return ResizableAndConfigurableTextBox(
      initialSize: Size(
        (data['width'] as num?)?.toDouble() ?? 200.0,
        (data['height'] as num?)?.toDouble() ?? 100.0,
      ),
      initialText: data['text']?.toString() ?? '',
      initialTextStyle: customTextStyle,
      onSave: (size, text, textStyle) {
        Future.microtask(() {
          _updateTextBox(
            data['id'],
            size,
            text,
            textStyle,
          );
          _debouncedSave();
          _saveStateToHistory();
        });
      },
      onDeleteCurrent: () {
        Future.microtask(() {
          _deleteTextBox(data['id']);
          _debouncedSave();
          _saveStateToHistory();
        });
      },
      onDuplicateCurrent: () {
        Future.microtask(() {
          _duplicateTextBox(data['id']);
          _debouncedSave();
          _saveStateToHistory();
        });
      },

    );
  }

  Future<void> _checkIsTemplate() async {
    try {
      final db = await _databaseService.database;
      List<Map<String, dynamic>> result = await db.query(
        'documents',
        columns: ['is_template'], // 修正字段名，使用下划线格式
        where: 'name = ?',
        whereArgs: [widget.documentName],
      );

      if (result.isNotEmpty) {
        setState(() {
          _isTemplate = result.first['is_template'] == 1; // 修正字段名，使用下划线格式
        });
      }
    } catch (e) {
      print('检查模板状态时出错: $e');
    }
  }

  Future<void> _toggleTemplateStatus() async {
    try {
      bool newStatus = !_isTemplate;
      await _databaseService
          .setDocumentAsTemplate(widget.documentName, newStatus);

      setState(() {
        _isTemplate = newStatus;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(newStatus ? '已设置为模板文档' : '已取消模板文档设置')),
      );
    } catch (e) {
      print('设置模板状态时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置模板状态时出错，请重试。')),
      );
    }
  }

  void _toggleTextEnhanceMode() {
    final newMode = !_textEnhanceMode;
    setState(() {
      _textEnhanceMode = newMode;
      _contentChanged = true;
      _debouncedSave();
      _saveStateToHistory();
    });
    _databaseService.insertOrUpdateDocumentSettings(
      widget.documentName,
      imagePath: _backgroundImage?.path,
      colorValue: _backgroundColor?.value,
      textEnhanceMode: newMode,
      positionLocked: _isPositionLocked,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(newMode ? '已开启文字增强模式' : '已关闭文字增强模式'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _togglePositionLock() {
    final newLockState = !_isPositionLocked;
    setState(() {
      _isPositionLocked = newLockState;
      _contentChanged = true;
      _debouncedSave();
      _saveStateToHistory();
    });
    _databaseService.insertOrUpdateDocumentSettings(
      widget.documentName,
      imagePath: _backgroundImage?.path,
      colorValue: _backgroundColor?.value,
      textEnhanceMode: _textEnhanceMode,
      positionLocked: newLockState,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(newLockState ? '已锁定所有元素位置' : '已解锁所有元素位置'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _undo() {
    if (_historyIndex > 0) {
      setState(() {
        _historyIndex--;
        _loadStateFromHistory();
        _contentChanged = true;
      });
    }
  }

  void _redo() {
    if (_historyIndex < _history.length - 1) {
      setState(() {
        _historyIndex++;
        _loadStateFromHistory();
        _contentChanged = true;
      });
    }
  }

  void _updateAudioPath(String id, String path) {
    int index = _audioBoxes.indexWhere((audioBox) => audioBox['id'] == id);
    if (index != -1) {
      setState(() {
        _audioBoxes[index]['audioPath'] = path;
        _contentChanged = true;
      });
      _debouncedSave();
      _saveStateToHistory();
    }
  }

  void _handleMediaMove() {
    _mediaPlayerKey.currentState?.moveCurrentMedia(context);
  }
  
  void _handleMediaDelete() async {
    try {
      final mediaPlayerState = _mediaPlayerKey.currentState;
      if (mediaPlayerState == null) return;

      // 获取当前播放的媒体项
      final currentMedia = await mediaPlayerState.getCurrentMedia();
      if (currentMedia == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有正在播放的媒体')),
        );
        return;
      }

      // 确保回收站文件夹存在
      const recycleBinId = 'recycle_bin';
      final dbHelper = _databaseService;
      
      // 检查回收站文件夹是否存在
      final recycleBinFolder = await dbHelper.getMediaItemById(recycleBinId);
      if (recycleBinFolder == null) {
        // 创建回收站文件夹
        await dbHelper.insertMediaItem({
          'id': recycleBinId,
          'name': '回收站',
          'path': '',
          'type': MediaType.folder.index,
          'directory': 'root',
          'date_added': DateTime.now().toIso8601String(),
        });
      } else if (recycleBinFolder['directory'] != 'root') {
        // 如果回收站文件夹存在但目录不正确，更新它
        await dbHelper.updateMediaItemDirectory(recycleBinId, 'root');
      }

      // 移动媒体到回收站文件夹
      final updatedMedia = {
        'id': currentMedia.id,
        'name': currentMedia.name,
        'path': currentMedia.path,
        'type': currentMedia.type.index,
        'directory': recycleBinId,
        'date_added': currentMedia.dateAdded.toIso8601String(),
      };

      final result = await dbHelper.updateMediaItem(updatedMedia);
      if (result <= 0) {
        throw Exception('移动到回收站失败');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已移动到回收站')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移动到回收站失败: $e')),
        );
      }
    }
  }

  void _handleMediaFavorite() async {
    try {
      final mediaPlayerState = _mediaPlayerKey.currentState;
      if (mediaPlayerState == null) return;

      // 获取当前播放的媒体项
      final currentMedia = await mediaPlayerState.getCurrentMedia();
      if (currentMedia == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有正在播放的媒体')),
        );
        return;
      }

      // 确保收藏文件夹存在
      const favoritesFolderId = 'favorites';
      final dbHelper = _databaseService;
      
      // 检查收藏文件夹是否存在
      final favoritesFolder = await dbHelper.getMediaItemById(favoritesFolderId);
      if (favoritesFolder == null) {
        // 创建收藏文件夹
        await dbHelper.insertMediaItem({
          'id': favoritesFolderId,
          'name': '收藏夹',
          'path': '',
          'type': MediaType.folder.index,
          'directory': 'root',
          'date_added': DateTime.now().toIso8601String(),
        });
      }

      // 移动媒体到收藏文件夹
      final updatedMedia = {
        'id': currentMedia.id,
        'name': currentMedia.name,
        'path': currentMedia.path,
        'type': currentMedia.type.index,
        'directory': favoritesFolderId,
        'date_added': currentMedia.dateAdded.toIso8601String(),
      };

      final result = await dbHelper.updateMediaItem(updatedMedia);
      if (result <= 0) {
        throw Exception('收藏失败');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已添加到收藏夹')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('收藏失败: $e')),
        );
      }
    }
  }

  Future<dynamic> _showImageSourceSelectionDialog() async {
    return showDialog<dynamic>(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: Text('选择图片来源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.camera_alt, color: Colors.blue),
                title: Text('拍照'),
                onTap: () => Navigator.of(context).pop(ImageSource.camera),
              ),
              ListTile(
                leading: Icon(Icons.photo_library, color: Colors.green),
                title: Text('相册'),
                onTap: () => Navigator.of(context).pop(ImageSource.gallery),
              ),
              SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: Text('取消'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _handleImageSelection(dynamic source) async {
    if (source == null) return null;

    try {
      final picker = ImagePicker();
      final XFile? pickedFile = await picker.pickImage(
        source: source as ImageSource,
        imageQuality: 85,
      );

      if (pickedFile == null) return null;

      // 获取应用文档目录
      final appDir = await getApplicationDocumentsDirectory();
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedImage = File('${appDir.path}/images/$fileName');

      // 确保目录存在
      await savedImage.parent.create(recursive: true);
      
      // 复制图片到应用目录
      await File(pickedFile.path).copy(savedImage.path);
      
      return savedImage.path;
    } catch (e) {
      print('选择图片时出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片时出错，请重试')),
        );
      }
      return null;
    }
  }


}

