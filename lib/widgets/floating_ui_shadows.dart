import 'package:flutter/material.dart';

/// 悬浮控制：不使用渐变/通栏衬底时，白字与白图标在亮、暗背景上仍可辨认。
class FloatingUiShadows {
  FloatingUiShadows._();

  static const List<Shadow> whiteIcon = [
    Shadow(color: Color(0xD9000000), blurRadius: 10, offset: Offset(0, 1.2)),
    Shadow(color: Color(0x73000000), blurRadius: 2, offset: Offset(0, 0)),
  ];

  static const List<Shadow> whiteLabel = [
    Shadow(color: Color(0xD9000000), blurRadius: 8, offset: Offset(0, 1)),
    Shadow(color: Color(0x80000000), blurRadius: 2, offset: Offset(0, 0)),
  ];

  /// 浅色底（如默认白底）上的深色图标：浅色描边 + 深色影，避免与背景糊在一起。
  static const List<Shadow> darkOnLightIcon = [
    Shadow(color: Color(0x73FFFFFF), blurRadius: 6, offset: Offset(0, 1)),
    Shadow(color: Color(0xA0000000), blurRadius: 4, offset: Offset(0, 0.5)),
  ];

  static const List<Shadow> darkOnLightLabel = [
    Shadow(color: Color(0x80FFFFFF), blurRadius: 4, offset: Offset(0, 0.5)),
    Shadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 0)),
  ];
}

/// 无通栏顶栏时：有背景图或深色底用浅色前景，否则用深色前景（适配白底）。
class FloatingUiBarStyle {
  FloatingUiBarStyle._();

  static bool preferLightForeground({
    required bool hasBackgroundImage,
    Color? backgroundSolidColor,
  }) {
    if (hasBackgroundImage) return true;
    final c = backgroundSolidColor;
    if (c == null) return false;
    return c.computeLuminance() < 0.45;
  }

  static Color iconColor(bool lightFg) =>
      lightFg ? Colors.white : const Color(0xE6000000);

  static List<Shadow> iconShadow(bool lightFg) =>
      lightFg ? FloatingUiShadows.whiteIcon : FloatingUiShadows.darkOnLightIcon;

  static TextStyle titleStyle(
    bool lightFg, {
    double fontSize = 16,
    FontWeight fontWeight = FontWeight.w500,
  }) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: lightFg ? Colors.white : const Color(0xE6000000),
      shadows: lightFg ? FloatingUiShadows.whiteLabel : FloatingUiShadows.darkOnLightLabel,
    );
  }
}
