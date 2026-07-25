/// JS helpers for smart-download action parts.
/// Each snippet must produce real page effects (scroll/touch/click), not labels only.
class SmartActionJs {
  SmartActionJs._();

  /// Shared: find best vertical/horizontal scrollable under viewport center.
  static const finderPreamble = r'''
function __smartIsScrollable(el, axis) {
  if (!el || el.nodeType !== 1) return false;
  const style = getComputedStyle(el);
  if (axis === 'y') {
    const oy = style.overflowY;
    return (oy === 'auto' || oy === 'scroll' || oy === 'overlay') &&
      el.scrollHeight > el.clientHeight + 8;
  }
  const ox = style.overflowX;
  return (ox === 'auto' || ox === 'scroll' || ox === 'overlay') &&
    el.scrollWidth > el.clientWidth + 8;
}
function __smartFindScroller(axis, preferRemain) {
  const cx = Math.floor((window.innerWidth || 360) / 2);
  const cy = Math.floor((window.innerHeight || 640) * 0.52);
  const chain = [];
  let el = document.elementFromPoint(cx, cy);
  while (el) { chain.push(el); el = el.parentElement; }
  const extras = Array.from(document.querySelectorAll(
    'div, main, section, article, ul, ol, [class*="scroll"], [class*="feed"],' +
    '[class*="list"], [class*="swiper"], [class*="container"], [role="main"], [role="feed"]'
  )).filter(n => {
    const r = n.getBoundingClientRect();
    return r.width > (innerWidth || 360) * 0.35 &&
      r.height > (innerHeight || 640) * 0.3;
  });
  const candidates = chain.concat(extras);
  const root = document.scrollingElement || document.documentElement || document.body;
  if (root) candidates.push(root);
  let best = null;
  let bestScore = -1;
  for (const c of candidates) {
    if (!__smartIsScrollable(c, axis)) continue;
    const remain = axis === 'y'
      ? (preferRemain > 0
          ? (c.scrollHeight - c.clientHeight - c.scrollTop)
          : c.scrollTop)
      : (preferRemain > 0
          ? (c.scrollWidth - c.clientWidth - c.scrollLeft)
          : c.scrollLeft);
    const size = axis === 'y' ? c.clientHeight : c.clientWidth;
    const score = size + (remain > 4 ? size : 0) + (chain.indexOf(c) >= 0 ? 200 : 0);
    if (score > bestScore) { best = c; bestScore = score; }
  }
  return best || root || document.documentElement || document.body;
}
function __smartMakeTouch(target, id, clientX, clientY) {
  const pageX = clientX + (window.scrollX || 0);
  const pageY = clientY + (window.scrollY || 0);
  if (typeof Touch !== 'undefined') {
    try {
      return new Touch({
        identifier: id, target,
        clientX, clientY, pageX, pageY, screenX: clientX, screenY: clientY,
        radiusX: 14, radiusY: 14, force: 0.85
      });
    } catch (_) {}
  }
  return {
    identifier: id, target,
    clientX, clientY, pageX, pageY, screenX: clientX, screenY: clientY,
    radiusX: 14, radiusY: 14, force: 0.85
  };
}
function __smartFireTouch(target, type, touch, active, includeMouse) {
  const touches = active ? [touch] : [];
  let ev = null;
  try {
    ev = new TouchEvent(type, {
      bubbles: true, cancelable: true, composed: true,
      touches, targetTouches: touches, changedTouches: [touch]
    });
  } catch (_) {
    ev = new Event(type, {bubbles: true, cancelable: true});
    try {
      Object.defineProperty(ev, 'touches', {configurable: true, value: touches});
      Object.defineProperty(ev, 'targetTouches', {configurable: true, value: touches});
      Object.defineProperty(ev, 'changedTouches', {configurable: true, value: [touch]});
    } catch (_) {}
  }
  target.dispatchEvent(ev);
  try {
    const map = {touchstart: 'pointerdown', touchmove: 'pointermove', touchend: 'pointerup'};
    const pType = map[type];
    if (pType && typeof PointerEvent !== 'undefined') {
      target.dispatchEvent(new PointerEvent(pType, {
        bubbles: true, cancelable: true, composed: true,
        clientX: touch.clientX, clientY: touch.clientY,
        pointerId: touch.identifier, pointerType: 'touch',
        isPrimary: true, pressure: type === 'touchend' ? 0 : 0.5,
        buttons: type === 'touchend' ? 0 : 1
      }));
    }
  } catch (_) {}
  // 滑动手势不要附带 mouse：mousedown/up 容易被当成点击
  if (includeMouse === false) return;
  try {
    const map = {touchstart: 'mousedown', touchmove: 'mousemove', touchend: 'mouseup'};
    const mType = map[type];
    if (mType) {
      target.dispatchEvent(new MouseEvent(mType, {
        bubbles: true, cancelable: true, composed: true,
        clientX: touch.clientX, clientY: touch.clientY,
        button: 0, buttons: type === 'touchend' ? 0 : 1
      }));
    }
  } catch (_) {}
}
function __smartIsInteractive(el) {
  if (!el || el.nodeType !== 1) return false;
  const tag = (el.tagName || '').toUpperCase();
  if (['A','BUTTON','INPUT','TEXTAREA','SELECT','LABEL','SUMMARY','VIDEO','AUDIO'].includes(tag)) {
    return true;
  }
  const role = (el.getAttribute && el.getAttribute('role')) || '';
  if (role === 'button' || role === 'link' || role === 'tab' || role === 'menuitem') return true;
  if (el.isContentEditable) return true;
  return false;
}
function __smartPickSwipeTarget(x, y, preferred) {
  if (preferred && preferred.nodeType === 1) return preferred;
  try {
    const stack = document.elementsFromPoint(x, y) || [];
    for (const el of stack) {
      if (!el || el === document.documentElement || el === document.body) continue;
      if (__smartIsInteractive(el)) continue;
      if (el.closest && el.closest('a[href], button, [role="button"], input, textarea, select, video, audio')) {
        continue;
      }
      return el;
    }
  } catch (_) {}
  return preferred || document.scrollingElement || document.body;
}
''';

  static String scrollRelative({
    required double fraction,
    required int direction,
  }) {
    final f = fraction.clamp(0.1, 2.0);
    final d = direction >= 0 ? 1 : -1;
    return '''
(() => {
  $finderPreamble
  const fraction = $f;
  const direction = $d;
  const scroller = __smartFindScroller('y', direction);
  const before = Number(scroller.scrollTop || 0);
  const amount = Math.max(
    160,
    Math.floor((scroller.clientHeight || window.innerHeight || 640) * fraction)
  );
  const delta = direction * amount;
  try { scroller.scrollBy({top: delta, left: 0, behavior: 'auto'}); } catch (_) {
    scroller.scrollTop = before + delta;
  }
  let after = Number(scroller.scrollTop || 0);
  if (Math.abs(after - before) < 2) {
    scroller.scrollTop = before + delta;
    after = Number(scroller.scrollTop || 0);
  }
  try {
    scroller.dispatchEvent(new WheelEvent('wheel', {
      deltaY: delta, bubbles: true, cancelable: true, deltaMode: 0
    }));
  } catch (_) {}
  if (scroller === document.scrollingElement ||
      scroller === document.documentElement ||
      scroller === document.body) {
    try { window.scrollBy(0, delta); } catch (_) {}
  }
  after = Number(scroller.scrollTop || 0);
  return {
    ok: true,
    moved: Math.abs(after - before),
    before, after,
    tag: (scroller.tagName || '') + (scroller.id ? '#' + scroller.id : '')
  };
})()
''';
  }

  /// 按屏幕尺寸推进一屏（意图驱动：直接滚一屏，不做假手指）。
  /// axisHint: up|down|left|right —— up = 内容向上走 / 看下面更多
  static String screenSwipe({
    required String axisHint,
    double fraction = 0.85,
  }) {
    final axis = axisHint;
    final f = fraction.clamp(0.4, 1.0);
    return '''
(() => {
  $finderPreamble
  const axisHint = '$axis';
  const fraction = $f;
  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;
  const vertical = axisHint === 'up' || axisHint === 'down';
  const distance = Math.max(160, Math.floor((vertical ? h : w) * fraction));
  let dx = 0, dy = 0;
  if (axisHint === 'up') dy = distance;
  else if (axisHint === 'down') dy = -distance;
  else if (axisHint === 'left') dx = distance;
  else dx = -distance;

  function pickOneScroller() {
    const axis = vertical ? 'y' : 'x';
    const preferRemain = (axisHint === 'up' || axisHint === 'left') ? 1 : -1;
    let best = null;
    let bestScore = -1;
    const cx = Math.floor(w * 0.5);
    const cy = Math.floor(h * 0.5);
    const chain = [];
    let el = document.elementFromPoint(cx, cy);
    while (el) { chain.push(el); el = el.parentElement; }
    const root = document.scrollingElement || document.documentElement || document.body;
    for (const c of chain.concat([root, document.documentElement, document.body])) {
      if (!c || c.nodeType !== 1) continue;
      const style = getComputedStyle(c);
      let size = 0, remain = 0, can = false;
      if (axis === 'y') {
        size = c.clientHeight || 0;
        if (c.scrollHeight <= size + 4) continue;
        const oy = style.overflowY;
        can = oy === 'auto' || oy === 'scroll' || oy === 'overlay' || oy === 'hidden' ||
          c === root || c === document.documentElement || c === document.body;
        if (!can) continue;
        remain = preferRemain > 0 ? (c.scrollHeight - size - c.scrollTop) : c.scrollTop;
      } else {
        size = c.clientWidth || 0;
        if (c.scrollWidth <= size + 4) continue;
        const ox = style.overflowX;
        can = ox === 'auto' || ox === 'scroll' || ox === 'overlay' || ox === 'hidden' ||
          c === root || c === document.documentElement || c === document.body;
        if (!can) continue;
        remain = preferRemain > 0 ? (c.scrollWidth - size - c.scrollLeft) : c.scrollLeft;
      }
      const score = size + (chain.indexOf(c) >= 0 ? 400 : 0) + (remain > 8 ? 150 : 0);
      if (score > bestScore) { best = c; bestScore = score; }
    }
    return best || root;
  }

  const scroller = pickOneScroller();
  const beforeY = Number(scroller.scrollTop || 0);
  const beforeX = Number(scroller.scrollLeft || 0);
  const winBeforeY = Number(window.scrollY || window.pageYOffset || 0);
  const winBeforeX = Number(window.scrollX || window.pageXOffset || 0);
  try {
    scroller.scrollBy({ top: dy, left: dx, behavior: 'smooth' });
  } catch (_) {
    try {
      scroller.scrollTop = beforeY + dy;
      scroller.scrollLeft = beforeX + dx;
    } catch (__) {}
  }
  // 若 smooth 未立刻生效，下一帧强制落到目标，保证「就滚这一下」
  const targetY = beforeY + dy;
  const targetX = beforeX + dx;
  setTimeout(() => {
    try {
      if (Math.abs(Number(scroller.scrollTop || 0) - targetY) > 8 && dy) {
        scroller.scrollTop = targetY;
      }
      if (Math.abs(Number(scroller.scrollLeft || 0) - targetX) > 8 && dx) {
        scroller.scrollLeft = targetX;
      }
      const isRoot = scroller === document.scrollingElement ||
        scroller === document.documentElement || scroller === document.body;
      if (isRoot) {
        try { window.scrollTo(winBeforeX + dx, winBeforeY + dy); } catch (_) {}
      }
    } catch (_) {}
  }, 80);

  const afterY = Number(scroller.scrollTop || 0);
  const afterX = Number(scroller.scrollLeft || 0);
  return {
    ok: true,
    intent: 'screen_page',
    axisHint,
    dx, dy,
    moved: Math.abs(afterY - beforeY) + Math.abs(afterX - beforeX),
    movedY: Math.abs(afterY - beforeY),
    movedX: Math.abs(afterX - beforeX),
    beforeY, afterY, beforeX, afterX,
    vh: h, vw: w,
    tag: (scroller.tagName || '') + (scroller.id ? '#' + scroller.id : ''),
    scheduledMs: 480
  };
})()
''';
  }

  static String scrollEdge({required bool toTop}) {
    return '''
(() => {
  $finderPreamble
  const scroller = __smartFindScroller('y', ${toTop ? -1 : 1});
  const before = Number(scroller.scrollTop || 0);
  const target = ${toTop ? 0 : 'scroller.scrollHeight'};
  try { scroller.scrollTo({top: target, behavior: 'smooth'}); } catch (_) {
    scroller.scrollTop = target;
  }
  if (scroller === document.scrollingElement ||
      scroller === document.documentElement) {
    try { window.scrollTo(0, target); } catch (_) {}
  }
  return {ok: true, before, after: Number(scroller.scrollTop || 0)};
})()
''';
  }

  /// 定位相邻媒体（意图驱动：找到下一条 → scrollIntoView，不做假滑动）。
  /// direction: next | prev ； axisHint: up | down | left | right（用于挑空间相邻项）
  static String swipeToAdjacentMedia({
    required String direction,
    required String axisHint,
    required bool imagesOnly,
    required bool videosOnly,
    bool autoAxis = false,
  }) {
    final dir = direction == 'prev' ? 'prev' : 'next';
    final axis = axisHint;
    return '''
(() => {
  $finderPreamble
  let direction = '$dir';
  let axisHint = '$axis';
  const autoAxis = $autoAxis;
  const imagesOnly = $imagesOnly;
  const videosOnly = $videosOnly;
  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;
  const selector = imagesOnly ? 'img' : (videosOnly ? 'video' : 'video, img');

  function collect() {
    return Array.from(document.querySelectorAll(selector)).filter(el => {
      const r = el.getBoundingClientRect();
      if (r.width < 90 || r.height < 70) return false;
      if (el.tagName === 'IMG') {
        const src = String(el.currentSrc || el.src || '').toLowerCase();
        if (/(avatar|emoji|icon|logo|profile_images|profile_banners|sprite)/.test(src)) {
          return false;
        }
      }
      return true;
    }).map(el => {
      const r = el.getBoundingClientRect();
      const x = r.left + r.width / 2;
      const y = r.top + r.height / 2;
      const visible = r.bottom > 0 && r.top < h && r.right > 0 && r.left < w;
      return {el, x, y, r, visible};
    }).sort((a, b) => {
      if (Math.abs(a.y - b.y) > 48) return a.y - b.y;
      return a.x - b.x;
    });
  }

  const rows = collect();
  if (!rows.length) return {ok: false, reason: 'no_media', intent: 'find_media'};

  let current = rows.find(r => r.el.getAttribute('data-app-smart-current') === '1');
  if (!current) {
    const visible = rows.filter(r => r.visible);
    const pool = visible.length ? visible : rows;
    current = pool.slice().sort((a, b) => {
      const da = Math.abs(a.y - h / 2) + Math.abs(a.x - w / 2) * 0.25;
      const db = Math.abs(b.y - h / 2) + Math.abs(b.x - w / 2) * 0.25;
      return da - db;
    })[0];
  }
  const curIdx = rows.indexOf(current);

  if (autoAxis && direction === 'next') {
    const rightSibling = rows.find(r =>
      r !== current && Math.abs(r.y - current.y) < 90 && r.x > current.x + 40
    );
    const belowSibling = rows.find(r => r !== current && r.y > current.y + 40);
    if (rightSibling && (!belowSibling || (rightSibling.x - current.x) < (belowSibling.y - current.y))) {
      axisHint = 'left';
    } else {
      axisHint = 'up';
    }
  }

  function pickSpatial() {
    if (axisHint === 'left' || axisHint === 'right') {
      const sameRow = rows.filter(r => r !== current && Math.abs(r.y - current.y) < 90);
      if (direction === 'next') {
        const right = sameRow.filter(r => r.x > current.x + 24).sort((a, b) => a.x - b.x);
        if (right[0]) return right[0];
        const below = rows.filter(r => r.y > current.y + 40).sort((a, b) => a.y - b.y || a.x - b.x);
        if (below[0]) return below[0];
      } else {
        const left = sameRow.filter(r => r.x < current.x - 24).sort((a, b) => b.x - a.x);
        if (left[0]) return left[0];
        const above = rows.filter(r => r.y < current.y - 40).sort((a, b) => b.y - a.y || b.x - a.x);
        if (above[0]) return above[0];
      }
    } else {
      if (direction === 'next') {
        const below = rows.filter(r => r.y > current.y + 40).sort((a, b) => a.y - b.y || a.x - b.x);
        if (below[0]) return below[0];
        const right = rows.filter(r => Math.abs(r.y - current.y) < 90 && r.x > current.x + 24)
          .sort((a, b) => a.x - b.x);
        if (right[0]) return right[0];
      } else {
        const above = rows.filter(r => r.y < current.y - 40).sort((a, b) => b.y - a.y || b.x - a.x);
        if (above[0]) return above[0];
        const left = rows.filter(r => Math.abs(r.y - current.y) < 90 && r.x < current.x - 24)
          .sort((a, b) => b.x - a.x);
        if (left[0]) return left[0];
      }
    }
    return null;
  }

  let next = pickSpatial();
  if (!next && curIdx >= 0) {
    if (direction === 'next' && curIdx + 1 < rows.length) next = rows[curIdx + 1];
    if (direction === 'prev' && curIdx - 1 >= 0) next = rows[curIdx - 1];
  }

  rows.forEach(r => r.el.removeAttribute('data-app-smart-current'));

  if (next) {
    try {
      next.el.scrollIntoView({behavior: 'smooth', block: 'center', inline: 'nearest'});
    } catch (_) {
      try { next.el.scrollIntoView(true); } catch (__) {}
    }
    next.el.setAttribute('data-app-smart-current', '1');
    const nr = next.el.getBoundingClientRect();
    return {
      ok: true,
      intent: 'find_media',
      foundNext: true,
      fromX: current.x / w,
      fromY: current.y / h,
      toX: (nr.left + nr.width / 2) / w,
      toY: (nr.top + nr.height / 2) / h,
      scheduledMs: 520,
      axisHint,
      index: rows.indexOf(next),
      total: rows.length
    };
  }

  // 没有下一条可见媒体：只推进一屏（同方向），再等下一轮识别
  const distance = Math.max(180, Math.floor((axisHint === 'left' || axisHint === 'right' ? w : h) * 0.75));
  try {
    const scroller = __smartFindScroller(
      (axisHint === 'left' || axisHint === 'right') ? 'x' : 'y',
      direction === 'next' ? 1 : -1
    );
    if (axisHint === 'left' || axisHint === 'right') {
      scroller.scrollBy({
        left: direction === 'next' ? distance : -distance,
        top: 0,
        behavior: 'smooth'
      });
    } else {
      scroller.scrollBy({
        top: direction === 'next' ? distance : -distance,
        left: 0,
        behavior: 'smooth'
      });
    }
  } catch (_) {}
  current.el.setAttribute('data-app-smart-current', '1');
  return {
    ok: true,
    intent: 'find_media',
    foundNext: false,
    fromX: current.x / w,
    fromY: current.y / h,
    toX: current.x / w,
    toY: current.y / h,
    scheduledMs: 520,
    axisHint,
    index: curIdx,
    total: rows.length
  };
})()
''';
  }

  /// 上/左/右 → 下一条媒体；下滑 → 上一条。
  /// [preferHorizontal] 为 true 时强制横滑；null 时自动判断。
  static String fingerSwipe({
    required double dxNorm,
    required double dyNorm,
    bool imagesOnly = false,
    bool videosOnly = false,
    bool? preferHorizontal,
  }) {
    final goNext = dyNorm < 0 || dxNorm != 0;
    String axisHint;
    if (preferHorizontal == true) {
      axisHint = 'left';
    } else if (preferHorizontal == false) {
      axisHint = goNext ? 'up' : 'down';
    } else if (dyNorm.abs() >= dxNorm.abs()) {
      axisHint = dyNorm < 0 ? 'up' : 'down';
    } else {
      axisHint = dxNorm < 0 ? 'left' : 'right';
    }
    return swipeToAdjacentMedia(
      direction: goNext ? 'next' : 'prev',
      axisHint: axisHint,
      imagesOnly: imagesOnly,
      videosOnly: videosOnly,
      autoAxis: preferHorizontal == null && goNext,
    );
  }

  /// 滚动零件也改为切相邻媒体。
  static String scrollToAdjacentMedia({
    required String direction,
    required bool imagesOnly,
    required bool videosOnly,
  }) {
    return swipeToAdjacentMedia(
      direction: direction == 'prev' ? 'prev' : 'next',
      axisHint: direction == 'prev' ? 'down' : 'up',
      imagesOnly: imagesOnly,
      videosOnly: videosOnly,
    );
  }

  /// 顶部下拉刷新：真人下拉手势（单次、竖直、不点控件）。
  static String pullRefresh() {
    return '''
(() => {
  $finderPreamble
  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;
  const cx = Math.floor(w * 0.5);
  const fromY = Math.max(24, Math.floor(h * 0.14));
  const toY = Math.min(h - 24, Math.floor(h * 0.42));
  const scroller = __smartFindScroller('y', -1);
  const target = __smartPickSwipeTarget(cx, fromY, scroller);
  const id = Date.now() % 100000;
  const steps = 14;
  const durationMs = 420;
  const ease = (t) => t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
  try { document.documentElement.setAttribute('data-app-smart-gesture', '1'); } catch (_) {}
  const startTouch = __smartMakeTouch(target, id, cx, fromY);
  __smartFireTouch(target, 'touchstart', startTouch, true, false);
  for (let i = 1; i <= steps; i++) {
    const delay = Math.floor(durationMs * (i / steps));
    const t = ease(i / steps);
    const y = Math.round(fromY + (toY - fromY) * t);
    setTimeout(() => {
      const touch = __smartMakeTouch(target, id, cx, y);
      if (i < steps) __smartFireTouch(target, 'touchmove', touch, true, false);
      else {
        __smartFireTouch(target, 'touchend', touch, false, false);
        try { document.documentElement.removeAttribute('data-app-smart-gesture'); } catch (_) {}
      }
    }, delay);
  }
  setTimeout(() => {
    try { scroller.scrollTo({top: 0, behavior: 'auto'}); } catch (_) {
      try { scroller.scrollTop = 0; } catch (__) {}
    }
  }, durationMs + 20);
  return {ok: true, scheduledMs: durationMs, fromX: 0.5, fromY: fromY / h, toX: 0.5, toY: toY / h};
})()
''';
  }

  static String tapAt({required double clientX, required double clientY}) {
    return '''
(() => {
  $finderPreamble
  const x = $clientX, y = $clientY;
  const el = document.elementFromPoint(x, y) || document.body;
  const target = (el.closest && (el.closest('a[href], button, [role="button"], video, img') || el)) || el;
  const id = Date.now() % 100000;
  const touch = __smartMakeTouch(target, id, x, y);
  __smartFireTouch(target, 'touchstart', touch, true);
  __smartFireTouch(target, 'touchend', touch, false);
  try { target.click(); } catch (_) {}
  return {ok: true, tag: target.tagName || ''};
})()
''';
  }

  static String doubleTapAt({required double clientX, required double clientY}) {
    return '''
(() => {
  $finderPreamble
  const x = $clientX, y = $clientY;
  const el = document.elementFromPoint(x, y) || document.body;
  const target = (el.closest && (el.closest('video, img, a[href], button') || el)) || el;
  const id = Date.now() % 100000;
  const fireOnce = () => {
    const touch = __smartMakeTouch(target, id, x, y);
    __smartFireTouch(target, 'touchstart', touch, true);
    __smartFireTouch(target, 'touchend', touch, false);
    try { target.click(); } catch (_) {}
  };
  fireOnce();
  fireOnce();
  try {
    target.dispatchEvent(new MouseEvent('dblclick', {
      bubbles: true, cancelable: true, clientX: x, clientY: y
    }));
  } catch (_) {}
  return {ok: true};
})()
''';
  }

  static String clickPlay() {
    return r'''
(() => {
  const videos = Array.from(document.querySelectorAll('video')).filter(v => {
    const r = v.getBoundingClientRect();
    return r.width > 80 && r.height > 60 && r.bottom > 0 && r.top < innerHeight;
  });
  const video = videos.sort((a, b) => {
    const ar = a.getBoundingClientRect(), br = b.getBoundingClientRect();
    return Math.abs(ar.top + ar.height / 2 - innerHeight / 2) -
      Math.abs(br.top + br.height / 2 - innerHeight / 2);
  })[0];
  if (video) {
    try { video.muted = true; video.play().catch(() => {}); } catch (_) {}
  }
  const pattern = /(播放|play|開始|开始|\u25B6)/i;
  const btn = Array.from(document.querySelectorAll(
    'button, [role="button"], a, div[class*="play"], span[class*="play"]'
  )).find(el => {
    const r = el.getBoundingClientRect();
    if (r.width < 16 || r.height < 16 || r.bottom <= 0 || r.top >= innerHeight) return false;
    const label = String(
      el.getAttribute('aria-label') || el.title || el.innerText || el.className || ''
    );
    return pattern.test(label);
  });
  if (btn) {
    try { btn.click(); } catch (_) {}
    return {ok: true, via: 'button'};
  }
  if (video) {
    try { video.click(); } catch (_) {}
    return {ok: true, via: 'video'};
  }
  return {ok: false};
})()
''';
  }

  static String clickCloseOverlay() {
    return r'''
(() => {
  const pattern = /(关闭|關閉|close|dismiss|got it|知道了|跳过|skip|×|✕|x)/i;
  const nodes = Array.from(document.querySelectorAll(
    'button, [role="button"], a, [aria-label], .close, [class*="close"], [class*="modal"] button'
  ));
  const candidates = nodes.map(el => {
    const r = el.getBoundingClientRect();
    const label = String(
      el.getAttribute('aria-label') || el.title || el.innerText || el.className || ''
    ).replace(/\s+/g, ' ').trim();
    return {el, r, label};
  }).filter(row => {
    if (row.r.width < 12 || row.r.height < 12) return false;
    if (row.r.bottom <= 0 || row.r.top >= innerHeight) return false;
    return pattern.test(row.label) || /close/i.test(row.el.className || '');
  }).sort((a, b) => (a.r.top + a.r.left) - (b.r.top + b.r.left));
  const hit = candidates[0];
  if (!hit) {
    try {
      document.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true
      }));
    } catch (_) {}
    return {ok: false};
  }
  try { hit.el.click(); } catch (_) {}
  return {ok: true, label: hit.label.slice(0, 40)};
})()
''';
  }

  static String clickTextButton({required String mode}) {
    final isNext = mode == 'next';
    return '''
(() => {
  const isNext = $isNext;
  const pattern = isNext
    ? /^(下一页|下一頁|下页|下頁|next|›|»|>>|＞)\$/i
    : /^(加载更多|載入更多|更多|查看更多|load more|more|show more)\$/i;
  const soft = isNext
    ? /(下一页|下一頁|下页|next page|next)/i
    : /(加载更多|載入更多|更多|load more|more)/i;
  const rows = Array.from(document.querySelectorAll(
    'a[href], button, [role="button"], input[type="button"], span, div'
  )).map(el => {
    const text = String(
      el.innerText || el.value || el.getAttribute('aria-label') || el.title || ''
    ).replace(/\\s+/g, ' ').trim();
    const r = el.getBoundingClientRect();
    return {el, text, r};
  }).filter(row => {
    if (!row.text || row.text.length > 40) return false;
    if (row.r.width < 18 || row.r.height < 14) return false;
    if (row.r.bottom <= 0 || row.r.top >= innerHeight + 40) return false;
    return pattern.test(row.text) || soft.test(row.text);
  }).sort((a, b) => {
    const aExact = pattern.test(a.text) ? 0 : 1;
    const bExact = pattern.test(b.text) ? 0 : 1;
    if (aExact !== bExact) return aExact - bExact;
    return (b.r.top) - (a.r.top);
  });
  const hit = rows[0];
  if (!hit) return {ok: false};
  try { hit.el.scrollIntoView({block: 'center', inline: 'nearest'}); } catch (_) {}
  try { hit.el.click(); } catch (_) {}
  return {ok: true, text: hit.text.slice(0, 40)};
})()
''';
  }

  static String focusCenterMedia({
    required bool imagesOnly,
    required bool videosOnly,
  }) {
    return '''
(() => {
  const imagesOnly = $imagesOnly;
  const videosOnly = $videosOnly;
  const selector = imagesOnly ? 'img' : (videosOnly ? 'video' : 'video, img');
  const rows = Array.from(document.querySelectorAll(selector)).filter(el => {
    const r = el.getBoundingClientRect();
    if (r.width < 90 || r.height < 70) return false;
    if (el.tagName === 'IMG') {
      const src = String(el.currentSrc || el.src || '').toLowerCase();
      return !/(avatar|emoji|icon|logo|profile_images|profile_banners)/.test(src);
    }
    return true;
  }).map(el => {
    const r = el.getBoundingClientRect();
    const y = r.top + r.height / 2;
    const x = r.left + r.width / 2;
    const visible = r.bottom > 0 && r.top < innerHeight;
    return {el, x, y, distance: Math.abs(y - innerHeight / 2) + Math.abs(x - innerWidth / 2) * 0.2, visible};
  }).sort((a, b) => {
    if (a.visible !== b.visible) return a.visible ? -1 : 1;
    return a.distance - b.distance;
  });
  const selected = rows[0];
  if (!selected) return {ok: false};
  try {
    document.querySelectorAll('[data-app-smart-current]').forEach(el => {
      el.removeAttribute('data-app-smart-current');
    });
    selected.el.scrollIntoView({behavior: 'smooth', block: 'center', inline: 'nearest'});
    selected.el.setAttribute('data-app-smart-current', '1');
  } catch (_) {}
  const r = selected.el.getBoundingClientRect();
  return {
    ok: true,
    x: innerWidth > 0 ? (r.left + r.width / 2) / innerWidth : 0.5,
    y: innerHeight > 0 ? (r.top + r.height / 2) / innerHeight : 0.5
  };
})()
''';
  }
}
