import json
import asyncio
import urllib.request
import websockets
import re
from pathlib import Path

# Pull helpers + collectAtDepth from dart source and evaluate on device
dart = Path(r'd:\1.Biancheng\my_app\lib\smart_download\smart_scope_batch.dart').read_text(encoding='utf-8')

# Extract helpers raw string between static const helpers = r''' ... ''';
m = re.search(r"static const helpers = r'''(.*?)''';", dart, re.S)
helpers = m.group(1)

# Build a minimal test using helpers
JS = helpers + r'''
(() => {
  const center = __sbPickCenter(false, false);
  const levels = [];
  let el = center;
  let depth = 0;
  const seen = new Set();
  while (el && el.nodeType === 1 && depth < 14) {
    if (seen.has(el)) break;
    seen.add(el);
    levels.push({depth, tag: (el.tagName||'')+String(el.className||'').slice(0,40)});
    if (el === document.body || el === document.documentElement) break;
    el = el.parentElement;
    depth++;
  }
  // simulate collect at recommended-ish depth: feeditem / swiper / layout
  function collect(depth) {
    let scope = center;
    for (let i=0;i<depth;i++){ if(!scope.parentElement) break; scope=scope.parentElement; }
    const groups = new Map();
    function feedRoot(node) {
      return __sbFeedRoot(node) || __sbCardOf(node);
    }
    function eachMedia(root, sel, fn) {
      __sbEachMedia(root, sel, fn);
    }
    eachMedia(scope, 'video,img', node => {
      const card = feedRoot(node);
      const g = groups.get(card) || {card, videos:[], images:[]};
      if (node.tagName==='VIDEO') g.videos.push(node); else g.images.push(node);
      groups.set(card, g);
    });
    const items = [];
    const seenUrl = new Set();
    groups.forEach(g => {
      if (g.videos.length) {
        g.videos.sort((a,b)=>{
          const ra=a.getBoundingClientRect(), rb=b.getBoundingClientRect();
          return (rb.width*rb.height)-(ra.width*ra.height);
        });
        const urls = __sbResolveVideoUrls(g.videos[0], __sbCollectSniffPool());
        const streams = urls.filter(u => __sbIsStreamUrl(u) && !__sbIsAdUrl(u) && (/\/full\.mp4(\?|#|$)/i.test(u) || !__sbIsPosterOrThumb(u)));
        const primary = streams[0] || urls.find(u => /\/full\.mp4(\?|#|$)/i.test(u)) || '';
        if (primary && !seenUrl.has(primary)) { seenUrl.add(primary); items.push({kind:'video', url: primary.slice(0,140), from:'video'}); }
        return;
      }
      if (g.images.length) {
        const poster = __sbImageUrl(g.images[0]);
        const up = __sbUpgradeToFullVideo(poster);
        if (up && !seenUrl.has(up)) { seenUrl.add(up); items.push({kind:'video', url: up.slice(0,140), from:'img'}); }
      }
    });
    return {depth, scope: (scope.tagName||'')+String(scope.className||'').slice(0,40), groups: groups.size, items: items.slice(0,15), videoCount: items.filter(i=>i.kind==='video').length};
  }
  return {
    center: center && {tag: center.tagName, id: center.id, src: (center.currentSrc||center.src||'').slice(0,120)},
    chain: levels,
    d0: collect(0),
    d3: collect(3),
    d6: collect(6),
    d8: collect(8),
    upgradeSample: __sbUpgradeToFullVideo('https://thumbs.xfree.com/listing/small_retina/f03da92b-010d-44fc-b82b-fb05dfb7b34d_0.webp')
  };
})()
'''


async def main():
    pages = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json/list'))
    # refresh forward
    ws_url = pages[0]['webSocketDebuggerUrl']
    async with websockets.connect(ws_url, max_size=20_000_000) as ws:
        await ws.send(json.dumps({
            'id': 1,
            'method': 'Runtime.evaluate',
            'params': {'expression': JS, 'returnByValue': True, 'awaitPromise': True},
        }))
        while True:
            msg = json.loads(await ws.recv())
            if msg.get('id') == 1:
                result = msg.get('result', {}).get('result', {})
                if result.get('subtype') == 'error':
                    print('ERR', json.dumps(result, ensure_ascii=False)[:2000])
                else:
                    print(json.dumps(result.get('value', result), ensure_ascii=False, indent=2)[:16000])
                break


if __name__ == '__main__':
    asyncio.run(main())
