# -*- coding: utf-8 -*-
"""Fix 91 bounce based on runtime logs (2026-07-25 22:15)."""
from pathlib import Path

p = Path(r"D:\1.Biancheng\my_app\lib\browser_page.dart")
t = p.read_text(encoding="utf-8")

# 1) Fix broken keep-load callback
old_keep = """      final smartTask = _smartDownloadTask;
      final a00_91 = smartTask != null && smartTask['a00_91_pipeline'] == true;
      if (!_isSameLoadedDocument(url, actualUrl)) {
        // 91 a00 管线：www/query 细微跳转仍属同一任务页时，不能丢弃完成回调，
        // 否则详情页永不 advance，只会表现为乱跳或卡住。
        final same91Task =
            a00_91 &&
            (_isSame91TaskPage(url, actualUrl) ||
                _is91ContentPage(actualUrl) ||
                _is91ContentPage(url));
        if (!same91Task) {
          debugPrint('忽略已失效的页面完成回调: $url -> $actualUrl');
          return;
        }
        debugPrint('Smart 91 a00: keep load callback $url -> $actualUrl');
      }
      if (_isXPlatformPage(actualUrl)) {
        unawaited(_flushBrowserCookies());
      }
      if (!mediaHandlersReady && _smartDownloadTask != null) {
        final task = _smartDownloadTask!;
        final id = (task['discoveryTaskId'] ?? '').toString();
        if (id.isNotEmpty) {
          _updateDownloadTask(
            id,
            progressDetail: '完整媒体监听暂不可用，正在使用页面资源与卡片点击兼容模式...',
          );
        }
      }
      final advanceUrl = a00_91 ? actualUrl : url;
      String title =
          ctrl != null ? (await ctrl.getTitle() ?? advanceUrl) : advanceUrl;
      await _addHistory(title, advanceUrl);

      // 更新状态：仅当加载真实网页时切换到 WebView
      setState(() {
        _isLoading = false;
        _currentUrl = advanceUrl;
        _urlController.text = advanceUrl;
        _showHomePage = false;
      });

      // 通知父组件浏览器状态变化
      widget.onBrowserHomePageChanged?.call(_showHomePage);

      debugPrint('页面加载完成: $advanceUrl, 标题: $title');
      unawaited(_advanceSmartDownload(advanceUrl));"""

new_keep = """      if (!_isSameLoadedDocument(url, actualUrl)) {
        // 绝不能用「url 是详情 / actual 是列表」这种半截导航回调去 advance，
        // 日志里正是它导致详情秒退回搜索页。
        final smartTask = _smartDownloadTask;
        final same91Page =
            smartTask != null &&
            smartTask['a00_91_pipeline'] == true &&
            _isSame91TaskPage(url, actualUrl);
        if (!same91Page) {
          debugPrint('忽略已失效的页面完成回调: $url -> $actualUrl');
          return;
        }
      }
      if (_isXPlatformPage(actualUrl)) {
        unawaited(_flushBrowserCookies());
      }
      if (!mediaHandlersReady && _smartDownloadTask != null) {
        final task = _smartDownloadTask!;
        final id = (task['discoveryTaskId'] ?? '').toString();
        if (id.isNotEmpty) {
          _updateDownloadTask(
            id,
            progressDetail: '完整媒体监听暂不可用，正在使用页面资源与卡片点击兼容模式...',
          );
        }
      }
      String title = ctrl != null ? (await ctrl.getTitle() ?? url) : url;
      await _addHistory(title, url);

      // 更新状态：仅当加载真实网页时切换到 WebView
      setState(() {
        _isLoading = false;
        _currentUrl = actualUrl.isNotEmpty ? actualUrl : url;
        _urlController.text = _currentUrl;
        _showHomePage = false;
      });

      // 通知父组件浏览器状态变化
      widget.onBrowserHomePageChanged?.call(_showHomePage);

      debugPrint('页面加载完成: $_currentUrl, 标题: $title');
      unawaited(_advanceSmartDownload(_currentUrl));"""

if old_keep not in t:
    raise SystemExit("onPageFinished block not found")
t = t.replace(old_keep, new_keep, 1)

# 2) visitNext91: strict91 never openNearest (it races and skips deep resolve)
old_visit_empty = """    if (index >= candidates.length) {
      unawaited(() async {
        final listUrl = (task['candidateListUrl'] ?? _currentUrl).toString();
        if (await _openNearestSmartMediaCard91A00(task, listUrl)) return;
        if (_allowSmartExploratoryClick(task) &&
            await _openExploratorySmartTarget(task, listUrl)) {
          return;
        }
        _broadenSmartDiscovery91A00(task, '当前列表的卡片和候选已全部尝试');
      }());
      return;
    }"""

new_visit_empty = """    if (index >= candidates.length) {
      unawaited(() async {
        final listUrl = (task['candidateListUrl'] ?? _currentUrl).toString();
        // strict91 关键词模式禁止 openNearest 乱点：日志显示它会点了却不导航，
        // 再和详情回调打架，表现为列表↔详情空转且从不「深入解析」。
        if (task['strict91KeywordMode'] == true) {
          _broadenSmartDiscovery91A00(task, '当前列表的卡片和候选已全部尝试');
          return;
        }
        if (await _openNearestSmartMediaCard91A00(task, listUrl)) return;
        if (_allowSmartExploratoryClick(task) &&
            await _openExploratorySmartTarget(task, listUrl)) {
          return;
        }
        _broadenSmartDiscovery91A00(task, '当前列表的卡片和候选已全部尝试');
      }());
      return;
    }"""

if old_visit_empty not in t:
    raise SystemExit("visitNext empty block not found")
t = t.replace(old_visit_empty, new_visit_empty, 1)

# 3) In advance91: filter junk media + force deep resolve for 91 detail
old_unique = """        urls.removeWhere((url) => url.trim().isEmpty);
        urls.removeWhere(_isLikelyAdUrl);
        final duplicateUrlKeys = task['duplicateVideoUrlKeys'] as Set<String>;
        final uniqueUrls =
            urls
                .toSet()
                .where(
                  (url) =>
                      !duplicateUrlKeys.contains(_normalizeVideoSourceUrl(url)),
                )
                .toList();
        if (_isXPlatformPage(pageUrl)) {
          uniqueUrls.sort(
            (left, right) => _scoreXVideoCandidate(
              right,
            ).compareTo(_scoreXVideoCandidate(left)),
          );
        }
        if (uniqueUrls.isEmpty &&
            phase == 'visiting_clicked_card' &&
            is91KeywordTask &&
            _is91ContentPage(pageUrl)) {"""

# Only replace inside advance91A00
adv_start = t.find("Future<void> _advanceSmartDownload91A00")
adv_end = t.find("void _visitNextSmartCandidate91A00", adv_start)
adv = t[adv_start:adv_end]
if old_unique not in adv:
    raise SystemExit("uniqueUrls block not in advance91")

new_unique = """        urls.removeWhere((url) => url.trim().isEmpty);
        urls.removeWhere(_isLikelyAdUrl);
        // 91 详情页首屏常抓到 spinner.svg / 图片，不能当视频地址，否则会跳过下翻深挖。
        bool isJunk91Media(String raw) {
          final lower = raw.toLowerCase();
          if (lower.contains('spinner') || lower.contains('/emoji')) return true;
          return lower.endsWith('.svg') ||
              lower.endsWith('.png') ||
              lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.gif') ||
              lower.endsWith('.webp') ||
              lower.endsWith('.ico') ||
              lower.contains('.svg?') ||
              lower.contains('.png?') ||
              lower.contains('.jpg?');
        }
        urls.removeWhere(isJunk91Media);
        final duplicateUrlKeys = task['duplicateVideoUrlKeys'] as Set<String>;
        final uniqueUrls =
            urls
                .toSet()
                .where(
                  (url) =>
                      !duplicateUrlKeys.contains(_normalizeVideoSourceUrl(url)),
                )
                .where((url) => !isJunk91Media(url))
                .toList();
        if (_isXPlatformPage(pageUrl)) {
          uniqueUrls.sort(
            (left, right) => _scoreXVideoCandidate(
              right,
            ).compareTo(_scoreXVideoCandidate(left)),
          );
        }
        if (uniqueUrls.isEmpty &&
            phase == 'visiting_clicked_card' &&
            is91KeywordTask &&
            _is91ContentPage(pageUrl)) {"""

adv = adv.replace(old_unique, new_unique, 1)
t = t[:adv_start] + adv + t[adv_end:]

# 4) resolve91: log click failure; prefer loadUrl and stay in visiting_clicked_card
old_click = """      final clicked = await _clickSmartCandidateLink(initialPageUrl);
      if (!identical(_smartDownloadTask, task)) return;
      if (!clicked) {
        // Fall back only for this card when its DOM click handler is missing.
        task['activeDiscoveryStrategy'] = 'direct_candidate_navigation';
        _loadUrl(initialPageUrl);
      } else {
        debugPrint(
          'Smart 91: clicked ordered card ${task['index']}/${candidates.length} $initialPageUrl',
        );
      }
      // 备份推进：避免 onLoadStop 丢失时详情页永不深挖。
      Future<void>.delayed(const Duration(milliseconds: 1600), () {
        if (identical(_smartDownloadTask, task) &&
            task['phase'] == 'visiting_clicked_card') {
          unawaited(_advanceSmartDownload91A00(_currentUrl));
        }
      });
      return;
    }"""

new_click = """      // 91 列表点进详情：优先直接 loadUrl，避免站点 click 被广告脚本吞掉却不导航。
      // （日志里 click/openNearest 多次「点击后尚未导航」，随后空转回列表。）
      task['activeDiscoveryStrategy'] = 'direct_candidate_navigation';
      debugPrint(
        'Smart 91: open ordered card ${task['index']}/${candidates.length} $initialPageUrl',
      );
      _loadUrl(initialPageUrl);
      Future<void>.delayed(const Duration(milliseconds: 1800), () {
        if (!identical(_smartDownloadTask, task)) return;
        if (task['phase'] != 'visiting_clicked_card') return;
        if (!_is91ContentPage(_currentUrl)) {
          debugPrint(
            'Smart 91: detail not reached after load, retry $initialPageUrl (now=$_currentUrl)',
          );
          _loadUrl(initialPageUrl);
          return;
        }
        unawaited(_advanceSmartDownload91A00(_currentUrl));
      });
      return;
    }"""

res_start = t.find("Future<void> _resolveAndDownloadSmartCandidate91A00")
res_end = t.find("Future<void> _returnFromSmartMediaCard91A00", res_start)
res = t[res_start:res_end]
if old_click not in res:
    raise SystemExit("resolve click block not found")
res = res.replace(old_click, new_click, 1)
t = t[:res_start] + res + t[res_end:]

# 5) collecting empty candidates: no openNearest for strict91
old_collect_empty = """        if (candidates.isEmpty) {
          // Some sites render playable cards through CSS/JavaScript and expose
          // no useful detail links to the source scanner. Exhaust real cards
          // on the current productive page before guessing another route.
          if (await _openNearestSmartMediaCard91A00(task, loadedUrl)) return;
          if (_allowSmartExploratoryClick(task) &&
              await _openExploratorySmartTarget(task, loadedUrl)) {
            return;
          }
          _broadenSmartDiscovery91A00(task, '当前搜索路径没有候选');
          return;
        }"""

new_collect_empty = """        if (candidates.isEmpty) {
          if (strict91Mode) {
            _broadenSmartDiscovery91A00(task, '当前搜索路径没有候选');
            return;
          }
          if (await _openNearestSmartMediaCard91A00(task, loadedUrl)) return;
          if (_allowSmartExploratoryClick(task) &&
              await _openExploratorySmartTarget(task, loadedUrl)) {
            return;
          }
          _broadenSmartDiscovery91A00(task, '当前搜索路径没有候选');
          return;
        }"""

if old_collect_empty not in t:
    raise SystemExit("collect empty not found")
t = t.replace(old_collect_empty, new_collect_empty, 1)

p.write_text(t, encoding="utf-8")
print("patched ok")
for s in [
    "keep load callback",
    "open ordered card",
    "isJunk91Media",
    "禁止 openNearest",
    "绝不能用「url 是详情",
]:
    print(s, s in t)
