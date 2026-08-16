#!/usr/bin/env bash
#
# Stage 1 of the Tenth Edition bootstrap: the toolchain, rebuilt on V10.
#
#	tools/v10-stage1.sh [v10-image] [src-image]
#
# The stage order is V8's, from docs/build-from-source.md:
#
#	1  the toolchain      <-- this
#	2  libc
#	3  the toolchain again, with stage 2's libc -- the fixpoint
#	4  headers   5  libraries   6  commands   7  kernel   8  disk
#	9  the new system rebuilds itself under chroot
#
# and it is V8's order because the user asked for V10's bootstrap to be based
# on V8's, which was got right the expensive way.
#
# WHAT THIS RUN CHANGES.  Three binaries.  The golden's ccom, as and libc.a
# are Bell Labs' own 1995 VAX executables off the tape; its cpp, c2 and ld
# were compiled by the EIGHTH Edition's cc, because until the K phase there
# was no V10 to run a compiler on.  Stage 1 replaces those three with ones
# V10 built, which is the whole of "you can't be mixing v8 and v10 apps".
#
# BOTH DISKS ARE CLONES.  The V10 golden is cloned because a stage run writes
# to it by design -- object trees, installed binaries, a rewritten /etc -- and
# because there is no committed V10 image to restore from if it is spoiled;
# recovery is a half-hour tools/v10-golden.sh.  See tools/v10clone.sh.
#
# The source disk is NOT cloned: it is mounted read-write but only read, and
# rebuilding it is a five-minute tools/v10-srcdisk.sh.  If that ever stops
# being true, clone it too.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v10clone.sh"

GOLD="${1:-ipnx-v10-ra81.img}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"

[[ -f "$SRC" ]] || { echo "v10-stage1: no $SRC -- run tools/v10-srcdisk.sh"; exit 1; }
[[ -f "$ROOT/work/v10boot/uda750" ]] || { echo "v10-stage1: no uda750 -- run tools/v10-uda750.py"; exit 1; }
pgrep -f "BIN/vax750" >/dev/null && { echo "v10-stage1: a vax750 is already running"; exit 1; }

python3 "$ROOT/v10/mk/mkdep.py" --check || { echo "regenerate the makefiles first"; exit 1; }

IMG=$(v10_clone "$GOLD" stage1) || exit 1
echo "== stage 1 on $(basename "$IMG") =="
echo "   source disk $SRC"
echo

expect "$ROOT/tools/v10-stage1.exp" "$IMG" "$SRC" 2>&1 | tee "$ROOT/work/v10-stage1.log"
rc=${PIPESTATUS[0]}

echo
echo "   the stage-1 machine is $IMG"
echo "   sha256 $(shasum -a 256 "$IMG" | cut -c1-16)"
echo "== v10-stage1 exit $rc =="
exit "$rc"
