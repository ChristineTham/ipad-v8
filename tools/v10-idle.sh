#!/usr/bin/env bash
# Does `set cpu idle=4.1BSD' make the Tenth Edition idle?  A/B, one variable.
#
#	bash tools/v10-idle.sh [image]
#
# The iPad question.  V8's SIMH thread sits at 2.7% at a login prompt because
# `set cpu idle=4.1BSD' plus three UNIT_IDLE flags let sim_idle() sleep; no V10
# harness has ever set an idle pattern, and the measured consequence is a core
# burned throughout (43:20 of CPU in 44:24 elapsed).  On a desktop that is
# merely rude.  On a battery it is the difference between shipping and not.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"
for fn in no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || { echo "v10-idle: $fn undefined"; exit 2; }
done

GOLD="${1:-ipnx-v10-made.img}"
[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-idle: no work/v10gold/$GOLD -- bash tools/v10-mkdisk.sh builds it"
    exit 1
}
LOG="$ROOT/work/v10-idle.log"
: > "$LOG"

for mode in off on; do
    no_overlap || exit 1
    IMG=$(v10_clone "$GOLD" "idle$mode") || exit 1
    echo "== idle=$mode ==" | tee -a "$LOG"
    expect "$ROOT/tools/v10-idle.exp" "$IMG" "$mode" 2>&1 | tee -a "$LOG"
done

echo
echo "== DOES set cpu idle=4.1BSD WORK ON V10? =="
grep 'IDLE-RESULT' "$LOG" | sed 's/^/   /'
off=$(grep 'IDLE-RESULT off' "$LOG" | sed -n 's/.*: \([0-9.]*\)%.*/\1/p')
on=$(grep 'IDLE-RESULT on'  "$LOG" | sed -n 's/.*: \([0-9.]*\)%.*/\1/p')
if [[ -n "${off:-}" && -n "${on:-}" ]]; then
    # A ratio, not a difference: what matters is whether the core comes back.
    awk -v a="$off" -v b="$on" 'BEGIN {
        printf "   idle off %.1f%%  ->  idle on %.1f%%", a, b
        if (a > 20 && b < a / 4) print "   IT WORKS"
        else if (b < a * 0.9)    print "   some effect, not decisive"
        else                     print "   NO EFFECT -- the pattern does not match"
    }'
else
    echo "   no measurement -- see $LOG"
fi
echo "   full transcript $LOG"
