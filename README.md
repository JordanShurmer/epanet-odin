# epanet/odin — EPANET, rewritten in Odin, one solver at a time

The water engine is being rewritten in Odin, data-oriented, from the core
solvers outward. Every piece is proved against the C original before the
next one starts, by plugging it into the real EPANET and running both.

```sh
epanet/odin/test.sh            # build c / odin / shadow, run every fixture
epanet/odin/test.sh -v         # name every check
make epanet-odin               # the same
```

## Layout

```
src/            the Odin package `epanet` — the rewrite
  smatrix.odin    numeric Cholesky: linsolve
  sparse.odin     symbolic factorization: createsparse
  genmmd.odin     minimum-degree ordering
  network.odin    the model and solver state, one array per field; Hooks
  hydcoeffs.odin  link coefficients and matrix assembly
  hydstatus.odin  status checks between trials
  hydsolve.odin   the Newton loop
  leakage.odin    pipe leaks as node demand, per trial
  export.odin     the C face: one exported proc per swapped EPANET symbol
fixtures/       small networks that reach the branches the real ones do not
bridge/
  bridge.c        the swapped symbols, with -DSHADOW running C and Odin side by side
  run.c           driver: every node and link value, every time step, %.17g
test.sh         builds the three binaries from epanet/EPANET and compares
build/          scratch (gitignored)
```

## How a piece is plugged in

EPANET's source is never edited. `test.sh` compiles `epanet/EPANET/src` to
objects, then for each symbol in `SWAP` renames the C definition in its own
object (`objcopy --redefine-sym linsolve=linsolve_c`). The callers keep asking
for `linsolve`, and `bridge/bridge.c` supplies it: a function with EPANET's
signature that hands the arrays to the Odin package. Three binaries of the
same driver come out:

| | |
|---|---|
| `run-c` | plain EPANET, the reference |
| `run-odin` | the swapped symbols come from Odin |
| `run-shadow` | the same, but every swapped call also runs the C original on a copy and compares, element by element |

A fixture passes when `run-c` and `run-odin` print the same results
(bit-exact, or within `TOL=1e-9` relative — then it says so) **and**
`run-shadow` reports zero per-call mismatches. `ASAN=1` builds all three
under AddressSanitizer, Odin side included (`-sanitize:address`); it found
the one heap overrun so far, in the shadow's own bookkeeping. The shadow is the sharp tool:
a port that drifts on the ten-thousandth call of a 24-hour run is caught at
that call, with the index and both values, not as a smeared difference in
the final heads.

To port the next piece: write it in `src/`, export it from `export.odin`,
add the C-signature function to `bridge.c` (both plain and `SHADOW`
flavours), and add the symbol to `SWAP`'s default in `test.sh`.

## Fixtures

EPANET's `example-networks/*.inp` and `tests/data/*.inp`, this repo's
`utilities/*/data/*.inp` and `smoketest/testdata/model.inp`, a generated
40×40 grid with parallel pipes, and `fixtures/`: `valves.inp` (every valve
type on its own branch, a check valve, a constant-horsepower pump, controls),
`dw-emitters.inp` (Darcy-Weisbach through laminar, transitional and
turbulent flow, emitters, pressure-driven demand, a pump speed pattern) and
`cm-leakage.inp` (Chezy-Manning, leaking pipes, emitter backflow). Override
with `FIXTURES="…"`.

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

Next, in order:

5. **Time stepping and controls** — `hydraul.c`: tank levels, patterns,
   simple controls, rules, energy; `openleakage`'s pipe-to-node leak
   coefficients; `resistcoeff` and the PCV loss curve.
6. **Water quality** — `quality.c`, `qualroute.c`, `qualreact.c`.
7. **The outside** — `.inp` parsing, reporting, the toolkit API; at that
   point `epanet/epanet.go` links the Odin library instead of
   `libepanet2.a`.

## Installing Odin

A release zip from <https://github.com/odin-lang/Odin/releases> works; so
does building it: `apt install llvm-18-dev clang-18`, clone the repo at a
`dev-YYYY-MM` tag, `make release-native`, and point `ODIN=` at the binary.
