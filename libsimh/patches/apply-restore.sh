#!/bin/bash
# `restore' must attempt EVERY attach, not stop at the first failure.
#
#   libsimh/patches/apply-restore.sh [path-to-opensimh]
#
# THE BUG, in scp.c's restore path:
#
#	for (j=0, r = SCPE_OK; j<attcnt; j++) {
#	    if ((r == SCPE_OK) && (!dont_detach_attach)) {
#	        ...
#	        r = scp_attach_unit (dptr, attunits[j], attnames[j]);
#
# `r' is assigned by the attach inside the loop and never reset, and the loop
# body is gated on it. So the FIRST failure silently skips every remaining
# attach -- the machine comes back with only the units that happened to
# precede the failure.
#
# WHY THAT IS SEVERE HERE RATHER THAN UNTIDY. The DZ precedes RP0 in device
# order, and tmxr binds without SO_REUSEADDR, so a quick relaunch hits the
# previous incarnation's TIME_WAIT pairs and the DZ attach fails -- after
# which the DISK is never attached at all. The console still answers (the
# kernel is in memory) and the shell still echoes `# ' from memory, so it
# presents as a terminal gone quiet, which is nothing like the truth: exec
# SIGKILLs, login never reaches a shell, getty is stuck.
#
# Filed upstream as open-simh/simh#576. simh/simh already does the right
# thing; this is the one concrete cherry-pick from that codebase, expressed
# as a patch because work/opensimh is a clone build-xcframework.sh can
# recreate at any time.
#
# The fix keeps `r' as the worst-status-so-far for the caller and uses a
# separate per-iteration status to decide and report, so every unit is tried
# and every failure is named as it happens.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIMH="${1:-$ROOT/work/opensimh}"

python3 - "$SIMH" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "scp.c"
s = p.read_text()

old = """for (j=0, r = SCPE_OK; j<attcnt; j++) {
    if ((r == SCPE_OK) && (!dont_detach_attach)) {
        struct stat fstat;
        t_addr saved_pos;
"""
new = """for (j=0, r = SCPE_OK; j<attcnt; j++) {
    /* ipnx: every unit gets its attempt.  This used to read
       `if ((r == SCPE_OK) && ...)', and r is assigned by the attach below and
       never reset -- so one failure skipped every remaining attach.  With the
       DZ ahead of RP0 in device order, a bind failure on a quick relaunch
       therefore restored a machine with NO DISK, and said so only about the
       DZ.  See open-simh/simh#576. */
    if (!dont_detach_attach) {
        struct stat fstat;
        t_addr saved_pos;
        t_stat ar;
"""
if new in s:
    print("   already applied")
    raise SystemExit

if old not in s:
    raise SystemExit("   restore attach loop not found -- upstream changed?")
s = s.replace(old, new, 1)

# Inside the body: use the per-iteration status, and fold it into r so the
# caller still learns that something failed.
old2 = """            if (fstat.st_mtime > rstat.st_mtime + 30) {
                r = SCPE_INCOMP;"""
new2 = """            if (fstat.st_mtime > rstat.st_mtime + 30) {
                if (r == SCPE_OK) r = SCPE_INCOMP;"""
if old2 not in s:
    raise SystemExit("   mtime sanity check not found")
s = s.replace(old2, new2, 1)

old3 = """        r = scp_attach_unit (dptr, attunits[j], attnames[j]);/* reattach unit */
        attunits[j]->pos = saved_pos;
        if (r != SCPE_OK)
            sim_printf ("Error Attaching %s to %s\\n", sim_dname (dptr), attnames[j]);"""
new3 = """        ar = scp_attach_unit (dptr, attunits[j], attnames[j]);/* reattach unit */
        attunits[j]->pos = saved_pos;
        if (ar != SCPE_OK) {
            sim_printf ("Error Attaching %s to %s\\n", sim_dname (dptr), attnames[j]);
            if (r == SCPE_OK) r = ar;           /* remember, but keep going */
            }"""
if old3 not in s:
    raise SystemExit("   attach call site not found")
s = s.replace(old3, new3, 1)

p.write_text(s)
print("   restore now attempts every attach and reports each failure")
PY

echo "apply-restore: done"
