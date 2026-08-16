#!/usr/bin/env bash
#
# Stop hook: you do not get to call it done while the app is stale.
#
# Wired into .claude/settings.json as a Stop hook. Exit 2 blocks the stop and
# hands the reason back, so the next thing that happens is a rebuild rather
# than a report that the work is finished.
#
# THE FAILURE THIS PREVENTS.  Fixes were built, verified and committed while
# the app the user actually launches kept running the previous system image --
# a new /etc/motd, /etc/copyright and /usr/inet/lib/services all present in the
# repo and absent from the running machine. Nothing was wrong with any test;
# the tests were simply not looking at the artefact the user opens. "It is in
# the golden, it will arrive on Reset" is the shape of the excuse, and the
# answer is that arriving is the job, not the user's.
#
# It passes quietly when nothing has been built yet, so a session that never
# touches the app is never blocked by it.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

out=$(bash tools/app-check.sh 2>&1)
rc=$?
[[ $rc -eq 0 ]] && exit 0

{
    echo "BLOCKED: the built app is not current, so it must not be reported as done."
    echo
    echo "$out"
} >&2
exit 2
