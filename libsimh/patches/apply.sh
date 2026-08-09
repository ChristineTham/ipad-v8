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

# Let the VAX-780 idle at all.
#
# sim_idle() sleeps only if the unit at the *head* of the event queue is
# UNIT_IDLE. On this machine two units are permanently near the head, 100
# times a second each, and neither carries the flag:
#
#   clk_unit (TODR) -- the calibrated 100 Hz clock; clk_svc reactivates it
#     every 10 ms for as long as the machine runs.
#   tmr_unit (TMR)  -- the programmable interval timer, which V8 (like every
#     other VAX Unix) sets to 10 ms and leaves running, so tmr_sched
#     coschedules it onto the same tick forever.
#
# So `set cpu idle=4.1BSD` can match V8's idle loop perfectly and still buy
# almost nothing: measured here, 100% of sim_idle()'s refusals at an idle
# login prompt named one of these two.
#
# clk_unit is a plain omission. Every other VAX in the tree sets UNIT_IDLE on
# it -- including the 730 and 750, whose TOY-clock unit is byte-identical
# (`UDATA (&clk_svc, UNIT_FIX, sizeof(TOY))` + the same
# sim_rtcn_init_unit(&clk_unit, CLK_DELAY, TMR_CLK)) and which are declared
# UNIT_IDLE+UNIT_FIX. Only 780, 820 and 860 drop it: one omission copied
# twice, not a decision about those machines.
#
# tmr_unit is missing the flag on all five big VAXen (730/750/780/820/860 --
# exactly the models that have a separate interval timer; the MicroVAX-class
# models fold it into clk_unit and mark that idle-capable). Sleeping until the
# guest's own tick is precisely what idling means, and the flag is safe by
# construction: UNIT_IDLE is read nowhere in SIMH except sim_idle() and the
# SHOW QUEUE label, and sim_idle() is only ever reached from cpu_idle(), i.e.
# when the guest is already executing its recognised do-nothing loop.
#
# We patch the 780 because that is the model ipnx ships; the same two one-word
# fixes apply to the other big VAXen.
python3 - "$SIMH" <<'PY'
import sys, pathlib

p = pathlib.Path(sys.argv[1]) / "VAX" / "vax780_stddev.c"
s = p.read_text()
edits = [
    ("UNIT clk_unit = { UDATA (&clk_svc, UNIT_FIX, sizeof(TOY))};",
     "UNIT clk_unit = { UDATA (&clk_svc, UNIT_IDLE+UNIT_FIX, sizeof(TOY))};",
     "clk_unit (TODR)"),
    ("UNIT tmr_unit = { UDATA (&tmr_svc, 0, 0) };",
     "UNIT tmr_unit = { UDATA (&tmr_svc, UNIT_IDLE, 0) };",
     "tmr_unit (TMR)"),
]
for old, new, what in edits:
    if new in s:
        print("apply: vax780 %s already UNIT_IDLE" % what)
    elif old in s:
        s = s.replace(old, new, 1)
        print("apply: vax780 %s now UNIT_IDLE" % what)
    else:
        sys.exit("apply: vax780 %s declaration not found -- upstream changed?" % what)
p.write_text(s)
PY

# Let a restored DZ line still receive.
#
# tmxr's per-line receive enable, lp->rcve, lives in the TMLN -- runtime state
# that no snapshot records. The DZ sets it in exactly one place: when the guest
# writes LPR (pdp11_dz.c, case 01). A guest that already has the line open has
# no reason to write LPR again, so after `restore` the line comes back with
# rcve = 0 and tmxr_poll_rx skips it forever (sim_tmxr.c: "(conn || txbfd) &&
# rcve"). Everything typed at the terminal is dropped in silence; the line
# looks perfectly healthy -- connected, DCD/CTS/DSR asserted, the guest still
# polling MSR from its clock routine -- and never carries another byte.
#
# In ipnx that is the whole "resumed session shows a blinking cursor and
# pressing RETURN does nothing" symptom: it is the 5620's line, not the 5620.
#
# The fix belongs in dz_attach, which already carries the restore-aware fixup
# for the *other* direction -- re-asserting DTR/RTS from the restored CSR/TCR
# for lines the guest had open. This extends that same judgement to receive:
# a line the guest has open is a line that should be listening. The block only
# runs when CSR_MSE is already set, which on a cold attach it never is, so a
# fresh boot is untouched.
python3 - "$SIMH" <<'PY'
import sys, pathlib

p = pathlib.Path(sys.argv[1]) / "PDP11" / "pdp11_dz.c"
s = p.read_text()
old = """    if (!dz_mctl || (0 == (dz_csr[dz] & CSR_MSE)))      /* enabled? */
        continue;
    for (muxln = 0; muxln < DZ_LINES; muxln++) {
        if (dz_tcr[dz] & (1 << (muxln + TCR_V_DTR))) {
            TMLN *lp = &dz_ldsc[(dz * DZ_LINES) + muxln];

            tmxr_set_get_modem_bits (lp, TMXR_MDM_DTR|TMXR_MDM_RTS, 0, NULL);
            }
        }
"""
new = """    if (0 == (dz_csr[dz] & CSR_MSE))                    /* scanner enabled? */
        continue;
    for (muxln = 0; muxln < DZ_LINES; muxln++) {
        TMLN *lp = &dz_ldsc[(dz * DZ_LINES) + muxln];

        if (dz_mctl && (0 == (dz_tcr[dz] & (1 << (muxln + TCR_V_DTR)))))
            continue;                                   /* guest has it hung up */
        /* lp->rcve is TMLN state, which no snapshot records, and the guest
           only ever sets it by writing LPR -- which it will not do again on a
           line it already has open.  Without this a restored line silently
           drops everything typed at it forever. */
        lp->rcve = 1;
        if (dz_mctl)
            tmxr_set_get_modem_bits (lp, TMXR_MDM_DTR|TMXR_MDM_RTS, 0, NULL);
        }
"""
if new in s:
    print("apply: dz rcve restore patch already applied")
elif old in s:
    p.write_text(s.replace(old, new, 1))
    print("apply: dz_attach now restores per-line receive enable")
else:
    sys.exit("apply: dz_attach modem-restore block not found -- upstream changed?")
PY

echo "apply: done"
