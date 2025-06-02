// lib/resizable_and_configurable_text_box.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:uuid/uuid.dart';

// 设置模式枚举
enum SettingsMode {
  textBox,       // 文本框设置
}

// 配置类，定义常用的颜色和其他配置
class Config {
  // 常用文本颜色
  static const List<Color> textColors = [
    Colors.black,
    Colors.white,
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.lightGreen,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
    Colors.deepOrange,
    Colors.brown,
    Colors.grey,
  ];
  
  // 常用背景颜色 - 移除const，因为shade100不是常量表达式
  static List<Color> backgroundColors = [
    Colors.pink.shade100,
    Colors.purple.shade100,
    Colors.indigo.shade100,
    Colors.blue.shade100,
    Colors.lightBlue.shade100,
    Colors.cyan.shade100,
    Colors.teal.shade100,
    Colors.green.shade100,
    Colors.lightGreen.shade100,
    Colors.lime.shade100,
    Colors.yellow.shade100,
    Colors.amber.shade100,
    Colors.orange.shade100,
    Colors.deepOrange.shade100,
  ];
}

// 文本片段的样式和内容
class TextSegment {
  final String text;
  final CustomTextStyle style;

  TextSegment({
    required this.text,
    required this.style,
  });

  Map<String, dynamic> toMap() {
    return {
      'text': text,
      'style': style.toMap(),
    };
  }

  factory TextSegment.fromMap(Map<String, dynamic> map) {
    return TextSegment(
      text: map['text'],
      style: CustomTextStyle.fromMap(map['style']),
    );
  }

  TextSegment copyWith({
    String? text,
    CustomTextStyle? style,
  }) {
    return TextSegment(
      text: text ?? this.text,
      style: style ?? this.style,
    );
  }
}

class CustomTextStyle {
  final double fontSize;
  final Color fontColor;
  final FontWeight fontWeight;
  final bool isItalic;
  final Color? backgroundColor;
  final TextAlign textAlign;
  
  CustomTextStyle({
    required this.fontSize,
    required this.fontColor,
    this.fontWeight = FontWeight.normal,
    this.isItalic = false,
    this.backgroundColor,
    this.textAlign = TextAlign.left,
  });
  
  CustomTextStyle copyWith({
    double? fontSize,
    Color? fontColor,
    FontWeight? fontWeight,
    bool? isItalic,
    Color? backgroundColor,
    TextAlign? textAlign,
  }) {
    return CustomTextStyle(
      fontSize: fontSize ?? this.fontSize,
      fontColor: fontColor ?? this.fontColor,
      fontWeight: fontWeight ?? this.fontWeight,
      isItalic: isItalic ?? this.isItalic,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textAlign: textAlign ?? this.textAlign,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'fontSize': fontSize,
      'fontColor': fontColor.value,
      'fontWeight': fontWeight.index,
      'isItalic': isItalic,
      'backgroundColor': backgroundColor?.value,
      'textAlign': textAlign.index,
    };
  }

  factory CustomTextStyle.fromMap(Map<String, dynamic> map) {
    return CustomTextStyle(
      fontSize: map['fontSize'],
      fontColor: Color(map['fontColor']),
      fontWeight: FontWeight.values[map['fontWeight'] ?? 0],
      isItalic: map['isItalic'] ?? false,
      backgroundColor: map['backgroundColor'] != null ? Color(map['backgroundColor']) : null,
      textAlign: TextAlign.values[map['textAlign'] ?? 0],
    );
  }
}

// 存储文本框数据的类
class TextBoxData {
  final String id;
  final double x; // 文本框左上角 x 坐标
  final double y; // 文本框左上角 y 坐标
  final double width; // 文本框宽度
  final double height; // 文本框高度
  final String text; // 文本内容
  final List<TextSegment> textSegments; // 文本片段列表
  final CustomTextStyle defaultTextStyle; // 默认文本样式

  TextBoxData({
    String? id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.text,
    required this.textSegments,
    required this.defaultTextStyle,
  }) : id = id ?? Uuid().v4();

  // 创建副本，可选择性地更新某些字段
  TextBoxData copyWith({
    String? id,
    double? x,
    double? y,
    double? width,
    double? height,
    String? text,
    List<TextSegment>? textSegments,
    CustomTextStyle? defaultTextStyle,
  }) {
    return TextBoxData(
      id: id ?? this.id,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      text: text ?? this.text,
      textSegments: textSegments ?? this.textSegments,
      defaultTextStyle: defaultTextStyle ?? this.defaultTextStyle,
    );
  }

  // 转换为 Map 以便序列化
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'text': text,
      'textSegments': textSegments.map((segment) => segment.toMap()).toList(),
      'defaultTextStyle': defaultTextStyle.toMap(),
    };
  }

  // 从 Map 创建 TextBoxData 对象
  factory TextBoxData.fromMap(Map<String, dynamic> map) {
    return TextBoxData(
      id: map['id'],
      x: map['x'].toDouble(),
      y: map['y'].toDouble(),
      width: map['width'].toDouble(),
      height: map['height'].toDouble(),
      text: map['text'],
      textSegments: List<TextSegment>.from(
        (map['textSegments'] ?? []).map((x) => TextSegment.fromMap(x)),
      ),
      defaultTextStyle: CustomTextStyle.fromMap(map['defaultTextStyle']),
    );
  }
}

class ResizableAndConfigurableTextBox extends StatefulWidget {
  final Size initialSize;
  final String initialText;
  final CustomTextStyle initialTextStyle;
  final Function(Size, String, CustomTextStyle) onSave;
  final Function() onDeleteCurrent;
  final Function() onDuplicateCurrent;
  final bool globalEnhanceMode; // 添加全局增强模式参数
  
  const ResizableAndConfigurableTextBox({
    Key? key,
    required this.initialSize,
    required this.initialText,
    required this.initialTextStyle,
    required this.onSave,
    required this.onDeleteCurrent,
    required this.onDuplicateCurrent,
    this.globalEnhanceMode = false, // 默认为false
  }) : super(key: key);

  @override
  _ResizableAndConfigurableTextBoxState createState() =>
      _ResizableAndConfigurableTextBoxState();
}

class _ResizableAndConfigurableTextBoxState
    extends State<ResizableAndConfigurableTextBox> {
  late Size _size;
  late CustomTextStyle _textStyle;
  late TextEditingController _controller;
  late FocusNode _focusNode;
  late ScrollController _textScrollController;
  final double _minWidth = 25.0;
  final double _minHeight = 25.0;
  
  // 选择文本的相关变量
  int? _selectionStart;
  int? _selectionEnd;

  // 设置界面相关变量
  bool _showBottomSettings = false;
  SettingsMode _settingsMode = SettingsMode.textBox;

  // 可用字体列表
  // 注释掉未使用的字段
  /*
  final List<String> _availableFonts = [
    'Arial',
    'Roboto',
    'Times New Roman',
    'Courier New',
    'Comic Sans MS',
    'Impact',
    '宋体',
    '黑体',
    '楷体',
    '仿宋',
    '微软雅黑',
    '华文楷体',
    '华文宋体',
    '华文仿宋',
    '方正舒体',
    '方正姚体',
    '华文细黑',
    '华文行楷',
    '华文新魏',
    '华文中宋',
  ];
  */

  // 12个经典预定义颜色
  // 注释掉未使用的字段
  /*
  final List<Color> _presetColors = [
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.orange,
    Colors.brown,
  ];
  */

  // 建立中文字体列表，直接使用系统字体
  // 注释掉未使用的字段
  /*
  final List<String> _chineseFonts = [
    '宋体',
    '黑体',
    '楷体', 
    '仿宋',
    '微软雅黑',
    '华文楷体',
    '华文宋体',
    '华文仿宋',
    '华文行楷',
    '方正舒体',
    '方正姚体',
    '华文细黑'
  ];
  */

  @override
  void initState() {
    super.initState();
    _size = widget.initialSize;
    
    // 确保使用完整的CustomTextStyle对象，填充所有属性
    _textStyle = widget.initialTextStyle;
    
    // 打印初始样式，用于调试
    print('初始化文本框样式: 字体大小=${_textStyle.fontSize}, '
          '颜色=${_textStyle.fontColor}, '
          '粗体=${_textStyle.fontWeight}, '
          '斜体=${_textStyle.isItalic}, '
          '背景色=${_textStyle.backgroundColor}, '
          '对齐=${_textStyle.textAlign}');
    
    _controller = TextEditingController(text: widget.initialText);
    
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      // 移除自动显示设置面板的逻辑
      // 只在文本框获得或失去焦点时更新状态
      setState(() {});
    });
    _textScrollController = ScrollController();
    
    // 监听文本选择变化
    _controller.addListener(_handleTextChange);
  }
  
  // 处理文本变化和选择
  void _handleTextChange() {
    if (_controller.selection.isValid) {
      setState(() {
        _selectionStart = _controller.selection.start;
        _selectionEnd = _controller.selection.end;
        
        // 只记录选择状态，不自动弹出面板
        // 面板将通过左上角的设置按钮显示
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTextChange);
    _controller.dispose();
    _focusNode.dispose();
    _textScrollController.dispose();
    super.dispose();
  }

  void _saveChanges() {
    // 打印保存的样式信息，用于调试
    print('保存文本框样式更改: 字体大小=${_textStyle.fontSize}, '
          '颜色=${_textStyle.fontColor}, '
          '粗体=${_textStyle.fontWeight}, '
          '斜体=${_textStyle.isItalic}, '
          '背景色=${_textStyle.backgroundColor}, '
          '对齐=${_textStyle.textAlign}');
    
    // 调用父组件提供的保存方法
    widget.onSave(_size, _controller.text, _textStyle);
  }

  void _increaseFontSize() {
      setState(() {
        _textStyle = _textStyle.copyWith(fontSize: _textStyle.fontSize + 2);
      });
      _saveChanges();
  }

  void _decreaseFontSize() {
      setState(() {
        if (_textStyle.fontSize > 8) {
          _textStyle = _textStyle.copyWith(fontSize: _textStyle.fontSize - 2);
        }
      });
      _saveChanges();
  }

  void _showColorPicker() {
    // 保存当前文本样式，以便在取消时恢复
    final CustomTextStyle originalStyle = _textStyle;
    Color pickerColor = _textStyle.fontColor;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('选择文字颜色'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 预览区域
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '文字颜色预览',
                  style: TextStyle(
                    color: pickerColor,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              SizedBox(height: 12),
              // 颜色选择器
              ColorPicker(
                pickerColor: pickerColor,
                onColorChanged: (color) {
                  pickerColor = color;
                  setState(() {
                    _textStyle = _textStyle.copyWith(fontColor: color);
                  });
                },
                enableAlpha: true,
                labelTypes: const [],
                pickerAreaHeightPercent: 0.8,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              // 取消操作，恢复原始样式
              setState(() {
                _textStyle = originalStyle;
              });
              Navigator.of(context).pop();
            },
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
                _saveChanges();
            },
            child: Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showBackgroundColorPicker() {
    // 保存当前文本样式，以便在取消时恢复
    final CustomTextStyle originalStyle = _textStyle;
    Color pickerColor = _textStyle.backgroundColor ?? Colors.transparent;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('选择背景颜色'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 预览区域
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                  color: pickerColor,
                ),
                child: Text(
                  '背景颜色预览',
                  style: TextStyle(
                    color: _getContrastColor(pickerColor),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              SizedBox(height: 12),
              // 颜色选择器
              ColorPicker(
                pickerColor: pickerColor,
                onColorChanged: (color) {
                  pickerColor = color;
                  setState(() {
                    _textStyle = _textStyle.copyWith(backgroundColor: color);
                  });
                },
                enableAlpha: true,
                labelTypes: const [],
                pickerAreaHeightPercent: 0.8,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              // 取消操作，恢复原始样式
              setState(() {
                _textStyle = originalStyle;
              });
              Navigator.of(context).pop();
            },
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
                _saveChanges();
            },
            child: Text('确定'),
          ),
        ],
      ),
    );
  }

  void _toggleFontWeight() {
      setState(() {
        _textStyle = _textStyle.copyWith(
          fontWeight: _textStyle.fontWeight == FontWeight.normal
              ? FontWeight.bold
              : FontWeight.normal,
        );
      });
      _saveChanges();
  }

  void _toggleItalic() {
      setState(() {
        _textStyle = _textStyle.copyWith(isItalic: !_textStyle.isItalic);
      });
      _saveChanges();
  }

  void _changeTextAlign(TextAlign align) {
    // 文本对齐只能应用于整个文本框
    setState(() {
      _textStyle = _textStyle.copyWith(textAlign: align);
    });
    _saveChanges();
  }

  // 完全重新实现的强制维持选择状态方法 - 更简单，更可靠
  void _forceMaintainSelection(TextSelection selection) {
    if (!selection.isValid || selection.start == selection.end) return;
    
    print('强制维持选择状态: ${selection.start}-${selection.end}');
    
    // 立即应用选择状态
    _controller.selection = selection;
    _selectionStart = selection.start;
    _selectionEnd = selection.end;
    
    // 只用一次延迟应用，避免过度更新
    Future.delayed(Duration(milliseconds: 100), () {
      if (mounted) {
        _controller.selection = selection;
      }
    });
  }

  // 显示设置面板 - 修改为只显示文本框设置面板，增强磨砂效果
  void _showSettingsPanel(BuildContext context) {
    print('显示设置面板');
    
    // 显示底部面板，使用正确的参数结构
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent, // 设置为透明，以便磨砂效果显示
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (BuildContext context) {
        return Container(
      constraints: BoxConstraints(
            maxHeight: 260, // 删除字体部分后降低高度 (原来350)
      ),
          child: StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
              // 始终返回文本框设置面板
              return _buildTextBoxSettings(setModalState);
            },
          ),
        );
      },
    );
  }

  // 修改文本框设置选项，增强磨砂效果
  Widget _buildTextBoxSettings(StateSetter setModalState) {
    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0), // 增强模糊效果
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 8, horizontal: 15),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.35), // 降低不透明度以增强磨砂效果 (原来0.5的70%)
            borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: Offset(0, -1),
              ),
            ],
          ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
              // 第一行：对齐方式按钮和文本操作按钮(删除、复制)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                  // 对齐方式按钮组
                  Row(
                    children: [
                      _buildAlignmentButton(Icons.format_align_left, TextAlign.left),
                      _buildAlignmentButton(Icons.format_align_center, TextAlign.center),
                      _buildAlignmentButton(Icons.format_align_right, TextAlign.right),
                      _buildAlignmentButton(Icons.format_align_justify, TextAlign.justify),
                    ],
                  ),
                  // 操作按钮组
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.content_copy, color: Colors.blue),
                        onPressed: widget.onDuplicateCurrent,
                        iconSize: 22,
                        padding: EdgeInsets.all(4),
                        constraints: BoxConstraints(),
                      ),
                      IconButton(
                        icon: Icon(Icons.delete, color: Colors.red),
                        onPressed: widget.onDeleteCurrent,
                        iconSize: 22,
                        padding: EdgeInsets.all(4),
                        constraints: BoxConstraints(),
                      ),
                    ],
                  ),
                ],
              ),

              Divider(height: 12),
              
              // 第二行：简化的文本样式按钮组（保留A-/A+/B/I）和清除样式按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                _buildToolButton(
                  null, 
                    () {
                      setState(() {
                        if (_textStyle.fontSize > 8) {
                          _textStyle = _textStyle.copyWith(fontSize: _textStyle.fontSize - 2);
                        }
                      });
                      // 确保立即保存更改
                      Future.microtask(() => _saveChanges());
                    },
                    false, text: "A-", width: 40
                  ),
                  SizedBox(width: 8),
                _buildToolButton(
                  null, 
                    () {
                      setState(() {
                        _textStyle = _textStyle.copyWith(fontSize: _textStyle.fontSize + 2);
                      });
                      // 确保立即保存更改
                      Future.microtask(() => _saveChanges());
                    },
                    false, text: "A+", width: 40
                  ),
                  SizedBox(width: 8),
                _buildToolButton(
                  null, 
                    () {
                      print('点击加粗按钮');
                      final newFontWeight = _textStyle.fontWeight == FontWeight.normal
                          ? FontWeight.bold
                          : FontWeight.normal;
                      setState(() {
                        _textStyle = _textStyle.copyWith(
                          fontWeight: newFontWeight,
                        );
                        print('设置加粗状态为: $newFontWeight');
                      });
                      // 确保立即保存更改
                      Future.microtask(() => _saveChanges());
                    },
                    _textStyle.fontWeight == FontWeight.bold,
                    text: "B", width: 40
                  ),
                  SizedBox(width: 8),
                _buildToolButton(
                  null, 
                    () {
                      print('点击斜体按钮');
                      final newItalicState = !_textStyle.isItalic;
                      setState(() {
                        _textStyle = _textStyle.copyWith(isItalic: newItalicState);
                        print('设置斜体状态为: $newItalicState');
                      });
                      // 确保立即保存更改
                      Future.microtask(() => _saveChanges());
                    },
                    _textStyle.isItalic,
                    text: "I", width: 40, isItalic: true
                  ),
                  SizedBox(width: 12), // 增加间距使红色按钮更加明显
                  // 清除样式按钮，改为红色并放大
                _buildToolButton(
                  Icons.format_clear, 
                    () {
                      setState(() {
                        // 重置样式回默认状态
                        _textStyle = CustomTextStyle(
                          fontSize: 16.0, // 默认字体大小
                          fontColor: Colors.black,
                          fontWeight: FontWeight.normal,
                          isItalic: false,
                          backgroundColor: null,
                          textAlign: TextAlign.left,
                        );
                      });
                      _saveChanges();
                    },
                    false, width: 45, color: Colors.red
                  ),
                ],
              ),
              
              SizedBox(height: 12),
              
              // 第三行：文本颜色选择（10个经典颜色）
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (Color color in [
                      Colors.black, 
                      Colors.white, 
                      Colors.red, 
                      Colors.orange,
                      Colors.yellow, 
                      Colors.green, 
                      Colors.blue, 
                      Colors.indigo,
                      Colors.purple, 
                      Colors.pink,
                    ])
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: InkWell(
                        onTap: () {
                          print('点击文本颜色: $color');
                          setState(() {
                            _textStyle = _textStyle.copyWith(fontColor: color);
                            print('设置文本颜色为: $color');
                          });
                          setModalState(() {}); // 更新底部面板状态
                          // 确保立即保存更改
                          Future.microtask(() => _saveChanges());
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _compareColors(_textStyle.fontColor, color) ? 
                                Colors.blue : Colors.grey.shade300,
                              width: _compareColors(_textStyle.fontColor, color) ? 2 : 1,
                            ),
                            boxShadow: _compareColors(_textStyle.fontColor, color) ? 
                                [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 4)] : null,
                          ),
                          child: _compareColors(_textStyle.fontColor, color) ?
                            Icon(Icons.check, color: _getContrastColor(color), size: 12) : null,
                        ),
                      ),
                    ),
                ],
              ),
              
              SizedBox(height: 12),
              
              // 第四行：背景颜色选择（正方形，10个颜色）
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 透明背景
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: InkWell(
                      onTap: () {
                        print("设置透明背景");
                        // 这里直接设置为完全透明的颜色，而不是null
                        setState(() {
                          _textStyle = _textStyle.copyWith(backgroundColor: Colors.transparent);
                          print('背景颜色已设置为透明');
                        });
                        setModalState(() {}); // 更新底部面板状态
                        // 确保立即保存更改
                        Future.microtask(() => _saveChanges());
                      },
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: _textStyle.backgroundColor == null || _textStyle.backgroundColor == Colors.transparent ? 
                                  Colors.blue : Colors.grey.shade300,
                            width: _textStyle.backgroundColor == null || _textStyle.backgroundColor == Colors.transparent ? 2 : 1,
                          ),
                          // 透明背景标志 - 棋盘格图案
                          gradient: LinearGradient(
                            colors: [Colors.white, Colors.grey.shade200],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: _textStyle.backgroundColor == null || _textStyle.backgroundColor == Colors.transparent ? 
                              [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 4)] : null,
                        ),
                        child: _textStyle.backgroundColor == null || _textStyle.backgroundColor == Colors.transparent ?
                          Icon(Icons.check, color: Colors.blue, size: 12) : null,
                      ),
                    ),
                  ),
                  
                  // 彩色背景选项 - 正方形
                for (Color color in [
                    Colors.white,
                    Colors.pink.shade100,
                    Colors.yellow.shade100,
                    Colors.lightGreen.shade100,
                    Colors.lightBlue.shade100,
                    Colors.purple.shade100,
                    Colors.orange.shade100,
                    Colors.grey.shade200,
                    Colors.teal.shade100,
                  ])
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: InkWell(
                      onTap: () {
                        print('点击背景颜色: $color');
                        setState(() {
                          _textStyle = _textStyle.copyWith(backgroundColor: color);
                          print('设置背景颜色为: $color');
                        });
                        setModalState(() {}); // 更新底部面板状态
                        // 确保立即保存更改
                        Future.microtask(() => _saveChanges());
                      },
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: _compareColors(_textStyle.backgroundColor, color) ? 
                              Colors.blue : Colors.grey.shade300,
                            width: _compareColors(_textStyle.backgroundColor, color) ? 2 : 1,
                          ),
                          boxShadow: _compareColors(_textStyle.backgroundColor, color) ? 
                              [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 4)] : null,
                        ),
                        child: _compareColors(_textStyle.backgroundColor, color) ?
                          Icon(Icons.check, color: Colors.blue, size: 12) : null,
                      ),
                    ),
                  ),
                ],
              ),
              
              // 添加一个小把手，使其看起来更像抽屉
              Container(
                height: 4,
                width: 40,
                margin: EdgeInsets.only(top: 12, bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 构建工具按钮 - 添加颜色参数
  Widget _buildToolButton(IconData? icon, VoidCallback onPressed, bool isActive, {String? text, double width = 32, bool isItalic = false, Color? color}) {
    final Color buttonColor = color ?? (isActive ? Colors.blue : Colors.black);
    final double iconSize = color == Colors.red ? 24 : 20; // 如果是红色清除按钮，则放大图标
    
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            height: 32,
            decoration: BoxDecoration(
              border: isActive ? Border.all(color: Colors.blue, width: 2) : null,
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: text != null 
              ? Text(
                  text,
                  style: TextStyle(
                    fontSize: 16, 
                    fontWeight: FontWeight.bold,
                    fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
                    color: buttonColor
                  ),
                )
              : Icon(icon, size: iconSize, color: buttonColor),
          ),
        ),
      ),
    );
  }

  // 对齐方式按钮
  Widget _buildAlignmentButton(IconData icon, TextAlign align) {
    final bool isActive = _textStyle.textAlign == align;
    
    return IconButton(
      icon: Icon(
        icon,
        color: isActive ? Colors.blue.shade700 : Colors.blue.shade300, // 激活状态颜色更深
      ),
      onPressed: () {
        print('点击对齐按钮: $align');
        setState(() {
          _textStyle = _textStyle.copyWith(textAlign: align);
          print('设置文本对齐为: $align');
        });
        // 确保立即保存更改
        Future.microtask(() => _saveChanges());
      },
    );
  }

  Color _getContrastColor(Color color) {
    // 根据背景色计算对比色
    int d = color.computeLuminance() > 0.5 ? 0 : 255;
    return Color.fromARGB(color.alpha, d, d, d);
  }

  Color getOutlineColor() {
    return Colors.white;
  }

  TextDecoration _getTextDecoration() {
    return TextDecoration.none;  // 简化此方法
  }

  @override
  Widget build(BuildContext context) {
    // 判断是否有文本选择
    bool hasTextSelection = _selectionStart != null && _selectionEnd != null && _selectionStart != _selectionEnd;
    
    return Focus(
      // 使用Focus小部件来禁用键盘弹出
      onKeyEvent: (node, event) {
        return _showBottomSettings ? KeyEventResult.handled : KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () {
          // 使 TextField 获取焦点
          FocusScope.of(context).requestFocus(_focusNode);
          
          // 点击空白处时关闭底部设置面板
          if (_showBottomSettings) {
            setState(() {
              _showBottomSettings = false;
            });
          }
        },
        // 移除长按显示文本片段设置面板的功能
        child: Stack(
          children: [
            Container(
              width: _size.width,
              height: _size.height,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _focusNode.hasFocus ? Colors.blue : Colors.white,
                  width: 1.0,
                ),
                borderRadius: BorderRadius.circular(10),
                color: _textStyle.backgroundColor,
                // 添加阴影效果
                boxShadow: [
                  BoxShadow(
                    color: Color(0xFFD2B48C).withOpacity(0.2), // 将不透明度从0.1提高到0.2，增强视觉效果
                    blurRadius: 3.5,
                    spreadRadius: 0.3,
                    offset: Offset(1, 1),
                  ),
                ],
              ),
              child: _buildCustomTextField(),
            ),
            // 设置按钮 - 使其更加透明
              Positioned(
                left: -10,
                top: -12,
              child: Opacity(
                opacity: 0.125, // 降低到之前的一半透明度
                child: IconButton(
                  icon: Icon(Icons.settings, size: 24),
                  padding: EdgeInsets.all(4),
                  constraints: BoxConstraints(),
                  iconSize: 20,
                  onPressed: () {
                    // 显示设置面板并关闭键盘
                    setState(() {
                      _showBottomSettings = true;
                      _settingsMode = SettingsMode.textBox;
                    });
                    // 确保键盘收起
                    FocusScope.of(context).unfocus();
                    // 显示设置面板
                    _showSettingsPanel(context);
                  },
                  tooltip: '文本框设置',
                ),
              ),
            ),
            // 调整大小的手柄 - 使其更加透明
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    double newWidth = _size.width + details.delta.dx;
                    double newHeight = _size.height + details.delta.dy;
                    if (newWidth >= _minWidth && newHeight >= _minHeight) {
                      setState(() {
                        _size = Size(newWidth, newHeight);
                      });
                      _saveChanges();
                    }
                  },
                  child: Opacity(
                  opacity: 0.25, // 降低到之前的一半透明度
                    child: Icon(
                      Icons.zoom_out_map,
                      size: 24,
                      color: Colors.grey,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // 构建自定义文本框，确保字体正确应用
  Widget _buildCustomTextField() {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      scrollController: _textScrollController,
      maxLines: null,
      expands: true,
      textAlign: _textStyle.textAlign,
      style: TextStyle(
        color: _textStyle.fontColor,
        fontSize: _textStyle.fontSize,
        fontWeight: widget.globalEnhanceMode ? FontWeight.bold : _textStyle.fontWeight,
        fontStyle: _textStyle.isItalic ? FontStyle.italic : FontStyle.normal,
        backgroundColor: _textStyle.backgroundColor,
        height: 1.2,
        shadows: widget.globalEnhanceMode ? [
          Shadow(color: _getContrastingColor(_textStyle.fontColor), offset: Offset(1, 1), blurRadius: 1),
          Shadow(color: _getContrastingColor(_textStyle.fontColor), offset: Offset(-1, 1), blurRadius: 1),
          Shadow(color: _getContrastingColor(_textStyle.fontColor), offset: Offset(1, -1), blurRadius: 1),
          Shadow(color: _getContrastingColor(_textStyle.fontColor), offset: Offset(-1, -1), blurRadius: 1),
        ] : null,
      ),
      decoration: InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(5.0),
        fillColor: Colors.transparent,
      ),
      onChanged: (text) {
        _saveChanges();
      },
      onTap: () {
        if (_showBottomSettings) {
          setState(() {
            _showBottomSettings = false;
          });
        }
      },
      cursorWidth: 2.0,
      cursorColor: _textStyle.fontColor,
      enableInteractiveSelection: true,
    );
  }

  // 安全比较颜色 - 修复透明背景比较问题
  bool _compareColors(Color? color1, Color? color2) {
    // 处理透明色的特殊情况
    if (color1 == null || color1 == Colors.transparent) {
      return color2 == null || color2 == Colors.transparent;
    }
    if (color2 == null || color2 == Colors.transparent) {
      return color1 == null || color1 == Colors.transparent;
    }
    return color1.value == color2.value;
  }

  Color _getContrastingColor(Color color) {
    // 根据背景色计算对比色
    int d = color.computeLuminance() > 0.5 ? 0 : 255;
    return Color.fromARGB(color.alpha, d, d, d);
  }
}

// 添加三角形绘制类
class TrianglePainter extends CustomPainter {
  final Color color;
  
  TrianglePainter(this.color);
  
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
      
    final Path path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
      
    canvas.drawPath(path, paint);
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is TrianglePainter && oldDelegate.color != color;
  }
}
