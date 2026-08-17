#!/usr/bin/env bash
#
# Stage 2 of the Tenth Edition bootstrap: libc, built on V10.
#
#	tools/v10-stage2.sh [stage1-image] [src-image]
#
# The stage order is V8's, from docs/build-from-source.md:
#
#	1  the toolchain
#	2  libc                          <-- this
#	3  the toolchain again, with stage 2's libc -- the fixpoint
#	4  headers   5  libraries   6  commands   7  kernel   8  disk
#	9  the new system rebuilds itself under chroot
#
# IT STARTS FROM THE STAGE-1 MACHINE, NOT THE GOLDEN.  Stage 1 left its
# compiler under /usr/s1 and installed ar, cmp, ed and tail into the running
# system; this stage needs all of them, and it asserts each one before it
# builds anything so that a run started from the wrong image says so in one
# line rather than in 261 confusing ones.
#
# THE CLONE RULE APPLIES, and harder than on V8: there is no committed V10
# image to restore from, and recovery is a half-hour tools/v10-golden.sh
# followed by a stage-1 run.  See tools/v10clone.sh.
#
# The source disk is NOT cloned -- it is mounted read-write but only read,
# and rebuilding it is a five-minute tools/v10-srcdisk.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v10clone.sh"

GOLD="${1:-ipnx-v10-ra81.img.stage1}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
LOG="$ROOT/work/v10-stage2.log"

[[ -f "$SRC" ]] || { echo "v10-stage2: no $SRC -- run tools/v10-srcdisk.sh"; exit 1; }
[[ -f "$ROOT/work/v10boot/uda750" ]] || { echo "v10-stage2: no uda750 -- run tools/v10-uda750.py"; exit 1; }
pgrep -f "BIN/vax750" >/dev/null && { echo "v10-stage2: a vax750 is already running"; exit 1; }

python3 "$ROOT/v10/mk/mkdep.py" --check || { echo "regenerate the makefiles first"; exit 1; }

IMG=$(v10_clone "$GOLD" s2) || exit 1
echo "== stage 2 on $(basename "$IMG") =="
echo "   source disk $SRC"
echo

expect "$ROOT/tools/v10-stage2.exp" "$IMG" "$SRC" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ------------------------------------------------------------ the measurement ---
#
# Counted here and not on the guest: V10 has no wc and no grep, and its shell
# has no arithmetic.  The guest's job was to print one line per differing
# member; counting them is the host's.
#
# THIS IS A MEASUREMENT, NOT A PASS/FAIL.  The tape's mkfile builds ten of the
# 261 with `lcc' and we build all 261 with pcc2, so some difference is
# expected and the interesting number is HOW MANY and WHICH.  A hard assertion
# on "all 261 identical" would be a guess dressed as a check.
echo
echo "== stage 2 against the tape's libc.a =="
# Counted from clean lines only.  The guest prints these under v10_run, so no
# marker echo is spliced through them -- see the note in v10-stage2.exp.
# `sort -u' because a name must count once however often it appears.
miss=$(tr -d '\r' < "$LOG" | grep -oE '^MISS [A-Za-z_0-9]+\.o$' | sort -u | grep -c . || true)
diff=$(tr -d '\r' < "$LOG" | grep -oE '^DIFF [A-Za-z_0-9]+\.o$' | sort -u | grep -c . || true)
total=$(grep -c . "$ROOT/v10/mk/gen/libc.ord")
: "${miss:=0}" "${diff:=0}"
# THE TWO SETS OVERLAP, and the first version of this subtracted both and
# printed a negative count.  A member that did not compile has no file, so
# `cmp' against the tape's copy fails for it too -- every MISS is also a DIFF.
# So identical = total - diff, and `miss' is a breakdown of diff, not a
# separate column to subtract.
lccm=$(tr -d '\r' < "$LOG" | grep -oE '^LCCMATCH [A-Za-z_0-9]+\.o$' | sort -u | grep -c . || true)
: "${lccm:=0}"
echo "   members expected                 $total"
echo "   byte-identical, our cc           $(( total - diff ))"
echo "   byte-identical, lcc instead      $lccm"
echo "   ACCOUNTED FOR                    $(( total - diff + lccm ))"
echo "   still unexplained                $(( diff - lccm ))"
echo "     of which: did not compile      $miss"
echo "     of which: compiled, differ     $(( diff - miss ))"
if (( lccm )); then
    echo
    echo "   members whose bytes are LCC's, not cc's:"
    tr -d '\r' < "$LOG" | grep -hoE '^LCCMATCH [A-Za-z_0-9]+\.o$' | sed 's/^LCCMATCH /     /' \
        | sort -u | tr '\n' ' '
    echo
    echo "   -> these belong in LIBC_LCC in v10/mk/mkdep.py: the tape's own"
    echo "      archive says Bell Labs compiled them with lcc."
fi
if (( diff )); then
    echo
    echo "   differing members:"
    grep -hE '^DIFF [A-Za-z_0-9]+\.o' "$LOG" | sed 's/^DIFF /     /' | tr -d '\r' | sort | tr '\n' ' '
    echo
fi
if (( miss )); then
    echo
    echo "   members that did not compile:"
    grep -hE '^MISS [A-Za-z_0-9]+\.o' "$LOG" | sed 's/^MISS /     /' | tr -d '\r' | sort | tr '\n' ' '
    echo
fi

echo
echo "   the stage-2 machine is $IMG"
echo "   sha256 $(shasum -a 256 "$IMG" | cut -c1-16)"
echo "== v10-stage2 exit $rc =="
exit "$rc"
