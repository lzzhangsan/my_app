# -*- coding: utf-8 -*-
"""Diff inserted A00 methods vs renamed bundle; check bounce-related conditions."""
from pathlib import Path
import re
import subprocess

root = Path(r"D:\1.Biancheng\my_app")
bp = (root / "lib" / "browser_page.dart").read_text(encoding="utf-8")
ren = (root / "tool" / "a00_91_methods_renamed.dart").read_text(encoding="utf-8")
old = subprocess.check_output(
    ["git", "show", "a00c4bd:lib/browser_page.dart"],
    cwd=root,
    encoding="utf-8",
    errors="replace",
)

def extract(src: str, start_sig: str, end_sig: str | None = None) -> str:
    i = src.find(start_sig)
    if i < 0:
        return ""
    if end_sig:
        j = src.find(end_sig, i + len(start_sig))
        return src[i:j] if j > 0 else src[i:]
    return src[i:]

# Compare deep-resolve gate
needle = "正在深入解析当前关键词卡片"
for label, src in [("lib", bp), ("renamed", ren), ("a00", old)]:
    i = src.find(needle)
    print(f"\n=== {label} deep-resolve present={i>=0} ===")
    if i >= 0:
        chunk = src[i - 600 : i + 200]
        # print condition lines
        for line in chunk.splitlines():
            if "uniqueUrls.isEmpty" in line or "visiting_clicked" in line or "is91" in line or "_is91ContentPage" in line or "深入解析" in line:
                print(line)

# pageUrl assignment in A00 advance inside lib
i = bp.find("Future<void> _advanceSmartDownload91A00")
j = bp.find("void _visitNextSmartCandidate91A00")
adv = bp[i:j]
print("\npageUrl assignment in lib A00 advance:")
for line in adv.splitlines():
    if "pageUrl" in line and ("loadedUrl" in line or "actual" in line or "currentUrl" in line):
        print(line)

# Check if shared helpers called from A00 can escape to HEAD visitNext
print("\nHEAD helpers referenced from A00 block:")
a00_block = bp[bp.find("// ========== a00c4bd 91 pipeline") :]
for name in [
    "_visitNextSmartCandidate(",
    "_advanceSmartDownload(",
    "_returnFromSmartMediaCard(",
    "_openNearestSmartMediaCard",
    "_broadenSmartDiscovery",
    "_continueSmartFeed",
]:
    print(f"  {name}: {a00_block.count(name)}")

# Check _isSameLoadedDocument for search pages
print("\n_isSameLoadedDocument def snippet:")
k = bp.find("bool _isSameLoadedDocument")
print(bp[k : k + 700])
