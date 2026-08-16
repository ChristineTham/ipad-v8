#!/usr/bin/env bash
#
# Put a userland in the V10 filesystem, so the kernel has something to exec.
# Phase K5.
#
#	tools/v10-userland.sh [image]
#
# Four shares, because the point is that the build reads each from its own
# place and the makefiles say which:
#
#	/n/v10       work/v10          the pristine tarball tree (read-only)
#	/n/v10ours   v10/src           our corrections (read-only)
#	/n/v10mk     v10/mk/gen        the generated makefiles (read-only)
#	/n/t         work/v10mk        scratch, for the log (read/write)
#
# See tools/v10-userland.exp for what is being asserted.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v8clone.sh"

TPORT="${TPORT:-9250}"; OPORT="${OPORT:-9251}"
MPORT="${MPORT:-9252}"; SPORT="${SPORT:-9253}"
SCRATCH="$ROOT/work/v10ul"
NETFSD="$ROOT/netfs/.build/release/netfsd"
PIDS=()

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    true
}
trap cleanup EXIT

[[ -d "$ROOT/work/v10" ]] || { echo "v10-make: no work/v10 -- run tools/v10-import.py"; exit 1; }
if pgrep -x vax780 >/dev/null; then
    echo "v10-make: a vax780 is already running -- wait for it"; exit 1
fi

# The generator and the overlay have to be in step with the tree, exactly as
# the V8 driver insists: a stale makefile is the one failure that looks like
# a source bug.
python3 "$ROOT/tools/v10-overlay.py" --check || { echo "v10-make: regenerate the overlay first"; exit 1; }
python3 "$ROOT/v10/mk/mkdep.py" --check      || { echo "v10-make: regenerate the makefiles first"; exit 1; }

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) || exit 1
[[ -x "$NETFSD" ]] || { echo "v10-make: netfsd did not build"; exit 1; }

rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
IMG=$(v8_clone "${1:-rp07new}" userland) || exit 1
echo "== booting the clone $IMG =="

serve() {   # serve <port> <dir> <logname> [-w]
    "$NETFSD" -p "$1" ${4:-} "$2" > "$ROOT/work/netfs-$3.log" 2>&1 &
    PIDS+=($!)
}
serve "$TPORT" "$ROOT/work/v10"   v10tree
serve "$OPORT" "$ROOT/v10/src"    v10ours
serve "$MPORT" "$ROOT/v10/mk/gen" v10mkgen
serve "$SPORT" "$SCRATCH"         v10mkscratch -w
sleep 1
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || { echo "netfsd died:"; tail -5 "$ROOT"/work/netfs-v10*.log; exit 1; }
done

echo "== driving the guest =="
expect "$ROOT/tools/v10-userland.exp" "$IMG" "$TPORT" "$OPORT" "$MPORT" "$SPORT" 2>&1 \
    | tee "$ROOT/work/v10-make.log"
rc=${PIPESTATUS[0]}

if [[ -s "$SCRATCH/make.log" ]]; then
    echo
    echo "== what make said, where it was not just a compile =="
    grep -E "Don't know how to make|Stop\.|cannot |not found|Undefined" \
         "$SCRATCH/make.log" | sort -u | head -20
fi
echo "== v10-make exit $rc =="
exit "$rc"
