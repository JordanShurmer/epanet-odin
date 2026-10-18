#!/usr/bin/env python3
"""loc.py — count the two sources: lines, functions, decisions, depth, and the API surface.

  audit/loc.py [<epanet checkout>]        one JSON object on stdout (default: epanet-c)

One row per file: lines, blank, comment, code, functions, decisions (if / for
/ while / case / && / ||), the deepest brace nesting and the longest function.
The C files and the Odin files that port them are grouped side by side, the
EN_* functions epanet2_2.h declares are set against the ones api.odin exports,
and the harness is counted on its own. Comments and strings are stripped
first, so a `for` in a comment is not a decision.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "epanet-c")

# What ports what: (group, C files under src/, Odin files under the root).
GROUPS = [
    ("sparse solver", ["smatrix.c", "genmmd.c"],
                      ["epanet/smatrix.odin", "epanet/sparse.odin", "epanet/genmmd.odin"]),
    ("hydraulics", ["hydraul.c", "hydcoeffs.c", "hydsolver.c", "hydstatus.c", "leakage.c", "flowbalance.c"],
                   ["epanet/hydraul.odin", "epanet/hydcoeffs.odin", "epanet/hydsolve.odin",
                    "epanet/hydstatus.odin", "epanet/leakage.odin", "epanet/network.odin"]),
    ("rules", ["rules.c"], ["epanet/rules.odin"]),
    ("water quality", ["quality.c", "qualroute.c", "qualreact.c"], ["epanet/quality.odin"]),
    (".inp reader", ["input1.c", "input2.c", "input3.c", "validate.c"],
                    ["epanet/parse.odin", "epanet/parse2.odin", "epanet/units.odin",
                     "epanet/validate.odin", "epanet/project.odin", "epanet/numbers.odin", "epanet/files.odin"]),
    ("report and files", ["report.c", "output.c"], ["epanet/report.odin", "epanet/output.odin", "epanet/text.odin"]),
    ("toolkit", ["epanet.c", "project.c"],
                ["api/api.odin", "api/edit.odin", "epanet/edit.odin", "epanet/open.odin", "epanet/export.odin", "epanet/errors.odin",
                 "epanet/arena.odin", "epanet/cmath.odin"]),
    (".inp writer", ["inpfile.c"], ["epanet/inpfile.odin"]),
    ("the Odin API", [], ["epanet/model.odin", "epanet/sim.odin", "epanet/simulate.odin", "wasm/epanet.odin"]),
    ("declarations", ["types.h", "funcs.h", "text.h", "enumstxt.h", "hash.h", "mempool.h"], []),
    ("not ported", ["epanet2.c", "hash.c", "mempool.c",
                    "util/cstr_helper.c", "util/cstr_helper.h", "util/errormanager.c",
                    "util/errormanager.h", "util/filemanager.c", "util/filemanager.h"], []),
    ("harness only", [], ["epanet/dump.odin"]),
    ("the wasm build", [], ["epanet/arena_wasm.odin", "epanet/cmath_wasm.odin", "epanet/numbers_wasm.odin", "epanet/report_wasm.odin"]),
]
NOTES = {
    "epanet2.c": "the legacy single-project API",
    "hash.c": "a string hash; the port keeps a map",
    "mempool.c": "a pool; the port keeps an arena",
    "util/filemanager.c": "a file wrapper the port does not need",
    "util/cstr_helper.c": "string helpers",
    "util/errormanager.c": "an error-message table; see errors.odin",
    "epanet/network.odin": "the model and the solver state, one array per field",
    "epanet/export.odin": "the C face the harness plugs in through",
    "epanet/dump.odin": "the project as text, for the parse comparison",
    "epanet/model.odin": "the .inp as data, one fat Entity per component",
    "epanet/sim.odin": "a network as columns, edited at any time and stepped",
    "epanet/simulate.odin": "a whole run as tables",
    "wasm/epanet.odin": "the engine for JavaScript: exports over a Sim and the column table",
    "epanet/text.odin": "the names of things, a report line, the clock, the run's warning",
    "epanet/files.odin": "what opens a file: the readers' file entry, load, write_inp, the quality run over the hydraulics file",
}
HARNESS = ["harness/bridge.c", "harness/run.c", "harness/rebuild.c", "harness/dumpnet.c", "harness/test.sh",
           "harness/out.sh", "cmd/dumpnet/main.odin", "cmd/run/main.odin", "cmd/inp/main.odin", "cmd/check/main.odin",
           "wasm/check.mjs",
           "audit/audit.sh", "audit/bench.c", "audit/loc.py", "audit/render.py"]

DECISION = {
    "c": re.compile(r"\b(?:if|for|while|case)\b|&&|\|\||\?"),
    "odin": re.compile(r"\b(?:if|for|case|when)\b|&&|\|\|"),
    "sh": re.compile(r"\b(?:if|for|while|case|elif)\b|&&|\|\|"),
    "py": re.compile(r"\b(?:if|for|while|elif|and|or)\b"),
}
FUNC = {
    "c": re.compile(r"^[A-Za-z_][\w\s\*]*?\b[A-Za-z_]\w*\s*\([^;]*$"),
    "odin": re.compile(r"^\w+\s*::\s*(?:#\w+\s+)?proc\b"),
    "sh": re.compile(r"^\w+\s*\(\)\s*\{"),
    "py": re.compile(r"^\s*def\s+\w+"),
}
NOT_FUNC = re.compile(r"^(?:typedef|return|else|struct|union|enum|extern|#)\b")


def lang_of(path):
    return {".c": "c", ".h": "c", ".odin": "odin", ".sh": "sh", ".py": "py"}[os.path.splitext(path)[1]]


def strip(line, lang, state):
    """The code of one line with comments and strings taken out, and whether it held a comment.
    state[0] is the block-comment depth carried from the line before."""
    out, had, i, n = [], False, 0, len(line)
    hash_comment = lang in ("sh", "py")
    while i < n:
        if state[0]:
            had = True
            if lang == "odin" and line.startswith("/*", i):
                state[0] += 1
                i += 2
            elif line.startswith("*/", i):
                state[0] -= 1
                i += 2
            else:
                i += 1
            continue
        if hash_comment and line[i] == "#":
            had = True
            break
        if not hash_comment and line.startswith("//", i):
            had = True
            break
        if not hash_comment and line.startswith("/*", i):
            had = True
            state[0] = 1
            i += 2
            continue
        c = line[i]
        if c in "\"'`":
            j = i + 1
            while j < n and line[j] != c:
                if line[j] == "\\" and c != "`":
                    j += 1
                j += 1
            out.append('""')
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), had


def count(path):
    lang = lang_of(path)
    row = {"file": path, "lang": lang, "lines": 0, "blank": 0, "comment": 0, "code": 0,
           "functions": 0, "decisions": 0, "max_depth": 0, "longest": 0}
    state, depth, start, line_no = [0], 0, None, 0
    with open(os.path.join(ROOT, path) if not os.path.isabs(path) else path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line_no += 1
            row["lines"] += 1
            code, had = strip(raw.rstrip("\n"), lang, state)
            text = code.strip()
            if not text:
                row["comment" if had else "blank"] += 1
                continue
            row["code"] += 1
            row["decisions"] += len(DECISION[lang].findall(code))
            if FUNC[lang].match(code) and not NOT_FUNC.match(text):
                row["functions"] += 1
                if start is not None:
                    row["longest"] = max(row["longest"], line_no - start)
                start = line_no
            for ch in code:
                if ch == "{":
                    depth += 1
                    row["max_depth"] = max(row["max_depth"], depth)
                elif ch == "}":
                    depth = max(0, depth - 1)
    if start is not None:
        row["longest"] = max(row["longest"], line_no - start + 1)
    return row


def c_file(name):
    return os.path.join(EP, "src", name)


def main():
    files = []
    seen = set()
    for group, cs, odins in GROUPS:
        for name in cs:
            p = c_file(name)
            if os.path.exists(p):
                r = count(p)
                r.update(file=name, group=group, side="c")
                files.append(r)
                seen.add(name)
        for name in odins:
            if os.path.exists(os.path.join(ROOT, name)):
                r = count(name)
                r.update(group=group, side="odin")
                files.append(r)
                seen.add(name)
    # Anything in src/ the table did not name, so a new EPANET file is never silently dropped.
    for sub in ("", "util"):
        d = os.path.join(EP, "src", sub)
        for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            rel = os.path.join(sub, name) if sub else name
            if rel in seen or not name.endswith((".c", ".h")):
                continue
            r = count(c_file(rel))
            r.update(file=rel, group="not ported", side="c")
            files.append(r)
    for d in ("epanet", "api"):
        for name in sorted(os.listdir(os.path.join(ROOT, d))):
            rel = d + "/" + name
            if rel not in seen and name.endswith(".odin"):
                r = count(rel)
                r.update(group="other", side="odin")
                files.append(r)

    harness = [count(p) for p in HARNESS if os.path.exists(os.path.join(ROOT, p))]
    fixtures = {
        "EPANET example networks": len([f for f in os.listdir(os.path.join(EP, "example-networks")) if f.endswith(".inp")]),
        "EPANET test networks": len([f for f in os.listdir(os.path.join(EP, "tests", "data")) if f.endswith(".inp")]),
        "harness/fixtures": len([f for f in os.listdir(os.path.join(ROOT, "harness", "fixtures")) if f.endswith(".inp")]),
        "generated (grid40)": 1,
    }

    header = open(os.path.join(EP, "include", "epanet2_2.h"), encoding="utf-8", errors="replace").read()
    declared = sorted(set(re.findall(r"DLLEXPORT\s+(EN_\w+)\s*\(", header)))
    api = "".join(open(os.path.join(ROOT, "api", f), encoding="utf-8").read()
                  for f in sorted(os.listdir(os.path.join(ROOT, "api"))) if f.endswith(".odin"))
    exported = sorted(set(re.findall(r'link_name\s*=\s*"(EN_\w+)"', api)))

    json.dump({
        "files": files,
        "groups": [g[0] for g in GROUPS],
        "notes": NOTES,
        "harness": {"files": harness, "fixtures": fixtures},
        "api": {"declared": declared, "exported": exported,
                "missing": [n for n in declared if n not in exported]},
    }, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
