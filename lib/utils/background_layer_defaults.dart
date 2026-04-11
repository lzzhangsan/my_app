import 'package:flutter/material.dart';

/// 背景「着色层」在未保存自定义颜色时的显示色。
///
/// 有背景图/视频时默认 **全透明**，避免上层默认不透明白挡住底图；无背景媒体时用
/// [fallbackWhenNoMedia]（文档/目录/日记一般为白，封面可为浅灰）。
Color backgroundTintLayerColor({
  required Color? stored,
  required bool hasBackgroundMedia,
  required Color fallbackWhenNoMedia,
}) {
  if (stored != null) return stored;
  return hasBackgroundMedia ? Colors.transparent : fallbackWhenNoMedia;
}

/// 颜色选择器初始色：无已保存颜色时用不透明白色，避免 [Colors.transparent] 在取色盘中呈现为黑色。
Color backgroundColorPickerSeed(Color? stored) => stored ?? Colors.white;
