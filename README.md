# epanet-odin — EPANET, rewritten in Odin, one solver at a time

[OWA EPANET](https://github.com/OpenWaterAnalytics/EPANET), the water
distribution network engine, rewritten in Odin, data-oriented, from the core
solvers outward. Every piece is proved against the C original before the
next one starts, by plugging it into the real EPANET and running both. The
tag `Identical` is the last state that matched EPANET byte for byte; since
then the port departs from it where EPANET is wrong or merely odd (see
*Where it departs from EPANET*), and the harness proves equivalence within
1e-9 instead.

```sh
harness/test.sh            # build c / odin / shadow, run every fixture
harness/test.sh -v         # name every check
```

The first run clones EPANET at the pinned commit into `epanet-c/` (or point
`EPANET=` at a checkout). Needs an Odin compiler (`ODIN=` if not on PATH),
clang, binutils.

## Layout

```
epanet/         the Odin package `epanet` — the rewrite
  smatrix.odin    numeric Cholesky: linsolve
  sparse.odin     symbolic factorization: createsparse
  genmmd.odin     minimum-degree ordering
  network.odin    the model and solver state, one array per field
  hydcoeffs.odin  link coefficients and matrix assembly
  hydstatus.odin  status checks between trials
  hydsolve.odin   the Newton loop
  leakage.odin    pipe leaks as node demand, per trial
  hydraul.odin    the engine around it: demands, controls, time step, energy,
                  the flow balance, and the run itself: inithyd, runhyd, nexthyd
  rules.odin      the rule-based controls at run time
  quality.odin    water quality: segments, transport, reactions, tank mixing
  export.odin     the C face: one exported proc per swapped EPANET symbol
  project.odin    a project the package owns: the network, the settings, the
                  names, the unit factors, all from one arena
  parse.odin      the .inp reader, pass one (counts, names) and pass two
  parse2.odin     the rest of the sections, and the rule statements
  units.odin      after reading: tank re-indexing, defaults that depend on
                  other data, the unit factors, conversion to internal units
  validate.odin   tank levels, pump curve fitting, patterns and curves
  dump.odin       the project as text, every field, for the comparison
  report.odin     the report file: logo, summary, status lines, warnings,
                  energy and results tables, errors
  output.odin     the binary output file and the hydraulics file
  errors.odin     EPANET's error messages by code; Error and Warning as values
  text.odin       what every build says: the names of things, a report line,
                  the clock as h:mm:ss, the run's warning code (writehydwarn)
  open.odin       opening and closing the solvers on an owned project
  files.odin      what opens a file: the readers' file entry, load, write_inp,
                  the quality run read back from the hydraulics file (native only)
  cmath.odin      pow, log and sqrt from the C library; cmath_wasm.odin: core:math
  numbers.odin    a number read by strtod; numbers_wasm.odin: by strconv
  arena.odin      a project's growing arena, and File; arena_wasm.odin: a block
                  arena over the wasm heap
  prof.odin       the engine's stopwatch, on with -define:PROF=true: the phases
                  of a step, for cmd/prof; prof_wasm.odin: no clock, nothing
  report_wasm.odin  what the step would say to a report, with nowhere to say it
  edit.odin       the project edited after it is read: tables that grow, a
                  node, link, demand, pattern, curve, control or rule added or
                  taken out with every index moved
  inpfile.odin    the project written back as an .inp file
  model.odin      the Odin API's rows: Model, one fat Entity per component, the
                  .inp as data; load, parse, write_inp; the project built from
                  it as the reader builds one
  sim.odin        the Odin API's columns: Sim, a network edited at any time and
                  stepped through time, N chemicals over one hydraulics, what no
                  source reaches left out; sim_from_model
  simulate.odin   a whole run of a Model as tables: Results
api/            the toolkit: EN_* over the Odin project, its own static library
  api.odin        the running half: files, runs, the report, every getter
  edit.odin       the editing half: EN_init, EN_set*, EN_add*, EN_delete*
cmd/dumpnet/    reads an .inp with the Odin reader and prints the project
                (--model: the same file as a Model, built back)
cmd/run/        runs an .inp through the Odin API and prints what harness/run.c prints
cmd/inp/        reads an .inp as a Model and writes it back
cmd/check/      the Odin API's own proofs: networks laid in code, two roads to one answer
cmd/prof/       the Odin engine's hot path and memory on one network: the stages,
                the phases of a step, the arena, the segments, the allocators — see Profiling
wasm/           the engine for JavaScript
  epanet.odin     the exports: a Sim made, rows added, the column table, step
  epanet.js       the loader and the typed-array views over the columns
  check.mjs       cmd/check's network through epanet.js in Node, printed as
                  `check --reference` prints it
harness/        the plug-in validation
  test.sh         builds the four binaries (plain EPANET, the plug-in build, its
                  shadow, and the pure Odin toolkit) and the Odin API's commands,
                  and compares
  bridge.c        the swapped symbols, with -DSHADOW running C and Odin side by side
  run.c           driver: every node and link value and quality, every step, %.17g,
                  and the report, output and hydraulics files when asked
  rebuild.c       driver: a network read, built again through the editing API,
                  run, written as .inp and read back — on each build
  dumpnet.c       the twin of cmd/dumpnet over EPANET's own reader
  fixtures/       small networks that reach the branches the real ones do not
  grid.sh         a generated N×N grid, one steady state or days of them
  out.sh          the ✓/✗ output vocabulary the script speaks
audit/          the port measured against EPANET — see Audit below
  audit.sh        harness, sources, builds, bench, valgrind, coverage → build/audit/index.html
  bench.c         one network through the whole toolkit, timed phase by phase
  prof.sh         the pure Odin engine on its own: cmd/prof on every network,
                  callgrind and memcheck beside — see Profiling
  loc.py          lines, functions, decisions and depth per file, both sides
  render.py       the files read, the summary printed, the page written
  odin-runtime.supp  what memcheck says about Odin's own allocator
package.sh      builds lib/, include/ and bin/ and tars them up for a release
.github/workflows/
  ci.yml          the harness, on every push and pull request
  release.yml     a v* tag: the harness, package.sh per platform, the release
  audit.yml       audit.sh on main, the page published to GitHub Pages
epanet-c/       OWA EPANET, cloned on demand (gitignored; not `EPANET/`, which
                is `epanet/` on a case-insensitive disk)
build/          scratch (gitignored)
```

## How a piece is plugged in

EPANET's source is never edited. `harness/test.sh` compiles `epanet-c/src` to
objects. Every object that defines a symbol in `SWAP` then goes into the
build twice: a `_c` copy with every swapped symbol renamed (`objcopy
--redefine-sym linsolve=linsolve_c`, definitions and calls alike, the rest
made local) — the pure-C originals, calling each other — and the object
itself with those definitions weakened, so the strong ones in
`harness/bridge.c` take every call, including the ones from the same file
(EPANET is compiled with `-fsemantic-interposition` so those are real calls).
The bridge's `linsolve` has EPANET's signature and hands the arrays to the
Odin package. Three binaries of the same driver come out:

| | |
|---|---|
| `run-c` | plain EPANET, the reference |
| `run-odin` | the swapped symbols come from Odin |
| `run-shadow` | the same, but every swapped call also runs the C original on a copy and compares, element by element |
| `run-pure` | the same driver over the Odin toolkit library (`api/`) and no EPANET object at all |
| `run-api` | not that driver: `cmd/run`, the file read as a `Model` and stepped as a `Sim` through the Odin API, printing the same lines |

A fixture passes when `run-c`, `run-odin`, `run-pure` and `run-api` print
the same results (bit-exact, or within `TOL=1e-9` relative — then it says
so) **and** `run-shadow` reports zero per-call mismatches, **and** the
file read as a `Model` and built back dumps as the reader's project does
(`dumpnet --model`), **and** written back (`cmd/inp`) it is the file the
toolkit writes. `cmd/check` adds the road no file can take: a network laid
with `node_add` and `link_add` and stepped by hand must give the same
bytes as the same network as a `Model` through `simulate`, and two
chemicals on one `Sim` the same bytes as two single-chemical runs. The
wasm build takes that road too, through `wasm/epanet.js` in Node, within
`WASM_TOL` (1e-6: its `pow` is the host's). The shadow snapshots every
array and struct field the engine writes before each call, so one pattern
covers every symbol. The one thing it cannot do twice is evaluate the rules,
which keep state of their own: on a network with rules the time step runs
Odin alone, and the end-to-end comparison carries it. `ASAN=1` builds all
three under AddressSanitizer, Odin side included (`-sanitize:address`); it
found the one heap overrun so far, in the shadow's own bookkeeping. The shadow is the sharp tool:
a port that drifts on the ten-thousandth call of a 24-hour run is caught at
that call, with the index and both values, not as a smeared difference in
the final heads.

To port the next piece: write it in `epanet/`, export it from `export.odin`,
add the C-signature function to `bridge.c` (both plain and `SHADOW`
flavours), and add the symbol to `SWAP`'s default in `test.sh`.

## Fixtures

EPANET's `example-networks/*.inp` and `tests/data/*.inp`, a generated 40×40
grid with parallel pipes, and `harness/fixtures/`: `valves.inp` (every valve
type on its own branch, a check valve, a constant-horsepower pump, controls),
`dw-emitters.inp` (Darcy-Weisbach through laminar, transitional and
turbulent flow, emitters, pressure-driven demand, a pump speed pattern) and
`cm-leakage.inp` (Chezy-Manning, leaking pipes, emitter backflow) and
`rules-energy.inp` (rules on a tank and the clock, a volume curve, an
efficiency curve with energy prices and patterns, a reservoir head pattern,
timer and clock-time controls), `rules-quality.inp` (the same under a
decaying chemical, with a rule closing a pipe: the quality run sees links
switch between its periods), `quality-mix.inp` (second-order bulk and
zero-order wall decay to a limiting potential, every tank mixing model,
every booster source type) and `quality-age.inp` (water age). Add your own
networks with `EXTRA_FIXTURES="…"`, or run only some with `FIXTURES="…"`.

## Where it departs from EPANET

Up to the tag `Identical` every result, report and file matched EPANET's
byte for byte, and a few lines of Odin were written strangely to get there:
a product of constants went through variables, because Odin folds the
product exactly where C rounds each constant first. Those lines are plain
now (`units.odin`, `open.odin`, `output.odin`). Checked one by one, all but
one of those products round the same either way; the orifice constant of a
leaking pipe, `4.8149766e-6`, is one ulp closer to the number written than
C's compiled `4.8149766 * 1.e-6`. That ulp does not change the accuracy of
any result — the Newton loop stops at a relative flow change of 1e-3, far
above it — but on a network that mixes leaking pipes with pressure-driven
demand it can decide whether one more trial runs. The harness compares
within `TOL` (1e-9, relative) after a bit-exact try and says which fixtures
match to the bit. One fixture is no longer run at all: `parse-clean`, which
puts every valve kind and three pumps in one loop so that every section is
read, has no stable hydraulic solution (EPANET calls it unbalanced at most
steps), so one ulp anywhere flips the sign of a flow; it is compared as
read and as written back, which is what it is for. `Identical` remains for
anyone who needs the bytes.

Bugs EPANET has that the port does not:

- `EN_addnode` of a junction moves every tank up one index but not the
  quality trace node; here it moves too.
- Reading a file whose junction lines had errors, EPANET shifts a rule
  premise on a tank once per tank, which is wrong past the first; here once.
- EPANET's `.inp` writer prints a FILLTIME or DRAINTIME premise as h:m:s,
  which EPANET's own parser cannot read back. The writer here prints the
  same (the files stay identical), and the parser reads h:m:s as well as
  hours, so the port reads what either wrote.
- `EN_setlinknodes` accepted node 0; `EN_settimeparam(EN_REPORTSTART)`
  tested the old start against the duration instead of the new one;
  `EN_deletecurve` and `EN_setcurveid` answered a bad curve index with the
  pattern error (205); `EN_setruleenabled` answered a bad rule index with
  the control error (241). Each answers as its documentation says now.
- A project begun with `EN_init` reported the quality column with no
  quality set; now the column follows the quality type, as it does for a
  project read from a file.
- EPANET makes its scratch files in the working directory; the port makes
  them in `$TMPDIR` (else `/tmp`).

Kept, because callers may lean on them: a report file name of `""` sends
the report to stdout; `EN_settimeparam` silently clamps a hydraulic step to
the pattern and report steps.

## Roadmap — core out

Ported, equivalent on every fixture (bit-exact up to the tag `Identical`):

1. **`linsolve`** — numeric Cholesky factorization + forward/back
   substitution (`smatrix.odin`).
2. **`createsparse`** — the symbolic side: adjacency with parallel links
   folded, Liu's multiple-minimum-degree ordering (`genmmd.odin`, the
   Fortran's loops kept so the ordering is EPANET's), fill-in, column
   structure (`sparse.odin`).
3. **`headlosscoeffs` / `matrixcoeffs`** — every link's P and Y (H-W, D-W,
   C-M pipes, pumps, all seven valve types) and the assembly of A and F
   with emitters and pressure-driven demands (`hydcoeffs.odin`). The first
   piece that reads the model, which the Odin side holds as one array per
   field (`network.odin`); the bridge fills that mirror from EPANET's
   structs on every call. Leakage stays in C for now, called back between
   the demands and the node balances.

4. **`hydsolve`** — the Newton loop with the status checks
   (`hydsolve.odin`, `hydstatus.odin`): damping, convergence (head error,
   flow change, PDA), the ill-conditioning recovery, pressure controls,
   and the per-trial leakage model (`leakage.odin`). What is still C's is
   reached through `Hooks`, a struct of C function pointers the bridge
   fills. The shadow snapshots every array and scalar the solver writes,
   runs both, and compares the lot.

5. **The engine around it** — `hydraul.c` (`hydraul.odin`): the demands
   of each period, the simple controls, the next time step from the tanks,
   controls and rules, tank levels through area or volume curve, pump
   energy and efficiency, the link setters, `resistcoeff` and the PCV loss
   curve.

6. **Water quality** — `quality.c`, `qualroute.c`, `qualreact.c`
   (`quality.odin`): the volume segments as arrays with index links, the
   engine's own store rather than EPANET's pool; transport in flow order,
   the topological sort, sources, bulk and wall reactions, water age,
   tracing, the four tank mixing models, the mass balance. The entry
   points `initqual`, `runqual`, `nextqual`, `stepqual` and `avgqual` are
   swapped as a unit, with their file reads and report writes kept in the
   bridge. In the shadow build the two engines run side by side on their
   own segment stores and are compared chain by chain, segment by segment.
   The driver runs every fixture twice: hydraulics and quality together,
   and quality from the hydraulics file with `EN_stepQ`.

7. **The run and the rules** — `openhyd`'s `inithyd`, `runhyd`, `nexthyd`
   (`hydraul.odin`) and the rule engine (`rules.odin`): premises, the
   action list with priorities, the rule time step. The whole hydraulic
   and quality run is now Odin's.

8. **The reader** — `input1.c`, `input2.c`, `input3.c` and the parsing
   half of `rules.c` (`project.odin`, `parse.odin`, `parse2.odin`,
   `units.odin`, `validate.odin`). The Odin package now owns a `Project`
   read from an `.inp` file: the two passes, every section, EPANET's
   keyword matching (a prefix, case blind), `strtod` numbers, the clock
   time forms, the error codes and the error count, then the tank
   re-indexing, the dependent defaults, the unit factors and the
   conversion to feet, cfs and seconds, and the validation that fits each
   pump's curve. Checked another way than the engine: `cmd/dumpnet` and
   `harness/dumpnet.c` print the whole project, from the Odin reader and
   from EPANET's, and `test.sh` wants the two prints identical — they are,
   for every fixture, the three parse fixtures (every section and option,
   the error lines, the junction errors that move the tanks) included.
   Two EPANET readings are not mirrored, both out of bounds in C: after a
   quoted token holding a blank it tokenizes the bytes past the line, and
   a tank line in `[MIXING]` or `[REACTIONS]` read before the tanks are
   re-indexed is indexed past the tank table (the Odin reader stops at the
   table's end). One is mirrored on purpose: a quoted token makes the
   line's last token keep its line end, so `"600" 8 120 1.5` reads 1.5 as
   no number.

9. **The report and the files** — `report.c`, `output.c` and the file
   opening in `project.c` (`report.odin`, `output.odin`, `errors.odin`).
   The engine writes its own status lines, warnings and errors now (the
   last of `Hooks` is gone: every engine proc takes the project), and
   the report file is written whole: logo, summary, the hydraulic status
   report, the energy table, the node and link tables read back from the
   output file with their page breaks and continuation headings, the
   reporting limits, the time statistics. The binary output file (prolog,
   energy, every reporting period, the time statistic, the reaction rates,
   the epilog) and the hydraulics file (written per period, read back for
   a quality run) are Odin's too. Text goes through the C library's
   formatting, so the bytes are EPANET's. Checked by `run.c` writing all
   three files from each build and `test.sh` diffing them, the report less
   its dates: identical on every fixture, with two report fixtures added
   for what the networks did not reach (tables over several pages, a
   setting changed by a pressure control, a junction cut off behind a
   closed pipe, one pressure-deficient node). Still C's: the input error
   messages (`inperrmsg`, `ruleerrmsg`) and `clocktime`'s progress text.

10. **The toolkit** — `epanet.c` (`api/api.odin`, with `open.odin`
    underneath): the `EN_*` functions with EPANET's names, calling
    convention and error codes, as a static library of their own. The
    running half: projects and their scratch files, `EN_open`, the
    hydraulic and quality runs (`EN_solveH`, `EN_openH` … `EN_closeQ`,
    `EN_stepQ`, the hydraulics file saved and reused), the report, and
    every getter (counts, options, times, nodes, links, demands,
    patterns, curves, controls, rules, statistics). Under it the project
    opens its own solvers: the matrix shape from `sparse.odin`, the
    adjacency lists, the leakage setup, the quality arrays and segment
    store. `harness/run.c` now also links this library and nothing of
    EPANET's (`run-pure`), and prints the same results and writes the
    same three files as plain EPANET on every fixture. One trap found on
    the way: Odin folds a product of two constants exactly, where C
    rounds each constant to a double first, a last-bit difference that
    grows through a Newton iteration; such products go through variables.
    Still C's: the input error messages.

11. **The editing toolkit** — the other half of `epanet.c` (`api/edit.odin`
    over `epanet/edit.odin`) and `inpfile.c` (`inpfile.odin`): `EN_init`,
    every `EN_set*`, `EN_add*` and `EN_delete*`, `EN_saveinpfile`, and
    with them demand names, link vertices, comments and tags, which the
    reader now keeps. The project's tables grow (doubling, from the
    arena); a node or link added or taken out moves every index that
    pointed past it — the tanks, the links' ends, the controls, the rules'
    premises and actions, the demand ranges — as EPANET's do, and a rule
    added by text goes through the reader's own rule parser. All 144
    `EN_*` functions of `epanet2_2.h` are exported. Proved by
    `harness/rebuild.c`: each fixture read, built again in a fresh project
    through the getters and setters, run and printed, written as `.inp`,
    read back and run, on plain EPANET and on the toolkit — the prints and
    the files are byte for byte the same (one EPANET quirk shared: its own
    writer prints a FILLTIME premise in h:m:s, which its own parser does
    not read back; fixed here, see *Where it departs from EPANET*).

12. **The Odin API** — designed in [`API.md`](API.md), built in
    `model.odin`, `sim.odin` and `simulate.odin`. A `Model` is the `.inp`
    as data, one fat `Entity` per component in the file's units; `load`
    reads one (a file with bad lines still comes back, its `problems`
    listed), `write_inp` writes one, and `project_from_model` builds the
    engine's project from it the way the reader builds one from the file,
    so the two run to the same bytes (`dumpnet --model`, on every
    fixture). A `Sim` is columns: nodes and links the caller edits at any
    time, stepped through time with `sim_step`, its results in columns
    beside them; values are read every step, structure when `rewire` is
    set (a row added or removed sets it); what no tank or reservoir
    reaches is left out and said so, not refused; N chemicals ride one
    hydraulics, each with its own segments; a `Sim` made from a `Model`
    keeps the model's patterns, controls, rules and quality options
    inside and plays them each step. `simulate` is that loop with the
    reporting times kept as `Results` tables. `cmd/run` proves the loop
    is EPANET's run on every fixture, `cmd/check` that the bare road and
    the model road give the same bytes. Two things the design did not
    foresee: the engine's `Project` stays inside the `Sim` as its own
    (built on rewire from an effective `Model`; nothing had to move to
    `api/`), and `sim_copy` rebuilds the copy's engine on its first step
    rather than cloning the solver's state, so a copy goes on within the
    solver's accuracy, not to the bit.

13. **WebAssembly** — the engine's step path with no C library, no
    files and no virtual memory: `cmath`, `numbers` and `arena` pick
    their implementation per target, `text.odin` holds what every build
    says (the names, a report line, the clock, the run's warning code),
    the file world (`files.odin`, `report.odin`, `output.odin`,
    `inpfile.odin`, `dump.odin`, `export.odin`) is native-only and what
    the step would say to a report goes to stubs on wasm. The native
    build is the same bytes as before (the harness says so). `wasm/`
    exports a Sim over plain numbers and the column table, `epanet.js`
    wraps it in typed-array views, and `check.mjs` lays `cmd/check`'s
    network through it in Node and matches `check --reference` within
    `WASM_TOL`: the one import the module has is `pow`, the host's.

That is the roadmap: core out, every phase done.

## Living inside bywater-mill

bywater-mill carries this repository as the submodule `epanet/odin`; its
`make epanet-odin` runs the harness here against its own EPANET checkout
with its utilities' networks added to the fixtures.

## Audit — the live report

```sh
audit/audit.sh            # everything, a few minutes → build/audit/index.html
audit/audit.sh quick      # no valgrind, no coverage
audit/audit.sh -v         # name every step
```

One script measures the port against EPANET and writes one page (and prints
the same figures on the terminal). Three builds of the engine go through it:
EPANET's C at `-O2`, the Odin toolkit at `-o:speed`, and the Odin toolkit
with `-no-bounds-check` — the difference between the last two is what the
checks cost.

1. **Overview** — the harness tally; lines, functions, decisions and nesting
   per part of EPANET beside the Odin files that port it; the EN_* functions
   declared against those exported; build times at both optimisation levels;
   library and binary sizes; how much of EPANET's C the fixtures run
   (llvm-cov).
2. **Examples** — Net1, Net2, Net3 and a 1,600-node grid through open,
   hydraulics, quality, report and close on each build: results, report,
   `.out` and `.hyd` byte for byte identical, then the median time per phase,
   the peak resident set and its growth over the reps.
3. **Analytics** — callgrind instruction counts with simulated caches and
   branch prediction, each hot C function beside its Odin twin, the twenty
   costliest functions inclusive of callees per build; massif peak heap;
   memcheck errors and leaks with where they come from.

The page is `build/audit/index.html`, one file, set in Iosevka (the local
font if installed, else fetched), light and dark. `.github/workflows/audit.yml`
runs it on every push to `main` and publishes it at
<https://jordanshurmer.github.io/epanet-odin/>. Needs python3; valgrind and
llvm-cov are optional and a run without them says so.

## Profiling — the engine on its own

```sh
audit/prof.sh                # cmd/prof on every network → build/prof/
audit/prof.sh callgrind      # + instructions per proc (valgrind)
audit/prof.sh memcheck       # + leaks and errors on the step path
audit/prof.sh save before    # keep this run's figures as build/prof/before/
audit/prof.sh diff before    # a saved run beside the last one
NETWORKS="Net3 grid40x3d" REPS=10 audit/prof.sh
```

The audit measures the port against EPANET; this measures the Odin
rewrite against itself, the way a program drives it: `load`,
`sim_from_model`, `sim_step` to the end. `cmd/prof` prints, for one
network, the time of each stage (load, the engine built on the first
step, the steps), then — built with `-define:PROF=true` — the phases of
a step from `epanet/prof.odin` (the coefficients, the solve, the flow
corrections, the status checks, the quality transport and reactions,
the copies in and out), each with its calls, its share and its mean;
then memory: the project's arena and whether the steps grew it, the
segment store, what the Sim's allocator and the temporary allocator
were asked for during the steps (a step that allocates is a smell), and
the resident set. The stopwatch is the cycle counter, calibrated over
the run, so a microsecond phase is measured and not swamped; off, it
compiles to nothing. `audit/prof.sh` runs it on EPANET's examples, the
fixtures that run, and two grids from `harness/grid.sh`: `grid40`, one
steady state of 1,600 junctions (the solver), and `grid40x3d`, the same
for three days by the hour with a decaying chemical (the step path and
the segments in their steady state). `callgrind` puts an instruction
count on every proc; `memcheck` says what leaks.

What it found, and what changed for it (every result still bit for bit
EPANET's, and the harness says so):

- `copy_in` recomputed every link's resistance every step, two `pow`
  calls a pipe; now only when its size or roughness moved.
- The wall reaction rate took the Schmidt number's power per pipe per
  step; it is one number a step.
- The quality sort and the rule engine took scratch from the temporary
  allocator every step, which nothing freed on the toolkit's path: a
  long run grew without bound. The scratch is the solver's now,
  allocated when it opens.
- The segment store was three dynamic arrays (volume, quality, link),
  three cache lines a segment and three appends; it is one array of
  `Segment`, with room for two a chain before it grows. The chain
  walks take one pointer per segment instead of indexing the store
  three to five times, and run without bounds checks, as `linsolve`
  does: the indexes are the store's own.
- The matrix's coefficients sit in `aij` in the order the solver walks
  them (`column_order`, after `create_sparse`, which keeps EPANET's
  numbering for the shadow): a fifth fewer cache misses in the solve.
- Opening a large network spent half its time in `fill_in` asking
  whether two nodes were already linked by scanning a list; a marker
  array answers it, in the same order.
- A second pass found the bounds checks still a tenth of every step,
  in the per-trial passes over the links and junctions (the
  coefficients, the flow corrections, the status checks, the copies in
  and out) and in what transport calls: they run unchecked now too, over
  the engine's own indexes, like the solver (the policy is one paragraph
  in `network.odin`). And transport worked out each link's flow order on
  every visit from every node; it is noted once a period (`up`, `down`),
  which also reads better. The flow itself is still read at transport
  time, as EPANET reads it: a rule that switches a link between the two
  is seen, and `rules-quality.inp` pins that.

Against the first measurement, on the 1,600-junction grid a step is
30 % faster and the engine opens twice as fast; on Net3 a step is a
quarter faster; the step loop runs 44 % fewer instructions. What is left
is `linsolve` and the quality transport, EPANET's algorithms over EPANET's
data layout — a Cholesky on the junction graph and a walk of every
segment — and `pow`: bound by memory and libm, not by anything the port
adds. The peak resident set on opening is Odin's 4 MB temporary
allocator backing and the transient effective Model (480 bytes an
entity), not the engine's tables; `memcheck` finds nothing lost.

## Releases

Every push and pull request runs the harness (`.github/workflows/ci.yml`).
A tag `vX.Y.Z` makes a release (`release.yml`): the harness on Linux, then
`package.sh` on `linux-amd64` and `macos-arm64`, then a GitHub release with
one tarball per platform:

```
epanet-odin-v0.1.0-linux-amd64/
  lib/libepanet-api.a    EN_* with the C ABI — links wherever libepanet2.a
                         does, -lm with it
  include/               epanet2_2.h, epanet2_enums.h (EPANET's own: the API
                         is EPANET's), LICENSE-EPANET
  bin/dumpnet            reads an .inp and prints the project
  bin/run                runs an .inp through the Odin API and prints every result
  wasm/epanet.wasm       the engine for JavaScript, with wasm/epanet.js to load it
  LICENSE  README.md
```

The Odin package is not in it: an Odin program takes `epanet/` as source.

```sh
./package.sh v0.1.0 linux-amd64       # the same tarball by hand, in build/
git tag v0.1.0 && git push origin v0.1.0
```

Or run `release` from the Actions tab with the version to tag: it tags the
commit it ran on as it publishes.

## License

MIT, like EPANET itself (see `LICENSE`).

## Installing Odin

A release tarball from <https://github.com/odin-lang/Odin/releases> works
(`odin-linux-amd64-dev-2026-10.tar.gz`, `odin-macos-arm64-…`; untar and
point `ODIN=` at the `odin` in it — the workflows do the same, with the
release named at the top of each). So does building it: `apt install
llvm-18-dev clang-18`, clone the repo at a `dev-YYYY-MM` tag, `make
release-native`, and point `ODIN=` at the binary. The wasm build links
with LLVM's `wasm-ld`, which comes with the `lld` package (`apt install
lld`, `brew install lld`); without it the harness skips the wasm road.
