import json
import asyncio
import urllib.request
import websockets
import re
from pathlib import Path

dart = Path(r'd:\1.Biancheng\my_app\lib\smart_download\smart_scope_batch.dart').read_text(encoding='utf-8')
helpers = re.search(r"static const helpers = r'''(.*?)''';", dart, re.S).group(1)
idx = dart.find('static String collectAtDepth')
chunk = dart[idx:idx + 25000]
body = re.search(r"return '''\n(.*?)'''\s*;\s*\n\s*\}", chunk, re.S).group(1)


def build(depth: int) -> str:
    js = (
        body.replace('$helpers', helpers)
        .replace('$d', str(depth))
        .replace('$imagesOnly', 'false')
        .replace('$videosOnly', 'false')
        .replace('$lim', '40')
    )
    # Dart non-raw string stored \$ as literal backslash-dollar in source;
    # after Dart compilation \$ becomes $. In the .dart file text we have \$.
    js = js.replace('\\$', '$')
    return js


async def main():
    pages = [
        p
        for p in json.load(urllib.request.urlopen('http://127.0.0.1:9222/json/list'))
        if p.get('type') == 'page'
    ]
    ws_url = pages[0]['webSocketDebuggerUrl']
    print('url', pages[0]['url'][:100])
    async with websockets.connect(ws_url, max_size=20_000_000) as ws:
        for depth in [0, 3, 6, 9]:
            js = build(depth)
            await ws.send(
                json.dumps(
                    {
                        'id': depth + 1,
                        'method': 'Runtime.evaluate',
                        'params': {
                            'expression': js,
                            'returnByValue': True,
                            'awaitPromise': True,
                        },
                    }
                )
            )
            while True:
                msg = json.loads(await ws.recv())
                if msg.get('id') == depth + 1:
                    r = msg.get('result', {}).get('result', {})
                    v = r.get('value')
                    if not isinstance(v, dict):
                        print('d', depth, 'ERR', str(msg)[:400])
                    else:
                        sample = [
                            (i.get('kind'), (i.get('url') or '')[:75])
                            for i in (v.get('items') or [])[:6]
                        ]
                        print(
                            'd',
                            depth,
                            'v',
                            v.get('videoCount'),
                            'i',
                            v.get('imageCount'),
                            'center',
                            v.get('centerId'),
                            sample,
                        )
                    break


if __name__ == '__main__':
    asyncio.run(main())
