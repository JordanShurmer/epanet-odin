# epanet-odin — EPANET, rewritten in Odin, one solver at a time

[OWA EPANET](https://github.com/OpenWaterAnalytics/EPANET), the water
distribution network engine, rewritten in Odin, data-oriented, from the core
solvers outward. Every piece is proved against the C original before the
next one starts, by plugging it into the real EPANET and running both.

```sh
harness/test.sh            # build c / odin / shadow, run every fixture
harness/test.sh -v         # name every check
```

The first run clones EPANET at the pinned commit into `EPANET/` (or point
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
  hydraul.odin    the engine around it: demands, controls, time step, energy
  quality.odin    water quality: segments, transport, reactions, tank mixing
  export.odin     the C face: one exported proc per swapped EPANET symbol
harness/        the plug-in validation
  test.sh         builds the three binaries from EPANET's sources and compares
  bridge.c        the swapped symbols, with -DSHADOW running C and Odin side by side
  run.c           driver: every node and link value and quality, every step, %.17g
  fixtures/       small networks that reach the branches the real ones do not
  out.sh          the ✓/✗ output vocabulary the script speaks
EPANET/         OWA EPANET, cloned on demand (gitignored)
build/          scratch (gitignored)
```

## How a piece is plugged in

EPANET's source is never edited. `harness/test.sh` compiles `EPANET/src` to
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
   and the per-trial leakage model (`leakage.odin`). What is still C's,
   the status-report lines, is reached through `Hooks`, a struct of C
   function pointers the bridge fills. The shadow snapshots every array
   and scalar the solver writes, runs both, and compares the lot.

5. **The engine around it** — `hydraul.c` (`hydraul.odin`): the demands
   of each period, the simple controls, the next time step from the tanks,
   controls and rules, tank levels through area or volume curve, pump
   energy and efficiency, the link setters, `resistcoeff` and the PCV loss
   curve. Rules (`rules.c`) are still C's, reached through a hook that
   syncs the mirror around the call; so are `openhyd`/`inithyd`/`runhyd`/
   `nexthyd`, the orchestration with the file I/O and reports.

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

Next, in order:

7. **The outside** — `quality.c`, `qualroute.c`, `qualreact.c`.
7. **The outside** — `openhyd`/`inithyd`/`runhyd`/`nexthyd` and the rule
   engine, then `.inp` parsing, reporting, the toolkit API; at that point
   a program links the Odin library instead of `libepanet2.a`.

## Living inside bywater-mill

This directory is laid out as its own repository. To give it one:

```sh
git subtree split --prefix=epanet/odin -b epanet-odin   # in bywater-mill
git push git@github.com:JordanShurmer/epanet-odin.git epanet-odin:main
```

then replace the directory with a submodule of it. Until then bywater-mill's
`make epanet-odin` runs the harness here against its own EPANET checkout.

## License

MIT, like EPANET itself (see `LICENSE`).

## Installing Odin

A release zip from <https://github.com/odin-lang/Odin/releases> works; so
does building it: `apt install llvm-18-dev clang-18`, clone the repo at a
`dev-YYYY-MM` tag, `make release-native`, and point `ODIN=` at the binary.
