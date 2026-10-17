#!/usr/bin/env bash
# test.sh — build EPANET with the Odin pieces plugged in, and prove they match.
#
#   harness/test.sh            one symbol per fixture × check, then the tally
#   harness/test.sh -v         name every check
#   harness/test.sh -vv        + compiler, objcopy and shadow output
#   SWAP="linsolve" harness/test.sh        the symbols to take from Odin
#   ODIN=/opt/odin/odin harness/test.sh    where the compiler is (default: PATH)
#   EPANET=../EPANET harness/test.sh       an EPANET checkout to build from
#                                          (default: ./EPANET, cloned on demand)
#   FIXTURES="a.inp b.inp" harness/test.sh       just those networks
#   EXTRA_FIXTURES="c.inp" harness/test.sh       the usual set plus those
#   ASAN=1 harness/test.sh     every binary under AddressSanitizer (both
#                              sides; needs libclang-rt-<ver>-dev)
#
# Three binaries of the same driver (harness/run.c) are built from EPANET's
# own sources: `c` is plain EPANET; `odin` has each symbol in SWAP renamed
# away in its object (objcopy --redefine-sym linsolve=linsolve_c) and supplied
# by harness/bridge.c, which calls the Odin package; `shadow` is the same with
# every swapped call running both and comparing. Then for every fixture: c and
# odin must print the same results (bit-exact, else within TOL relative and
# noted), and shadow must report no per-call mismatches.
#
# ponytail: a shell loop over clang and objcopy; cmake stays out of it.
set -uo pipefail

cd "$(dirname "$0")/.."
. harness/out.sh

for a in "$@"; do
    debug_flag "$a" || usage "unknown argument: $a"
done

ODIN=${ODIN:-odin}
SWAP=${SWAP:-"linsolve createsparse headlosscoeffs matrixcoeffs hydsolve resistcoeff pcvlosscoeff initlinkflow resetpumpflow setlinkstatus setlinksetting demands controls timestep tanklevels tankvolume tankgrade getenergy getallpumpsenergy addenergy initqual runqual nextqual stepqual avgqual checkrules inithyd runhyd nexthyd"}
TOL=${TOL:-1e-9}
EP=${EPANET:-EPANET}
EPANET_COMMIT=444725fbf16ab28b0470ef0ed281dc4849d49583   # OWA EPANET 2.3 dev
B=build
CC=${CC:-clang}
CFLAGS="-O2 -fPIC -fsemantic-interposition -w -I$EP/include -I$EP/src"
ODINFLAGS="-o:speed"
if [ -n "${ASAN:-}" ]; then
    CFLAGS="$CFLAGS -g -fsanitize=address -fno-sanitize-address-globals-dead-stripping"
    ODINFLAGS="-o:none -debug -sanitize:address"
fi

command -v "$ODIN" >/dev/null || usage "odin compiler not found (ODIN=$ODIN); see README.md"
if [ ! -f "$EP/src/epanet.c" ]; then
    note "cloning OWA EPANET @ ${EPANET_COMMIT:0:7} into $EP"
    run git clone -q https://github.com/OpenWaterAnalytics/EPANET.git "$EP" &&
        run git -C "$EP" checkout -q "$EPANET_COMMIT" ||
        usage "could not fetch EPANET into $EP (set EPANET= to a checkout)"
fi

# The default fixture set: EPANET's own example networks and harness/fixtures
# — small networks written to reach the branches those do not (every valve
# type, D-W and C-M, emitters, PDA, leakage). EXTRA_FIXTURES adds to it.
if [ -z "${FIXTURES:-}" ]; then
    FIXTURES="$(ls $EP/example-networks/*.inp $EP/tests/data/*.inp \
        harness/fixtures/*.inp 2>/dev/null) ${EXTRA_FIXTURES:-}"
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
run $CC $CFLAGS -c harness/run.c -o "$B/run.o" || bad "compile run.c"

cp "$B"/c/*.o "$B/odin/"
# Each object that defines a swapped symbol goes into the odin build twice.
# One copy, <obj>_c.o, has every swapped symbol renamed sym -> sym_c (the
# definitions it holds and the calls it makes alike) with only those
# definitions left global: the pure-C originals, calling each other. The
# other keeps its name but with its swapped definitions weakened, so the
# bridge's strong ones take every call, those from the same file included
# (EPANET is compiled with -fsemantic-interposition so that such calls are
# real calls, not inlined bodies).
renames=""; keeps=""
for sym in $SWAP; do renames="$renames --redefine-sym $sym=${sym}_c"; keeps="$keeps -G ${sym}_c"; done
for obj in "$B"/odin/*.o; do
    defined=$(nm "$obj" | awk -v syms=" $SWAP " '$2=="T" && index(syms, " "$3" ") {print $3}')
    [ -n "$defined" ] || continue
    weakens=""
    for sym in $defined; do weakens="$weakens --weaken-symbol=$sym"; done
    dbg "objcopy $renames $keeps $obj ${obj%.o}_c.o"
    run objcopy $renames $keeps "$obj" "${obj%.o}_c.o" || bad "swap $(basename "$obj")"
    run objcopy $weakens "$obj" || bad "weaken $(basename "$obj")"
done
for sym in $SWAP; do
    nm "$B"/odin/*_c.o | grep " T ${sym}_c\$" >/dev/null || bad "swap $sym" "no object defines $sym"
done

note "odin build epanet"
run "$ODIN" build epanet -build-mode:static -out:"$B/libepanet-odin.a" \
    -no-entry-point $ODINFLAGS -vet -strict-style || bad "odin build"

run $CC $CFLAGS -c harness/bridge.c -o "$B/bridge.o" || bad "compile bridge.c"
run $CC $CFLAGS -DSHADOW -c harness/bridge.c -o "$B/bridge-shadow.o" || bad "compile bridge.c -DSHADOW"

run $CC $CFLAGS "$B/run.o" "$B"/c/*.o -lm -o "$B/run-c" || bad "link run-c"
run $CC $CFLAGS "$B/run.o" "$B"/odin/*.o "$B/bridge.o" "$B/libepanet-odin.a" -lm -o "$B/run-odin" || bad "link run-odin"
run $CC $CFLAGS "$B/run.o" "$B"/odin/*.o "$B/bridge-shadow.o" "$B/libepanet-odin.a" -lm -o "$B/run-shadow" || bad "link run-shadow"
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

# check FIXTURE MODE — run one network through c, odin and shadow in one
# driver mode ("" = hydraulics and quality together, "stepq" = quality
# from the hydraulics file) and judge the three.
check() {
    inp=$1; mode=$2
    fx=$(basename "$inp" .inp)${mode:+.$mode}
    "$B/run-c" "$inp" $mode >"$B/$fx.c.txt" 2>"$B/$fx.c.err"
    rc_c=$?
    "$B/run-odin" "$inp" $mode >"$B/$fx.odin.txt" 2>"$B/$fx.odin.err"
    rc_o=$?
    if [ $rc_c -ne 0 ]; then
        skip "$fx (EPANET itself fails: $(grep -m1 'EPANET error' "$B/$fx.c.err"))"
        return
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

    "$B/run-shadow" "$inp" $mode >/dev/null 2>"$B/$fx.shadow.err"
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
}

for inp in $FIXTURES; do
    check "$inp" ""
    check "$inp" stepq
done


tally "epanet-odin"
