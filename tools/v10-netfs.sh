#!/usr/bin/env bash
# K12.0: netfs on V10, over a pipe.  The decisive measurement before the phase.
#
#	bash tools/v10-netfs.sh [k7-on-k102-image] [src-image]
#
# See tools/v10-netfs.exp's header for what this separates and why it comes first.
# The short form: V10 ships `runfs', which mounts a netfs filesystem on a PIPE via
# fmount(2), so the client and the protocol can be tested with no network at all.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/srcid.sh"

for fn in srcid_check no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-netfs: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

# THE IMAGE IS THE WHOLE PRECONDITION AND IT IS A COMPOUND ONE.  This run needs
# BOTH halves: our 780 kernel, because seki configures `netbfs 0' and cannot mount
# one at all; and K10.2's /usr/lib/libnetb.a, because zarf links against it.  One
# image has both, and it is K7's output built on top of K10.2's:
#
#	bash tools/v10-kernel.sh ipnx-v10-ra81.img.stage1.k102
#
# which leaves ipnx-v10-ra81.img.stage1.k102.k7 behind.  Stages chain this way
# throughout -- .stage1 -> .s2 -> .s2.s3 -- so this is the convention and not a
# special case.
GOLD="${1:-ipnx-v10-ra81.img.stage1.k102.k7}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
LOG="$ROOT/work/v10-netfs.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-netfs: no $GOLD in work/v10gold."
    echo "   K12 needs one image carrying BOTH our 780 kernel and K10.2's"
    echo "   libnetb.a.  Build it with:"
    echo "       bash tools/v10-libs.sh"
    echo "       bash tools/v10-kernel.sh ipnx-v10-ra81.img.stage1.k102"
    exit 1
}
[[ -x "$ROOT/work/opensimh/BIN/vax780" ]] || {
    echo "v10-netfs: no work/opensimh/BIN/vax780 -- the 780 is what has the"
    echo "   NI1010 and what our kernel is built for."
    exit 1
}
python3 "$ROOT/v10/mk/mkdep.py" --check || {
    echo "v10-netfs: the makefiles are stale -- run v10/mk/mkdep.py"
    exit 1
}
srcid_check "$SRC" || {
    echo "v10-netfs: the source disk is stale -- bash tools/v10-srcdisk.sh"
    exit 1
}
python3 "$ROOT/tools/v10-free.py" "$ROOT/work/v10gold/$GOLD" c --need 4000 || {
    echo "v10-netfs: not enough room on $GOLD."
    exit 1
}

no_overlap "$SRC" "$ROOT/work/v10gold/$GOLD" || exit 1

IMG=$(v10_clone "$GOLD" k12) || exit 1
SRCIMG=$(v10_clone "$SRC" k12src) || exit 1
echo "== netfs over a pipe on $(basename "$IMG") =="

expect "$ROOT/tools/v10-netfs.exp" "$IMG" "$SRCIMG" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

echo
# THE ONE FAILURE MODE THAT WOULD NOT LOOK LIKE ONE.  A netbfs mount on a kernel
# with zero instances fails with a bare errno, and `Invalid argument' from
# fmount(2) reads as a bad argument rather than as a kernel that cannot do this at
# all.  Naming it here means a wrong image says so in one line.
if grep -qE 'fmount|Invalid argument' "$LOG" 2>/dev/null; then
    echo "   NOTE: fmount(2) complained.  If the mount failed, check FIRST that"
    echo "   the running kernel is ours: seki configures netafs 0 and netbfs 0,"
    echo "   so it has the filesystem TYPES with no instances and every mount"
    echo "   fails whatever the userland does."
    grep -m3 -B1 -A2 -E 'fmount|Invalid argument' "$LOG" | sed -e 's/^/     /'
    echo
fi

# THE VERDICT KEYS ON THE DECISIVE ASSERTIONS, NOT ON THE EXIT STATUS.  Keyed on
# rc, one cosmetic assertion failing printed "the pipe mount did NOT work" over a
# transcript in which /n/local listed V10's own /usr, stdio.h read back and a file
# written through the pipe appeared on the served side.  A summary that contradicts
# its own evidence is worse than none.
decisive=0
grep -qE 'lists the served tree +ok' "$LOG" 2>/dev/null && decisive=$((decisive+1))
grep -qE 'reads back through the pipe +ok' "$LOG" 2>/dev/null && decisive=$((decisive+1))
grep -qE 'write goes through and reads back +ok' "$LOG" 2>/dev/null && decisive=$((decisive+1))

echo "== K12.0: WHAT A PIPE MOUNT SETTLES =="
if (( decisive == 3 )); then
    echo "   The netfs CLIENT, the netb protocol library and fmount(2) all work on"
    echo "   V10, with our kernel's netbfs instances.  So the rest of K12 is"
    echo "   TRANSPORT and nothing else: the Interlan, an address for it, and a"
    echo "   stream discipline underneath the same mount call."
else
    echo "   The pipe mount did NOT work ($decisive of 3 decisive assertions), so"
    echo "   no amount of transport work would have helped -- the client half is"
    echo "   where K12 has to start."
fi
if [[ "$rc" != 0 ]] && (( decisive == 3 )); then
    echo
    echo "   (The run still exits nonzero: something else in it failed, and that"
    echo "    is reported above rather than being absorbed into this verdict.)"
fi
echo
echo "   the machine is $IMG"
echo "   full transcript $LOG"
echo "== v10-netfs exit $rc =="
exit "$rc"
