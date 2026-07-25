import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 智能下载「动作零件」分类（最小完备）。
enum SmartActionCategory {
  media,
  touch,
  navigate,
  wait,
  page,
}

extension SmartActionCategoryX on SmartActionCategory {
  String get label {
    switch (this) {
      case SmartActionCategory.media:
        return '滑动';
      case SmartActionCategory.touch:
        return '点按';
      case SmartActionCategory.navigate:
        return '导航';
      case SmartActionCategory.wait:
        return '等待';
      case SmartActionCategory.page:
        return '翻页';
    }
  }
}

/// 最小完备动作集：屏幕距离滑动 / 找媒体滑动 分开，其余为真实效力零件。
enum SmartActionKind {
  /// 按屏幕高度向上滑动（不找媒体）
  swipeUpScreen,
  /// 按屏幕高度向下滑动
  swipeDownScreen,
  /// 按屏幕宽度向左滑动
  swipeLeftScreen,
  /// 按屏幕宽度向右滑动
  swipeRightScreen,
  /// 向上滑动并找到下一条媒体
  swipeUpFindMedia,
  /// 向下滑动并找到上一条媒体
  swipeDownFindMedia,
  /// 向左滑动并找到下一条媒体
  swipeLeftFindMedia,
  /// 向右滑动并找到下一条媒体
  swipeRightFindMedia,
  /// 当前媒体滚到屏幕中心
  focusMedia,
  /// 点击当前媒体（进详情）
  tapMedia,
  /// 双击当前媒体
  doubleTapMedia,
  /// 长按当前媒体触发下载
  longPressDownload,
  /// 点播放
  clickPlay,
  /// 关弹层/广告
  closeOverlay,
  /// 浏览器返回
  goBack,
  /// 刷新页面
  reloadPage,
  /// 下拉刷新
  pullRefresh,
  /// 滚到列表顶部
  scrollToTop,
  /// 短等待（约 1 秒）
  waitBrief,
  /// 等页面稳定
  waitPageSettle,
  /// 等本次下载完成
  waitDownload,
  /// 点「下一页」
  nextPage,
  /// 点「加载更多」
  loadMore,
}

extension SmartActionKindX on SmartActionKind {
  String get id {
    switch (this) {
      case SmartActionKind.swipeUpScreen:
        return 'swipe_up_screen';
      case SmartActionKind.swipeDownScreen:
        return 'swipe_down_screen';
      case SmartActionKind.swipeLeftScreen:
        return 'swipe_left_screen';
      case SmartActionKind.swipeRightScreen:
        return 'swipe_right_screen';
      case SmartActionKind.swipeUpFindMedia:
        return 'swipe_up_find_media';
      case SmartActionKind.swipeDownFindMedia:
        return 'swipe_down_find_media';
      case SmartActionKind.swipeLeftFindMedia:
        return 'swipe_left_find_media';
      case SmartActionKind.swipeRightFindMedia:
        return 'swipe_right_find_media';
      case SmartActionKind.focusMedia:
        return 'focus_media';
      case SmartActionKind.tapMedia:
        return 'tap_media';
      case SmartActionKind.doubleTapMedia:
        return 'double_tap_media';
      case SmartActionKind.longPressDownload:
        return 'longpress_download';
      case SmartActionKind.clickPlay:
        return 'click_play';
      case SmartActionKind.closeOverlay:
        return 'close_overlay';
      case SmartActionKind.goBack:
        return 'go_back';
      case SmartActionKind.reloadPage:
        return 'reload_page';
      case SmartActionKind.pullRefresh:
        return 'pull_refresh';
      case SmartActionKind.scrollToTop:
        return 'scroll_to_top';
      case SmartActionKind.waitBrief:
        return 'wait_brief';
      case SmartActionKind.waitPageSettle:
        return 'wait_page_settle';
      case SmartActionKind.waitDownload:
        return 'wait_download';
      case SmartActionKind.nextPage:
        return 'next_page';
      case SmartActionKind.loadMore:
        return 'load_more';
    }
  }

  String get label {
    switch (this) {
      case SmartActionKind.swipeUpScreen:
        return '向上推进一屏';
      case SmartActionKind.swipeDownScreen:
        return '向下推进一屏';
      case SmartActionKind.swipeLeftScreen:
        return '向左推进一屏';
      case SmartActionKind.swipeRightScreen:
        return '向右推进一屏';
      case SmartActionKind.swipeUpFindMedia:
        return '定位下一条媒体';
      case SmartActionKind.swipeDownFindMedia:
        return '定位上一条媒体';
      case SmartActionKind.swipeLeftFindMedia:
        return '定位右侧下一条';
      case SmartActionKind.swipeRightFindMedia:
        return '定位左侧下一条';
      case SmartActionKind.focusMedia:
        return '媒体居中';
      case SmartActionKind.tapMedia:
        return '点击媒体';
      case SmartActionKind.doubleTapMedia:
        return '双击媒体';
      case SmartActionKind.longPressDownload:
        return '长按下载';
      case SmartActionKind.clickPlay:
        return '点击播放';
      case SmartActionKind.closeOverlay:
        return '关闭弹层';
      case SmartActionKind.goBack:
        return '返回';
      case SmartActionKind.reloadPage:
        return '刷新页面';
      case SmartActionKind.pullRefresh:
        return '下拉刷新';
      case SmartActionKind.scrollToTop:
        return '回到顶部';
      case SmartActionKind.waitBrief:
        return '等待片刻';
      case SmartActionKind.waitPageSettle:
        return '等待页面稳定';
      case SmartActionKind.waitDownload:
        return '等待下载完成';
      case SmartActionKind.nextPage:
        return '下一页';
      case SmartActionKind.loadMore:
        return '加载更多';
    }
  }

  String get subtitle {
    switch (this) {
      case SmartActionKind.swipeUpScreen:
        return '直接把页面向上滚约一屏（不做假手指）';
      case SmartActionKind.swipeDownScreen:
        return '直接把页面向下滚约一屏（不做假手指）';
      case SmartActionKind.swipeLeftScreen:
        return '直接把页面向左滚约一屏（不做假手指）';
      case SmartActionKind.swipeRightScreen:
        return '直接把页面向右滚约一屏（不做假手指）';
      case SmartActionKind.swipeUpFindMedia:
        return '找到下一条视频/图片并滚到屏幕中央';
      case SmartActionKind.swipeDownFindMedia:
        return '找到上一条视频/图片并滚到屏幕中央';
      case SmartActionKind.swipeLeftFindMedia:
        return '找到右侧下一条媒体并滚入视野';
      case SmartActionKind.swipeRightFindMedia:
        return '找到左侧下一条媒体并滚入视野';
      case SmartActionKind.focusMedia:
        return '把当前媒体滚进屏幕正中';
      case SmartActionKind.tapMedia:
        return '点击当前媒体（常用于进详情）';
      case SmartActionKind.doubleTapMedia:
        return '双击当前媒体';
      case SmartActionKind.longPressDownload:
        return '长按当前媒体，触发下载';
      case SmartActionKind.clickPlay:
        return '寻找并点击播放按钮 / 播放视频';
      case SmartActionKind.closeOverlay:
        return '关闭弹窗、广告层、遮罩';
      case SmartActionKind.goBack:
        return '浏览器返回上一页';
      case SmartActionKind.reloadPage:
        return '刷新当前页';
      case SmartActionKind.pullRefresh:
        return '从顶部下拉，触发站点刷新';
      case SmartActionKind.scrollToTop:
        return '滚到页面最上方';
      case SmartActionKind.waitBrief:
        return '停约 1 秒，给动画/加载一点时间';
      case SmartActionKind.waitPageSettle:
        return '等滚动停稳、页面大致就绪';
      case SmartActionKind.waitDownload:
        return '等到本次下载结束再继续';
      case SmartActionKind.nextPage:
        return '点击「下一页 / Next」';
      case SmartActionKind.loadMore:
        return '点击「加载更多 / 更多」';
    }
  }

  SmartActionCategory get category {
    switch (this) {
      case SmartActionKind.swipeUpScreen:
      case SmartActionKind.swipeDownScreen:
      case SmartActionKind.swipeLeftScreen:
      case SmartActionKind.swipeRightScreen:
      case SmartActionKind.swipeUpFindMedia:
      case SmartActionKind.swipeDownFindMedia:
      case SmartActionKind.swipeLeftFindMedia:
      case SmartActionKind.swipeRightFindMedia:
      case SmartActionKind.focusMedia:
      case SmartActionKind.scrollToTop:
      case SmartActionKind.pullRefresh:
        return SmartActionCategory.media;
      case SmartActionKind.tapMedia:
      case SmartActionKind.doubleTapMedia:
      case SmartActionKind.longPressDownload:
      case SmartActionKind.clickPlay:
      case SmartActionKind.closeOverlay:
        return SmartActionCategory.touch;
      case SmartActionKind.goBack:
      case SmartActionKind.reloadPage:
        return SmartActionCategory.navigate;
      case SmartActionKind.waitBrief:
      case SmartActionKind.waitPageSettle:
      case SmartActionKind.waitDownload:
        return SmartActionCategory.wait;
      case SmartActionKind.nextPage:
      case SmartActionKind.loadMore:
        return SmartActionCategory.page;
    }
  }

  IconData get icon {
    switch (this) {
      case SmartActionKind.swipeUpScreen:
        return Icons.swipe_up;
      case SmartActionKind.swipeDownScreen:
        return Icons.swipe_down;
      case SmartActionKind.swipeLeftScreen:
        return Icons.swipe_left;
      case SmartActionKind.swipeRightScreen:
        return Icons.swipe_right;
      case SmartActionKind.swipeUpFindMedia:
        return Icons.skip_next;
      case SmartActionKind.swipeDownFindMedia:
        return Icons.skip_previous;
      case SmartActionKind.swipeLeftFindMedia:
        return Icons.arrow_circle_left_outlined;
      case SmartActionKind.swipeRightFindMedia:
        return Icons.arrow_circle_right_outlined;
      case SmartActionKind.focusMedia:
        return Icons.center_focus_strong;
      case SmartActionKind.tapMedia:
        return Icons.touch_app;
      case SmartActionKind.doubleTapMedia:
        return Icons.ads_click;
      case SmartActionKind.longPressDownload:
        return Icons.download_for_offline;
      case SmartActionKind.clickPlay:
        return Icons.play_circle_outline;
      case SmartActionKind.closeOverlay:
        return Icons.close;
      case SmartActionKind.goBack:
        return Icons.arrow_back;
      case SmartActionKind.reloadPage:
        return Icons.refresh;
      case SmartActionKind.pullRefresh:
        return Icons.swipe_down_alt;
      case SmartActionKind.scrollToTop:
        return Icons.vertical_align_top;
      case SmartActionKind.waitBrief:
        return Icons.hourglass_empty;
      case SmartActionKind.waitPageSettle:
        return Icons.hourglass_top;
      case SmartActionKind.waitDownload:
        return Icons.hourglass_bottom;
      case SmartActionKind.nextPage:
        return Icons.navigate_next;
      case SmartActionKind.loadMore:
        return Icons.expand_more;
    }
  }

  static SmartActionKind? fromId(String id) {
    for (final kind in SmartActionKind.values) {
      if (kind.id == id) return kind;
    }
    // 兼容旧版零件 id
    switch (id) {
      case 'next_media':
      case 'next_media_button':
      case 'scroll_to_bottom':
      case 'scroll_down_half':
      case 'scroll_down_full':
        return SmartActionKind.swipeUpFindMedia;
      case 'prev_media':
      case 'scroll_up_half':
      case 'scroll_up_full':
        return SmartActionKind.swipeDownFindMedia;
      case 'next_media_horizontal':
      case 'swipe_left':
      case 'finger_swipe_left':
        return SmartActionKind.swipeLeftFindMedia;
      case 'swipe_right':
      case 'finger_swipe_right':
        return SmartActionKind.swipeRightFindMedia;
      case 'swipe_up':
      case 'finger_swipe_up':
        return SmartActionKind.swipeUpScreen;
      case 'swipe_down':
      case 'finger_swipe_down':
        return SmartActionKind.swipeDownScreen;
      case 'focus_center_media':
        return SmartActionKind.focusMedia;
      case 'tap_center':
        return SmartActionKind.tapMedia;
      case 'click_close_overlay':
        return SmartActionKind.closeOverlay;
      case 'go_forward':
        return SmartActionKind.goBack;
      case 'wait_short':
      case 'wait_medium':
      case 'wait_long':
        return SmartActionKind.waitBrief;
      case 'next_page_button':
        return SmartActionKind.nextPage;
      case 'load_more_button':
        return SmartActionKind.loadMore;
    }
    return null;
  }
}

String _newStepId() =>
    's_${DateTime.now().microsecondsSinceEpoch}_${_stepSeq++}';
int _stepSeq = 0;

class SmartActionStep {
  SmartActionStep({
    required this.kind,
    String? id,
    Map<String, dynamic>? params,
  }) : id = id ?? _newStepId(),
       params = params ?? <String, dynamic>{};

  final String id;
  final SmartActionKind kind;
  final Map<String, dynamic> params;

  SmartActionStep copyWith({
    SmartActionKind? kind,
    Map<String, dynamic>? params,
  }) {
    return SmartActionStep(
      id: id,
      kind: kind ?? this.kind,
      params: params ?? Map<String, dynamic>.from(this.params),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind.id,
    'params': params,
  };

  factory SmartActionStep.fromJson(Map<String, dynamic> json) {
    final kind =
        SmartActionKindX.fromId((json['kind'] ?? '').toString()) ??
        SmartActionKind.waitBrief;
    final rawParams = json['params'];
    return SmartActionStep(
      id: (json['id'] ?? _newStepId()).toString(),
      kind: kind,
      params:
          rawParams is Map
              ? Map<String, dynamic>.from(rawParams)
              : <String, dynamic>{},
    );
  }
}

class SmartActionRecipe {
  SmartActionRecipe({
    required this.host,
    required this.name,
    required this.steps,
    String? id,
    this.updatedAt,
    this.lastUsedAt,
  }) : id = id ?? _newRecipeId();

  final String id;
  final String host;
  String name;
  final List<SmartActionStep> steps;
  DateTime? updatedAt;
  DateTime? lastUsedAt;

  bool get isEmpty => steps.isEmpty;

  SmartActionRecipe copyWith({
    String? host,
    String? name,
    List<SmartActionStep>? steps,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
  }) {
    return SmartActionRecipe(
      id: id,
      host: host ?? this.host,
      name: name ?? this.name,
      steps: steps ?? List<SmartActionStep>.from(this.steps),
      updatedAt: updatedAt ?? this.updatedAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'host': host,
    'name': name,
    'steps': steps.map((s) => s.toJson()).toList(),
    'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
  };

  factory SmartActionRecipe.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'];
    final steps = <SmartActionStep>[];
    if (rawSteps is List) {
      for (final row in rawSteps) {
        if (row is Map) {
          steps.add(SmartActionStep.fromJson(Map<String, dynamic>.from(row)));
        }
      }
    }
    return SmartActionRecipe(
      id: (json['id'] ?? _newRecipeId()).toString(),
      host: (json['host'] ?? '').toString(),
      name: (json['name'] ?? '未命名套路').toString(),
      steps: steps,
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()),
      lastUsedAt: DateTime.tryParse((json['lastUsedAt'] ?? '').toString()),
    );
  }

  /// 普通列表页：下一条 → 长按 → 等下载。
  static SmartActionRecipe feedTemplate(String host) {
    return SmartActionRecipe(
      host: host,
      name: '列表 · 下一条长按',
      steps: [
        SmartActionStep(kind: SmartActionKind.swipeUpScreen),
        SmartActionStep(kind: SmartActionKind.focusMedia),
        SmartActionStep(kind: SmartActionKind.longPressDownload),
        SmartActionStep(kind: SmartActionKind.waitDownload),
      ],
    );
  }

  /// 短视频/信息流：切下一条 → 长按。
  static SmartActionRecipe immersiveTemplate(String host) {
    return SmartActionRecipe(
      host: host,
      name: '沉浸流 · 下一条长按',
      steps: [
        SmartActionStep(kind: SmartActionKind.swipeUpFindMedia),
        SmartActionStep(kind: SmartActionKind.waitBrief),
        SmartActionStep(kind: SmartActionKind.longPressDownload),
        SmartActionStep(kind: SmartActionKind.waitDownload),
      ],
    );
  }

  /// 详情页：点进 → 长按 → 返回 → 下一条。
  static SmartActionRecipe detailTemplate(String host) {
    return SmartActionRecipe(
      host: host,
      name: '详情 · 点进长按返回',
      steps: [
        SmartActionStep(kind: SmartActionKind.tapMedia),
        SmartActionStep(kind: SmartActionKind.waitPageSettle),
        SmartActionStep(kind: SmartActionKind.clickPlay),
        SmartActionStep(kind: SmartActionKind.waitBrief),
        SmartActionStep(kind: SmartActionKind.longPressDownload),
        SmartActionStep(kind: SmartActionKind.waitDownload),
        SmartActionStep(kind: SmartActionKind.goBack),
        SmartActionStep(kind: SmartActionKind.waitPageSettle),
        SmartActionStep(kind: SmartActionKind.swipeUpScreen),
      ],
    );
  }
}

String _newRecipeId() =>
    'r_${DateTime.now().microsecondsSinceEpoch}_${_recipeSeq++}';
int _recipeSeq = 0;

/// 多套路库：同一站点可保存多套命名动作，并记住上次使用的一套。
class SmartActionRecipeStore {
  static const _prefsKeyV2 = 'browser_smart_action_recipes_v2';
  static const _prefsKeyV1 = 'browser_smart_action_recipes_v1';

  static String normalizeHost(String host) {
    return host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  }

  static String keyForHost(String host) => normalizeHost(host);

  static Future<Map<String, dynamic>> _loadRaw() async {
    final prefs = await SharedPreferences.getInstance();
    final rawV2 = prefs.getString(_prefsKeyV2);
    if (rawV2 != null && rawV2.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawV2);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    // 迁移 v1：每站只有一套 → 写入 v2
    final rawV1 = prefs.getString(_prefsKeyV1);
    if (rawV1 == null || rawV1.isEmpty) {
      return <String, dynamic>{
        'recipes': <String, dynamic>{},
        'lastByHost': <String, dynamic>{},
      };
    }
    try {
      final decoded = jsonDecode(rawV1);
      final recipes = <String, dynamic>{};
      final lastByHost = <String, dynamic>{};
      if (decoded is Map) {
        decoded.forEach((key, value) {
          if (value is! Map) return;
          final recipe = SmartActionRecipe.fromJson(
            Map<String, dynamic>.from(value),
          );
          // 保证 host 与 key 一致
          final fixed = recipe.copyWith(host: key.toString());
          recipes[fixed.id] = fixed.toJson();
          lastByHost[keyForHost(key.toString())] = fixed.id;
        });
      }
      final migrated = <String, dynamic>{
        'recipes': recipes,
        'lastByHost': lastByHost,
      };
      await prefs.setString(_prefsKeyV2, jsonEncode(migrated));
      return migrated;
    } catch (_) {
      return <String, dynamic>{
        'recipes': <String, dynamic>{},
        'lastByHost': <String, dynamic>{},
      };
    }
  }

  static Future<void> _saveRaw(Map<String, dynamic> raw) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyV2, jsonEncode(raw));
  }

  static Future<List<SmartActionRecipe>> loadAllRecipes() async {
    final raw = await _loadRaw();
    final recipesMap = raw['recipes'];
    final out = <SmartActionRecipe>[];
    if (recipesMap is Map) {
      for (final value in recipesMap.values) {
        if (value is Map) {
          out.add(SmartActionRecipe.fromJson(Map<String, dynamic>.from(value)));
        }
      }
    }
    out.sort((a, b) {
      final aa = a.lastUsedAt ?? a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bb = b.lastUsedAt ?? b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bb.compareTo(aa);
    });
    return out;
  }

  static Future<List<SmartActionRecipe>> loadForHost(String host) async {
    final want = keyForHost(host);
    final all = await loadAllRecipes();
    final same =
        all.where((r) => keyForHost(r.host) == want).toList(growable: false);
    return same;
  }

  /// 本站上次用过的套路；没有则返回本站最近更新的一套。
  static Future<SmartActionRecipe?> loadLastForHost(String host) async {
    final want = keyForHost(host);
    if (want.isEmpty) return null;
    final raw = await _loadRaw();
    final lastByHost = raw['lastByHost'];
    final recipesMap = raw['recipes'];
    if (lastByHost is Map && recipesMap is Map) {
      final id = (lastByHost[want] ?? '').toString();
      final row = recipesMap[id];
      if (row is Map) {
        return SmartActionRecipe.fromJson(Map<String, dynamic>.from(row));
      }
    }
    final list = await loadForHost(host);
    return list.isEmpty ? null : list.first;
  }

  static Future<void> save(SmartActionRecipe recipe) async {
    final raw = await _loadRaw();
    final recipes = Map<String, dynamic>.from(
      (raw['recipes'] is Map)
          ? Map<String, dynamic>.from(raw['recipes'] as Map)
          : <String, dynamic>{},
    );
    final lastByHost = Map<String, dynamic>.from(
      (raw['lastByHost'] is Map)
          ? Map<String, dynamic>.from(raw['lastByHost'] as Map)
          : <String, dynamic>{},
    );
    recipe.updatedAt = DateTime.now();
    recipes[recipe.id] = recipe.toJson();
    lastByHost[keyForHost(recipe.host)] = recipe.id;
    await _saveRaw(<String, dynamic>{
      'recipes': recipes,
      'lastByHost': lastByHost,
    });
  }

  static Future<void> markUsed(SmartActionRecipe recipe) async {
    final raw = await _loadRaw();
    final recipes = Map<String, dynamic>.from(
      (raw['recipes'] is Map)
          ? Map<String, dynamic>.from(raw['recipes'] as Map)
          : <String, dynamic>{},
    );
    final lastByHost = Map<String, dynamic>.from(
      (raw['lastByHost'] is Map)
          ? Map<String, dynamic>.from(raw['lastByHost'] as Map)
          : <String, dynamic>{},
    );
    recipe.lastUsedAt = DateTime.now();
    recipe.updatedAt = recipe.updatedAt ?? DateTime.now();
    recipes[recipe.id] = recipe.toJson();
    lastByHost[keyForHost(recipe.host)] = recipe.id;
    await _saveRaw(<String, dynamic>{
      'recipes': recipes,
      'lastByHost': lastByHost,
    });
  }

  static Future<void> deleteById(String id) async {
    final raw = await _loadRaw();
    final recipes = Map<String, dynamic>.from(
      (raw['recipes'] is Map)
          ? Map<String, dynamic>.from(raw['recipes'] as Map)
          : <String, dynamic>{},
    );
    final lastByHost = Map<String, dynamic>.from(
      (raw['lastByHost'] is Map)
          ? Map<String, dynamic>.from(raw['lastByHost'] as Map)
          : <String, dynamic>{},
    );
    final removed = recipes.remove(id);
    if (removed is Map) {
      final host = keyForHost((removed['host'] ?? '').toString());
      if (lastByHost[host] == id) {
        lastByHost.remove(host);
        // 同站若还有别的套路，改记最近一套
        SmartActionRecipe? fallback;
        for (final value in recipes.values) {
          if (value is! Map) continue;
          final r = SmartActionRecipe.fromJson(Map<String, dynamic>.from(value));
          if (keyForHost(r.host) != host) continue;
          if (fallback == null ||
              (r.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0)).isAfter(
                fallback.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
              )) {
            fallback = r;
          }
        }
        if (fallback != null) lastByHost[host] = fallback.id;
      }
    }
    await _saveRaw(<String, dynamic>{
      'recipes': recipes,
      'lastByHost': lastByHost,
    });
  }

  /// 兼容旧调用：返回本站上次套路。
  static Future<SmartActionRecipe?> loadForHostSingle(String host) =>
      loadLastForHost(host);

  static Future<void> deleteForHost(String host) async {
    final want = keyForHost(host);
    final list = await loadForHost(want);
    for (final r in list) {
      await deleteById(r.id);
    }
  }
}

