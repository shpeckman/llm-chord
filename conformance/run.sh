#!/bin/sh
# conformance/run.sh
# Usage: CHORD_SRC=/path/to/pi/packages/chord/src/index.ts conformance/run.sh
# Needs Node 22+ with typebox 1.3.27 resolvable from the chord package, and Crystal.
set -eu
cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/llm-chord-conformance"
mkdir -p "$out"
crystal build crystal_worker.cr -o "$out/crystal_worker"
crystal build crystal_server.cr -o "$out/crystal_server"
CRYSTAL_WORKER="$out/crystal_worker" node --experimental-strip-types --conditions=source node_parent.ts
CRYSTAL_SERVER="$out/crystal_server" node --experimental-strip-types --conditions=source node_browser.ts
