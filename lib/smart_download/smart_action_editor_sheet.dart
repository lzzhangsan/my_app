import 'package:flutter/material.dart';

import 'smart_action_parts.dart';

/// 编排下载动作：全屏编辑，零件库紧凑，序列区占主要空间。
/// [onVerifySteps]：在当前网页上实际跑一步/多步，返回可读结果文案。
Future<SmartActionRecipe?> showSmartActionEditor({
  required BuildContext context,
  required String host,
  SmartActionRecipe? initial,
  String title = '编排下载动作',
  Future<String> Function(List<SmartActionStep> steps)? onVerifySteps,
}) {
  return showGeneralDialog<SmartActionRecipe>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭编排',
    // 屏障透明：验证零件时由编辑器自行收起面板，才能看到底下真实网页
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, anim, secondary) {
      return _SmartActionEditorSheet(
        host: host,
        initial: initial,
        title: title,
        onVerifySteps: onVerifySteps,
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
    this.onVerifySteps,
  });

  final String host;
  final SmartActionRecipe? initial;
  final String title;
  final Future<String> Function(List<SmartActionStep> steps)? onVerifySteps;

  @override
  State<_SmartActionEditorSheet> createState() => _SmartActionEditorSheetState();
}

class _SmartActionEditorSheetState extends State<_SmartActionEditorSheet> {
  late final TextEditingController _nameController;
  late List<SmartActionStep> _steps;
  late String _editingId;
  SmartActionCategory _paletteCategory = SmartActionCategory.gesture;
  List<SmartActionRecipe> _hostRecipes = const [];
  bool _loading = true;
  bool _probing = false;
  String _probeStatus = '';

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
      final template = SmartActionRecipe.feedTemplate(widget.host);
      _steps = template.steps.map((s) => s.copyWith()).toList();
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

  bool _stepHasTunableParams(SmartActionKind kind) {
    switch (kind) {
      case SmartActionKind.flickUp:
      case SmartActionKind.flickDown:
      case SmartActionKind.flickLeft:
      case SmartActionKind.flickRight:
      case SmartActionKind.scrollPageUp:
      case SmartActionKind.scrollPageDown:
      case SmartActionKind.scrollPageLeft:
      case SmartActionKind.scrollPageRight:
      case SmartActionKind.findNextMedia:
      case SmartActionKind.findPrevMedia:
      case SmartActionKind.findNextMediaRight:
      case SmartActionKind.findPrevMediaLeft:
      case SmartActionKind.waitBrief:
      case SmartActionKind.waitDownload:
        return true;
      default:
        return false;
    }
  }

  bool _isSwitchMediaKind(SmartActionKind kind) {
    return kind == SmartActionKind.findNextMedia ||
        kind == SmartActionKind.findPrevMedia ||
        kind == SmartActionKind.findNextMediaRight ||
        kind == SmartActionKind.findPrevMediaLeft;
  }

  String _stepParamHint(SmartActionStep step) {
    switch (step.kind) {
      case SmartActionKind.flickUp:
      case SmartActionKind.flickDown:
      case SmartActionKind.flickLeft:
      case SmartActionKind.flickRight:
        final f = step.paramDouble(
          'distanceFraction',
          step.kind == SmartActionKind.flickLeft ||
                  step.kind == SmartActionKind.flickRight
              ? 0.50
              : 0.34,
        );
        final ms = step.paramInt(
          'durationMs',
          step.kind == SmartActionKind.flickLeft ||
                  step.kind == SmartActionKind.flickRight
              ? 380
              : 280,
        );
        return '仅轻扫距离 ${(f * 100).round()}% · ${ms}ms（不保证切条）';
      case SmartActionKind.findNextMedia:
      case SmartActionKind.findPrevMedia:
      case SmartActionKind.findNextMediaRight:
      case SmartActionKind.findPrevMediaLeft:
        final n = step.paramInt(
          'maxAttempts',
          step.kind == SmartActionKind.findNextMediaRight ||
                  step.kind == SmartActionKind.findPrevMediaLeft
              ? 1
              : 4,
        );
        final f = step.paramDouble(
          'distanceFraction',
          step.kind == SmartActionKind.findNextMediaRight ||
                  step.kind == SmartActionKind.findPrevMediaLeft
              ? 0.50
              : 0.34,
        );
        return '校验切换 · 最多重试 $n 次 · 起始距离 ${(f * 100).round()}%';
      case SmartActionKind.scrollPageUp:
      case SmartActionKind.scrollPageDown:
      case SmartActionKind.scrollPageLeft:
      case SmartActionKind.scrollPageRight:
        final f = step.paramDouble('fraction', 0.85);
        return '约 ${(f * 100).round()}% 屏 · 点验证可单独试';
      case SmartActionKind.waitBrief:
        return '等待 ${step.paramInt('ms', 1000)}ms · 点验证可单独试';
      case SmartActionKind.waitDownload:
        if (step.waitMode == 'fixed') {
          return '最多等 ${step.waitSeconds}s，入库成功则提前切条 · 点 ✎ 可改';
        }
        return '媒体库确认后再切条 · 点 ✎ 可改等待方式';
      default:
        return '${step.kind.subtitle} · 点 ▶ 验证';
    }
  }

  Future<void> _editStepParams(int index) async {
    final step = _steps[index];
    if (!_stepHasTunableParams(step.kind)) return;
    // 用 StatefulWidget 托管 TextEditingController：showDialog 返回时退场动画
    // 可能尚未结束，此时 dispose controller 会触发 InheritedWidget 断言红屏。
    final result = await showDialog<_EditStepParamsResult>(
      context: context,
      builder: (ctx) => _EditStepParamsDialog(
        step: step,
        isSwitchMedia: _isSwitchMediaKind(step.kind),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      final params = Map<String, dynamic>.from(step.params);
      if (step.kind == SmartActionKind.waitBrief) {
        params['ms'] = result.waitMs;
      } else if (step.kind == SmartActionKind.waitDownload) {
        params['waitMode'] =
            result.waitMode == 'fixed' ? 'fixed' : 'library';
        params['waitSeconds'] = result.waitSeconds.clamp(1, 600);
      } else if (step.kind == SmartActionKind.scrollPageUp ||
          step.kind == SmartActionKind.scrollPageDown ||
          step.kind == SmartActionKind.scrollPageLeft ||
          step.kind == SmartActionKind.scrollPageRight) {
        params['fraction'] = result.fraction;
        params['distanceFraction'] = result.fraction;
      } else if (_isSwitchMediaKind(step.kind)) {
        params['maxAttempts'] = result.maxAttempts;
        params['distanceFraction'] = result.distance;
        params['durationMs'] = result.duration;
      } else {
        params['distanceFraction'] = result.distance;
        params['durationMs'] = result.duration;
      }
      _steps[index] = step.copyWith(params: params);
    });
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
          _nameController.text.contains('套路') ||
          _nameController.text.contains('核心') ||
          _nameController.text.contains('验证')) {
        _nameController.text = template.name;
      }
    });
  }

  void _newBlank() {
    final blank = SmartActionRecipe(
      host: widget.host,
      name: '本站套路',
      steps: SmartActionRecipe.feedTemplate(widget.host).steps,
    );
    setState(() {
      _editingId = blank.id;
      _nameController.text = blank.name;
      _steps = blank.steps.map((s) => s.copyWith()).toList();
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

  SmartActionRecipe _buildCurrentRecipe() {
    return SmartActionRecipe(
      id: _editingId,
      host: widget.host,
      name:
          _nameController.text.trim().isEmpty
              ? '本站套路'
              : _nameController.text.trim(),
      steps: List<SmartActionStep>.from(_steps),
      updatedAt: DateTime.now(),
    );
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
    final recipe = _buildCurrentRecipe();
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

  /// 将当前编辑套路覆盖为「沿用套路」本站默认（无需等下次实跑成功）。
  Future<void> _overwriteAsSiteDefault() async {
    if (_steps.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请至少添加一个动作')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('覆盖为本站默认套路'),
            content: Text(
              '将「${_nameController.text.trim().isEmpty ? '本站套路' : _nameController.text.trim()}」'
              '设为「沿用套路」的本站默认，写入全局成功列表（可跨站借用），并覆盖上一套本站默认。\n'
              '不影响 X / 91 等内置管线。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('覆盖'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    final recipe = _buildCurrentRecipe();
    await SmartActionRecipeStore.markLastSuccess(
      recipe,
      defaultForHost: widget.host,
    );
    if (!mounted) return;
    await _reloadLibrary();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已覆盖为本站默认套路「${recipe.name}」')),
    );
  }

  Future<void> _runVerify(List<SmartActionStep> steps, {required String label}) async {
    final probe = widget.onVerifySteps;
    if (probe == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前环境未接入验证（请从智能下载入口打开编排）')),
      );
      return;
    }
    if (_probing) return;
    if (steps.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有可验证的动作')));
      return;
    }
    setState(() {
      _probing = true;
      _probeStatus = '正在验证：$label';
    });
    String result;
    try {
      result = await probe(steps);
    } catch (e) {
      result = '验证异常：$e';
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeStatus = '';
    });
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text('验证结果 · $label'),
            content: SingleChildScrollView(
              child: Text(
                result.trim().isEmpty ? '已执行，请观察页面是否有实际变化。' : result,
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
              ),
            ],
          ),
    );
  }

  Future<void> _verifyStepAt(int index) async {
    if (index < 0 || index >= _steps.length) return;
    final step = _steps[index];
    await _runVerify([step.copyWith()], label: step.kind.label);
  }

  Future<void> _verifyPaletteCategory() async {
    final kinds = _paletteKinds;
    final steps = kinds.map((k) => SmartActionStep(kind: k)).toList();
    await _runVerify(steps, label: '本类「${_paletteCategory.label}」');
  }

  Future<void> _verifyWholeSequence() async {
    await _runVerify(
      _steps.map((s) => s.copyWith()).toList(),
      label: '整段序列',
    );
  }

  List<SmartActionKind> get _paletteKinds =>
      SmartActionKind.values
          .where((k) => k.category == _paletteCategory)
          .toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 验证时收起面板，只留底部提示，露出网页观察真实效果
    if (_probing) {
      return Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.greenAccent.withValues(alpha: 0.55),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _probeStatus.isEmpty ? '正在当前页验证动作…' : _probeStatus,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.black54,
      child: SafeArea(
        child: Material(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          clipBehavior: Clip.antiAlias,
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
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _overwriteAsSiteDefault,
                  icon: const Icon(Icons.bookmark_added_outlined, size: 18),
                  label: const Text(
                    '覆盖为本站默认套路',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(
                '站点：${widget.host} · 核心循环＝长按下载 → 上切/左切下一条（会校验是否真切走）→ 再长按。'
                '「轻扫」只滑距离；「上切/左切」才保证换媒体。零件可点 ▶ 验证。'
                '「覆盖为本站默认套路」会立刻替换「沿用套路」自动选用；下次动作编排真实成功也会覆盖。',
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
                          onSelected: (_) {
                            setState(() {
                              _editingId = r.id;
                              _nameController.text = r.name;
                              _steps = r.steps.map((s) => s.copyWith()).toList();
                            });
                          },
                        ),
                      );
                    }),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: '套路名称',
                  border: const OutlineInputBorder(),
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
                      label: const Text('长按→上切', style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          () => _applyTemplate(
                            SmartActionRecipe.feedTemplate(widget.host),
                          ),
                    ),
                    const SizedBox(width: 4),
                    ActionChip(
                      label: const Text('长按→左切', style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          () => _applyTemplate(
                            SmartActionRecipe.feedLeftTemplate(widget.host),
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
                    const SizedBox(width: 4),
                    ActionChip(
                      avatar: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('验证整段', style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          widget.onVerifySteps == null ? null : _verifyWholeSequence,
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
                  '执行序列（长按拖动排序 · ▶ 单独验证）',
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
                              onTap:
                                  _stepHasTunableParams(step.kind)
                                      ? () => _editStepParams(index)
                                      : () => _verifyStepAt(index),
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
                                _stepParamHint(step),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '在当前页验证这一步',
                                    icon: const Icon(
                                      Icons.play_circle_outline,
                                      size: 22,
                                    ),
                                    onPressed:
                                        widget.onVerifySteps == null
                                            ? null
                                            : () => _verifyStepAt(index),
                                  ),
                                  if (_stepHasTunableParams(step.kind))
                                    IconButton(
                                      tooltip: '调整参数',
                                      icon: const Icon(Icons.tune, size: 20),
                                      onPressed: () => _editStepParams(index),
                                    ),
                                  IconButton(
                                    tooltip: '删除',
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 20,
                                    ),
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
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '零件库 · ${_paletteCategory.label}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed:
                        widget.onVerifySteps == null
                            ? null
                            : _verifyPaletteCategory,
                    icon: const Icon(Icons.science_outlined, size: 16),
                    label: Text(
                      '验证本类',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ],
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
                              onLongPress:
                                  widget.onVerifySteps == null
                                      ? null
                                      : () => _runVerify(
                                        [SmartActionStep(kind: kind)],
                                        label: kind.label,
                                      ),
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
                                    Row(
                                      children: [
                                        Icon(kind.icon, size: 18),
                                        const Spacer(),
                                        if (widget.onVerifySteps != null)
                                          GestureDetector(
                                            onTap: () => _runVerify(
                                              [SmartActionStep(kind: kind)],
                                              label: kind.label,
                                            ),
                                            child: const Icon(
                                              Icons.play_arrow,
                                              size: 16,
                                              color: Colors.black54,
                                            ),
                                          ),
                                      ],
                                    ),
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
      ),
    );
  }
}

class _EditStepParamsResult {
  const _EditStepParamsResult({
    required this.distance,
    required this.fraction,
    required this.duration,
    required this.waitMs,
    required this.maxAttempts,
    required this.waitMode,
    required this.waitSeconds,
  });

  final double distance;
  final double fraction;
  final int duration;
  final int waitMs;
  final int maxAttempts;
  final String waitMode;
  final int waitSeconds;
}

/// 步骤参数弹窗：自行托管 TextEditingController，在 State.dispose 中释放，
/// 避免 showDialog Future 返回后立即 dispose 导致退场动画期间红屏。
class _EditStepParamsDialog extends StatefulWidget {
  const _EditStepParamsDialog({
    required this.step,
    required this.isSwitchMedia,
  });

  final SmartActionStep step;
  final bool isSwitchMedia;

  @override
  State<_EditStepParamsDialog> createState() => _EditStepParamsDialogState();
}

class _EditStepParamsDialogState extends State<_EditStepParamsDialog> {
  late double _distance;
  late double _fraction;
  late int _duration;
  late int _waitMs;
  late int _maxAttempts;
  late String _waitMode;
  late int _waitSeconds;
  late final TextEditingController _customSecondsController;

  @override
  void initState() {
    super.initState();
    final step = widget.step;
    _distance = step.paramDouble('distanceFraction', 0.34);
    _fraction = step.paramDouble('fraction', 0.85);
    _duration = step.paramInt('durationMs', 280);
    _waitMs = step.paramInt('ms', 1000);
    _maxAttempts = step.paramInt('maxAttempts', 4);
    _waitMode = step.waitMode;
    _waitSeconds = step.waitSeconds;
    _customSecondsController = TextEditingController(text: '$_waitSeconds');
  }

  @override
  void dispose() {
    _customSecondsController.dispose();
    super.dispose();
  }

  void _applyWaitSeconds(int seconds) {
    setState(() {
      _waitSeconds = seconds.clamp(1, 600);
      _customSecondsController.text = '$_waitSeconds';
    });
  }

  void _confirm() {
    if (_waitMode == 'fixed') {
      final n = int.tryParse(_customSecondsController.text.trim());
      if (n != null && n >= 1) {
        _waitSeconds = n.clamp(1, 600);
      }
    }
    FocusScope.of(context).unfocus();
    Navigator.pop(
      context,
      _EditStepParamsResult(
        distance: _distance,
        fraction: _fraction,
        duration: _duration,
        waitMs: _waitMs,
        maxAttempts: _maxAttempts,
        waitMode: _waitMode,
        waitSeconds: _waitSeconds.clamp(1, 600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final isFlick =
        step.kind == SmartActionKind.flickUp ||
        step.kind == SmartActionKind.flickDown ||
        step.kind == SmartActionKind.flickLeft ||
        step.kind == SmartActionKind.flickRight;
    final isPage =
        step.kind == SmartActionKind.scrollPageUp ||
        step.kind == SmartActionKind.scrollPageDown ||
        step.kind == SmartActionKind.scrollPageLeft ||
        step.kind == SmartActionKind.scrollPageRight;
    final isWait = step.kind == SmartActionKind.waitBrief;
    final isWaitDownload = step.kind == SmartActionKind.waitDownload;
    final isHorizontalSwitch =
        step.kind == SmartActionKind.findNextMediaRight ||
        step.kind == SmartActionKind.findPrevMediaLeft;
    final isHorizontalFlick =
        step.kind == SmartActionKind.flickLeft ||
        step.kind == SmartActionKind.flickRight;
    final switchMaxDistance = isHorizontalSwitch ? 0.92 : 0.7;
    final flickMaxDistance = isHorizontalFlick ? 0.92 : 0.7;

    return AlertDialog(
      title: Text('调整 · ${step.kind.label}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.isSwitchMedia) ...[
              const Text(
                '目标：真正切换到相邻媒体（会校验是否换了）。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 8),
              Text('最多重试：$_maxAttempts 次'),
              Slider(
                value: _maxAttempts.toDouble(),
                min: 1,
                max: 8,
                divisions: 7,
                onChanged: (v) => setState(() => _maxAttempts = v.round()),
              ),
              Text(
                '起始轻扫距离：${(_distance * 100).round()}%'
                '${isHorizontalSwitch ? '（左/右可近整屏）' : ''}（失败会自动加大）',
              ),
              Slider(
                value: _distance.clamp(0.22, switchMaxDistance),
                min: 0.22,
                max: switchMaxDistance,
                onChanged: (v) => setState(() => _distance = v),
              ),
              Text('单次轻扫时长：${_duration}ms'),
              Slider(
                value: _duration.toDouble().clamp(180, 600),
                min: 180,
                max: 600,
                divisions: 21,
                onChanged: (v) => setState(() => _duration = v.round()),
              ),
            ],
            if (isFlick) ...[
              Text(
                '轻扫距离：${(_distance * 100).round()}%'
                '${isHorizontalFlick ? '（左/右可近整屏）' : ''}（不校验是否切条）',
              ),
              Slider(
                value: _distance.clamp(0.18, flickMaxDistance),
                min: 0.18,
                max: flickMaxDistance,
                onChanged: (v) => setState(() => _distance = v),
              ),
              Text('轻扫时长：${_duration}ms'),
              Slider(
                value: _duration.toDouble().clamp(160, 600),
                min: 160,
                max: 600,
                divisions: 22,
                onChanged: (v) => setState(() => _duration = v.round()),
              ),
            ],
            if (isPage) ...[
              Text('滚动比例：${(_fraction * 100).round()}%'),
              Slider(
                value: _fraction,
                min: 0.5,
                max: 1.0,
                onChanged: (v) => setState(() => _fraction = v),
              ),
            ],
            if (isWait) ...[
              Text('等待：${_waitMs}ms'),
              Slider(
                value: _waitMs.toDouble(),
                min: 300,
                max: 5000,
                divisions: 47,
                onChanged: (v) => setState(() => _waitMs = v.round()),
              ),
            ],
            if (isWaitDownload) ...[
              const Text(
                '长按下载后，用哪种方式再切下一条：',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('媒体库确认'),
                    selected: _waitMode == 'library',
                    onSelected: (_) => setState(() => _waitMode = 'library'),
                  ),
                  ChoiceChip(
                    label: const Text('固定等待'),
                    selected: _waitMode == 'fixed',
                    onSelected: (_) => setState(() => _waitMode = 'fixed'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_waitMode == 'library')
                const Text(
                  '确认当前媒体已成功写入媒体库后，再切下一条（默认）。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              if (_waitMode == 'fixed') ...[
                const Text(
                  '最长等待此时长；期间若已成功写入媒体库则立刻切条。'
                  '到点仍未入库也可切条，下载在后台继续。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final sec in const [15, 30, 60])
                      ChoiceChip(
                        label: Text('$sec秒'),
                        selected: _waitSeconds == sec,
                        onSelected: (_) => _applyWaitSeconds(sec),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _customSecondsController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '自定义秒数',
                    hintText: '例如 45',
                    isDense: true,
                    border: OutlineInputBorder(),
                    suffixText: '秒',
                  ),
                  onChanged: (raw) {
                    final n = int.tryParse(raw.trim());
                    if (n != null && n >= 1) {
                      setState(() => _waitSeconds = n.clamp(1, 600));
                    }
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  '当前：固定等待 $_waitSeconds 秒',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.pop(context);
          },
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('确定')),
      ],
    );
  }
}
