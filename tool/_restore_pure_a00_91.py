# -*- coding: utf-8 -*-
"""Restore pure a00c4bd 91 smart-download path into browser_page.dart.

- FSM methods: absolute rename copy from a00c4bd
- Helpers that diverged and are called by that FSM: also a00 copies (*91A00)
- Only intentional addition: a00_91_pipeline routing flag in start task map
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(r"D:\1.Biancheng\my_app")
old = subprocess.check_output(
    ["git", "show", "a00c4bd:lib/browser_page.dart"],
    cwd=ROOT,
    encoding="utf-8",
    errors="replace",
)
bp_path = ROOT / "lib" / "browser_page.dart"
bp = bp_path.read_text(encoding="utf-8")


def extract(src: str, sig: str) -> str:
    i = src.find(sig)
    if i < 0:
        raise SystemExit(f"missing {sig}")
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


fsm_sigs = [
    "  Future<void> _startSmartDownload(",
    "  Future<void> _advanceSmartDownload(",
    "  void _visitNextSmartCandidate(",
    "  Future<void> _resolveAndDownloadSmartCandidateInBackground(",
    "  Future<void> _returnFromSmartMediaCard(",
]
helper_sigs = [
    "  Future<bool> _openNearestSmartMediaCard(",
    "  void _broadenSmartDiscovery(",
    "  void _continueSmartFeed(",
]

fsm = [extract(old, s) for s in fsm_sigs]
helpers = [extract(old, s) for s in helper_sigs]

# Rename map: apply longest-first inside each chunk.
rename_fsm = [
    ("_resolveAndDownloadSmartCandidateInBackground", "_resolveAndDownloadSmartCandidate91A00"),
    ("_returnFromSmartMediaCard", "_returnFromSmartMediaCard91A00"),
    ("_visitNextSmartCandidate", "_visitNextSmartCandidate91A00"),
    ("_advanceSmartDownload", "_advanceSmartDownload91A00"),
    ("_startSmartDownload", "_startSmartDownload91A00"),
    # Point FSM at a00 helper snapshots (not HEAD versions)
    ("_openNearestSmartMediaCard", "_openNearestSmartMediaCard91A00"),
    ("_broadenSmartDiscovery", "_broadenSmartDiscovery91A00"),
    ("_continueSmartFeed", "_continueSmartFeed91A00"),
]
rename_helpers = [
    ("_openNearestSmartMediaCard", "_openNearestSmartMediaCard91A00"),
    ("_broadenSmartDiscovery", "_broadenSmartDiscovery91A00"),
    ("_continueSmartFeed", "_continueSmartFeed91A00"),
    # helpers may call advance / visit / return — keep them on a00 pipeline
    ("_advanceSmartDownload", "_advanceSmartDownload91A00"),
    ("_visitNextSmartCandidate", "_visitNextSmartCandidate91A00"),
    ("_returnFromSmartMediaCard", "_returnFromSmartMediaCard91A00"),
]


def apply_renames(text: str, pairs: list[tuple[str, str]]) -> str:
    out = text
    for a, b in sorted(pairs, key=lambda x: -len(x[0])):
        out = out.replace(a, b)
    return out


fsm_bundle = apply_renames("\n\n".join(fsm), rename_fsm)
helper_bundle = apply_renames("\n\n".join(helpers), rename_helpers)

# Routing flag only
needle = "      'strict91KeywordMode': keywordFirstOn91,"
flag = (
    "      'strict91KeywordMode': keywordFirstOn91,\n"
    "      'a00_91_pipeline': true,"
)
if "a00_91_pipeline" not in fsm_bundle:
    if needle not in fsm_bundle:
        raise SystemExit("cannot insert a00_91_pipeline")
    fsm_bundle = fsm_bundle.replace(needle, flag, 1)

bundle = (
    "  // ========== a00c4bd 91 pipeline (pure copy from a00c4bd, no remix) ==========\n\n"
    + fsm_bundle
    + "\n\n"
    + "  // ----- a00c4bd helper snapshots used only by 91 a00 pipeline -----\n\n"
    + helper_bundle
    + "\n"
)

# Restore shared _isSame91TaskPage to a00 (91 identity checks)
is_same_old = extract(old, "  bool _isSame91TaskPage(")
is_same_new = extract(bp, "  bool _isSame91TaskPage(")
if is_same_old != is_same_new:
    bp = bp.replace(is_same_new, is_same_old, 1)
    print("restored _isSame91TaskPage -> a00c4bd")
else:
    print("_isSame91TaskPage already a00")

# Remove a00 redirect patch from HEAD _returnFromSmartMediaCard if present —
# a00 helper snapshots call *91A00 return directly; HEAD return should stay HEAD.
head_ret = extract(bp, "  Future<void> _returnFromSmartMediaCard(")
# If it redirects a00 pipeline, strip that for purity of HEAD method (optional).
# Keep redirect as safety when HEAD openNearest is somehow used — actually user
# wants pure a00. Keep a small gate only in _advanceSmartDownload.
redirect_snip = (
    "    // 共享卡片入口若触发返回，a00 91 任务必须回到 a00 队列，不能串进 HEAD visitNext。\n"
    "    if (task['a00_91_pipeline'] == true) {\n"
    "      await _returnFromSmartMediaCard91A00(task, madeProgress: madeProgress);\n"
    "      return;\n"
    "    }\n"
)
if redirect_snip in head_ret:
    # Keep it — prevents HEAD helpers from poisoning a00 tasks. Not an a00 algorithm change.
    print("kept HEAD->a00 return safety redirect")

# Replace a00 block at end of class
start_marker = "  // ========== a00c4bd 91 pipeline"
start = bp.find(start_marker)
if start < 0:
    start = bp.find("  Future<void> _startSmartDownload91A00(")
if start < 0:
    raise SystemExit("cannot find existing a00 block start")

# Class closing brace (unindented)
end = bp.find("\n}\n", start)
if end < 0:
    end = bp.rfind("\n}")
    if end < 0:
        raise SystemExit("cannot find class end")

bp = bp[:start] + bundle + bp[end:]
bp_path.write_text(bp, encoding="utf-8")
print("wrote pure a00 block, chars", len(bundle))

bp2 = bp_path.read_text(encoding="utf-8")
for name in [
    "_startSmartDownload91A00",
    "_advanceSmartDownload91A00",
    "_visitNextSmartCandidate91A00",
    "_resolveAndDownloadSmartCandidate91A00",
    "_returnFromSmartMediaCard91A00",
    "_openNearestSmartMediaCard91A00",
    "_broadenSmartDiscovery91A00",
    "_continueSmartFeed91A00",
]:
    print(f"  {name}: defs={bp2.count(' '+name+'(') + bp2.count('void '+name) } refs={bp2.count(name)}")

remnants = [
    "on91ListSide",
    "actualLoadedUrl.isNotEmpty",
    "window.scrollBy({top: step",
    "strict91 必须标记",
    "搜索页等非 archives",
]
print("remnants:")
for r in remnants:
    print(f"  {r!r}: {r in bp2}")
