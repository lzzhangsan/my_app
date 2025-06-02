// lib/cover_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'resizable_and_configurable_text_box.dart';
import 'database_helper.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'services/image_picker_service.dart';
import 'widgets/performance_indicator.dart';
import 'performance_monitor_page.dart';

class CoverPage extends StatefulWidget {
  const CoverPage({super.key});

  @override
  _CoverPageState createState() => _CoverPageState();
}

class _CoverPageState extends State<CoverPage> {
  File? _backgroundImage;
  Color _backgroundColor = Colors.grey[200]!; // 默认背景颜色
  bool _isLoading = true;
  bool _hasCustomBackgroundColor = false; // 是否设置了自定义背景颜色

  List<Map<String, dynamic>> _textBoxes = [];
  List<String> _deletedTextBoxIds = [];
  static const String coverDocumentName = '__CoverPage__';
  late final DatabaseService _databaseService;

  @override
  void initState() {
    super.initState();
    print('CoverPage initState: ${DateTime.now()}'); // 添加日志
    
    if (!kIsWeb) {
      _databaseService = getService<DatabaseService>();
      _ensureCoverImageTableExists().then((_) {
        _loadBackgroundImage();
        _loadContent();
      });
    } else {
      print("Web environment: Skipping database operations in CoverPage");
      // 为Web环境设置默认状态
      if (mounted) {
        setState(() {
          _isLoading = false;
          _textBoxes = [];
          _backgroundColor = Colors.grey[200]!;
        });
      }
    }
  }

  @override
  void dispose() {
    print('CoverPage dispose: ${DateTime.now()}'); // 添加日志
    // 清理工作，例如取消订阅、释放资源等
    // _textBoxes.forEach((textBoxData) {
    //   final controller = textBoxData['controller'] as TextEditingController?;
    //   controller?.dispose();
    // });
    super.dispose();
  }
  // 确保cover_image表存在
  Future<void> _ensureCoverImageTableExists() async {
    try {
      Database db = await _databaseService.database;
      
      // 检查表是否存在
      List<Map<String, dynamic>> tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_image';"
      );
      
      if (tables.isEmpty) {
        print('cover_image表不存在，正在创建...');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cover_image (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            timestamp INTEGER
          )
        ''');
        print('cover_image表已创建');
      } else {
        print('cover_image表已存在');
      }
    } catch (e) {
      print('检查或创建cover_image表时出错: $e');
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
        });

        // 更新数据库
        await DatabaseHelper().insertCoverImage(destinationPath);
      }
    } catch (e) {
      print('选择背景图片时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择背景图片时出错，请重试。')),
      );
    }
  }

  Future<void> _removeBackgroundImage() async {
    final shouldDelete = await _showDeleteConfirmationDialog();
    if (shouldDelete) {
      try {
        await _ensureCoverImageTableExists(); // 确保表存在
        await DatabaseHelper().deleteCoverImage();
        
        // 同时清除封面设置
        DatabaseService dbHelper = _databaseService;
        Database db = await dbHelper.database;
        
        List<Map<String, dynamic>> tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_settings';"
        );
        
        if (tables.isNotEmpty) {
          // 更新设置，清除背景图片和颜色
          await db.update(
            'cover_settings',
            {
              'background_image_path': null,
              'background_color': null,
            },
            where: 'id = 1'
          );
        }
        
        setState(() {
          _backgroundImage = null;
          _backgroundColor = Colors.grey[200]!; // 恢复默认背景色
          _hasCustomBackgroundColor = false;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('背景设置已清除')),
        );
      } catch (e) {
        print('删除背景设置时出错: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除背景设置时出错，请重试。')),
        );
      }
    }
  }

  // 只删除背景图片，保留背景颜色
  Future<void> _removeBackgroundImageOnly() async {
    try {
      // 获取数据库实例
      Database db = await _databaseService.database;
      
      // 清空现有图片记录
      await db.delete('cover_image');
      
      // 更新封面设置，只清除背景图片路径，保留背景颜色
      List<Map<String, dynamic>> tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_settings';"
      );
      
      if (tables.isNotEmpty) {
        List<Map<String, dynamic>> settings = await db.query('cover_settings', where: 'id = 1');
        if (settings.isNotEmpty) {
          // 保留原有背景颜色
          int? backgroundColor = settings.first['background_color'];
          
          await db.update(
            'cover_settings',
            {
              'background_image_path': null,
              'background_color': backgroundColor,
            },
            where: 'id = 1'
          );
        }
      }
      
      setState(() {
        _backgroundImage = null;
        // 不重置背景颜色，保留当前颜色
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('背景图片已删除')),
      );
    } catch (e) {
      print('删除背景图片时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除背景图片时出错，请重试。')),
      );
    }
  }

  Future<void> _loadBackgroundImage() async {
    try {
      await _ensureCoverImageTableExists(); // 确保表存在
      
      // 先尝试加载图片
      List<Map<String, dynamic>> imageRecords = await DatabaseHelper().getCoverImage();
      if (imageRecords.isNotEmpty) {
        String imagePath = imageRecords.first['path'];
        if (await File(imagePath).exists()) {
          setState(() {
            _backgroundImage = File(imagePath);
          });
          print('成功加载背景图片: $imagePath');
        } else {
          print('图片文件不存在: $imagePath');
        }
      } else {
        print('没有找到背景图片记录');
      }
      
      // 再尝试加载封面设置（包括背景颜色）
      await _loadCoverSettings();
      
    } catch (e) {
      print('加载背景图片时出错: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 加载封面设置
  Future<void> _loadCoverSettings() async {
    try {
      // 获取数据库实例
      Database db = await _databaseService.database;
      
      // 检查表是否存在
      List<Map<String, dynamic>> tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_settings';"
      );
      
      if (tables.isEmpty) {
        print('cover_settings表不存在');
        return;
      }
      
      // 查询设置
      List<Map<String, dynamic>> settings = await db.query('cover_settings', where: 'id = 1');
      if (settings.isEmpty) {
        print('没有找到封面设置记录');
        return;
      }
      
      // 获取背景颜色
      if (settings.first['background_color'] != null) {
        int colorValue = settings.first['background_color'];
        setState(() {
          _backgroundColor = Color(colorValue);
          _hasCustomBackgroundColor = true;
        });
        print('成功加载背景颜色: $colorValue');
      }
      
      // 获取背景图片路径
      if (settings.first['background_image_path'] != null) {
        String imagePath = settings.first['background_image_path'];
        if (await File(imagePath).exists()) {
          setState(() {
            _backgroundImage = File(imagePath);
          });
          print('从设置中加载背景图片: $imagePath');
        }
      }
      
    } catch (e) {
      print('加载封面设置时出错: $e');
    }
  }

  Future<void> _saveBackgroundImage(String imagePath) async {
    try {
      await _ensureCoverImageTableExists(); // 确保表存在
      
      // 获取数据库实例
      Database db = await _databaseService.database;
      
      // 清空现有图片记录
      await db.delete('cover_image');
      
      // 插入新图片路径
      await db.insert('cover_image', {
        'path': imagePath,
        'timestamp': DateTime.now().millisecondsSinceEpoch
      });
      
      // 同时更新封面设置
      await _saveCoverSettings(imagePath, null);
      
      print('背景图片路径已保存: $imagePath');
      
      // 自动备份数据库
      await _databaseService.backupDatabase();
    } catch (e) {
      print('保存背景图片时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存背景图片失败，请重试。')),
      );
    }
  }

  Future<bool> _showDeleteConfirmationDialog() async {
    return await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('删除背景设置'),
          content: Text('确定要删除当前背景设置吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('删除'),
            ),
          ],
        );
      },
    ) ??
        false;
  }

  // 加载文本框内容
  Future<void> _loadContent() async {
    try {
      List<Map<String, dynamic>> textBoxes =
      await DatabaseHelper().getTextBoxesByDocument(coverDocumentName);
      setState(() {
        _textBoxes =
            textBoxes.map((map) => Map<String, dynamic>.from(map)).toList();
      });
    } catch (e) {
      print('加载内容时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载内容时出错，请重试。')),
      );
    }
  }

  // 保存文本框内容
  Future<void> _saveContent() async {
    final dbHelper = DatabaseHelper();
    final db = await dbHelper.database;

    try {
      await db.transaction((txn) async {
        // 删除已删除的文本框
        if (_deletedTextBoxIds.isNotEmpty) {
          await txn.delete(
            'text_boxes',
            where: 'id IN (${_deletedTextBoxIds.map((_) => '?').join(', ')})',
            whereArgs: _deletedTextBoxIds,
          );
          _deletedTextBoxIds.clear();
        }

        // 更新或插入文本框
        for (var textBox in _textBoxes) {
          // 数据验证
          if (!dbHelper.validateTextBoxData(textBox)) {
            throw Exception('文本框数据无效');
          }

          await txn.insert(
            'text_boxes',
            textBox,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
      // 自动备份数据库
      await _databaseService.backupDatabase();
    } catch (e) {
      print('保存内容时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存内容时出错，请重试。')),
      );
    }
  }

  void _addNewTextBox() {
    setState(() {
      var uuid = Uuid();
      double screenWidth = MediaQuery.of(context).size.width;
      double screenHeight = MediaQuery.of(context).size.height;

      Map<String, dynamic> newTextBox = {
        'id': uuid.v4(),
        'documentName': coverDocumentName,
        'positionX': screenWidth / 2 - 100,
        'positionY': screenHeight / 2 - 50,
        'width': 200.0,
        'height': 100.0,
        'text': '',
        'fontSize': 16.0,
        'fontColor': Colors.black.value,
      };

      // 数据验证
      if (_databaseService.validateTextBoxData(newTextBox)) {
        _textBoxes.add(newTextBox);
        _saveContent();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文本框数据无效，无法添加。')),
        );
      }
    });
  }

  Widget _buildTextBox(Map<String, dynamic> data) {
    final customTextStyle = CustomTextStyle(
      fontSize: data['fontSize'],
      fontColor: Color(data['fontColor']),
      fontWeight: data.containsKey('fontWeight') ? 
                  FontWeight.values[data['fontWeight']] : 
                  FontWeight.normal,
      isItalic: data.containsKey('isItalic') ? 
                data['isItalic'] == 1 : 
                false,
      backgroundColor: data.containsKey('backgroundColor') && data['backgroundColor'] != null ? 
                      Color(data['backgroundColor']) : 
                      null,
      textAlign: data.containsKey('textAlign') ? 
                TextAlign.values[data['textAlign']] : 
                TextAlign.left,
    );
    
    return ResizableAndConfigurableTextBox(
      initialSize: Size(
        data['width'],
        data['height'],
      ),
      initialText: data['text'],
      initialTextStyle: customTextStyle,
      onSave: (size, text, textStyle) {
        setState(() {
          data['width'] = size.width;
          data['height'] = size.height;
          data['text'] = text;
          data['fontSize'] = textStyle.fontSize;
          data['fontColor'] = textStyle.fontColor.value;
          data['fontWeight'] = textStyle.fontWeight.index;
          data['isItalic'] = textStyle.isItalic ? 1 : 0;
          data['backgroundColor'] = textStyle.backgroundColor?.value;
          data['textAlign'] = textStyle.textAlign.index;
        });
        _saveContent();
      },
      onDeleteCurrent: () {
        setState(() {
          _textBoxes.removeWhere((textBox) => textBox['id'] == data['id']);
          _deletedTextBoxIds.add(data['id']);
        });
        _saveContent();
      },
      onDuplicateCurrent: () {
        setState(() {
          var uuid = Uuid();
          Map<String, dynamic> original = data;
          Map<String, dynamic> newTextBox = {
            'id': uuid.v4(),
            'documentName': coverDocumentName,
            'positionX': original['positionX'] + 20,
            'positionY': original['positionY'] + 20,
            'width': original['width'],
            'height': original['height'],
            'text': original['text'],
            'fontSize': original['fontSize'],
            'fontColor': original['fontColor'],
          };

          // 数据验证
          if (_databaseService.validateTextBoxData(newTextBox)) {
            _textBoxes.add(newTextBox);
            _saveContent();
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('文本框数据无效，无法复制。')),
            );
          }
        });
      },
    );
  }

  // 显示恢复数据库的确认对话框
  Future<void> _showRestoreConfirmationDialog() async {
    bool confirm = await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('恢复数据库'),
          content: Text('这将恢复到最近的数据库备份，当前未保存的数据将会丢失。确定要继续吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('恢复'),
            ),
          ],
        );
      },
    ) ??
        false;

    if (confirm) {
      await DatabaseHelper().restoreDatabase();
      // 重新加载数据
      await _loadBackgroundImage();
      await _loadContent();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('数据库已恢复。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Container(
          color: Colors.white,
          child: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    return Scaffold(
      extendBodyBehindAppBar: true, // 让body延伸到顶部
      body: Stack(
        children: [
          // 第一层：背景颜色层
          Container(
            color: _backgroundColor,
          ),
          
          // 第二层：背景图片层
          if (_backgroundImage != null)
            Container(
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: FileImage(_backgroundImage!),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          
          // 第三层：文本框层
          if (_textBoxes.isEmpty && _backgroundImage == null && !_hasCustomBackgroundColor)
            Center(
              child: Text(
                '点击右下角设置按钮\n设置封面背景图片或颜色',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, color: Colors.black54),
              ),
            ),
          
          // 文本框层
          ..._textBoxes.map((textBoxData) {
            return _buildTextBox(textBoxData);
          }).toList(),
          // 添加浮动性能指示器
          Positioned(
            top: 56, // 向下调整图标位置
            right: 16,
            child: FloatingPerformanceIndicator(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PerformanceMonitorPage(),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      // 优化设置按钮样式 - 磨砂玻璃效果
      floatingActionButton: ClipRRect(
        borderRadius: BorderRadius.circular(24), // 更大的圆角
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5), // 磨砂玻璃效果
          child: Container(
            height: 48, // 保持大小
            width: 48,
            decoration: BoxDecoration(
              color: Colors.purple.withOpacity(0.2), // 更加透明的紫色
              borderRadius: BorderRadius.circular(24), // 圆形按钮
              border: Border.all(
                color: Colors.white.withOpacity(0.15), // 微妙的白边
                width: 0.5, 
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: FloatingActionButton(
              onPressed: _showSettingsPanel,
              heroTag: 'settingsBtn',
              child: Icon(
                Icons.settings, 
                size: 20,
                color: Colors.white.withOpacity(0.9), // 略微透明的图标
              ),
              backgroundColor: Colors.transparent, // 完全透明的背景
              elevation: 0, // 去除默认的阴影效果
              focusElevation: 0,
              hoverElevation: 0,
              highlightElevation: 0,
              splashColor: Colors.white.withOpacity(0.1), // 轻微的点击效果
            ),
          ),
        ),
      ),
    );
  }

  void _showSettingsPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // 允许内容滚动
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.only(
              top: 16,
              left: 16,
              right: 16,
              // 添加底部内边距，确保在有软键盘时内容不被遮挡
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题行
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Text(
                    '封面页设置',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                
                // 设置选项（减小间距）
                _buildSettingItem(
                  icon: Icons.image,
                  iconColor: Colors.blue,
                  title: '设置背景图片',
                  onTap: () {
                    Navigator.pop(context);
                    _pickBackgroundImage();
                  },
                ),
                _buildSettingItem(
                  icon: Icons.color_lens,
                  iconColor: Colors.purple,
                  title: '设置背景颜色',
                  onTap: () {
                    Navigator.pop(context);
                    _showColorPickerDialog();
                  },
                ),
                
                // 只删除背景图片的选项
                if (_backgroundImage != null)
                  _buildSettingItem(
                    icon: Icons.hide_image,
                    iconColor: Colors.orange,
                    title: '仅删除背景图片',
                    subtitle: '保留背景颜色设置',
                    onTap: () {
                      Navigator.pop(context);
                      _removeBackgroundImageOnly();
                    },
                  ),
                
                // 完全删除背景设置的选项
                if (_backgroundImage != null || _hasCustomBackgroundColor)
                  _buildSettingItem(
                    icon: Icons.delete,
                    iconColor: Colors.red[300]!,
                    title: '删除所有背景设置',
                    subtitle: '清除图片和颜色设置',
                    onTap: () {
                      Navigator.pop(context);
                      _removeBackgroundImage();
                    },
                  ),
                
                _buildSettingItem(
                  icon: Icons.text_fields,
                  iconColor: Colors.green,
                  title: '添加文本框',
                  onTap: () {
                    Navigator.pop(context);
                    _addNewTextBox();
                  },
                ),
                
                // 添加清空所有的选项
                _buildSettingItem(
                  icon: Icons.clear_all,
                  iconColor: Colors.red,
                  title: '清空封面页',
                  subtitle: '删除所有背景设置和文本框',
                  onTap: () {
                    Navigator.pop(context);
                    _clearAllContent();
                  },
                ),
                
                _buildSettingItem(
                  icon: Icons.restore,
                  iconColor: Colors.amber[800]!,
                  title: '恢复数据库',
                  onTap: () {
                    Navigator.pop(context);
                    _showRestoreConfirmationDialog();
                  },
                  isLast: true,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 创建更紧凑的设置项
  Widget _buildSettingItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    bool isLast = false,
  }) {
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: 8.0),
          visualDensity: VisualDensity.compact, // 更紧凑的布局
          leading: Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          title: Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 15,
              color: subtitle != null && title.contains('删除') ? iconColor : null,
            ),
          ),
          subtitle: subtitle != null
              ? Text(
                  subtitle,
                  style: TextStyle(fontSize: 12),
                )
              : null,
          onTap: onTap,
        ),
        if (!isLast) Divider(height: 1, indent: 56, endIndent: 16),
      ],
    );
  }

  // 使用flutter_colorpicker库的颜色选择器
  void _showColorPickerDialog() {
    Color pickerColor = _backgroundColor;
    
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('选择背景颜色'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: pickerColor,
              onColorChanged: (color) {
                pickerColor = color;
              },
              pickerAreaHeightPercent: 0.8,
              enableAlpha: true,
              displayThumbColor: true,
              showLabel: true,
              paletteType: PaletteType.hsv,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _setBackgroundColor(pickerColor);
              },
              child: Text('确定'),
            ),
          ],
        );
      },
    );
  }
  
  Future<void> _setBackgroundColor(Color color) async {
    try {
      setState(() {
        _backgroundColor = color;
        _hasCustomBackgroundColor = true;
      });
      
      // 保存背景颜色到设置
      await _saveCoverSettings(null, color.value);
      
      print('背景颜色已设置: ${color.value}');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('背景颜色已更新')),
      );
    } catch (e) {
      print('设置背景颜色时出错: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置背景颜色失败，请重试')),
      );
    }
  }
  
  Future<void> _saveCoverSettings(String? imagePath, int? colorValue) async {
    try {
      // 确保表存在
      await _ensureCoverImageTableExists();
      
      // 获取数据库实例
      Database db = await _databaseService.database;
      
      // 检查表是否存在
      List<Map<String, dynamic>> tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_settings';"
      );
      
      if (tables.isEmpty) {
        // 如果表不存在，创建表
        await db.execute('''
          CREATE TABLE cover_settings (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            background_image_path TEXT,
            background_color INTEGER
          )
        ''');
        print('创建了cover_settings表');
      }
      
      // 查询当前设置
      List<Map<String, dynamic>> settings = await db.query('cover_settings', where: 'id = 1');
      Map<String, dynamic> data = {'id': 1};
      
      // 如果有现有设置，继承那些没有明确指定要更改的值
      if (settings.isNotEmpty) {
        // 如果没有明确指定图片路径，保留现有的
        if (imagePath == null && !settings.first['background_image_path'].toString().contains('null')) {
          data['background_image_path'] = settings.first['background_image_path'];
        } else {
          data['background_image_path'] = imagePath;
        }
        
        // 如果没有明确指定颜色，保留现有的
        if (colorValue == null && settings.first['background_color'] != null) {
          data['background_color'] = settings.first['background_color'];
        } else {
          data['background_color'] = colorValue;
        }
      } else {
        // 没有现有设置，直接使用提供的值
        data['background_image_path'] = imagePath;
        data['background_color'] = colorValue;
      }
      
      // 更新或插入设置
      int updated = await db.update('cover_settings', data, where: 'id = 1');
      if (updated == 0) {
        await db.insert('cover_settings', data, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      
      print('已保存封面设置: 图片路径=${data['background_image_path'] ?? "无"}, 颜色=${data['background_color'] ?? "无"}');
      
    } catch (e) {
      print('保存封面设置时出错: $e');
      throw e;
    }
  }

  // 清空封面页所有内容（背景图片、背景颜色和文本框）
  Future<void> _clearAllContent() async {
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('清空封面页'),
          content: Text('这将删除封面页上的所有内容，包括背景图片、背景颜色和所有文本框。此操作无法撤销，确定要继续吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('清空'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          ],
        );
      },
    ) ?? false;

    if (shouldClear) {
      try {
        // 获取数据库实例
        DatabaseService dbHelper = _databaseService;
        Database db = await dbHelper.database;
        
        // 1. 清空背景图片
        await db.delete('cover_image');
        
        // 2. 清空背景设置
        List<Map<String, dynamic>> tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_settings';"
        );
        
        if (tables.isNotEmpty) {
          await db.update(
            'cover_settings',
            {
              'background_image_path': null,
              'background_color': null,
            },
            where: 'id = 1'
          );
        }
        
        // 3. 删除所有文本框
        await db.delete(
          'text_boxes',
          where: 'documentName = ?',
          whereArgs: [coverDocumentName],
        );
        
        // 更新UI
        setState(() {
          _backgroundImage = null;
          _backgroundColor = Colors.grey[200]!;
          _hasCustomBackgroundColor = false;
          _textBoxes.clear();
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('封面页已清空')),
        );
      } catch (e) {
        print('清空封面页时出错: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清空封面页时出错，请重试。')),
        );
      }
    }
  }
}
