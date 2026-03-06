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
  }

  @override
  void didUpdateWidget(FlippableCanvasWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 如果画布的翻转状态发生了变化，同步动画状态
    if (oldWidget.canvas.isFlipped != widget.canvas.isFlipped) {
      if (widget.canvas.isFlipped && _flipController.value == 0.0) {
        _flipController.value = 1.0;
      } else if (!widget.canvas.isFlipped && _flipController.value == 1.0) {
        _flipController.value = 0.0;
      }
    }
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
    final xController = TextEditingController(text: widget.canvas.positionX.toStringAsFixed(0));
    final yController = TextEditingController(text: widget.canvas.positionY.toStringAsFixed(0));
    final wController = TextEditingController(text: widget.canvas.width.toStringAsFixed(0));
    final hController = TextEditingController(text: widget.canvas.height.toStringAsFixed(0));

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final screenWidth = MediaQuery.of(context).size.width;

            void applyValues({bool updateX = false, bool updateY = false, bool updateW = false, bool updateH = false, bool enforceMin = false}) {
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

              if (enforceMin) {
                w = w.clamp(50.0, screenWidth);
                h = h.clamp(50.0, 4000.0);
              } else {
                w = w.clamp(1.0, screenWidth);
                h = h.clamp(1.0, 4000.0);
              }
              x = x.clamp(0.0, screenWidth - w);

              if (x + w > screenWidth) {
                x = screenWidth - w;
              }

              widget.canvas.positionX = x;
              widget.canvas.positionY = y;
              widget.canvas.width = w;
              widget.canvas.height = h;

              widget.onCanvasUpdated(widget.canvas);
              if (enforceMin) {
                setModalState(() {
                  xController.text = x.toStringAsFixed(0);
                  yController.text = y.toStringAsFixed(0);
                  wController.text = w.toStringAsFixed(0);
                  hController.text = h.toStringAsFixed(0);
                });
              } else {
                setModalState(() {});
              }
              setState(() {});
            }

            InputDecoration dec(String label) => InputDecoration(
                  labelText: label,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                );

            Widget miniBtn({required IconData icon, required VoidCallback onTap, required VoidCallback onDouble}) {
              return GestureDetector(
                onTap: onTap,
                onDoubleTap: onDouble,
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

            Widget compactField({
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
                        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      ),
                      onChanged: (_) => onChanged(),
                      onEditingComplete: () {
                        onChanged();
                        if (label == '宽') {
                          applyValues(updateW: true, enforceMin: true);
                        } else if (label == '高') {
                          applyValues(updateH: true, enforceMin: true);
                        } else if (label == 'X') {
                          applyValues(updateX: true, enforceMin: true);
                        } else if (label == 'Y') {
                          applyValues(updateY: true, enforceMin: true);
                        }
                      },
                      onSubmitted: (_) {
                        onChanged();
                        if (label == '宽') {
                          applyValues(updateW: true, enforceMin: true);
                        } else if (label == '高') {
                          applyValues(updateH: true, enforceMin: true);
                        } else if (label == 'X') {
                          applyValues(updateX: true, enforceMin: true);
                        } else if (label == 'Y') {
                          applyValues(updateY: true, enforceMin: true);
                        }
                      },
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        miniBtn(
                          icon: Icons.remove,
                          onTap: onDec,
                          onDouble: () { for(int i=0;i<10;i++){ onDec(); } },
                        ),
                        const SizedBox(width: 6),
                        miniBtn(
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
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 10,
                    offset: const Offset(0, -1),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 10, bottom: 6),
                        child: Text('画布设置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            compactField(
                              controller: xController,
                              label: 'X',
                              onChanged: () => applyValues(updateX: true),
                              onInc: () { xController.text = ((double.tryParse(xController.text) ?? widget.canvas.positionX) + 1).toInt().toString(); applyValues(updateX: true); },
                              onDec: () { xController.text = ((double.tryParse(xController.text) ?? widget.canvas.positionX) - 1).toInt().toString(); applyValues(updateX: true); },
                            ),
                            compactField(
                              controller: yController,
                              label: 'Y',
                              onChanged: () => applyValues(updateY: true),
                              onInc: () { yController.text = ((double.tryParse(yController.text) ?? widget.canvas.positionY) + 1).toInt().toString(); applyValues(updateY: true); },
                              onDec: () { yController.text = ((double.tryParse(yController.text) ?? widget.canvas.positionY) - 1).toInt().toString(); applyValues(updateY: true); },
                            ),
                            compactField(
                              controller: wController,
                              label: '宽',
                              onChanged: () {
                                applyValues(updateW: true, enforceMin: false);
                              },
                              onInc: () {
                                wController.text = ((double.tryParse(wController.text) ?? widget.canvas.width) + 1).toInt().toString();
                                applyValues(updateW: true, enforceMin: true);
                              },
                              onDec: () {
                                wController.text = ((double.tryParse(wController.text) ?? widget.canvas.width) - 1).toInt().toString();
                                applyValues(updateW: true, enforceMin: true);
                              },
                            ),
                            compactField(
                              controller: hController,
                              label: '高',
                              onChanged: () {
                                applyValues(updateH: true, enforceMin: false);
                              },
                              onInc: () { hController.text = ((double.tryParse(hController.text) ?? widget.canvas.height) + 1).toInt().toString(); applyValues(updateH: true, enforceMin: true); },
                              onDec: () { hController.text = ((double.tryParse(hController.text) ?? widget.canvas.height) - 1).toInt().toString(); applyValues(updateH: true, enforceMin: true); },
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 12, top: 4, bottom: 6),
                        child: Text('范围: 0 ≤ X 且 X+宽 ≤ 屏幕(${screenWidth.toStringAsFixed(0)}) 宽≥50', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: Row(
                          children: [
                            TextButton.icon(
                              onPressed: () { Navigator.pop(context); _flipCanvas(); },
                              icon: Icon(widget.canvas.isFlipped ? Icons.flip_to_front : Icons.flip_to_back, size: 18, color: Colors.blue),
                              label: Text(widget.canvas.isFlipped ? '正面' : '反面'),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '正:${widget.canvas.frontTextBoxIds.length + widget.canvas.frontImageBoxIds.length + widget.canvas.frontAudioBoxIds.length} 反:${widget.canvas.backTextBoxIds.length + widget.canvas.backImageBoxIds.length + widget.canvas.backAudioBoxIds.length}',
                                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () { Navigator.pop(context); if (widget.onSettingsPressed != null) widget.onSettingsPressed!(); },
                              icon: const Icon(Icons.delete, size: 18, color: Colors.red),
                              label: const Text('删除', style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
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
          final screenWidth = MediaQuery.of(context).size.width;
          widget.canvas.positionX = widget.canvas.positionX.clamp(0.0, screenWidth - widget.canvas.width);
          widget.onCanvasUpdated(widget.canvas);
        }
      },
      onPanEnd: widget.isPositionLocked ? null : (details) {
        _isDragging = false;
      },
      onDoubleTap: _flipCanvas,
      onLongPress: _showCanvasOptions,
      child: AnimatedBuilder(
        animation: _flipAnimation,
        builder: (context, child) {
          final isShowingFront = _flipAnimation.value < 0.5;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateY(_flipAnimation.value * math.pi),
            child: _buildCanvasSide(isShowingFront),
          );
        },
      ),
    );
  }

  Widget _buildCanvasSide(bool isShowingFront) {
    final bool shouldShowFront = isShowingFront == !widget.canvas.isFlipped;
    
    return Container(
      width: widget.canvas.width,
      height: widget.canvas.height,
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border.all(
          color: shouldShowFront ? Colors.blue[300]! : Colors.orange[300]!,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          const SizedBox.shrink(),
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
