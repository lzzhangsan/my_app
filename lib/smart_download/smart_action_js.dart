/// JS helpers for smart-download action parts.
/// Each snippet must produce real page effects (touch/scroll/click), not labels only.
class SmartActionJs {
  SmartActionJs._();

  /// Shared: find best vertical/horizontal scrollable under viewport center + touch helpers.
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
        radiusX: 12, radiusY: 12, force: 0.9
      });
    } catch (_) {}
  }
  return {
    identifier: id, target,
    clientX, clientY, pageX, pageY, screenX: clientX, screenY: clientY,
    radiusX: 12, radiusY: 12, force: 0.9
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
  try { target.dispatchEvent(ev); } catch (_) {}
  try {
    const map = {touchstart: 'pointerdown', touchmove: 'pointermove', touchend: 'pointerup'};
    const pType = map[type];
    if (pType && typeof PointerEvent !== 'undefined') {
      target.dispatchEvent(new PointerEvent(pType, {
        bubbles: true, cancelable: true, composed: true,
        clientX: touch.clientX, clientY: touch.clientY,
        pointerId: touch.identifier, pointerType: 'touch',
        isPrimary: true, pressure: type === 'touchend' ? 0 : 0.55,
        buttons: type === 'touchend' ? 0 : 1,
        width: 24, height: 24
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
  if (['A','BUTTON','INPUT','TEXTAREA','SELECT','LABEL','SUMMARY'].includes(tag)) {
    return true;
  }
  const role = (el.getAttribute && el.getAttribute('role')) || '';
  if (role === 'button' || role === 'link' || role === 'tab' || role === 'menuitem') return true;
  if (el.isContentEditable) return true;
  return false;
}
function __smartPickSwipeTarget(x, y, preferred) {
  if (preferred && preferred.nodeType === 1) {
    // preferred 若是可点控件，改找父层滚动容器，避免轻扫变成误点
    if (!__smartIsInteractive(preferred)) return preferred;
  }
  try {
    const stack = document.elementsFromPoint(x, y) || [];
    for (const el of stack) {
      if (!el || el === document.documentElement || el === document.body) continue;
      if (__smartIsInteractive(el)) continue;
      if (el.closest && el.closest('a[href], button, [role="button"], input, textarea, select')) {
        continue;
      }
      return el;
    }
  } catch (_) {}
  return preferred || document.scrollingElement || document.body;
}
function __smartEaseOutCubic(t) {
  return 1 - Math.pow(1 - t, 3);
}
function __smartEaseInOut(t) {
  return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
}
''';

  /// 真人短促轻扫：派发 touch/pointer 序列，若页面未滚动再 scrollBy 兜底。
  /// axisHint: up|down|left|right —— 手指移动方向（up = 手指向上，内容上移看更多）。
  static String fingerFlick({
    required String axisHint,
    double distanceFraction = 0.28,
    int durationMs = 220,
  }) {
    final axis = axisHint;
    final f = distanceFraction.clamp(0.12, 0.92);
    final dur = durationMs.clamp(120, 700);
    return '''
(() => {
  $finderPreamble
  const axisHint = '$axis';
  const fraction = $f;
  const durationMs = $dur;
  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;
  const vertical = axisHint === 'up' || axisHint === 'down';
  const distance = Math.max(
    72,
    Math.floor((vertical ? h : w) * fraction)
  );
  // 手指轨迹：up = 手指从下往上滑；大幅度时从近底起手，保证近一屏行程
  let fromX = Math.floor(w * 0.5);
  let fromY = Math.floor(h * 0.58);
  let toX = fromX;
  let toY = fromY;
  if (axisHint === 'up') {
    if (fraction >= 0.5) {
      fromY = Math.min(Math.floor(h * 0.92), Math.floor(h * (0.10 + fraction)));
      toY = Math.max(16, fromY - distance);
    } else {
      fromY = Math.floor(h * 0.62);
      toY = Math.max(16, fromY - distance);
    }
  } else if (axisHint === 'down') {
    if (fraction >= 0.5) {
      fromY = Math.max(Math.floor(h * 0.08), Math.floor(h * (0.90 - fraction)));
      toY = Math.min(h - 16, fromY + distance);
    } else {
      fromY = Math.floor(h * 0.38);
      toY = Math.min(h - 16, fromY + distance);
    }
  } else if (axisHint === 'left') {
    // 大幅度：从近右缘起手，保证接近一整屏行程（相册/图片查看器）
    if (fraction >= 0.5) {
      fromX = Math.min(Math.floor(w * 0.94), Math.floor(w * (0.10 + fraction)));
      toX = Math.max(16, fromX - distance);
    } else {
      fromX = Math.floor(w * 0.72);
      toX = Math.max(16, fromX - distance);
    }
    fromY = Math.floor(h * 0.5);
    toY = fromY;
  } else {
    if (fraction >= 0.5) {
      fromX = Math.max(Math.floor(w * 0.06), Math.floor(w * (0.90 - fraction)));
      toX = Math.min(w - 16, fromX + distance);
    } else {
      fromX = Math.floor(w * 0.28);
      toX = Math.min(w - 16, fromX + distance);
    }
    fromY = Math.floor(h * 0.5);
    toY = fromY;
  }

  const preferRemain = (axisHint === 'up' || axisHint === 'left') ? 1 : -1;
  const scroller = __smartFindScroller(vertical ? 'y' : 'x', preferRemain);
  const target = __smartPickSwipeTarget(fromX, fromY, scroller);
  const beforeY = Number(scroller.scrollTop || 0);
  const beforeX = Number(scroller.scrollLeft || 0);
  const winBeforeY = Number(window.scrollY || window.pageYOffset || 0);
  const winBeforeX = Number(window.scrollX || window.pageXOffset || 0);
  // 内容滚动方向与手指相反
  let scrollDx = 0, scrollDy = 0;
  if (axisHint === 'up') scrollDy = distance;
  else if (axisHint === 'down') scrollDy = -distance;
  else if (axisHint === 'left') scrollDx = distance;
  else scrollDx = -distance;

  const id = Date.now() % 100000;
  const steps = Math.max(6, Math.min(16, Math.round(durationMs / 18)));
  try { document.documentElement.setAttribute('data-app-smart-gesture', '1'); } catch (_) {}
  const startTouch = __smartMakeTouch(target, id, fromX, fromY);
  __smartFireTouch(target, 'touchstart', startTouch, true, false);

  for (let i = 1; i <= steps; i++) {
    const delay = Math.floor(durationMs * (i / steps));
    const t = __smartEaseOutCubic(i / steps);
    const x = Math.round(fromX + (toX - fromX) * t);
    const y = Math.round(fromY + (toY - fromY) * t);
    setTimeout(() => {
      const touch = __smartMakeTouch(target, id, x, y);
      if (i < steps) {
        __smartFireTouch(target, 'touchmove', touch, true, false);
      } else {
        __smartFireTouch(target, 'touchend', touch, false, false);
        try { document.documentElement.removeAttribute('data-app-smart-gesture'); } catch (_) {}
        // 若站点未响应 touch（常见于普通文档流），用短距离 scroll 兜底
        setTimeout(() => {
          try {
            const afterY = Number(scroller.scrollTop || 0);
            const afterX = Number(scroller.scrollLeft || 0);
            const moved = Math.abs(afterY - beforeY) + Math.abs(afterX - beforeX);
            const winMoved = Math.abs((window.scrollY || 0) - winBeforeY) +
              Math.abs((window.scrollX || 0) - winBeforeX);
            if (moved < 4 && winMoved < 4) {
              try {
                scroller.scrollBy({ top: scrollDy, left: scrollDx, behavior: 'auto' });
              } catch (_) {
                try {
                  scroller.scrollTop = beforeY + scrollDy;
                  scroller.scrollLeft = beforeX + scrollDx;
                } catch (__) {}
              }
              const isRoot = scroller === document.scrollingElement ||
                scroller === document.documentElement || scroller === document.body;
              if (isRoot) {
                try { window.scrollBy(scrollDx, scrollDy); } catch (_) {}
              }
              try {
                scroller.dispatchEvent(new WheelEvent('wheel', {
                  deltaY: scrollDy, deltaX: scrollDx,
                  bubbles: true, cancelable: true, deltaMode: 0
                }));
              } catch (_) {}
            }
          } catch (_) {}
        }, 24);
      }
    }, delay);
  }

  return {
    ok: true,
    intent: 'finger_flick',
    axisHint,
    distance,
    durationMs,
    fromX: fromX / w,
    fromY: fromY / h,
    toX: toX / w,
    toY: toY / h,
    scheduledMs: durationMs + 80,
    tag: (target.tagName || '') + (target.id ? '#' + target.id : '')
  };
})()
''';
  }

  /// 按屏幕尺寸推进一屏（较长滚动，与轻扫分开）。
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

  /// 定位相邻媒体；找不到时用真人轻扫推进（而不是整屏假滚）。
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

  // 没有下一条：不在此派发合成 touch（Android WebView 会忽略 isTrusted=false）。
  // 交由 Dart 侧注入原生 MotionEvent 轻扫。
  let fromX = Math.floor(w * 0.5);
  let fromY = Math.floor(h * 0.58);
  let toX = fromX;
  let toY = fromY;
  const flickDistance = Math.max(96, Math.floor((axisHint === 'left' || axisHint === 'right' ? w : h) * 0.34));
  if (axisHint === 'left') {
    fromX = Math.floor(w * 0.72); toX = fromX - flickDistance; fromY = Math.floor(h * 0.5); toY = fromY;
  } else if (axisHint === 'right') {
    fromX = Math.floor(w * 0.28); toX = fromX + flickDistance; fromY = Math.floor(h * 0.5); toY = fromY;
  } else if (axisHint === 'down' || direction === 'prev') {
    fromY = Math.floor(h * 0.38); toY = fromY + flickDistance;
  } else {
    fromY = Math.floor(h * 0.62); toY = fromY - flickDistance;
  }
  try { current.el.setAttribute('data-app-smart-current', '1'); } catch (_) {}
  return {
    ok: true,
    intent: 'find_media',
    foundNext: false,
    needsNativeFlick: true,
    fromX: fromX / w,
    fromY: fromY / h,
    toX: toX / w,
    toY: toY / h,
    scheduledMs: 40,
    axisHint,
    index: curIdx,
    total: rows.length
  };
})()
''';
  }

  /// 当前「主媒体」指纹：用于判断是否已真正切到下一条（不仅是滑了距离）。
  static String mediaIdentity({
    required bool imagesOnly,
    required bool videosOnly,
  }) {
    return '''
(() => {
  const imagesOnly = $imagesOnly;
  const videosOnly = $videosOnly;
  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;
  const cx = w / 2, cy = h / 2;
  const selector = imagesOnly ? 'img' : (videosOnly ? 'video' : 'video, img');
  const se = document.scrollingElement || document.documentElement || document.body;
  const marked = document.querySelector('[data-app-smart-current="1"]');
  function srcOf(el) {
    if (!el) return '';
    return String(el.currentSrc || el.src || el.getAttribute('src') ||
      el.getAttribute('data-src') || el.getAttribute('poster') || '').trim();
  }
  function pick() {
    if (marked && (!imagesOnly || marked.tagName === 'IMG') &&
        (!videosOnly || marked.tagName === 'VIDEO')) {
      const r = marked.getBoundingClientRect();
      if (r.width >= 80 && r.height >= 60) return marked;
    }
    let best = null, bestScore = -1e18;
    for (const el of document.querySelectorAll(selector)) {
      const r = el.getBoundingClientRect();
      const iw = Math.max(0, Math.min(w, r.right) - Math.max(0, r.left));
      const ih = Math.max(0, Math.min(h, r.bottom) - Math.max(0, r.top));
      if (iw < 100 || ih < 80) continue;
      const mx = r.left + r.width / 2, my = r.top + r.height / 2;
      const cover = (r.left <= cx && r.right >= cx && r.top <= cy && r.bottom >= cy) ? 1 : 0;
      const score = cover * 50000 + (iw * ih) / (w * h) * 20000 -
        Math.hypot(mx - cx, my - cy) * 2 + (el.tagName === 'VIDEO' ? 2000 : 0);
      if (score > bestScore) { bestScore = score; best = el; }
    }
    return best;
  }
  const el = pick();
  const r = el ? el.getBoundingClientRect() : {left:0,top:0,width:0,height:0};
  const src = srcOf(el);
  const key = [
    el ? el.tagName : 'none',
    src.slice(0, 220),
    Math.round(r.left), Math.round(r.top),
    Math.round(r.width), Math.round(r.height),
    Math.round(Number(se && se.scrollTop) || 0),
    Math.round(Number(se && se.scrollLeft) || 0),
    String(location.pathname || ''),
    String(location.search || '').slice(0, 80)
  ].join('|');
  return {
    ok: true,
    found: !!el,
    key,
    src: src.slice(0, 180),
    tag: el ? el.tagName : '',
    x: w > 0 ? ((r.left + r.width / 2) / w) : 0.5,
    y: h > 0 ? ((r.top + r.height / 2) / h) : 0.5,
    scrollTop: Math.round(Number(se && se.scrollTop) || 0),
    scrollLeft: Math.round(Number(se && se.scrollLeft) || 0),
    pageUrl: String(location.href || '')
  };
})()
''';
  }

  /// 定位相邻媒体。directionOverride: next|prev|null（null 时由 dy/dx 推断）。
  static String fingerSwipe({
    required double dxNorm,
    required double dyNorm,
    bool imagesOnly = false,
    bool videosOnly = false,
    bool? preferHorizontal,
    String? directionOverride,
    String? axisHint,
  }) {
    final goNext =
        directionOverride == 'next'
            ? true
            : directionOverride == 'prev'
            ? false
            : (dyNorm < 0 || (dxNorm < 0 && dyNorm == 0));
    late final String resolvedAxis;
    final override = (axisHint ?? '').trim();
    if (override == 'up' ||
        override == 'down' ||
        override == 'left' ||
        override == 'right') {
      resolvedAxis = override;
    } else if (preferHorizontal == true) {
      // 手指左滑常用于看右侧下一条；右滑看左侧
      resolvedAxis = goNext ? 'left' : 'right';
    } else if (preferHorizontal == false) {
      resolvedAxis = goNext ? 'up' : 'down';
    } else if (dyNorm.abs() >= dxNorm.abs()) {
      resolvedAxis = dyNorm < 0 ? 'up' : 'down';
    } else {
      resolvedAxis = dxNorm < 0 ? 'left' : 'right';
    }
    return swipeToAdjacentMedia(
      direction: goNext ? 'next' : 'prev',
      axisHint: resolvedAxis,
      imagesOnly: imagesOnly,
      videosOnly: videosOnly,
      autoAxis:
          override.isEmpty &&
          preferHorizontal == null &&
          goNext &&
          directionOverride == null,
    );
  }

  /// 顶部下拉刷新：真人下拉手势。
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
  try { document.documentElement.setAttribute('data-app-smart-gesture', '1'); } catch (_) {}
  const startTouch = __smartMakeTouch(target, id, cx, fromY);
  __smartFireTouch(target, 'touchstart', startTouch, true, false);
  for (let i = 1; i <= steps; i++) {
    const delay = Math.floor(durationMs * (i / steps));
    const t = __smartEaseInOut(i / steps);
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

  /// 真实单击：touchstart → 短停 → touchend → click。
  static String tapAt({required double clientX, required double clientY}) {
    return '''
(() => {
  $finderPreamble
  const x = $clientX, y = $clientY;
  const el = document.elementFromPoint(x, y) || document.body;
  const target = (el.closest && (el.closest('a[href], button, [role="button"], video, img, [onclick]') || el)) || el;
  const id = Date.now() % 100000;
  const holdMs = 48;
  try { target.setAttribute('data-app-smart-gesture', '1'); } catch (_) {}
  const touch = __smartMakeTouch(target, id, x, y);
  __smartFireTouch(target, 'touchstart', touch, true, true);
  setTimeout(() => {
    const end = __smartMakeTouch(target, id, x, y);
    __smartFireTouch(target, 'touchend', end, false, true);
    try { target.click(); } catch (_) {}
    try { target.removeAttribute('data-app-smart-gesture'); } catch (_) {}
  }, holdMs);
  return {ok: true, tag: target.tagName || '', scheduledMs: holdMs + 40};
})()
''';
  }

  /// 真实双击：两次短按，间隔约 90ms。
  static String doubleTapAt({
    required double clientX,
    required double clientY,
  }) {
    return '''
(() => {
  $finderPreamble
  const x = $clientX, y = $clientY;
  const el = document.elementFromPoint(x, y) || document.body;
  const target = (el.closest && (el.closest('video, img, a[href], button') || el)) || el;
  const id = Date.now() % 100000;
  const tapOnce = (delay, withClick) => {
    setTimeout(() => {
      const t0 = __smartMakeTouch(target, id, x, y);
      __smartFireTouch(target, 'touchstart', t0, true, true);
      setTimeout(() => {
        const t1 = __smartMakeTouch(target, id, x, y);
        __smartFireTouch(target, 'touchend', t1, false, true);
        if (withClick) {
          try { target.click(); } catch (_) {}
        }
      }, 40);
    }, delay);
  };
  try { target.setAttribute('data-app-smart-gesture', '1'); } catch (_) {}
  tapOnce(0, false);
  tapOnce(100, true);
  setTimeout(() => {
    try {
      target.dispatchEvent(new MouseEvent('dblclick', {
        bubbles: true, cancelable: true, clientX: x, clientY: y
      }));
    } catch (_) {}
    try { target.removeAttribute('data-app-smart-gesture'); } catch (_) {}
  }, 180);
  return {ok: true, scheduledMs: 240};
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

  static String clickCloseOverlay() => clearSmartBlockers(forceHide: false);

  /// 探测干扰弹层是否仍在（用于清障后复核）。
  static String probeSmartBlockers() {
    return r'''
(() => {
  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;
  const promoRe = /(温馨提示|溫馨提示|建议前往|建議前往|百度|更高清|打开app|打開APP|下载app|安裝app|领券|廣告|广告)/i;
  const hits = [];
  const nodes = document.querySelectorAll('body *');
  for (let i = 0; i < nodes.length && hits.length < 6; i++) {
    const el = nodes[i];
    const r = el.getBoundingClientRect();
    if (r.width < 80 || r.height < 40) continue;
    if (r.bottom <= 0 || r.top >= h || r.right <= 0 || r.left >= w) continue;
    const st = getComputedStyle(el);
    if (st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) === 0) continue;
    const t = String(el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
    if (!t || t.length > 60) continue;
    if (promoRe.test(t) && (/(取消|确定|確定|关闭|關閉)/.test(t) || r.width * r.height > w * h * 0.08)) {
      hits.push(t.slice(0, 40));
    }
  }
  return { ok: true, present: hits.length > 0, samples: hits };
})()
''';
  }

  /// 智能下载中清障：定位「取消」坐标供原生 MotionEvent 点击；
  /// JS click 常被忽略（isTrusted=false）。仅当 forceHide=true 时强制隐藏弹层。
  static String clearSmartBlockers({bool forceHide = false}) {
    // 前缀插值 + 后续 raw，避免正则里的 `$` 被 Dart 当成插值
    return '''
(() => {
  const forceHide = $forceHide;
'''
        r'''
  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;
  const actions = [];
  const tapTargets = [];

  const dismissRe = /^(取消|关闭|關閉|关掉|跳过|skip|知道了|我知道了|暂不|拒絕|拒绝|忽略|算了|以后再说|以後再說|继续浏览|繼續瀏覽|×|✕|✖|x)$/i;
  const dismissSoftRe = /(取消|关闭|關閉|关闭广告|關閉廣告|跳过广告|跳过|dismiss|cancel|close|got it|知道了|暂不|拒絕|拒绝|不了|继续浏览|忽略|算了)/i;
  const dangerGoRe = /(百度|高清|更高清|前往|立即前往|打开app|打開app|下载app|下載app|安装|安裝|领取|領取|开通|開通|vip|充值|免费领|免費領)/i;
  const promoDialogRe = /(温馨提示|溫馨提示|温馨|建议前往|建議前往|广告|廣告|推荐|推薦|高清|百度|打开app|领券|領券)/i;
  const confirmOkRe = /^(确定|確定|ok|yes|确认|確認|同意|允许|允許)$/i;

  function labelOf(el) {
    return String(
      el.getAttribute('aria-label') || el.title || el.value ||
      el.innerText || el.textContent || ''
    ).replace(/\s+/g, ' ').trim();
  }

  function ownText(el) {
    let s = '';
    try {
      for (const n of el.childNodes) {
        if (n.nodeType === 3) s += (n.textContent || '');
      }
    } catch (_) {}
    s = s.replace(/\s+/g, ' ').trim();
    if (s) return s;
    // 叶子或近似叶子
    const t = String(el.innerText || '').replace(/\s+/g, ' ').trim();
    return t.length <= 12 ? t : '';
  }

  function visible(el) {
    const r = el.getBoundingClientRect();
    if (r.width < 8 || r.height < 8) return false;
    if (r.bottom <= 0 || r.top >= h || r.right <= 0 || r.left >= w) return false;
    const st = getComputedStyle(el);
    if (st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) === 0) return false;
    return true;
  }

  function pushTap(el, why) {
    const r = el.getBoundingClientRect();
    const x = (r.left + r.width / 2) / w;
    const y = (r.top + r.height / 2) / h;
    tapTargets.push({
      x: Math.max(0.03, Math.min(0.97, x)),
      y: Math.max(0.03, Math.min(0.97, y)),
      label: (ownText(el) || labelOf(el)).slice(0, 20),
      why
    });
    actions.push(why + ':' + (ownText(el) || labelOf(el)).slice(0, 20));
  }

  function tryJsClick(el) {
    try { el.click(); return true; } catch (_) {}
    try {
      el.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
      return true;
    } catch (_) { return false; }
  }

  // A) 精确找短文案「取消」—— 不依赖 modal class
  const candidates = [];
  const scan = document.querySelectorAll(
    'button, [role="button"], a, input[type="button"], input[type="submit"],' +
    'span, div, li, p, font, label, td'
  );
  for (const el of scan) {
    if (!visible(el)) continue;
    const own = ownText(el);
    const full = labelOf(el);
    const t = own || (full.length <= 10 ? full : '');
    if (!t || t.length > 10) continue;
    if (dangerGoRe.test(t)) continue;
    let score = -1;
    if (dismissRe.test(t)) score = 120;
    else if (dismissSoftRe.test(t) && t.length <= 8) score = 90;
    else if (/^(×|✕|✖|x|X)$/.test(t)) score = 110;
    if (score < 0) continue;
    // 父级若是促销弹窗，加分
    let p = el.parentElement, promoBoost = 0, depth = 0;
    while (p && depth < 6) {
      const pt = labelOf(p).slice(0, 100);
      if (promoDialogRe.test(pt)) { promoBoost = 40; break; }
      p = p.parentElement; depth++;
    }
    const r = el.getBoundingClientRect();
    candidates.push({ el, score: score + promoBoost, t, r });
  }
  candidates.sort((a, b) => b.score - a.score || (a.r.top - b.r.top));

  let jsClicked = false;
  if (candidates[0]) {
    pushTap(candidates[0].el, 'cancel_btn');
    jsClicked = tryJsClick(candidates[0].el);
    // 再备选一个次优坐标
    if (candidates[1]) pushTap(candidates[1].el, 'cancel_alt');
  }

  // B) 找到「温馨提示」类容器，估算左侧「取消」热区（双按钮常见布局）
  if (tapTargets.length === 0) {
    for (const el of document.querySelectorAll('body *')) {
      if (!visible(el)) continue;
      const r = el.getBoundingClientRect();
      if (r.width < w * 0.45 || r.height < 90 || r.height > h * 0.85) continue;
      const t = labelOf(el).slice(0, 120);
      if (!promoDialogRe.test(t)) continue;
      if (!/(取消|确定|確定|关闭|關閉)/.test(t)) continue;
      // 左下「取消」、右下「确定」
      tapTargets.push({
        x: (r.left + r.width * 0.28) / w,
        y: (r.top + r.height * 0.78) / h,
        label: 'promo_left_cancel_zone',
        why: 'promo_zone'
      });
      tapTargets.push({
        x: (r.left + r.width * 0.22) / w,
        y: (r.top + r.height * 0.72) / h,
        label: 'promo_left_cancel_zone2',
        why: 'promo_zone'
      });
      actions.push('promo_zone');
      break;
    }
  }

  // C) 仅在明确要求时强制隐藏促销层（避免干净页误伤）
  let forceHidden = 0;
  if (forceHide) {
    for (const el of Array.from(document.querySelectorAll('body *'))) {
      if (!visible(el)) continue;
      const r = el.getBoundingClientRect();
      const area = r.width * r.height;
      if (area < w * h * 0.08 && !(r.width >= w * 0.5 && r.height >= 100)) continue;
      const t = labelOf(el).slice(0, 160);
      if (!promoDialogRe.test(t)) continue;
      if (el === document.body || el === document.documentElement) continue;
      try {
        el.style.setProperty('display', 'none', 'important');
        el.style.setProperty('visibility', 'hidden', 'important');
        el.style.setProperty('pointer-events', 'none', 'important');
        el.setAttribute('data-app-smart-force-hidden', '1');
        forceHidden++;
        actions.push('force_hide');
        if (forceHidden >= 3) break;
      } catch (_) {}
    }
    document.querySelectorAll(
      '[class*="mask"], [class*="overlay"], [class*="modal"], [class*="dialog"], [class*="popup"]'
    ).forEach(el => {
      if (forceHidden >= 6) return;
      if (!visible(el)) return;
      const t = labelOf(el).slice(0, 120);
      if (!promoDialogRe.test(t) && !/(取消|确定|確定)/.test(t)) return;
      try {
        el.style.setProperty('display', 'none', 'important');
        el.setAttribute('data-app-smart-force-hidden', '1');
        forceHidden++;
        actions.push('force_hide_mask');
      } catch (_) {}
    });
  }

  // 复核
  let still = false;
  try {
    const probeNodes = document.querySelectorAll('body *');
    for (let i = 0; i < probeNodes.length; i++) {
      const el = probeNodes[i];
      if (el.getAttribute && el.getAttribute('data-app-smart-force-hidden') === '1') continue;
      if (!visible(el)) continue;
      const t = labelOf(el).slice(0, 80);
      if (promoDialogRe.test(t) && /(取消|确定|確定)/.test(t)) { still = true; break; }
    }
  } catch (_) {}

  return {
    ok: tapTargets.length > 0 || forceHidden > 0 || jsClicked,
    clicked: jsClicked,
    forceHidden,
    stillPresent: still,
    tapTargets: tapTargets.slice(0, 4),
    actions: actions.slice(0, 10)
  };
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

  /// 选中「当前应操作」的媒体：优先盖住屏幕中心的大图/视频，返回其中心点。
  /// [excludeSrcsJson]：已下载/已跳过的 src 列表，避免清障后又选回旧媒体。
  static String findCenterMedia({
    required bool imagesOnly,
    required bool videosOnly,
    String excludeSrcsJson = '[]',
  }) {
    return '''
(() => {
  const imagesOnly = $imagesOnly;
  const videosOnly = $videosOnly;
  const excludeSrcs = $excludeSrcsJson;
  const w = window.innerWidth || 360;
  const h = window.innerHeight || 640;
  const cx = w / 2;
  const cy = h / 2;
  const vw = Math.max(1, w);
  const vh = Math.max(1, h);
  let isFacebook = false;
  let isFacebookReels = false;
  try {
    const host = String(location.hostname || '').toLowerCase();
    isFacebook = host === 'facebook.com' || host.endsWith('.facebook.com') ||
      host === 'fb.com' || host.endsWith('.fb.com') ||
      host === 'fb.watch' || host.endsWith('.fb.watch') ||
      host === 'messenger.com' || host.endsWith('.messenger.com');
    const path = String(location.pathname || '').toLowerCase();
    const href = String(location.href || '').toLowerCase();
    isFacebookReels = isFacebook && (
      path.includes('/reel/') || path.includes('/reels') ||
      href.includes('/reel/') || href.includes('/reels')
    );
  } catch (_) {}
  const selector = imagesOnly ? 'img' : (videosOnly ? 'video' : 'video, img');
  function isExcludedSrc(src) {
    if (!src) return false;
    const s = String(src).toLowerCase();
    for (const ex of excludeSrcs) {
      const e = String(ex || '').toLowerCase();
      if (!e) continue;
      if (s === e || (e.length >= 12 && s.indexOf(e) >= 0) || (s.length >= 12 && e.indexOf(s) >= 0)) {
        return true;
      }
    }
    return false;
  }

  function isJunkImg(el) {
    if (!el || el.tagName !== 'IMG') return false;
    const src = String(el.currentSrc || el.src || el.getAttribute('src') || '').toLowerCase();
    return /(avatar|emoji|icon|logo|sprite|badge|profile_images|profile_banners|favicon|safe_image)/.test(src);
  }

  function looksFbMediaSrc(src) {
    const s = String(src || '').toLowerCase();
    return s.includes('fbcdn') || s.includes('scontent.') ||
      /\\.(jpe?g|png|gif|webp|mp4|webm)(\\?|#|\$)/.test(s);
  }

  function visibleRect(el) {
    const r = el.getBoundingClientRect();
    const left = Math.max(0, r.left);
    const top = Math.max(0, r.top);
    const right = Math.min(w, r.right);
    const bottom = Math.min(h, r.bottom);
    const iw = Math.max(0, right - left);
    const ih = Math.max(0, bottom - top);
    return { r, iw, ih, area: iw * ih };
  }

  function coversCenter(r) {
    return r.left <= cx && r.right >= cx && r.top <= cy && r.bottom >= cy;
  }

  const samplePts = [
    [cx, cy],
    [cx, h * 0.42],
    [cx, h * 0.58],
    [w * 0.4, cy],
    [w * 0.6, cy],
  ];
  const hitSet = new Set();
  for (const [px, py] of samplePts) {
    try {
      const el = document.elementFromPoint(px, py);
      const media = el && el.closest ? el.closest(selector) : null;
      if (media) hitSet.add(media);
      // Facebook overlays often sit above img/video; walk the stack.
      if (isFacebook) {
        const stack = document.elementsFromPoint(px, py) || [];
        for (const node of stack) {
          if (!node) continue;
          const tag = String(node.tagName || '').toLowerCase();
          if ((tag === 'video' && !imagesOnly) || ((tag === 'img' || tag === 'image') && !videosOnly)) {
            hitSet.add(node);
            break;
          }
          if (!videosOnly) {
            const role = node.closest && node.closest('[role="img"]');
            const nestedImg = (role && role.querySelector && role.querySelector('img')) ||
              (node.querySelector && node.querySelector('img'));
            if (nestedImg) hitSet.add(nestedImg);
          }
          if (!imagesOnly) {
            const nestedVideo = node.querySelector && node.querySelector('video');
            if (nestedVideo) hitSet.add(nestedVideo);
          }
        }
      }
    } catch (_) {}
  }

  const marked = document.querySelector('[data-app-smart-current="1"]');
  const all = Array.from(document.querySelectorAll(selector));
  const candidates = new Set(all);
  hitSet.forEach(el => candidates.add(el));
  if (marked) candidates.add(marked);
  if (isFacebook && !videosOnly) {
    try {
      document.querySelectorAll('[role="img"] img, img[srcset]').forEach(el => candidates.add(el));
    } catch (_) {}
  }

  let best = null;
  let bestScore = -1e18;
  const videoAlternatives = [];
  const minIw = isFacebook ? 72 : 120;
  const minIh = isFacebook ? 72 : 100;
  const minAreaRatio = isFacebook ? 0.02 : 0.04;
  for (const el of candidates) {
    if (!el || !el.getBoundingClientRect) continue;
    if (imagesOnly && el.tagName !== 'IMG') continue;
    if (videosOnly && el.tagName !== 'VIDEO') continue;
    if (isJunkImg(el)) continue;
    const src = String(el.currentSrc || el.src || el.getAttribute('src') ||
      el.getAttribute('data-src') || el.getAttribute('poster') ||
      el.getAttribute('srcset') || '');
    const excluded = isExcludedSrc(src);
    // 已处理过的媒体：不当作首选（彻底排除），防止清障后回到旧条
    if (excluded) continue;
    const { r, iw, ih, area } = visibleRect(el);
    if (iw < minIw || ih < minIh) continue;
    if (area < vw * vh * minAreaRatio) continue; // 太小的角标/缩略图丢掉
    const mx = r.left + r.width / 2;
    const my = r.top + r.height / 2;
    // 中心点必须落在屏幕内，否则会漂到边缘/右下角
    if (mx < 8 || mx > w - 8 || my < 8 || my > h - 8) continue;
    const dist = Math.hypot(mx - cx, my - cy);
    const cover = coversCenter(r) ? 1 : 0;
    const areaRatio = area / (vw * vh);
    const isVideo = el.tagName === 'VIDEO' ? 1 : 0;
    const isMarked = (marked && el === marked) ? 1 : 0;
    const fromHitTest = hitSet.has(el) ? 1 : 0;
    const fbBonus = (isFacebook && looksFbMediaSrc(src)) ? 1 : 0;
    let playingBonus = 0;
    if (isVideo && el.tagName === 'VIDEO') {
      try {
        if (!el.paused && !el.ended) playingBonus += isFacebookReels ? 80000 : 20000;
        if (Number(el.currentTime || 0) > 0.2) playingBonus += isFacebookReels ? 20000 : 5000;
        // Full-screen vertical reel player under center beats below-fold prefetch.
        if (isFacebookReels && areaRatio >= 0.35) playingBonus += 40000;
      } catch (_) {}
    }
    // 盖住中心 > 正在播放(Reels) > 面积 > 命中探测 > 视频 > FB CDN > 标记 > 靠近中心
    const score =
      cover * 50000 +
      playingBonus +
      areaRatio * 20000 +
      fromHitTest * 8000 +
      isVideo * 3000 +
      fbBonus * 2500 +
      isMarked * 1500 -
      dist * 2;
    const candidate = { el, mx, my, cover, areaRatio, isVideo, src, r, score };
    if (isVideo) videoAlternatives.push(candidate);
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }

  // A poster IMG is commonly layered directly above its real VIDEO. In mixed
  // mode the underlying video owns that visual card: downloading the poster
  // must never be counted as downloading the media. Keep genuine image-only
  // cards unchanged.
  if (!imagesOnly && !videosOnly && best && !best.isVideo) {
    let owningVideo = null;
    let owningScore = -1e18;
    for (const video of videoAlternatives) {
      const overlapW = Math.max(
        0,
        Math.min(best.r.right, video.r.right) -
          Math.max(best.r.left, video.r.left)
      );
      const overlapH = Math.max(
        0,
        Math.min(best.r.bottom, video.r.bottom) -
          Math.max(best.r.top, video.r.top)
      );
      const overlapArea = overlapW * overlapH;
      const smallerArea = Math.max(
        1,
        Math.min(
          Math.max(1, best.r.width * best.r.height),
          Math.max(1, video.r.width * video.r.height)
        )
      );
      const overlapRatio = overlapArea / smallerArea;
      let sameCard = false;
      try {
        const cardSelector =
          'article, figure, [role="dialog"], [class*="card"], ' +
          '[class*="item"], [class*="media"], [class*="slide"]';
        const imageCard = best.el.closest(cardSelector);
        sameCard = !!imageCard && imageCard === video.el.closest(cardSelector);
      } catch (_) {}
      const centerGap = Math.hypot(video.mx - best.mx, video.my - best.my);
      const ownsPoster =
        overlapRatio >= 0.35 ||
        (sameCard && centerGap <= Math.max(120, Math.min(w, h) * 0.28));
      if (ownsPoster && video.score > owningScore) {
        owningVideo = video;
        owningScore = video.score;
      }
    }
    if (owningVideo) best = owningVideo;
  }

  document.querySelectorAll('[data-app-smart-current]').forEach(el => {
    try { el.removeAttribute('data-app-smart-current'); } catch (_) {}
  });

  if (!best) {
    return {
      ok: true,
      found: false,
      reason: 'fallback_screen_center',
      type: 'none',
      x: 0.5,
      y: 0.5,
      clientX: cx,
      clientY: cy
    };
  }

  try { best.el.setAttribute('data-app-smart-current', '1'); } catch (_) {}
  return {
    ok: true,
    found: true,
    type: best.isVideo ? 'video' : 'image',
    coversCenter: !!best.cover,
    areaRatio: Math.round(best.areaRatio * 1000) / 1000,
    x: best.mx / w,
    y: best.my / h,
    clientX: best.mx,
    clientY: best.my
  };
})()
''';
  }
}
