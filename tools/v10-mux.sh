#!/usr/bin/env bash
# K15: rung 8's host half -- does V10 build mux(1), the 5620 multiplexer's VAX side?
#
#	bash tools/v10-mux.sh [k13-image]
#
# Rung 8 was carried for weeks as "blocked on an authenticity decision" and is
# actually two questions with two different answers.  The TERMINAL half
# (`muxterm', a WE32100 program) cannot be built from this tape at all: its
# makefile names `3cc'/`3as'/`3ld'/`3nm', `src/man/man9/3cc.9' documents all eight
# of those as the DMD-5620 cross-compiler, and the man page is the only one of the
# eight that survived.  That was settled host-side on 2026-08-19, no simulator
# needed.  The HOST half is ordinary VAX C naming `$CC', and this is it.
#
# No courier disk: the tape, our overlay and the generated makefiles all arrive
# over TCP, which is what K13 was for.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"

for fn in no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-mux: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

GOLD="${1:-ipnx-v10-ra81.img.stage1.k102.k7.k13}"
TPORT="${TPORT:-9310}"; OPORT="${OPORT:-9311}"; MPORT="${MPORT:-9312}"
NETFSD="$ROOT/netfs/.build/release/netfsd"
LOG="$ROOT/work/v10-mux.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-mux: no $GOLD -- bash tools/v10-netboot.sh builds it."
    exit 1
}

# NO srcid_check: this run reads no source disk at all.  The repository working
# tree IS the source, served live, so there is no stamp to disagree with -- the
# two --check calls are what replace it.
python3 "$ROOT/tools/v10-overlay.py" --check || exit 1
python3 "$ROOT/v10/mk/mkdep.py"      --check || exit 1

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) >/dev/null || exit 1

PIDS=()
serve() { "$NETFSD" -p "$1" -v "$2" > "$ROOT/work/netfs-$3.log" 2>&1 & PIDS+=($!); }
# `work/v10' and not `work/v10/src', because mux needs BOTH: its sources are under
# src/ and the 5620 include tree it stands /usr/jerq/include up from is
# work/v10/blit/include, a sibling of src/.  The makefile's $(SRC) is
# /n/tree/src, one level in.
serve "$TPORT" "$ROOT/work/v10"      muxtree
serve "$OPORT" "$ROOT/v10/src"       muxours
serve "$MPORT" "$ROOT/v10/mk/gen"    muxmk
sleep 1
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || { echo "netfsd died"; tail -5 "$ROOT"/work/netfs-mux*.log; exit 1; }
done
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done' EXIT

no_overlap "$ROOT/work/v10gold/$GOLD" || exit 1
IMG=$(v10_clone "$GOLD" k15) || exit 1

echo "== V10 builds mux from the ix tree =="
expect "$ROOT/tools/v10-mux.exp" "$IMG" "$TPORT" "$OPORT" "$MPORT" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ===================== the oracle, counted HOST-SIDE from the log ===========
# Three rules are baked into this one grep, and each cost a real run somewhere:
#
#   NOT ANCHORED at ^.  v10_run's first line of output shares a line with the
#   tty's echo of the command that produced it, so `CMPSAME 32ld.o' can arrive
#   as `MCMPSAME 32ld.o'.  An anchored count in v10-stage2.sh hid a missing
#   libc member for a week.
#
#   `sort -u' because the token can appear more than once for one object -- the
#   echo of the command and the answer itself.
#
#   `grep -c .' and `|| true', because `grep -c' PRINTS 0 AND EXITS 1 when it
#   matches nothing, which under `set -o pipefail' fails the script at exactly
#   the moment the honest answer is zero.
#
# The object names start with a digit and contain a dot (`32ld.o'), so the class
# needs both.
k15count() {
    tr -d '\r' < "$LOG" | grep -oE "$1 [A-Za-z_0-9.]+" | sort -u | grep -c . || true
}
if grep -q 'the oracle.*ok$' "$LOG" 2>/dev/null; then
    echo "== our seven objects against Bell Labs' own 1989 lib.a =="
    printf '   byte-identical                      %s\n' "$(k15count CMPSAME)"
    printf '   differ                              %s\n' "$(k15count CMPDIFF)"
    printf '   missing from the archive             %s\n' "$(k15count CMPGONE)"
    cat <<'EOF'
   A DIFFERENCE HERE IS THE EXPECTED RESULT, NOT A DEFECT.  lib.a's members are
   dated 1989-01-02 (six) and 1989-07-15 (mux.o), which is the era CLAUDE.md
   establishes is unreproducible: the compiler that built it is not on the tape,
   and these are most likely Ninth Edition objects besides.  Read this number
   beside "all seven objects compile", never instead of it.
EOF
fi

echo
if [[ $rc -eq 0 ]]; then
    cat <<'EOF'
== RUNG 8's HOST HALF IS BUILT ==
   V10 compiled and linked mux(1) from src/history/ix/src/jerq/mux with its own
   compiler, against a /usr/jerq/include assembled from the v10blit tarball plus
   six headers no surviving tree provides at the path mux names.

   The packet size is the tape's 124, asserted through sizeof(struct Packet).
   That is deliberate: `proto.h' carries `/* was 64 */' above the constant, but
   Bell Labs' own 1989 `mux.o' in lib.a declares `_buf' as a 124-byte common, so
   124 is what the shipped artefact used and 64 would be a deviation rather than
   a restoration.  Interoperating with V8's muxterm -- the only 5620 muxterm this
   project possesses, built for 64 -- is a separate decision with its own patch.
EOF
else
    echo "== NOT YET.  The first NO names the step. =="
fi
exit $rc
