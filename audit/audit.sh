#!/usr/bin/env bash
# audit.sh — measure the port against EPANET, and write the report.
#
#   audit/audit.sh               everything: harness, sources, builds, bench,
#                                valgrind, coverage → build/audit/index.html
#   audit/audit.sh quick         no valgrind, no coverage
#   audit/audit.sh -v            name every step
#   REPS=10 audit/audit.sh       bench repetitions (default 5)
#   EXAMPLES="Net1 Net3" audit/audit.sh    the networks the examples and the
#                                          analytics use (default: Net1 Net2 Net3 grid40)
#   ODIN=… EPANET=… CC=…         as harness/test.sh
#
# Measures, then renders. Every step writes a file under build/audit/: JSON
# from bench.c and loc.py, key<TAB>value text from here, and valgrind's and
# llvm-cov's output as they wrote it. Then audit/render.py reads the
# directory, prints the summary and writes index.html. A tool that is not
# installed (valgrind, llvm-cov) is a skipped step, named in the report.
#
# Three builds of the engine are compared: EPANET's C at -O2, the Odin
# toolkit at -o:speed, and the same with -no-bounds-check — the difference
# between the last two is what the bounds checks cost.
set -uo pipefail

cd "$(dirname "$0")/.."
. harness/out.sh
. harness/same.sh

QUICK=
for a in "$@"; do
    debug_flag "$a" && continue
    case "$a" in
    quick) QUICK=1 ;;
    *) usage "unknown argument: $a" ;;
    esac
done

ODIN=${ODIN:-odin}
CC=${CC:-clang}
EP=${EPANET:-epanet-c}
REPS=${REPS:-5}
EXAMPLES=${EXAMPLES:-"Net1 Net2 Net3 grid40"}
LLVM_COV=${LLVM_COV:-llvm-cov}
LLVM_PROFDATA=${LLVM_PROFDATA:-llvm-profdata}
A=build/audit
IMPLS="c odin odin-nbc"
WDIFF=$A/wdiff

command -v "$ODIN" >/dev/null || usage "odin compiler not found (ODIN=$ODIN); see README.md"
command -v python3 >/dev/null || usage "python3 not found (loc.py and render.py need it)"

# ms — milliseconds now (python: BSD date has no %N).
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# timed NAME CMD… — run a command, append NAME<TAB>ms to builds.txt.
timed() {
    local name=$1 t0 t1 status
    shift
    t0=$(ms)
    run "$@"
    status=$?
    t1=$(ms)
    printf '%s\t%s\n' "$name" "$((t1 - t0))" >>"$A/builds.txt"
    return $status
}

# inp_of NAME — the path of a network by name, wherever it lives.
inp_of() {
    local p
    for p in "$EP/example-networks/$1.inp" "$EP/tests/data/$1.inp" "harness/fixtures/$1.inp" "build/$1.inp" "$1"; do
        [ -f "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# lib IMPL — the library each build of the engine is linked from.
lib() {
    case $1 in
    c) echo "$A/c/libepanet2.a" ;;
    odin) echo "$A/libepanet-api.a" ;;
    odin-nbc) echo "$A/libepanet-api-nbc.a" ;;
    esac
}

# ── 1 the harness: the port proved on every fixture ──────────────────────
# test.sh empties build/ first, so its tally is kept outside until it is done.
tally_file=$(mktemp)
t0=$(ms)
harness/test.sh | tee "$tally_file"
t1=$(ms)
mkdir -p "$A"
tally=$(grep -o 'epanet-odin [0-9]*✓.*' "$tally_file" | tail -1)
rm -f "$tally_file"
pass=$(printf '%s' "$tally" | grep -o '[0-9]*✓' | tr -d '✓')
fail=$(printf '%s' "$tally" | grep -o '[0-9]*✗' | tr -d '✗')
printf 'pass\t%s\nfail\t%s\nms\t%s\n' "${pass:-0}" "${fail:-0}" "$((t1 - t0))" >"$A/harness.txt"
if [ -z "$tally" ]; then
    bad "harness" "no tally line from harness/test.sh"
elif [ "${fail:-0}" -eq 0 ]; then
    ok "harness $tally"
else
    bad "harness" "$tally"
fi

# ── 2 the sources ────────────────────────────────────────────────────────
python3 audit/loc.py "$EP" >"$A/loc.json" && ok "sources counted" || bad "loc.py"

# ── 3 the builds: time and size ──────────────────────────────────────────
: >"$A/builds.txt"
mkdir -p "$A/c" "$A/c0"

# build_c DIR FLAGS… — every EPANET source to DIR, then the archive.
build_c() {
    local dir=$1 f
    shift
    for f in "$EP"/src/*.c "$EP"/src/util/*.c; do
        "$CC" "$@" -w -I"$EP/include" -I"$EP/src" -c "$f" -o "$dir/$(basename "$f" .c).o" || return 1
    done
    ar rcs "$dir/libepanet2.a" "$dir"/*.o
}
timed c_speed build_c "$A/c" -O2 && ok "build c -O2" || bad "build c -O2"
timed c_none build_c "$A/c0" -O0 && ok "build c -O0" || bad "build c -O0"
timed odin_speed "$ODIN" build api -build-mode:static -no-entry-point -o:speed -vet -strict-style \
    -out:"$A/libepanet-api.a" && ok "build odin -o:speed" || bad "build odin -o:speed"
timed odin_nbc "$ODIN" build api -build-mode:static -no-entry-point -o:speed -no-bounds-check \
    -out:"$A/libepanet-api-nbc.a" && ok "build odin -no-bounds-check" || bad "build odin -no-bounds-check"
timed odin_none "$ODIN" build api -build-mode:static -no-entry-point -o:none \
    -out:"$A/libepanet-api-none.a" && ok "build odin -o:none" || bad "build odin -o:none"
timed odin_engine "$ODIN" build epanet -build-mode:static -no-entry-point -o:speed \
    -out:"$A/libepanet-odin.a" || bad "build odin engine"
timed odin_dumpnet "$ODIN" build cmd/dumpnet -o:speed -out:"$A/dumpnet-odin" || bad "build dumpnet-odin"
run "$CC" -O2 -w -I"$EP/include" -I"$EP/src" harness/dumpnet.c "$A/c/libepanet2.a" -lm -o "$A/dumpnet-c" || bad "link dumpnet-c"
run "$CC" -O2 -w harness/wdiff.c -lm -o "$A/wdiff" || bad "compile wdiff.c"
for impl in $IMPLS; do
    run "$CC" -O2 -w -I"$EP/include" audit/bench.c "$(lib $impl)" -lm -o "$A/bench-$impl" || bad "link bench-$impl"
    run "$CC" -O2 -w -I"$EP/include" harness/run.c "$(lib $impl)" -lm -o "$A/run-$impl" || bad "link run-$impl"
done
for f in c/libepanet2.a c0/libepanet2.a libepanet-api.a libepanet-api-nbc.a libepanet-api-none.a libepanet-odin.a \
    run-c run-odin run-odin-nbc dumpnet-c dumpnet-odin; do
    [ -f "$A/$f" ] || continue
    printf 'size\t%s\t%s\n' "$f" "$(wc -c <"$A/$f" | tr -d ' ')" >>"$A/builds.txt"
    case $f in
    *.a) ;;
    *) strip -o "$A/$f.stripped" "$A/$f" 2>/dev/null &&
        printf 'stripped\t%s\t%s\n' "$f" "$(wc -c <"$A/$f.stripped" | tr -d ' ')" >>"$A/builds.txt" ;;
    esac
done
ok "sizes"

# ── 4 bench: the same driver on each build, phase by phase ───────────────
for impl in $IMPLS; do : >"$A/bench-$impl.jsonl"; done
for fx in $EXAMPLES; do
    inp=$(inp_of "$fx") || { bad "bench $fx" "no such network"; continue; }
    for impl in $IMPLS; do
        if "$A/bench-$impl" "$inp" "$REPS" "$A/bench.rpt" >>"$A/bench-$impl.jsonl" 2>"$A/bench.err"; then
            ok "bench $fx $impl ×$REPS"
        else
            bad "bench $fx $impl" "$(tail -1 "$A/bench.err")"
        fi
    done
done

# ── 5 equivalence: every value at %.17g, the report, the .out and .hyd files ──
# A verdict is `ok` (byte for byte), `near` (within TOL, 1e-9 relative) or `bad`.
undated() { sed -e '1s/^\(  Page 1 *\).*$/\1DATE/' -e 's/^\(  Analysis \(begun\|ended\) \).*$/\1DATE/' "$1"; }
: >"$A/equiv.txt"
for fx in $EXAMPLES; do
    inp=$(inp_of "$fx") || continue
    for impl in $IMPLS; do
        "$A/run-$impl" "$inp" - "$A/eq.$fx.$impl" >"$A/eq.$fx.$impl.txt" 2>&1
        undated "$A/eq.$fx.$impl.rpt" >"$A/eq.$fx.$impl.rpt.undated"
    done
    worst=ok
    for impl in odin odin-nbc; do
        for what in txt rpt.undated out hyd; do
            a="$A/eq.$fx.c.$what"; b="$A/eq.$fx.$impl.$what"
            if cmp -s "$a" "$b"; then
                verdict=ok
            elif case $what in out|hyd) same_bin "$a" "$b" >/dev/null ;; *) same "$a" "$b" >/dev/null ;; esac; then
                verdict=near
            else
                verdict=bad
            fi
            [ $verdict = bad ] && worst=bad
            [ $verdict = near ] && [ $worst = ok ] && worst=near
            printf '%s\t%s\t%s\t%s\n' "$fx" "$impl" "${what%.undated}" "$verdict" >>"$A/equiv.txt"
        done
    done
    case $worst in
    ok) ok "$fx: results, report, .out and .hyd identical on all three" ;;
    near) ok "$fx: results, report, .out and .hyd within $TOL on all three" ;;
    *) bad "$fx differs" "$(grep "^$fx" "$A/equiv.txt" | grep bad | head -3)" ;;
    esac
done

# ── 6 valgrind: instructions and cache (callgrind), heap (massif), errors (memcheck) ──
rm -f "$A"/callgrind.* "$A"/massif.* "$A"/memcheck.*
if [ -n "$QUICK" ]; then
    skip "valgrind (quick)"
elif ! command -v valgrind >/dev/null; then
    skip "valgrind (not installed)"
else
    for fx in $EXAMPLES; do
        inp=$(inp_of "$fx") || continue
        for impl in $IMPLS; do
            if run valgrind -q --tool=callgrind --cache-sim=yes --branch-sim=yes \
                    --callgrind-out-file="$A/callgrind.$impl.$fx" "$A/bench-$impl" "$inp" 1 "$A/bench.rpt"; then
                callgrind_annotate --inclusive=no "$A/callgrind.$impl.$fx" >"$A/callgrind.$impl.$fx.self.txt" 2>/dev/null
                callgrind_annotate --inclusive=yes "$A/callgrind.$impl.$fx" >"$A/callgrind.$impl.$fx.incl.txt" 2>/dev/null
                ok "callgrind $fx $impl"
            else
                bad "callgrind $fx $impl"
            fi
            run valgrind -q --tool=massif --massif-out-file="$A/massif.$impl.$fx" \
                "$A/bench-$impl" "$inp" 1 "$A/bench.rpt" && ok "massif $fx $impl" || bad "massif $fx $impl"
            valgrind --tool=memcheck --leak-check=full --show-leak-kinds=all --suppressions=audit/odin-runtime.supp \
                "$A/bench-$impl" "$inp" 1 "$A/bench.rpt" >/dev/null 2>"$A/memcheck.$impl.$fx.txt"
            ok "memcheck $fx $impl"   # the verdict is in the report
        done
    done
fi

# ── 7 coverage: how much of EPANET's C the fixtures run (llvm-cov) ───────
rm -f "$A/coverage.json"
if [ -n "$QUICK" ]; then
    skip "coverage (quick)"
elif ! command -v "$LLVM_PROFDATA" >/dev/null || ! command -v "$LLVM_COV" >/dev/null; then
    skip "coverage (llvm-cov not installed)"
else
    mkdir -p "$A/cov"
    rm -f "$A"/cov/*.profraw
    covflags="-O0 -w -fprofile-instr-generate -fcoverage-mapping -I$EP/include -I$EP/src"
    for f in "$EP"/src/*.c "$EP"/src/util/*.c; do
        run "$CC" $covflags -c "$f" -o "$A/cov/$(basename "$f" .c).o" || bad "coverage compile $(basename "$f")"
    done
    run "$CC" $covflags harness/run.c "$A"/cov/*.o -lm -o "$A/cov/run-cov" || bad "coverage link"
    # the same networks and modes as the harness
    n=0
    for inp in "$EP"/example-networks/*.inp "$EP"/tests/data/*.inp harness/fixtures/*.inp build/grid40.inp; do
        [ -f "$inp" ] || continue
        LLVM_PROFILE_FILE="$A/cov/%p.profraw" "$A/cov/run-cov" "$inp" - "$A/cov/x" >/dev/null 2>&1
        LLVM_PROFILE_FILE="$A/cov/%p.profraw" "$A/cov/run-cov" "$inp" stepq "$A/cov/y" >/dev/null 2>&1
        n=$((n + 1))
    done
    printf 'coverage_networks\t%s\n' "$n" >>"$A/builds.txt"
    run "$LLVM_PROFDATA" merge -o "$A/cov/all.profdata" "$A"/cov/*.profraw &&
        "$LLVM_COV" export -summary-only -instr-profile="$A/cov/all.profdata" "$A/cov/run-cov" >"$A/coverage.json" &&
        ok "coverage: $n networks × 2 modes" || bad "coverage"
fi

# ── 8 the machine and the tools ──────────────────────────────────────────
{
    printf 'date\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'uname\t%s\n' "$(uname -sm)"
    printf 'cpu\t%s\n' "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    printf 'odin\t%s\n' "$("$ODIN" version 2>/dev/null | sed 's/.*odin version //')"
    printf 'cc\t%s\n' "$("$CC" --version | head -1)"
    printf 'valgrind\t%s\n' "$(valgrind --version 2>/dev/null || echo 'not installed')"
    printf 'llvm-cov\t%s\n' "$("$LLVM_COV" --version 2>/dev/null | grep -m1 -i 'version' || echo 'not installed')"
    printf 'epanet\t%s\n' "$(git -C "$EP" rev-parse --short HEAD 2>/dev/null)"
    printf 'commit\t%s\n' "$(git rev-parse --short HEAD 2>/dev/null)"
    printf 'reps\t%s\n' "$REPS"
    printf 'examples\t%s\n' "$EXAMPLES"
    printf 'quick\t%s\n' "${QUICK:-0}"
} >"$A/env.txt"

tally "audit"
status=$?
python3 audit/render.py "$A" || exit 1
exit $status
