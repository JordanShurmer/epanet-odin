# epanet-odin — EPANET, rewritten in Odin, one solver at a time

[OWA EPANET](https://github.com/OpenWaterAnalytics/EPANET), the water
distribution network engine, rewritten in Odin, data-oriented, from the core
solvers outward. Every piece is proved against the C original before the
next one starts, by plugging it into the real EPANET and running both.

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
  network.odin    the model and solver state, one array per field; Hooks
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
  errors.odin     EPANET's error messages by code
  open.odin       opening and closing the solvers on an owned project; the
                  quality run's orchestration over the hydraulics file
api/            the toolkit: EN_* over the Odin project, its own static library
cmd/dumpnet/    reads an .inp with the Odin reader and prints the project
harness/        the plug-in validation
  test.sh         builds the four binaries (plain EPANET, the plug-in build, its
                  shadow, and the pure Odin toolkit) and compares
  bridge.c        the swapped symbols, with -DSHADOW running C and Odin side by side
  run.c           driver: every node and link value and quality, every step, %.17g,
                  and the report, output and hydraulics files when asked
  dumpnet.c       the twin of cmd/dumpnet over EPANET's own reader
  fixtures/       small networks that reach the branches the real ones do not
  out.sh          the ✓/✗ output vocabulary the script speaks
audit/          the port measured against EPANET — see Audit below
  audit.sh        harness, sources, builds, bench, valgrind, coverage → build/audit/index.html
  bench.c         one network through the whole toolkit, timed phase by phase
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

A fixture passes when `run-c` and `run-odin` print the same results
(bit-exact, or within `TOL=1e-9` relative — then it says so) **and**
`run-shadow` reports zero per-call mismatches. The shadow snapshots every
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
timer and clock-time controls), `quality-mix.inp` (second-order bulk and
zero-order wall decay to a limiting potential, every tank mixing model,
every booster source type) and `quality-age.inp` (water age). Add your own
networks with `EXTRA_FIXTURES="…"`, or run only some with `FIXTURES="…"`.

## Roadmap — core out

Ported, bit-exact on every fixture:

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
    Not yet: the editing calls (`EN_set*`, `EN_add*`, `EN_delete*`,
    `EN_saveinpfile`), demand names, link vertices, comments and tags,
    and the input error messages.

Next, in order:

11. **The Odin API** — designed in [`API.md`](API.md), for games and
    every other data-oriented use: a `Sim` whose network is columns the
    caller edits at any time and steps through time, its results columns
    beside them, N chemicals over one hydraulics, what no source reaches
    left out rather than refused, nothing allocated in a step, wasm in
    mind; a `Model` (one fat `Entity` per component, the `.inp` as data)
    for files, `simulate` to `Results` as tables. No Project: the
    engine's struct becomes `Sim`, and the files, report state and
    `EN_*` semantics move to `api/`, which stays beside it for C programs.
12. **The editing toolkit** — `EN_set*`, `EN_add*`, `EN_delete*`,
    `EN_saveinpfile` (`inpfile.c`): a project built and changed through
    the C API, not only read from a file.

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
release-native`, and point `ODIN=` at the binary.
