// lib/widgets/flippable_canvas_widget.dart
// 可翻转画布组件

import 'package:flutter/material.dart';
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (context) {
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
          child: Wrap(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    '画布设置',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1),
              ListTile(
                leading: Icon(
                  widget.canvas.isFlipped ? Icons.flip_to_front : Icons.flip_to_back,
                  color: Colors.blue,
                ),
                title: Text(widget.canvas.isFlipped ? '翻转到正面' : '翻转到反面'),
                onTap: () {
                  Navigator.pop(context);
                  _flipCanvas();
                },
              ),
              ListTile(
                leading: Icon(Icons.info_outline, color: Colors.green),
                title: Text('当前显示：${widget.canvas.isFlipped ? "反面" : "正面"}'),
                subtitle: Text(
                  '正面内容：${widget.canvas.frontTextBoxIds.length + widget.canvas.frontImageBoxIds.length + widget.canvas.frontAudioBoxIds.length}个\n'
                  '反面内容：${widget.canvas.backTextBoxIds.length + widget.canvas.backImageBoxIds.length + widget.canvas.backAudioBoxIds.length}个'
                ),
              ),
              ListTile(
                leading: Icon(Icons.delete, color: Colors.red),
                title: Text('删除画布'),
                onTap: () {
                  Navigator.pop(context);
                  if (widget.onSettingsPressed != null) {
                    widget.onSettingsPressed!();
                  }
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (details) {
        // 记录初始尺寸和初始缩放/焦点
        _initialWidth = widget.canvas.width;
        _initialHeight = widget.canvas.height;
        _currentScale = 1.0;
      },
      onScaleUpdate: (details) {
        // 双指缩放
        if (details.pointerCount > 1 && !widget.isPositionLocked) {
          setState(() {
            _currentScale = details.scale.clamp(0.3, 4.0);
            widget.canvas.width = (_initialWidth * _currentScale).clamp(50.0, 2000.0);
            widget.canvas.height = (_initialHeight * _currentScale).clamp(50.0, 2000.0);
            widget.onCanvasUpdated(widget.canvas);
          });
          return;
        }

        // 单指拖动：使用 scale 的 focalPointDelta 来平移
        if (details.pointerCount <= 1 && !widget.isPositionLocked) {
          final delta = details.focalPointDelta;
          if (delta != Offset.zero) {
            setState(() {
              widget.canvas.positionX += delta.dx;
              widget.canvas.positionY += delta.dy;
              widget.onCanvasUpdated(widget.canvas);
            });
          }
        }
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
        // 填充色与文本框一致，区别通过边框颜色体现
        color: Colors.white,
        border: Border.all(
          color: shouldShowFront ? Colors.blue[300]! : Colors.orange[300]!,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: Offset(2, 2),
          ),
        ],
      ),
      child: Stack(
        children: [
          // 画布背景标识
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  shouldShowFront ? Icons.crop_portrait : Icons.crop_portrait,
                  size: 32,
                  color: shouldShowFront ? Colors.blue[200] : Colors.orange[200],
                ),
                SizedBox(height: 4),
                Text(
                  shouldShowFront ? '正面' : '反面',
                  style: TextStyle(
                    fontSize: 12,
                    color: shouldShowFront ? Colors.blue[400] : Colors.orange[400],
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  shouldShowFront 
                    ? '${widget.canvas.frontTextBoxIds.length + widget.canvas.frontImageBoxIds.length + widget.canvas.frontAudioBoxIds.length}个内容'
                    : '${widget.canvas.backTextBoxIds.length + widget.canvas.backImageBoxIds.length + widget.canvas.backAudioBoxIds.length}个内容',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          // （保留）设置按钮位于左上角，翻转由双击空白处触发，不再需要单独翻转按钮
          // 设置按钮
          Positioned(
            top: 4,
            left: 4,
            child: GestureDetector(
              onTap: _showCanvasOptions,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[400]!, width: 1),
                ),
                child: Icon(
                  Icons.settings,
                  size: 14,
                  color: Colors.grey[700],
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
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey[400]!, width: 1),
                ),
                child: Icon(
                  Icons.open_in_full,
                  size: 14,
                  color: Colors.grey[700],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}