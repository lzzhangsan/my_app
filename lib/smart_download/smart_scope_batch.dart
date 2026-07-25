/// 本页「同层批量」：按 DOM 层级收集平行媒体，视频优先于海报图。
class SmartScopeBatchJs {
  SmartScopeBatchJs._();

  /// 共用：广告/垃圾、URL 判定、嗅探池。
  static const helpers = r'''
  function __sbJunk(s) {
    return /(?:avatar|emoji|icon|logo|sprite|badge|qr|placeholder|skeleton|spacer|广告|ad[-_]|adservice|doubleclick|sponsor|promo|banner|hqmediago|czavbanner|prbn__)/i.test(s || '');
  }
  function __sbAbs(raw) {
    if (!raw) return '';
    try { return new URL(String(raw), location.href).href; } catch (_) { return ''; }
  }
  function __sbIsPosterOrThumb(u) {
    const s = String(u || '').toLowerCase();
    if (!s) return true;
    // 明确视频后缀先放行，再排除预览/listing 短片
    if (/\.(m3u8|m3u|mpd|mp4|webm|mov|ts)(\?|#|$)/.test(s) || s.includes('mpegurl')) {
      if (/(?:thumb|thumbnail|preview|sample|teaser|trailer|listing\d*\.mp4|\/peek\/)/i.test(s)) return true;
      return false;
    }
    if (/\.(jpg|jpeg|png|gif|webp|bmp|svg)(\?|#|$)/.test(s)) return true;
    return /(?:thumb|thumbnail|poster|cover|preview|sprite|storyboard|placeholder|\/peek\/)/i.test(s);
  }
  function __sbIsStreamUrl(u) {
    const s = String(u || '').toLowerCase();
    if (!s || s.startsWith('data:')) return false;
    if (s.startsWith('blob:')) return false;
    return /\.(m3u8|m3u|mpd|mp4|webm|mov)(\?|#|$)/.test(s) ||
      s.includes('mpegurl') || s.includes('/hls/') || s.includes('/manifest') ||
      s.includes('/stream') || s.includes('videodelivery') || s.includes('video.twimg');
  }
  function __sbIsAdUrl(u) {
    const s = String(u || '').toLowerCase();
    return /(?:doubleclick|googlesyndication|adsystem|adservice|adnxs|taboola|outbrain|criteo|\/ads\/|\/ad\/|vast|vpaid|prebid|pixel\.|analytics\.|hqmediago|czavbanner)/.test(s);
  }
  // xfree 等站点：listing/预览/封面 UUID → 同路径 full.mp4
  function __sbUpgradeToFullVideo(u) {
    const raw = __sbAbs(u);
    if (!raw) return '';
    try {
      const listing = raw.match(/^(https?:\/\/cdn\.xfree\.com\/xfree-prod\/(?:[0-9a-f]\/){3}[0-9a-f-]{36}\/)listing\d*\.mp4(\?.*)?$/i);
      if (listing) return listing[1] + 'full.mp4' + (listing[2] || '');
      const uuidRe = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i;
      const m = raw.match(uuidRe);
      if (m && /(?:thumbs\.xfree\.com|cdn\.xfree\.com|xfree\.com)/i.test(raw)) {
        const id = m[1].toLowerCase();
        return 'https://cdn.xfree.com/xfree-prod/' + id[0] + '/' + id[1] + '/' + id[2] + '/' + id + '/full.mp4';
      }
    } catch (_) {}
    return '';
  }
  function __sbScoreStream(u, meta) {
    const s = String(u || '').toLowerCase();
    if (!s || __sbIsAdUrl(s)) return -1e15;
    let score = 0;
    const ct = String((meta && meta.contentType) || '').toLowerCase();
    if (/\.m3u8|\.m3u|\.mpd|mpegurl|dash/.test(s) || ct.includes('mpegurl') || ct.includes('dash')) score += 1e9;
    else if (/\/full\.mp4(\?|#|$)/.test(s)) score += 9e8;
    else if (/\.mp4|\.webm|\.mov/.test(s) || ct.startsWith('video/')) score += 5e8;
    else if (__sbIsStreamUrl(s)) score += 2e8;
    else return -1e12;
    if (/(?:preview|sample|trailer|teaser|thumb|poster|storyboard|sprite|snippet|init\.|\/seg|\/chunk|\/fragment|\.m4s|listing\d*\.mp4|\/peek\/)/.test(s)) {
      score -= 1.2e9;
    }
    const age = meta && meta.timestamp ? (Date.now() - Number(meta.timestamp)) : 0;
    if (age > 0 && age < 120000) score += 5e7;
    return score;
  }
  function __sbCollectSniffPool() {
    const pool = new Map();
    const add = (url, meta) => {
      const u = __sbAbs(url);
      if (!u || __sbIsAdUrl(u)) return;
      if (!__sbIsStreamUrl(u) && !String((meta && meta.contentType) || '').toLowerCase().startsWith('video/')) {
        return;
      }
      const upgraded = __sbUpgradeToFullVideo(u);
      const finalUrl = upgraded || u;
      const score = __sbScoreStream(finalUrl, meta || {});
      if (score < 0) return;
      const prev = pool.get(finalUrl);
      if (!prev || score > prev.score) pool.set(finalUrl, { url: finalUrl, score, meta: meta || {} });
    };
    try {
      if (window.MediaInterceptor && window.MediaInterceptor.interceptedRequests) {
        for (const [u, info] of window.MediaInterceptor.interceptedRequests) {
          add(u, info);
        }
      }
    } catch (_) {}
    try {
      const early = window.__appEarlyMediaRequests;
      if (early && typeof early.forEach === 'function') {
        early.forEach((meta, url) => add(url, meta));
      } else if (early && typeof early.entries === 'function') {
        for (const [url, meta] of early.entries()) add(url, meta);
      }
    } catch (_) {}
    try {
      performance.getEntriesByType('resource').forEach(e => {
        add(e.name, { contentType: '', timestamp: Date.now(), type: 'performance' });
      });
    } catch (_) {}
    return Array.from(pool.values()).sort((a, b) => b.score - a.score);
  }
  function __sbCardOf(el) {
    if (!el || !el.closest) return el;
    return __sbFeedRoot(el) || el.closest(
      'article[data-testid="tweet"], article, li, [role="article"], [role="listitem"], figure,' +
      ' [class*="card"], [class*="Card"], [class*="post"], [class*="Post"],' +
      ' [class*="tile"], [data-testid*="cell"]'
    ) || el.closest('[class*="item"], [class*="Item"], [class*="media"]') ||
      el.parentElement || el;
  }
  function __sbUsefulMedia(el) {
    if (!el || el.nodeType !== 1) return false;
    const r = el.getBoundingClientRect();
    const tag = (el.tagName || '').toUpperCase();
    if (tag === 'IMG') {
      const width = Math.max(el.naturalWidth || 0, r.width || 0);
      const height = Math.max(el.naturalHeight || 0, r.height || 0);
      if (width < 160 || height < 120) return false;
      const src = String(el.currentSrc || el.src || el.getAttribute('data-src') || '');
      if (!src || src.startsWith('data:')) return false;
      const marker = [src, el.alt, el.className, el.id].join(' ');
      if (__sbJunk(marker)) return false;
      // 侧栏播放列表小缩略图不当成主体
      if (/(?:playlist__thumb|playlist-inner)/i.test(marker)) return false;
      return true;
    }
    if (tag === 'VIDEO') {
      if (Math.max(r.width, el.videoWidth || 0) < 100 ||
          Math.max(r.height, el.videoHeight || 0) < 70) return false;
      if (__sbJunk([el.className, el.id, el.getAttribute('aria-label') || ''].join(' '))) return false;
      if (el.closest && el.closest('[class*="video-ad"], [class*="preroll"], [id*="ad-"], [class*="prbn"]')) return false;
      return true;
    }
    return false;
  }
  function __sbImageUrl(img) {
    const srcset = (img.getAttribute('srcset') || '').split(',')
      .map(v => v.trim().split(' ')[0]).filter(Boolean);
    const raw = srcset[srcset.length - 1] || img.currentSrc ||
      img.getAttribute('data-original') || img.getAttribute('data-src') ||
      img.getAttribute('data-url') || img.src;
    const url = __sbAbs(raw);
    if (!url || url.startsWith('data:') || url.startsWith('blob:')) return '';
    return url;
  }
  function __sbAttrVideoHints(el) {
    const out = [];
    const push = (raw) => {
      const u = __sbAbs(raw);
      if (!u || u.startsWith('data:')) return;
      if (!out.includes(u)) out.push(u);
      const up = __sbUpgradeToFullVideo(u);
      if (up && !out.includes(up)) out.push(up);
    };
    if (!el || !el.getAttribute) return out;
    [
      'data-video-url', 'data-video-src', 'data-src', 'data-url', 'data-file',
      'data-source', 'data-stream', 'data-mp4', 'data-hls', 'data-media',
      'href', 'content'
    ].forEach(k => push(el.getAttribute(k)));
    return out;
  }
  function __sbHasPlayControl(root) {
    if (!root || !root.querySelector) return false;
    // 切勿用 [class*=play]：会误伤 playlist
    return !!(
      root.querySelector('video') ||
      root.querySelector('[aria-label*="play" i], [aria-label*="播放"], [data-video-url], [data-mp4], [data-hls]') ||
      root.querySelector('[class*="play-btn"], [class*="playBtn"], [class*="PlayButton"], [class*="video-play"]')
    );
  }
  function __sbCardHasVideoSignal(card) {
    if (!card) return false;
    if (card.querySelector && card.querySelector('video')) return true;
    const marker = String(card.className || '') + ' ' +
      (card.getAttribute && (card.getAttribute('aria-label') || '') || '');
    if (/(?:videoplayer|video-player|feeditem|wall__item__media)/i.test(marker)) return true;
    if (__sbHasPlayControl(card)) return true;
    const hints = [];
    try {
      __sbAttrVideoHints(card).forEach(u => hints.push(u));
      Array.from(card.querySelectorAll(
        'a[href], [data-video-url], [data-src], [data-mp4], [data-hls], source, img, video'
      )).slice(0, 20).forEach(n => {
        __sbAttrVideoHints(n).forEach(u => hints.push(u));
        if (n.tagName === 'IMG' || n.tagName === 'VIDEO') {
          const up = __sbUpgradeToFullVideo(n.currentSrc || n.src || '');
          if (up) hints.push(up);
        }
      });
    } catch (_) {}
    return hints.some(u => {
      const up = __sbUpgradeToFullVideo(u) || u;
      return __sbIsStreamUrl(up) && !__sbIsAdUrl(up);
    });
  }
  function __sbResolveVideoUrls(video, sniffPool) {
    const out = [];
    const push = (raw) => {
      const u = __sbAbs(raw);
      if (!u || u.startsWith('data:')) return;
      if (!out.includes(u)) out.push(u);
      const up = __sbUpgradeToFullVideo(u);
      if (up && !out.includes(up)) out.push(up);
    };
    push(video.currentSrc);
    push(video.src);
    __sbAttrVideoHints(video).forEach(push);
    Array.from(video.querySelectorAll('source')).forEach(s => {
      push(s.src);
      push(s.getAttribute('data-src'));
    });
    try {
      const card = __sbCardOf(video);
      if (card && card !== video) {
        __sbAttrVideoHints(card).forEach(push);
        Array.from(card.querySelectorAll(
          'a[href], source, [data-video-url], [data-src], [data-mp4], [data-hls], img'
        )).slice(0, 30).forEach(n => {
          __sbAttrVideoHints(n).forEach(push);
          if (n.tagName === 'IMG') push(n.currentSrc || n.src);
        });
      }
    } catch (_) {}
    try {
      if (typeof window.__appMediaFragmentsForVideo === 'function') {
        (window.__appMediaFragmentsForVideo(video) || []).forEach(push);
      }
    } catch (_) {}
    // 主片优先：full.mp4 > 其他流；listing/peek 不当主键
    const domStreams = out.filter(u => __sbIsStreamUrl(u) && !__sbIsAdUrl(u));
    const preferred = domStreams.filter(u => /\/full\.mp4(\?|#|$)/i.test(u));
    const decent = domStreams.filter(u => !__sbIsPosterOrThumb(u));
    const rankedDom = [...preferred, ...decent, ...domStreams]
      .filter((u, i, arr) => arr.indexOf(u) === i)
      .map(u => ({ url: u, score: __sbScoreStream(u, {}) + 5e8 }))
      .sort((a, b) => b.score - a.score).map(r => r.url);
    const sniffExtras = [];
    (sniffPool || []).slice(0, 20).forEach(row => {
      if (!out.includes(row.url) && !rankedDom.includes(row.url)) sniffExtras.push(row.url);
    });
    const rankedSniff = sniffExtras.map(u => ({
      url: u,
      score: __sbScoreStream(u, {})
    })).filter(r => r.score > 0).sort((a, b) => b.score - a.score).map(r => r.url);
    return [...rankedDom, ...rankedSniff, ...out.filter(u => !rankedDom.includes(u) && !rankedSniff.includes(u))];
  }
  function __sbPickCenter(imagesOnly, videosOnly) {
    const w = window.innerWidth || 360;
    const h = window.innerHeight || 640;
    const sel = imagesOnly ? 'img' : (videosOnly ? 'video' : 'video, img');
    const rows = Array.from(document.querySelectorAll(sel)).filter(__sbUsefulMedia).map(el => {
      const r = el.getBoundingClientRect();
      const visible = r.bottom > 0 && r.top < h && r.right > 0 && r.left < w;
      const dist = Math.abs((r.top + r.height / 2) - h / 2) +
        Math.abs((r.left + r.width / 2) - w / 2) * 0.25;
      const area = Math.max(0, r.width) * Math.max(0, r.height);
      // 视频权重大幅高于封面图，避免 peek/cover 抢中心
      let score = dist - area / 5000;
      if (el.tagName === 'VIDEO') score -= 500;
      if (el.tagName === 'IMG' && /(?:peek|cover|poster)/i.test(
        [el.className, el.id, (el.parentElement && el.parentElement.className) || '', el.src || ''].join(' ')
      )) score += 200;
      return {el, dist, visible, score};
    });
    const pool = rows.filter(r => r.visible);
    const list = (pool.length ? pool : rows).sort((a, b) => a.score - b.score);
    return list[0] && list[0].el;
  }
  function __sbFeedRoot(el) {
    if (!el) return null;
    let p = el;
    while (p && p.nodeType === 1) {
      const c = String(p.className || '');
      // 只要整卡 feeditem / wall__item，不要 feeditem__videoplayer 子块
      if (/(?:^|\s)feeditem(?:\s|$)/.test(c) || /(?:^|\s)wall__item(?:\s|$)/.test(c)) return p;
      if (p.matches && p.matches('article, [role="article"], li, figure')) return p;
      if (p === document.body || p === document.documentElement) break;
      p = p.parentElement;
    }
    return null;
  }
  function __sbEachMedia(root, sel, fn) {
    if (!root) return;
    try {
      if (root.matches && root.matches(sel) && __sbUsefulMedia(root)) fn(root);
    } catch (_) {}
    Array.from(root.querySelectorAll(sel)).forEach(el => {
      if (__sbUsefulMedia(el)) fn(el);
    });
  }
  function __sbWarmVideos(root) {
    const videos = Array.from((root || document).querySelectorAll('video')).filter(__sbUsefulMedia);
    videos.slice(0, 16).forEach(v => {
      try {
        v.setAttribute('data-app-smart-scope-warm', '1');
        v.muted = true;
        const p = v.play();
        if (p && typeof p.then === 'function') {
          p.then(() => { try { v.pause(); } catch (_) {} }).catch(() => {});
        }
        try { v.load(); } catch (_) {}
      } catch (_) {}
    });
    return videos.length;
  }
''';

  /// 从当前媒体到整页，枚举完整层级（外→内）并标注每层图/视频分布。
  static String listLevels({
    required bool imagesOnly,
    required bool videosOnly,
  }) {
    return '''
(() => {
  $helpers
  const imagesOnly = $imagesOnly;
  const videosOnly = $videosOnly;

  function analyzeScope(root, excludeInner) {
    const empty = {
      images: 0, videos: 0, total: 0,
      videoCards: 0, imageOnlyCards: 0, posterLikelyVideo: 0,
      rawImages: 0, rawVideos: 0
    };
    if (!root) return empty;
    const cards = new Map();
    let rawImages = 0, rawVideos = 0;
    const sel = imagesOnly ? 'img' : (videosOnly ? 'video' : 'video, img');
    Array.from(root.querySelectorAll(sel)).forEach(el => {
      if (!__sbUsefulMedia(el)) return;
      if (excludeInner && excludeInner.contains(el) && excludeInner !== el) return;
      if (el.tagName === 'VIDEO') rawVideos += 1; else rawImages += 1;
      const card = __sbCardOf(el);
      if (excludeInner && excludeInner.contains(card) && excludeInner !== card) return;
      const row = cards.get(card) || {hasVideo: false, hasImage: false, card};
      if (el.tagName === 'VIDEO') row.hasVideo = true; else row.hasImage = true;
      cards.set(card, row);
    });
    let videoCards = 0, imageOnlyCards = 0, posterLikelyVideo = 0;
    cards.forEach(row => {
      if (row.hasVideo) {
        videoCards += 1;
      } else if (row.hasImage) {
        if (__sbCardHasVideoSignal(row.card)) posterLikelyVideo += 1;
        else imageOnlyCards += 1;
      }
    });
    const videos = videoCards + posterLikelyVideo;
    const images = imageOnlyCards;
    return {
      images, videos, total: images + videos,
      videoCards, imageOnlyCards, posterLikelyVideo,
      rawImages, rawVideos
    };
  }

  function describeNode(el, depth, fromTop, totalLevels) {
    const tag = (el.tagName || '').toLowerCase();
    const cls = String(el.className || '').toString().slice(0, 36);
    const id = el.id ? '#' + el.id : '';
    const role = el.getAttribute && (el.getAttribute('role') || '');
    const key = tag + ' ' + cls + ' ' + id + ' ' + role;
    let short = tag + id;
    let kind = '容器';
    if (depth === 0) { short = '当前媒体'; kind = '最内层'; }
    else if (el === document.body || el === document.documentElement) {
      short = '整页'; kind = '最外层';
    } else if (/article|card|item|post|tweet|cell|tile/i.test(key)) {
      short = '卡片/条目'; kind = '条目层';
    } else if (/feed|list|grid|main|section|timeline|scroll/i.test(key)) {
      short = '列表/信息流'; kind = '列表层';
    } else if (/dialog|modal|sheet|overlay|drawer/i.test(key)) {
      short = '弹层'; kind = '弹层';
    }
    return {
      label: 'L' + fromTop + ' · ' + short,
      kind,
      pathHint: fromTop === 1
        ? '最外'
        : (fromTop === totalLevels ? '最内' : ('自上第' + fromTop + '层')),
      tag: tag + id
    };
  }

  const center = __sbPickCenter(imagesOnly, videosOnly);
  if (!center) return {ok: false, levels: [], reason: 'no_media', totalLevels: 0};

  const chain = [];
  let el = center;
  const seen = new Set();
  let depth = 0;
  while (el && el.nodeType === 1 && depth < 16) {
    if (seen.has(el)) break;
    seen.add(el);
    chain.push({el, depth});
    if (el === document.body || el === document.documentElement) break;
    el = el.parentElement;
    depth += 1;
  }
  const totalLevels = chain.length;
  const ordered = chain.slice().reverse();
  const levels = [];
  ordered.forEach((node, i) => {
    const fromTop = i + 1;
    const innerEl = i + 1 < ordered.length ? ordered[i + 1].el : null;
    const inclusive = analyzeScope(node.el, null);
    const exclusive = analyzeScope(node.el, innerEl);
    const meta = describeNode(node.el, node.depth, fromTop, totalLevels);
    let hint = '';
    if (inclusive.posterLikelyVideo > 0 && inclusive.rawVideos === 0) {
      hint = '本层多为海报，真实视频可能在更内层或需嗅探';
    } else if (innerEl) {
      const child = analyzeScope(innerEl, null);
      if (child.rawVideos > inclusive.rawVideos && inclusive.posterLikelyVideo > 0) {
        hint = '更内层有更多真实 <video>，可对比选择';
      } else if (child.videos > inclusive.videoCards && inclusive.rawVideos < child.rawVideos) {
        hint = '更内层视频更多，可对比选择';
      }
    }
    if (!hint && inclusive.videos >= inclusive.images && inclusive.videos > 0) {
      hint = '本层视频较多，适合批量';
    } else if (!hint && inclusive.images > 0 && inclusive.videos === 0) {
      hint = '本层主要是图片';
    }
    levels.push({
      depth: node.depth,
      fromTop,
      totalLevels,
      label: meta.label,
      kind: meta.kind,
      pathHint: meta.pathHint,
      tag: meta.tag,
      images: inclusive.images,
      videos: inclusive.videos,
      total: inclusive.total,
      videoCards: inclusive.videoCards,
      imageOnlyCards: inclusive.imageOnlyCards,
      posterLikelyVideo: inclusive.posterLikelyVideo,
      rawImages: inclusive.rawImages,
      rawVideos: inclusive.rawVideos,
      exclusiveImages: exclusive.images,
      exclusiveVideos: exclusive.videos,
      exclusivePoster: exclusive.posterLikelyVideo,
      exclusiveRawVideos: exclusive.rawVideos,
      hint,
      recommend: false
    });
  });

  let best = null;
  levels.forEach(l => {
    if (l.total < 1) return;
    // 优先真实 <video> / 可升级片源，打压「整页缩略图墙」
    const score = (l.rawVideos * 5000) + (l.videoCards * 2000) + (l.posterLikelyVideo * 600)
      + Math.min(l.total, 12) * 15
      - (l.imageOnlyCards * 30)
      - (l.depth === 0 ? 80 : 0)
      - (l.pathHint === '最外' ? 200 : 0)
      - (l.total > 20 && l.rawVideos < 2 ? 500 : 0);
    if (!best || score > best._score) {
      best = l;
      best._score = score;
    }
  });
  if (best) best.recommend = true;
  const defaultDepth = best
    ? best.depth
    : (levels.length ? levels[levels.length - 1].depth : 0);

  return {
    ok: true,
    totalLevels,
    defaultDepth,
    centerTag: center.tagName || '',
    summary: '共 ' + totalLevels + ' 层（最外 L1 → 最内 L' + totalLevels
      + '）。选一层即下载该层范围内去广告后的媒体；视频优先于海报。',
    levels
  };
})()
''';
  }

  /// 预热同层 video（短暂 play/load），促使嗅探器抓到真实流地址。
  static String warmScope({required int depth}) {
    final d = depth.clamp(0, 20);
    return '''
(() => {
  $helpers
  const targetDepth = $d;
  const center = __sbPickCenter(false, false);
  if (!center) return {ok: false, warmed: 0};
  let scope = center;
  for (let i = 0; i < targetDepth; i++) {
    if (!scope.parentElement) break;
    scope = scope.parentElement;
  }
  const warmed = __sbWarmVideos(scope);
  const pool = __sbCollectSniffPool();
  return {ok: true, warmed, sniffed: pool.length};
})()
''';
  }

  /// 在指定 depth 的祖先容器内收集媒体；同一卡片优先视频。
  static String collectAtDepth({
    required int depth,
    required bool imagesOnly,
    required bool videosOnly,
    required int limit,
  }) {
    final d = depth.clamp(0, 20);
    final lim = limit.clamp(1, 100);
    return '''
(() => {
  $helpers
  const targetDepth = $d;
  const imagesOnly = $imagesOnly;
  const videosOnly = $videosOnly;
  const limit = $lim;
  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;

  const center = __sbPickCenter(imagesOnly, videosOnly);
  if (!center) return {ok: false, items: [], reason: 'no_media'};
  let scope = center;
  for (let i = 0; i < targetDepth; i++) {
    if (!scope.parentElement) break;
    scope = scope.parentElement;
  }
  try {
    document.querySelectorAll('[data-smart-seed-scope],[data-smart-seed-media]').forEach(n => {
      n.removeAttribute('data-smart-seed-scope');
      n.removeAttribute('data-smart-seed-media');
    });
    center.setAttribute('data-smart-seed-media', '1');
    scope.setAttribute('data-smart-seed-scope', '1');
  } catch (_) {}

  __sbWarmVideos(scope);
  const sniffPool = __sbCollectSniffPool();

  function feedRoot(el) { return __sbFeedRoot(el) || __sbCardOf(el); }

  // 按「条目」归组：封面图与主 video 并到同一 feeditem；含 scope 自身
  const groups = new Map();
  const sel = imagesOnly ? 'img' : (videosOnly ? 'video' : 'video, img');
  __sbEachMedia(scope, sel, el => {
    const card = feedRoot(el);
    const g = groups.get(card) || {card, videos: [], images: []};
    if (el.tagName === 'VIDEO') g.videos.push(el); else g.images.push(el);
    groups.set(card, g);
  });
  if (!imagesOnly) {
    __sbEachMedia(scope, 'video', video => {
      let owned = false;
      groups.forEach(g => { if (g.videos.indexOf(video) >= 0) owned = true; });
      if (owned) return;
      const card = feedRoot(video);
      const g = groups.get(card) || {card, videos: [], images: []};
      g.videos.push(video);
      groups.set(card, g);
    });
  }

  const items = [];
  const seenUrl = new Set();
  const sniffCandidates = sniffPool.slice(0, 20).map(r => r.url);

  groups.forEach(g => {
    const sample = (g.videos[0] || g.images[0]);
    if (!sample) return;
    const r = sample.getBoundingClientRect();
    const visible = r.bottom > 0 && r.top < h && r.right > 0 && r.left < w;
    const centerDistance = Math.abs((r.top + r.height / 2) - h / 2) +
      Math.abs((r.left + r.width / 2) - w / 2) * 0.25;

    if (!imagesOnly && g.videos.length) {
      // 同一条目多个 video 时优先面积最大（主播放器）
      g.videos.sort((a, b) => {
        const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
        return (rb.width * rb.height) - (ra.width * ra.height);
      });
      const video = g.videos[0];
      const urls = __sbResolveVideoUrls(video, sniffPool);
      const streams = urls.filter(u => __sbIsStreamUrl(u) && !__sbIsAdUrl(u) && (
        /\/full\.mp4(\?|#|\$)/i.test(u) || !__sbIsPosterOrThumb(u)
      ));
      const primary = streams[0] || urls.find(u => /\/full\.mp4(\?|#|\$)/i.test(u)) || '';
      const candidates = [
        ...streams.slice(1),
        ...urls.filter(u => u !== primary && __sbIsStreamUrl(u) && !__sbIsAdUrl(u)),
        ...sniffCandidates
      ].filter((u, i, arr) => u && u !== primary && arr.indexOf(u) === i).slice(0, 12);
      if (primary) {
        if (seenUrl.has(primary)) return;
        seenUrl.add(primary);
        items.push({
          url: primary,
          kind: 'video',
          candidates,
          score: (visible ? 3000000 : 1000000) - centerDistance + Math.min(r.width * r.height, 500000) / 100
        });
        return;
      }
      items.push({
        url: '',
        kind: 'video',
        needsSniff: true,
        candidates: candidates.length ? candidates : sniffCandidates.slice(0, 12),
        x: (r.left + r.width / 2) / w,
        y: (r.top + r.height / 2) / h,
        score: (visible ? 2500000 : 800000) - centerDistance
      });
      return;
    }

    if (!videosOnly && g.images.length) {
      const img = g.images[0];
      const poster = __sbImageUrl(img);
      // 同条目已有 video 时跳过封面
      if (!imagesOnly && g.videos.length) return;
      const upgraded = __sbUpgradeToFullVideo(poster);
      const hints = [];
      if (upgraded) hints.push(upgraded);
      __sbAttrVideoHints(img).forEach(u => hints.push(u));
      __sbAttrVideoHints(g.card).forEach(u => hints.push(u));
      Array.from(g.card.querySelectorAll(
        'a[href], [data-video-url], [data-src], [data-mp4], [data-hls], source, video, img'
      )).slice(0, 32).forEach(n => {
        __sbAttrVideoHints(n).forEach(u => hints.push(u));
        if (n.tagName === 'IMG' || n.tagName === 'VIDEO') {
          const up = __sbUpgradeToFullVideo(n.currentSrc || n.src || '');
          if (up) hints.push(up);
        }
      });
      let deep = img.parentElement;
      for (let i = 0; i < 4 && deep && deep !== scope; i++) {
        __sbAttrVideoHints(deep).forEach(u => hints.push(u));
        deep = deep.parentElement;
      }
      const streamHints = hints
        .map(u => __sbUpgradeToFullVideo(u) || u)
        .filter(u => __sbIsStreamUrl(u) && !__sbIsAdUrl(u))
        .filter((u, i, arr) => arr.indexOf(u) === i);
      const preferred = streamHints.filter(u => /\/full\.mp4(\?|#|\$)/i.test(u));
      const decent = streamHints.filter(u => !__sbIsPosterOrThumb(u));
      const ranked = [...preferred, ...decent, ...streamHints].filter((u, i, a) => a.indexOf(u) === i);
      const looksVideoPoster = ranked.length > 0 || __sbCardHasVideoSignal(g.card) ||
        /(?:wall__item|feeditem|videoplayer|listing\/)/i.test(
          [img.className, img.id, g.card.className || '', poster].join(' ')
        );
      if (!imagesOnly && looksVideoPoster) {
        const primary = ranked[0] || '';
        const candidates = [
          ...ranked.slice(1),
          ...sniffCandidates
        ].filter((u, i, arr) => u && u !== primary && arr.indexOf(u) === i).slice(0, 12);
        if (primary) {
          if (seenUrl.has(primary)) return;
          seenUrl.add(primary);
          items.push({
            url: primary,
            kind: 'video',
            candidates,
            posterUrl: poster,
            upgradedFromImage: true,
            score: (visible ? 2800000 : 900000) - centerDistance
          });
          return;
        }
        items.push({
          url: '',
          kind: 'video',
          needsSniff: true,
          candidates,
          posterUrl: poster,
          upgradedFromImage: true,
          x: (r.left + r.width / 2) / w,
          y: (r.top + r.height / 2) / h,
          score: (visible ? 2600000 : 850000) - centerDistance
        });
        return;
      }
      if (poster && !seenUrl.has(poster) && !__sbIsAdUrl(poster)) {
        seenUrl.add(poster);
        items.push({
          url: poster,
          kind: 'image',
          candidates: [],
          score: (visible ? 1000000 : 0) - centerDistance + (r.width * r.height) / 1000
        });
      }
    }
  });

  items.sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === 'video' ? -1 : 1;
    return b.score - a.score;
  });
  return {
    ok: true,
    depth: targetDepth,
    sniffed: sniffPool.length,
    total: items.length,
    videoCount: items.filter(i => i.kind === 'video').length,
    imageCount: items.filter(i => i.kind === 'image').length,
    centerTag: center.tagName || '',
    centerId: center.id || '',
    items: items.slice(0, limit)
  };
})()
''';
  }
}
