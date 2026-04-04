import 'dart:io';

import 'package:flutter/material.dart';

/// 图片从居中「横向填满」起，在 [animationDuration] 内线性放大到 [maxScale] 倍。
/// [onAnimationComplete] 在动画正常结束时调用（用于自动连播切换下一条）。
class KenBurnsImageDisplay extends StatefulWidget {
  const KenBurnsImageDisplay({
    super.key,
    required this.imageFile,
    required this.animationDuration,
    this.maxScale = 3.0,
    this.onAnimationComplete,
  });

  final File imageFile;
  final Duration animationDuration;
  final double maxScale;
  final VoidCallback? onAnimationComplete;

  @override
  State<KenBurnsImageDisplay> createState() => _KenBurnsImageDisplayState();
}

class _KenBurnsImageDisplayState extends State<KenBurnsImageDisplay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );
    _scale = Tween<double>(begin: 1.0, end: widget.maxScale).animate(
      CurvedAnimation(parent: _controller, curve: Curves.linear),
    );
    _controller.forward().then((_) {
      if (!mounted) return;
      widget.onAnimationComplete?.call();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) {
          return Transform.scale(
            scale: _scale.value,
            alignment: Alignment.center,
            child: child,
          );
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: Image.file(
                widget.imageFile,
                fit: BoxFit.fitWidth,
                alignment: Alignment.center,
              ),
            );
          },
        ),
      ),
    );
  }
}
