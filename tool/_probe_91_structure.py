# -*- coding: utf-8 -*-
"""Probe 91cg1 search + detail HTML structure."""
from pathlib import Path
from html.parser import HTMLParser
import re

root = Path(r"D:\1.Biancheng\my_app\tool\91_site_probe")
search = (root / "search.html").read_text(encoding="utf-8", errors="replace")
detail = (root / "detail.html").read_text(encoding="utf-8", errors="replace")

out = []

def section(title):
    out.append("\n## " + title)

section("SEARCH URL / basics")
out.append(f"search bytes={len(search)} detail bytes={len(detail)}")
# title
m = re.search(r"<title>(.*?)</title>", search, re.I | re.S)
out.append(f"search title: {m.group(1).strip() if m else '?'}")

section("SEARCH: archive links (ordered)")
links = []
for m in re.finditer(r'<a[^>]+href=["\']([^"\']+)["\'][^>]*>(.*?)</a>', search, re.I | re.S):
    href, inner = m.group(1), re.sub(r"<[^>]+>", " ", m.group(2))
    inner = re.sub(r"\s+", " ", inner).strip()
    if "/archives/" in href and re.search(r"/archives/\d+", href):
        links.append((href, inner[:80]))
# dedupe keep order
seen = set()
ordered = []
for href, title in links:
    key = re.sub(r"[#?].*", "", href)
    if key in seen:
        continue
    seen.add(key)
    ordered.append((href, title))
out.append(f"unique archive links: {len(ordered)}")
for i, (href, title) in enumerate(ordered[:12]):
    out.append(f"  [{i}] {href} | {title}")

section("SEARCH: article/card wrappers")
for pat in [
    r'<article\b[^>]*>',
    r'class=["\'][^"\']*post[^"\']*["\']',
    r'class=["\'][^"\']*card[^"\']*["\']',
    r'id=["\']index["\']',
    r'class=["\'][^"\']*search[^"\']*["\']',
    r'page-navigator',
    r'ol class=["\']page-navigator',
]:
    out.append(f"{pat}: {len(re.findall(pat, search, re.I))}")

section("SEARCH: first article block sample")
m = re.search(r"<article[\s\S]{0,2500}?</article>", search, re.I)
if m:
    sample = m.group(0)
    out.append(sample[:1200])
else:
    # mirages might use div.post
    m = re.search(r'<div[^>]*class=["\'][^"\']*post[^"\']*["\'][\s\S]{0,2000}?</div>', search, re.I)
    out.append((m.group(0)[:1200] if m else "no article/post block"))

section("DETAIL: media/player signals")
for pat in [
    r"<video\b",
    r"<source\b",
    r"\.m3u8",
    r"\.mp4",
    r"dplayer",
    r"plyr",
    r"video-js",
    r"iframe",
    r"player",
    r"artplayer",
    r"xgplayer",
    r"hls\.js",
    r"blob:",
    r"poster=",
    r"spinner\.svg",
]:
    out.append(f"{pat}: {len(re.findall(pat, detail, re.I))}")

section("DETAIL: title / structure")
m = re.search(r"<title>(.*?)</title>", detail, re.I | re.S)
out.append(f"detail title: {m.group(1).strip() if m else '?'}")
for pat in [
    r'id=["\']content["\']',
    r'class=["\'][^"\']*post-content[^"\']*["\']',
    r'class=["\'][^"\']*entry-content[^"\']*["\']',
    r'<article\b',
    r'class=["\'][^"\']*post-title[^"\']*["\']',
]:
    out.append(f"{pat}: {len(re.findall(pat, detail, re.I))}")

section("DETAIL: video-ish snippets")
for m in re.finditer(r".{0,80}(m3u8|mp4|dplayer|artplayer|video-js|<video).{0,120}", detail, re.I):
    line = re.sub(r"\s+", " ", m.group(0))
    out.append(line[:220])
    if len(out) > 80:
        break

section("DETAIL: script src hints")
for m in re.finditer(r'<script[^>]+src=["\']([^"\']+)["\']', detail, re.I):
    src = m.group(1)
    if re.search(r"player|video|hls|dplayer|art|mirages|pjax", src, re.I):
        out.append(src)

section("DETAIL: around first video/player")
idx = detail.lower().find("<video")
if idx < 0:
    idx = detail.lower().find("dplayer")
if idx < 0:
    idx = detail.lower().find("m3u8")
if idx >= 0:
    out.append(detail[max(0, idx - 400) : idx + 800])
else:
    out.append("no video/dplayer/m3u8 literal in static HTML")

# age gate
section("AGE GATE")
out.append(f"search age gate: {'年满18岁' in search}")
out.append(f"detail age gate: {'年满18岁' in detail}")

report = "\n".join(out)
(root / "structure_report.md").write_text(report, encoding="utf-8")
print(report[:8000])
print("\n... wrote", root / "structure_report.md")
