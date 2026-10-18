#!/usr/bin/env python3
"""render.py — the audit's files read, the summary printed, index.html written.

  audit/render.py [build/audit]          print the summary and write <dir>/index.html
  audit/render.py build/audit --quiet    write the page only

Reads what audit/audit.sh left in the directory — harness.txt, loc.json,
builds.txt, bench-*.jsonl, equiv.txt, the callgrind, massif and memcheck
files, coverage.json, env.txt — and renders them twice: a few tables on the
terminal, and one HTML page with the same figures and the bars that make them
readable. A measurement that was skipped is said to be, not left blank.
"""
import html
import json
import os
import re
import statistics
import sys

IMPLS = ["c", "odin", "odin-nbc"]
LABEL = {"c": "EPANET (C)", "odin": "Odin", "odin-nbc": "Odin, no bounds checks"}
SHORT = {"c": "C", "odin": "Odin", "odin-nbc": "Odin −bc"}


# ── reading ───────────────────────────────────────────────────────────────

def kv(path):
    """key<TAB>value lines as a dict; a line with three fields nests: {key: {field: value}}."""
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 2:
            out[parts[0]] = parts[1]
        elif len(parts) == 3:
            out.setdefault(parts[0], {})[parts[1]] = parts[2]
    return out


def jsonl(path):
    if not os.path.exists(path):
        return []
    rows = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def callgrind_summary(path):
    """The event names and their program totals, from the raw file."""
    events, summary = [], []
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("events:"):
            events = line.split()[1:]
        elif line.startswith("summary:"):
            summary = [int(x) for x in line.split()[1:]]
    return dict(zip(events, summary))


ANNOT = re.compile(r"^\s*([\d,]+)\s+\(\s*[\d.]+%\)\s.*?(\S+):(\S+)\s+\[")


def callgrind_functions(path):
    """(Ir, file, function) per row of callgrind_annotate's table, in its order (Ir descending)."""
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path, encoding="utf-8", errors="replace"):
        m = ANNOT.match(line)
        if m:
            rows.append((int(m.group(1).replace(",", "")), m.group(2), m.group(3)))
    return rows


def massif_peak(path):
    peak, cur = 0, {}
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("snapshot="):
            cur = {}
        for key in ("mem_heap_B", "mem_heap_extra_B", "mem_stacks_B"):
            if line.startswith(key + "="):
                cur[key] = int(line.split("=")[1])
                if key == "mem_stacks_B":
                    peak = max(peak, cur.get("mem_heap_B", 0) + cur.get("mem_heap_extra_B", 0))
    return peak


FRAME = re.compile(r"^==\d+==\s+(?:at|by) 0x[0-9A-Fa-f]+: (\S+)")
NOISE = ("runtime::", "os::", "calloc", "malloc", "realloc", "free", "posix_memalign", "aligned_alloc", "???")


def memcheck(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    out = {"errors": None, "contexts": 0, "suppressed": 0, "allocs": 0, "frees": 0, "bytes": 0,
           "definitely": 0, "possibly": 0, "reachable": 0, "origins": []}
    m = re.search(r"ERROR SUMMARY: (\d+) errors from (\d+) contexts \(suppressed: (\d+) from (\d+)\)", text)
    if m:
        out.update(errors=int(m.group(1)), contexts=int(m.group(2)), suppressed=int(m.group(3)))
    m = re.search(r"total heap usage: ([\d,]+) allocs, ([\d,]+) frees, ([\d,]+) bytes allocated", text)
    if m:
        out.update(allocs=int(m.group(1).replace(",", "")), frees=int(m.group(2).replace(",", "")),
                   bytes=int(m.group(3).replace(",", "")))
    for key, word in (("definitely", "definitely lost"), ("possibly", "possibly lost"), ("reachable", "still reachable")):
        m = re.search(word + r": ([\d,]+) bytes", text)
        if m:
            out[key] = int(m.group(1).replace(",", ""))
    # Each finding's first frame outside the allocator and the runtime: where it comes from.
    block, origins = [], []
    for line in text.splitlines() + ["==0== "]:
        m = FRAME.match(line)
        if m:
            block.append(m.group(1))
        elif block:
            for fn in block:
                if not fn.startswith(NOISE):
                    if fn not in origins:
                        origins.append(fn)
                    break
            block = []
    out["origins"] = origins[:6]
    return out


def load(d):
    D = {"dir": d, "env": kv(os.path.join(d, "env.txt")), "harness": kv(os.path.join(d, "harness.txt")),
         "builds": kv(os.path.join(d, "builds.txt"))}
    D["loc"] = json.load(open(os.path.join(d, "loc.json"))) if os.path.exists(os.path.join(d, "loc.json")) else None
    D["bench"] = {impl: {b["fixture"]: b for b in jsonl(os.path.join(d, f"bench-{impl}.jsonl")) if b.get("errcode") == 0}
                  for impl in IMPLS}
    D["equiv"] = {}
    for line in open(os.path.join(d, "equiv.txt"), encoding="utf-8") if os.path.exists(os.path.join(d, "equiv.txt")) else []:
        fx, impl, what, verdict = line.rstrip("\n").split("\t")
        D["equiv"].setdefault(fx, {}).setdefault(impl, {})[what] = verdict  # ok, near or bad
    D["examples"] = D["env"].get("examples", "").split()
    D["callgrind"], D["massif"], D["memcheck"] = {}, {}, {}
    for impl in IMPLS:
        for fx in D["examples"]:
            p = os.path.join(d, f"callgrind.{impl}.{fx}")
            if os.path.exists(p):
                D["callgrind"][(impl, fx)] = {"summary": callgrind_summary(p),
                                              "self": callgrind_functions(p + ".self.txt"),
                                              "incl": callgrind_functions(p + ".incl.txt")}
            p = os.path.join(d, f"massif.{impl}.{fx}")
            if os.path.exists(p):
                D["massif"][(impl, fx)] = massif_peak(p)
            p = os.path.join(d, f"memcheck.{impl}.{fx}.txt")
            if os.path.exists(p):
                D["memcheck"][(impl, fx)] = memcheck(p)
    p = os.path.join(d, "coverage.json")
    D["coverage"] = json.load(open(p))["data"][0] if os.path.exists(p) else None
    return D


# ── figures ───────────────────────────────────────────────────────────────

def n(x):
    return format(int(round(x)), ",")


def kb(bytes_):
    return "%s KB" % n(bytes_ / 1024)


def ms(ns):
    if ns < 1e5:
        return "%.0f µs" % (ns / 1e3)
    return "%.2f ms" % (ns / 1e6) if ns < 1e8 else "%.0f ms" % (ns / 1e6)


def pct(a, b):
    return "%.0f%%" % (100.0 * a / b) if b else "—"


def ratio(a, b):
    return "%.2f×" % (a / b) if b else "—"


def loc_totals(loc):
    tot = {}
    for r in loc["files"]:
        if r["group"] in ("harness only", "the Odin API"):
            continue
        t = tot.setdefault(r["side"], {"files": 0, "lines": 0, "code": 0, "comment": 0, "functions": 0,
                                       "decisions": 0, "max_depth": 0, "longest": 0})
        t["files"] += 1
        for k in ("lines", "code", "comment", "functions", "decisions"):
            t[k] += r[k]
        t["max_depth"] = max(t["max_depth"], r["max_depth"])
        t["longest"] = max(t["longest"], r["longest"])
    return tot


def loc_groups(loc):
    rows = []
    for g in loc["groups"]:
        cs = [r for r in loc["files"] if r["group"] == g and r["side"] == "c"]
        os_ = [r for r in loc["files"] if r["group"] == g and r["side"] == "odin"]
        rows.append({"group": g, "c": cs, "odin": os_,
                     "c_code": sum(r["code"] for r in cs), "odin_code": sum(r["code"] for r in os_),
                     "c_fn": sum(r["functions"] for r in cs), "odin_fn": sum(r["functions"] for r in os_)})
    return rows


def phase_medians(b):
    """median ns per phase, and of the whole rep, over the reps a bench ran."""
    phases = b["phases"]
    med = {ph: statistics.median(rep[i] for rep in b["ns"]) for i, ph in enumerate(phases)}
    med["total"] = statistics.median(sum(rep) for rep in b["ns"])
    return med


def bench_rows(D):
    rows = []
    for fx in D["examples"]:
        row = {"fixture": fx, "per": {}}
        for impl in IMPLS:
            b = D["bench"][impl].get(fx)
            if not b:
                continue
            row.update(nodes=b["nodes"], links=b["links"], duration=b["duration_s"], hstep=b["hstep_s"],
                       quality=b["quality"], reps=b["reps"])
            row["per"][impl] = {"med": phase_medians(b), "maxrss": b["maxrss_kb"],
                                "rss_first": b["rss_closed_kb"][0], "rss_last": b["rss_closed_kb"][-1],
                                "cpu": b["cpu_user_ns"] + b["cpu_sys_ns"]}
        rows.append(row)
    return rows


def norm(name):
    """A function's name without its package and underscores, so matrixcoeffs meets epanet::matrix_coeffs."""
    name = name.split("::")[-1]
    return name.lower().replace("_", "")


def hot_pairs(D, fx):
    """C's hottest functions on this network with their Odin twins, by name; then what only one side has."""
    c = D["callgrind"].get(("c", fx))
    o = D["callgrind"].get(("odin", fx))
    if not c or not o:
        return []
    total_c = c["summary"].get("Ir", 1)
    o_self = {}
    for ir, f, fn in o["self"]:
        o_self.setdefault(norm(fn), (ir, fn))
    nbc = D["callgrind"].get(("odin-nbc", fx))
    nbc_self = {}
    for ir, f, fn in (nbc["self"] if nbc else []):
        nbc_self.setdefault(norm(fn), (ir, fn))
    rows, seen = [], set()
    for ir, f, fn in c["self"]:
        if ir < total_c * 0.005:
            break
        key = norm(fn)
        seen.add(key)
        twin = o_self.get(key)
        rows.append({"c": fn, "c_ir": ir, "odin": twin[1] if twin else None, "odin_ir": twin[0] if twin else None,
                     "nbc_ir": nbc_self[key][0] if key in nbc_self else None})
    total_o = o["summary"].get("Ir", 1)
    for ir, f, fn in o["self"]:
        if ir < total_o * 0.005:
            break
        if norm(fn) not in seen:
            rows.append({"c": None, "c_ir": None, "odin": fn, "odin_ir": ir,
                         "nbc_ir": nbc_self.get(norm(fn), (None,))[0]})
    return rows


def coverage_rows(D):
    cov = D["coverage"]
    if not cov:
        return None, []
    rows = []
    for f in cov["files"]:
        name = os.path.basename(f["filename"])
        if not name.endswith(".c") or "/src/" not in f["filename"].replace(os.sep, "/"):
            continue
        s = f["summary"]
        rows.append({"file": name, "lines": s["lines"], "functions": s["functions"], "branches": s.get("branches")})
    rows.sort(key=lambda r: -r["lines"]["count"])
    return cov["totals"], rows


# ── the terminal ──────────────────────────────────────────────────────────

def table(rows, align=None):
    """rows of strings, columns padded; align is a string of l/r per column."""
    if not rows:
        return ""
    w = [max(len(str(r[i])) for r in rows) for i in range(len(rows[0]))]
    align = align or "l" * len(w)
    out = []
    for r in rows:
        cells = [(str(c).rjust(w[i]) if align[i] == "r" else str(c).ljust(w[i])) for i, c in enumerate(r)]
        out.append("  ".join(cells).rstrip())
    return "\n".join(out)


def cli(D):
    env, H = D["env"], D["harness"]
    lines = []
    tick = "✓" if H.get("fail", "0") == "0" else "✗"
    lines.append("audit — %s, %s, odin %s, %s" % (env.get("date", ""), env.get("uname", ""), env.get("odin", "?"), env.get("cc", "?")))
    lines.append("")
    lines.append("OVERVIEW")
    rows = [["harness", "%s %s✓ %s✗ in %.0f s" % (tick, H.get("pass", "?"), H.get("fail", "?"), int(H.get("ms", 0)) / 1000)]]
    if D["loc"]:
        t = loc_totals(D["loc"])
        c, o = t.get("c", {}), t.get("odin", {})
        rows.append(["code lines", "C %s in %d files · Odin %s in %d files (%s)" % (n(c.get("code", 0)), c.get("files", 0), n(o.get("code", 0)), o.get("files", 0), pct(o.get("code", 0), c.get("code", 1)))])
        rows.append(["functions", "C %s · Odin %s" % (n(c.get("functions", 0)), n(o.get("functions", 0)))])
        rows.append(["decisions / kloc", "C %.0f · Odin %.0f" % (1000.0 * c.get("decisions", 0) / max(1, c.get("code", 1)), 1000.0 * o.get("decisions", 0) / max(1, o.get("code", 1)))])
        api = D["loc"]["api"]
        rows.append(["EN_* toolkit", "%d of %d exported" % (len(api["exported"]), len(api["declared"]))])
    B = D["builds"]
    if "c_speed" in B:
        rows.append(["build, optimised", "C -O2 %.1f s · Odin -o:speed %.1f s" % (int(B["c_speed"]) / 1000, int(B.get("odin_speed", 0)) / 1000)])
        rows.append(["build, unoptimised", "C -O0 %.1f s · Odin -o:none %.1f s" % (int(B.get("c_none", 0)) / 1000, int(B.get("odin_none", 0)) / 1000)])
    sz = B.get("size", {})
    if sz:
        rows.append(["library", "libepanet2.a %s · libepanet-api.a %s" % (kb(int(sz.get("c/libepanet2.a", 0))), kb(int(sz.get("libepanet-api.a", 0))))])
        st = B.get("stripped", {})
        if st:
            rows.append(["driver, stripped", "run-c %s · run-odin %s" % (kb(int(st.get("run-c", 0))), kb(int(st.get("run-odin", 0))))])
    tot, _ = coverage_rows(D)
    if tot:
        rows.append(["EPANET lines run by the fixtures", "%s of %s (%s)" % (n(tot["lines"]["covered"]), n(tot["lines"]["count"]), pct(tot["lines"]["covered"], tot["lines"]["count"]))])
    lines.append(table(rows))
    lines.append("")
    lines.append("EXAMPLES  (median of %s reps; whole run = open + hydraulics + quality + report + close)" % env.get("reps", "?"))
    rows = [["network", "nodes", "links", "identical", "C", "Odin", "Odin −bc", "Odin/C", "peak RSS C", "Odin"]]
    for r in bench_rows(D):
        eq = D["equiv"].get(r["fixture"], {})
        same = all(v2 != "bad" for v in eq.values() for v2 in v.values()) if eq else None
        per = r["per"]
        c = per.get("c", {}).get("med", {}).get("total")
        o = per.get("odin", {}).get("med", {}).get("total")
        nb = per.get("odin-nbc", {}).get("med", {}).get("total")
        rows.append([r["fixture"], n(r.get("nodes", 0)), n(r.get("links", 0)),
                     ("✓" if all(v2 == "ok" for v in eq.values() for v2 in v.values()) else "≈") if same else ("✗" if same is False else "·"),
                     ms(c) if c else "—", ms(o) if o else "—", ms(nb) if nb else "—", ratio(o, c) if c and o else "—",
                     kb(per.get("c", {}).get("maxrss", 0) * 1024) if "c" in per else "—",
                     kb(per.get("odin", {}).get("maxrss", 0) * 1024) if "odin" in per else "—"])
    lines.append(table(rows, "lrrlrrrrrr"))
    lines.append("")
    if D["callgrind"]:
        lines.append("ANALYTICS  (callgrind: instructions, data-cache misses, branch mispredictions; massif: peak heap)")
        rows = [["network", "build", "Ir", "Ir/C", "D1 miss", "LL miss", "mispredict", "peak heap"]]
        for fx in D["examples"]:
            base = D["callgrind"].get(("c", fx), {}).get("summary", {}).get("Ir")
            for impl in IMPLS:
                cg = D["callgrind"].get((impl, fx))
                if not cg:
                    continue
                s = cg["summary"]
                rows.append([fx if impl == "c" else "", SHORT[impl], n(s.get("Ir", 0)), ratio(s.get("Ir", 0), base) if base else "—",
                             pct(s.get("D1mr", 0) + s.get("D1mw", 0), s.get("Dr", 0) + s.get("Dw", 0)) if "D1mr" in s else "—",
                             pct(s.get("DLmr", 0) + s.get("DLmw", 0), s.get("Dr", 0) + s.get("Dw", 0)) if "DLmr" in s else "—",
                             pct(s.get("Bcm", 0) + s.get("Bim", 0), s.get("Bc", 0) + s.get("Bi", 0)) if "Bc" in s else "—",
                             kb(D["massif"].get((impl, fx), 0)) if (impl, fx) in D["massif"] else "—"])
        lines.append(table(rows, "llrrrrrr"))
        big = max(D["examples"], key=lambda fx: D["callgrind"].get(("c", fx), {}).get("summary", {}).get("Ir", 0))
        pairs = hot_pairs(D, big)
        if pairs:
            lines.append("")
            lines.append("hot paths on %s, self instructions (≥0.5%% of a run)" % big)
            rows = [["C", "Ir", "Odin", "Ir", "Odin −bc", "Odin/C"]]
            for p in pairs[:14]:
                rows.append([p["c"] or "—", n(p["c_ir"]) if p["c_ir"] else "—", p["odin"] or "—",
                             n(p["odin_ir"]) if p["odin_ir"] else "—", n(p["nbc_ir"]) if p["nbc_ir"] else "—",
                             ratio(p["odin_ir"], p["c_ir"]) if p["c_ir"] and p["odin_ir"] else "—"])
            lines.append(table(rows, "lrlrrr"))
        if D["memcheck"]:
            lines.append("")
            rows = [["memcheck", "errors", "suppressed", "definitely lost", "possibly lost", "allocs"]]
            for fx in D["examples"]:
                for impl in IMPLS:
                    m = D["memcheck"].get((impl, fx))
                    if m:
                        rows.append(["%s %s" % (fx, SHORT[impl]), n(m["errors"] or 0), n(m["suppressed"]), kb(m["definitely"]) if m["definitely"] else "0",
                                     kb(m["possibly"]) if m["possibly"] else "0", n(m["allocs"])])
            lines.append(table(rows, "lrrrrr"))
    else:
        lines.append("ANALYTICS  skipped (%s)" % ("quick" if env.get("quick") == "1" else "valgrind not installed"))
    lines.append("")
    lines.append("the page: %s" % os.path.join(D["dir"], "index.html"))
    return "\n".join(lines)


# ── the page ──────────────────────────────────────────────────────────────

CSS = """
@font-face { font-family: Iosevka; font-weight: 400; font-style: normal; font-display: swap;
  src: local("Iosevka"), local("Iosevka Term"), url("https://cdn.jsdelivr.net/npm/@fontsource/iosevka@5.3.0/files/iosevka-latin-400-normal.woff2") format("woff2"); }
@font-face { font-family: Iosevka; font-weight: 700; font-style: normal; font-display: swap;
  src: local("Iosevka Bold"), local("Iosevka Term Bold"), url("https://cdn.jsdelivr.net/npm/@fontsource/iosevka@5.3.0/files/iosevka-latin-700-normal.woff2") format("woff2"); }
@font-face { font-family: Iosevka; font-weight: 400; font-style: italic; font-display: swap;
  src: local("Iosevka Italic"), local("Iosevka Term Italic"), url("https://cdn.jsdelivr.net/npm/@fontsource/iosevka@5.3.0/files/iosevka-latin-400-italic.woff2") format("woff2"); }
:root {
  color-scheme: light;
  --bg: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --rule: #dcdbd6; --rule-strong: #0b0b0b;
  --wash: #f2f1ed;
  --s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a;
  --ok: #008300; --bad: #e34948;
  --fs: 15px; --lh: 1.6;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  color-scheme: dark;
  --bg: #1a1a19; --ink: #f0efec; --ink-2: #c3c2b7; --rule: #3a3a37; --rule-strong: #f0efec; --wash: #232321;
  --s1: #3987e5; --s2: #d95926; --s3: #199e70; --ok: #3fbf3f; --bad: #e66767;
} }
:root[data-theme="dark"] {
  color-scheme: dark;
  --bg: #1a1a19; --ink: #f0efec; --ink-2: #c3c2b7; --rule: #3a3a37; --rule-strong: #f0efec; --wash: #232321;
  --s1: #3987e5; --s2: #d95926; --s3: #199e70; --ok: #3fbf3f; --bad: #e66767;
}
* { box-sizing: border-box; }
html { font-family: Iosevka, "Iosevka Term", ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  font-size: var(--fs); line-height: var(--lh); background: var(--bg); color: var(--ink);
  font-variant-numeric: tabular-nums; -webkit-font-smoothing: antialiased; }
body { margin: 0; padding: 3lh 16px 6lh; }
main { max-width: 112ch; margin: 0 auto; }
h1, h2, h3 { font-weight: 700; line-height: 1.25; margin: 0; letter-spacing: -0.01em; }
h1 { font-size: 2rem; margin-bottom: 0.5lh; }
h2 { font-size: 1.35rem; margin: 2.5lh 0 1lh; padding-top: 1lh; border-top: 1px solid var(--rule-strong); }
h3 { font-size: 1rem; margin: 1.75lh 0 0.5lh; }
p { max-width: 76ch; margin: 0 0 1lh; }
p.lede { font-size: 1.1rem; color: var(--ink-2); max-width: 80ch; }
a { color: inherit; text-decoration: underline; text-underline-offset: 0.18em; text-decoration-color: var(--rule); }
a:hover { text-decoration-color: currentColor; }
.eyebrow { font-size: 0.72rem; letter-spacing: 0.1em; text-transform: uppercase; color: var(--ink-2); }
nav.toc { display: flex; flex-wrap: wrap; gap: 0 3ch; margin: 1lh 0 2lh; color: var(--ink-2); font-size: 0.9rem; }
nav.toc a { text-decoration: none; } nav.toc a:hover { text-decoration: underline; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(22ch, 1fr)); gap: 1lh 3ch; margin: 1lh 0 1.5lh; }
.stat .value { font-size: 1.6rem; font-weight: 700; line-height: 1.2; }
.stat .value small { font-size: 0.85rem; font-weight: 400; color: var(--ink-2); }
.stat .label { font-size: 0.8rem; color: var(--ink-2); }
table { border-collapse: collapse; width: 100%; margin: 0.5lh 0 1lh; font-size: 0.92rem; }
th, td { text-align: left; padding: 0.25lh 1.5ch 0.25lh 0; vertical-align: baseline; border-bottom: 1px solid var(--rule); }
th { font-size: 0.72rem; letter-spacing: 0.08em; text-transform: uppercase; font-weight: 400; color: var(--ink-2);
  border-bottom: 1px solid var(--rule-strong); white-space: nowrap; }
td.num, th.num { text-align: right; white-space: nowrap; }
td.name { white-space: nowrap; }
tr.total td { border-top: 1px solid var(--rule-strong); border-bottom: 0; font-weight: 700; }
tr.sub td { color: var(--ink-2); font-size: 0.85rem; padding-left: 2ch; }
tr:last-child td { border-bottom: 0; }
.ok { color: var(--ok); } .bad { color: var(--bad); } .muted { color: var(--ink-2); }
.bars { display: grid; gap: 2px; min-width: 18ch; }
.bar { height: 6px; border-radius: 0 4px 4px 0; background: var(--s1); width: calc(var(--w) * 1%); min-width: 2px; }
.bar.s2 { background: var(--s2); } .bar.s3 { background: var(--s3); }
.legend { display: flex; flex-wrap: wrap; gap: 0.25lh 3ch; font-size: 0.85rem; color: var(--ink-2); margin: 0 0 0.5lh; }
.legend span::before { content: ""; display: inline-block; width: 1.2ch; height: 1.2ch; border-radius: 2px; margin-right: 0.8ch; background: var(--s1); vertical-align: -0.1em; }
.legend span.s2::before { background: var(--s2); } .legend span.s3::before { background: var(--s3); }
details { margin: 0.5lh 0 1lh; } summary { cursor: pointer; color: var(--ink-2); }
pre { font: inherit; font-size: 0.85rem; background: var(--wash); padding: 0.5lh 2ch; overflow-x: auto; margin: 0 0 1lh; }
code { font: inherit; background: var(--wash); padding: 0 0.4ch; }
.note { color: var(--ink-2); font-size: 0.9rem; }
footer { margin-top: 0; color: var(--ink-2); font-size: 0.85rem; }
footer dl { display: grid; grid-template-columns: max-content 1fr; gap: 0 3ch; margin: 0.5lh 0; }
footer dt { color: var(--ink-2); } footer dd { margin: 0; }
.two { display: grid; grid-template-columns: 1fr 1fr; gap: 0 4ch; } @media (max-width: 760px) { .two { grid-template-columns: 1fr; } }
@media print { body { padding: 0; } tr { break-inside: avoid; } h2 { break-before: page; } details { display: none; } }
"""


def esc(s):
    return html.escape(str(s))


def bars(values):
    """Three thin bars, the longest the row's max, one per build; a missing value is no bar."""
    vals = [v for v in values if v]
    if not vals:
        return ""
    mx = max(vals)
    out = []
    for i, v in enumerate(values):
        if v:
            out.append('<div class="bar s%d" style="--w:%.1f" title="%s: %s"></div>' % (i + 1, 100.0 * v / mx, esc(LABEL[IMPLS[i]]), n(v)))
    return '<div class="bars">%s</div>' % "".join(out)


def legend():
    return '<div class="legend"><span>%s</span><span class="s2">%s</span><span class="s3">%s</span></div>' % tuple(LABEL[i] for i in IMPLS)


def td(x, cls=""):
    return "<td%s>%s</td>" % (' class="%s"' % cls if cls else "", x)


def tick(ok):
    return '<span class="ok">✓</span>' if ok else '<span class="bad">✗</span>'


def page(D):
    env, H, B = D["env"], D["harness"], D["builds"]
    out = []
    w = out.append
    skipped = []
    if not D["callgrind"]:
        skipped.append("valgrind (%s)" % ("quick run" if env.get("quick") == "1" else "not installed"))
    if not D["coverage"]:
        skipped.append("coverage (%s)" % ("quick run" if env.get("quick") == "1" else "llvm-cov not installed"))

    w('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    w("<title>epanet-odin audit</title><style>%s</style></head><body><main>" % CSS)
    w('<div class="eyebrow">epanet-odin · audit · %s</div>' % esc(env.get("date", "")))
    w("<h1>The port, measured against EPANET</h1>")
    w('<p class="lede">The same driver, the same networks, three builds of the engine: OWA EPANET’s C at <code>-O2</code>, '
      'the Odin toolkit at <code>-o:speed</code>, and the Odin toolkit with its bounds checks off. '
      'Every figure here was produced by <code>audit/audit.sh</code> on this checkout; nothing is typed in.</p>')
    w('<nav class="toc"><a href="#overview">1 Overview</a><a href="#examples">2 Examples</a><a href="#analytics">3 Analytics</a><a href="#how">How it was measured</a></nav>')

    # ── 1 overview ──
    w('<h2 id="overview">1 · Overview</h2>')
    ok = H.get("fail", "0") == "0"
    tot, cov_rows = coverage_rows(D)
    api = D["loc"]["api"] if D["loc"] else None
    t = loc_totals(D["loc"]) if D["loc"] else {}
    c, o = t.get("c", {}), t.get("odin", {})
    w('<div class="stats">')
    w('<div class="stat"><div class="value">%s %s<small>✓</small>%s</div><div class="label">harness checks, %s fixtures × parse, results, files, shadow and pure, in %.0f s</div></div>'
      % (tick(ok), esc(H.get("pass", "?")), (' <span class="bad">%s✗</span>' % esc(H["fail"])) if not ok else "",
         sum(D["loc"]["harness"]["fixtures"].values()) if D["loc"] else "?", int(H.get("ms", 0)) / 1000))
    if t:
        w('<div class="stat"><div class="value">%s<small> of %s lines</small></div><div class="label">code lines, Odin against C (%s); comments and blanks not counted</div></div>'
          % (n(o.get("code", 0)), n(c.get("code", 0)), pct(o.get("code", 0), c.get("code", 1))))
    if api:
        w('<div class="stat"><div class="value">%d<small> of %d</small></div><div class="label">EN_* toolkit functions exported with the C ABI</div></div>'
          % (len(api["exported"]), len(api["declared"])))
    if "c_speed" in B:
        w('<div class="stat"><div class="value">%.1f s<small> · C %.1f s</small></div><div class="label">optimised build of the engine, Odin -o:speed against clang -O2 over every EPANET source</div></div>'
          % (int(B.get("odin_speed", 0)) / 1000, int(B["c_speed"]) / 1000))
    if tot:
        w('<div class="stat"><div class="value">%s</div><div class="label">of EPANET’s C lines run by the fixtures (%s of %s; every network, both driver modes)</div></div>'
          % (pct(tot["lines"]["covered"], tot["lines"]["count"]), n(tot["lines"]["covered"]), n(tot["lines"]["count"])))
    w("</div>")

    if D["loc"]:
        w("<h3>Source, side by side</h3>")
        w('<p class="note">Each row is one part of EPANET and the Odin files that port it. Decisions are <code>if</code>, <code>for</code>, '
          '<code>while</code>, <code>case</code>, <code>&amp;&amp;</code>, <code>||</code> on code lines; depth is the deepest brace nesting; '
          'longest is the longest function. The toolkit row is uneven on purpose: <code>epanet.c</code> holds every EN_* function and the port exports %s of them so far.</p>'
          % (len(api["exported"])))
        w('<table><tr><th>part</th><th>C files</th><th class="num">code</th><th class="num">fn</th><th class="num">dec/kloc</th><th class="num">depth</th><th class="num">longest</th>'
          '<th>Odin files</th><th class="num">code</th><th class="num">fn</th><th class="num">dec/kloc</th><th class="num">depth</th><th class="num">longest</th><th class="num">Odin/C</th></tr>')
        for g in loc_groups(D["loc"]):
            def side(rows):
                code = sum(r["code"] for r in rows)
                return (code, sum(r["functions"] for r in rows),
                        "%.0f" % (1000.0 * sum(r["decisions"] for r in rows) / code) if code else "—",
                        max((r["max_depth"] for r in rows), default=0), max((r["longest"] for r in rows), default=0))
            cc, oo = side(g["c"]), side(g["odin"])
            w("<tr>%s%s%s%s%s%s%s%s%s%s%s%s%s%s</tr>" % (
                td(esc(g["group"]), "name"), td(", ".join(esc(r["file"]) for r in g["c"]) or "—"),
                td(n(cc[0]) if cc[0] else "—", "num"), td(n(cc[1]) if cc[0] else "—", "num"), td(cc[2], "num"), td(cc[3] or "—", "num"), td(cc[4] or "—", "num"),
                td(", ".join(esc(r["file"].split("/")[-1]) for r in g["odin"]) or "—"),
                td(n(oo[0]) if oo[0] else "—", "num"), td(n(oo[1]) if oo[0] else "—", "num"), td(oo[2], "num"), td(oo[3] or "—", "num"), td(oo[4] or "—", "num"),
                td(pct(oo[0], cc[0]) if cc[0] and oo[0] else "—", "num")))
        w('<tr class="total">%s%s%s%s%s%s%s%s%s%s%s%s%s%s</tr>' % (
            td("all"), td("%d files" % c.get("files", 0)), td(n(c.get("code", 0)), "num"), td(n(c.get("functions", 0)), "num"),
            td("%.0f" % (1000.0 * c.get("decisions", 0) / max(1, c.get("code", 1))), "num"), td(c.get("max_depth", 0), "num"), td(c.get("longest", 0), "num"),
            td("%d files" % o.get("files", 0)), td(n(o.get("code", 0)), "num"), td(n(o.get("functions", 0)), "num"),
            td("%.0f" % (1000.0 * o.get("decisions", 0) / max(1, o.get("code", 1))), "num"), td(o.get("max_depth", 0), "num"), td(o.get("longest", 0), "num"),
            td(pct(o.get("code", 0), c.get("code", 1)), "num")))
        w("</table>")
        notes = D["loc"]["notes"]
        w("<details><summary>What is not ported, and why; the EN_* functions still to come</summary>")
        w("<table><tr><th>file</th><th>note</th></tr>")
        for f in sorted(r["file"] for r in D["loc"]["files"] if r["group"] == "not ported"):
            w("<tr>%s%s</tr>" % (td(esc(f), "name"), td(esc(notes.get(f, "")))))
        w("</table>")
        w('<p class="note">Not yet exported (%d): %s</p>' % (len(api["missing"]), ", ".join("<code>%s</code>" % esc(x) for x in api["missing"])))
        w("</details>")
        hf = D["loc"]["harness"]
        w('<p class="note">The harness itself: %s lines over %s, and %s fixtures (%s).</p>' % (
            n(sum(r["code"] for r in hf["files"])), ", ".join("<code>%s</code>" % esc(r["file"].split("/")[-1]) for r in hf["files"]),
            sum(hf["fixtures"].values()), "; ".join("%s %d" % (esc(k), v) for k, v in hf["fixtures"].items())))

    if "c_speed" in B:
        w("<h3>Builds</h3>")
        w(legend())
        sz, st = B.get("size", {}), B.get("stripped", {})
        w('<table><tr><th>what</th><th class="num">C</th><th class="num">Odin</th><th class="num">Odin −bc</th><th></th></tr>')
        def row(label, vals, fmt):
            w("<tr>%s%s%s%s%s</tr>" % (td(esc(label), "name"), *(td(fmt(v) if v else "—", "num") for v in vals), td(bars(vals))))
        row("build, optimised (clang -O2 · odin -o:speed)", [int(B["c_speed"]), int(B.get("odin_speed", 0)), int(B.get("odin_nbc", 0))], lambda v: "%.1f s" % (v / 1000))
        row("build, unoptimised (clang -O0 · odin -o:none)", [int(B.get("c_none", 0)), int(B.get("odin_none", 0)), None], lambda v: "%.1f s" % (v / 1000))
        row("static library", [int(sz.get("c/libepanet2.a", 0)), int(sz.get("libepanet-api.a", 0)), int(sz.get("libepanet-api-nbc.a", 0))], kb)
        row("driver, linked and stripped (run.c)", [int(st.get("run-c", 0)), int(st.get("run-odin", 0)), int(st.get("run-odin-nbc", 0))], kb)
        row("dumpnet, stripped", [int(st.get("dumpnet-c", 0)), int(st.get("dumpnet-odin", 0)), None], kb)
        w("</table>")
        w('<p class="note">The Odin library carries its runtime (the allocator, formatting, the OS layer), which is most of the size difference; '
          'the C library is the engine alone and leans on libc. The unoptimised Odin library is %s.</p>' % kb(int(sz.get("libepanet-api-none.a", 0))))

    if tot:
        w("<h3>What the fixtures exercise in EPANET</h3>")
        w('<p class="note">EPANET’s C compiled with llvm-cov instrumentation and run on every fixture in both driver modes, so this is how much of the '
          'official engine the harness actually compares. The port mirrors the C function for function, so it is the port’s coverage too. '
          'Odin has no line-coverage tooling of its own.</p>')
        w('<table><tr><th>file</th><th class="num">lines</th><th class="num">run</th><th class="num">%</th><th class="num">functions</th><th class="num">run</th><th class="num">branches run</th><th></th></tr>')
        for r in cov_rows:
            L, F, Br = r["lines"], r["functions"], r["branches"]
            w("<tr>%s%s%s%s%s%s%s%s</tr>" % (td(esc(r["file"]), "name"), td(n(L["count"]), "num"), td(n(L["covered"]), "num"), td(pct(L["covered"], L["count"]), "num"),
                                            td(n(F["count"]), "num"), td(n(F["covered"]), "num"), td(pct(Br["covered"], Br["count"]) if Br and Br["count"] else "—", "num"),
                                            td('<div class="bars"><div class="bar" style="--w:%.1f"></div></div>' % (100.0 * L["covered"] / L["count"] if L["count"] else 0))))
        L, F = tot["lines"], tot["functions"]
        w('<tr class="total">%s%s%s%s%s%s%s%s</tr>' % (td("all"), td(n(L["count"]), "num"), td(n(L["covered"]), "num"), td(pct(L["covered"], L["count"]), "num"),
                                                       td(n(F["count"]), "num"), td(n(F["covered"]), "num"), td(pct(tot["branches"]["covered"], tot["branches"]["count"]), "num"), td("")))
        w("</table>")

    # ── 2 examples ──
    w('<h2 id="examples">2 · Examples</h2>')
    w('<p>EPANET’s own example networks and a generated 40×40 grid, each through the whole pipeline — open, hydraulics, quality, report, close — '
      'on all three builds. ✓ means the driver’s print of every node and link value at every step (<code>%%.17g</code>), the report, '
      'the binary output file and the hydraulics file are byte for byte the same as EPANET’s; ≈ means every number is within 1e-9 of EPANET’s '
      '(a last bit, where a constant product is now computed plainly). Times are the median of %s reps.</p>' % esc(env.get("reps", "?")))
    w(legend())
    w('<table><tr><th>network</th><th class="num">nodes</th><th class="num">links</th><th>run</th><th>quality</th><th>identical</th>'
      '<th class="num">C</th><th class="num">Odin</th><th class="num">Odin −bc</th><th class="num">Odin/C</th><th></th></tr>')
    brows = bench_rows(D)
    for r in brows:
        eq = D["equiv"].get(r["fixture"], {})
        same = all(v2 != "bad" for v in eq.values() for v2 in v.values()) if eq else None
        exact = same and all(v2 == "ok" for v in eq.values() for v2 in v.values())
        per = r["per"]
        vals = [per.get(i, {}).get("med", {}).get("total") for i in IMPLS]
        w("<tr>%s%s%s%s%s%s%s%s%s%s%s</tr>" % (
            td(esc(r["fixture"]), "name"), td(n(r.get("nodes", 0)), "num"), td(n(r.get("links", 0)), "num"),
            td("%s h, %s min steps" % (r.get("duration", 0) // 3600, r.get("hstep", 0) // 60) if r.get("duration") else "steady state"),
            td(esc(r.get("quality", "?"))), td((tick(True) if exact else '<span class="ok">≈</span>') if same else (tick(False) if same is False else "·")),
            *(td(ms(v) if v else "—", "num") for v in vals), td(ratio(vals[1], vals[0]) if vals[0] and vals[1] else "—", "num"), td(bars(vals))))
    w("</table>")
    for r in brows:
        if not r["per"]:
            continue
        w("<h3>%s</h3>" % esc(r["fixture"]))
        eq = D["equiv"].get(r["fixture"], {})
        w('<p class="note">against EPANET (✓ identical, ≈ within 1e-9): %s</p>' % " · ".join(
            "%s %s" % (esc(SHORT[impl]), " ".join("%s %s" % (tick(True) if v == "ok" else ('<span class="ok">≈</span>' if v == "near" else tick(False)), esc({"txt": "results", "rpt": "report", "out": ".out", "hyd": ".hyd"}[k])) for k, v in eq[impl].items()))
            for impl in ("odin", "odin-nbc") if impl in eq) if eq else "not checked")
        w('<div class="two"><div>')
        w('<table><tr><th>phase</th><th class="num">C</th><th class="num">Odin</th><th class="num">Odin −bc</th><th></th></tr>')
        for ph in ["open", "hydraulics", "quality", "report", "close", "total"]:
            vals = [r["per"].get(i, {}).get("med", {}).get(ph) for i in IMPLS]
            w('<tr%s>%s%s%s</tr>' % (' class="total"' if ph == "total" else "", td(esc(ph), "name"), "".join(td(ms(v) if v is not None else "—", "num") for v in vals), td(bars(vals))))
        w("</table></div><div>")
        w('<table><tr><th>memory</th><th class="num">C</th><th class="num">Odin</th><th class="num">Odin −bc</th><th></th></tr>')
        vals = [r["per"].get(i, {}).get("maxrss") for i in IMPLS]
        w("<tr>%s%s%s</tr>" % (td("peak resident set", "name"), "".join(td(kb(v * 1024) if v else "—", "num") for v in vals), td(bars(vals))))
        growth = [(r["per"][i]["rss_last"] - r["per"][i]["rss_first"]) if i in r["per"] else None for i in IMPLS]
        w("<tr>%s%s%s</tr>" % (td("resident set growth over %s reps" % r.get("reps", "?"), "name"), "".join(td(("%s KB" % n(v)) if v is not None else "—", "num") for v in growth), td("")))
        vals = [D["massif"].get((i, r["fixture"])) for i in IMPLS]
        if any(vals):
            w("<tr>%s%s%s</tr>" % (td("peak heap (massif)", "name"), "".join(td(kb(v) if v else "—", "num") for v in vals), td(bars(vals))))
        w("</table>")
        sample = os.path.join(D["dir"], "eq.%s.c.txt" % r["fixture"])
        if os.path.exists(sample):
            lines_ = open(sample, encoding="utf-8", errors="replace").read().splitlines()
            w('<p class="note">%s lines of results compared; the first node line and the last line, as both builds print them:</p>' % n(len(lines_)))
            w("<pre>%s</pre>" % esc("\n".join(lines_[2:3] + lines_[-1:])))
        w("</div></div>")

    # ── 3 analytics ──
    w('<h2 id="analytics">3 · Analytics</h2>')
    if not D["callgrind"]:
        w('<p>Skipped: %s. Run <code>audit/audit.sh</code> without <code>quick</code> on a machine with valgrind for instruction counts, cache behaviour, heap profiles and the error check.</p>' % esc(skipped[0]))
    else:
        w('<p>Instruction counts and simulated caches from callgrind, the heap from massif, errors and leaks from memcheck — one rep of the bench driver per build, '
          'so the counts are the engine’s, deterministic, and free of the timer’s noise. Odin’s bounds checks are the difference between the second and third build.</p>')
        w(legend())
        w('<table><tr><th>network</th><th>build</th><th class="num">instructions</th><th class="num">vs C</th><th class="num">data reads+writes</th><th class="num">D1 miss</th><th class="num">LL miss</th>'
          '<th class="num">branches</th><th class="num">mispredicted</th><th></th></tr>')
        for fx in D["examples"]:
            base = D["callgrind"].get(("c", fx), {}).get("summary", {}).get("Ir")
            irs = [D["callgrind"].get((i, fx), {}).get("summary", {}).get("Ir") for i in IMPLS]
            for k, impl in enumerate(IMPLS):
                cg = D["callgrind"].get((impl, fx))
                if not cg:
                    continue
                s = cg["summary"]
                data = s.get("Dr", 0) + s.get("Dw", 0)
                br = s.get("Bc", 0) + s.get("Bi", 0)
                w("<tr>%s%s%s%s%s%s%s%s%s%s</tr>" % (
                    td(esc(fx) if k == 0 else "", "name"), td(esc(SHORT[impl]), "name"), td(n(s.get("Ir", 0)), "num"), td(ratio(s.get("Ir", 0), base) if base else "—", "num"),
                    td(n(data), "num"), td(pct(s.get("D1mr", 0) + s.get("D1mw", 0), data) if "D1mr" in s else "—", "num"),
                    td(pct(s.get("DLmr", 0) + s.get("DLmw", 0), data) if "DLmr" in s else "—", "num"),
                    td(n(br) if br else "—", "num"), td(pct(s.get("Bcm", 0) + s.get("Bim", 0), br) if br else "—", "num"),
                    td(bars(irs) if k == 0 else "")))
        w("</table>")
        for fx in D["examples"]:
            pairs = hot_pairs(D, fx)
            if not pairs:
                continue
            w("<h3>Hot paths on %s</h3>" % esc(fx))
            w('<p class="note">Self instructions per function — the function’s own work, callees not included — for every C function at or above 0.5% of the run, '
              'with the Odin function of the same name beside it, then what only the Odin side spends 0.5% on. A C function with no twin was either inlined into its Odin caller '
              '(<code>genmmd</code> into <code>create_sparse</code>, <code>reactpipes</code> into <code>transport</code>) or has no counterpart (the allocator and the hash table: the port keeps an arena).</p>')
            w('<table><tr><th>C function</th><th class="num">Ir</th><th>Odin function</th><th class="num">Ir</th><th class="num">Odin −bc</th><th class="num">Odin/C</th><th></th></tr>')
            for p in pairs:
                w("<tr>%s%s%s%s%s%s%s</tr>" % (
                    td(esc(p["c"]) if p["c"] else "—", "name"), td(n(p["c_ir"]) if p["c_ir"] else "—", "num"),
                    td(esc(p["odin"]) if p["odin"] else "—", "name"), td(n(p["odin_ir"]) if p["odin_ir"] else "—", "num"), td(n(p["nbc_ir"]) if p["nbc_ir"] else "—", "num"),
                    td(ratio(p["odin_ir"], p["c_ir"]) if p["c_ir"] and p["odin_ir"] else "—", "num"), td(bars([p["c_ir"], p["odin_ir"], p["nbc_ir"]]))))
            w("</table>")
            cg = D["callgrind"]
            w("<details><summary>The twenty costliest functions on each build, inclusive of callees</summary><div class=\"two\">")
            for impl in IMPLS:
                if (impl, fx) not in cg:
                    continue
                w('<div><div class="eyebrow">%s</div><table><tr><th>function</th><th class="num">Ir incl.</th><th class="num">%%</th></tr>' % esc(LABEL[impl]))
                total = cg[(impl, fx)]["summary"].get("Ir", 1)
                for ir, f, fn in cg[(impl, fx)]["incl"][:20]:
                    w("<tr>%s%s%s</tr>" % (td(esc(fn), "name"), td(n(ir), "num"), td(pct(ir, total), "num")))
                w("</table></div>")
            w("</div></details>")
        if D["memcheck"]:
            w("<h3>Memory errors and leaks</h3>")
            w('<p class="note">memcheck over one rep per build. What it says about Odin’s own heap allocator (a size header it reads that memcheck counts as uninitialised) is suppressed by '
              '<code>audit/odin-runtime.supp</code> and counted here as <em>suppressed</em>; everything else is shown with where it comes from. '
              '“Possibly lost” on the Odin builds is the runtime’s temporary-allocator arenas, kept for the thread’s life and reused — the resident-set growth above is the test of whether anything really leaks.</p>')
            w('<table><tr><th>network</th><th>build</th><th class="num">errors</th><th class="num">suppressed</th><th class="num">definitely lost</th><th class="num">possibly lost</th><th class="num">allocations</th><th class="num">freed</th><th class="num">bytes allocated</th><th>origins</th></tr>')
            for fx in D["examples"]:
                for k, impl in enumerate(IMPLS):
                    m = D["memcheck"].get((impl, fx))
                    if not m:
                        continue
                    w("<tr>%s%s%s%s%s%s%s%s%s%s</tr>" % (
                        td(esc(fx) if k == 0 else "", "name"), td(esc(SHORT[impl]), "name"),
                        td(('<span class="ok">0</span>' if m["errors"] == 0 else '<span class="bad">%s</span>' % n(m["errors"])) if m["errors"] is not None else "—", "num"),
                        td(n(m["suppressed"]), "num"), td(kb(m["definitely"]) if m["definitely"] else "0", "num"), td(kb(m["possibly"]) if m["possibly"] else "0", "num"),
                        td(n(m["allocs"]), "num"), td(n(m["frees"]), "num"), td(kb(m["bytes"]), "num"),
                        td(", ".join("<code>%s</code>" % esc(x) for x in m["origins"]) or "—")))
            w("</table>")

    # ── how ──
    w('<h2 id="how">How it was measured</h2>')
    w("<footer><dl>")
    for key, label in (("date", "when"), ("uname", "machine"), ("cpu", "cpu"), ("odin", "odin"), ("cc", "C compiler"), ("valgrind", "valgrind"),
                       ("llvm-cov", "llvm-cov"), ("epanet", "EPANET commit"), ("commit", "epanet-odin commit"), ("reps", "bench reps"), ("examples", "networks")):
        if env.get(key):
            w("<dt>%s</dt><dd>%s</dd>" % (esc(label), esc(env[key])))
    w("</dl>")
    if skipped:
        w("<p>Skipped on this run: %s.</p>" % esc("; ".join(skipped)))
    w("<p>Reproduce: <code>audit/audit.sh</code> at the root of <a href=\"https://github.com/JordanShurmer/epanet-odin\">epanet-odin</a>; "
      "<code>audit/audit.sh quick</code> leaves out valgrind and coverage. The C is compiled with <code>clang -O2</code>, no <code>-fPIC</code>, no interposition — "
      "the harness’s plug-in build is not what is timed here. Both are linked into the same <code>audit/bench.c</code>; wall time is <code>CLOCK_MONOTONIC</code> around each phase, "
      "the resident set is <code>/proc/self/statm</code>, instruction counts are callgrind with <code>--cache-sim=yes --branch-sim=yes</code>, the heap is massif, "
      "errors are memcheck with <code>--leak-check=full</code>, and coverage is <code>llvm-cov</code> over the harness driver on every fixture.</p>")
    w("</footer></main></body></html>")
    return "\n".join(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    d = args[0] if args else "build/audit"
    if not os.path.isdir(d):
        sys.stderr.write("render.py: no such directory: %s (run audit/audit.sh first)\n" % d)
        return 1
    D = load(d)
    with open(os.path.join(d, "index.html"), "w", encoding="utf-8") as f:
        f.write(page(D))
    if "--quiet" not in sys.argv:
        print(cli(D))
    return 0


if __name__ == "__main__":
    sys.exit(main())
