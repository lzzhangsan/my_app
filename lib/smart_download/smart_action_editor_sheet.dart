import 'package:flutter/material.dart';

import 'smart_action_parts.dart';

/// 编排下载动作：全屏编辑，零件库紧凑，序列区占主要空间。
Future<SmartActionRecipe?> showSmartActionEditor({
  required BuildContext context,
  required String host,
  SmartActionRecipe? initial,
  String title = '编排下载动作',
}) {
  return showGeneralDialog<SmartActionRecipe>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭编排',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, anim, secondary) {
      return _SmartActionEditorSheet(
        host: host,
        initial: initial,
        title: title,
      );
    },
    transitionBuilder: (ctx, anim, secondary, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _SmartActionEditorSheet extends StatefulWidget {
  const _SmartActionEditorSheet({
    required this.host,
    required this.initial,
    required this.title,
  });

  final String host;
  final SmartActionRecipe? initial;
  final String title;

  @override
  State<_SmartActionEditorSheet> createState() => _SmartActionEditorSheetState();
}

class _SmartActionEditorSheetState extends State<_SmartActionEditorSheet> {
  late final TextEditingController _nameController;
  late List<SmartActionStep> _steps;
  late String _editingId;
  SmartActionCategory _paletteCategory = SmartActionCategory.media;
  List<SmartActionRecipe> _hostRecipes = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final seed =
        widget.initial ??
        SmartActionRecipe(host: widget.host, name: '本站套路', steps: const []);
    _editingId = seed.id;
    _nameController = TextEditingController(text: seed.name);
    _steps = seed.steps.map((s) => s.copyWith()).toList();
    if (_steps.isEmpty) {
      _steps =
          SmartActionRecipe.feedTemplate(
            widget.host,
          ).steps.map((s) => s.copyWith()).toList();
    }
    _reloadLibrary();
  }

  Future<void> _reloadLibrary() async {
    final list = await SmartActionRecipeStore.loadForHost(widget.host);
    if (!mounted) return;
    setState(() {
      _hostRecipes = list;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _addStep(SmartActionKind kind) {
    setState(() => _steps.add(SmartActionStep(kind: kind)));
  }

  void _removeAt(int index) {
    setState(() => _steps.removeAt(index));
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _steps.removeAt(oldIndex);
      _steps.insert(newIndex, item);
    });
  }

  void _applyTemplate(SmartActionRecipe template) {
    setState(() {
      _steps = template.steps.map((s) => s.copyWith()).toList();
      if (_nameController.text.trim().isEmpty ||
          _nameController.text.trim() == '本站套路') {
        _nameController.text = template.name;
      }
    });
  }

  void _loadRecipe(SmartActionRecipe recipe) {
    setState(() {
      _editingId = recipe.id;
      _nameController.text = recipe.name;
      _steps = recipe.steps.map((s) => s.copyWith()).toList();
    });
  }

  void _newBlank() {
    final blank = SmartActionRecipe(
      host: widget.host,
      name: '新套路 ${_hostRecipes.length + 1}',
      steps: const [],
    );
    setState(() {
      _editingId = blank.id;
      _nameController.text = blank.name;
      _steps =
          SmartActionRecipe.feedTemplate(
            widget.host,
          ).steps.map((s) => s.copyWith()).toList();
    });
  }

  Future<void> _saveAsNew() async {
    final recipe = SmartActionRecipe(
      host: widget.host,
      name:
          _nameController.text.trim().isEmpty
              ? '本站套路'
              : '${_nameController.text.trim()} 副本',
      steps: List<SmartActionStep>.from(_steps),
      updatedAt: DateTime.now(),
    );
    await SmartActionRecipeStore.save(recipe);
    if (!mounted) return;
    setState(() {
      _editingId = recipe.id;
      _nameController.text = recipe.name;
    });
    await _reloadLibrary();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已另存为「${recipe.name}」')));
  }

  Future<void> _deleteCurrent() async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删除套路'),
            content: Text('确定删除「${_nameController.text}」？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    await SmartActionRecipeStore.deleteById(_editingId);
    if (!mounted) return;
    _newBlank();
    await _reloadLibrary();
  }

  Future<void> _submit({required bool startNow}) async {
    if (_steps.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请至少添加一个动作')));
      return;
    }
    if (!_steps.any((s) => s.kind == SmartActionKind.longPressDownload)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('建议加入「长按下载」，否则可能不会触发保存')),
      );
    }
    final recipe = SmartActionRecipe(
      id: _editingId,
      host: widget.host,
      name:
          _nameController.text.trim().isEmpty
              ? '本站套路'
              : _nameController.text.trim(),
      steps: List<SmartActionStep>.from(_steps),
      updatedAt: DateTime.now(),
    );
    await SmartActionRecipeStore.save(recipe);
    if (!mounted) return;
    if (startNow) {
      Navigator.pop(context, recipe);
    } else {
      await _reloadLibrary();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已保存「${recipe.name}」')));
    }
  }

  List<SmartActionKind> get _paletteKinds =>
      SmartActionKind.values
          .where((k) => k.category == _paletteCategory)
          .toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => _submit(startNow: false),
                    child: const Text('仅保存'),
                  ),
                  FilledButton(
                    onPressed: () => _submit(startNow: true),
                    child: const Text('保存并用此套路'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(
                '站点：${widget.host} · 可保存多套命名动作；上次使用的会自动带出。',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ),
            if (!_loading && _hostRecipes.isNotEmpty)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                  children: [
                    ..._hostRecipes.map((r) {
                      final selected = r.id == _editingId;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(r.name, style: const TextStyle(fontSize: 12)),
                          selected: selected,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => _loadRecipe(r),
                        ),
                      );
                    }),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 14),
                      label: const Text('新建', style: TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: _newBlank,
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: '套路名称',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  suffixIcon: IconButton(
                    tooltip: '删除当前套路',
                    onPressed: _deleteCurrent,
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ActionChip(
                      label: const Text('列表下一条', style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          () => _applyTemplate(
                            SmartActionRecipe.feedTemplate(widget.host),
                          ),
                    ),
                    const SizedBox(width: 4),
                    ActionChip(
                      label: const Text('沉浸流', style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          () => _applyTemplate(
                            SmartActionRecipe.immersiveTemplate(widget.host),
                          ),
                    ),
                    const SizedBox(width: 4),
                    ActionChip(
                      label: const Text('详情进出', style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          () => _applyTemplate(
                            SmartActionRecipe.detailTemplate(widget.host),
                          ),
                    ),
                    const SizedBox(width: 4),
                    ActionChip(
                      label: const Text('另存为', style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      onPressed: _saveAsNew,
                    ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '执行序列（长按拖动排序）',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ),
            Expanded(
              child:
                  _steps.isEmpty
                      ? const Center(child: Text('还没有动作，请从下方零件库添加'))
                      : ReorderableListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                        itemCount: _steps.length,
                        onReorder: _reorder,
                        itemBuilder: (context, index) {
                          final step = _steps[index];
                          return Card(
                            key: ValueKey(step.id),
                            margin: const EdgeInsets.only(bottom: 6),
                            child: ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: CircleAvatar(
                                radius: 14,
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              title: Text(
                                step.kind.label,
                                style: const TextStyle(fontSize: 14),
                              ),
                              subtitle: Text(
                                step.kind.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '删除',
                                    icon: const Icon(Icons.delete_outline, size: 20),
                                    onPressed: () => _removeAt(index),
                                  ),
                                  const Icon(Icons.drag_handle, size: 20),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '零件库 · ${_paletteCategory.label}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
              child: Row(
                children:
                    SmartActionCategory.values
                        .map(
                          (cat) => Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text(
                                cat.label,
                                style: const TextStyle(fontSize: 11),
                              ),
                              selected: _paletteCategory == cat,
                              visualDensity: VisualDensity.compact,
                              onSelected:
                                  (_) =>
                                      setState(() => _paletteCategory = cat),
                            ),
                          ),
                        )
                        .toList(),
              ),
            ),
            SizedBox(
              height: 78,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                children:
                    _paletteKinds
                        .map(
                          (kind) => Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: InkWell(
                              onTap: () => _addStep(kind),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                width: 96,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.black12),
                                  borderRadius: BorderRadius.circular(8),
                                  color: Colors.grey.shade50,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(kind.icon, size: 18),
                                    const SizedBox(height: 4),
                                    Text(
                                      kind.label,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        height: 1.15,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
