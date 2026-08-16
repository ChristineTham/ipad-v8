# tools/expdry.tcl -- run an expect harness under plain tclsh, with every
# interactive verb stubbed, purely to see whether it PARSES.
#
#	tclsh tools/expdry.tcl tools/v10-stage1.exp arg1 arg2 ...
#
# WHY.  Tcl reports a syntax error only when control REACHES the offending
# command, so a typo in the last block of a harness surfaces three hours into
# a run, after the work it was supposed to check has already been done.  This
# walks the whole script in about a second.
#
# It is a parse check and nothing more.  Every `expect' succeeds instantly and
# every `send' goes nowhere, so a harness that passes here can still be wrong
# about patterns, ordering or timing -- which is where the real bugs are.
# What it catches is the class that costs a boot to discover:
#
#	* an unbalanced brace or bracket in a block never reached
#	* "2[0-9]" written as a character class, which Tcl reads as command
#	  substitution and fails on with `invalid command name "0-9"'
#	* a proc called with the wrong number of arguments
#	* a misspelled proc name
#
# THE STUBS DELIBERATELY DO NOT MODEL EXPECT.  `expect' returns without ever
# running a pattern's body, so v8_try/v10_try see their `set hit 1' skipped
# and report a MISS for everything -- a dry run ends "0/23" no matter how
# healthy the harness is.  Read the output for ERRORS, never for results, and
# do not add a "did the dry run pass?" check on that number.
set ::nsent 0
set ::spawn_id stub

proc spawn {args}       { set ::spawn_id stub }
proc send {s}           { incr ::nsent }
proc send_user {args}   {}
proc expect {args}      { return 1 }
proc expect_user {args} { return 1 }
proc exp_continue {}    {}
proc log_user {args}    {}
proc log_file {args}    {}
proc interact {args}    {}
proc close {args}       {}
proc wait {args}        { return {0 0 0 0} }

# A harness that bails calls exit; that is a legitimate end to a dry run, not
# a failure of one.  Report it and stop rather than letting the stubs carry on
# past a point the real script would never reach.
rename exit real_exit
proc exit {{c 0}} {
    puts "expdry: script called exit $c after $::nsent sent lines"
    real_exit 0
}

if {[llength $argv] < 1} {
    puts "usage: tclsh tools/expdry.tcl <harness.exp> \[args ...\]"
    real_exit 2
}
set script [lindex $argv 0]
set argv   [lrange $argv 1 end]
set argc   [llength $argv]
set argv0  $script

if {[catch {source $script} err]} {
    puts "expdry: FAILED to parse $script"
    puts $errorInfo
    real_exit 1
}
puts "expdry: $script parsed and ran to the end ($::nsent sent lines)"
