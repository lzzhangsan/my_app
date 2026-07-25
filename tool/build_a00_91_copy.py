# -*- coding: utf-8 -*-
from pathlib import Path
import re

outdir = Path("tool/a00_91_extract")
start = (outdir / "_startSmartDownload.dart").read_text(encoding="utf-8")
advance = (outdir / "_advanceSmartDownload.dart").read_text(encoding="utf-8")
visit = (outdir / "_visitNextSmartCandidate.dart").read_text(encoding="utf-8")
resolve = (outdir / "_resolveAndDownloadSmartCandidateInBackground.dart").read_text(
    encoding="utf-8"
)
ret = (outdir / "_returnFromSmartMediaCard.dart").read_text(encoding="utf-8")

replacements = [
    ("_startSmartDownload", "_startSmartDownload91A00"),
    ("_advanceSmartDownload", "_advanceSmartDownload91A00"),
    ("_visitNextSmartCandidate", "_visitNextSmartCandidate91A00"),
    (
        "_resolveAndDownloadSmartCandidateInBackground",
        "_resolveAndDownloadSmartCandidate91A00",
    ),
    ("_returnFromSmartMediaCard", "_returnFromSmartMediaCard91A00"),
]


def rename(src: str) -> str:
    out = src
    for old, new in replacements:
        out = out.replace(old, new)
    return out


start2 = rename(start)
needle = "'strict91KeywordMode': keywordFirstOn91,"
if needle in start2:
    start2 = start2.replace(
        needle,
        "'strict91KeywordMode': keywordFirstOn91,\n"
        "      'a00_91_pipeline': true,\n"
        "      'siteProfile': '91',",
        1,
    )
else:
    print("WARN: could not inject a00_91_pipeline flag")

# a00 start signature may lack newer optional params used by dialog - keep a00 signature.
advance2 = rename(advance)
visit2 = rename(visit)
resolve2 = rename(resolve)
ret2 = rename(ret)

body = "\n\n".join(
    [
        "  // ========== a00c4bd 91 pipeline (absolute copy, do not remix) ==========",
        start2,
        advance2,
        visit2,
        resolve2,
        ret2,
    ]
)
out = Path("tool/a00_91_methods_renamed.dart")
out.write_text(body, encoding="utf-8")
print("written", out, "chars", len(body), "lines", body.count("\n"))
for old, new in replacements:
    left = len(re.findall(r"  (?:Future<[^>]+>|void) " + re.escape(old) + r"\(", body))
    print(old, "old-def-left", left, "->", new)
