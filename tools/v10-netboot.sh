#!/usr/bin/env bash
# K13: give V10 a network of its own, and prove it comes up by itself.
#
#	bash tools/v10-netboot.sh [k7-image] [src-image]
#
# WHY THIS EXISTS.  K12 proved the transport by building every piece of it on the
# spot -- mknod, the device nodes, dipconfig, tcpconfig, nafsmnt -- on every run.
# That is an experiment, not a machine.  This installs them, teaches /etc/rc to
# bring the interface up, and then BOOTS AGAIN to check that it did: the second
# boot compiles nothing.
#
# Two shares are served, the tape and our overlay, because that is what every
# later phase actually reads -- and once they mount from an installed command,
# tools/v10-srcdisk.sh and the fourteen minutes it costs stop being on the path.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/srcid.sh"

for fn in srcid_check no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-netboot: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

GOLD="${1:-ipnx-v10-ra81.img.stage1.k102.k7}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
TPORT="${TPORT:-9280}"; OPORT="${OPORT:-9281}"
NETFSD="$ROOT/netfs/.build/release/netfsd"
LOG="$ROOT/work/v10-netboot.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-netboot: no $GOLD in work/v10gold -- bash tools/v10-kernel.sh builds it."
    exit 1
}
python3 "$ROOT/tools/v10-overlay.py" --check || exit 1
python3 "$ROOT/v10/mk/mkdep.py"      --check || exit 1
srcid_check "$SRC" || {
    echo "v10-netboot: the source disk is stale -- bash tools/v10-srcdisk.sh"
    exit 1
}

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) >/dev/null || exit 1
[[ -x "$NETFSD" ]] || { echo "netfsd did not build"; exit 1; }

# READ-ONLY, DELIBERATELY.  These are the source trees every stage compiles from;
# a guest that can write to them is a guest that can corrupt the repository, and
# the V8 side has the same rule.  K12's write path is proven separately.
PIDS=()
serve() { "$NETFSD" -p "$1" -v "$2" > "$ROOT/work/netfs-$3.log" 2>&1 & PIDS+=($!); }
serve "$TPORT" "$ROOT/work/v10"  nbtree
serve "$OPORT" "$ROOT/v10/src"   nbours
sleep 1
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || {
        echo "netfsd died:"; tail -5 "$ROOT"/work/netfs-nb*.log; exit 1; }
done
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done' EXIT

BANNER=$(cat "$ROOT/work/netfs-nbtree.log" "$ROOT/work/netfs-nbours.log" | wc -l)

no_overlap "$SRC" "$ROOT/work/v10gold/$GOLD" || exit 1
IMG=$(v10_clone "$GOLD" k13) || exit 1
SRCIMG=$(v10_clone "$SRC" k13src) || exit 1

echo "== provisioning $(basename "$IMG"), then booting it again =="
expect "$ROOT/tools/v10-netboot.exp" "$IMG" "$SRCIMG" "$TPORT" "$OPORT" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# THE INDEPENDENT WITNESS, measured against the banner rather than `test -s' --
# netfsd -v writes a startup line, so a non-empty log is true from the first
# second and would make this branch unfailable.
AFTER=$(cat "$ROOT/work/netfs-nbtree.log" "$ROOT/work/netfs-nbours.log" | wc -l)
echo
echo "== what the servers saw =="
if (( AFTER > BANNER )); then
    printf '   %d lines of request trace past the %d-line banner\n' \
        "$(( AFTER - BANNER ))" "$BANNER"
    grep -hE 'connection|NSTART|mounted' "$ROOT"/work/netfs-nb*.log | sed -e 8q -e 's/^/   /'
else
    echo "   NOTHING.  Neither share was reached, so the failure is on the guest"
    echo "   side -- read the assertions above for which step stopped it."
    rc=1
fi

echo
echo "== K13: DOES V10 NETWORK BY ITSELF? =="
if [[ "$rc" == 0 ]]; then
    echo "   Yes.  The second boot compiled nothing: /etc/rc brought the interface"
    echo "   up, and two source trees mounted with one installed command each."
    echo "   tools/v10-srcdisk.sh is no longer on the path for reading source."
else
    echo "   Not yet.  The assertions are ordered so the first NO names the step:"
    echo "   the install, /etc/rc, the second boot, or the mount."
fi
echo "   the machine is $IMG"
echo "   full transcript $LOG"
echo "== v10-netboot exit $rc =="
exit "$rc"
