import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 智能下载「动作零件」分类（最小完备，按真人操作分组）。
enum SmartActionCategory {
  gesture,
  media,
  touch,
  navigate,
  wait,
  page,
}

extension SmartActionCategoryX on SmartActionCategory {
  String get label {
    switch (this) {
      case SmartActionCategory.gesture:
        return '手势';
      case SmartActionCategory.media:
        return '媒体';
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

/// 最小完备动作集：短轻扫（真人手指）与整屏滚动分开；点按/长按/等待/导航齐全。
enum SmartActionKind {
  /// 手指向上轻扫（短距离 flick，默认约 28% 屏高）
  flickUp,
  /// 手指向下轻扫
  flickDown,
  /// 手指向左轻扫
  flickLeft,
  /// 手指向右轻扫
  flickRight,
  /// 向上滚约一屏（较长滚动，非手指轻扫）
  scrollPageUp,
  /// 向下滚约一屏
  scrollPageDown,
  /// 向左滚约一屏
  scrollPageLeft,
  /// 向右滚约一屏
  scrollPageRight,
  /// 上切到下一条媒体（验证切成功；失败则加重试轻扫）
  findNextMedia,
  /// 下切到上一条媒体
  findPrevMedia,
  /// 左切到下一条媒体
  findNextMediaRight,
  /// 右切到上一条/左侧媒体
  findPrevMediaLeft,
  /// 当前媒体滚到屏幕中心
  focusMedia,
  /// 点击当前媒体（进详情/卡片）
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
  /// 下拉刷新（真人下拉手势）
  pullRefresh,
  /// 滚到列表顶部
  scrollToTop,
  /// 短等待（默认约 1 秒）
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
      case SmartActionKind.flickUp:
        return 'flick_up';
      case SmartActionKind.flickDown:
        return 'flick_down';
      case SmartActionKind.flickLeft:
        return 'flick_left';
      case SmartActionKind.flickRight:
        return 'flick_right';
      case SmartActionKind.scrollPageUp:
        return 'scroll_page_up';
      case SmartActionKind.scrollPageDown:
        return 'scroll_page_down';
      case SmartActionKind.scrollPageLeft:
        return 'scroll_page_left';
      case SmartActionKind.scrollPageRight:
        return 'scroll_page_right';
      case SmartActionKind.findNextMedia:
        return 'find_next_media';
      case SmartActionKind.findPrevMedia:
        return 'find_prev_media';
      case SmartActionKind.findNextMediaRight:
        return 'find_next_media_right';
      case SmartActionKind.findPrevMediaLeft:
        return 'find_prev_media_left';
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
      case SmartActionKind.flickUp:
        return '轻扫上';
      case SmartActionKind.flickDown:
        return '轻扫下';
      case SmartActionKind.flickLeft:
        return '轻扫左';
      case SmartActionKind.flickRight:
        return '轻扫右';
      case SmartActionKind.scrollPageUp:
        return '向上滚一屏';
      case SmartActionKind.scrollPageDown:
        return '向下滚一屏';
      case SmartActionKind.scrollPageLeft:
        return '向左滚一屏';
      case SmartActionKind.scrollPageRight:
        return '向右滚一屏';
      case SmartActionKind.findNextMedia:
        return '上切下一条';
      case SmartActionKind.findPrevMedia:
        return '下切上一条';
      case SmartActionKind.findNextMediaRight:
        return '左切下一条';
      case SmartActionKind.findPrevMediaLeft:
        return '右切一条';
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
      case SmartActionKind.flickUp:
        return '真人手指短促向上轻扫（默认约 28% 屏高，站点可感知 touch）';
      case SmartActionKind.flickDown:
        return '真人手指短促向下轻扫（默认约 28% 屏高）';
      case SmartActionKind.flickLeft:
        return '真人手指短促向左轻扫（默认约 32% 屏宽）';
      case SmartActionKind.flickRight:
        return '真人手指短促向右轻扫（默认约 32% 屏宽）';
      case SmartActionKind.scrollPageUp:
        return '把内容向上推进约一屏（长距离滚动，不是轻扫）';
      case SmartActionKind.scrollPageDown:
        return '把内容向下推进约一屏';
      case SmartActionKind.scrollPageLeft:
        return '把内容向左推进约一屏';
      case SmartActionKind.scrollPageRight:
        return '把内容向右推进约一屏';
      case SmartActionKind.findNextMedia:
        return '目标是切到下一条：先定位，不成则原生上滑并校验是否换了媒体';
      case SmartActionKind.findPrevMedia:
        return '目标是切到上一条：先定位，不成则原生下滑并校验是否换了媒体';
      case SmartActionKind.findNextMediaRight:
        return '目标是左切到下一条：校验媒体是否真的切换，失败自动加重试';
      case SmartActionKind.findPrevMediaLeft:
        return '目标是右切切换媒体：校验是否真的切换，失败自动加重试';
      case SmartActionKind.focusMedia:
        return '把当前媒体滚进屏幕正中';
      case SmartActionKind.tapMedia:
        return '单击当前媒体（常用于进详情/打开卡片）';
      case SmartActionKind.doubleTapMedia:
        return '双击当前媒体（点赞/放大等）';
      case SmartActionKind.longPressDownload:
        return '长按当前媒体，触发本地下载';
      case SmartActionKind.clickPlay:
        return '寻找并点击播放按钮 / 播放视频';
      case SmartActionKind.closeOverlay:
        return '关闭弹窗、广告层、遮罩';
      case SmartActionKind.goBack:
        return '浏览器返回上一页';
      case SmartActionKind.reloadPage:
        return '刷新当前页';
      case SmartActionKind.pullRefresh:
        return '从顶部真人下拉，触发站点刷新';
      case SmartActionKind.scrollToTop:
        return '滚到页面最上方';
      case SmartActionKind.waitBrief:
        return '停约 1 秒，给动画/加载一点时间';
      case SmartActionKind.waitPageSettle:
        return '等滚动停稳、页面大致就绪';
      case SmartActionKind.waitDownload:
        return '媒体库确认后再切条，或按固定秒数等待后切条';
      case SmartActionKind.nextPage:
        return '点击「下一页 / Next」';
      case SmartActionKind.loadMore:
        return '点击「加载更多 / 更多」';
    }
  }

  SmartActionCategory get category {
    switch (this) {
      case SmartActionKind.flickUp:
      case SmartActionKind.flickDown:
      case SmartActionKind.flickLeft:
      case SmartActionKind.flickRight:
      case SmartActionKind.scrollPageUp:
      case SmartActionKind.scrollPageDown:
      case SmartActionKind.scrollPageLeft:
      case SmartActionKind.scrollPageRight:
      case SmartActionKind.pullRefresh:
      case SmartActionKind.scrollToTop:
        return SmartActionCategory.gesture;
      case SmartActionKind.findNextMedia:
      case SmartActionKind.findPrevMedia:
      case SmartActionKind.findNextMediaRight:
      case SmartActionKind.findPrevMediaLeft:
      case SmartActionKind.focusMedia:
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
      case SmartActionKind.flickUp:
        return Icons.swipe_up;
      case SmartActionKind.flickDown:
        return Icons.swipe_down;
      case SmartActionKind.flickLeft:
        return Icons.swipe_left;
      case SmartActionKind.flickRight:
        return Icons.swipe_right;
      case SmartActionKind.scrollPageUp:
        return Icons.keyboard_double_arrow_up;
      case SmartActionKind.scrollPageDown:
        return Icons.keyboard_double_arrow_down;
      case SmartActionKind.scrollPageLeft:
        return Icons.keyboard_double_arrow_left;
      case SmartActionKind.scrollPageRight:
        return Icons.keyboard_double_arrow_right;
      case SmartActionKind.findNextMedia:
        return Icons.skip_next;
      case SmartActionKind.findPrevMedia:
        return Icons.skip_previous;
      case SmartActionKind.findNextMediaRight:
        return Icons.arrow_circle_right_outlined;
      case SmartActionKind.findPrevMediaLeft:
        return Icons.arrow_circle_left_outlined;
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

  /// 新建步骤时的默认参数（距离/时长等）。
  Map<String, dynamic> get defaultParams {
    switch (this) {
      case SmartActionKind.flickUp:
      case SmartActionKind.flickDown:
        return <String, dynamic>{
          'distanceFraction': 0.28,
          'durationMs': 220,
        };
      case SmartActionKind.flickLeft:
      case SmartActionKind.flickRight:
        return <String, dynamic>{
          'distanceFraction': 0.32,
          'durationMs': 220,
        };
      case SmartActionKind.scrollPageUp:
      case SmartActionKind.scrollPageDown:
      case SmartActionKind.scrollPageLeft:
      case SmartActionKind.scrollPageRight:
        return <String, dynamic>{'distanceFraction': 0.85};
      case SmartActionKind.waitBrief:
        return <String, dynamic>{'ms': 1000};
      case SmartActionKind.waitDownload:
        // library：入库确认后切条（默认）；fixed：最多等 waitSeconds，入库成功可提前切条
        return <String, dynamic>{
          'waitMode': 'library',
          'waitSeconds': 30,
        };
      case SmartActionKind.findNextMedia:
      case SmartActionKind.findPrevMedia:
        return <String, dynamic>{
          'maxAttempts': 4,
          'distanceFraction': 0.34,
          'durationMs': 280,
        };
      case SmartActionKind.findNextMediaRight:
      case SmartActionKind.findPrevMediaLeft:
        return <String, dynamic>{
          'maxAttempts': 4,
          'distanceFraction': 0.36,
          'durationMs': 280,
        };
      default:
        return <String, dynamic>{};
    }
  }

  static SmartActionKind? fromId(String id) {
    for (final kind in SmartActionKind.values) {
      if (kind.id == id) return kind;
    }
    // 兼容旧版零件 id
    switch (id) {
      case 'swipe_up_screen':
      case 'swipe_up':
      case 'finger_swipe_up':
        return SmartActionKind.flickUp;
      case 'swipe_down_screen':
      case 'swipe_down':
      case 'finger_swipe_down':
        return SmartActionKind.flickDown;
      case 'swipe_left_screen':
      case 'swipe_left':
      case 'finger_swipe_left':
        return SmartActionKind.flickLeft;
      case 'swipe_right_screen':
      case 'swipe_right':
      case 'finger_swipe_right':
        return SmartActionKind.flickRight;
      case 'scroll_down_half':
      case 'scroll_down_full':
      case 'scroll_to_bottom':
        return SmartActionKind.scrollPageUp;
      case 'scroll_up_half':
      case 'scroll_up_full':
        return SmartActionKind.scrollPageDown;
      case 'next_media':
      case 'next_media_button':
      case 'swipe_up_find_media':
        return SmartActionKind.findNextMedia;
      case 'prev_media':
      case 'swipe_down_find_media':
        return SmartActionKind.findPrevMedia;
      case 'next_media_horizontal':
      case 'swipe_left_find_media':
        return SmartActionKind.findNextMediaRight;
      case 'swipe_right_find_media':
        return SmartActionKind.findPrevMediaLeft;
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
       params = params ?? Map<String, dynamic>.from(kind.defaultParams);

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

  double paramDouble(String key, double fallback) {
    final v = params[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  int paramInt(String key, int fallback) {
    final v = params[key];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  String paramString(String key, String fallback) {
    final v = params[key];
    if (v == null) return fallback;
    final s = v.toString().trim();
    return s.isEmpty ? fallback : s;
  }

  /// `library`（默认）或 `fixed`。
  String get waitMode {
    final mode = paramString('waitMode', 'library').toLowerCase();
    return mode == 'fixed' ? 'fixed' : 'library';
  }

  /// 固定等待秒数（仅 waitMode=fixed 使用）。
  int get waitSeconds => paramInt('waitSeconds', 30).clamp(1, 600);

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
    final merged = Map<String, dynamic>.from(kind.defaultParams);
    if (rawParams is Map) {
      merged.addAll(Map<String, dynamic>.from(rawParams));
    }
    return SmartActionStep(
      id: (json['id'] ?? _newStepId()).toString(),
      kind: kind,
      params: merged,
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
    this.advanceAxisHint,
    this.advanceMode,
    this.lastSuccessAt,
  }) : id = id ?? _newRecipeId();

  final String id;
  final String host;
  String name;
  final List<SmartActionStep> steps;
  DateTime? updatedAt;
  DateTime? lastUsedAt;
  /// 成功实跑时的切条方向：`up` / `down` / `left`。
  String? advanceAxisHint;
  /// 成功实跑时的滑动方式：`distance` / `verify`。
  String? advanceMode;
  /// 最近一次「动作编排」真实入库成功的时间。
  DateTime? lastSuccessAt;

  bool get isEmpty => steps.isEmpty;

  SmartActionRecipe copyWith({
    String? host,
    String? name,
    List<SmartActionStep>? steps,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
    String? advanceAxisHint,
    String? advanceMode,
    DateTime? lastSuccessAt,
  }) {
    return SmartActionRecipe(
      id: id,
      host: host ?? this.host,
      name: name ?? this.name,
      steps: steps ?? List<SmartActionStep>.from(this.steps),
      updatedAt: updatedAt ?? this.updatedAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      advanceAxisHint: advanceAxisHint ?? this.advanceAxisHint,
      advanceMode: advanceMode ?? this.advanceMode,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'host': host,
    'name': name,
    'steps': steps.map((s) => s.toJson()).toList(),
    'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
    if (advanceAxisHint != null && advanceAxisHint!.isNotEmpty)
      'advanceAxisHint': advanceAxisHint,
    if (advanceMode != null && advanceMode!.isNotEmpty)
      'advanceMode': advanceMode,
    if (lastSuccessAt != null)
      'lastSuccessAt': lastSuccessAt!.toIso8601String(),
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
      advanceAxisHint: () {
        final v = (json['advanceAxisHint'] ?? '').toString().trim();
        return v.isEmpty ? null : v;
      }(),
      advanceMode: () {
        final v = (json['advanceMode'] ?? '').toString().trim();
        return v.isEmpty ? null : v;
      }(),
      lastSuccessAt: DateTime.tryParse(
        (json['lastSuccessAt'] ?? '').toString(),
      ),
    );
  }

  /// 核心循环（竖滑信息流）：长按 → 等下载 → 上切下一条（校验切换）→ 短等。
  static SmartActionRecipe feedTemplate(String host) {
    return SmartActionRecipe(
      host: host,
      name: '核心 · 长按→上切',
      steps: [
        SmartActionStep(kind: SmartActionKind.longPressDownload),
        SmartActionStep(kind: SmartActionKind.waitDownload),
        SmartActionStep(
          kind: SmartActionKind.findNextMedia,
          params: const {'maxAttempts': 4, 'distanceFraction': 0.34},
        ),
        SmartActionStep(kind: SmartActionKind.waitBrief),
      ],
    );
  }

  /// 核心循环（横滑信息流）：长按 → 等下载 → 左切下一条（校验切换）→ 短等。
  static SmartActionRecipe feedLeftTemplate(String host) {
    return SmartActionRecipe(
      host: host,
      name: '核心 · 长按→左切',
      steps: [
        SmartActionStep(kind: SmartActionKind.longPressDownload),
        SmartActionStep(kind: SmartActionKind.waitDownload),
        SmartActionStep(
          kind: SmartActionKind.findNextMediaRight,
          params: const {'maxAttempts': 4, 'distanceFraction': 0.36},
        ),
        SmartActionStep(kind: SmartActionKind.waitBrief),
      ],
    );
  }

  /// 沉浸短视频：长按 → 上切下一条（带校验重试）。
  static SmartActionRecipe immersiveTemplate(String host) {
    return SmartActionRecipe(
      host: host,
      name: '沉浸流 · 长按上切',
      steps: [
        SmartActionStep(kind: SmartActionKind.longPressDownload),
        SmartActionStep(kind: SmartActionKind.waitDownload),
        SmartActionStep(
          kind: SmartActionKind.findNextMedia,
          params: const {'maxAttempts': 5, 'distanceFraction': 0.38},
        ),
        SmartActionStep(kind: SmartActionKind.waitBrief),
      ],
    );
  }

  /// 详情页：点进 → 长按 → 返回 → 上切下一条。
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
        SmartActionStep(
          kind: SmartActionKind.findNextMedia,
          params: const {'maxAttempts': 4},
        ),
      ],
    );
  }

  /// 与 [feedTemplate] 相同：长按当前 → 上滑下一条（推荐默认验证）。
  static SmartActionRecipe flickLongPressTemplate(String host) =>
      feedTemplate(host);
}

String _newRecipeId() =>
    'r_${DateTime.now().microsecondsSinceEpoch}_${_recipeSeq++}';
int _recipeSeq = 0;

/// 多套路库：同一站点可保存多套命名动作，并记住上次使用的一套。
/// [userActionRecipes]：跨站可借用的「成功动作套路」id 列表（最近成功在前）。
class SmartActionRecipeStore {
  static const _prefsKeyV2 = 'browser_smart_action_recipes_v2';
  static const _prefsKeyV1 = 'browser_smart_action_recipes_v1';

  static String normalizeHost(String host) {
    return host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  }

  static String keyForHost(String host) => normalizeHost(host);

  static Map<String, dynamic> _emptyRaw() => <String, dynamic>{
    'recipes': <String, dynamic>{},
    'lastByHost': <String, dynamic>{},
    'lastSuccessByHost': <String, dynamic>{},
    'userActionRecipes': <String>[],
  };

  static List<String> _migrateUserActionRecipeIds(Map<String, dynamic> raw) {
    final recipesMap =
        (raw['recipes'] is Map)
            ? Map<String, dynamic>.from(raw['recipes'] as Map)
            : <String, dynamic>{};
    final ids = <String>[];
    void addId(String id) {
      if (id.isEmpty || ids.contains(id) || !recipesMap.containsKey(id)) {
        return;
      }
      ids.add(id);
    }

    final rawList = raw['userActionRecipes'];
    if (rawList is List) {
      for (final e in rawList) {
        addId(e.toString());
      }
    }
    if (ids.isNotEmpty) return ids;

    // 旧数据迁移：本站默认 + 曾标记 lastSuccessAt 的套路 → 全局可借用列表。
    final lastSuccessByHost = raw['lastSuccessByHost'];
    if (lastSuccessByHost is Map) {
      for (final value in lastSuccessByHost.values) {
        addId(value.toString());
      }
    }
    final scored = <({String id, DateTime at})>[];
    for (final entry in recipesMap.entries) {
      final row = entry.value;
      if (row is! Map) continue;
      final recipe = SmartActionRecipe.fromJson(
        Map<String, dynamic>.from(row),
      );
      if (recipe.lastSuccessAt == null || recipe.steps.isEmpty) continue;
      if (ids.contains(recipe.id)) continue;
      scored.add((
        id: recipe.id,
        at: recipe.lastSuccessAt ??
            recipe.updatedAt ??
            DateTime.fromMillisecondsSinceEpoch(0),
      ));
    }
    scored.sort((a, b) => b.at.compareTo(a.at));
    for (final row in scored) {
      addId(row.id);
    }
    return ids;
  }

  static Map<String, dynamic> _normalizeRaw(Map<String, dynamic> raw) {
    final normalized = <String, dynamic>{
      'recipes':
          (raw['recipes'] is Map)
              ? Map<String, dynamic>.from(raw['recipes'] as Map)
              : <String, dynamic>{},
      'lastByHost':
          (raw['lastByHost'] is Map)
              ? Map<String, dynamic>.from(raw['lastByHost'] as Map)
              : <String, dynamic>{},
      'lastSuccessByHost':
          (raw['lastSuccessByHost'] is Map)
              ? Map<String, dynamic>.from(raw['lastSuccessByHost'] as Map)
              : <String, dynamic>{},
    };
    normalized['userActionRecipes'] = _migrateUserActionRecipeIds({
      ...normalized,
      'userActionRecipes': raw['userActionRecipes'],
    });
    return normalized;
  }

  static Future<Map<String, dynamic>> _loadRaw() async {
    final prefs = await SharedPreferences.getInstance();
    final rawV2 = prefs.getString(_prefsKeyV2);
    if (rawV2 != null && rawV2.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawV2);
        if (decoded is Map) {
          return _normalizeRaw(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }
    // 迁移 v1：每站只有一套 → 写入 v2
    final rawV1 = prefs.getString(_prefsKeyV1);
    if (rawV1 == null || rawV1.isEmpty) {
      return _emptyRaw();
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
        'lastSuccessByHost': <String, dynamic>{},
        'userActionRecipes': <String>[],
      };
      await prefs.setString(_prefsKeyV2, jsonEncode(migrated));
      return _normalizeRaw(migrated);
    } catch (_) {
      return _emptyRaw();
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

  /// 本站「沿用套路」默认成功动作；没有则返回 null（不静默回退）。
  /// 可为他站来源的借用套路（以 [lastSuccessByHost] 指针为准，不强制 recipe.host 同源）。
  static Future<SmartActionRecipe?> loadLastSuccessForHost(String host) async {
    final want = keyForHost(host);
    if (want.isEmpty) return null;
    final raw = await _loadRaw();
    final lastSuccessByHost = raw['lastSuccessByHost'];
    final recipesMap = raw['recipes'];
    if (lastSuccessByHost is! Map || recipesMap is! Map) return null;
    final id = (lastSuccessByHost[want] ?? '').toString();
    if (id.isEmpty) return null;
    final row = recipesMap[id];
    if (row is! Map) return null;
    final recipe = SmartActionRecipe.fromJson(Map<String, dynamic>.from(row));
    if (recipe.steps.isEmpty) return null;
    return recipe;
  }

  static Map<String, dynamic> _bundle(
    Map<String, dynamic> recipes,
    Map<String, dynamic> lastByHost,
    Map<String, dynamic> lastSuccessByHost,
    List<String> userActionRecipes,
  ) =>
      <String, dynamic>{
        'recipes': recipes,
        'lastByHost': lastByHost,
        'lastSuccessByHost': lastSuccessByHost,
        'userActionRecipes': userActionRecipes,
      };

  static List<String> _upsertUserActionRecipeId(
    List<String> ids,
    String id,
  ) {
    final next = List<String>.from(ids)..remove(id);
    next.insert(0, id);
    return next;
  }

  /// 全部「成功动作套路」（跨站可借用；不含 X/91 内置管线）。
  static Future<List<SmartActionRecipe>> loadUserActionRecipes() async {
    final raw = _normalizeRaw(await _loadRaw());
    final recipesMap = raw['recipes'] as Map;
    final ids = List<String>.from(raw['userActionRecipes'] as List);
    final out = <SmartActionRecipe>[];
    for (final id in ids) {
      final row = recipesMap[id];
      if (row is! Map) continue;
      final recipe = SmartActionRecipe.fromJson(
        Map<String, dynamic>.from(row),
      );
      if (recipe.steps.isEmpty) continue;
      out.add(recipe);
    }
    return out;
  }

  static Future<void> save(SmartActionRecipe recipe) async {
    final raw = _normalizeRaw(await _loadRaw());
    final recipes = Map<String, dynamic>.from(raw['recipes'] as Map);
    final lastByHost = Map<String, dynamic>.from(raw['lastByHost'] as Map);
    final lastSuccessByHost = Map<String, dynamic>.from(
      raw['lastSuccessByHost'] as Map,
    );
    final userActionRecipes = List<String>.from(
      raw['userActionRecipes'] as List,
    );
    recipe.updatedAt = DateTime.now();
    recipes[recipe.id] = recipe.toJson();
    lastByHost[keyForHost(recipe.host)] = recipe.id;
    await _saveRaw(
      _bundle(recipes, lastByHost, lastSuccessByHost, userActionRecipes),
    );
  }

  static Future<void> markUsed(SmartActionRecipe recipe) async {
    final raw = _normalizeRaw(await _loadRaw());
    final recipes = Map<String, dynamic>.from(raw['recipes'] as Map);
    final lastByHost = Map<String, dynamic>.from(raw['lastByHost'] as Map);
    final lastSuccessByHost = Map<String, dynamic>.from(
      raw['lastSuccessByHost'] as Map,
    );
    final userActionRecipes = List<String>.from(
      raw['userActionRecipes'] as List,
    );
    recipe.lastUsedAt = DateTime.now();
    recipe.updatedAt = recipe.updatedAt ?? DateTime.now();
    recipes[recipe.id] = recipe.toJson();
    lastByHost[keyForHost(recipe.host)] = recipe.id;
    await _saveRaw(
      _bundle(recipes, lastByHost, lastSuccessByHost, userActionRecipes),
    );
  }

  /// 将「动作编排」成功经验写入全局可借用列表，并设为某站「本站默认」。
  /// [defaultForHost]：默认指针写入的站点（当前浏览站）；[recipe.host] 保留来源站标签。
  /// 同一 defaultForHost 的默认指针会**覆盖**；旧成功套路仍保留在 [userActionRecipes]。
  static Future<void> markLastSuccess(
    SmartActionRecipe recipe, {
    String? advanceAxisHint,
    String? advanceMode,
    String? defaultForHost,
  }) async {
    final defaultHostKey = keyForHost(
      (defaultForHost ?? recipe.host).trim(),
    );
    if (defaultHostKey.isEmpty || recipe.steps.isEmpty) return;
    final now = DateTime.now();
    final axis = (advanceAxisHint ?? recipe.advanceAxisHint ?? '').trim();
    final mode = (advanceMode ?? recipe.advanceMode ?? '').trim();
    recipe.advanceAxisHint =
        (axis == 'up' || axis == 'down' || axis == 'left') ? axis : null;
    recipe.advanceMode =
        (mode == 'distance' || mode == 'verify') ? mode : null;
    recipe.lastSuccessAt = now;
    recipe.lastUsedAt = now;
    recipe.updatedAt = now;
    // 来源 host：已有则保留（跨站借用成功不改写）；空则记为当前默认站。
    if (keyForHost(recipe.host).isEmpty) {
      recipe = recipe.copyWith(host: defaultHostKey);
    }

    final raw = _normalizeRaw(await _loadRaw());
    final recipes = Map<String, dynamic>.from(raw['recipes'] as Map);
    final lastByHost = Map<String, dynamic>.from(raw['lastByHost'] as Map);
    final lastSuccessByHost = Map<String, dynamic>.from(
      raw['lastSuccessByHost'] as Map,
    );
    final userActionRecipes = _upsertUserActionRecipeId(
      List<String>.from(raw['userActionRecipes'] as List),
      recipe.id,
    );
    // 若同 id 已有条目，合并保留其来源 host（避免被调用方误改）。
    final prevRow = recipes[recipe.id];
    if (prevRow is Map) {
      final prevHost =
          keyForHost((prevRow['host'] ?? '').toString());
      if (prevHost.isNotEmpty && keyForHost(recipe.host) != prevHost) {
        recipe = recipe.copyWith(host: prevHost);
      }
    }
    recipes[recipe.id] = recipe.toJson();
    lastByHost[defaultHostKey] = recipe.id;
    lastSuccessByHost[defaultHostKey] = recipe.id; // 本站默认覆盖
    await _saveRaw(
      _bundle(recipes, lastByHost, lastSuccessByHost, userActionRecipes),
    );
  }

  /// 将已有成功套路设为某站「本站默认」（跨站借用后可落盘为当前站默认）。
  static Future<void> setAsHostDefault(String host, String recipeId) async {
    final hostKey = keyForHost(host);
    final id = recipeId.trim();
    if (hostKey.isEmpty || id.isEmpty) return;
    final raw = _normalizeRaw(await _loadRaw());
    final recipes = Map<String, dynamic>.from(raw['recipes'] as Map);
    final lastByHost = Map<String, dynamic>.from(raw['lastByHost'] as Map);
    final lastSuccessByHost = Map<String, dynamic>.from(
      raw['lastSuccessByHost'] as Map,
    );
    final row = recipes[id];
    if (row is! Map) return;
    final recipe = SmartActionRecipe.fromJson(Map<String, dynamic>.from(row));
    if (recipe.steps.isEmpty) return;
    recipe.lastSuccessAt = recipe.lastSuccessAt ?? DateTime.now();
    recipe.updatedAt = DateTime.now();
    recipes[id] = recipe.toJson();
    lastByHost[hostKey] = id;
    lastSuccessByHost[hostKey] = id;
    final userActionRecipes = _upsertUserActionRecipeId(
      List<String>.from(raw['userActionRecipes'] as List),
      id,
    );
    await _saveRaw(
      _bundle(recipes, lastByHost, lastSuccessByHost, userActionRecipes),
    );
  }

  /// 重命名用户动作套路（不影响 X/91 内置管线）。
  static Future<bool> renameRecipe(String id, String name) async {
    final trimmed = name.trim();
    if (id.isEmpty || trimmed.isEmpty) return false;
    final raw = _normalizeRaw(await _loadRaw());
    final recipes = Map<String, dynamic>.from(raw['recipes'] as Map);
    final row = recipes[id];
    if (row is! Map) return false;
    final recipe = SmartActionRecipe.fromJson(Map<String, dynamic>.from(row));
    recipe.name = trimmed;
    recipe.updatedAt = DateTime.now();
    recipes[id] = recipe.toJson();
    await _saveRaw(
      _bundle(
        recipes,
        Map<String, dynamic>.from(raw['lastByHost'] as Map),
        Map<String, dynamic>.from(raw['lastSuccessByHost'] as Map),
        List<String>.from(raw['userActionRecipes'] as List),
      ),
    );
    return true;
  }

  /// 清除本站「沿用套路」自动选用的成功经验（不影响 X/91 等内置管线）。
  /// [deleteRecipe] 为 true 时同时删除该套路实体；否则仅取消本站默认指针。
  static Future<void> clearLastSuccessForHost(
    String host, {
    bool deleteRecipe = true,
  }) async {
    final hostKey = keyForHost(host);
    if (hostKey.isEmpty) return;
    final raw = _normalizeRaw(await _loadRaw());
    final recipes = Map<String, dynamic>.from(raw['recipes'] as Map);
    final lastByHost = Map<String, dynamic>.from(raw['lastByHost'] as Map);
    final lastSuccessByHost = Map<String, dynamic>.from(
      raw['lastSuccessByHost'] as Map,
    );
    final userActionRecipes = List<String>.from(
      raw['userActionRecipes'] as List,
    );
    final id = (lastSuccessByHost.remove(hostKey) ?? '').toString();
    if (id.isNotEmpty) {
      if (deleteRecipe) {
        recipes.remove(id);
        userActionRecipes.remove(id);
        // 其他站若也指向同一套路 id，一并清掉默认指针。
        lastSuccessByHost.removeWhere((_, value) => value.toString() == id);
        if (lastByHost[hostKey] == id) {
          lastByHost.remove(hostKey);
          SmartActionRecipe? fallback;
          for (final value in recipes.values) {
            if (value is! Map) continue;
            final r = SmartActionRecipe.fromJson(
              Map<String, dynamic>.from(value),
            );
            if (keyForHost(r.host) != hostKey) continue;
            if (fallback == null ||
                (r.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                    .isAfter(
                  fallback.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
                )) {
              fallback = r;
            }
          }
          if (fallback != null) lastByHost[hostKey] = fallback.id;
        }
      }
    }
    await _saveRaw(
      _bundle(recipes, lastByHost, lastSuccessByHost, userActionRecipes),
    );
  }

  static Future<void> deleteById(String id) async {
    final raw = _normalizeRaw(await _loadRaw());
    final recipes = Map<String, dynamic>.from(raw['recipes'] as Map);
    final lastByHost = Map<String, dynamic>.from(raw['lastByHost'] as Map);
    final lastSuccessByHost = Map<String, dynamic>.from(
      raw['lastSuccessByHost'] as Map,
    );
    final userActionRecipes = List<String>.from(
      raw['userActionRecipes'] as List,
    );
    final removed = recipes.remove(id);
    userActionRecipes.remove(id);
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
      // 任一站默认指向该套路则清空（不回退旧默认，避免错套路复活）。
      lastSuccessByHost.removeWhere((_, value) => value.toString() == id);
    }
    await _saveRaw(
      _bundle(recipes, lastByHost, lastSuccessByHost, userActionRecipes),
    );
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
