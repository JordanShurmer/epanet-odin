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
  smatrix.odin    sparse Cholesky solver (EPANET smatrix.c: linsolve)
  export.odin     the C face: one exported proc per swapped EPANET symbol
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
`run-shadow` reports zero per-call mismatches. The shadow is the sharp tool:
a port that drifts on the ten-thousandth call of a 24-hour run is caught at
that call, with the index and both values, not as a smeared difference in
the final heads.

To port the next piece: write it in `src/`, export it from `export.odin`,
add the C-signature function to `bridge.c` (both plain and `SHADOW`
flavours), and add the symbol to `SWAP`'s default in `test.sh`.

## Fixtures

EPANET's `example-networks/*.inp` and `tests/data/*.inp`, plus this repo's
`utilities/*/data/*.inp` and `smoketest/testdata/model.inp`. Override with
`FIXTURES="…"`.

## Roadmap — core out

Ported, bit-exact on every fixture:

1. **`linsolve`** — numeric Cholesky factorization + forward/back
   substitution (`smatrix.odin`).

Next, in order:

2. **Symbolic factorization** — `createsparse`: multiple-minimum-degree
   reordering (`genmmd.c`), fill-in (`factorize`), `storesparse`,
   `sortsparse`. One exported proc taking the adjacency as CSR arrays and
   giving back `Order`, `Row`, `XLNZ`, `NZSUB`, `LNZ`, `Ndx`.
3. **Link coefficients** — `hydcoeffs.c`: head-loss formulas (H-W, D-W,
   C-M), pump and valve coefficients, emitters, leakage, PDA demands. The
   first piece that reads the network, so the Odin side gets its own
   struct-of-arrays network (`Network`) that the bridge fills from EPANET's
   `Snode`/`Slink`.
4. **The Newton loop** — `hydsolve`, with `hydstatus.c` (valve and link
   status checks) and the convergence tests.
5. **Time stepping and controls** — `hydraul.c`: tank levels, patterns,
   simple controls, rules, energy.
6. **Water quality** — `quality.c`, `qualroute.c`, `qualreact.c`.
7. **The outside** — `.inp` parsing, reporting, the toolkit API; at that
   point `epanet/epanet.go` links the Odin library instead of
   `libepanet2.a`.

## Installing Odin

A release zip from <https://github.com/odin-lang/Odin/releases> works; so
does building it: `apt install llvm-18-dev clang-18`, clone the repo at a
`dev-YYYY-MM` tag, `make release-native`, and point `ODIN=` at the binary.
