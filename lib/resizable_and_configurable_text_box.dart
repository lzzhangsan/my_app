// lib/resizable_and_configurable_text_box.dart
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:uuid/uuid.dart';
import 'dart:convert';

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

// 轻量富文本区间
class _AttributedRange {
  int start;
  int end; // 不包含 end
  TextStyle style;
  _AttributedRange({required this.start, required this.end, required this.style});
}

class _RichTextController extends TextEditingController {
  final List<_AttributedRange> _ranges = [];
  TextStyle defaultStyle;

  _RichTextController({required String text, required this.defaultStyle}) : super(text: text);

  void clearRanges() => _ranges.clear();

  void applyStyle(int start, int end, TextStyle style) {
    if (start >= end) return;
    // 简单合并：先移除覆盖区间，再插入
    _ranges.removeWhere((r) => !(end <= r.start || start >= r.end));
    _ranges.add(_AttributedRange(start: start, end: end, style: style));
    _ranges.sort((a, b) => a.start.compareTo(b.start));
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, bool? withComposing}) {
    final String full = text;
    if (_ranges.isEmpty) {
      return TextSpan(text: full, style: defaultStyle);
    }
    final List<TextSpan> children = [];
    int index = 0;
    for (final r in _ranges) {
      if (index < r.start) {
        children.add(TextSpan(text: full.substring(index, r.start), style: defaultStyle));
      }
      children.add(TextSpan(text: full.substring(r.start, r.end), style: r.style));
      index = r.end;
    }
    if (index < full.length) {
      children.add(TextSpan(text: full.substring(index), style: defaultStyle));
    }
    return TextSpan(style: defaultStyle, children: children);
  }

  // 导出富文本JSON（带前缀以兼容旧版本）
  String exportRichJson() {
    final Map<String, dynamic> data = {
      'type': 'rich_text',
      'text': text,
      'defaultStyle': _textStyleToMap(defaultStyle),
      'ranges': _ranges
          .map((r) => {
                'start': r.start,
                'end': r.end,
                'style': _textStyleToMap(r.style),
              })
          .toList(),
    };
    return '__RICH__' + jsonEncode(data);
  }

  static Map<String, dynamic> _textStyleToMap(TextStyle s) => {
        'fontSize': s.fontSize ?? 16.0,
        'fontColor': (s.color ?? Colors.black).value,
        'fontWeight': (s.fontWeight ?? FontWeight.normal).index,
        'isItalic': (s.fontStyle ?? FontStyle.normal) == FontStyle.italic,
        'backgroundColor': (s.backgroundColor ?? Colors.transparent).value,
        'textAlign': 0,
      };

  static TextStyle _mapToTextStyle(Map<String, dynamic> m) => TextStyle(
        fontSize: (m['fontSize'] as num?)?.toDouble() ?? 16.0,
        color: Color((m['fontColor'] as int?) ?? Colors.black.value),
        fontWeight: FontWeight.values[(m['fontWeight'] as int?) ?? 0],
        fontStyle: (m['isItalic'] == true) ? FontStyle.italic : FontStyle.normal,
        backgroundColor: Color((m['backgroundColor'] as int?) ?? Colors.transparent.value),
      );

  // 解析富文本
  static ({String text, TextStyle defaultStyle, List<_AttributedRange> ranges}) parseRich(String s) {
    final Map<String, dynamic> data = jsonDecode(s) as Map<String, dynamic>;
    final String plain = data['text'] as String? ?? '';
    final TextStyle def = _mapToTextStyle((data['defaultStyle'] as Map).cast<String, dynamic>());
    final List<_AttributedRange> ranges = [];
    final List list = data['ranges'] as List? ?? [];
    for (final item in list) {
      final map = (item as Map).cast<String, dynamic>();
      ranges.add(_AttributedRange(
        start: (map['start'] as num).toInt(),
        end: (map['end'] as num).toInt(),
        style: _mapToTextStyle((map['style'] as Map).cast<String, dynamic>()),
      ));
    }
    return (text: plain, defaultStyle: def, ranges: ranges);
  }
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

  TextStyle toTextStyle() => TextStyle(
        fontSize: fontSize,
        color: fontColor,
        fontWeight: fontWeight,
        fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
        backgroundColor: backgroundColor,
      );

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
  final bool globalEnhanceMode; // 添加全局增强模式参数

  const ResizableAndConfigurableTextBox({
    super.key,
    required this.initialSize,
    required this.initialText,
    required this.initialTextStyle,
    required this.onSave,
    required this.onDeleteCurrent,
    required this.onDuplicateCurrent,
    this.globalEnhanceMode = false, // 默认为false
  });

  @override
  _ResizableAndConfigurableTextBoxState createState() =>
      _ResizableAndConfigurableTextBoxState();
}

class _ResizableAndConfigurableTextBoxState
    extends State<ResizableAndConfigurableTextBox> {
  late Size _size;
  late CustomTextStyle _textStyle;
  late _RichTextController _controller;
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

    _textStyle = widget.initialTextStyle;

    // 解析初始文本是否为富文本
    if (widget.initialText.startsWith('__RICH__')) {
      try {
        final parsed = _RichTextController.parseRich(widget.initialText.substring(8));
        _textStyle = CustomTextStyle(
          fontSize: parsed.defaultStyle.fontSize ?? _textStyle.fontSize,
          fontColor: parsed.defaultStyle.color ?? _textStyle.fontColor,
          fontWeight: parsed.defaultStyle.fontWeight ?? _textStyle.fontWeight,
          isItalic: (parsed.defaultStyle.fontStyle == FontStyle.italic),
          backgroundColor: parsed.defaultStyle.backgroundColor,
          textAlign: _textStyle.textAlign,
        );
        _controller = _RichTextController(text: parsed.text, defaultStyle: _textStyle.toTextStyle());
        for (final r in parsed.ranges) {
          _controller.applyStyle(r.start, r.end, r.style);
        }
      } catch (_) {
        _controller = _RichTextController(text: widget.initialText, defaultStyle: _textStyle.toTextStyle());
      }
    } else {
      _controller = _RichTextController(text: widget.initialText, defaultStyle: _textStyle.toTextStyle());
    }

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
    // 若存在任何区间样式，则导出为富文本JSON
    final rich = _controller._ranges.isNotEmpty;
    final textToSave = rich ? _controller.exportRichJson() : _controller.text;
    widget.onSave(_size, textToSave, _textStyle);
  }

  // 显示设置面板
  void _showSettingsPanel(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (BuildContext context) {
        return Container(
          constraints: const BoxConstraints(maxHeight: 260),
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setModalState) {
              return _buildTextBoxSettings(setModalState);
            },
          ),
        );
      },
    );
  }

  // 文本框设置面板（当有选区时对选区生效，否则对整体生效）
  Widget _buildTextBoxSettings(StateSetter setModalState) {
    bool hasSelection = _selectionStart != null && _selectionEnd != null && _selectionStart != _selectionEnd;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 15),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.35),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: const Offset(0, -1),
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
                        icon: const Icon(Icons.content_copy, color: Colors.blue),
                        onPressed: widget.onDuplicateCurrent,
                        iconSize: 22,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: widget.onDeleteCurrent,
                        iconSize: 22,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ],
              ),
              const Divider(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildToolButton(
                    null,
                    () {
                      setState(() {
                        if (hasSelection && _selectionStart != null && _selectionEnd != null) {
                          final st = (_textStyle.copyWith(fontSize: (_textStyle.fontSize - 2).clamp(8.0, 300.0)));
                          _controller.applyStyle(_selectionStart!, _selectionEnd!, st.toTextStyle());
                        } else {
                          if (_textStyle.fontSize > 8) {
                            _textStyle = _textStyle.copyWith(fontSize: _textStyle.fontSize - 2);
                            _controller.defaultStyle = _textStyle.toTextStyle();
                          }
                        }
                      });
                      Future.microtask(() => _saveChanges());
                    },
                    false,
                    text: "A-",
                    width: 40,
                  ),
                  const SizedBox(width: 8),
                  _buildToolButton(
                    null,
                    () {
                      setState(() {
                        if (hasSelection && _selectionStart != null && _selectionEnd != null) {
                          final st = _textStyle.copyWith(fontSize: _textStyle.fontSize + 2);
                          _controller.applyStyle(_selectionStart!, _selectionEnd!, st.toTextStyle());
                        } else {
                          _textStyle = _textStyle.copyWith(fontSize: _textStyle.fontSize + 2);
                          _controller.defaultStyle = _textStyle.toTextStyle();
                        }
                      });
                      Future.microtask(() => _saveChanges());
                    },
                    false,
                    text: "A+",
                    width: 40,
                  ),
                  const SizedBox(width: 8),
                  _buildToolButton(
                    null,
                    () {
                      final newWeight = _textStyle.fontWeight == FontWeight.normal ? FontWeight.bold : FontWeight.normal;
                      setState(() {
                        if (hasSelection && _selectionStart != null && _selectionEnd != null) {
                          final st = _textStyle.copyWith(fontWeight: newWeight);
                          _controller.applyStyle(_selectionStart!, _selectionEnd!, st.toTextStyle());
                        } else {
                          _textStyle = _textStyle.copyWith(fontWeight: newWeight);
                          _controller.defaultStyle = _textStyle.toTextStyle();
                        }
                      });
                      Future.microtask(() => _saveChanges());
                    },
                    _textStyle.fontWeight == FontWeight.bold,
                    text: "B",
                    width: 40,
                  ),
                  const SizedBox(width: 8),
                  _buildToolButton(
                    null,
                    () {
                      final newItalic = !_textStyle.isItalic;
                      setState(() {
                        if (hasSelection && _selectionStart != null && _selectionEnd != null) {
                          final st = _textStyle.copyWith(isItalic: newItalic);
                          _controller.applyStyle(_selectionStart!, _selectionEnd!, st.toTextStyle());
                        } else {
                          _textStyle = _textStyle.copyWith(isItalic: newItalic);
                          _controller.defaultStyle = _textStyle.toTextStyle();
                        }
                      });
                      Future.microtask(() => _saveChanges());
                    },
                    _textStyle.isItalic,
                    text: "I",
                    width: 40,
                    isItalic: true,
                  ),
                  const SizedBox(width: 12),
                  _buildToolButton(
                    Icons.format_clear,
                    () {
                      setState(() {
                        if (hasSelection && _selectionStart != null && _selectionEnd != null) {
                          // 清除选择区间样式 -> 还原为默认样式
                          _controller.applyStyle(_selectionStart!, _selectionEnd!, _textStyle.toTextStyle());
                        } else {
                          _textStyle = CustomTextStyle(
                            fontSize: 16.0,
                            fontColor: Colors.black,
                            fontWeight: FontWeight.normal,
                            isItalic: false,
                            backgroundColor: null,
                            textAlign: TextAlign.left,
                          );
                          _controller.defaultStyle = _textStyle.toTextStyle();
                          _controller.clearRanges();
                        }
                      });
                      _saveChanges();
                    },
                    false,
                    width: 45,
                    color: Colors.red,
                  ),
                ],
              ),
              const SizedBox(height: 12),
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
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            if (hasSelection && _selectionStart != null && _selectionEnd != null) {
                              final st = _textStyle.copyWith(fontColor: color);
                              _controller.applyStyle(_selectionStart!, _selectionEnd!, st.toTextStyle());
                            } else {
                              _textStyle = _textStyle.copyWith(fontColor: color);
                              _controller.defaultStyle = _textStyle.toTextStyle();
                            }
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
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          if (hasSelection && _selectionStart != null && _selectionEnd != null) {
                            final st = _textStyle.copyWith(backgroundColor: Colors.transparent);
                            _controller.applyStyle(_selectionStart!, _selectionEnd!, st.toTextStyle());
                          } else {
                            _textStyle = _textStyle.copyWith(backgroundColor: Colors.transparent);
                            _controller.defaultStyle = _textStyle.toTextStyle();
                          }
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
                        child: _textStyle.backgroundColor == null || _textStyle.backgroundColor == Colors.transparent ? const Icon(Icons.check, color: Colors.blue, size: 12) : null,
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
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            if (hasSelection && _selectionStart != null && _selectionEnd != null) {
                              final st = _textStyle.copyWith(backgroundColor: color);
                              _controller.applyStyle(_selectionStart!, _selectionEnd!, st.toTextStyle());
                            } else {
                              _textStyle = _textStyle.copyWith(backgroundColor: color);
                              _controller.defaultStyle = _textStyle.toTextStyle();
                            }
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
                          child: _compareColors(_textStyle.backgroundColor, color) ? const Icon(Icons.check, color: Colors.blue, size: 12) : null,
                        ),
                      ),
                    ),
                ],
              ),
              Container(
                height: 4,
                width: 40,
                margin: const EdgeInsets.only(top: 12, bottom: 8),
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
        setState(() {
          _textStyle = _textStyle.copyWith(textAlign: align);
        });
        Future.microtask(() => _saveChanges());
      },
    );
  }

  Color _getContrastColor(Color color) {
    int d = color.computeLuminance() > 0.5 ? 0 : 255;
    return Color.fromARGB((color.a * 255).round(), d, d, d);
  }

  @override
  Widget build(BuildContext context) {
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
                    color: const Color(0xFFD2B48C).withOpacity(0.2),
                    blurRadius: 3.5,
                    spreadRadius: 0.3,
                    offset: const Offset(1, 1),
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
                  icon: const Icon(Icons.settings, size: 24),
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
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
                child: const Opacity(
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
    if (!widget.globalEnhanceMode || _focusNode.hasFocus) {
      return EditableText(
        controller: _controller,
        focusNode: _focusNode,
        scrollController: _textScrollController,
        maxLines: null,
        expands: true,
        textAlign: _textStyle.textAlign,
        style: _textStyle.toTextStyle(),
        cursorWidth: 2.0,
        cursorColor: _textStyle.fontColor,
        backgroundCursorColor: Colors.transparent,
        selectionColor: _textStyle.fontColor.withOpacity(0.25),
        onChanged: (text) => _saveChanges(),
      );
    } else {
      // 只读视图：用 RichText 展示区间样式
      final full = _controller.text;
      final List<InlineSpan> spans = [];
      int index = 0;
      final ranges = List<_AttributedRange>.from(_controller._ranges)..sort((a, b) => a.start.compareTo(b.start));
      for (final r in ranges) {
        if (index < r.start) {
          spans.add(TextSpan(text: full.substring(index, r.start), style: _textStyle.toTextStyle()));
        }
        spans.add(TextSpan(text: full.substring(r.start, r.end), style: r.style));
        index = r.end;
      }
      if (index < full.length) {
        spans.add(TextSpan(text: full.substring(index), style: _textStyle.toTextStyle()));
      }
      return Container(
        alignment: Alignment.topLeft,
        padding: const EdgeInsets.all(5.0),
        child: SingleChildScrollView(
          controller: _textScrollController,
          child: RichText(text: TextSpan(children: spans)),
        ),
      );
    }
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