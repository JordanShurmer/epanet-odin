#!/usr/bin/env bash
# prof.sh — the Odin engine's hot path and memory, network by network.
#
#   audit/prof.sh                 build cmd/prof, run every network, print the figures → build/prof/
#   audit/prof.sh callgrind       + instructions per proc, inclusive and self (valgrind)
#   audit/prof.sh memcheck        + leaks and errors on the step path (valgrind)
#   audit/prof.sh -v              name every step
#   audit/prof.sh save NAME       keep the last run's figures as build/prof/NAME/
#   audit/prof.sh diff A B        two saved runs side by side (B = the last run when left out)
#   NETWORKS="Net3 grid40x3d" REPS=10 audit/prof.sh
#   ODIN=… EPANET=…               as harness/test.sh
#
# This is the debug harness for the pure Odin rewrite: not the port
# against EPANET (that is audit.sh) but the engine on its own, through
# the Odin API — load, sim_from_model, sim_step to the end — the way a
# program would drive it. cmd/prof measures it: the stages, the phases of
# a step (the engine built with -define:PROF=true), the project's arena,
# the segment store, what the allocators were asked for during the
# steps, and the resident set. callgrind puts an instruction count on
# every proc of a plain -o:speed build with symbols, so the table says
# where a step goes; memcheck says what leaks.
#
# The networks: EPANET's examples, the harness fixtures that run, and
# two grids from harness/grid.sh — grid40 (one steady state, 1600 rows:
# the solver) and grid40x3d (three days by the hour with a chemical: the
# step path and the segments in their steady state).
set -uo pipefail

cd "$(dirname "$0")/.."
. harness/out.sh
. harness/grid.sh

MODE=
SAVE_AS=
DIFF_A=
DIFF_B=
while [ $# -gt 0 ]; do
    debug_flag "$1" && { shift; continue; }
    case "$1" in
    callgrind | memcheck) MODE=$1 ;;
    save) SAVE_AS=${2:-}; [ -n "$SAVE_AS" ] || usage "save needs a name"; shift ;;
    diff) DIFF_A=${2:-}; DIFF_B=${3:-}; [ -n "$DIFF_A" ] || usage "diff needs a name"; shift $(($# - 1)) ;;
    *) usage "unknown argument: $1" ;;
    esac
    shift
done

ODIN=${ODIN:-odin}
EP=${EPANET:-epanet-c}
REPS=${REPS:-5}
P=build/prof

# ── save and diff: no run ────────────────────────────────────────────────
if [ -n "$SAVE_AS" ]; then
    [ -d "$P" ] || usage "nothing to save: run audit/prof.sh first"
    rm -rf "$P/$SAVE_AS"
    mkdir -p "$P/$SAVE_AS"
    cp "$P"/*.txt "$P/$SAVE_AS/"
    echo "saved as $P/$SAVE_AS/"
    exit 0
fi
if [ -n "$DIFF_A" ]; then
    a=$P/$DIFF_A
    b=${DIFF_B:+$P/$DIFF_B}
    b=${b:-$P}
    [ -d "$a" ] || usage "no saved run $a"
    for f in "$a"/*.prof.txt; do
        n=$(basename "$f" .prof.txt)
        [ -f "$b/$n.prof.txt" ] || continue
        printf '\n── %s: %s | %s ──\n' "$n" "$DIFF_A" "${DIFF_B:-last}"
        diff -y -W 150 "$f" "$b/$n.prof.txt" | sed '1d'
    done
    exit 0
fi

command -v "$ODIN" >/dev/null || usage "odin compiler not found (ODIN=$ODIN); see README.md"
[ -f "$EP/example-networks/Net1.inp" ] || usage "no EPANET checkout at $EP (harness/test.sh clones it)"

# inp_of NAME — the path of a network by name.
inp_of() {
    local p
    for p in "$EP/example-networks/$1.inp" "$EP/tests/data/$1.inp" "harness/fixtures/$1.inp" "$P/$1.inp" "$1"; do
        [ -f "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

mkdir -p "$P"
rm -f "$P"/*.txt
grid_inp 40 >"$P/grid40.inp"
grid_inp 40 72 >"$P/grid40x3d.inp"
NETWORKS=${NETWORKS:-"Net1 Net2 Net3 valves dw-emitters cm-leakage rules-energy quality-mix quality-age grid40 grid40x3d"}

# ── build ────────────────────────────────────────────────────────────────
# plain: the honest timing. phases: the stopwatch inside. symbols: plain
# with debug info, for callgrind's table.
run "$ODIN" build cmd/prof -o:speed -vet -strict-style -out:"$P/prof" && ok "build prof" || bad "build prof"
run "$ODIN" build cmd/prof -o:speed -define:PROF=true -vet -strict-style -out:"$P/prof-phases" && ok "build prof-phases" || bad "build prof-phases"
if [ "$MODE" = callgrind ] || [ "$MODE" = memcheck ]; then
    command -v valgrind >/dev/null || usage "valgrind not found"
    run "$ODIN" build cmd/prof -o:speed -debug -out:"$P/prof-symbols" && ok "build prof-symbols" || bad "build prof-symbols"
fi
[ "$_fail" -eq 0 ] || { tally "prof"; exit 1; }

# ── run ──────────────────────────────────────────────────────────────────
for fx in $NETWORKS; do
    inp=$(inp_of "$fx") || { bad "$fx" "no such network"; continue; }
    out=$P/$fx.prof.txt
    if "$P/prof" "$inp" -reps "$REPS" >"$out" 2>"$P/$fx.err"; then
        # the phases from the instrumented build, under the plain timing
        "$P/prof-phases" "$inp" -reps "$REPS" 2>>"$P/$fx.err" | sed -n '/^phase/,/^(unaccounted)/p' >>"$out"
        ok "$fx $(grep '^steps' "$out" | sed 's/ *(.*//')"
    else
        bad "$fx" "$(tail -1 "$P/$fx.err")"
        continue
    fi
    case $MODE in
    callgrind)
        if run valgrind -q --tool=callgrind --callgrind-out-file="$P/$fx.callgrind" "$P/prof-symbols" "$inp" >/dev/null; then
            callgrind_annotate --inclusive=no "$P/$fx.callgrind" 2>/dev/null | awk 'NR > 20 && /epanet\./ && n++ < 25' | sed 's/ \[[^]]*\]//' >"$P/$fx.self.txt"
            callgrind_annotate --inclusive=yes "$P/$fx.callgrind" 2>/dev/null | awk 'NR > 20 && /epanet\./ && n++ < 25' | sed 's/ \[[^]]*\]//' >"$P/$fx.incl.txt"
            ok "callgrind $fx"
        else
            bad "callgrind $fx"
        fi
        ;;
    memcheck)
        valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,possible --suppressions=audit/odin-runtime.supp \
            "$P/prof-symbols" "$inp" >/dev/null 2>"$P/$fx.memcheck.txt"
        if grep -q 'ERROR SUMMARY: 0 errors' "$P/$fx.memcheck.txt" && ! grep -q 'definitely lost: [1-9]' "$P/$fx.memcheck.txt"; then
            ok "memcheck $fx clean"
        else
            bad "memcheck $fx" "$(grep -E 'ERROR SUMMARY|definitely lost|possibly lost' "$P/$fx.memcheck.txt" | head -3)" "$P/$fx.memcheck.txt"
        fi
        ;;
    esac
done
tally "prof" || exit 1

# ── the figures ──────────────────────────────────────────────────────────
for fx in $NETWORKS; do
    [ -f "$P/$fx.prof.txt" ] || continue
    printf '\n── %s ──\n' "$fx"
    sed '1d' "$P/$fx.prof.txt"
    if [ "$MODE" = callgrind ] && [ -f "$P/$fx.self.txt" ]; then
        printf '\ninstructions, self (callgrind)\n'
        head -12 "$P/$fx.self.txt"
    fi
done
