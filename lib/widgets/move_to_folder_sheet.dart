import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/media_type.dart';

/// 「移动到」面板中的一个可选目标。
class MoveSheetChoice {
  const MoveSheetChoice({
    required this.value,
    required this.label,
    this.isRoot = false,
    this.enabled = true,
  });

  /// 选中后回传的值（媒体页为文件夹 id；目录页根目录为 `''`，其余为文件夹名）。
  final String value;
  final String label;
  final bool isRoot;
  final bool enabled;
}

/// 半透明「移动到」底部面板：约屏高 85%、天蓝细线圈选项。
Future<String?> showMoveTargetSheet({
  required BuildContext context,
  required List<MoveSheetChoice> choices,
  int crossAxisCount = 2,
  /// 面板背景不透明度（1=完全不透明）。
  double panelOpacity = 0.5,
}) {
  final screenHeight = MediaQuery.of(context).size.height;
  final panelHeight = screenHeight * 0.85;
  const tileExtent = (44.0 * 1.2 + 4) * (2 / 3); // ~37.9
  final clampedOpacity = panelOpacity.clamp(0.0, 1.0);
  final columns = crossAxisCount.clamp(1, 4);

  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      Widget buildTile(MoveSheetChoice choice) {
        final enabled = choice.enabled;
        final content = Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  enabled
                      ? const Color(0xFF87CEEB)
                      : const Color(0xFF87CEEB).withValues(alpha: 0.35),
              width: 1.2,
            ),
            color: Colors.white.withValues(alpha: enabled ? 0.28 : 0.12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Icon(
                choice.isRoot ? Icons.folder_open : Icons.folder,
                size: 18,
                color: enabled ? Colors.black87 : Colors.black38,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  choice.label,
                  style: TextStyle(
                    fontSize: 13,
                    color: enabled ? Colors.black87 : Colors.black38,
                    fontWeight: FontWeight.w500,
                    height: 1.1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
            ],
          ),
        );

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap:
                enabled
                    ? () => Navigator.pop(sheetContext, choice.value)
                    : null,
            child: content,
          ),
        );
      }

      return Container(
        height: panelHeight,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: clampedOpacity),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 28,
              child: Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 28,
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: '取消',
                  onPressed: () => Navigator.pop(sheetContext),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: tileExtent,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 6,
                ),
                itemCount: choices.length,
                itemBuilder: (context, index) => buildTile(choices[index]),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 媒体库「移动到」：将 [MediaItem] 列表包装为 [showMoveTargetSheet]。
Future<MediaItem?> showMoveToFolderSheet({
  required BuildContext context,
  required List<MediaItem> folders,
  bool includeRoot = true,
  bool rootEnabled = true,
  double panelOpacity = 0.5,
  int crossAxisCount = 2,
}) async {
  final choices = <MoveSheetChoice>[
    if (includeRoot)
      MoveSheetChoice(
        value: 'root',
        label: '根目录',
        isRoot: true,
        enabled: rootEnabled,
      ),
    ...folders.map(
      (folder) => MoveSheetChoice(value: folder.id, label: folder.name),
    ),
  ];

  final selectedId = await showMoveTargetSheet(
    context: context,
    choices: choices,
    crossAxisCount: crossAxisCount,
    panelOpacity: panelOpacity,
  );
  if (selectedId == null) return null;
  if (selectedId == 'root') {
    return MediaItem(
      id: 'root',
      name: '根目录',
      path: '',
      type: MediaType.folder,
      directory: '',
      dateAdded: DateTime.now(),
    );
  }
  for (final folder in folders) {
    if (folder.id == selectedId) return folder;
  }
  return null;
}
