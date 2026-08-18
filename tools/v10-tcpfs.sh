#!/usr/bin/env bash
# K12.1: netfs over TCP on V10 -- the transport half of K12.
#
#	bash tools/v10-tcpfs.sh [k7-on-k102-image] [src-image]
#
# K12.0 proved the client, the protocol library and fmount(2) all work by mounting
# over a PIPE.  This does the same mount on a TCP connection to netfsd, which is
# the server this project has had since the N track -- see tools/v10-tcpfs.exp's
# header for why netafs and not netbfs, and for the three preconditions the N track
# paid for.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/srcid.sh"

for fn in srcid_check no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-tcpfs: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

GOLD="${1:-ipnx-v10-ra81.img.stage1.k102.k7}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
PORT="${PORT:-9260}"
EXPORT="$ROOT/work/v10tcpfs"
NETFSD="$ROOT/netfs/.build/release/netfsd"
LOG="$ROOT/work/v10-tcpfs.log"
SRV_PID=""

cleanup() {
    if [[ -n "$SRV_PID" ]] && kill -0 "$SRV_PID" 2>/dev/null; then
        kill "$SRV_PID" 2>/dev/null
        wait "$SRV_PID" 2>/dev/null
    fi
    true
}
trap cleanup EXIT

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-tcpfs: no $GOLD -- build it with"
    echo "       bash tools/v10-libs.sh"
    echo "       bash tools/v10-kernel.sh ipnx-v10-ra81.img.stage1.k102"
    exit 1
}
python3 "$ROOT/tools/v10-overlay.py" --check || {
    echo "v10-tcpfs: the overlay index is stale -- run tools/v10-overlay.py"
    exit 1
}
srcid_check "$SRC" || {
    echo "v10-tcpfs: the source disk is stale -- bash tools/v10-srcdisk.sh"
    exit 1
}

# The export, with one file of known content so the read assertion has something
# to be right about.  A directory listing can be satisfied by an empty directory;
# a byte of content cannot.
rm -rf "$EXPORT"; mkdir -p "$EXPORT"
printf 'hello from the host, over TCP, to the Tenth Edition\n' > "$EXPORT/hello.txt"

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) >/dev/null || exit 1
[[ -x "$NETFSD" ]] || { echo "netfsd did not build"; exit 1; }

echo "== starting netfsd on 127.0.0.1:$PORT =="
"$NETFSD" -p "$PORT" -v "$EXPORT" > "$ROOT/work/netfs-tcpfs.log" 2>&1 &
SRV_PID=$!
sleep 1
kill -0 "$SRV_PID" 2>/dev/null || {
    echo "netfsd died:"; cat "$ROOT/work/netfs-tcpfs.log"; exit 1
}
# HOW MANY LINES THE SERVER WRITES BEFORE ANY GUEST EXISTS.  netfsd -v prints a
# startup banner, so `test -s' on its log is true from the first second and the
# "the guest never reached the server" branch below could never fire -- an
# unfailable check, and this one sat directly under a comment saying assert
# traffic and not files.  Measured now, compared after.
BANNER=$(wc -l < "$ROOT/work/netfs-tcpfs.log")

no_overlap "$SRC" "$ROOT/work/v10gold/$GOLD" || exit 1

IMG=$(v10_clone "$GOLD" k12t) || exit 1
SRCIMG=$(v10_clone "$SRC" k12tsrc) || exit 1
echo "== netfs over TCP on $(basename "$IMG") =="

expect "$ROOT/tools/v10-tcpfs.exp" "$IMG" "$SRCIMG" "$PORT" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ASSERT TRAFFIC, NOT FILES -- the N track's own rule, and the only check that
# would have caught either of the two faults that hid behind each other in 2026-08.
# netfsd -v traces every request, so its log is the independent witness: if the
# guest reached it at all, there is a line here, and if it did not, no amount of
# guest-side output means anything.
echo
echo "== what netfsd saw =="
AFTER=$(wc -l < "$ROOT/work/netfs-tcpfs.log")
if (( AFTER > BANNER )); then
    printf '   %d lines of request trace, past the %d-line startup banner\n' \
        "$(( AFTER - BANNER ))" "$BANNER"
    sed -e "1,${BANNER}d" -e 20q "$ROOT/work/netfs-tcpfs.log" | sed -e 's/^/   /'
else
    echo "   NOTHING.  The guest never reached the server, so the failure is on"
    echo "   the guest side of the connection -- read the assertions above for"
    echo "   which precondition stopped it, and note that tcpconfig not being"
    echo "   pushed onto an ip device makes connect() block with no diagnostic."
fi


# THE CROSS-CHECK, BECAUSE TWO READINGS OF THE SAME TTY ARE ONE READING.  The
# guest's assertions and this log are independent instruments: the guest cannot
# have mounted a filesystem the server never served.  A pass here with a silent
# server means the guest matched something it should not have.
if [[ "$rc" == 0 ]] && (( AFTER <= BANNER )); then
    echo
    echo "== NO MEASUREMENT: the guest reported a mount and the server saw nothing =="
    echo "   Every assertion passed and netfsd logged no request, which cannot both"
    echo "   be true.  Suspect a guest-side match on the wrong string."
    rc=1
fi

echo
echo "== K12.1: NETFS OVER TCP =="
if [[ "$rc" == 0 ]]; then
    echo "   V10 mounted a host directory over TCP, with V10's own netafs client"
    echo "   and this project's own netfs server.  That retires the courier disk."
else
    echo "   Not yet.  The assertions above are ordered so that the first NO names"
    echo "   the step that stopped it: the Interlan, the device nodes, tcpconfig,"
    echo "   the mounter's build, or the mount itself."
fi
echo
echo "   the machine is $IMG"
echo "   full transcript $LOG"
echo "== v10-tcpfs exit $rc =="
exit "$rc"
