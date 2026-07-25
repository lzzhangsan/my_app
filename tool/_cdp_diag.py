import json
import asyncio
import urllib.request
import websockets

JS = r"""
(() => {
  const h = window.innerHeight, w = window.innerWidth;
  const vids = Array.from(document.querySelectorAll('video')).map((v, i) => {
    const r = v.getBoundingClientRect();
    return {
      i,
      src: (v.currentSrc || v.src || '').slice(0, 180),
      rw: Math.round(r.width), rh: Math.round(r.height),
      top: Math.round(r.top), left: Math.round(r.left),
      visible: r.bottom > 0 && r.top < h && r.right > 0 && r.left < w,
      area: Math.round(r.width * r.height),
      useful: Math.max(r.width, v.videoWidth || 0) >= 100 &&
        Math.max(r.height, v.videoHeight || 0) >= 70,
      vw: v.videoWidth, vh: v.videoHeight,
      cls: String(v.className || '').slice(0, 60),
      id: v.id || '',
      parent: ((v.parentElement && (v.parentElement.className || v.parentElement.tagName)) || '')
        .toString().slice(0, 80)
    };
  }).sort((a, b) => b.area - a.area);

  const uniquePerf = [...new Set(
    performance.getEntriesByType('resource').map(e => e.name)
      .filter(u => /\.mp4|\.m3u8|cdn\.xfree/i.test(u))
  )];

  function cardOf(el) {
    return el.closest(
      'article, li, [role="article"], [role="listitem"], figure, [class*="card"],' +
      ' [class*="Card"], [class*="item"], [class*="Item"], [class*="tile"],' +
      ' [class*="media"], [class*="playlist"], [class*="video"]'
    ) || el.parentElement || el;
  }
  const cards = new Map();
  document.querySelectorAll('video,img').forEach(el => {
    const r = el.getBoundingClientRect();
    const tag = el.tagName;
    if (tag === 'IMG') {
      const width = Math.max(el.naturalWidth || 0, r.width || 0);
      const height = Math.max(el.naturalHeight || 0, r.height || 0);
      if (width < 160 || height < 120) return;
    } else {
      if (Math.max(r.width, el.videoWidth || 0) < 100 ||
          Math.max(r.height, el.videoHeight || 0) < 70) return;
    }
    const c = cardOf(el);
    const g = cards.get(c) || {
      tag: (c.tagName || '') + String(c.className || '').slice(0, 40),
      v: 0, i: 0, src: []
    };
    if (tag === 'VIDEO') {
      g.v += 1;
      g.src.push((el.currentSrc || el.src || '').slice(0, 120));
    } else {
      g.i += 1;
    }
    cards.set(c, g);
  });

  // Find full.mp4 / listing references in DOM attributes
  const attrHits = [];
  document.querySelectorAll('[src],[href],[data-src],[data-video-url]').forEach(n => {
    ['src', 'href', 'data-src', 'data-video-url', 'data-url'].forEach(k => {
      const v = n.getAttribute && n.getAttribute(k);
      if (v && /cdn\.xfree|\.mp4|m3u8/i.test(v)) {
        attrHits.push({tag: n.tagName, k, v: v.slice(0, 160)});
      }
    });
  });

  return {
    viewport: {w, h},
    videosSorted: vids,
    uniquePerfMp4: uniquePerf.slice(0, 40),
    cardCount: cards.size,
    cardSample: Array.from(cards.values()).slice(0, 20),
    videoLinkCount: document.querySelectorAll('a[href*="/video"]').length,
    playlistThumbs: document.querySelectorAll('.playlist__thumb').length,
    attrHits: attrHits.slice(0, 25),
    mainCandidate: vids[0] || null
  };
})()
"""


async def main():
    pages = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json/list'))
    ws_url = pages[0]['webSocketDebuggerUrl']
    async with websockets.connect(ws_url, max_size=20_000_000) as ws:
        await ws.send(json.dumps({
            'id': 1,
            'method': 'Runtime.evaluate',
            'params': {
                'expression': JS,
                'returnByValue': True,
                'awaitPromise': True,
            },
        }))
        while True:
            msg = json.loads(await ws.recv())
            if msg.get('id') == 1:
                result = msg.get('result', {}).get('result', {})
                print(json.dumps(result.get('value', result), ensure_ascii=False, indent=2)[:15000])
                break


if __name__ == '__main__':
    asyncio.run(main())
