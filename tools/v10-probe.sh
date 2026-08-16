#!/usr/bin/env bash
#
# The V10 binary-compatibility probe, as one command.
#
#	tools/v10-probe.sh [image]
#
# Serves the imported V10 tree read-only, a scratch directory read/write, and
# drives the guest through tools/v10-probe.exp.  See that file for what is
# being asked and why.
#
# THE IMAGE IS A CLONE, ALWAYS.  Booting a disk mounts it and mounting
# rewrites the superblock, so even a clean, correctly halted run leaves a
# different hash than the golden in git.  `cp -c' is an APFS clone: no time,
# no space.  The clone is left behind on purpose -- if the probe found
# something, the disk it found it on should still exist.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-rp07new}"
IMG="rp07v10probe"
TPORT="${TPORT:-9210}"
SPORT="${SPORT:-9211}"
TREE="$ROOT/work/v10"
SCRATCH="$ROOT/work/v10probe"
NETFSD="$ROOT/netfs/.build/release/netfsd"
TREE_PID=""; SCRATCH_PID=""

cleanup() {
    for pid in "$TREE_PID" "$SCRATCH_PID"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    true
}
trap cleanup EXIT

[[ -d "$TREE" ]] || { echo "v10-probe: no $TREE -- run tools/v10-import.py"; exit 1; }
if pgrep -x vax780 >/dev/null; then
    echo "v10-probe: a vax780 is already running -- wait for it"; exit 1
fi

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) || exit 1
[[ -x "$NETFSD" ]] || { echo "v10-probe: netfsd did not build"; exit 1; }

echo "== laying out the scratch share at $SCRATCH =="
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
# Content the guest asserts on, so a mount that succeeds and reads nothing
# cannot pass for a working one.
echo "V10-FIXTURE" > "$SCRATCH/fixture.txt"

# The fixtures live here rather than being echoed into the guest, and that is
# not laziness: expect and 1985 sh each have their own opinion about
# backslashes, so a C string with an escape in it passes through two layers of
# quoting before ccom ever sees it.  On the share it is just a file.
#
# A .i is post-cpp by definition, so this includes nothing.  write(2) rather
# than printf keeps the link down to one libc member and one syscall -- if
# this fails, the failure is the compiler or the ABI, not stdio.
cat > "$SCRATCH/t.i" <<'EOF'
char msg[] = "V10-COMPILED-AND-RUN\n";

main()
{
	write(1, msg, sizeof msg - 1);
	return 0;
}
EOF

# One instruction and a label, which is all that is needed to tell an
# assembler that starts from one that does not.
cat > "$SCRATCH/t.s" <<'EOF'
	.globl	_probe
_probe:
	ret
EOF

echo "== cloning $SRC -> $IMG =="
rm -f "$ROOT/work/myv8/$IMG"
cp -c "$ROOT/work/myv8/$SRC" "$ROOT/work/myv8/$IMG" || exit 1

echo "== serving the V10 tree on 127.0.0.1:$TPORT (read-only) =="
"$NETFSD" -p "$TPORT" "$TREE" > "$ROOT/work/netfs-v10tree.log" 2>&1 &
TREE_PID=$!
echo "== serving scratch on 127.0.0.1:$SPORT (read/write) =="
"$NETFSD" -p "$SPORT" -w "$SCRATCH" > "$ROOT/work/netfs-v10scratch.log" 2>&1 &
SCRATCH_PID=$!
sleep 1
for pid in "$TREE_PID" "$SCRATCH_PID"; do
    kill -0 "$pid" 2>/dev/null || { echo "netfsd died:"; tail -5 "$ROOT"/work/netfs-v10*.log; exit 1; }
done

echo "== driving the guest =="
expect "$ROOT/tools/v10-probe.exp" "$IMG" "$TPORT" "$SPORT" 2>&1 | tee "$ROOT/work/v10-probe.log"
rc=${PIPESTATUS[0]}

echo
echo "== what came back to the host =="
ls -l "$SCRATCH"
for f in "$SCRATCH"/a.out "$SCRATCH"/t.o "$SCRATCH"/crt0.o; do
    [[ -s "$f" ]] && { printf '%s: ' "$(basename "$f")"; xxd -l 8 "$f" | head -1; }
done
echo "== v10-probe exit $rc =="
exit "$rc"
