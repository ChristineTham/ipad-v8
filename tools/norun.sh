# tools/norun.sh -- two simulators must never run at once.  Source; do not run.
#
#	source "$(dirname "${BASH_SOURCE[0]}")/norun.sh"
#	no_other_sims          || exit 1     # before spawning anything
#	claim_images "$IMG" "$SRC" || exit 1 # before attaching them
#
# WHY THIS FILE EXISTS, and it is not hypothetical.  On 2026-08-17 a stage-2
# run and a source-disk rebuild overlapped for the last minute of the stage-2
# run.  tools/v10-srcdisk.sh finishes by doing
#
#	dd if=/dev/zero of=$GOLD/ipnx-v10-src.img ...
#
# and tools/v10-stage2.sh attached THAT PATH, uncloned, as rq1.  So stage 2
# spent its final minutes reading a source disk that was being zeroed and
# rewritten underneath it.
#
# BOTH RUNS EXITED 0.  The srcdisk builder reported 36/36; stage 2 reported a
# full set of numbers, a member list, a DIFF list and four compiler trials --
# all of it measured against an image that had changed mid-run, and none of it
# true.  The only evidence was two mtimes fifty-one seconds apart, found by
# going and looking.  That is the same shape as the V8 golden-drift incident in
# CLAUDE.md: a clean exit status over a corrupted premise.
#
# Christine's rule, 2026-08-17, verbatim: "Always ensure no processes running
# in the background before you start the next round. Last time, you left
# multiple processes running and the disk keeps getting corrupted."  It was
# followed as a habit and not as a check, and a habit is precisely what fails
# across a session boundary.  So it is a check now.
#
# THE TWO GUARDS ARE DIFFERENT QUESTIONS and both are needed.
#   no_other_sims  -- is any simulator running at all?  Catches the case where
#                     the other run's images are ones we do not know about.
#   claim_images   -- is anything holding THESE files?  Catches a `dd', an
#                     editor, a stray python -- anything, not just a VAX.

# no_other_sims
#
# Fails if any open-simh binary is running.  `pgrep -x' on the binary NAMES
# rather than on a path, because harnesses spawn them by absolute path and a
# path match would miss a differently-rooted checkout -- and this repository
# has been moved between machines twice.
#
# VERIFIED AGAINST THE REAL BINARY, because two plausible ways of testing it
# both give a FALSE PASS and would have left this file inert:
#
#   cp /bin/sleep $tmp/vax750; $tmp/vax750 8 &      -- never runs at all.
#	macOS refuses to execute a copy of a platform binary, so `ps -p'
#	shows no such pid and pgrep correctly finds nothing.  The guard reads
#	as broken when the test is.
#   printf '#!/bin/sh\nexec /bin/sleep 8\n' > vax750 -- runs as `sleep'.
#	`exec' replaces the shell, so the process name is the interpreter's
#	target and not the script's.  A script named vax750 is `sh' anyway.
#
# The honest test spawns work/opensimh/BIN/vax750 itself with NO image
# attached, reading a fifo so it sits at `sim>' instead of exiting on EOF:
#
#	mkfifo f; work/opensimh/BIN/vax750 < f & exec 8> f
#	pgrep -x vax750     ->  the pid
#	no_other_sims       ->  refuses, as it should
#	echo quit >&8       ->  and passes again once it is gone
#
# Which is the rule CLAUDE.md already states about the app-currency gate:
# prove the gate bites before trusting a pass.
no_other_sims() {
    local found
    # -x on the basename: `vax750'/`vax780' are the process names.  pgrep -f
    # would also match this shell's own command line if a path is in it.
    found=$(pgrep -x vax750 2>/dev/null; pgrep -x vax730 2>/dev/null; \
            pgrep -x vax780 2>/dev/null; pgrep -x vax 2>/dev/null)
    if [[ -n "$found" ]]; then
        echo "norun: a simulator is already running (pid$(echo $found | tr '\n' ' '))." >&2
        echo "norun: overlapping runs are how images get corrupted here." >&2
        echo "norun: let it finish -- every harness halts its guest cleanly and reaps itself." >&2
        ps -o pid,etime,command -p $(echo $found | tr '\n' ' ') 2>/dev/null >&2
        return 1
    fi
    return 0
}

# claim_images <path>...
#
# Fails if any of the named files is open by another process.  This is the
# guard that would have caught the 2026-08-17 overlap: the srcdisk builder's
# `dd' and the stage-2 simulator both had ipnx-v10-src.img open.
#
# lsof, not fuser: macOS has lsof and its exit status is 1 when nothing holds
# the file, which is the answer we want and not an error.
claim_images() {
    local f holders rc=0
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        # ONLY WRITERS BLOCK, and this cost a run.  `lsof -t' lists every
        # process with the file open, and on macOS that includes SPOTLIGHT:
        #
        #   SIM-BAIL: v10src.part is open by another process (pid 17623).
        #   ...mdworker_shared -s mdworker -c MDSImporterWorker
        #
        # mdworker had just been handed a freshly-written 64 MB file to index.
        # It reads; it cannot corrupt anything.  The hazard this guard exists
        # for is a WRITER -- the `dd' that rewrote an attached image -- and a
        # running SIMH opens its disks read-write, so filtering on access mode
        # keeps every real case and drops the indexer.
        #
        # Field 4 of lsof's default output is the FD plus its mode: `4u' and
        # `3w' are read-write and write, `5r' and `txt' are not.
        holders=$(lsof -- "$f" 2>/dev/null | awk 'NR>1 && $4 ~ /[uw]/ {print $2}' | grep -v "^$$\$")
        if [[ -n "$holders" ]]; then
            echo "norun: $f is open by another process:" >&2
            ps -o pid,etime,command -p $(echo $holders | tr '\n' ' ') 2>/dev/null >&2
            rc=1
        fi
    done
    (( rc == 0 )) || {
        echo "norun: refusing to attach an image someone else holds." >&2
        return 1
    }
    return 0
}

# no_overlap <path>...
#
# Both guards, in the order that gives the better message: the process check
# first, because "a simulator is running" explains a held image, while a held
# image does not explain a running simulator.
no_overlap() {
    no_other_sims || return 1
    claim_images "$@" || return 1
    return 0
}
