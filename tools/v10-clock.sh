#!/usr/bin/env bash
# Is the V10 guest STARVED, or is netfs merely slow?  Two boots, one number each.
#
#	bash tools/v10-clock.sh [image]
#
# THE QUESTION.  netfsd serves the V10 guest at ~9.6 s per request, and K15 then
# spent forty-five minutes compiling its FIRST object -- work that is almost
# entirely guest CPU, since the source is read once and the rest of its headers
# are local.  Network latency cannot explain a slow compile, so the 9.6 s may be
# a symptom rather than the cause.
#
# THE TEST.  A fixed amount of local guest work, timed by the HOST, with the
# Interlan attached and then disabled.  Same image, same work, one variable.
#
#	similar times   -> not starved; the 9.6 s is real network latency
#	much slower on  -> starved by the device model's polling, and the netfs
#	                   rate is a symptom
#
# WHY NOT JUST LOOK AT CPU.  The V10 config never sets `set cpu idle', so the
# simulator burns a core either way -- 100% is the expected reading and carries no
# information.  Hence a stopwatch.
#
# NO NETWORK IS NEEDED FOR EITHER ARM, so this runs no netfsd and mounts nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"

for fn in no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-clock: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

GOLD="${1:-ipnx-v10-ra81.img.stage1.k102.k7.k13}"
LOG="$ROOT/work/v10-clock.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-clock: no $GOLD"
    exit 1
}

# TRUNCATE FIRST.  A predicate a stale file can satisfy is how a completed,
# consistent, forty-minute-old report gets read as this run's -- CLAUDE.md
# records that costing a whole scheduling decision.
: > "$LOG"

rc=0
for arm in on off; do
    no_overlap "$ROOT/work/v10gold/$GOLD" || exit 1
    IMG=$(v10_clone "$GOLD" "clk$arm") || exit 1
    echo "== il $arm ==" | tee -a "$LOG"
    # ONE AT A TIME, and never backgrounded: two simulators must never run at
    # once, and the arms share the same base image.
    expect "$ROOT/tools/v10-clock.exp" "$IMG" "$arm" 2>&1 | tee -a "$LOG"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || rc=1
done

echo
echo "== the answer =="
# Unanchored, because v10_run's first line of output shares a line with the tty's
# echo of the command that produced it -- an anchored grep in v10-stage2.sh hid a
# missing libc member for a week.
on=$(tr -d '\r' < "$LOG" | grep -oE "CLOCKPROBE il=on median=[0-9]+"  | grep -oE "[0-9]+$" | tail -1)
off=$(tr -d '\r' < "$LOG" | grep -oE "CLOCKPROBE il=off median=[0-9]+" | grep -oE "[0-9]+$" | tail -1)

if [[ -z "${on:-}" || -z "${off:-}" ]]; then
    echo "   one arm produced no median (on='${on:-}' off='${off:-}') -- read $LOG"
    exit 1
fi

printf '   il on   %8s ms\n' "$on"
printf '   il off  %8s ms\n' "$off"
python3 - "$on" "$off" <<'PY'
import sys
on, off = int(sys.argv[1]), int(sys.argv[2])
ratio = on / off if off else 0
print(f"   ratio    {ratio:8.2f}x")
print()
if ratio >= 2.0:
    print("   STARVED.  The same local work costs materially more with the card")
    print("   attached, so the guest is losing cycles to the device model rather")
    print("   than waiting on the network.  The ~9.6 s netfs figure is a SYMPTOM.")
    print("   Look at il_svc()'s sim_activate(uptr, 1000) burst and the eth_read()")
    print("   host select() it performs on every one of those service calls.")
elif ratio <= 1.3:
    print("   NOT STARVED.  Local work costs the same either way, so the guest is")
    print("   executing fine and the ~9.6 s per netfs request is real latency.")
    print("   Then `show il stats' decides whether it is dropped frames (receive")
    print("   errors near the request count) or something else entirely.")
else:
    print("   INCONCLUSIVE at this ratio.  Raise REPS in v10-clock.exp before")
    print("   drawing anything from it -- two boots of a noisy measurement is not")
    print("   a result, and CLAUDE.md already records netfs-latency.sh having ~50%")
    print("   run-to-run variance.")
PY
exit $rc
