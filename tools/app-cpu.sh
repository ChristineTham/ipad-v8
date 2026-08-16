#!/bin/bash
# Measure what the shipped Mac app actually costs while V8 sits at `login:`,
# broken down per thread -- the SIMH interpreter and the 5620 interpreter are
# separate threads with separate reasons to burn CPU, and a single process
# number hides which one is which.
#
#   tools/app-cpu.sh [app-bundle] [settle-seconds] [window-seconds]
#
# One-shot: hard watchdog, and the app is killed on every exit path.
set -u

# Default to the app this repo builds, not to whatever scratch directory the
# measurement happened to be taken from once — that path pointed into a
# temporary folder belonging to a session that ended long ago.
APP=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/app/build/DerivedData/Build/Products/Debug/ipnx.app}
SETTLE=${2:-75}
WINDOW=${3:-20}
LOG=${TMPDIR:-/tmp}/ipnx-cpu.log

cleanup() { pkill -9 -x ipnx 2>/dev/null; }
trap cleanup EXIT INT TERM

( sleep $((SETTLE + WINDOW + 120)); echo "WATCHDOG: killing app"; cleanup ) &
WD=$!

cleanup; sleep 1

# Cold boot, not a restored snapshot: the restore path skips fsck and lands in
# whatever state the machine was left in, which is not a comparable baseline.
for d in "$HOME/Library/Containers"/*ipnx*/Data/Library/Application\ Support/* \
         "$HOME/Library/Application Support"/*ipnx*; do
  [ -d "$d" ] && rm -f "$d/state.sav" "$d/restore.attempt" && echo "cleared snapshot in $d"
done

# Exec'ing the binary directly gets no WindowServer connection: it boots V8 and
# binds sockets but never draws, so `open` is the only faithful launch.
open -n "$APP" --stdout "$LOG" --stderr "$LOG"
sleep 5
PID=$(pgrep -x ipnx | head -1)
[ -z "$PID" ] && { echo "app did not start"; exit 1; }
echo "pid $PID; settling ${SETTLE}s for the cold boot to reach login:"
sleep "$SETTLE"

# `ps -M` prints the process on a 9-column row and each of its threads on a
# 6-column row (PID %CPU STAT PRI STIME UTIME); a thread's CPU is STIME+UTIME.
# Threads have no names here, so they are identified by rank -- which is stable
# within one run, and that is all a before/after comparison needs.
thread_secs() {
  ps -M -p "$PID" | awk 'NF==6 {print $5, $6}' |
    awk 'function s(t,  a,n,v){n=split(t,a,":");v=a[n];if(n>1)v+=a[n-1]*60;if(n>2)v+=a[n-2]*3600;return v}
         {print s($1)+s($2)}'
}
cpu_secs() {
  ps -o time= -p "$PID" | awk -F: '{n=NF; s=$n; if(n>1) s+=$(n-1)*60; if(n>2) s+=$(n-2)*3600; print s}'
}

C0=$(cpu_secs); T0=$(date +%s)
thread_secs > "${TMPDIR:-/tmp}/ipnx-threads-0.txt"
sleep "$WINDOW"
C1=$(cpu_secs); T1=$(date +%s)
thread_secs > "${TMPDIR:-/tmp}/ipnx-threads-1.txt"

echo "=== whole process ==="
echo "$C0 $C1 $T0 $T1" | awk '{printf "IDLE CPU: %.1f%% of a core (%.2f s CPU over %d s wall)\n", 100*($2-$1)/($4-$3), $2-$1, $4-$3}'

echo "=== per thread, over the same window (only threads above 1%) ==="
paste "${TMPDIR:-/tmp}/ipnx-threads-0.txt" "${TMPDIR:-/tmp}/ipnx-threads-1.txt" \
  | awk -v w="$((T1 - T0))" '{ d = $2 - $1; if (100*d/w > 1) printf "  thread %2d: %5.1f%% of a core\n", NR, 100*d/w }'

# ps -M cannot name a thread, so ask sample(1) what each one is actually doing.
# A SIMH thread that is idling correctly sits in sim_idle/nanosleep; one that is
# not sits in sim_instr. The dmd thread shows dmd_step_loop either way.
SAMP="${TMPDIR:-/tmp}/ipnx-sample.txt"
sample "$PID" 2 -file "$SAMP" > /dev/null 2>&1
echo "=== what each busy thread is doing (sample) ==="
awk '/^ *[0-9]+ Thread_/ {print "  " $0}
     /sim_instr|sim_idle|dmd_step_loop|nanosleep|usleep|__semwait/ {print "      " $0}' "$SAMP" \
  | sed 's/  */ /g' | head -40

kill "$WD" 2>/dev/null
echo "--- app log tail ---"; tail -5 "$LOG" 2>/dev/null
cleanup
echo "cleanup done; ipnx processes left: $(pgrep -x ipnx | wc -l | tr -d ' ')"
