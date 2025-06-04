// resizable_image_box.dart
import 'package:flutter/material.dart';
import 'dart:io';

class ResizableImageBox extends StatefulWidget {
  final Size initialSize;
  final String imagePath;
  final Function(Size) onResize;
  final Function() onSettingsPressed;

  const ResizableImageBox({
    super.key,
    required this.initialSize,
    required this.imagePath,
    required this.onResize,
    required this.onSettingsPressed,
  });

  @override
  _ResizableImageBoxState createState() => _ResizableImageBoxState();
}

class _ResizableImageBoxState extends State<ResizableImageBox> {
  late Size _size;

  @override
  void initState() {
    super.initState();
    _size = widget.initialSize;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          width: _size.width,
          height: _size.height,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black),
            borderRadius: BorderRadius.circular(10), // 添加圆角
          ),
          child: widget.imagePath.isNotEmpty
              ? ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(widget.imagePath),
              fit: BoxFit.cover,
            ),
          )
              : Center(child: Text('点击左上角设置按钮更改图片')),
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
              onPressed: widget.onSettingsPressed,
              tooltip: '图片框设置',
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
              if (newWidth >= 50 && newHeight >= 50) {
                setState(() {
                  _size = Size(newWidth, newHeight);
                });
                widget.onResize(_size);
              }
            },
            child: Opacity(
              opacity: 0.25,
              child: Icon(
                Icons.zoom_out_map,
                size: 20,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
