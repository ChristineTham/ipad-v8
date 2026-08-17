#!/usr/bin/env bash
# Stage 3: the fixpoint.  Rebuild the toolchain against stage 2's libc, then
# rebuild it again with itself, and compare stripped binaries.
#
#	bash tools/v10-stage3.sh [stage2-image] [src-image]
#
# The whole argument for what is required and what is merely strong is in
# tools/v10-stage3.exp's header.  The short form: stage 3 == stage 3b is the
# test; stage 1 == stage 3 is a measurement that is EXPECTED to differ, because
# stage 1 linked the tape's libc.a and stage 3 links ours.
#
# THE CLONE RULE AND THE OVERLAP GUARD BOTH APPLY, and both are sourced rather
# than restated.  This stage installs stage 2's libc.a over /lib/libc.a on the
# machine it runs on -- see the .exp header for why V10's cc leaves no choice --
# so it MUST have its own copy of the image.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/srcid.sh"

GOLD="${1:-ipnx-v10-ra81.img.stage1.s2}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
LOG="$ROOT/work/v10-stage3.log"

[[ -f "$SRC" ]] || { echo "v10-stage3: no $SRC -- run tools/v10-srcdisk.sh"; exit 1; }
[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-stage3: no $GOLD -- run tools/v10-stage2.sh first, and note that"
    echo "            stage 2 leaves its machine behind on purpose."
    exit 1
}
[[ -f "$ROOT/work/v10boot/uda750" ]] || { echo "v10-stage3: no uda750 -- run tools/v10-uda750.py"; exit 1; }

no_overlap "$SRC" "$ROOT/work/v10gold/$GOLD" || exit 1

python3 "$ROOT/v10/mk/mkdep.py" --check || { echo "regenerate the makefiles first"; exit 1; }

# AND IS THE DISK CARRYING THEM?  --check above proves the repo's generated
# makefiles are current; it says nothing about the copies on the source disk,
# which is what the guest actually reads.  Both questions have to be asked.
srcid_check "$SRC" || exit 1

IMG=$(v10_clone "$GOLD" s3) || exit 1
SRCIMG=$(v10_clone "$SRC" s3src) || exit 1
echo "== stage 3 on $(basename "$IMG") =="
echo "   source disk $(basename "$SRCIMG")"
echo

expect "$ROOT/tools/v10-stage3.exp" "$IMG" "$SRCIMG" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ----------------------------------------------------------- the measurement ---
#
# Counted host-side for the reason every other stage counts host-side: there is
# no `wc' on this machine and arithmetic in its shell is not worth the trouble.
echo
echo "== stage 3, the fixpoint =="
fx_ok=$(grep -c 'FIXPOINT.*ok$' "$LOG" 2>/dev/null || true)
fx_no=$(grep -c 'FIXPOINT.*NO$' "$LOG" 2>/dev/null || true)
printf '   components reproducing themselves   %s\n' "${fx_ok:-0}"
printf '   components that do NOT              %s\n' "${fx_no:-0}"
if [[ "${fx_no:-0}" != "0" ]]; then
    echo "   -> NOT a fixpoint.  Every later stage would inherit whichever"
    echo "      generation it happened to be built by, so this is the one"
    echo "      result in stage 3 that must be zero."
fi

echo
echo "== stage 1 vs stage 3 (a measurement, not a test) =="
# UNANCHORED, and counted by NAME rather than by line.  Two bugs lived in the
# three anchored `grep -c' lines that stood here:
#
#   ^SAME dropped a spliced verdict.  v10_run's first line of output shares a
#   tty line with the tail of the echoed command, so a real result can arrive as
#   `MSAME yacc'.  The same anchor in v10-stage2.sh hid `MISS atof.o' for a
#   whole round, and stage 3 was what finally reported it -- as ccom and as
#   failing to link with `Undefined: _atof'.
#
#   `grep -c' PRINTS 0 AND EXITS 1 when it matches nothing, so `|| echo 0'
#   appended a second zero and the report read
#	byte-identical to stage 1           0
#	0
#   Harmless, and exactly the kind of thing that trains a reader to skim past
#   the numbers.  `|| true' is what that idiom wanted.
#
# Unanchored is only safe because the verdicts now go through guest variables
# (`echo $S $name'), so no command echo carries the literal token -- see the
# note beside `S=SAME' in v10-stage3.exp.
s3count() {
    tr -d '\r' < "$LOG" | grep -oE "$1 [A-Za-z_0-9]+" | sort -u | grep -c . || true
}
printf '   byte-identical to stage 1           %s\n' "$(s3count SAME)"
printf '   differ                              %s\n' "$(s3count DIFF)"
printf '   no stage-1 binary to compare        %s\n' "$(s3count NOS1)"
echo "   Differences are EXPECTED: stage 1 linked the tape's libc.a and stage 3"
echo "   links ours, and only 143 of the tape's 261 members are byte-identical."

echo
echo "   the stage-3 machine is $IMG"
echo "   sha256 $(shasum -a 256 "$IMG" | cut -c1-16)"
echo "== v10-stage3 exit $rc =="
exit "$rc"
