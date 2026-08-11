#!/bin/bash
# Everything that has to be true before the ipnx disk replaces the TUHS one.
#
#	tools/verify-golden.sh [ipnx-image] [tuhs-image]
#
# Defaults: work/myv8/rp07new  work/myv8/rp06v8.golden
#
# Five checks, in the order their failures matter.  The first three are the
# gate; the last two are measurements that are reported whatever they say.
#
#   1  the disk is a filesystem     -- v8fs can walk both partitions
#   2  containment                  -- retire-check: nothing exists ONLY on
#                                      the TUHS image
#   3  the lists are current        -- mkcarry --check, against the image the
#                                      build actually read
#   4  what we reproduce            -- compare-built (C4), reported not gated:
#                                      it is a research number, not a defect
#   5  the packed copy round-trips  -- image-pack check, if one is committed
#
# Deliberately NOT here: booting the disk.  tools/boot-newdisk.sh does that,
# it costs a VAX boot, and it answers a different question -- these checks are
# about content and take a second.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IPNX="${1:-$ROOT/work/myv8/rp07new}"
TUHS="${2:-$ROOT/work/myv8/rp06v8.golden}"
fail=0

hdr() { printf '\n== %s ==\n' "$1"; }

# Run a check, indent its output, and keep ITS exit status.
#
# The obvious spelling -- `if cmd | sed 's/^/  /'; then' -- takes the exit
# status of the PIPELINE, which is sed's, and sed always succeeds. This
# script's first run printed "NOT SAFE TO RETIRE" with four files listed
# and then "GOLDEN DISK OK" four lines later. A verifier that reports
# success over a failure it just printed is worse than no verifier.
run() {
    local out rc
    out=$("$@" 2>&1); rc=$?
    sed 's/^/  /' <<< "$out"
    return $rc
}

hdr "1. the disk is a filesystem"
if python3 "$ROOT/tools/v8fs.py" stat "$IPNX:a" > /dev/null 2>&1 &&
   python3 "$ROOT/tools/v8fs.py" stat "$IPNX:f" > /dev/null 2>&1; then
    python3 "$ROOT/tools/v8fs.py" stat "$IPNX:a" | sed -n '2,4p;9p' | sed 's/^/  root /'
    python3 "$ROOT/tools/v8fs.py" stat "$IPNX:f" | sed -n '9p' | sed 's/^/  usr  /'
    echo "  ok"
else
    echo "  FAIL  cannot read both partitions of $IPNX"; fail=1
fi

hdr "2. containment: nothing exists only on the TUHS image"
run python3 "$ROOT/tools/retire-check.py" --tuhs "$TUHS" --ipnx "$IPNX" || fail=1

hdr "3. the generated lists are current"
run python3 "$ROOT/tools/mkcarry.py" --image "$TUHS" --check ||
    { echo "  FAIL  run tools/mkcarry.py"; fail=1; }

hdr "4. C4: what our build reproduces of the 1985 binaries"
python3 "$ROOT/tools/compare-built.py" --tuhs "$TUHS" --ipnx "$IPNX" 2>&1 |
    sed -n '3,$p' | sed 's/^/  /'
echo "  (reported, not gated -- see task #54)"

hdr "5. the packed copy in git"
if [[ -f "$ROOT/image/ipnx-v8-rp07.img.xz" ]]; then
    run python3 "$ROOT/tools/image-pack.py" check || fail=1
else
    echo "  none committed yet -- tools/image-pack.py pack"
fi

echo
if [[ $fail -eq 0 ]]; then
    echo "GOLDEN DISK OK -- safe to retire $(basename "$TUHS")"
    exit 0
fi
echo "GOLDEN DISK NOT READY"
exit 1
