# -*- coding: utf-8 -*-
import re
from pathlib import Path
from html import unescape

d = Path(r"D:\1.Biancheng\my_app\tool\91_site_probe\detail.html").read_text(
    encoding="utf-8", errors="replace"
)
s = Path(r"D:\1.Biancheng\my_app\tool\91_site_probe\search.html").read_text(
    encoding="utf-8", errors="replace"
)
lines = []

lines.append("=== SEARCH CARD DOM ===")
m = re.search(r'<div class="post-card"[^>]*>[\s\S]{0,1800}', s)
lines.append(m.group(0)[:1600] if m else "none")

lines.append("\n=== DETAIL DPLAYERS ===")
players = list(re.finditer(r'<div class="dplayer"([^>]*)>', d, re.I))
lines.append(f"count {len(players)}")
for i, mm in enumerate(players[:8]):
    attrs = mm.group(1)
    vid = re.search(r'data-video_id="([^"]+)"', attrs)
    title = re.search(r'data-video_title="([^"]+)"', attrs)
    cfg = re.search(r"data-config='([^']+)'", attrs)
    t = title.group(1) if title else "?"
    lines.append(f"[{i}] id={vid.group(1) if vid else '?'} title={t[:70]}")
    if cfg:
        raw = unescape(cfg.group(1)).replace("\\/", "/")
        urls = re.findall(r"https?://[^\"\s]+?\.m3u8[^\"\s]*", raw)
        lines.append(f"  m3u8 in config: {len(urls)}")
        if urls:
            lines.append("  " + re.sub(r"\?.*", "", urls[0])[:140])
        lines.append(f"  has pre_ads: {'pre_ads' in raw}")

title_i = d.find("post-title")
dp_i = d.find('class="dplayer"')
lines.append(f"\noffset title={title_i} dplayer={dp_i} delta={dp_i - title_i}")
if title_i >= 0 and dp_i > title_i:
    between = d[title_i:dp_i]
    img_n = len(re.findall(r"<img\b", between, re.I))
    ad_n = len(re.findall(r"banner|hc237|loadBanner|adsby|pre_ads", between, re.I))
    lines.append(f"imgs between title->player: {img_n}")
    lines.append(f"ad-ish tokens between: {ad_n}")
    lines.append(f"chars between: {len(between)}")

# heading markers before players
heads = re.findall(r"<h2[^>]*>(.*?)</h2>", d, re.I | re.S)
lines.append("\nH2 headings:")
for h in heads[:20]:
    lines.append(" - " + re.sub(r"<[^>]+>", "", h).strip()[:80])

report = "\n".join(lines)
outp = Path(r"D:\1.Biancheng\my_app\tool\91_site_probe\structure_detail.md")
outp.write_text(report, encoding="utf-8")
print("wrote", outp, "chars", len(report))
