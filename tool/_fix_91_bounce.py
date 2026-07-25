# -*- coding: utf-8 -*-
"""Surgical fixes so a00 91 path actually deep-resolves detail pages."""
from pathlib import Path

p = Path(r"D:\1.Biancheng\my_app\lib\browser_page.dart")
t = p.read_text(encoding="utf-8")

# ---- 1) resolve91A00: force click path when still on list side ----
resolve_start = t.find("Future<void> _resolveAndDownloadSmartCandidate91A00")
resolve_end = t.find("Future<void> _returnFromSmartMediaCard91A00", resolve_start)
if resolve_start < 0 or resolve_end < 0:
    raise SystemExit("resolve91A00 not found")
resolve = t[resolve_start:resolve_end]

old_gate = """    if (is91 && currentlyOnCandidateList) {
      task['strict91ActiveCardUrl'] = initialPageUrl;
      task['phase'] = 'visiting_clicked_card';
      task['cardListUrl'] = candidateListUrl;
      task['resumeCandidateQueueAfterCard'] = true;
      task['activeDiscoveryStrategy'] = 'click_media_card';
      task['cardEnteredAt'] = DateTime.now();
      task['nextMediaLabel'] =
          (candidate['title'] ?? '').trim().isEmpty
              ? '下一个关键词视频'
              : (candidate['title'] ?? '').trim();
      task['nextMediaStatus'] = '正在直接进入关键词视频详情';
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
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
      return;
    }"""

new_gate = """    // a00 意图：关键词列表点卡片进详情再深挖。列表页 URL 细微差异时也不能跳过。
    final on91ListSide =
        is91 &&
        task['strict91KeywordMode'] == true &&
        !_is91ContentPage(_currentUrl);
    if (is91 && (currentlyOnCandidateList || on91ListSide)) {
      task['strict91ActiveCardUrl'] = initialPageUrl;
      task['phase'] = 'visiting_clicked_card';
      task['cardListUrl'] =
          candidateListUrl.isNotEmpty
              ? candidateListUrl
              : (task['strict91SearchUrl'] ?? '').toString();
      task['resumeCandidateQueueAfterCard'] = true;
      task['activeDiscoveryStrategy'] = 'click_media_card';
      task['cardEnteredAt'] = DateTime.now();
      task['candidateResolveRetries'] = 0;
      task['nextMediaLabel'] =
          (candidate['title'] ?? '').trim().isEmpty
              ? '下一个关键词视频'
              : (candidate['title'] ?? '').trim();
      task['nextMediaStatus'] = '正在直接进入关键词视频详情';
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
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

if old_gate not in resolve:
    raise SystemExit("old resolve gate not found")
resolve = resolve.replace(old_gate, new_gate, 1)

# selected==null fallback: mark visiting_clicked_card for strict91
old_null = """      // 动态播放器无法从 HTML 解析时，真实点击当前页的媒体卡片。
      task['phase'] = 'visiting_candidate';"""
new_null = """      // 动态播放器无法从 HTML 解析时，真实点击当前页的媒体卡片。
      if (is91 && task['strict91KeywordMode'] == true) {
        task['strict91ActiveCardUrl'] = initialPageUrl;
        task['phase'] = 'visiting_clicked_card';
        task['cardListUrl'] =
            candidateListUrl.isNotEmpty
                ? candidateListUrl
                : (task['strict91SearchUrl'] ?? '').toString();
        task['resumeCandidateQueueAfterCard'] = true;
        task['cardEnteredAt'] = DateTime.now();
        task['candidateResolveRetries'] = 0;
      } else {
        task['phase'] = 'visiting_candidate';
      }"""
if old_null not in resolve:
    raise SystemExit("selected==null phase assign not found in resolve91")
resolve = resolve.replace(old_null, new_null, 1)

t = t[:resolve_start] + resolve + t[resolve_end:]

# ---- 2) advance91A00: actualLoadedUrl + promote phase + page scroll ----
adv_start = t.find("Future<void> _advanceSmartDownload91A00")
adv_end = t.find("void _visitNextSmartCandidate91A00", adv_start)
if adv_start < 0 or adv_end < 0:
    raise SystemExit("advance91A00 not found")
adv = t[adv_start:adv_end]

adv = adv.replace(
    "      final phase = task['phase']?.toString() ?? '';",
    "      var phase = task['phase']?.toString() ?? '';",
    1,
)

old_page = """        var ok = false;
        final pageUrl = loadedUrl.isNotEmpty ? loadedUrl : _currentUrl;
        final urls = <String>[];"""
new_page = """        var ok = false;
        // 用 WebView 真实地址，避免过期 loadedUrl 导致 _is91ContentPage 误判、深挖被跳过。
        final pageUrl =
            actualLoadedUrl.isNotEmpty
                ? actualLoadedUrl
                : (loadedUrl.isNotEmpty ? loadedUrl : _currentUrl);
        if (strict91Mode &&
            phase == 'visiting_candidate' &&
            _is91ContentPage(pageUrl)) {
          task['phase'] = 'visiting_clicked_card';
          phase = 'visiting_clicked_card';
          if ((task['strict91ActiveCardUrl'] ?? '').toString().isEmpty) {
            task['strict91ActiveCardUrl'] = pageUrl;
          }
          task['cardEnteredAt'] ??= DateTime.now();
        }
        final urls = <String>[];"""
if old_page not in adv:
    raise SystemExit("pageUrl assign not found in advance91")
adv = adv.replace(old_page, new_page, 1)

old_js = """          // Some 91 players expose the real address only after play/visibility.
          await controller.evaluateJavascript(
            source: '''
              (() => {
                const videos = Array.from(document.querySelectorAll('video'));
                const video = videos.find(v => {
                  const r = v.getBoundingClientRect();
                  return r.width > 80 && r.height > 60;
                }) || videos[0];
                if (video) {
                  video.scrollIntoView({behavior:'auto', block:'center'});
                  video.muted = true;
                  try { video.load(); } catch (_) {}
                  try { video.play().catch(() => {}); } catch (_) {}
                }
                const play = Array.from(document.querySelectorAll(
                  'button, [role="button"], .play, [class*="play"]'
                )).find(el => {
                  const r = el.getBoundingClientRect();
                  const text = (el.innerText || el.title || el.getAttribute('aria-label') || '').trim();
                  return r.width > 20 && r.height > 20 &&
                    /(play|播放|开始)/i.test([text, el.className].join(' '));
                });
                if (play) { try { play.click(); } catch (_) {} }
                return {videos: videos.length, clickedPlay: !!play};
              })()
            ''',
          );"""

new_js = """          // a00：播放器可见后才有真实地址。91 首屏常无 video，需先整页下翻再找。
          await controller.evaluateJavascript(
            source: '''
              (() => {
                const pick = (list) => list.find(v => {
                  const r = v.getBoundingClientRect();
                  return r.width > 80 && r.height > 60;
                }) || list[0] || null;
                let videos = Array.from(document.querySelectorAll('video'));
                let video = pick(videos);
                if (!video) {
                  const step = Math.max(420, Math.floor(innerHeight * 0.8));
                  window.scrollBy({top: step, left: 0, behavior: 'auto'});
                  videos = Array.from(document.querySelectorAll('video'));
                  video = pick(videos);
                }
                if (video) {
                  video.scrollIntoView({behavior:'auto', block:'center'});
                  video.muted = true;
                  try { video.load(); } catch (_) {}
                  try { video.play().catch(() => {}); } catch (_) {}
                }
                const play = Array.from(document.querySelectorAll(
                  'button, [role="button"], .play, [class*="play"]'
                )).find(el => {
                  const r = el.getBoundingClientRect();
                  const text = (el.innerText || el.title || el.getAttribute('aria-label') || '').trim();
                  return r.width > 20 && r.height > 20 &&
                    /(play|播放|开始)/i.test([text, el.className].join(' '));
                });
                if (play) { try { play.click(); } catch (_) {} }
                return {videos: document.querySelectorAll('video').length, clickedPlay: !!play, scrolled: !video};
              })()
            ''',
          );"""

if old_js not in adv:
    raise SystemExit("deep-resolve JS not found in advance91")
adv = adv.replace(old_js, new_js, 1)

t = t[:adv_start] + adv + t[adv_end:]
p.write_text(t, encoding="utf-8")
print("patched resolve+advance for 91 bounce")
print("on91ListSide", "on91ListSide" in t)
print("scrollBy step", "innerHeight * 0.8" in t)
print("actualLoadedUrl pageUrl", "actualLoadedUrl.isNotEmpty" in t)
