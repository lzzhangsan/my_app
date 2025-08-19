// lib/resizable_and_configurable_text_box.dart
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:uuid/uuid.dart';

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

  // 常用背景颜色
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
      'fontColor': _getArgb(fontColor),
      'fontWeight': fontWeight.index,
      'isItalic': isItalic,
      'backgroundColor': backgroundColor != null ? _getArgb(backgroundColor!) : null,
      'textAlign': textAlign.index,
    };
  }

  factory CustomTextStyle.fromMap(Map<String, dynamic> map) {
    return CustomTextStyle(
      fontSize: map['fontSize'] ?? 16.0,
      fontColor: map['fontColor'] != null ? Color(map['fontColor']) : Colors.black,
      fontWeight: FontWeight.values[map['fontWeight'] ?? 0],
      isItalic: map['isItalic'] ?? false,
      backgroundColor: map['backgroundColor'] != null ? Color(map['backgroundColor']) : null,
      textAlign: TextAlign.values[map['textAlign'] ?? 0],
    );
  }

  static int _getArgb(Color color) {
    return ((color.a * 255).round() << 24) |
    ((color.r * 255).round() << 16) |
    ((color.g * 255).round() << 8) |
    (color.b * 255).round();
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

  const ResizableAndConfigurableTextBox({
    super.key,
    required this.initialSize,
    required this.initialText,
    required this.initialTextStyle,
    required this.onSave,
    required this.onDeleteCurrent,
    required this.onDuplicateCurrent,
  });

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
    print('保存文本框样式更改: 字体大小=${_textStyle.fontSize}, '
        '颜色=${_textStyle.fontColor}, '
        '粗体=${_textStyle.fontWeight}, '
        '斜体=${_textStyle.isItalic}, '
        '背景色=${_textStyle.backgroundColor}, '
        '对齐=${_textStyle.textAlign}');

    widget.onSave(_size, _controller.text, _textStyle);
  }

  // 显示设置面板
  void _showSettingsPanel(BuildContext context) {
    print('显示设置面板');

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (BuildContext context) {
        return Container(
          constraints: BoxConstraints(maxHeight: 260),
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setModalState) {
              return _buildTextBoxSettings(setModalState);
            },
          ),
        );
      },
    );
  }

  // 文本框设置面板
  Widget _buildTextBoxSettings(StateSetter setModalState) {
    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 8, horizontal: 15),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.35),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      _buildAlignmentButton(Icons.format_align_left, TextAlign.left),
                      _buildAlignmentButton(Icons.format_align_center, TextAlign.center),
                      _buildAlignmentButton(Icons.format_align_right, TextAlign.right),
                      _buildAlignmentButton(Icons.format_align_justify, TextAlign.justify),
                    ],
                  ),
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
                      Future.microtask(() => _saveChanges());
                    },
                    false,
                    text: "A-",
                    width: 40,
                  ),
                  SizedBox(width: 8),
                  _buildToolButton(
                    null,
                        () {
                      setState(() {
                        _textStyle = _textStyle.copyWith(fontSize: _textStyle.fontSize + 2);
                      });
                      Future.microtask(() => _saveChanges());
                    },
                    false,
                    text: "A+",
                    width: 40,
                  ),
                  SizedBox(width: 8),
                  _buildToolButton(
                    null,
                        () {
                      print('点击加粗按钮');
                      final newFontWeight = _textStyle.fontWeight == FontWeight.normal ? FontWeight.bold : FontWeight.normal;
                      setState(() {
                        _textStyle = _textStyle.copyWith(fontWeight: newFontWeight);
                        print('设置加粗状态为: $newFontWeight');
                      });
                      Future.microtask(() => _saveChanges());
                    },
                    _textStyle.fontWeight == FontWeight.bold,
                    text: "B",
                    width: 40,
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
                      Future.microtask(() => _saveChanges());
                    },
                    _textStyle.isItalic,
                    text: "I",
                    width: 40,
                    isItalic: true,
                  ),
                  SizedBox(width: 12),
                  _buildToolButton(
                    Icons.format_clear,
                        () {
                      setState(() {
                        _textStyle = CustomTextStyle(
                          fontSize: 16.0,
                          fontColor: Colors.black,
                          fontWeight: FontWeight.normal,
                          isItalic: false,
                          backgroundColor: null,
                          textAlign: TextAlign.left,
                        );
                      });
                      _saveChanges();
                    },
                    false,
                    width: 45,
                    color: Colors.red,
                  ),
                ],
              ),
              SizedBox(height: 12),
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
                          setModalState(() {});
                          Future.microtask(() => _saveChanges());
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _compareColors(_textStyle.fontColor, color) ? Colors.blue : Colors.grey.shade300,
                              width: _compareColors(_textStyle.fontColor, color) ? 2 : 1,
                            ),
                            boxShadow: _compareColors(_textStyle.fontColor, color) ? [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 4)] : null,
                          ),
                          child: _compareColors(_textStyle.fontColor, color) ? Icon(Icons.check, color: _getContrastColor(color), size: 12) : null,
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: InkWell(
                      onTap: () {
                        print("设置透明背景");
                        setState(() {
                          _textStyle = _textStyle.copyWith(backgroundColor: Colors.transparent);
                          print('背景颜色已设置为透明');
                        });
                        setModalState(() {});
                        Future.microtask(() => _saveChanges());
                      },
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: _textStyle.backgroundColor == null || _textStyle.backgroundColor == Colors.transparent ? Colors.blue : Colors.grey.shade300,
                            width: _textStyle.backgroundColor == null || _textStyle.backgroundColor == Colors.transparent ? 2 : 1,
                          ),
                          gradient: LinearGradient(
                            colors: [Colors.white, Colors.grey.shade200],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: _textStyle.backgroundColor == null || _textStyle.backgroundColor == Colors.transparent ? [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 4)] : null,
                        ),
                        child: _textStyle.backgroundColor == null || _textStyle.backgroundColor == Colors.transparent ? Icon(Icons.check, color: Colors.blue, size: 12) : null,
                      ),
                    ),
                  ),
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
                          setModalState(() {});
                          Future.microtask(() => _saveChanges());
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _compareColors(_textStyle.backgroundColor, color) ? Colors.blue : Colors.grey.shade300,
                              width: _compareColors(_textStyle.backgroundColor, color) ? 2 : 1,
                            ),
                            boxShadow: _compareColors(_textStyle.backgroundColor, color) ? [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 4)] : null,
                          ),
                          child: _compareColors(_textStyle.backgroundColor, color) ? Icon(Icons.check, color: Colors.blue, size: 12) : null,
                        ),
                      ),
                    ),
                ],
              ),
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

  // 构建工具按钮
  Widget _buildToolButton(IconData? icon, VoidCallback onPressed, bool isActive, {String? text, double width = 32, bool isItalic = false, Color? color}) {
    final Color buttonColor = color ?? (isActive ? Colors.blue : Colors.black);
    final double iconSize = color == Colors.red ? 24 : 20;

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
                color: buttonColor,
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
        color: isActive ? Colors.blue.shade700 : Colors.blue.shade300,
      ),
      onPressed: () {
        print('点击对齐按钮: $align');
        setState(() {
          _textStyle = _textStyle.copyWith(textAlign: align);
          print('设置文本对齐为: $align');
        });
        Future.microtask(() => _saveChanges());
      },
    );
  }

  Color _getContrastColor(Color color) {
    int d = color.computeLuminance() > 0.5 ? 0 : 255;
    return Color.fromARGB((color.a * 255).round(), d, d, d);
  }

  // 智能描边颜色计算函数
  Color _getSmartStrokeColor(Color textColor) {
    // 计算文字颜色的亮度
    double luminance = textColor.computeLuminance();
    
    // 如果文字颜色较亮（亮度 > 0.5），使用黑色描边
    // 如果文字颜色较暗（亮度 <= 0.5），使用白色描边
    if (luminance > 0.5) {
      return Colors.black;
    } else {
      return Colors.white;
    }
  }

  @override
  Widget build(BuildContext context) {
    bool hasTextSelection = _selectionStart != null && _selectionEnd != null && _selectionStart != _selectionEnd;

    return Focus(
      onKeyEvent: (node, event) {
        return _showBottomSettings ? KeyEventResult.handled : KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () {
          FocusScope.of(context).requestFocus(_focusNode);
          if (_showBottomSettings) {
            setState(() {
              _showBottomSettings = false;
            });
          }
        },
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
                boxShadow: [
                  BoxShadow(
                    color: Color(0xFFD2B48C).withOpacity(0.2),
                    blurRadius: 3.5,
                    spreadRadius: 0.3,
                    offset: Offset(1, 1),
                  ),
                ],
              ),
              child: _buildCustomTextField(),
            ),
            Positioned(
              left: -10,
              top: -12,
              child: Opacity(
                opacity: 0.125,
                child: IconButton(
                  icon: Icon(Icons.settings, size: 24),
                  padding: EdgeInsets.all(4),
                  constraints: BoxConstraints(),
                  iconSize: 20,
                  onPressed: () {
                    setState(() {
                      _showBottomSettings = true;
                    });
                    FocusScope.of(context).unfocus();
                    _showSettingsPanel(context);
                  },
                  tooltip: '文本框设置',
                ),
              ),
            ),
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
                  opacity: 0.25,
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

  Widget _buildCustomTextField() {
    // 统一增强模式：基于TextField结构，添加背景增强文字效果
    print('渲染增强模式: ${_focusNode.hasFocus ? "编辑状态" : "显示状态"}');
    final text = _controller.text;
    
    return SingleChildScrollView(
      controller: _textScrollController,
      child: Stack(
        children: [
          // 背景增强文字层（描边效果）
          TextField(
            controller: TextEditingController(text: text),
            enabled: false, // 禁用交互，仅用于显示
            maxLines: null,
            textAlign: _textStyle.textAlign,
            style: TextStyle(
              fontSize: _textStyle.fontSize,
              fontWeight: FontWeight.bold,
              fontStyle: _textStyle.isItalic ? FontStyle.italic : FontStyle.normal,
              backgroundColor: _textStyle.backgroundColor,
              height: 1.2,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2.5
                ..color = _getSmartStrokeColor(_textStyle.fontColor),
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(5.0),
              fillColor: Colors.transparent,
            ),
          ),
          // 背景增强文字层（填充效果）
          TextField(
            controller: TextEditingController(text: text),
            enabled: false, // 禁用交互，仅用于显示
            maxLines: null,
            textAlign: _textStyle.textAlign,
            style: TextStyle(
              color: _textStyle.fontColor,
              fontSize: _textStyle.fontSize,
              fontWeight: FontWeight.bold,
              fontStyle: _textStyle.isItalic ? FontStyle.italic : FontStyle.normal,
              backgroundColor: _textStyle.backgroundColor,
              height: 1.2,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(5.0),
              fillColor: Colors.transparent,
            ),
          ),
          // 前景交互TextField层（透明文字，精确光标定位）
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            maxLines: null,
            textAlign: _textStyle.textAlign,
            style: TextStyle(
              color: Colors.transparent, // 文字透明，只显示光标
              fontSize: _textStyle.fontSize,
              fontWeight: FontWeight.bold, // 与背景文字保持一致
              fontStyle: _textStyle.isItalic ? FontStyle.italic : FontStyle.normal,
              height: 1.2,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(5.0), // 与背景文字完全一致
              fillColor: Colors.transparent,
            ),
            onChanged: (text) {
              setState(() {}); // 更新背景增强文字显示
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
          ),
        ],
      ),
    );
  }

  bool _compareColors(Color? color1, Color? color2) {
    if (color1 == null || color1 == Colors.transparent) {
      return color2 == null || color2 == Colors.transparent;
    }
    if (color2 == null || color2 == Colors.transparent) {
      return color1 == Colors.transparent;
    }
    return color1 == color2;
  }
}