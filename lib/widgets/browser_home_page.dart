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

  @override
  Widget build(BuildContext context) {
    final bottomSafeInset = MediaQuery.of(context).padding.bottom;
    return ReorderableGridView.builder(
      padding: EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 16.0 + bottomSafeInset + 8.0),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 1.0,
        crossAxisSpacing: 16.0,
        mainAxisSpacing: 16.0,
      ),
      itemCount: commonWebsites.length + 1,
      itemBuilder: (context, index) {
        if (index == commonWebsites.length) {
          return InkWell(
            key: const ValueKey('add_website'),
            onTap: onAddWebsite,
            child: Card(
              elevation: 4.0,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.add_circle_outline, size: 40, color: Colors.green),
                  SizedBox(height: 8),
                  Text('添加网站', style: TextStyle(fontSize: 16), textAlign: TextAlign.center),
                ],
              ),
            ),
          );
        } else {
          final website = commonWebsites[index];
          final iconData = IconData(website['iconCode'] ?? Icons.web.codePoint, fontFamily: 'MaterialIcons');
          return InkWell(
            key: ValueKey(website['url']),
            onTap: () => onWebsiteTap(website['url']),
            onLongPress: () => onWebsiteLongPress(website, index),
            child: Card(
              elevation: 4.0,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(iconData, size: 40, color: Colors.blue),
                  const SizedBox(height: 8),
                  Text(website['name'], style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
                ],
              ),
            ),
          );
        }
      },
      onReorder: onReorder,
    );
  }
}
