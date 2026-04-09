import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class ResizableImageBox extends StatefulWidget {
  const ResizableImageBox({
    super.key,
    required this.initialSize,
    required this.imagePath,
    required this.onResize,
    this.onResizeEnd,
    required this.onSettingsPressed,
    this.isPositionLocked = true,
  });

  final Size initialSize;
  final String imagePath;
  final ValueChanged<Size> onResize;
  final ValueChanged<Size>? onResizeEnd;
  final VoidCallback onSettingsPressed;
  final bool isPositionLocked;

  @override
  State<ResizableImageBox> createState() => _ResizableImageBoxState();
}

class _ResizableImageBoxState extends State<ResizableImageBox> {
  late final ValueNotifier<Size> _sizeNotifier;
  double _contentAspectRatio = 1.0;

  @override
  void initState() {
    super.initState();
    _sizeNotifier = ValueNotifier<Size>(_normalizeSize(widget.initialSize));
    _loadContentAspectRatio();
  }

  @override
  void didUpdateWidget(covariant ResizableImageBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSize != widget.initialSize) {
      _sizeNotifier.value = _normalizeSize(widget.initialSize);
    }
    if (oldWidget.imagePath != widget.imagePath) {
      _contentAspectRatio = 1.0;
      _loadContentAspectRatio();
    }
  }

  @override
  void dispose() {
    _sizeNotifier.dispose();
    super.dispose();
  }

  Size _normalizeSize(Size size) {
    final width = size.width <= 0 ? 200.0 : size.width;
    final height = size.height <= 0 ? 200.0 : size.height;
    return Size(width, height);
  }

  Future<void> _loadContentAspectRatio() async {
    final path = widget.imagePath;
    if (path.isEmpty) return;
    try {
      final bytes = await File(path).readAsBytes();
      final image = await _decodeImage(bytes);
      if (!mounted || path != widget.imagePath) return;
      final width = image.width.toDouble();
      final height = image.height.toDouble();
      if (width > 0 && height > 0) {
        setState(() {
          _contentAspectRatio = width / height;
        });
      }
    } catch (_) {}
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }

  void _handleResize(DragUpdateDetails details) {
    if (widget.isPositionLocked) return;
    final current = _sizeNotifier.value;
    final nextWidth = (current.width + details.delta.dx).clamp(50.0, 2000.0);
    final nextHeight = (current.height + details.delta.dy).clamp(50.0, 2000.0);
    final nextSize = Size(nextWidth, nextHeight);
    _sizeNotifier.value = nextSize;
    widget.onResize(nextSize);
  }

  @override
  Widget build(BuildContext context) {
    final imageLayer = widget.imagePath.isNotEmpty
        ? IgnorePointer(
            child: RepaintBoundary(
              child: Image.file(
                key: ValueKey(widget.imagePath),
                File(widget.imagePath),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
              ),
            ),
          )
        : const Center(child: Text('点击左上角设置按钮更换图片'));

    return ValueListenableBuilder<Size>(
      valueListenable: _sizeNotifier,
      child: imageLayer,
      builder: (context, size, child) {
        return SizedBox(
          width: size.width,
          height: size.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: size.width,
                height: size.height,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: widget.imagePath.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: _contentAspectRatio,
                            child: child!,
                          ),
                        ),
                      )
                    : child!,
              ),
              Positioned(
                left: -10,
                top: -12,
                child: Opacity(
                  opacity: 0.35,
                  child: IconButton(
                    icon: const Icon(Icons.settings, size: 24),
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    iconSize: 20,
                    onPressed: widget.onSettingsPressed,
                    tooltip: '图片框设置',
                  ),
                ),
              ),
              Positioned(
                right: -6,
                bottom: -6,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: _handleResize,
                  onPanEnd: (_) =>
                      widget.onResizeEnd?.call(_sizeNotifier.value),
                  child: Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    child: Opacity(
                      opacity: widget.isPositionLocked ? 0.18 : 0.45,
                      child: const Icon(Icons.zoom_out_map, size: 20),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
