#!/usr/bin/env bash
#
# Run the Tenth Edition golden image and hand you its console.
#
#	tools/v10-run.sh [image] [port]
#
# Starts a VAX-11/750 with the image attached, boots V10 multi-user, and puts
# the console on a telnet port so you can log in from your own terminal:
#
#	nc localhost 5610
#
# WHY TELNET AND NOT THE TERMINAL THIS RUNS IN.  A local-tty console makes ^E
# SIMH's stop character, so a stray one drops the machine to `sim>' with the
# guest still running.  On a telnet console ^E is an ordinary data byte --
# docs/a1-notes.md has the full table of which channel does what.
#
# WHY NOT THE ipnx APP.  The app is built around V8's machine: an RP07 on a
# Massbus, eight DZ lines, and a 5620 on line 0.  This is a 750 with an MSCP
# disk, and its kernel is seki, which has a `cometcons' console.  Making the
# app boot V10 is real work -- a second simulator in libsimh, a second media
# path, and the two-goldens design in docs/roadmap.md's B5 -- and none of it
# is needed to log in today.
#
# YOUR CLIENT MUST KEEP ITS STDIN OPEN.  SIMH treats a lost console as fatal
# -- `Console Telnet connection lost' and the simulator stops -- so a client
# that closes the socket takes the machine with it.  `nc localhost 5610' from
# a terminal is fine, because the terminal keeps stdin open.  `nc ... </dev/null'
# is not: nc exits on EOF, and the machine dies before the kernel banner.
# That cost several runs here, all of which looked like the guest crashing.
#
# HOW TO STOP IT.  Log in and `/etc/halt', then `pkill -f vax750'.  There is
# no clean-shutdown promise here: this image is reproducible in one command
# (tools/v10-golden.sh), which is why it is safe to be casual with.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-$ROOT/work/v10gold/ipnx-v10-ra81.img}"
PORT="${2:-5610}"
CONF=$(mktemp /tmp/v10run.XXXXXX.conf)

[[ -f "$IMG" ]] || { echo "v10-run: no $IMG -- run tools/v10-golden.sh"; exit 1; }
[[ -f "$ROOT/work/v10boot/uda750" ]] || { echo "v10-run: no uda750 -- run tools/v10-uda750.py"; exit 1; }
pgrep -f "vax750" >/dev/null && { echo "v10-run: a vax750 is already running"; exit 1; }

cat > "$CONF" <<EOF
set cpu 8m
set rq0 ra81
attach rq0 $IMG
set dz enable
set dz lines=8
set console telnet=$PORT
load -o $ROOT/work/v10boot/uda750 FA00
dep sp 200
dep r1 0
dep r3 0
dep r5 0
run FA02
EOF

echo "== Research UNIX Tenth Edition, on a VAX-11/750 =="
echo "   image  $IMG"
echo "   sha256 $(shasum -a 256 "$IMG" | cut -c1-16)"
echo
echo "   connect with:   nc localhost $PORT"
echo "   log in as:      root   (no password)"
echo
echo "   /bin and /etc hold what we built from source; /usr/bin holds the"
echo "   1995 binaries off the tape.  /usr is a separate filesystem mounted"
echo "   by /etc/rc.  Try:  ls /usr/bin | wc -l"
echo
"$ROOT/work/opensimh/BIN/vax750" "$CONF"
rm -f "$CONF"
