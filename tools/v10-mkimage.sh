#!/usr/bin/env bash
#
# Make a Tenth Edition root filesystem with Tenth Edition tools.  Phase K2.
#
#	tools/v10-mkimage.sh [image]
#
# Four shares, because the point is that the build reads each from its own
# place and the makefiles say which:
#
#	/n/v10       work/v10          the pristine tarball tree (read-only)
#	/n/v10ours   v10/src           our corrections (read-only)
#	/n/v10mk     v10/mk/gen        the generated makefiles (read-only)
#	/n/t         work/v10mk        scratch, for the log (read/write)
#
# See tools/v10-mkimage.exp for what is being asserted.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v8clone.sh"

TPORT="${TPORT:-9240}"; OPORT="${OPORT:-9241}"
SPORT="${SPORT:-9243}"
SCRATCH="$ROOT/work/v10img"
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
IMG=$(v8_clone "${1:-rp07new}" mkimage) || exit 1

# The target: a blank image the guest writes a V10 filesystem into through a
# RAW device.  Recreated every run -- mkbitfs does not clear what it does not
# use, and this artefact is meant to be reproducible.
TARGET="$ROOT/work/myv8/v10root.img"
echo "== creating a blank $TARGET =="
rm -f "$TARGET"
dd if=/dev/zero of="$TARGET" bs=1m count=456 2>/dev/null || exit 1
echo "== booting the clone $IMG =="

serve() {   # serve <port> <dir> <logname> [-w]
    "$NETFSD" -p "$1" ${4:-} "$2" > "$ROOT/work/netfs-$3.log" 2>&1 &
    PIDS+=($!)
}
serve "$TPORT" "$ROOT/work/v10"   v10tree
serve "$OPORT" "$ROOT/v10/src"    v10ours
serve "$SPORT" "$SCRATCH"         v10mkscratch -w
sleep 1
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || { echo "netfsd died:"; tail -5 "$ROOT"/work/netfs-v10*.log; exit 1; }
done

echo "== driving the guest =="
expect "$ROOT/tools/v10-mkimage.exp" "$IMG" "$TPORT" "$OPORT" "$SPORT" 2>&1 \
    | tee "$ROOT/work/v10-make.log"
rc=${PIPESTATUS[0]}

if [[ -s "$SCRATCH/superblock.bin" ]]; then
    echo
    echo "== the superblock mkbitfs wrote =="
    true
fi
echo "== v10-make exit $rc =="
exit "$rc"

# s_valid = 1 is what says this is the BITMAPPED variant; the free-list form
# never sets it.  Decoded here rather than trusted, because "mkbitfs exited 0"
# and "mkbitfs wrote a bitmapped superblock" are different claims.
if [[ -s "$SCRATCH/superblock.bin" ]]; then
    python3 - "$SCRATCH/superblock.bin" <<'PYEOF'
import struct, sys
d = open(sys.argv[1], "rb").read()
sb = d[512:]                      # superblock lives in block 1
isize, fsize = struct.unpack_from("<HI", sb, 0)
print(f"  s_isize = {isize} i-list blocks")
print(f"  s_fsize = {fsize} blocks")
PYEOF
fi
