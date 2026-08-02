import html
import json
import re
import sys
from urllib.parse import urlparse

path = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\Administrator\AppData\Local\Temp\flutter_prefs.xml"
raw_bytes = open(path, "rb").read()
if raw_bytes.startswith(b"\xff\xfe"):
    text = raw_bytes.decode("utf-16-le", errors="replace")
elif raw_bytes.startswith(b"\xfe\xff"):
    text = raw_bytes.decode("utf-16-be", errors="replace")
else:
    text = raw_bytes.decode("utf-8", errors="replace")
marker = 'name="flutter.common_websites">'
start = text.find(marker)
if start < 0:
    sys.exit("common_websites not found")
start += len(marker)
end = text.find("</string>", start)
if end < 0:
    sys.exit("common_websites end not found")
raw_json = html.unescape(text[start:end])
try:
    items = json.loads(raw_json)
except json.JSONDecodeError:
    items = []
    for m in re.finditer(
        r'\{"name":"((?:\\.|[^"\\])*)","url":"((?:\\.|[^"\\])*)","iconCode":\d+\}',
        raw_json,
    ):
        name = json.loads(f'"{m.group(1)}"')
        url = json.loads(f'"{m.group(2)}"')
        items.append({"name": name, "url": url})
    if not items:
        for m in re.finditer(r'"url":"(https?://[^"]+)"', raw_json):
            items.append({"name": f"site-{len(items)+1}", "url": json.loads(f'"{m.group(1)}"')})
    if not items:
        raise

seen = set()
groups = {
    "core_video": [],
    "social": [],
    "image_gallery": [],
    "downloader_tools": [],
    "search_nav": [],
    "other": [],
}


def host(u: str) -> str:
    try:
        return urlparse(u).netloc.lower().replace("www.", "")
    except Exception:
        return ""


for i, it in enumerate(items, 1):
    name = (it.get("name") or "").strip()
    url = (it.get("url") or "").strip()
    h = host(url)
    key = (name.lower(), h)
    dup = key in seen
    seen.add(key)
    row = f"{i:2}. {name} | {url}" + (" [dup]" if dup else "")

    if any(
        x in h
        for x in [
            "x.com",
            "twitter.com",
            "91cg",
            "facebook",
            "instagram",
            "telegram",
            "tik.porn",
            "pin.porn",
            "xfree",
            "xvideos",
            "youtube",
            "youtu.be",
        ]
    ):
        groups["core_video"].append(row)
    elif any(
        x in h
        for x in ["downloader", "iiilab", "indown", "fdown", "threadsdown"]
    ):
        groups["downloader_tools"].append(row)
    elif any(x in h for x in ["baidu", "google"]):
        groups["search_nav"].append(row)
    elif any(
        x in h
        for x in [
            "xsnvshen",
            "pornpics",
            "elitebabes",
            "eroticbeauties",
            "youporn",
            "fikfap",
            "avrebo",
            "reelsmunkey",
            "svortking",
        ]
    ):
        groups["image_gallery"].append(row)
    else:
        groups["other"].append(row)

print(f"TOTAL {len(items)} cards, {len(seen)} unique name+host")
for g, rows in groups.items():
    if rows:
        print(f"\n=== {g} ({len(rows)}) ===")
        for r in rows:
            print(r)
