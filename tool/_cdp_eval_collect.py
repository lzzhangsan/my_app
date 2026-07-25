import json
import asyncio
import urllib.request
import websockets
import re
import subprocess
from pathlib import Path

# Build the exact JS the app would run by invoking Dart? Too heavy.
# Instead manually assemble like SmartScopeBatchJs.collectAtDepth
dart = Path(r'd:\1.Biancheng\my_app\lib\smart_download\smart_scope_batch.dart').read_text(encoding='utf-8')
helpers = re.search(r"static const helpers = r'''(.*?)''';", dart, re.S).group(1)

# Extract collectAtDepth method body return string - approximate by reading after collectAtDepth
# Simpler: run a dart snippet... or construct from known template.

collect_template = None
# Find the return ''' after collectAtDepth
idx = dart.find('static String collectAtDepth')
chunk = dart[idx:idx+25000]
# The return uses ''' ... ''' with $helpers $d etc
m = re.search(r"return '''\n(.*?)''';\n  \}\n\}\n?\Z", chunk, re.S)
if not m:
    m = re.search(r"return '''\n(.*?)'''\s*;\s*\n\s*\}", chunk, re.S)
body = m.group(1)
# Perform dart-like interpolation for the parts we need
js = body.replace('$helpers', helpers).replace('$d', '3').replace('$imagesOnly', 'false').replace('$videosOnly', 'false').replace('$lim', '20')
# Unescape \$ to $ for regex (dart had \$)
js = js.replace(r'\$', '$')

Path(r'd:\1.Biancheng\my_app\tool\_collect_eval.js').write_text(js, encoding='utf-8')
print('js length', len(js))
print('has FeedRoot', '__sbFeedRoot' in js)
print('has EachMedia', '__sbEachMedia' in js)

async def main():
    pages = [p for p in json.load(urllib.request.urlopen('http://127.0.0.1:9222/json/list')) if p.get('type')=='page']
    print('page', pages[0]['url'][:100])
    ws_url = pages[0]['webSocketDebuggerUrl']
    async with websockets.connect(ws_url, max_size=20_000_000) as ws:
        # first navigate to video if on home
        if '/video' not in pages[0]['url']:
            await ws.send(json.dumps({'id': 9, 'method': 'Page.navigate', 'params': {
                'url': 'https://www.xfree.com/video?id=1053861&title=boom-boom-full-on-patreon'}}))
            while True:
                msg = json.loads(await ws.recv())
                if msg.get('id') == 9:
                    break
            await asyncio.sleep(5)
            # reconnect list
        pages = [p for p in json.load(urllib.request.urlopen('http://127.0.0.1:9222/json/list')) if p.get('type')=='page']
        ws_url = pages[0]['webSocketDebuggerUrl']
    async with websockets.connect(ws_url, max_size=20_000_000) as ws:
        await ws.send(json.dumps({
            'id': 1,
            'method': 'Runtime.evaluate',
            'params': {'expression': js, 'returnByValue': True, 'awaitPromise': True},
        }))
        while True:
            msg = json.loads(await ws.recv())
            if msg.get('id') == 1:
                result = msg.get('result', {}).get('result', {})
                if result.get('subtype') == 'error' or result.get('type') == 'undefined':
                    print('EVAL ERROR', json.dumps(msg, ensure_ascii=False)[:3000])
                else:
                    val = result.get('value', result)
                    # trim items urls
                    if isinstance(val, dict) and 'items' in val:
                        print(json.dumps({
                            'ok': val.get('ok'),
                            'depth': val.get('depth'),
                            'total': val.get('total'),
                            'videoCount': val.get('videoCount'),
                            'imageCount': val.get('imageCount'),
                            'centerTag': val.get('centerTag'),
                            'centerId': val.get('centerId'),
                            'items': val.get('items', [])[:8],
                        }, ensure_ascii=False, indent=2)[:8000])
                    else:
                        print(json.dumps(val, ensure_ascii=False, indent=2)[:4000])
                break

asyncio.run(main())
