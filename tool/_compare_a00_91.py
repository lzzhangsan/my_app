# -*- coding: utf-8 -*-
from pathlib import Path
import subprocess
import re

old = subprocess.check_output(
    ["git", "show", "a00c4bd:lib/browser_page.dart"],
    encoding="utf-8",
    errors="replace",
)
new = Path("lib/browser_page.dart").read_text(encoding="utf-8")


def extract(src: str, sig: str) -> str | None:
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


def normalize_a00(text: str) -> str:
    mapping = [
        ("_startSmartDownload91A00", "_startSmartDownload"),
        ("_advanceSmartDownload91A00", "_advanceSmartDownload"),
        ("_visitNextSmartCandidate91A00", "_visitNextSmartCandidate"),
        (
            "_resolveAndDownloadSmartCandidate91A00",
            "_resolveAndDownloadSmartCandidateInBackground",
        ),
        ("_returnFromSmartMediaCard91A00", "_returnFromSmartMediaCard"),
    ]
    out = text
    for a, b in mapping:
        out = out.replace(a, b)
    lines = []
    for ln in out.splitlines():
        if "a00_91_pipeline" in ln:
            continue
        if "'siteProfile': '91'" in ln:
            continue
        lines.append(ln)
    return "\n".join(lines)


pairs = [
    (
        "start",
        "  Future<void> _startSmartDownload(",
        "  Future<void> _startSmartDownload91A00(",
    ),
    (
        "advance",
        "  Future<void> _advanceSmartDownload(",
        "  Future<void> _advanceSmartDownload91A00(",
    ),
    (
        "visit",
        "  void _visitNextSmartCandidate(",
        "  void _visitNextSmartCandidate91A00(",
    ),
    (
        "resolve",
        "  Future<void> _resolveAndDownloadSmartCandidateInBackground(",
        "  Future<void> _resolveAndDownloadSmartCandidate91A00(",
    ),
    (
        "return",
        "  Future<void> _returnFromSmartMediaCard(",
        "  Future<void> _returnFromSmartMediaCard91A00(",
    ),
]

print("=== Core FSM methods vs a00c4bd ===")
for name, old_sig, new_sig in pairs:
    o = extract(old, old_sig)
    n = extract(new, new_sig)
    if o is None or n is None:
        print(name, "MISSING", o is None, n is None)
        continue
    n_norm = normalize_a00(n)
    o_norm = "\n".join(o.splitlines())
    same = o_norm == n_norm
    print(
        f"{name}: identical_to_a00={same} "
        f"old_lines={o_norm.count(chr(10))+1} new_lines={n_norm.count(chr(10))+1}"
    )
    if not same:
        ol, nl = o_norm.splitlines(), n_norm.splitlines()
        for k, (a, b) in enumerate(zip(ol, nl)):
            if a != b:
                print(f"  first diff @{k+1}")
                print("   OLD:", a[:140])
                print("   NEW:", b[:140])
                break
        else:
            print(f"  line-count differ old={len(ol)} new={len(nl)}")

print("\n=== Shared helpers used by 91 path ===")
helpers = [
    "  bool _isSame91TaskPage(",
    "  bool _is91ContentPage(",
    "  String _smartStablePageKey(",
    "  Future<bool> _clickSmartCandidateLink(",
    "  Future<bool> _openNearestSmartMediaCard(",
    "  bool _isSameLoadedDocument(",
]
for sig in helpers:
    o = extract(old, sig)
    n = extract(new, sig)
    print(f"{sig.strip()}: identical_to_a00={o == n}")

print("\n=== Entry wiring ===")
print("has _startSmartDownload91A00 call for pattern 91:", "id == '91'" in new and "_startSmartDownload91A00" in new)
print("has a00 gate in _advanceSmartDownload:", "a00_91_pipeline" in new)
