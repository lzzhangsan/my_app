(() => {
  function __sbJunk(s) {
    return /(?:avatar|emoji|icon|logo|sprite|badge|qr|placeholder|skeleton|spacer|广告|ad[-_]|adservice|doubleclick|sponsor|promo|banner)/i.test(s || '');
  }
  function __sbAbs(raw) {
    if (!raw) return '';
    try { return new URL(String(raw), location.href).href; } catch (_) { return ''; }
  }
  function __sbIsPosterOrThumb(u) {
    const s = String(u || '').toLowerCase();
    if (!s) return true;
    if (/\.(m3u8|m3u|mpd|mp4|webm|mov|ts)(\?|#|$)/.test(s) || s.includes('mpegurl')) return false;
    if (/\.(jpg|jpeg|png|gif|webp|bmp|svg)(\?|#|$)/.test(s)) return true;
    return /(?:thumb|thumbnail|poster|cover|preview|sprite|storyboard|placeholder)/i.test(s);
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
    return /(?:doubleclick|googlesyndication|adsystem|adservice|adnxs|taboola|outbrain|criteo|\/ads\/|\/ad\/|vast|vpaid|prebid|pixel\.|analytics\.)/.test(s);
  }
  function __sbCardOf(el) {
    if (!el || !el.closest) return el;
    return el.closest(
      'article[data-testid="tweet"], article, li, [role="article"], [role="listitem"],' +
      ' figure, [class*="card"], [class*="Card"], [class*="post"], [class*="Post"],' +
      ' [class*="item"], [class*="Item"], [class*="tile"], [class*="media"], [data-testid*="cell"]'
    ) || el.parentElement || el;
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
      if (__sbJunk([src, el.alt, el.className, el.id].join(' '))) return false;
      return true;
    }
    if (tag === 'VIDEO') {
      if (Math.max(r.width, el.videoWidth || 0) < 100 ||
          Math.max(r.height, el.videoHeight || 0) < 70) return false;
      if (__sbJunk([el.className, el.id, el.getAttribute('aria-label') || ''].join(' '))) return false;
      if (el.closest && el.closest('[class*="video-ad"], [class*="preroll"], [id*="ad-"]')) return false;
      return true;
    }
    return false;
  }

  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;
  const rows = Array.from(document.querySelectorAll('video, img')).filter(__sbUsefulMedia).map(el => {
    const r = el.getBoundingClientRect();
    const visible = r.bottom > 0 && r.top < h && r.right > 0 && r.left < w;
    const dist = Math.abs((r.top + r.height / 2) - h / 2) +
      Math.abs((r.left + r.width / 2) - w / 2) * 0.25;
    return {el, dist, visible, tag: el.tagName, src: (el.currentSrc||el.src||'').slice(0,100),
      junkVideo: el.tagName==='VIDEO' ? __sbJunk([el.className, el.id, ''].join(' ')) : false,
      cls: String(el.className||'').slice(0,40)};
  });
  const pool = rows.filter(r => r.visible);
  const list = (pool.length ? pool : rows).slice().sort((a,b)=>a.dist-b.dist);
  const center = list[0] && list[0].el;

  // Why might main video be junk? czavbanner has banner!
  const videoUseful = Array.from(document.querySelectorAll('video')).map(v => ({
    id: v.id,
    cls: String(v.className||''),
    junk: __sbJunk([v.className, v.id, ''].join(' ')),
    useful: __sbUsefulMedia(v),
    src: (v.currentSrc||v.src||'').slice(0,120),
    card: (() => { const c=__sbCardOf(v); return (c.tagName||'')+String(c.className||'').slice(0,50); })()
  }));

  // collect at depth from center
  function collect(depth) {
    let scope = center;
    for (let i = 0; i < depth; i++) {
      if (!scope || !scope.parentElement) break;
      scope = scope.parentElement;
    }
    const groups = new Map();
    Array.from(scope.querySelectorAll('video, img')).forEach(el => {
      if (!__sbUsefulMedia(el)) return;
      const card = __sbCardOf(el);
      const g = groups.get(card) || {card, videos: [], images: []};
      if (el.tagName === 'VIDEO') g.videos.push(el); else g.images.push(el);
      groups.set(card, g);
    });
    const items = [];
    groups.forEach(g => {
      if (g.videos.length) {
        const video = g.videos[0];
        const url = __sbAbs(video.currentSrc || video.src);
        const streamOk = __sbIsStreamUrl(url) && !__sbIsPosterOrThumb(url);
        items.push({
          kind: 'video',
          url: streamOk ? url : '',
          raw: url.slice(0,140),
          streamOk,
          isPosterFlag: __sbIsPosterOrThumb(url),
          card: (g.card.tagName||'')+String(g.card.className||'').slice(0,40),
          junkCls: __sbJunk([video.className, video.id, ''].join(' '))
        });
      } else if (g.images.length) {
        items.push({kind:'image', url: __sbAbs(g.images[0].currentSrc||g.images[0].src).slice(0,100)});
      }
    });
    return {
      depth,
      scopeTag: (scope.tagName||'')+String(scope.className||'').slice(0,40),
      groups: groups.size,
      items: items.slice(0, 30),
      videoItems: items.filter(i=>i.kind==='video').length,
      imageItems: items.filter(i=>i.kind==='image').length
    };
  }

  const chain = [];
  let el = center;
  let depth = 0;
  while (el && depth < 14) {
    chain.push({
      depth,
      tag: (el.tagName||'')+String(el.className||'').slice(0,50),
      collect: collect(depth)
    });
    if (el === document.body) break;
    el = el.parentElement;
    depth++;
  }

  return {
    center: center && {
      tag: center.tagName,
      id: center.id,
      cls: String(center.className||''),
      src: (center.currentSrc||center.src||'').slice(0,140)
    },
    visibleUseful: pool.map(p => ({tag:p.tag, id:p.el.id, cls:p.cls, src:p.src, dist:Math.round(p.dist)})),
    videoUseful,
    chainSummary: chain.map(c => ({
      depth: c.depth,
      tag: c.tag,
      groups: c.collect.groups,
      videos: c.collect.videoItems,
      images: c.collect.imageItems,
      first: (c.collect.items[0]||null)
    })),
    depth0: collect(0),
    depth2: collect(2),
    depth5: collect(5),
    depth8: collect(8)
  };
})()
