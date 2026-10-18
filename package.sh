#!/usr/bin/env bash
# package.sh — build the toolkit library, dumpnet and run, and tar them up for a release.
#
#   ./package.sh <version> <platform>     build/epanet-odin-<version>-<platform>.tar.gz
#   ./package.sh v0.1.0 linux-amd64 -v    name each step
#   ODIN=/opt/odin/odin ./package.sh …    where the compiler is (default: PATH)
#   EPANET=../EPANET ./package.sh …       an EPANET checkout, for the headers
#                                         (default: ./epanet-c, cloned on demand)
#
# What goes in:
#   lib/libepanet-api.a    EN_* with the C ABI over the Odin engine — links
#                          wherever libepanet2.a does (-lm with it)
#   include/               epanet2_2.h and epanet2_enums.h, EPANET's own: the
#                          API is EPANET's, so the headers are too (MIT; its
#                          licence is beside them)
#   bin/dumpnet            reads an .inp and prints the project
#   bin/run                runs an .inp through the Odin API and prints every result
#   wasm/epanet.wasm       the engine for JavaScript, with wasm/epanet.js to load it
#   LICENSE, README.md
# Not in it: the Odin package epanet/ — an Odin program takes the source.
#
# The library is linked the way a user links it (harness/run.c against the
# packaged headers and lib) and run on EPANET's Net1 before the tar is made.
# .github/workflows/release.yml runs this on a v* tag, once per platform,
# after harness/test.sh has passed on Linux, and publishes the tarballs.
set -uo pipefail

cd "$(dirname "$0")"
. harness/out.sh

args=()
for a in "$@"; do
    debug_flag "$a" || args+=("$a")
done
[ "${#args[@]}" -eq 2 ] || usage "need a version and a platform"
version=${args[0]}
platform=${args[1]}

ODIN=${ODIN:-odin}
CC=${CC:-clang}
EP=${EPANET:-epanet-c}
EPANET_COMMIT=444725fbf16ab28b0470ef0ed281dc4849d49583   # OWA EPANET 2.3 dev
B=build
name="epanet-odin-$version-$platform"
P="$B/$name"

command -v "$ODIN" >/dev/null || usage "odin compiler not found (ODIN=$ODIN); see README.md"
if [ ! -f "$EP/include/epanet2_2.h" ]; then
    note "cloning OWA EPANET @ ${EPANET_COMMIT:0:7} into $EP"
    run git clone -q https://github.com/OpenWaterAnalytics/EPANET.git "$EP" &&
        run git -C "$EP" checkout -q "$EPANET_COMMIT" ||
        usage "could not fetch EPANET into $EP (set EPANET= to a checkout)"
fi

rm -rf "$P" "$P.tar.gz"
mkdir -p "$P/lib" "$P/include" "$P/bin"

if run "$ODIN" build api -build-mode:static -out:"$P/lib/libepanet-api.a" \
        -no-entry-point -o:speed -vet -strict-style; then
    ok "lib/libepanet-api.a"
else
    bad "odin build api"
fi
if run "$ODIN" build cmd/dumpnet -out:"$P/bin/dumpnet" -o:speed -vet -strict-style; then
    ok "bin/dumpnet"
else
    bad "odin build dumpnet"
fi
if run "$ODIN" build cmd/run -out:"$P/bin/run" -o:speed -vet -strict-style; then
    ok "bin/run"
else
    bad "odin build run"
fi
mkdir -p "$P/wasm"
command -v wasm-ld >/dev/null || usage "wasm-ld not found (the lld package; brew install lld on macOS): the wasm build needs it"
if run "$ODIN" build wasm -target:freestanding_wasm32 -out:"$P/wasm/epanet.wasm" -no-entry-point -o:speed -vet -strict-style &&
        cp wasm/epanet.js "$P/wasm/"; then
    ok "wasm/epanet.wasm epanet.js"
else
    bad "odin build wasm"
fi
if cp "$EP/include/epanet2_2.h" "$EP/include/epanet2_enums.h" "$P/include/" &&
        cp "$EP/LICENSE" "$P/include/LICENSE-EPANET" && cp LICENSE README.md "$P/"; then
    ok "include/ LICENSE README.md"
else
    bad "copy headers, LICENSE, README.md"
fi
[ "$_fail" -eq 0 ] || { tally "package"; exit 1; }

# Linked the way a user links it, and run.
if run "$CC" -O2 -w -I"$P/include" harness/run.c "$P/lib/libepanet-api.a" -lm -o "$B/run-packaged" &&
        "$B/run-packaged" "$EP/example-networks/Net1.inp" >"$B/run-packaged.txt" 2>&1 &&
        grep -q '^massbalance ' "$B/run-packaged.txt"; then
    ok "links and runs Net1"
else
    bad "link check" "$(tail -3 "$B/run-packaged.txt" 2>/dev/null)"
fi

if run tar czf "$P.tar.gz" -C "$B" "$name"; then
    ok "$P.tar.gz ($(du -h "$P.tar.gz" | cut -f1))"
else
    bad "tar $P.tar.gz"
fi
tally "package"
