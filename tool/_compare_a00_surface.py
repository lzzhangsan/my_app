# -*- coding: utf-8 -*-
import subprocess
import re
from pathlib import Path

def extract(src, sig):
    i = src.find(sig)
    if i < 0:
        return None
    j = i + len(sig)
    while True:
        n = src.find("\n  ", j)
        if n < 0:
            return src[i:]
        line = src[n + 1 : src.find("\n", n + 1)]
        if re.match(
            r"  (Future<|void |bool |String |int |double |Widget |Map<|List<|"
            r"Color |dynamic |@|static |late )",
            line,
        ) and not line.strip().startswith("//"):
            return src[i:n]
        j = n + 3

a00 = subprocess.check_output(
    ["git", "show", "a00c4bd:lib/browser_page.dart"],
    encoding="utf-8",
    errors="replace",
)
head = Path("lib/browser_page.dart").read_text(encoding="utf-8")

for sig in [
    "  Future<void> _onPageFinished(",
    "  Future<void> _startSmartDownload(",
    "  Future<void> _advanceSmartDownload(",
    "  Future<void> _resolveAndDownloadSmartCandidateInBackground(",
    "  Future<bool> _injectDownloadHandlers(",
    "  bool _isSame91TaskPage(",
    "  Future<bool> _clickSmartCandidateLink(",
]:
    o, h = extract(a00, sig), extract(head, sig)
    print(
        sig.strip(),
        "a00",
        None if o is None else len(o),
        "head",
        None if h is None else len(h),
        "same",
        o == h,
    )

print("a00 深入解析", "正在深入解析当前关键词卡片" in a00)
print("a00 strict91KeywordMode", a00.count("strict91KeywordMode"))
print("a00 visiting_clicked_card", a00.count("visiting_clicked_card"))
print("sizes", len(a00), len(head))

# Does a00 onPageFinished have ignore stale callback?
onp = extract(a00, "  Future<void> _onPageFinished(") or ""
print("a00 has 忽略已失效", "忽略已失效" in onp)
print("head has 忽略已失效", "忽略已失效" in (extract(head, "  Future<void> _onPageFinished(") or ""))
