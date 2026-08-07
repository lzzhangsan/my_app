import 'package:flutter/material.dart';
import 'core/service_locator.dart';
import 'services/browser_session_preview.dart';
import 'services/database_service.dart';
import 'services/logger.dart';

/// 媒体来源对话框中的一个可选条目。
class _MediaSourceChoice {
  const _MediaSourceChoice({
    required this.value,
    required this.label,
    required this.icon,
    this.subtitle,
    this.enabled = true,
    this.isReturnUp = false,
  });

  final String value;
  final String label;
  final IconData icon;
  final String? subtitle;
  final bool enabled;
  final bool isReturnUp;
}

/// 弹出底部大面板样式的「选择媒体来源」，返回选中的目录 id（含
/// [kMediaSourceBrowserLive] / 真实目录 id / 'root' 整个媒体库）。
///
/// 视觉与「移动到」面板保持一致：底部 85% 屏高、天蓝细边框卡片、
/// GridView 两列、右上角关闭按钮。
Future<String?> showMediaSourceSelectionSheet({
  required BuildContext context,
  required String? selectedDirectory,
  double panelOpacity = 0.8,
}) async {
  final screenHeight = MediaQuery.of(context).size.height;
  final panelHeight = screenHeight * 0.85;
  const tileExtent = (44.0 * 1.2 + 4) * (2 / 3);
  final clampedOpacity = panelOpacity.clamp(0.0, 1.0);
  const columns = 2;

  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return _MediaSourceSelectionBody(
        panelHeight: panelHeight,
        clampedOpacity: clampedOpacity,
        tileExtent: tileExtent,
        columns: columns,
        selectedDirectory: selectedDirectory,
      );
    },
  );
}

class _MediaSourceSelectionBody extends StatefulWidget {
  const _MediaSourceSelectionBody({
    required this.panelHeight,
    required this.clampedOpacity,
    required this.tileExtent,
    required this.columns,
    required this.selectedDirectory,
  });

  final double panelHeight;
  final double clampedOpacity;
  final double tileExtent;
  final int columns;
  final String? selectedDirectory;

  @override
  State<_MediaSourceSelectionBody> createState() =>
      _MediaSourceSelectionBodyState();
}

class _MediaSourceSelectionBodyState
    extends State<_MediaSourceSelectionBody> {
  List<Map<String, dynamic>> _folders = [];
  bool _isLoading = true;
  String _currentDirectory = 'root';
  late final DatabaseService _databaseService;

  @override
  void initState() {
    super.initState();
    _databaseService = getService<DatabaseService>();
    BrowserSessionPreview.instance.availabilityNotifier.addListener(
      _onBrowserAvailabilityChanged,
    );
    _loadFolders();
  }

  @override
  void dispose() {
    BrowserSessionPreview.instance.availabilityNotifier.removeListener(
      _onBrowserAvailabilityChanged,
    );
    super.dispose();
  }

  void _onBrowserAvailabilityChanged() {
    if (mounted) setState(() {});
  }

  bool _isSelected(String value) => widget.selectedDirectory == value;

  Future<void> _loadFolders() async {
    setState(() => _isLoading = true);
    try {
      final items = await _databaseService.getMediaItems(_currentDirectory);
      final folders = items.where((item) {
        final t = item['type'];
        final idx =
            t is int ? t : (t is num ? t.toInt() : int.tryParse('$t') ?? -1);
        return idx == 3; // MediaType.folder
      }).toList();
      setState(() {
        _folders = folders;
        _isLoading = false;
      });
    } catch (e) {
      Logger.e('加载媒体来源文件夹出错', e);
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载文件夹失败，请重试。')),
        );
      }
    }
  }

  Future<void> _navigateUp() async {
    if (_currentDirectory == 'root') return;
    final parent =
        await _databaseService.getMediaItemParentDirectory(_currentDirectory);
    setState(() => _currentDirectory = parent ?? 'root');
    await _loadFolders();
  }

  String _currentFolderLabel() {
    if (_currentDirectory == 'root') return '选择媒体来源';
    for (final f in _folders) {
      if (f['id']?.toString() == _currentDirectory) {
        return '选择媒体来源 / ${f['name']}';
      }
    }
    return '选择媒体来源 / ...';
  }

  Future<void> _enterFolder(Map<String, dynamic> folder) async {
    setState(() => _currentDirectory = folder['id']?.toString() ?? 'root');
    await _loadFolders();
  }

  @override
  Widget build(BuildContext context) {
    final contentBottomPad =
        MediaQuery.viewPaddingOf(context).bottom + 38;

    // 特殊项（仅 root 时显示：浏览器实时预览 + 整个媒体库）
    final specialChoices = <_MediaSourceChoice>[
      if (_currentDirectory == 'root')
        _MediaSourceChoice(
          value: kMediaSourceBrowserLive,
          label: '当前的浏览页面',
          icon: Icons.language,
          subtitle: BrowserSessionPreview.instance.isAvailable
              ? (BrowserSessionPreview.instance.pageUrl ??
                  '实时预览浏览器页面与下载进度')
              : '请从浏览器目录入口进入',
          enabled: BrowserSessionPreview.instance.isAvailable,
        ),
      if (_currentDirectory == 'root')
        _MediaSourceChoice(
          value: 'root',
          label: '整个媒体库',
          icon: Icons.library_music,
        ),
    ];

    // 返回上级（非 root 时作为第一个卡片显示）
    final returnUp = <_MediaSourceChoice>[
      if (_currentDirectory != 'root')
        const _MediaSourceChoice(
          value: '__navigate_up__',
          label: '返回上级',
          icon: Icons.arrow_upward,
          isReturnUp: true,
        ),
    ];

    // 真正的文件夹卡片：点击进入文件夹（而不是立即选中）——
    // 和旧 Dialog 行为一致：先一层层进入子目录，选中项用 tileColor 高亮。
    final folderChoices = _folders
        .map(
          (f) => _MediaSourceChoice(
            value: f['id']?.toString() ?? '',
            label: f['name']?.toString() ?? '未命名',
            icon: Icons.folder,
          ),
        )
        .toList();

    final allChoices = [
      ...specialChoices,
      ...returnUp,
      ...folderChoices,
    ];

    return Container(
      height: widget.panelHeight,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: widget.clampedOpacity),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                if (_currentDirectory != 'root')
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 28),
                    visualDensity: VisualDensity.compact,
                    tooltip: '返回上级',
                    onPressed: _navigateUp,
                    icon: const Icon(Icons.arrow_back, size: 20),
                  )
                else
                  const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _currentFolderLabel(),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 28),
                  visualDensity: VisualDensity.compact,
                  tooltip: '取消',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : allChoices.isEmpty
                    ? const Center(child: Text('没有可用的文件夹'))
                    : GridView.builder(
                        padding: EdgeInsets.fromLTRB(10, 0, 10, contentBottomPad),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: widget.columns,
                          mainAxisExtent: widget.tileExtent,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 6,
                        ),
                        itemCount: allChoices.length,
                        itemBuilder: (ctx, index) => _buildTile(
                          allChoices[index],
                          folderListMap: _folders,
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(
    _MediaSourceChoice choice, {
    required List<Map<String, dynamic>> folderListMap,
  }) {
    final selected = !choice.isReturnUp && _isSelected(choice.value);
    final enabled = choice.enabled;

    final borderColor =
        selected
            ? Colors.blue
            : (enabled
                ? const Color(0xFF87CEEB)
                : const Color(0xFF87CEEB).withValues(alpha: 0.35));

    final content = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 1.2),
        color:
            selected
                ? Colors.blue.withOpacity(0.12)
                : Colors.white.withValues(alpha: enabled ? 0.28 : 0.12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(
            choice.icon,
            size: 18,
            color:
                selected
                    ? Colors.blue
                    : (enabled ? Colors.black87 : Colors.black38),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              choice.label,
              style: TextStyle(
                fontSize: 13,
                color:
                    selected
                        ? Colors.blue
                        : (enabled ? Colors.black87 : Colors.black38),
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
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
            !enabled
                ? null
                : () {
                    // 1. 返回上级
                    if (choice.isReturnUp) {
                      _navigateUp();
                      return;
                    }
                    // 2. 真实文件夹：先判断是不是「进入子目录」还是「作为来源选中这个文件夹本身」
                    //    - 和旧 Dialog 保持一致逻辑：点击文件夹就立即作为来源选中（onDirectorySelected）
                    //    - 同时保留"如果还想一层层进入"的可能：用 onLongPress 进入子目录
                    Navigator.pop(context, choice.value);
                  },
        onLongPress:
            !enabled || choice.isReturnUp
                ? null
                : () {
                    // 长按文件夹 → 进入该目录查看子文件夹
                    final folder = folderListMap.firstWhere(
                      (f) => f['id']?.toString() == choice.value,
                      orElse: () => const {},
                    );
                    if (folder.isNotEmpty) _enterFolder(folder);
                  },
        child: Tooltip(
          message:
              choice.subtitle != null && choice.subtitle!.isNotEmpty
                  ? choice.subtitle!
                  : (choice.isReturnUp
                      ? '返回上一级文件夹'
                      : '短按：选中该文件夹作为媒体来源；长按：进入该文件夹查看子文件夹'),
          preferBelow: false,
          child: content,
        ),
      ),
    );
  }
}
