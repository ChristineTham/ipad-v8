#!/bin/bash
# Apply every ipnx patch to a clean open-simh checkout. Idempotent.
#
#   libsimh/patches/apply.sh [path-to-opensimh]
#
# work/opensimh is a clone that build-xcframework.sh can recreate at any time,
# so nothing may be edited in place and survive; the patches live here.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIMH="${1:-$ROOT/work/opensimh}"

"$ROOT/libsimh/patches/apply-il.sh" "$SIMH"

# Let a telnet console idle.
#
# SIMH refuses to idle whenever the next scheduled event belongs to a unit
# without UNIT_IDLE (sim_timer.c, sim_idle). sim_con_poll_svc reschedules
# itself every second for as long as a telnet or serial console is configured,
# and sim_con_unit is declared without UNIT_IDLE -- so a simulator with
# `set console telnet=` spins at 100% while an idle-capable one next to it
# sleeps. Measured on V8: ~25% of a core with a local console, ~100% with a
# telnet console, same guest sitting at the same login prompt.
#
# This looks like an oversight rather than a decision: sim_console.c already
# sets UNIT_IDLE explicitly on both *remote* console units a few hundred lines
# further down. Keystroke latency is unaffected either way, because console
# input arrives through tti_unit (which is UNIT_IDLE and polls at the clock
# rate), not through this connection poll.
python3 - "$SIMH" <<'PY'
import sys, pathlib

p = pathlib.Path(sys.argv[1]) / "sim_console.c"
s = p.read_text()
old = "UNIT sim_con_units[2] = {{ UDATA (&sim_con_poll_svc, UNIT_ATTABLE, 0)}};"
new = "UNIT sim_con_units[2] = {{ UDATA (&sim_con_poll_svc, UNIT_ATTABLE|UNIT_IDLE, 0)}};"
if new in s:
    print("apply: console idle patch already applied")
elif old in s:
    p.write_text(s.replace(old, new, 1))
    print("apply: sim_con_unit now UNIT_IDLE")
else:
    sys.exit("apply: sim_con_units declaration not found -- upstream changed?")
PY

echo "apply: done"
