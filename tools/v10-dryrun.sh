#!/usr/bin/env bash
#
# Dry-run a guest harness under tclsh, with every interactive verb stubbed.
#
#	bash tools/v10-dryrun.sh tools/v10-compile.exp [args...]
#	bash tools/v10-dryrun.sh --all              every V10 harness
#
# WHY THIS EXISTS AS A TOOL AND NOT AS A HABIT.  CLAUDE.md has said "dry-run any
# change under tclsh with the interactive verbs stubbed before spending a boot on
# it" since the expect-spelling incident, and the reason is specific: Tcl reports
# a syntax error only when it REACHES the command, so a typo in a harness's last
# block surfaces three hours into a run that has already done all its work.  A
# rule you have to remember is one that gets skipped on the run where it matters,
# which is exactly the argument tools/norun.sh and tools/srcid.sh were written
# from.
#
# WHAT IT PROVES AND WHAT IT CANNOT.  Every command it REACHES is parsed, so this
# catches typos, bad variable names, wrong argument counts and unbalanced braces.
# It cannot catch a wrong expect pattern or a wrong compiler flag -- the stubs
# return success for everything, so the report always reads as a pass.  A green
# dry-run means "this file will run", never "this run will succeed".
#
# AND UNREACHED CODE IS STILL UNPARSED, which is the same property that makes
# this tool necessary rather than an exception to it.  Tcl compiles a command
# when it executes it, so anything after a harness's final `exit' -- or inside a
# branch the stubs never take -- is not checked.  Verified by injecting a bad
# verb name: after the exit it passed clean, before it, TCL ERROR.  So this
# shrinks the class of three-hours-in typos; it does not eliminate it.
#
# The harness is copied to a scratch directory beside a STUB v10drive.exp so
# that its own `source [file dirname [info script]]/v10drive.exp' picks up the
# stub without the real driver being touched or the harness being edited.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/v10dry.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# EXPECT'S BUILTINS GO IN A PRELUDE, NOT IN THE DRIVER STUB, and the difference
# is not cosmetic: a harness's first line is `log_user 1' and its second is the
# `source .../v10drive.exp'.  Defining log_user inside the stub therefore defines
# it one line too late, and every harness fails identically at line 1 while
# appearing to prove something about line 1.  The prelude is sourced first and
# then sources the harness, so [info script] inside the harness is still the
# harness -- which is what makes its own `source [file dirname [info script]]'
# find the stub driver beside it.
#
# Deliberately NOT `package require Expect': the point is to parse a harness
# without a pty, a simulator or a disk.
cat > "$WORK/prelude.tcl" <<'PRELUDE'
proc log_user      {args} {}
proc send_user     {args} { puts -nonewline [lindex $args end] }
proc send          {args} {}
proc send_error    {args} {}
proc expect        {args} { return 1 }
proc expect_user   {args} { return 1 }
proc spawn         {args} { return 4242 }
proc exp_internal  {args} {}
proc exp_continue  {args} {}
proc interact      {args} {}
proc sleep         {args} {}
proc stty          {args} {}
if {[info commands close] eq ""} { proc close {args} {} }
if {[info commands wait]  eq ""} { proc wait  {args} { return {0 0 0 0} } }
source $env(V10DRY_EXP)
PRELUDE

# The shim the harness's own `source' finds.  IT LOADS THE REAL DRIVER AND THEN
# OVERRIDES ONLY THE VERBS THAT TOUCH A GUEST.
#
# THE FIRST VERSION REIMPLEMENTED v10_order AND WAS WRONG, WHICH IS THE ONE
# FAILURE MODE THIS TOOL MUST NOT HAVE.  It declared `proc v10_order {name}'
# while the real one is `{file {col 0}}', so v10-stage1.exp's entirely correct
# `v10_order buildtools.ord 2' was reported as a TCL ERROR -- a dry-runner that
# sends you to fix working code is worse than no dry-runner at all.  The real
# driver's top level is nothing but `set's, an fconfigure and a `source
# norun.exp', so sourcing it is safe under plain tclsh, and then every pure
# function -- v10_order, v10_rows, v10_expired -- is THE REAL ONE and cannot
# disagree with it.  That also means a harness destructuring a generated table
# is checked against the table's true shape, which is how the fixpoint's "seven
# differences from zero comparisons" bug would be caught.
cat > "$WORK/v10drive.exp" <<STUB
source "$ROOT/tools/v10drive.exp"
STUB
cat >> "$WORK/v10drive.exp" <<'STUB'
# Now blind the verbs that need a pty.  v10_try yields 1 (matched) so `note'
# records a pass; nothing here can fail, which is why a green dry run means
# "this file will run" and never "this run will succeed".
proc dry {what args} { puts "  \[dry\] $what $args" }
proc v10_boot    {args} { dry boot  $args }
proc v10_login   {args} { dry login $args }
proc v10_sh      {args} { dry sh    [lindex $args 0] }
proc v10_run     {args} { dry run   [lindex $args 0] }
proc v10_must    {args} { dry must  [lindex $args 0]; return 1 }
proc v10_try     {args} { dry try   [lindex $args 0]; return 1 }
proc v10_shmust  {args} { dry shmust [lindex $args 0]; return 1 }
proc v10_halt    {args} { dry halt  $args }
proc v10_reap    {args} {}
proc v10_deadline {args} {}
proc sim_guard   {args} {}
STUB

run_one() {
    local exp="$1"; shift
    local base; base="$(basename "$exp")"
    cp "$ROOT/$exp" "$WORK/$base" 2>/dev/null || cp "$exp" "$WORK/$base"
    printf '%-28s ' "$base"
    local out
    if out=$(cd "$WORK" && V10DRY_EXP="$WORK/$base" tclsh prelude.tcl "$@" 2>&1); then
        echo "parsed and ran clean"
        return 0
    fi
    # An `exit' from the harness is not a failure of the dry run: most report a
    # nonzero status when a stubbed assertion is "false".  Only a Tcl ERROR is.
    if echo "$out" | grep -qE 'invalid command name|wrong # args|can.t read "|extra characters|missing close|syntax error'; then
        echo "TCL ERROR"
        echo "$out" | grep -E -A3 'invalid command name|wrong # args|can.t read "|extra characters|missing close|syntax error' | head -12
        return 1
    fi
    echo "ran (nonzero exit, no Tcl error)"
    return 0
}

rc=0
if [[ "${1:-}" == "--all" ]]; then
    for f in "$ROOT"/tools/v10-*.exp; do
        case "$(basename "$f")" in
            v10drive.exp) continue ;;   # the driver itself, not a harness
        esac
        run_one "$f" img src a b c d e f || rc=1
    done
else
    [[ $# -ge 1 ]] || { echo "usage: v10-dryrun.sh <harness.exp> [args...] | --all"; exit 2; }
    run_one "$@" || rc=1
fi
exit "$rc"
