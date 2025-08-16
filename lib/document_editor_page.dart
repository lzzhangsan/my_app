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
import 'dart:async';
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
  List<String> _deletedTextBoxIds = [];
  List<String> _deletedImageBoxIds = [];
  List<String> _deletedAudioBoxIds = [];
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
  bool _contentChanged = false;
  bool _textEnhanceMode = true;
  bool _isPositionLocked = true;
  String? _recordingAudioBoxId;
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

    _autoSaveTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      if (_contentChanged) {
        print('自动保存文档内容...');
        _saveContent();
        _contentChanged = false;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_contentChanged) {
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

        // 删除旧的背景图片文件
        if (_backgroundImage != null) {
          try {
            await _backgroundImage!.delete();
          } catch (e) {
            print('删除旧背景图片时出错: $e');
          }
        }

        // 生成唯一的文件名
        final uuid = const Uuid().v4();
        final extension = path.extension(imagePath);
        final fileName = '$uuid$extension';
        final destinationPath = '${backgroundDir.path}/$fileName';

        // 复制文件到应用私有目录
        await File(imagePath).copy(destinationPath);

        setState(() {
          _backgroundImage = File(destinationPath);
          _contentChanged = true;
        });
        await _databaseService.insertOrUpdateDocumentSettings(
          widget.documentName,
          imagePath: destinationPath,
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
    Color? pickedColor = await showDialog<Color>(
      context: context,
      builder: (context) {
        Color tempColor = _backgroundColor ?? Colors.white;
        return AlertDialog(
          title: Text('选择背景颜色'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: tempColor,
              onColorChanged: (Color color) {
                tempColor = color;
              },
              pickerAreaHeightPercent: 0.8,
              enableAlpha: true,
              displayThumbColor: true,
              showLabel: false,
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
          'deletedTextBoxIds': List<String>.from(_deletedTextBoxIds.where((id) => id != null)),
          'deletedImageBoxIds': List<String>.from(_deletedImageBoxIds.where((id) => id != null)),
          'deletedAudioBoxIds': List<String>.from(_deletedAudioBoxIds.where((id) => id != null)),
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

  Future<void> _saveContent() async {
    try {
      print('正在保存文档内容...');
      await _databaseService.saveTextBoxes(List<Map<String, dynamic>>.from(_textBoxes), widget.documentName);
      await _databaseService.saveImageBoxes(List<Map<String, dynamic>>.from(_imageBoxes), widget.documentName);
      await _databaseService.saveAudioBoxes(List<Map<String, dynamic>>.from(_audioBoxes), widget.documentName);
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
        Map<String, dynamic> newTextBox = {
          'id': uuid.v4(),
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
          _contentChanged = true;
          Future.microtask(() => _saveContent());
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
    Map<String, dynamic> imageBox = {
      'id': uuid.v4(),
      'documentName': widget.documentName,
      'positionX': screenWidth / 2 - 100,
      'positionY': scrollOffset + screenHeight / 2 - 50,
      'width': 200.0,
      'height': 200.0,
      'imagePath': '',
    };
    setState(() {
      _imageBoxes.add(imageBox);
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
            _saveContent();
            _saveStateToHistory();
          }
        });
      } else {
        setState(() {
          _imageBoxes.removeWhere((imageBox) => imageBox['id'] == id);
        });
        _saveContent();
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
            Future.microtask(() => _saveContent());
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
            Future.microtask(() => _saveContent());
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
      Map<String, dynamic> newAudioBox = {
        'id': uuid.v4(),
        'documentName': widget.documentName,
        'positionX': screenWidth / 2 - 28,
        'positionY': scrollOffset + screenHeight / 2 - 28,
        'audioPath': '',
      };

      _audioBoxes.add(newAudioBox);
      _contentChanged = true;
      _saveContent();
      _saveStateToHistory();
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
                  _saveContent();
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

          _saveContent();
          _saveStateToHistory();
        }
      });
    }
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
      
      _history.add({
        'textBoxes': safeTextBoxes,
        'imageBoxes': safeImageBoxes,
        'audioBoxes': safeAudioBoxes,
        'deletedTextBoxIds': List<String>.from(_deletedTextBoxIds.where((id) => id != null)),
        'deletedImageBoxIds': List<String>.from(_deletedImageBoxIds.where((id) => id != null)),
        'deletedAudioBoxIds': List<String>.from(_deletedAudioBoxIds.where((id) => id != null)),
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
        'deletedTextBoxIds': <String>[],
        'deletedImageBoxIds': <String>[],
        'deletedAudioBoxIds': <String>[],
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
    _deletedTextBoxIds = List<String>.from(historyState['deletedTextBoxIds']);
    _deletedImageBoxIds = List<String>.from(historyState['deletedImageBoxIds']);
    _deletedAudioBoxIds = historyState['deletedAudioBoxIds'] != null
        ? List<String>.from(historyState['deletedAudioBoxIds'])
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
    _scrollController.dispose();
    super.dispose();
  }

  // 页面销毁时的保存方法，不调用setState和UI相关方法
  Future<void> _saveContentOnDispose() async {
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
                    IconButton(
                      icon: Icon(
                        Icons.text_format,
                        size: 20,
                        color: _textEnhanceMode ? Colors.blue : Colors.black,
                      ),
                      onPressed: _toggleTextEnhanceMode,
                      tooltip: '文字增强模式',
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
                    ...List<Map<String, dynamic>>.from(_imageBoxes).map<Widget>((data) {
                      return Positioned(
                        key: ValueKey(data['id']),
                        left: data['positionX'],
                        top: data['positionY'],
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onPanUpdate: (details) {
                            if (_isPositionLocked) return;
                            setState(() {
                              double newDx =
                                  data['positionX'] + details.delta.dx;
                              double newDy =
                                  data['positionY'] + details.delta.dy;
                              double documentWidth =
                                  MediaQuery.of(context).size.width;
                              double documentHeight = totalHeight;
                              newDx = newDx.clamp(
                                  0.0, documentWidth - data['width']);
                              newDy = newDy.clamp(
                                  0.0, documentHeight - data['height']);
                              data['positionX'] = newDx;
                              data['positionY'] = newDy;
                              _updateImageBoxPosition(
                                data['id'],
                                Offset(newDx, newDy),
                              );
                            });
                          },
                          onPanEnd: (_) {
                            _saveContent();
                            _saveStateToHistory();
                          },
                          child: ResizableImageBox(
                            initialSize: Size(data['width'], data['height']),
                            imagePath: data['imagePath'],
                            onResize: (size) {
                              _updateImageBox(data['id'], size);
                              _saveContent();
                              _saveStateToHistory();
                            },
                            onSettingsPressed: () =>
                                _showImageBoxOptions(data['id']),
                          ),
                        ),
                      );
                    }),
                    ...List<Map<String, dynamic>>.from(_textBoxes).map<Widget>((data) {
                      return Positioned(
                        key: ValueKey(data['id']),
                        left: data['positionX'],
                        top: data['positionY'],
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onPanUpdate: (details) {
                            if (_isPositionLocked) return;
                            setState(() {
                              double newDx =
                                  data['positionX'] + details.delta.dx;
                              double newDy =
                                  data['positionY'] + details.delta.dy;
                              double documentWidth =
                                  MediaQuery.of(context).size.width;
                              double documentHeight = totalHeight;
                              newDx = newDx.clamp(
                                  0.0, documentWidth - data['width']);
                              newDy = newDy.clamp(
                                  0.0, documentHeight - data['height']);
                              data['positionX'] = newDx;
                              data['positionY'] = newDy;
                              _updateTextBoxPosition(
                                data['id'],
                                Offset(newDx, newDy),
                              );
                            });
                          },
                          onPanEnd: (_) {
                            _saveContent();
                            _saveStateToHistory();
                          },
                          child: _buildTextBox(data),
                        ),
                      );
                    }),
                    ..._audioBoxes.map<Widget>((data) {
                      return Positioned(
                        key: ValueKey(data['id']),
                        left: data['positionX'],
                        top: data['positionY'],
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onPanUpdate: (details) {
                            if (_isPositionLocked) return;
                            setState(() {
                              double newDx =
                                  data['positionX'] + details.delta.dx;
                              double newDy =
                                  data['positionY'] + details.delta.dy;
                              double documentWidth =
                                  MediaQuery.of(context).size.width;
                              double documentHeight = totalHeight;
                              newDx = newDx.clamp(0.0, documentWidth - 37.3);
                              newDy = newDy.clamp(0.0, documentHeight - 37.3);
                              data['positionX'] = newDx;
                              data['positionY'] = newDy;
                              _updateAudioBoxPosition(
                                data['id'],
                                Offset(newDx, newDy),
                              );
                            });
                          },
                          onPanEnd: (_) {
                            _saveContent();
                            _saveStateToHistory();
                          },
                          child: ResizableAudioBox(
                            audioPath: data['audioPath'] ?? '',
                            onIsRecording: (isRecording) =>
                                _handleAudioRecordingState(
                                    data['id'], isRecording),
                            onSettingsPressed: () =>
                                _showAudioBoxOptions(data['id']),
                            onPathUpdated: (path) =>
                                _updateAudioPath(data['id'], path),
                            startRecording: _recordingAudioBoxId == data['id'],
                          ),
                        ),
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
                  _saveContent();
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
          _saveContent();
          _saveStateToHistory();
        });
      },
      onDeleteCurrent: () {
        Future.microtask(() {
          _deleteTextBox(data['id']);
          _saveContent();
          _saveStateToHistory();
        });
      },
      onDuplicateCurrent: () {
        Future.microtask(() {
          _duplicateTextBox(data['id']);
          _saveContent();
          _saveStateToHistory();
        });
      },
      globalEnhanceMode: _textEnhanceMode,
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
      _saveContent();
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
      _saveContent();
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
      _saveContent();
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

