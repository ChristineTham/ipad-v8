#!/usr/bin/env bash
#
# Does the Tenth Edition boot path compile?  Phase B2.0.
#
#	tools/v10-bootpath.sh [image]
#
# Serves the imported V10 tree read-only and a scratch directory read/write,
# assembles the B1 toolchain, and tries to build the seventeen programs B3 is
# blocked on -- twice, once against V8's headers and once against r70's.  See
# tools/v10-bootpath.exp for what is being asked and why.
#
# The deliverable is work/v10bp/bootpath.log: every compiler diagnostic, in
# order, carried back from the guest.  The ok/NO table says which builds
# failed; only that log says why, and why is the whole point of the phase.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v8clone.sh"

TPORT="${TPORT:-9220}"
SPORT="${SPORT:-9221}"
TREE="$ROOT/work/v10"
SCRATCH="$ROOT/work/v10bp"
NETFSD="$ROOT/netfs/.build/release/netfsd"
TREE_PID=""; SCRATCH_PID=""

cleanup() {
    for pid in "$TREE_PID" "$SCRATCH_PID"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    true
}
trap cleanup EXIT

[[ -d "$TREE" ]] || { echo "v10-bootpath: no $TREE -- run tools/v10-import.py"; exit 1; }
if pgrep -x vax780 >/dev/null; then
    echo "v10-bootpath: a vax780 is already running -- wait for it"; exit 1
fi

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) || exit 1
[[ -x "$NETFSD" ]] || { echo "v10-bootpath: netfsd did not build"; exit 1; }

echo "== laying out the scratch share at $SCRATCH =="
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"

IMG=$(v8_clone "${1:-rp07new}" bootpath) || exit 1
echo "== booting the clone $IMG =="

echo "== serving the V10 tree on 127.0.0.1:$TPORT (read-only) =="
"$NETFSD" -p "$TPORT" "$TREE" > "$ROOT/work/netfs-v10tree.log" 2>&1 &
TREE_PID=$!
echo "== serving scratch on 127.0.0.1:$SPORT (read/write) =="
"$NETFSD" -p "$SPORT" -w "$SCRATCH" > "$ROOT/work/netfs-v10bp.log" 2>&1 &
SCRATCH_PID=$!
sleep 1
for pid in "$TREE_PID" "$SCRATCH_PID"; do
    kill -0 "$pid" 2>/dev/null || { echo "netfsd died:"; tail -5 "$ROOT"/work/netfs-v10*.log; exit 1; }
done

echo "== driving the guest =="
expect "$ROOT/tools/v10-bootpath.exp" "$IMG" "$TPORT" "$SPORT" 2>&1 \
    | tee "$ROOT/work/v10-bootpath.log"
rc=${PIPESTATUS[0]}

echo
echo "== what came back =="
ls -l "$SCRATCH"
if [[ -s "$SCRATCH/bootpath.log" ]]; then
    echo
    echo "== diagnostics, classified =="
    # Which stage refused each build.  cpp says "Can't find include file";
    # ccom says "syntax error" or names a line; ld says "Undefined".  The
    # distinction is the whole diagnostic value of the run, so it is drawn
    # here rather than left to be eyeballed in 400 lines of log.
    awk '
        /^##### / { hdr = $2 " " $3 " " $4; seen[hdr] = 1; next }
        /Can.t find include file/ { if (!c[hdr]++) print "  CPP   " hdr ": " $0; next }
        /^Undefined/              { if (!u[hdr]++) print "  LD    " hdr ": undefined symbols"; next }
        /syntax error|redeclared|illegal|cannot|Cannot/ {
                                    if (!e[hdr]++) print "  CCOM  " hdr ": " $0; next }
    ' "$SCRATCH/bootpath.log"
fi
echo "== v10-bootpath exit $rc =="
exit "$rc"
