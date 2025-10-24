// lib/widgets/flippable_canvas_widget.dart
// 可翻转画布组件

import 'package:flutter/material.dart';
// 移除长按自动重复所需的 async Timer（保留可扩展性）
import 'dart:math' as math;
import '../models/flippable_canvas.dart';

class FlippableCanvasWidget extends StatefulWidget {
  final FlippableCanvas canvas;
  final Function(FlippableCanvas) onCanvasUpdated;
  final VoidCallback? onSettingsPressed;
  final bool isPositionLocked;

  const FlippableCanvasWidget({
    super.key,
    required this.canvas,
    required this.onCanvasUpdated,
    this.onSettingsPressed,
    this.isPositionLocked = false,
  });

  @override
  State<FlippableCanvasWidget> createState() => _FlippableCanvasWidgetState();
}

class _FlippableCanvasWidgetState extends State<FlippableCanvasWidget>
    with TickerProviderStateMixin {
  late AnimationController _flipController;
  late Animation<double> _flipAnimation;
  bool _isFlipping = false;
  
  // 画布拖拽相关
  bool _isDragging = false;
  Offset _dragStart = Offset.zero;
  // 缩放相关
  double _initialWidth = 0.0;
  double _initialHeight = 0.0;
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    _flipController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _flipAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _flipController,
      curve: Curves.easeInOut,
    ));

    // 如果画布已经是翻转状态，设置动画到最终位置
    if (widget.canvas.isFlipped) {
      _flipController.value = 1.0;
    }
    _initialWidth = widget.canvas.width;
    _initialHeight = widget.canvas.height;
  }

  @override
  void dispose() {
    _flipController.dispose();
    super.dispose();
  }

  void _flipCanvas() {
    if (_isFlipping) return;
    
    setState(() {
      _isFlipping = true;
    });

    if (widget.canvas.isFlipped) {
      // 当前显示反面，翻转到正面
      _flipController.reverse().then((_) {
        widget.canvas.flip();
        widget.onCanvasUpdated(widget.canvas);
        setState(() {
          _isFlipping = false;
        });
      });
    } else {
      // 当前显示正面，翻转到反面
      _flipController.forward().then((_) {
        widget.canvas.flip();
        widget.onCanvasUpdated(widget.canvas);
        setState(() {
          _isFlipping = false;
        });
      });
    }
  }

  void _showCanvasOptions() {
    // Create controllers once so they won't be recreated on every rebuild of the modal's StatefulBuilder.
    final xController = TextEditingController(text: widget.canvas.positionX.toStringAsFixed(0));
    final yController = TextEditingController(text: widget.canvas.positionY.toStringAsFixed(0));
    final wController = TextEditingController(text: widget.canvas.width.toStringAsFixed(0));
    final hController = TextEditingController(text: widget.canvas.height.toStringAsFixed(0));

    final sheet = showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (context) {
        // 使用StatefulBuilder让底部弹窗内部局部刷新
        return StatefulBuilder(
          builder: (context, setModalState) {
            final screenWidth = MediaQuery.of(context).size.width;
            // 使用外层创建的 controllers，避免在 setModalState 时被重建

            // 通用解析与更新函数
              void _applyValues({bool updateX = false, bool updateY = false, bool updateW = false, bool updateH = false, bool enforceMin = false}) {
              // 读取现有值
              double x = widget.canvas.positionX;
              double y = widget.canvas.positionY;
              double w = widget.canvas.width;
              double h = widget.canvas.height;

              double? parse(String v) {
                if (v.trim().isEmpty) return null;
                return double.tryParse(v.trim());
              }

              if (updateX) {
                final px = parse(xController.text);
                if (px != null) x = px;
              }
              if (updateY) {
                final py = parse(yController.text);
                if (py != null) y = py;
              }
              if (updateW) {
                final pw = parse(wController.text);
                if (pw != null) w = pw;
              }
              if (updateH) {
                final ph = parse(hController.text);
                if (ph != null) h = ph;
              }

              // 安全范围与最小值限制
              // 如果 enforceMin 为 true，则强制最低值（例如 50），否则仅限制上限，允许用户临时输入较小值以便编辑
              if (enforceMin) {
                w = w.clamp(50.0, screenWidth); // 宽度不超过屏幕宽，且最小 50
                h = h.clamp(50.0, 4000.0); // 高度下限 50，上限给大一些
              } else {
                // 允许用户临时输入更小的正整数（>=1），但仍不超过屏幕宽或极大值
                w = w.clamp(1.0, screenWidth);
                h = h.clamp(1.0, 4000.0);
              }
              x = x.clamp(0.0, screenWidth - w); // 左右不超出屏幕
              // y 暂不做垂直安全范围限制，如需可加：y = y.clamp(0.0, MediaQuery.of(context).size.height - h)

              // 如果用户把x调到靠右导致 x+width > 屏幕宽，则自动回调
              if (x + w > screenWidth) {
                x = screenWidth - w;
              }

              widget.canvas.positionX = x;
              widget.canvas.positionY = y;
              widget.canvas.width = w;
              widget.canvas.height = h;

              // 触发外部刷新，实时预览
              widget.onCanvasUpdated(widget.canvas);
              // 更新文本（去掉不合法输入时矫正值）。只有在 enforceMin=true 时才覆写用户正在输入的文本，避免打断输入体验。
              if (enforceMin) {
                setModalState(() {
                  xController.text = x.toStringAsFixed(0);
                  yController.text = y.toStringAsFixed(0);
                  wController.text = w.toStringAsFixed(0);
                  hController.text = h.toStringAsFixed(0);
                });
              } else {
                // 仍需刷新父视图以便预览（当 parse 成功时）
                setModalState(() {});
              }
              // 同时刷新父组件（防止大小未同步）
              setState(() {});
            }

            InputDecoration _dec(String label) => InputDecoration(
                  labelText: label,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                );

            // 微调按钮：单击 ±1，双击 ±10
            Widget _miniBtn({required IconData icon, required VoidCallback onTap, required VoidCallback onDouble}) {
              return GestureDetector(
                onTap: onTap, // 单击 ±1
                onDoubleTap: onDouble, // 双击 ±10
                child: Container(
                  width: 28,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.grey[400]!, width: 0.7),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 16, color: Colors.grey[700]),
                ),
              );
            }

            Widget _numField({
              required TextEditingController c,
              required String label,
              required Function(String) onChanged,
              required VoidCallback onInc,
              required VoidCallback onDec,
            }) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 82,
                    child: TextField(
                      controller: c,
                      keyboardType: TextInputType.number,
                      decoration: _dec(label),
                      onChanged: onChanged,
                    ),
                  ),
                  SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _miniBtn(
                        icon: Icons.remove,
                        onTap: onDec,
                        onDouble: () { for(int i=0;i<10;i++){ onDec(); } },
                      ),
                      SizedBox(width: 6),
                      _miniBtn(
                        icon: Icons.add,
                        onTap: onInc,
                        onDouble: () { for(int i=0;i<10;i++){ onInc(); } },
                      ),
                    ],
                  )
                ],
              );
            }

            // 紧凑型单行字段（含 ± 按钮）
            Widget _compactField({
              required TextEditingController controller,
              required String label,
              required VoidCallback onInc,
              required VoidCallback onDec,
              required VoidCallback onChanged,
            }) {
              return Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: label,
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                        contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      ),
                      onChanged: (_) => onChanged(),
                      // 当用户完成编辑（按完成键）或失去焦点时，强制最小值并更新。
                      onEditingComplete: () {
                        // 先做一次实时更新
                        onChanged();
                        // 编辑完成时，对宽/高 强制最小值，X/Y 也做边界修正
                        if (label == '宽') {
                          _applyValues(updateW: true, enforceMin: true);
                        } else if (label == '高') {
                          _applyValues(updateH: true, enforceMin: true);
                        } else if (label == 'X') {
                          _applyValues(updateX: true, enforceMin: true);
                        } else if (label == 'Y') {
                          _applyValues(updateY: true, enforceMin: true);
                        }
                      },
                      onSubmitted: (_) {
                        onChanged();
                        if (label == '宽') {
                          _applyValues(updateW: true, enforceMin: true);
                        } else if (label == '高') {
                          _applyValues(updateH: true, enforceMin: true);
                        } else if (label == 'X') {
                          _applyValues(updateX: true, enforceMin: true);
                        } else if (label == 'Y') {
                          _applyValues(updateY: true, enforceMin: true);
                        }
                      },
                    ),
                    SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _miniBtn(
                          icon: Icons.remove,
                          onTap: onDec,
                          onDouble: () { for(int i=0;i<10;i++){ onDec(); } },
                        ),
                        SizedBox(width: 6),
                        _miniBtn(
                          icon: Icons.add,
                          onTap: onInc,
                          onDouble: () { for(int i=0;i<10;i++){ onInc(); } },
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }

            return Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.95),
                borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 10,
                    offset: Offset(0, -1),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 精简标题与布局
                      Padding(
                        padding: EdgeInsets.only(top: 10, bottom: 6),
                        child: Text('画布设置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                      // 单行位置与大小
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            _compactField(
                              controller: xController,
                              label: 'X',
                              onChanged: () => _applyValues(updateX: true),
                              onInc: () { xController.text = ((double.tryParse(xController.text) ?? widget.canvas.positionX) + 1).toInt().toString(); _applyValues(updateX: true); },
                              onDec: () { xController.text = ((double.tryParse(xController.text) ?? widget.canvas.positionX) - 1).toInt().toString(); _applyValues(updateX: true); },
                            ),
                            _compactField(
                              controller: yController,
                              label: 'Y',
                              onChanged: () => _applyValues(updateY: true),
                              onInc: () { yController.text = ((double.tryParse(yController.text) ?? widget.canvas.positionY) + 1).toInt().toString(); _applyValues(updateY: true); },
                              onDec: () { yController.text = ((double.tryParse(yController.text) ?? widget.canvas.positionY) - 1).toInt().toString(); _applyValues(updateY: true); },
                            ),
                            // 宽/高输入：允许自由输入，只有在失焦或提交时才强制最小值
                            _compactField(
                              controller: wController,
                              label: '宽',
                              onChanged: () {
                                // 实时更新但不强制最小值以避免打断输入体验
                                _applyValues(updateW: true, enforceMin: false);
                              },
                              onInc: () {
                                wController.text = ((double.tryParse(wController.text) ?? widget.canvas.width) + 1).toInt().toString();
                                // 加减操作视为用户明确操作，立即生效并强制最小值
                                _applyValues(updateW: true, enforceMin: true);
                              },
                              onDec: () {
                                wController.text = ((double.tryParse(wController.text) ?? widget.canvas.width) - 1).toInt().toString();
                                _applyValues(updateW: true, enforceMin: true);
                              },
                            ),
                            _compactField(
                              controller: hController,
                              label: '高',
                              onChanged: () {
                                _applyValues(updateH: true, enforceMin: false);
                              },
                              onInc: () { hController.text = ((double.tryParse(hController.text) ?? widget.canvas.height) + 1).toInt().toString(); _applyValues(updateH: true, enforceMin: true); },
                              onDec: () { hController.text = ((double.tryParse(hController.text) ?? widget.canvas.height) - 1).toInt().toString(); _applyValues(updateH: true, enforceMin: true); },
                            ),
                          ],
                        ),
                      ),
                      // 安全范围提示
                      Padding(
                        padding: EdgeInsets.only(left: 12, top: 4, bottom: 6),
                        child: Text('范围: 0 ≤ X 且 X+宽 ≤ 屏幕(${screenWidth.toStringAsFixed(0)}) 宽≥50', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      ),
                      // 操作行：翻转 + 内容统计 + 删除
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: Row(
                          children: [
                            TextButton.icon(
                              onPressed: () { Navigator.pop(context); _flipCanvas(); },
                              icon: Icon(widget.canvas.isFlipped ? Icons.flip_to_front : Icons.flip_to_back, size: 18, color: Colors.blue),
                              label: Text(widget.canvas.isFlipped ? '正面' : '反面'),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '正:${widget.canvas.frontTextBoxIds.length + widget.canvas.frontImageBoxIds.length + widget.canvas.frontAudioBoxIds.length} 反:${widget.canvas.backTextBoxIds.length + widget.canvas.backImageBoxIds.length + widget.canvas.backAudioBoxIds.length}',
                                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () { Navigator.pop(context); if (widget.onSettingsPressed != null) widget.onSettingsPressed!(); },
                              icon: Icon(Icons.delete, size: 18, color: Colors.red),
                              label: Text('删除', style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 6),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    // Note: Do not dispose the controllers here. Disposing while framework still
    // has dependents can trigger assertions on some platforms/input flows.
    // Controllers will be GC'd when no longer referenced; explicit disposal
    // can be added later with careful lifecycle handling if desired.
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 使用单指平移拖动画布
      onPanStart: widget.isPositionLocked ? null : (details) {
        _isDragging = true;
        _dragStart = details.globalPosition;
      },
      onPanUpdate: widget.isPositionLocked ? null : (details) {
        if (_isDragging) {
          final delta = details.globalPosition - _dragStart;
          widget.canvas.positionX += delta.dx;
          widget.canvas.positionY += delta.dy;
          _dragStart = details.globalPosition;
          // 水平安全边界
          final screenWidth = MediaQuery.of(context).size.width;
          widget.canvas.positionX = widget.canvas.positionX.clamp(0.0, screenWidth - widget.canvas.width);
          widget.onCanvasUpdated(widget.canvas);
        }
      },
      onPanEnd: widget.isPositionLocked ? null : (details) {
        _isDragging = false;
      },
      onDoubleTap: _flipCanvas, // 双击翻转
      onLongPress: _showCanvasOptions, // 长按显示选项
      child: AnimatedBuilder(
        animation: _flipAnimation,
        builder: (context, child) {
          // 计算翻转角度
          final isShowingFront = _flipAnimation.value < 0.5;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001) // 添加透视效果
              ..rotateY(_flipAnimation.value * math.pi),
            child: _buildCanvasSide(isShowingFront),
          );
        },
      ),
    );
  }

  Widget _buildCanvasSide(bool isShowingFront) {
    // 根据翻转状态和动画进度决定显示哪一面
    final bool shouldShowFront = isShowingFront == !widget.canvas.isFlipped;
    
    return Container(
      width: widget.canvas.width,
      height: widget.canvas.height,
      decoration: BoxDecoration(
        // 画布透明，保持空白区域；通过边框颜色区分正/反面
        color: Colors.transparent,
        border: Border.all(
          color: shouldShowFront ? Colors.blue[300]! : Colors.orange[300]!,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          // 画布保持空白，不渲染默认占位标识
          SizedBox.shrink(),
          // （保留）设置按钮位于左上角，翻转由双击空白处触发，不再需要单独翻转按钮
          // 设置按钮
          Positioned(
            top: 4,
            left: 4,
            child: GestureDetector(
              onTap: _showCanvasOptions,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: Colors.white.withOpacity(0.4), width: 0.8),
                ),
                child: Icon(
                  Icons.settings,
                  size: 15,
                  color: Colors.grey[200],
                ),
              ),
            ),
          ),
          // 右下角缩放把手（可拖动来改变画布大小）
          Positioned(
            right: 4,
            bottom: 4,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (details) {
                if (widget.isPositionLocked) return;
                setState(() {
                  double newWidth = (widget.canvas.width + details.delta.dx).clamp(50.0, 2000.0);
                  double newHeight = (widget.canvas.height + details.delta.dy).clamp(50.0, 2000.0);
                  widget.canvas.width = newWidth;
                  widget.canvas.height = newHeight;
                  widget.onCanvasUpdated(widget.canvas);
                });
              },
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.30),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity(0.45), width: 0.8),
                ),
                child: Icon(
                  Icons.open_in_full,
                  size: 16,
                  color: Colors.grey[100],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}