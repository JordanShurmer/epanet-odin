#!/usr/bin/env bash
# test.sh — build EPANET with the Odin pieces plugged in, and prove they match.
#
#   epanet/odin/test.sh            one symbol per fixture × check, then the tally
#   epanet/odin/test.sh -v         name every check
#   epanet/odin/test.sh -vv        + compiler, objcopy and shadow output
#   SWAP="linsolve" epanet/odin/test.sh      the symbols to take from Odin
#   ODIN=/opt/odin/odin epanet/odin/test.sh  where the compiler is (default: PATH)
#   FIXTURES="a.inp b.inp" epanet/odin/test.sh   just those networks
#
# Three binaries of the same driver (bridge/run.c) are built from EPANET's own
# sources in epanet/EPANET: `c` is plain EPANET; `odin` has each symbol in SWAP
# renamed away in its object (objcopy --redefine-sym linsolve=linsolve_c) and
# supplied by bridge/bridge.c, which calls the Odin package; `shadow` is the
# same with every swapped call running both and comparing. Then for every
# fixture: c and odin must print the same results (bit-exact, else within TOL
# relative and noted), and shadow must report no per-call mismatches.
#
# ponytail: a shell loop over clang and objcopy; cmake stays out of it.
set -uo pipefail

cd "$(dirname "$0")/../.."
. scripts/lib/out.sh

for a in "$@"; do
    debug_flag "$a" || usage "unknown argument: $a"
done

ODIN=${ODIN:-odin}
SWAP=${SWAP:-"linsolve createsparse headlosscoeffs matrixcoeffs"}
TOL=${TOL:-1e-9}
EP=epanet/EPANET
OD=epanet/odin
B=$OD/build
CC=${CC:-clang}
CFLAGS="-O2 -w -I$EP/include -I$EP/src"

command -v "$ODIN" >/dev/null || usage "odin compiler not found (ODIN=$ODIN); see $OD/README.md"
[ -f $EP/src/epanet.c ] || usage "$EP is empty — git submodule update --init epanet/EPANET"

# The default fixture set: EPANET's own example networks, the utilities this
# repo serves, and fixtures/ — small networks written to reach the branches
# those do not (every valve type, D-W and C-M, emitters, PDA, leakage).
if [ -z "${FIXTURES:-}" ]; then
    FIXTURES="$(ls $EP/example-networks/*.inp $EP/tests/data/*.inp \
        utilities/*/data/*.inp smoketest/testdata/model.inp $OD/fixtures/*.inp 2>/dev/null)"
fi

rm -rf "$B"
mkdir -p "$B/c" "$B/odin"

# A generated fixture the real networks are too small for: a 40×40 grid of
# junctions (1600 rows, 3120 pipes) fed from one reservoir, with a strip of
# parallel pipes and a pump, so the ordering, the fill-in and the parallel-link
# folding all have real work to do.
grid_inp() {
    awk -v n="$1" 'BEGIN {
        print "[TITLE]\ngrid " n "x" n "\n\n[JUNCTIONS]"
        for (i = 0; i < n; i++) for (j = 0; j < n; j++)
            printf "J%d-%d %d %g\n", i, j, 500 - i - j, 0.3 + ((i * 7 + j * 3) % 5) / 10
        print "\n[RESERVOIRS]\nR1 700\n\n[PIPES]"
        for (i = 0; i < n; i++) for (j = 0; j < n; j++) {
            if (j + 1 < n) printf "H%d-%d J%d-%d J%d-%d 800 8 110 0 Open\n", i, j, i, j, i, j + 1
            if (i + 1 < n) printf "V%d-%d J%d-%d J%d-%d 800 8 110 0 Open\n", i, j, i, j, i + 1, j
        }
        for (j = 0; j + 1 < n; j += 3) printf "P%d J%d-%d J%d-%d 800 6 100 0 Open\n", j, 5, j, 5, j + 1
        print "\n[PUMPS]\nPU1 R1 J0-0 HEAD C1\n\n[CURVES]\nC1 0 150\nC1 3000 100\nC1 6000 30"
        print "\n[OPTIONS]\nUnits GPM\nHeadloss H-W\nTrials 60\nAccuracy 0.001"
        print "\n[TIMES]\nDuration 0\n\n[END]"
    }'
}
grid_inp 40 >"$B/grid40.inp"
FIXTURES="$FIXTURES $B/grid40.inp"

# ── build ───────────────────────────────────────────────────────────────
note "compiling $EP/src"
for f in $EP/src/*.c $EP/src/util/*.c; do
    run $CC $CFLAGS -c "$f" -o "$B/c/$(basename "$f" .c).o" || bad "compile $f"
done
run $CC $CFLAGS -c $OD/bridge/run.c -o "$B/run.o" || bad "compile run.c"

cp "$B"/c/*.o "$B/odin/"
# Rename each swapped symbol in the object that defines it. `nm` finds that
# object; the callers keep asking for the bare name and get the bridge's.
for sym in $SWAP; do
    obj=$(nm -A "$B"/odin/*.o 2>/dev/null | grep " T $sym\$" | cut -d: -f1 | head -1)
    [ -n "$obj" ] || { bad "swap $sym" "no object defines $sym"; continue; }
    dbg "objcopy --redefine-sym $sym=${sym}_c $obj"
    run objcopy --redefine-sym "$sym=${sym}_c" "$obj" || bad "swap $sym"
done

note "odin build $OD/src"
run "$ODIN" build $OD/src -build-mode:static -out:"$B/libepanet-odin.a" \
    -no-entry-point -o:speed -vet -strict-style || bad "odin build"

run $CC $CFLAGS -c $OD/bridge/bridge.c -o "$B/bridge.o" || bad "compile bridge.c"
run $CC $CFLAGS -DSHADOW -c $OD/bridge/bridge.c -o "$B/bridge-shadow.o" || bad "compile bridge.c -DSHADOW"

run $CC "$B/run.o" "$B"/c/*.o -lm -o "$B/run-c" || bad "link run-c"
run $CC "$B/run.o" "$B"/odin/*.o "$B/bridge.o" "$B/libepanet-odin.a" -lm -o "$B/run-odin" || bad "link run-odin"
run $CC "$B/run.o" "$B"/odin/*.o "$B/bridge-shadow.o" "$B/libepanet-odin.a" -lm -o "$B/run-shadow" || bad "link run-shadow"
[ "$_fail" -eq 0 ] || { tally "epanet-odin"; exit 1; }
ok "build c odin shadow"

# ── compare ─────────────────────────────────────────────────────────────
# same A B — exit 0 when every number on every line is within TOL (relative)
# of its twin; prints the first line that is not. `cmp` first: bit-exact is
# the common case and the one worth knowing about.
same() {
    paste -d'|' "$1" "$2" | awk -F'|' -v tol="$TOL" '
        { n = split($1, a, " "); m = split($2, b, " ")
          if (n != m) { print "line " NR ": " $1 " | " $2; exit 1 }
          for (i = 1; i <= n; i++) {
              if (a[i] == b[i]) continue
              x = a[i] + 0; y = b[i] + 0
              d = x - y; if (d < 0) d = -d
              s = x < 0 ? -x : x; t = y < 0 ? -y : y; if (t > s) s = t
              if (s == 0 || d / s > tol) { print "line " NR " field " i ": " a[i] " vs " b[i]; exit 1 }
          }
        }'
}

for inp in $FIXTURES; do
    fx=$(basename "$inp" .inp)
    "$B/run-c" "$inp" >"$B/$fx.c.txt" 2>"$B/$fx.c.err"
    rc_c=$?
    "$B/run-odin" "$inp" >"$B/$fx.odin.txt" 2>"$B/$fx.odin.err"
    rc_o=$?
    if [ $rc_c -ne 0 ] && [ $rc_o -eq $rc_c ]; then
        skip "$fx (EPANET itself fails: $(head -1 "$B/$fx.c.err"))"
        continue
    fi
    if [ $rc_c -ne $rc_o ]; then
        bad "$fx results" "exit c=$rc_c odin=$rc_o" "$(head -1 "$B/$fx.odin.err")"
    elif cmp -s "$B/$fx.c.txt" "$B/$fx.odin.txt"; then
        ok "$fx results bit-exact ($(wc -l <"$B/$fx.c.txt") lines)"
    elif diff=$(same "$B/$fx.c.txt" "$B/$fx.odin.txt"); then
        ok "$fx results within $TOL"
        note "  $fx is not bit-exact: $(diff "$B/$fx.c.txt" "$B/$fx.odin.txt" | grep -c '^<') lines differ"
    else
        bad "$fx results" "$diff" "diff $B/$fx.c.txt $B/$fx.odin.txt"
    fi

    "$B/run-shadow" "$inp" >/dev/null 2>"$B/$fx.shadow.err"
    [ "$DEBUG" -ge 2 ] && sed 's/^/    /' "$B/$fx.shadow.err" >&2
    for sym in $SWAP; do
        line=$(grep "^shadow $sym: [0-9]* calls" "$B/$fx.shadow.err")
        if [ -z "$line" ]; then
            bad "$fx shadow $sym" "no tally line in $B/$fx.shadow.err"
        elif echo "$line" | grep -q ' 0 mismatches'; then
            ok "$fx shadow ${line#shadow }"
        else
            bad "$fx shadow $sym" "$line" "$(grep "^shadow $sym: call" "$B/$fx.shadow.err")"
        fi
    done
done

tally "epanet-odin"
