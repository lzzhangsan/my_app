import 'package:flutter/material.dart';

/// [showModalBottomSheet] 内容区：为系统导航条/手势条留出底部空间，并可滚动避免项过多时溢出。
///
/// 使用 [SafeArea] 且 [SafeArea.top] 为 false，避免顶部重复留白。
class SafeModalSheetScrollable extends StatelessWidget {
  const SafeModalSheetScrollable({
    super.key,
    required this.children,
    this.minimumBottom = 8,
  });

  final List<Widget> children;
  final double minimumBottom;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: EdgeInsets.only(bottom: minimumBottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}
