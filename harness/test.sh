#!/usr/bin/env bash
# test.sh — build EPANET with the Odin pieces plugged in, and prove they match.
#
#   harness/test.sh            one symbol per fixture × check, then the tally
#   harness/test.sh -v         name every check
#   harness/test.sh -vv        + compiler, objcopy and shadow output
#   SWAP="linsolve" harness/test.sh        the symbols to take from Odin
#   SWAP_FILES="" harness/test.sh          ...and the report and file writers
#   ODIN=/opt/odin/odin harness/test.sh    where the compiler is (default: PATH)
#   EPANET=../EPANET harness/test.sh       an EPANET checkout to build from
#                                          (default: ./epanet-c, cloned on demand)
#   FIXTURES="a.inp b.inp" harness/test.sh       just those networks
#   EXTRA_FIXTURES="c.inp" harness/test.sh       the usual set plus those
#   ASAN=1 harness/test.sh     every binary under AddressSanitizer (both
#                              sides; needs libclang-rt-<ver>-dev)
#   WASM_TOL=1e-6 harness/test.sh   what the wasm build is held to (its pow
#                              is the host's, so not to the byte)
#
# Four binaries of the same driver (harness/run.c): `c` is plain EPANET;
# `odin` has each symbol in SWAP renamed away in its object (objcopy
# --redefine-sym linsolve=linsolve_c) and supplied by harness/bridge.c, which
# calls the Odin package; `shadow` is the same with every swapped call running
# both and comparing; `pure` links the Odin toolkit library (api/) and no
# EPANET object at all. Then for every fixture: c, odin and pure must print
# the same results and write the same files — bit-exact, else within TOL
# (relative, 1e-9) and said so — and shadow must report no per-call
# mismatch beyond TOL. (Bit-exact everywhere was the state at the tag
# `Identical`; since then a few of EPANET's constant products are computed
# plainly, which moves a last bit.) A second
# driver (harness/rebuild.c), linked to c and to pure, reads each fixture,
# builds it again through the editing API, runs that, writes both as .inp
# and reads the second back: the prints and the files must match too. The
# Odin API (model.odin, sim.odin) is held to the same: cmd/run prints the
# same lines of each fixture through load, sim_from_model and sim_step;
# cmd/dumpnet --model and cmd/inp read each fixture as a Model and write
# it back as a project and as a file; cmd/check lays networks in code. The
# wasm build (wasm/) lays cmd/check's network through epanet.js in Node and
# must print what check --reference prints, within WASM_TOL.
#
# ponytail: a shell loop over clang and objcopy; cmake stays out of it.
set -uo pipefail

cd "$(dirname "$0")/.."
. harness/out.sh
. harness/same.sh

for a in "$@"; do
    debug_flag "$a" || usage "unknown argument: $a"
done

ODIN=${ODIN:-odin}
SWAP=${SWAP:-"linsolve createsparse headlosscoeffs matrixcoeffs hydsolve resistcoeff pcvlosscoeff initlinkflow resetpumpflow setlinkstatus setlinksetting demands controls timestep tanklevels tankvolume tankgrade getenergy getallpumpsenergy addenergy initqual runqual nextqual stepqual avgqual checkrules inithyd runhyd nexthyd"}
# The report and the files: swapped, not shadowed (their result is the file).
SWAP_FILES=${SWAP_FILES:-"writeline writelogo clearreport writesummary writehydstat writeflowbalance writemassbalance writereport writeheader writerelerr writestatchange writecontrolaction writeruleaction writehydwarn writehyderr writetime errmsg savenetdata savehyd savehydstep saveenergy readhyd readhydstep saveoutput savefinaloutput openhydfile openoutfile closeoutfile freedata"}
TOL=${TOL:-1e-9}
WASM_TOL=${WASM_TOL:-1e-6}
EP=${EPANET:-epanet-c}
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
run $CC $CFLAGS -c harness/dumpnet.c -o "$B/dumpnet.o" || bad "compile dumpnet.c"
run $CC $CFLAGS -c harness/rebuild.c -o "$B/rebuild.o" || bad "compile rebuild.c"
run $CC -O2 -w harness/wdiff.c -lm -o "$B/wdiff" || bad "compile wdiff.c"

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
for sym in $SWAP $SWAP_FILES; do renames="$renames --redefine-sym $sym=${sym}_c"; keeps="$keeps -G ${sym}_c"; done
for obj in "$B"/odin/*.o; do
    defined=$(nm "$obj" | awk -v syms=" $SWAP $SWAP_FILES " '$2=="T" && index(syms, " "$3" ") {print $3}')
    [ -n "$defined" ] || continue
    weakens=""
    for sym in $defined; do weakens="$weakens --weaken-symbol=$sym"; done
    dbg "objcopy $renames $keeps $obj ${obj%.o}_c.o"
    run objcopy $renames $keeps "$obj" "${obj%.o}_c.o" || bad "swap $(basename "$obj")"
    run objcopy $weakens "$obj" || bad "weaken $(basename "$obj")"
done
for sym in $SWAP $SWAP_FILES; do
    nm "$B"/odin/*_c.o | grep " T ${sym}_c\$" >/dev/null || bad "swap $sym" "no object defines $sym"
done

note "odin build epanet"
run "$ODIN" build epanet -build-mode:static -out:"$B/libepanet-odin.a" \
    -no-entry-point $ODINFLAGS -vet -strict-style || bad "odin build"

run $CC $CFLAGS -c harness/bridge.c -o "$B/bridge.o" || bad "compile bridge.c"
run $CC $CFLAGS -DSHADOW -c harness/bridge.c -o "$B/bridge-shadow.o" || bad "compile bridge.c -DSHADOW"

run $CC $CFLAGS "$B/run.o" "$B"/c/*.o -lm -o "$B/run-c" || bad "link run-c"
run $CC $CFLAGS "$B/dumpnet.o" "$B"/c/*.o -lm -o "$B/dumpnet-c" || bad "link dumpnet-c"
run "$ODIN" build cmd/dumpnet -out:"$B/dumpnet-odin" $ODINFLAGS -vet -strict-style || bad "odin build dumpnet"
note "odin build run inp check"
run "$ODIN" build cmd/run -out:"$B/run-api" $ODINFLAGS -vet -strict-style || bad "odin build run"
run "$ODIN" build cmd/inp -out:"$B/inp-api" $ODINFLAGS -vet -strict-style || bad "odin build inp"
run "$ODIN" build cmd/check -out:"$B/check-api" $ODINFLAGS -vet -strict-style || bad "odin build check"
# the wasm build needs LLVM's wasm-ld (the lld package); without it the
# wasm road is skipped, not failed
if command -v wasm-ld >/dev/null; then
    note "odin build wasm"
    run "$ODIN" build wasm -target:freestanding_wasm32 -out:"$B/epanet.wasm" -no-entry-point $ODINFLAGS -vet -strict-style || bad "odin build wasm"
fi
note "odin build api"
run "$ODIN" build api -build-mode:static -out:"$B/libepanet-api.a" \
    -no-entry-point $ODINFLAGS -vet -strict-style || bad "odin build api"
run $CC $CFLAGS "$B/run.o" "$B/libepanet-api.a" -lm -o "$B/run-pure" || bad "link run-pure"
run $CC $CFLAGS "$B/rebuild.o" "$B"/c/*.o -lm -o "$B/rebuild-c" || bad "link rebuild-c"
run $CC $CFLAGS "$B/rebuild.o" "$B/libepanet-api.a" -lm -o "$B/rebuild-pure" || bad "link rebuild-pure"
run $CC $CFLAGS "$B/run.o" "$B"/odin/*.o "$B/bridge.o" "$B/libepanet-odin.a" -lm -o "$B/run-odin" || bad "link run-odin"
run $CC $CFLAGS "$B/run.o" "$B"/odin/*.o "$B/bridge-shadow.o" "$B/libepanet-odin.a" -lm -o "$B/run-shadow" || bad "link run-shadow"
[ "$_fail" -eq 0 ] || { tally "epanet-odin"; exit 1; }
ok "build c odin shadow pure dumpnet rebuild run inp check wasm"

# ── compare ─────────────────────────────────────────────────────────────
# (same / same_bin from harness/same.sh: cmp first, then within TOL)
export SHADOW_TOL=$TOL

# fixture_kind FIXTURE — `run`: results, files, shadow and the rebuild are
# all compared; `parse`: only its reading and what is written back.
# parse-clean puts every valve kind and three pumps in one loop so that
# every section and keyword gets read; it has no stable hydraulic solution
# (EPANET calls it unbalanced at most steps), so one ulp anywhere decides
# the sign of a flow, and comparing its results would prove nothing.
fixture_kind() {
    case $1 in
    parse-clean) echo parse ;;
    *) echo run ;;
    esac
}

# check_files FIXTURE BUILD — the report less its dates, the output file
# and the hydraulics file against plain EPANET's: identical, or within TOL.
check_files() {
    fx=$1; build=$2
    undated() { sed -e '1s/^\(  Page 1 *\).*$/\1DATE/' -e 's/^\(  Analysis \(begun\|ended\) \).*$/\1DATE/' "$1"; }
    undated "$B/$fx.c.rpt" >"$B/$fx.c.rpt.undated"
    undated "$B/$fx.$build.rpt" >"$B/$fx.$build.rpt.undated"
    if cmp -s "$B/$fx.c.rpt.undated" "$B/$fx.$build.rpt.undated"; then
        ok "$fx $build report identical ($(wc -l <"$B/$fx.c.rpt") lines)"
    elif diff=$(same "$B/$fx.c.rpt.undated" "$B/$fx.$build.rpt.undated"); then
        ok "$fx $build report within $TOL"
    else
        bad "$fx $build report" "$diff" "diff $B/$fx.c.rpt $B/$fx.$build.rpt"
    fi
    for ext in out hyd; do
        if cmp -s "$B/$fx.c.$ext" "$B/$fx.$build.$ext"; then
            ok "$fx $build .$ext identical ($(wc -c <"$B/$fx.c.$ext") bytes)"
        elif diff=$(same_bin "$B/$fx.c.$ext" "$B/$fx.$build.$ext"); then
            ok "$fx $build .$ext $diff"
        else
            bad "$fx $build .$ext" "$diff" "$WDIFF $B/$fx.c.$ext $B/$fx.$build.$ext $TOL"
        fi
    done
}

# check FIXTURE MODE — run one network through c, odin and shadow in one
# driver mode ("" = hydraulics and quality together, "stepq" = quality
# from the hydraulics file) and judge the three.
check() {
    inp=$1; mode=$2
    fx=$(basename "$inp" .inp)${mode:+.$mode}
    "$B/run-c" "$inp" "${mode:--}" "$B/$fx.c" >"$B/$fx.c.txt" 2>"$B/$fx.c.err"
    rc_c=$?
    "$B/run-odin" "$inp" "${mode:--}" "$B/$fx.odin" >"$B/$fx.odin.txt" 2>"$B/$fx.odin.err"
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

    # The three files: the report less its dates, the output file and the
    # hydraulics file.
    if [ $rc_c -eq 0 ]; then
        check_files "$fx" odin
    fi

    # The pure build, the toolkit over the Odin project alone: the same
    # results and the same files as plain EPANET.
    "$B/run-pure" "$inp" "${mode:--}" "$B/$fx.pure" >"$B/$fx.pure.txt" 2>"$B/$fx.pure.err"
    rc_p=$?
    if [ $rc_c -ne $rc_p ]; then
        bad "$fx pure" "exit c=$rc_c pure=$rc_p" "$(head -1 "$B/$fx.pure.err")"
    elif [ $rc_c -eq 0 ]; then
        if cmp -s "$B/$fx.c.txt" "$B/$fx.pure.txt"; then
            ok "$fx pure results bit-exact"
        elif diff=$(same "$B/$fx.c.txt" "$B/$fx.pure.txt"); then
            ok "$fx pure results within $TOL"
        else
            bad "$fx pure results" "$diff" "diff $B/$fx.c.txt $B/$fx.pure.txt"
        fi
        check_files "$fx" pure
    else
        ok "$fx pure fails as EPANET does"
    fi

    "$B/run-shadow" "$inp" "${mode:--}" >/dev/null 2>"$B/$fx.shadow.err"
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

# check_parse FIXTURE — read one network with EPANET's reader and with the
# Odin reader (cmd/dumpnet) and judge the two prints of the project.
check_parse() {
    inp=$1
    fx=$(basename "$inp" .inp)
    "$B/dumpnet-c" "$inp" "$B/$fx.dump.rpt" >"$B/$fx.dump.c.txt" 2>&1
    "$B/dumpnet-odin" "$inp" >"$B/$fx.dump.odin.txt" 2>&1
    if cmp -s "$B/$fx.dump.c.txt" "$B/$fx.dump.odin.txt"; then
        ok "$fx parse bit-exact ($(wc -l <"$B/$fx.dump.c.txt") lines)"
    else
        bad "$fx parse" "$(diff "$B/$fx.dump.c.txt" "$B/$fx.dump.odin.txt" | head -5)" "diff $B/$fx.dump.c.txt $B/$fx.dump.odin.txt"
    fi
    # the same file as a Model (load) built back into a project: nothing lost
    "$B/dumpnet-odin" --model "$inp" >"$B/$fx.dump.model.txt" 2>&1
    if cmp -s "$B/$fx.dump.odin.txt" "$B/$fx.dump.model.txt"; then
        ok "$fx model round trip bit-exact"
    else
        bad "$fx model round trip" "$(diff "$B/$fx.dump.odin.txt" "$B/$fx.dump.model.txt" | head -5)" "diff $B/$fx.dump.odin.txt $B/$fx.dump.model.txt"
    fi
}

# check_api FIXTURE — the Odin API (cmd/run: load, sim_from_model, a loop
# of sim_step) must print what the toolkit prints of the same file, and
# the Model written back (cmd/inp) must be the file the toolkit writes.
check_api() {
    inp=$1
    fx=$(basename "$inp" .inp)
    if [ -f "$B/$fx.pure.txt" ] && grep -q '^massbalance' "$B/$fx.pure.txt"; then
        "$B/run-api" "$inp" >"$B/$fx.api.txt" 2>"$B/$fx.api.err"
        if cmp -s "$B/$fx.pure.txt" "$B/$fx.api.txt"; then
            ok "$fx api results bit-exact"
        elif diff=$(same "$B/$fx.pure.txt" "$B/$fx.api.txt"); then
            ok "$fx api results within $TOL"
        else
            bad "$fx api results" "$diff $(head -1 "$B/$fx.api.err")" "diff $B/$fx.pure.txt $B/$fx.api.txt"
        fi
    fi
    if [ -f "$B/$fx.rb.pure.orig.inp" ]; then
        "$B/inp-api" "$inp" "$B/$fx.api.inp" 2>"$B/$fx.api.inp.err"
        if cmp -s "$B/$fx.rb.pure.orig.inp" "$B/$fx.api.inp"; then
            ok "$fx api .inp identical"
        elif diff=$(same "$B/$fx.rb.pure.orig.inp" "$B/$fx.api.inp"); then
            ok "$fx api .inp within $TOL"
        else
            bad "$fx api .inp" "$diff $(head -1 "$B/$fx.api.inp.err")" "diff $B/$fx.rb.pure.orig.inp $B/$fx.api.inp"
        fi
    fi
}

# check_rebuild FIXTURE [files] — the editing API: read the network, build
# it again through EN_init and the setters on each side, run and print,
# write both projects as .inp, read the rebuilt one back and run that too.
# With `files`, only the two .inp files are judged.
check_rebuild() {
    inp=$1
    fx=$(basename "$inp" .inp)
    files_only=${2:-}
    "$B/rebuild-c" "$inp" "$B/$fx.rb.c" >"$B/$fx.rb.c.txt" 2>"$B/$fx.rb.c.err"
    rc_c=$?
    "$B/rebuild-pure" "$inp" "$B/$fx.rb.pure" >"$B/$fx.rb.pure.txt" 2>"$B/$fx.rb.pure.err"
    rc_p=$?
    if [ $rc_c -ne 0 ] && grep -q 'open rebuilt' "$B/$fx.rb.c.err"; then
        # EPANET cannot read a file it wrote (a FILLTIME premise in h:m:s);
        # the port can. Judge what comes before the re-read.
        sed -i '/^reread /,$d' "$B/$fx.rb.c.txt" "$B/$fx.rb.pure.txt"
        skip "$fx re-read (EPANET refuses its own file: $(grep -m1 'EPANET error' "$B/$fx.rb.c.err" | sed 's/.*rebuild: //'))"
        rc_c=0
        rc_p=0
    fi
    if [ $rc_c -ne $rc_p ]; then
        bad "$fx rebuild" "exit c=$rc_c pure=$rc_p" "$(head -1 "$B/$fx.rb.pure.err")"
        return
    fi
    if [ -n "$files_only" ]; then
        :
    elif [ $rc_c -ne 0 ]; then
        skip "$fx rebuild ($(grep -m1 'EPANET error' "$B/$fx.rb.c.err" | sed 's/.*rebuild: //'))"
    elif cmp -s "$B/$fx.rb.c.txt" "$B/$fx.rb.pure.txt"; then
        ok "$fx rebuild results bit-exact ($(wc -l <"$B/$fx.rb.c.txt") lines)"
    elif diff=$(same "$B/$fx.rb.c.txt" "$B/$fx.rb.pure.txt"); then
        ok "$fx rebuild results within $TOL"
    else
        bad "$fx rebuild results" "$diff" "diff $B/$fx.rb.c.txt $B/$fx.rb.pure.txt"
    fi
    for what in orig rebuilt; do
        [ -f "$B/$fx.rb.c.$what.inp" ] || continue
        if cmp -s "$B/$fx.rb.c.$what.inp" "$B/$fx.rb.pure.$what.inp"; then
            ok "$fx $what .inp identical ($(wc -l <"$B/$fx.rb.c.$what.inp") lines)"
        elif diff=$(same "$B/$fx.rb.c.$what.inp" "$B/$fx.rb.pure.$what.inp"); then
            ok "$fx $what .inp within $TOL"
        else
            bad "$fx $what .inp" "$diff" "diff $B/$fx.rb.c.$what.inp $B/$fx.rb.pure.$what.inp"
        fi
    done
}

for inp in $FIXTURES; do
    check_parse "$inp"
    if [ "$(fixture_kind "$(basename "$inp" .inp)")" = parse ]; then
        skip "$(basename "$inp" .inp) hydraulics (no stable solution: read and written back only)"
        check_rebuild "$inp" files
    else
        check "$inp" ""
        check "$inp" stepq
        check_rebuild "$inp"
    fi
    check_api "$inp"
done

# the API's own road: networks laid in code (cmd/check)
"$B/check-api" >"$B/check.txt" 2>&1
while IFS= read -r line; do
    case $line in
    "ok "*) ok "api ${line#ok }" ;;
    "bad "*) bad "api ${line#bad }" "" "$B/check-api" ;;
    *) bad "api check" "$line" "$B/check-api" ;;
    esac
done <"$B/check.txt"

# the wasm build's road: the same network through epanet.js, in Node
if ! command -v wasm-ld >/dev/null; then
    skip "wasm bare road (no wasm-ld: install lld)"
elif command -v node >/dev/null; then
    "$B/check-api" --reference >"$B/check.ref.txt" 2>&1
    if node wasm/check.mjs "$B/epanet.wasm" >"$B/check.wasm.txt" 2>"$B/check.wasm.err"; then
        if cmp -s "$B/check.ref.txt" "$B/check.wasm.txt"; then
            ok "wasm bare road bit-exact"
        elif diff=$(TOL=$WASM_TOL same "$B/check.ref.txt" "$B/check.wasm.txt"); then
            ok "wasm bare road within $WASM_TOL ($(wc -l <"$B/check.ref.txt") lines, node $(node --version))"
        else
            bad "wasm bare road" "$diff" "diff $B/check.ref.txt $B/check.wasm.txt"
        fi
    else
        bad "wasm bare road" "$(head -3 "$B/check.wasm.err")" "node wasm/check.mjs $B/epanet.wasm"
    fi
else
    skip "wasm bare road (no node)"
fi


tally "epanet-odin"
