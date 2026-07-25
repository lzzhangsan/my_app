import 'package:flutter/material.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

class BrowserHomePage extends StatelessWidget {
  final List<Map<String, dynamic>> commonWebsites;
  final Function(String url) onWebsiteTap;
  final Function(Map<String, dynamic> website, int index) onWebsiteLongPress;
  final VoidCallback onAddWebsite;
  final ReorderCallback onReorder;

  const BrowserHomePage({
    Key? key,
    required this.commonWebsites,
    required this.onWebsiteTap,
    required this.onWebsiteLongPress,
    required this.onAddWebsite,
    required this.onReorder,
  }) : super(key: key);

  static const _radius = 14.0;

  static const List<Color> _candyColors = [
    Color(0xFFFFE4D6), // 蜜桃
    Color(0xFFD8F3E8), // 薄荷
    Color(0xFFE8E0F5), // 淡紫
    Color(0xFFFFF3C9), // 柠檬
    Color(0xFFD6ECFA), // 天空
    Color(0xFFF9DCE8), // 玫瑰
    Color(0xFFFFE8CC), // 杏橙
    Color(0xFFD5F0EE), // 海盐
  ];

  @override
  Widget build(BuildContext context) {
    final bottomSafeInset = MediaQuery.of(context).padding.bottom;
    return ColoredBox(
      color: Colors.white,
      child: ReorderableGridView.builder(
        padding: EdgeInsets.fromLTRB(
          14.0,
          14.0,
          14.0,
          14.0 + bottomSafeInset + 8.0,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          childAspectRatio: 1.15,
          crossAxisSpacing: 10.0,
          mainAxisSpacing: 10.0,
        ),
        itemCount: commonWebsites.length + 1,
        itemBuilder: (context, index) {
          if (index == commonWebsites.length) {
            return _candyShell(
              key: const ValueKey('add_website'),
              color: const Color(0xFFF4F5F7),
              isAdd: true,
              onTap: onAddWebsite,
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_rounded, size: 20, color: Color(0xFF8B93A7)),
                  SizedBox(height: 2),
                  Text(
                    '添加',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF8B93A7),
                      letterSpacing: 0.2,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }
          final website = commonWebsites[index];
          final color = _candyColors[index % _candyColors.length];
          return _candyShell(
            key: ValueKey(website['url']),
            color: color,
            onTap: () => onWebsiteTap(website['url']),
            onLongPress: () => onWebsiteLongPress(website, index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
              child: Center(
                child: Text(
                  website['name']?.toString() ?? '',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                    letterSpacing: 0.15,
                    color: Color(0xFF5A5568),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          );
        },
        onReorder: onReorder,
      ),
    );
  }

  Widget _candyShell({
    required Key key,
    required Color color,
    required Widget child,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool isAdd = false,
  }) {
    return Material(
      key: key,
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(_radius),
        splashColor: color.withValues(alpha: 0.35),
        highlightColor: color.withValues(alpha: 0.2),
        child: Ink(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(
              color: isAdd ? const Color(0xFFD0D5DD) : color.withValues(alpha: 0.85),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.45),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
