/// 「分页嗅探」：发现同站邻近/内容页 URL，供分层嗅探扩大覆盖。
///
/// 采集本体复用 [SmartScopeBatchJs]；本文件只负责「找哪些页」。
class SmartPaginatedSniffJs {
  SmartPaginatedSniffJs._();

  /// 从当前页发现同站邻近页（分页 / 上一页下一页 / 内容卡片 / 同级列表）。
  /// 返回 `{ ok, pages:[{url,label,score}], current }`。
  static String discoverNearbyPages({required int limit}) {
    final lim = limit.clamp(1, 48);
    return '''
(() => {
  const limit = $lim;
  const abs = (raw) => {
    if (!raw) return '';
    try { return new URL(String(raw), location.href).href; } catch (_) { return ''; }
  };
  const hostKey = (h) => String(h || '').toLowerCase().replace(/^www\\./, '');
  const sameSite = (a, b) => {
    const ha = hostKey(a), hb = hostKey(b);
    if (!ha || !hb) return false;
    if (ha === hb) return true;
    return ha.endsWith('.' + hb) || hb.endsWith('.' + ha);
  };
  const junkLabelRe = /^(?:中文(?:\\(简体\\)|（简体）)?|简体|繁體|繁体|english|日本語|한국어|hong\\s*kong|taiwan|singapore|全部播放列表|播放列表|playlists?|合作伙伴|经纪公司|關於我們|关于我们|隐私|privacy|terms|cookie|登录|登錄|注册|sign\\s*in|log\\s*in|language|語言|语言)\$/i;
  const junkPathRe = /\\/(?:language|lang|locale|i18n|partner|about|privacy|terms|login|signin|register|signup|playlist|playlists|tag|category|help|contact)(?:\\/|\$|\\?)/i;
  const junkQueryRe = /[?&](?:lang|locale|language|hl|country)=/i;
  const isJunk = (url, label) => {
    const text = String(label || '').replace(/\\s+/g, ' ').trim();
    if (text && junkLabelRe.test(text)) return true;
    const lower = String(url || '').toLowerCase();
    if (junkPathRe.test(lower) || junkQueryRe.test(lower)) return true;
    if (/(?:^|[\\/?#_-])(?:zh-cn|zh-tw|zh-hk|en-us|en-gb|ja-jp|ko-kr)(?:\$|[\\/?#_])/i.test(lower)) {
      return true;
    }
    return false;
  };
  const current = location.href;
  const curHost = location.hostname;
  const seen = new Set([current.split('#')[0]]);
  const pages = [];

  const push = (raw, label, score) => {
    const u = abs(raw);
    if (!u || !/^https?:/i.test(u)) return;
    let parsed;
    try { parsed = new URL(u); } catch (_) { return; }
    if (!sameSite(parsed.hostname, curHost)) return;
    const key = u.split('#')[0];
    if (seen.has(key)) return;
    const lower = key.toLowerCase();
    if (/\\.(mp4|webm|m3u8|jpg|jpeg|png|gif|webp|zip|rar|pdf|svg)(\\?|#|\$)/i.test(lower)) return;
    if (/(?:logout|signout|login|signin|register|javascript:|mailto:)/i.test(lower)) return;
    if (isJunk(key, label)) return;
    seen.add(key);
    pages.push({ url: key, label: String(label || '').slice(0, 40), score: score || 0 });
  };

  // 1) rel=next / prev
  document.querySelectorAll('a[rel="next"], link[rel="next"]').forEach(a =>
    push(a.href || a.getAttribute('href'), '下一页', 900));
  document.querySelectorAll('a[rel="prev"], link[rel="prev"]').forEach(a =>
    push(a.href || a.getAttribute('href'), '上一页', 850));

  // 2) 常见分页文案 / aria / page-navigator
  const nextRe = /^(下一页|下页|next|›|»|→|>|后页)\$/i;
  const prevRe = /^(上一页|上页|prev|previous|‹|«|←|<|前页)\$/i;
  Array.from(document.querySelectorAll(
    'a[href], .page-navigator a[href], nav a[href], button[onclick], [role="link"][href]'
  )).slice(0, 260).forEach(el => {
    const text = String(el.getAttribute('aria-label') || el.textContent || '')
      .replace(/\\s+/g, ' ').trim();
    const href = el.href || el.getAttribute('href') || '';
    if (!href) return;
    if (nextRe.test(text)) push(href, text || '下一页', 800);
    else if (prevRe.test(text)) push(href, text || '上一页', 780);
    else if (/page-link|pagination|pager|page-num|page_number|page-navigator/i.test(
      [el.className, el.id, (el.parentElement && el.parentElement.className) || ''].join(' ')
    )) {
      push(href, text || '分页', 500);
    }
  });

  // 3) URL 页码变体（page= / p= / /page/）
  try {
    const u = new URL(location.href);
    const tryParam = (name) => {
      if (!u.searchParams.has(name)) return;
      const cur = parseInt(u.searchParams.get(name) || '1', 10);
      if (!Number.isFinite(cur)) return;
      for (const d of [-1, 1, -2, 2, -3, 3]) {
        const n = cur + d;
        if (n < 1) continue;
        const nu = new URL(u.href);
        nu.searchParams.set(name, String(n));
        push(nu.href, '页码 ' + n, 600 - Math.abs(d) * 15);
      }
    };
    ['page', 'p', 'pn', 'pageNum', 'page_num', 'paged', 'offset'].forEach(tryParam);
    const path = u.pathname;
    const m = path.match(/^(.*\\/page\\/)(\\d+)(\\/?)\$/i) ||
      path.match(/^(.*\\/p\\/)(\\d+)(\\/?)\$/i) ||
      path.match(/^(.*\\/search\\/[^/]+\\/)(\\d+)(\\/?)\$/i);
    if (m) {
      const cur = parseInt(m[2], 10);
      for (const d of [-1, 1, 2]) {
        const n = cur + d;
        if (n < 1) continue;
        push(u.origin + m[1] + n + (m[3] || ''), '路径页 ' + n, 650);
      }
    }
  } catch (_) {}

  // 4) 内容卡片 / 详情链接（扩大整站覆盖）
  Array.from(document.querySelectorAll(
    'a[href*="/archives/"], a[href*="/post/"], a[href*="/video/"], a[href*="/watch/"],'
    + ' a.post-card, a.top_picks_item, article a[href], .post-card a[href], a[href*="/p/"]'
  )).slice(0, 220).forEach(a => {
    const href = a.href || a.getAttribute('href') || '';
    if (!href) return;
    let parsed;
    try { parsed = new URL(href, location.href); } catch (_) { return; }
    if (!sameSite(parsed.hostname, curHost)) return;
    const p = parsed.pathname || '';
    if (!/\\/(archives|post|video|watch|p)\\/\\d+/i.test(p) &&
        !/\\/archives\\/\\d+/i.test(p)) {
      // 仍允许明显内容路径
      if (!/\\/(tag|category|search|page)\\//i.test(p)) return;
    }
    const text = String(a.textContent || a.getAttribute('title') || '')
      .replace(/\\s+/g, ' ').trim().slice(0, 24);
    push(parsed.href, text || '内容页', 320);
  });

  // 5) 同路径层级下的兄弟列表链接（排除语言/导航垃圾）
  const curPath = (location.pathname || '/').replace(/\\/\$/, '') || '/';
  const parentPath = curPath.split('/').slice(0, -1).join('/') || '/';
  Array.from(document.querySelectorAll('a[href]')).slice(0, 140).forEach(a => {
    const href = a.href || '';
    if (!href) return;
    let parsed;
    try { parsed = new URL(href, location.href); } catch (_) { return; }
    if (!sameSite(parsed.hostname, curHost)) return;
    const p = (parsed.pathname || '/').replace(/\\/\$/, '') || '/';
    if (p === curPath) return;
    const parent = p.split('/').slice(0, -1).join('/') || '/';
    if (parent === parentPath && p.split('/').length === curPath.split('/').length) {
      const text = String(a.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 24);
      // 兄弟链接触发门槛更高：无数字内容 ID 且文案像导航则跳过
      if (!/\\d{2,}/.test(p) && junkLabelRe.test(text)) return;
      if (text.length <= 12 && /合作|经纪|伙伴|语言|語言|地区|地區|playlist/i.test(text)) return;
      push(parsed.href, text || '同级页', 200);
    }
  });

  pages.sort((a, b) => b.score - a.score);
  return {
    ok: true,
    current,
    pages: pages.slice(0, limit)
  };
})()
''';
  }
}
