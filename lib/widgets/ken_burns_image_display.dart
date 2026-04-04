import 'dart:io';

import 'package:flutter/material.dart';

import 'image_layout_utils.dart';

/// 初次：横向铺满屏幕宽度、纵向等比例居中；上下留白为同图模糊（非纯色条）。
/// 仅使用等比缩放（Transform.scale），图片用 BoxFit.fitWidth，不拉伸变形。
/// [loop] 为 true 时（手动模式）动画结束自动从头循环。
class KenBurnsImageDisplay extends StatefulWidget {
  const KenBurnsImageDisplay({
    super.key,
    required this.imageFile,
    required this.animationDuration,
    this.maxScale = 3.0,
    this.loop = false,
    this.onAnimationComplete,
  });

  final File imageFile;
  final Duration animationDuration;
  final double maxScale;
  final bool loop;
  final VoidCallback? onAnimationComplete;

  @override
  State<KenBurnsImageDisplay> createState() => _KenBurnsImageDisplayState();
}

class _KenBurnsImageDisplayState extends State<KenBurnsImageDisplay>
    with SingleTickerProviderStateMixin {
  late Future<Size> _sizeFuture;
  late AnimationController _controller;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _sizeFuture = measureImageFileSize(widget.imageFile);
    _controller = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: widget.maxScale).animate(
      CurvedAnimation(parent: _controller, curve: Curves.linear),
    );
    _controller.addStatusListener(_onStatus);
    _controller.forward();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (widget.loop) {
      _controller.reset();
      _controller.forward();
    } else {
      widget.onAnimationComplete?.call();
    }
  }

  @override
  void didUpdateWidget(KenBurnsImageDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageFile.path != widget.imageFile.path) {
      _sizeFuture = measureImageFileSize(widget.imageFile);
    }
    if (oldWidget.animationDuration != widget.animationDuration) {
      _controller.duration = widget.animationDuration;
    }
    if (oldWidget.maxScale != widget.maxScale) {
      _scaleAnim = Tween<double>(begin: 1.0, end: widget.maxScale).animate(
        CurvedAnimation(parent: _controller, curve: Curves.linear),
      );
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size>(
      future: _sizeFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ColoredBox(
            color: Colors.grey.shade900,
            child: Center(
              child: Text(
                '无法读取图片',
                style: TextStyle(color: Colors.grey.shade400),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final pixelSize = snapshot.data!;
        return LayoutBuilder(
          builder: (context, constraints) {
            final vw = constraints.maxWidth;
            final disp = fitWidthDisplaySize(pixelSize, vw);
            final dw = disp.width;
            final dh = disp.height;
            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: [
                  blurredCoverBackground(widget.imageFile),
                  AnimatedBuilder(
                    animation: _scaleAnim,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _scaleAnim.value,
                        alignment: Alignment.center,
                        child: child,
                      );
                    },
                    child: SizedBox(
                      width: dw,
                      height: dh,
                      child: Image.file(
                        widget.imageFile,
                        fit: BoxFit.fitWidth,
                        alignment: Alignment.center,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
