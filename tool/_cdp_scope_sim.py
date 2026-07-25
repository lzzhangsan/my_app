import json
import asyncio
import urllib.request
import websockets

# Extract helpers from dart by inlining a minimal collect simulation
JS = open(r'd:\1.Biancheng\my_app\tool\_scope_sim.js', encoding='utf-8').read()


async def main():
    pages = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json/list'))
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
                val = result.get('value', result)
                print(json.dumps(val, ensure_ascii=False, indent=2)[:18000])
                break


if __name__ == '__main__':
    asyncio.run(main())
