#!/usr/bin/env bash
#
# Build a V10 toolchain inside V8 and compile V10 programs with it.
#
#	tools/v10-toolchain.sh [image]
#
# Serves the imported V10 tree read-only, a scratch directory read/write, and
# drives the guest through tools/v10-toolchain.exp -- see that file for what
# is being assembled and why.
#
# The image is a CLONE, always: booting a disk mounts it and mounting rewrites
# the superblock, so even a clean run leaves a different hash than the golden.
# `cp -c' is an APFS clone -- no time, no space.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-rp07new}"
IMG="rp07v10tc"
TPORT="${TPORT:-9210}"
SPORT="${SPORT:-9211}"
TREE="$ROOT/work/v10"
SCRATCH="$ROOT/work/v10tc"
NETFSD="$ROOT/netfs/.build/release/netfsd"
TREE_PID=""; SCRATCH_PID=""

cleanup() {
    for pid in "$TREE_PID" "$SCRATCH_PID"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    true
}
trap cleanup EXIT

[[ -d "$TREE" ]] || { echo "v10-toolchain: no $TREE -- run tools/v10-import.py"; exit 1; }
if pgrep -x vax780 >/dev/null; then
    echo "v10-toolchain: a vax780 is already running -- wait for it"; exit 1
fi

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) || exit 1
[[ -x "$NETFSD" ]] || { echo "v10-toolchain: netfsd did not build"; exit 1; }

echo "== laying out the scratch share at $SCRATCH =="
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"

# The one source that is OURS rather than V10's, and it is deliberately a
# real #include: this is the first thing compiled by the assembled toolchain,
# so it should exercise cpp finding a header and ccom digesting it -- not just
# ccom on a .i, which the probe already proved.
cat > "$SCRATCH/hello.c" <<'EOF'
#include <stdio.h>

main()
{
	printf("hello from the Tenth Edition\n");
	return 0;
}
EOF

echo "== cloning $SRC -> $IMG =="
rm -f "$ROOT/work/myv8/$IMG"
cp -c "$ROOT/work/myv8/$SRC" "$ROOT/work/myv8/$IMG" || exit 1

echo "== serving the V10 tree on 127.0.0.1:$TPORT (read-only) =="
"$NETFSD" -p "$TPORT" "$TREE" > "$ROOT/work/netfs-v10tree.log" 2>&1 &
TREE_PID=$!
echo "== serving scratch on 127.0.0.1:$SPORT (read/write) =="
"$NETFSD" -p "$SPORT" -w "$SCRATCH" > "$ROOT/work/netfs-v10tc.log" 2>&1 &
SCRATCH_PID=$!
sleep 1
for pid in "$TREE_PID" "$SCRATCH_PID"; do
    kill -0 "$pid" 2>/dev/null || { echo "netfsd died:"; tail -5 "$ROOT"/work/netfs-v10*.log; exit 1; }
done

echo "== driving the guest =="
expect "$ROOT/tools/v10-toolchain.exp" "$IMG" "$TPORT" "$SPORT" 2>&1 \
    | tee "$ROOT/work/v10-toolchain.log"
rc=${PIPESTATUS[0]}

echo
echo "== what came back to the host =="
ls -l "$SCRATCH"
for f in "$SCRATCH"/hello "$SCRATCH"/hello2 "$SCRATCH"/ld "$SCRATCH"/ld10; do
    [[ -s "$f" ]] && { printf '%-8s ' "$(basename "$f")"; xxd -l 4 "$f" | awk '{print $2,$3}'; }
done
# ld built by V8's cc and ld built by V10's cc are different compilers on the
# same source, so they are NOT expected to match byte for byte. Both linking
# the same working hello is the claim; print the sizes so the difference is
# visible rather than assumed either way.
echo "== v10-toolchain exit $rc =="
exit "$rc"
