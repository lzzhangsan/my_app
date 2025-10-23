// lib/test_canvas_page.dart
// 测试画布功能的简化页面

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'widgets/flippable_canvas_widget.dart';
import 'models/flippable_canvas.dart';
import 'global_tool_bar.dart' as toolBar;

class TestCanvasPage extends StatefulWidget {
  @override
  _TestCanvasPageState createState() => _TestCanvasPageState();
}

class _TestCanvasPageState extends State<TestCanvasPage> {
  List<FlippableCanvas> _canvases = [];

  void _addNewCanvas() {
    setState(() {
      var uuid = Uuid();
      double screenWidth = MediaQuery.of(context).size.width;
      double screenHeight = MediaQuery.of(context).size.height;
      
      FlippableCanvas newCanvas = FlippableCanvas(
        id: uuid.v4(),
        documentName: 'test_document',
        positionX: screenWidth / 2 - 150,
        positionY: screenHeight / 2 - 100,
        width: 300.0,
        height: 200.0,
        isFlipped: false,
      );

      _canvases.add(newCanvas);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('画布已创建！双击画布可翻转，长按可查看设置'),
          duration: Duration(seconds: 3),
        ),
      );
    });
  }

  void _updateCanvas(FlippableCanvas canvas) {
    setState(() {
      int index = _canvases.indexWhere((c) => c.id == canvas.id);
      if (index != -1) {
        _canvases[index] = canvas;
      }
    });
  }

  void _deleteCanvas(String canvasId) {
    setState(() {
      _canvases.removeWhere((canvas) => canvas.id == canvasId);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('画布已删除')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('画布功能测试'),
        backgroundColor: Colors.blue,
      ),
      body: Stack(
        children: [
          // 背景
          Container(
            decoration: BoxDecoration(
              color: Colors.grey[100],
            ),
          ),
          // 画布列表
          ..._canvases.map<Widget>((canvas) {
            return Positioned(
              key: ValueKey(canvas.id),
              left: canvas.positionX,
              top: canvas.positionY,
              child: FlippableCanvasWidget(
                canvas: canvas,
                onCanvasUpdated: _updateCanvas,
                onSettingsPressed: () => _deleteCanvas(canvas.id),
                isPositionLocked: false,
              ),
            );
          }),
          // 说明文字
          if (_canvases.isEmpty)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.note_add,
                    size: 64,
                    color: Colors.grey[400],
                  ),
                  SizedBox(height: 16),
                  Text(
                    '三连击底部的+按钮来创建画布',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey[600],
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '双击画布可翻转\n长按画布可查看设置',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      bottomNavigationBar: toolBar.GlobalToolBar(
        onNewTextBox: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('单击: 新建文本框（在主应用中实现）')),
          );
        },
        onNewImageBox: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('双击: 新建图片框（在主应用中实现）')),
          );
        },
        onNewAudioBox: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('长按: 新建语音框（在主应用中实现）')),
          );
        },
        onNewCanvas: _addNewCanvas,
      ),
    );
  }
}