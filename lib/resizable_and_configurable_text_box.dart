// lib/resizable_and_configurable_text_box.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;
import 'package:uuid/uuid.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart';

/// 全局剪贴板存储：用于在同一应用内复制/粘贴时保留富文本格式。
/// 因 Flutter 系统剪贴板仅支持纯文本，需在应用内维护 Delta 以恢复格式。
class _QuillClipboardStore {
  String? _plainText;
  Object? _delta; // quill.Delta，使用 Object 避免直接依赖内部类型

  void store(String plainText, Object delta) {
    _plainText = plainText;
    _delta = delta;
  }

  Object? tryGetDelta(String? clipboardText) {
    if (clipboardText == null || _plainText == null || _delta == null) return null;
    if (clipboardText == _plainText && _plainText!.isNotEmpty) return _delta;
    return null;
  }
}

final _quillClipboardStore = _QuillClipboardStore();

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
    this.fontWeight = FontWeight.bold,
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
      fontWeight: FontWeight.values[map['fontWeight'] ?? FontWeight.bold.index],
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

  /// 转为 Quill 颜色字符串 (#AARRGGBB 或 #RRGGBB)
  static String _toQuillColorHex(Color c) {
    return '#${c.value.toRadixString(16).padLeft(8, '0')}';
  }
}

/// TextSegment <-> Quill Delta 转换（用于 flutter_quill 富文本）
class _QuillDeltaConverter {
  static List<Map<String, dynamic>> segmentsToDeltaOps(List<TextSegment> segments) {
    final ops = <Map<String, dynamic>>[];
    for (final seg in segments) {
      if (seg.text.isEmpty) continue;
      final attrs = <String, dynamic>{};
      final s = seg.style;
      if (s.fontSize != 16) attrs['size'] = s.fontSize.toString();
      attrs['color'] = CustomTextStyle._toQuillColorHex(s.fontColor);
      if (s.fontWeight == FontWeight.bold) attrs['bold'] = true;
      if (s.isItalic) attrs['italic'] = true;
      if (s.backgroundColor != null) {
        attrs['background'] = CustomTextStyle._toQuillColorHex(s.backgroundColor!);
      }
      final insert = seg.text.replaceAll('\n', '\n');
      if (insert.contains('\n')) {
        final parts = insert.split('\n');
        for (var i = 0; i < parts.length; i++) {
          if (parts[i].isNotEmpty) {
            ops.add({'insert': parts[i], if (attrs.isNotEmpty) 'attributes': Map<String, dynamic>.from(attrs)});
          }
          if (i < parts.length - 1) ops.add({'insert': '\n'});
        }
      } else {
        ops.add({'insert': insert, if (attrs.isNotEmpty) 'attributes': attrs});
      }
    }
    if (ops.isEmpty || (ops.last['insert'] != '\n')) ops.add({'insert': '\n'});
    return ops;
  }

  static List<TextSegment> deltaOpsToSegments(List<Map<String, dynamic>> ops, CustomTextStyle defaultStyle) {
    final segments = <TextSegment>[];
    CustomTextStyle current = defaultStyle;
    final buf = StringBuffer();
    for (final op in ops) {
      final data = op['insert'];
      if (data is! String) continue;
      final attrs = op['attributes'] as Map<String, dynamic>?;
      final style = _attrsToCustomStyle(attrs, defaultStyle);
      for (var i = 0; i < data.length; i++) {
        final ch = data[i];
        if (ch == '\n') {
          if (buf.isNotEmpty) {
            segments.add(TextSegment(text: buf.toString(), style: current));
            buf.clear();
          }
          segments.add(TextSegment(text: '\n', style: current));
        } else {
          if (style != current && buf.isNotEmpty) {
            segments.add(TextSegment(text: buf.toString(), style: current));
            buf.clear();
          }
          current = style;
          buf.write(ch);
        }
      }
    }
    if (buf.isNotEmpty) segments.add(TextSegment(text: buf.toString(), style: current));
    return segments;
  }

  static CustomTextStyle _attrsToCustomStyle(Map<String, dynamic>? attrs, CustomTextStyle defaultStyle) {
    if (attrs == null || attrs.isEmpty) return defaultStyle;
    double fontSize = defaultStyle.fontSize;
    if (attrs['size'] != null) {
      final v = attrs['size'];
      if (v is num) fontSize = v.toDouble();
      else if (v is String) fontSize = double.tryParse(v) ?? defaultStyle.fontSize;
    }
    Color fontColor = defaultStyle.fontColor;
    if (attrs['color'] != null) {
      var h = attrs['color'].toString().replaceFirst('#', '');
      if (h.length == 6) h = 'ff$h';
      fontColor = Color(int.parse(h, radix: 16));
    }
    final bold = attrs['bold'] == true;
    final italic = attrs['italic'] == true;
    Color? bg;
    if (attrs['background'] != null) {
      var h = attrs['background'].toString().replaceFirst('#', '');
      if (h.length == 6) h = 'ff$h';
      bg = Color(int.parse(h, radix: 16));
    }
    return defaultStyle.copyWith(
      fontSize: fontSize,
      fontColor: fontColor,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      isItalic: italic,
      backgroundColor: bg,
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

/// 光标折叠时显示的小雨滴手柄，位于光标竖线正下方，样式与选中文字时的紫色小雨滴一致（竖直）。
class _CursorHandleOverlay extends StatefulWidget {
  const _CursorHandleOverlay({
    required this.editorKey,
    required this.quillController,
    required this.stackKey,
    required this.onTap,
  });

  final GlobalKey<quill.EditorState> editorKey;
  final quill.QuillController quillController;
  final GlobalKey stackKey;
  final VoidCallback onTap;

  @override
  State<_CursorHandleOverlay> createState() => _CursorHandleOverlayState();
}

class _CursorHandleOverlayState extends State<_CursorHandleOverlay> {
  Offset? _handlePosition;
  double _lineHeight = 20.0;

  void _updatePosition() {
    if (!mounted) return;
    // 必须在布局完成后才能访问 getLocalRectForCaret、localToGlobal 等，否则会触发 debugNeedsLayout 断言
    SchedulerBinding.instance.addPostFrameCallback((_) => _computePositionAfterLayout());
  }

  void _computePositionAfterLayout() {
    if (!mounted) return;
    final state = widget.editorKey.currentState;
    final stackContext = widget.stackKey.currentContext;
    if (state == null || stackContext == null) return;
    if (widget.editorKey.currentContext == null) return;

    final selection = widget.quillController.selection;
    if (!selection.isCollapsed) return;

    try {
      final renderEditor = state.renderEditor;
      final textPosition = TextPosition(offset: selection.baseOffset);
      final caretRect = renderEditor.getLocalRectForCaret(textPosition);
      _lineHeight = renderEditor.preferredLineHeight(textPosition);

      final renderBox = renderEditor as RenderBox;
      final globalBottomCenter = renderBox.localToGlobal(caretRect.bottomCenter);
      final stackBox = stackContext.findRenderObject() as RenderBox?;
      if (stackBox == null) return;

      final localPos = stackBox.globalToLocal(globalBottomCenter);
      const belowOffset = 2.0;
      final newPos = Offset(localPos.dx, localPos.dy + belowOffset);

      if (_handlePosition == null ||
          (_handlePosition!.dx - newPos.dx).abs() > 0.5 ||
          (_handlePosition!.dy - newPos.dy).abs() > 0.5) {
        if (mounted) setState(() => _handlePosition = newPos);
      }
    } catch (_) {
      // 布局尚未就绪或 render 对象不可用时忽略
    }
  }

  @override
  void initState() {
    super.initState();
    widget.quillController.addListener(_updatePosition);
    _updatePosition();
  }

  @override
  void didUpdateWidget(_CursorHandleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.quillController != widget.quillController) {
      oldWidget.quillController.removeListener(_updatePosition);
      widget.quillController.addListener(_updatePosition);
    }
    _updatePosition();
  }

  @override
  void dispose() {
    widget.quillController.removeListener(_updatePosition);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_handlePosition == null) return const SizedBox.shrink();

    const handleSize = 22.0;
    final left = _handlePosition!.dx - handleSize / 2;
    final top = _handlePosition!.dy;

    return Positioned(
      left: left,
      top: top,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.translucent,
          child: SizedBox(
            width: handleSize,
            height: handleSize,
            child: MaterialTextSelectionControls().buildHandle(
              context,
              TextSelectionHandleType.collapsed,
              _lineHeight,
              widget.onTap,
            ),
          ),
        ),
      ),
    );
  }
}

class ResizableAndConfigurableTextBox extends StatefulWidget {
  final Size initialSize;
  final String initialText;
  final CustomTextStyle initialTextStyle;
  final List<TextSegment>? initialTextSegments;
  final Function(Size, String, CustomTextStyle, List<TextSegment>) onSave;
  final Function() onDeleteCurrent;
  final Function() onDuplicateCurrent;
  // 如果此文本框是处于画布上（需要显示移动/复制到另一面的功能）
  final bool isOnCanvas;
  // 将此文本框移动到画布另一面（通常会改变所属页面/层）
  final VoidCallback? onMoveToOtherSide;
  // 复制此文本框到画布另一面（保留当前文本框）
  final VoidCallback? onCopyToOtherSide;
  // 是否锁定位置和尺寸（锁定时禁用右下角缩放手柄）
  final bool isPositionLocked;

  const ResizableAndConfigurableTextBox({
    super.key,
    required this.initialSize,
    required this.initialText,
    required this.initialTextStyle,
    this.initialTextSegments,
    required this.onSave,
    required this.onDeleteCurrent,
    required this.onDuplicateCurrent,
    this.isOnCanvas = false,
    this.onMoveToOtherSide,
    this.onCopyToOtherSide,
    this.isPositionLocked = false,
  });

  @override
  _ResizableAndConfigurableTextBoxState createState() =>
      _ResizableAndConfigurableTextBoxState();
}

class _ResizableAndConfigurableTextBoxState
    extends State<ResizableAndConfigurableTextBox> {
  late Size _size;
  late CustomTextStyle _textStyle;
  late quill.QuillController _quillController;
  StreamSubscription<quill.DocChange>? _docChangeSub;
  bool _applyingDefaultStyle = false;
  late FocusNode _focusNode;
  late ScrollController _textScrollController;
  final double _minWidth = 25.0;
  final double _minHeight = 25.0;
  bool _showBottomSettings = false;
  Timer? _keyboardSuppressTimer;
  TextSelection? _lastSelectionForHaptic;
  DateTime? _lastHapticTime;
  Timer? _saveDebounceTimer; // 防抖：连续输入/格式调整合并为一次历史记录
  final GlobalKey<quill.EditorState> _editorKey = GlobalKey<quill.EditorState>();
  final GlobalKey _cursorHandleStackKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _size = widget.initialSize;
    _textStyle = widget.initialTextStyle.copyWith(fontWeight: FontWeight.bold);

    List<TextSegment> initSegments;
    if (widget.initialTextSegments != null && widget.initialTextSegments!.isNotEmpty) {
      final fullText = widget.initialTextSegments!.map((s) => s.text).join();
      initSegments = fullText == widget.initialText
          ? List.from(widget.initialTextSegments!)
          : [TextSegment(text: widget.initialText, style: _textStyle)];
    } else {
      initSegments = [TextSegment(text: widget.initialText, style: _textStyle)];
    }

    final ops = _QuillDeltaConverter.segmentsToDeltaOps(initSegments);
    final doc = quill.Document.fromJson(ops);
    _quillController = quill.QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
      keepStyleOnNewLine: false,
      config: quill.QuillControllerConfig(
        clipboardConfig: quill.QuillClipboardConfig(
          onClipboardPaste: () async {
            final clipboardData =
                await Clipboard.getData(Clipboard.kTextPlain);
            final clipboardText = clipboardData?.text;
            final delta = _quillClipboardStore.tryGetDelta(clipboardText);
            if (delta != null && delta is Delta) {
              final sel = _quillController.selection;
              final newOffset = sel.start + delta.length;
              _quillController.replaceText(
                sel.start,
                sel.end - sel.start,
                delta,
                TextSelection.collapsed(offset: newOffset),
              );
              return true;
            }
            return false;
          },
        ),
      ),
    );
    if (_textStyle.textAlign != TextAlign.left && _quillController.document.length > 0) {
      final alignVal = _textStyle.textAlign == TextAlign.center ? 'center' : _textStyle.textAlign == TextAlign.right ? 'right' : 'justify';
      _quillController.formatText(0, _quillController.document.length, quill.Attribute.clone(quill.Attribute.align, alignVal));
    }
    _quillController.addListener(_onQuillChanged);
    _docChangeSub = _quillController.changes.listen(_handleDocChange);

    _focusNode = FocusNode();
    _focusNode.addListener(() {
      setState(() {});
      if (!_focusNode.hasFocus) _flushSaveDebounce(); // 失焦时立即保存，确保连续操作为一步
    });
    _textScrollController = ScrollController();
  }

  void _flushSaveDebounce() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _saveChanges();
  }

  /// 粘贴时优先使用应用内存储的富文本 Delta，以保留格式
  Future<void> _onPaste(dynamic state) async {
    final clipboardData =
        await Clipboard.getData(Clipboard.kTextPlain);
    final clipboardText = clipboardData?.text;
    final delta = _quillClipboardStore.tryGetDelta(clipboardText);
    if (delta != null && delta is Delta) {
      final sel = _quillController.selection;
      final newOffset = sel.start + delta.length;
      _quillController.replaceText(
        sel.start,
        sel.end - sel.start,
        delta,
        TextSelection.collapsed(offset: newOffset),
      );
      state.hideToolbar();
      state.bringIntoView(TextPosition(offset: newOffset));
    } else {
      await state.pasteText(SelectionChangedCause.toolbar);
    }
  }

  void _debouncedSaveChanges() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 1200), _flushSaveDebounce);
  }

  void _onQuillChanged() {
    final sel = _quillController.selection;
    if (_lastSelectionForHaptic != null &&
        (sel.baseOffset != _lastSelectionForHaptic!.baseOffset ||
            sel.extentOffset != _lastSelectionForHaptic!.extentOffset)) {
      final now = DateTime.now();
      if (_lastHapticTime == null ||
          now.difference(_lastHapticTime!).inMilliseconds >= 25) {
        HapticFeedback.selectionClick();
        _lastHapticTime = now;
      }
    }
    _lastSelectionForHaptic = sel;
    setState(() {});
    _debouncedSaveChanges();
  }

  @override
  void dispose() {
    _saveDebounceTimer?.cancel();
    _keyboardSuppressTimer?.cancel();
    _docChangeSub?.cancel();
    _quillController.removeListener(_onQuillChanged);
    _quillController.dispose();
    _focusNode.dispose();
    _textScrollController.dispose();
    super.dispose();
  }

  void _saveChanges() {
    final plainText = _quillController.document.toPlainText();
    final delta = _quillController.document.toDelta();
    final opsJson = <Map<String, dynamic>>[];
    for (final op in delta.toList()) {
      if (!op.isInsert) continue;
      final m = <String, dynamic>{'insert': op.data};
      if (op.attributes != null && op.attributes!.isNotEmpty) {
        m['attributes'] = op.attributes;
      }
      opsJson.add(m);
    }
    final segments = _QuillDeltaConverter.deltaOpsToSegments(
      opsJson.map((m) => Map<String, dynamic>.from(m)).toList(),
      _textStyle,
    );
    widget.onSave(_size, plainText, _textStyle, segments);
  }

  void _applyDefaultStyleToRange(int index, int length) {
    if (length <= 0) return;
    final docLength = _quillController.document.length;
    if (index < 0 || index >= docLength) return;
    final clampedLength = (index + length) > docLength ? (docLength - index) : length;

    final defaultColorHex = CustomTextStyle._toQuillColorHex(_textStyle.fontColor);
    _quillController.formatText(
      index,
      clampedLength,
      quill.Attribute.clone(quill.Attribute.size, _textStyle.fontSize.toInt().toString()),
    );
    _quillController.formatText(
      index,
      clampedLength,
      quill.Attribute.clone(quill.Attribute.color, defaultColorHex),
    );
    _quillController.formatText(
      index,
      clampedLength,
      quill.Attribute.clone(quill.Attribute.background, null),
    );
    _quillController.formatText(
      index,
      clampedLength,
      quill.Attribute.clone(quill.Attribute.italic, null),
    );
    _quillController.formatText(
      index,
      clampedLength,
      quill.Attribute.bold,
    );
  }

  /// 是否在行首插入：文档开头或紧跟换行符后。
  bool _isAtLineStart(int index) {
    if (index <= 0) return true;
    final doc = _quillController.document;
    if (index > doc.length) return false;
    final char = doc.toPlainText().substring(index - 1, index);
    return char == '\n';
  }

  /// 插入后该行是否为空（无右侧内容）：仅当另起一行时为空，此时用默认格式。
  /// 若行首有右侧内容，应继承右侧格式。
  bool _isLineEmptyAfterInsert(int start, int insertedLength) {
    final doc = _quillController.document;
    final rightIndex = start + insertedLength;
    if (rightIndex >= doc.length) return true;
    final plainText = doc.toPlainText();
    final char = plainText.substring(rightIndex, rightIndex + 1);
    return char == '\n';
  }

  void _handleDocChange(quill.DocChange change) {
    if (_applyingDefaultStyle) return;
    if (change.source != quill.ChangeSource.local) return;

    final ops = change.change.toJson();
    int insertedLength = 0;
    for (final op in ops) {
      final inserted = op['insert'];
      if (inserted is String && inserted.isNotEmpty) {
        insertedLength += inserted.length;
      }
    }
    if (insertedLength == 0) return;

    final end = _quillController.selection.baseOffset;
    final start = end - insertedLength;
    if (start < 0) return;

    if (!_isAtLineStart(start)) return;
    _applyingDefaultStyle = true;
    try {
      if (_isLineEmptyAfterInsert(start, insertedLength)) {
        // 另起一行：使用默认格式
        _applyDefaultStyleToRange(start, insertedLength);
      } else {
        // 行首插入但该行有内容：继承右侧字符的格式
        final rightStyle = _quillController.document.collectStyle(
          start + insertedLength,
          1,
        );
        if (rightStyle.isNotEmpty) {
          _quillController.formatTextStyle(start, insertedLength, rightStyle);
        }
      }
    } finally {
      _applyingDefaultStyle = false;
    }
  }

  bool get _hasSelection {
    final s = _quillController.selection;
    return s.isValid && s.start < s.end;
  }

  void _quillFormatSelection(quill.Attribute? attr) {
    if (_showBottomSettings) SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    _quillController.formatSelection(attr);
    _debouncedSaveChanges();
    _suppressKeyboardAfterFormat();
  }

  void _quillFormatWhole(quill.Attribute? attr) {
    if (_showBottomSettings) SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    final len = _quillController.document.length;
    if (len > 0) _quillController.formatText(0, len, attr);
    _debouncedSaveChanges();
    _suppressKeyboardAfterFormat();
  }

  /// 对整个文档按等比例调整字号：每个 Delta 插入片段在自身字号基础上 +delta
  void _quillFormatWholeSizeDelta(int delta) {
    if (_showBottomSettings) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
    final ops = _quillController.document.toDelta().toList();
    int offset = 0;
    for (final op in ops) {
      if (op.isInsert) {
        final len = op.length ?? (op.data is String ? (op.data as String).length : 1);
        if (op.data is String && len > 0) {
          double cur = _textStyle.fontSize;
          final attrs = op.attributes;
          if (attrs != null && attrs['size'] != null) {
            final v = attrs['size'];
            cur = (v is num) ? v.toDouble() : (double.tryParse(v.toString()) ?? cur);
          }
          final newSize = (cur + delta).clamp(8.0, double.infinity);
          _quillController.formatText(
            offset,
            len,
            quill.Attribute.clone(quill.Attribute.size, newSize.toString()),
          );
        }
        offset += len;
      } else if (op.isRetain) {
        offset += op.length ?? 0;
      }
    }
    _debouncedSaveChanges();
    _suppressKeyboardAfterFormat();
  }

  void _hideKeyboard() {
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    FocusManager.instance.primaryFocus?.unfocus();
  }

  ///  format 后多次尝试收起键盘，避免闪现
  void _suppressKeyboardAfterFormat() {
    if (!_showBottomSettings) return;
    void hide() {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      FocusManager.instance.primaryFocus?.unfocus();
    }
    hide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _showBottomSettings) hide();
    });
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted && _showBottomSettings) hide();
    });
  }

  Color _getQuillFontColor() {
    final s = _quillController.getSelectionStyle();
    final a = s.values.cast<quill.Attribute>().firstWhere(
      (a) => a.key == quill.Attribute.color.key,
      orElse: () => quill.Attribute.color,
    );
    if (a.value == null) return _textStyle.fontColor;
    var h = a.value.toString().replaceFirst('#', '');
    if (h.length == 6) h = 'ff$h';
    return Color(int.parse(h, radix: 16));
  }

  Color? _getQuillBackgroundColor() {
    final s = _quillController.getSelectionStyle();
    final a = s.values.cast<quill.Attribute>().firstWhere(
      (a) => a.key == quill.Attribute.background.key,
      orElse: () => quill.Attribute.background,
    );
    if (a.value == null) return null;
    var h = a.value.toString().replaceFirst('#', '');
    if (h.length == 6) h = 'ff$h';
    return Color(int.parse(h, radix: 16));
  }

  // 显示设置面板
  void _showSettingsPanel(BuildContext context) {
    _hideKeyboard();
    _quillController.readOnly = true;
    _quillController.skipRequestKeyboard = true;
    _keyboardSuppressTimer?.cancel();
    _keyboardSuppressTimer = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (!mounted || !_showBottomSettings) return;
      _hideKeyboard();
    });
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (BuildContext context) {
        return GestureDetector(
          onTap: () {},
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setModalState) {
                return SingleChildScrollView(
                  child: _buildTextBoxSettings(setModalState),
                );
              },
            ),
          ),
        );
      },
    ).then((_) {
      if (mounted) {
        _keyboardSuppressTimer?.cancel();
        _keyboardSuppressTimer = null;
        _quillController.readOnly = false;
        _quillController.skipRequestKeyboard = false;
        setState(() {
          _showBottomSettings = false;
        });
      }
    });
  }

  // 文本框设置面板
  Widget _buildTextBoxSettings(StateSetter setModalState) {
    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 6, horizontal: 12),
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
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                  if (widget.isOnCanvas) ...[
                    _buildAlignmentButton(Icons.format_align_left, TextAlign.left, isLarge: true),
                    _buildAlignmentButton(Icons.format_align_center, TextAlign.center, isLarge: true),
                    _buildAlignmentButton(Icons.format_align_right, TextAlign.right, isLarge: true),
                    IconButton(
                      icon: Icon(Icons.copy_all, color: Colors.blue),
                      onPressed: widget.onCopyToOtherSide,
                      iconSize: 24,
                      padding: EdgeInsets.all(4),
                      constraints: BoxConstraints(minWidth: 40, minHeight: 40),
                      tooltip: '复制到另一面',
                    ),
                    IconButton(
                      icon: Icon(Icons.swap_horiz, color: Colors.blue),
                      onPressed: widget.onMoveToOtherSide,
                      iconSize: 24,
                      padding: EdgeInsets.all(4),
                      constraints: BoxConstraints(minWidth: 40, minHeight: 40),
                      tooltip: '移动到另一面',
                    ),
                  ] else ...[
                    _buildAlignmentButton(Icons.format_align_left, TextAlign.left),
                    _buildAlignmentButton(Icons.format_align_center, TextAlign.center),
                    _buildAlignmentButton(Icons.format_align_right, TextAlign.right),
                  ],
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check, size: 18, color: Colors.blue.shade700),
                          SizedBox(width: 4),
                          Text('完成', style: TextStyle(fontSize: 14, color: Colors.blue.shade700)),
                        ],
                      ),
                    ),
                  ),
                ],
                ),
              ),
              Divider(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Flexible(
                    child: _buildToolButton(
                      null,
                      () {
                        if (_hasSelection) {
                          final style = _quillController.getSelectionStyle();
                          final sizeVal = style.values.firstWhere((a) => a.key == quill.Attribute.size.key, orElse: () => quill.Attribute.size);
                          double cur = _textStyle.fontSize;
                          if (sizeVal.value != null) cur = double.tryParse(sizeVal.value.toString()) ?? cur;
                          cur = (cur - 2).clamp(8.0, double.infinity);
                          final attr = quill.Attribute.clone(quill.Attribute.size, cur.toString());
                          _quillFormatSelection(attr);
                        } else {
                          _quillFormatWholeSizeDelta(-2);
                        }
                        setModalState(() {});
                      },
                      false,
                      text: "A-",
                      width: 30,
                    ),
                  ),
                  SizedBox(width: 4),
                  Flexible(
                    child: _buildToolButton(
                      null,
                      () {
                        if (_hasSelection) {
                          final style = _quillController.getSelectionStyle();
                          final sizeVal = style.values.firstWhere((a) => a.key == quill.Attribute.size.key, orElse: () => quill.Attribute.size);
                          double cur = _textStyle.fontSize;
                          if (sizeVal.value != null) cur = double.tryParse(sizeVal.value.toString()) ?? cur;
                          cur = (cur + 2).clamp(8.0, double.infinity);
                          final attr = quill.Attribute.clone(quill.Attribute.size, cur.toString());
                          _quillFormatSelection(attr);
                        } else {
                          _quillFormatWholeSizeDelta(2);
                        }
                        setModalState(() {});
                      },
                      false,
                      text: "A+",
                      width: 30,
                    ),
                  ),
                  SizedBox(width: 4),
                  Flexible(
                    child: _buildToolButton(
                      null,
                      () {
                        final isBold = _quillController.getSelectionStyle().values.any((a) => a.key == quill.Attribute.bold.key && a.value == true);
                        final attr = isBold ? quill.Attribute.clone(quill.Attribute.bold, null) : quill.Attribute.bold;
                        if (_hasSelection) _quillFormatSelection(attr);
                        else _quillFormatWhole(attr);
                        setModalState(() {});
                      },
                      _quillController.getSelectionStyle().values.any((a) => a.key == quill.Attribute.bold.key && a.value == true),
                      text: "B",
                      width: 30,
                    ),
                  ),
                  SizedBox(width: 4),
                  Flexible(
                    child: _buildToolButton(
                      null,
                      () {
                        final isItalic = _quillController.getSelectionStyle().values.any((a) => a.key == quill.Attribute.italic.key && a.value == true);
                        final attr = isItalic ? quill.Attribute.clone(quill.Attribute.italic, null) : quill.Attribute.italic;
                        if (_hasSelection) _quillFormatSelection(attr);
                        else _quillFormatWhole(attr);
                        setModalState(() {});
                      },
                      _quillController.getSelectionStyle().values.any((a) => a.key == quill.Attribute.italic.key && a.value == true),
                      text: "I",
                      width: 30,
                      isItalic: true,
                    ),
                  ),
                  SizedBox(width: 6),
                  Flexible(
                    child: _buildToolButton(
                      Icons.format_clear,
                      () {
                        if (_showBottomSettings) SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
                        final len = _quillController.document.length;
                        if (len > 0) {
                          final sel = _quillController.selection;
                          final start = _hasSelection ? sel.start : 0;
                          final length = _hasSelection ? (sel.end - sel.start) : len;
                          if (length > 0) {
                            _quillController.formatText(start, length, quill.Attribute.clone(quill.Attribute.size, '16'));
                            _quillController.formatText(start, length, quill.Attribute.clone(quill.Attribute.color, '#FF000000'));
                            _quillController.formatText(start, length, quill.Attribute.clone(quill.Attribute.background, null));
                            _quillController.formatText(start, length, quill.Attribute.clone(quill.Attribute.bold, null));
                            _quillController.formatText(start, length, quill.Attribute.clone(quill.Attribute.italic, null));
                          }
                        }
                        _debouncedSaveChanges();
                        _suppressKeyboardAfterFormat();
                        setModalState(() {});
                      },
                      false,
                      width: 30,
                      color: Colors.red,
                    ),
                  ),
                  SizedBox(width: 6),
                  IconButton(
                    icon: Icon(Icons.content_copy, color: Colors.blue),
                    onPressed: widget.onDuplicateCurrent,
                    iconSize: 18,
                    padding: EdgeInsets.all(2),
                    constraints: BoxConstraints(minWidth: 28, minHeight: 28),
                    tooltip: '复制文本框',
                  ),
                  IconButton(
                    icon: Icon(Icons.delete, color: Colors.red),
                    onPressed: widget.onDeleteCurrent,
                    iconSize: 18,
                    padding: EdgeInsets.all(2),
                    constraints: BoxConstraints(minWidth: 28, minHeight: 28),
                    tooltip: '删除文本框',
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
                          final attr = quill.Attribute.clone(quill.Attribute.color, CustomTextStyle._toQuillColorHex(color));
                          if (_hasSelection) _quillFormatSelection(attr); else _quillFormatWhole(attr);
                          setModalState(() {});
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _compareColors(_getQuillFontColor(), color) ? Colors.blue : Colors.grey.shade300,
                              width: _compareColors(_getQuillFontColor(), color) ? 2 : 1,
                            ),
                            boxShadow: _compareColors(_getQuillFontColor(), color) ? [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 4)] : null,
                          ),
                          child: _compareColors(_getQuillFontColor(), color) ? Icon(Icons.check, color: _getContrastColor(color), size: 12) : null,
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
                        final attr = quill.Attribute.clone(quill.Attribute.background, null);
                        if (_hasSelection) _quillFormatSelection(attr); else _quillFormatWhole(attr);
                        setModalState(() {});
                      },
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: (_getQuillBackgroundColor() == null || _getQuillBackgroundColor() == Colors.transparent) ? Colors.blue : Colors.grey.shade300,
                            width: (_getQuillBackgroundColor() == null || _getQuillBackgroundColor() == Colors.transparent) ? 2 : 1,
                          ),
                          gradient: LinearGradient(
                            colors: [Colors.white, Colors.grey.shade200],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: (_getQuillBackgroundColor() == null || _getQuillBackgroundColor() == Colors.transparent) ? [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 4)] : null,
                        ),
                        child: (_getQuillBackgroundColor() == null || _getQuillBackgroundColor() == Colors.transparent) ? Icon(Icons.check, color: Colors.blue, size: 12) : null,
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
                          final attr = quill.Attribute.clone(quill.Attribute.background, CustomTextStyle._toQuillColorHex(color));
                          if (_hasSelection) _quillFormatSelection(attr); else _quillFormatWhole(attr);
                          setModalState(() {});
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _compareColors(_getQuillBackgroundColor(), color) ? Colors.blue : Colors.grey.shade300,
                              width: _compareColors(_getQuillBackgroundColor(), color) ? 2 : 1,
                            ),
                            boxShadow: _compareColors(_getQuillBackgroundColor(), color) ? [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 4)] : null,
                          ),
                          child: _compareColors(_getQuillBackgroundColor(), color) ? Icon(Icons.check, color: Colors.blue, size: 12) : null,
                        ),
                      ),
                    ),
                ],
              ),
              Container(
                height: 4,
                width: 40,
                margin: EdgeInsets.only(top: 6, bottom: 4),
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
  Widget _buildAlignmentButton(IconData icon, TextAlign align, {bool isLarge = false}) {
    final String alignVal = align == TextAlign.left ? 'left' : align == TextAlign.center ? 'center' : align == TextAlign.right ? 'right' : 'justify';
    final bool isActive = _textStyle.textAlign == align;

    return IconButton(
      icon: Icon(
        icon,
        color: isActive ? Colors.blue.shade700 : Colors.blue.shade300,
      ),
      onPressed: () {
        _textStyle = _textStyle.copyWith(textAlign: align);
        final attr = quill.Attribute.clone(quill.Attribute.align, alignVal);
        _quillFormatWhole(attr);
        setState(() {});
      },
      iconSize: isLarge ? 24 : 20,
      padding: EdgeInsets.all(isLarge ? 4 : 2),
      constraints: BoxConstraints(
        minWidth: isLarge ? 40 : 32, 
        minHeight: isLarge ? 40 : 32
      ),
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
                    color: Color(0xFFD2B48C).withOpacity(0.2),
                    blurRadius: 3.5,
                    spreadRadius: 0.3,
                    offset: Offset(1, 1),
                  ),
                ],
              ),
              child: Stack(
                key: _cursorHandleStackKey,
                clipBehavior: Clip.none,
                children: [
                  _buildCustomTextField(),
                  if (_focusNode.hasFocus &&
                      _quillController.selection.isCollapsed)
                    _CursorHandleOverlay(
                      editorKey: _editorKey,
                      quillController: _quillController,
                      stackKey: _cursorHandleStackKey,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _editorKey.currentState?.showToolbar();
                      },
                    ),
                ],
              ),
            ),
            Positioned(
              right: -10,
              top: -12,
              child: Opacity(
                opacity: 0.125,
                child: IconButton(
                  icon: Icon(Icons.settings, size: 24),
                  padding: EdgeInsets.all(4),
                  constraints: BoxConstraints(),
                  iconSize: 20,
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setState(() {
                      _showBottomSettings = true;
                    });
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
                  // 锁定状态下禁用缩放手柄，避免误触导致文本框变形
                  if (widget.isPositionLocked) return;
                  double newWidth = _size.width + details.delta.dx;
                  double newHeight = _size.height + details.delta.dy;
                  if (newWidth >= _minWidth && newHeight >= _minHeight) {
                    setState(() {
                      _size = Size(newWidth, newHeight);
                    });
                  }
                },
                onPanEnd: (_) {
                  _saveChanges();
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

  Color _getStrokeColorForText(Color textColor) {
    return textColor.computeLuminance() > 0.5 ? Colors.black : Colors.white;
  }

  TextStyle _strokeStyleForColor(Color textColor) {
    final strokeColor = _getStrokeColorForText(textColor);
    const offsets = [
      Offset(-1, -1), Offset(-1, 0), Offset(-1, 1),
      Offset(0, -1), Offset(0, 1),
      Offset(1, -1), Offset(1, 0), Offset(1, 1),
    ];
    return TextStyle(
      shadows: [for (final o in offsets) Shadow(blurRadius: 0, offset: o, color: strokeColor)],
    );
  }

  Widget _buildCustomTextField() {
    return Padding(
      padding: const EdgeInsets.all(5.0),
      child: ClipRect(
        clipBehavior: Clip.none,
        child: quill.QuillEditor.basic(
        controller: _quillController,
        focusNode: _focusNode,
        scrollController: _textScrollController,
        config: quill.QuillEditorConfig(
          editorKey: _editorKey,
          padding: EdgeInsets.zero,
          placeholder: '',
          paintCursorAboveText: true,
          textSelectionThemeData: const TextSelectionThemeData(
            cursorColor: Color(0xFF1565C0),
            selectionColor: Color(0x661565C0),
          ),
          quillMagnifierBuilder: (Offset dragPos) => _buildMagnifierAboveText(dragPos),
          contextMenuBuilder: (menuContext, state) {
            final anchors = state.contextMenuAnchors;
            final shifted = TextSelectionToolbarAnchors(
              primaryAnchor: anchors.primaryAnchor + const Offset(70, 0),
              secondaryAnchor: anchors.secondaryAnchor != null
                  ? anchors.secondaryAnchor! + const Offset(70, 0)
                  : null,
            );
            return TextFieldTapRegion(
              child: AdaptiveTextSelectionToolbar(
                anchors: shifted,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.content_cut, size: 18),
                          tooltip: '剪切',
                          splashRadius: 18,
                          onPressed: state.cutEnabled
                              ? () {
                                  state.cutSelection(
                                    SelectionChangedCause.toolbar,
                                  );
                                  _quillClipboardStore.store(
                                    _quillController.pastePlainText,
                                    _quillController.pasteDelta,
                                  );
                                }
                              : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          tooltip: '复制',
                          splashRadius: 18,
                          onPressed: state.copyEnabled
                              ? () {
                                  state.copySelection(
                                    SelectionChangedCause.toolbar,
                                  );
                                  _quillClipboardStore.store(
                                    _quillController.pastePlainText,
                                    _quillController.pasteDelta,
                                  );
                                }
                              : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.paste, size: 18),
                          tooltip: '粘贴',
                          splashRadius: 18,
                          onPressed: state.pasteEnabled
                              ? () => _onPaste(state)
                              : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.select_all, size: 18),
                          tooltip: '全选',
                          splashRadius: 18,
                          onPressed: state.selectAllEnabled
                              ? () => state.selectAll(
                                    SelectionChangedCause.toolbar,
                                  )
                              : null,
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.settings, size: 18),
                          tooltip: '文字设置',
                          splashRadius: 18,
                          onPressed: () {
                            state.hideToolbar();
                            setState(() {
                              _showBottomSettings = true;
                            });
                            _showSettingsPanel(context);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
          customStyles: quill.DefaultStyles(
            paragraph: quill.DefaultTextBlockStyle(
              TextStyle(
                fontSize: _textStyle.fontSize,
                color: _textStyle.fontColor,
                fontWeight: FontWeight.normal,
                fontStyle: _textStyle.isItalic ? FontStyle.italic : FontStyle.normal,
                height: 1.23,
                shadows: [
                  for (final o in [const Offset(-1,-1), const Offset(-1,0), const Offset(-1,1), const Offset(0,-1), const Offset(0,1), const Offset(1,-1), const Offset(1,0), const Offset(1,1)])
                    Shadow(blurRadius: 0, offset: o, color: _getStrokeColorForText(_textStyle.fontColor)),
                ],
              ),
              const quill.HorizontalSpacing(0, 0),
              const quill.VerticalSpacing(0, 0),
              const quill.VerticalSpacing(0, 0),
              null,
            ),
          ),
          customStyleBuilder: (quill.Attribute attr) {
            if (attr.key == quill.Attribute.color.key && attr.value != null) {
              var h = attr.value.toString().replaceFirst('#', '');
              if (h.length == 6) h = 'ff$h';
              final c = Color(int.parse(h, radix: 16));
              return _strokeStyleForColor(c);
            }
            return const TextStyle();
          },
        ),
      ),
    ),
    );
  }

  /// 自定义放大镜：使用默认实现。Overlay 方案曾导致 !_debugDoingPaint 崩溃，已回退。
  Widget _buildMagnifierAboveText(Offset dragPos) {
    return quill.defaultQuillMagnifierBuilder(dragPos);
  }

  bool _compareColors(Color? color1, Color? color2) {
    if (color1 == null || color1 == Colors.transparent) {
      return color2 == null || color2 == Colors.transparent;
    }
    if (color2 == null || color2 == Colors.transparent) {
      return color1 == Colors.transparent;
    }
    return CustomTextStyle._toQuillColorHex(color1).toLowerCase() ==
        CustomTextStyle._toQuillColorHex(color2).toLowerCase();
  }
}
