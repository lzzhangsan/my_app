import 'package:flutter/material.dart';

/// 一个简单的HomePage类，实际上在app中并未使用
/// 创建此文件只是为了解决import错误
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('首页'),
      ),
      body: Center(
        child: Text('这是首页，但实际上并未使用'),
      ),
    );
  }
} 