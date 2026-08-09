#!/bin/bash
# N0: cut a 516 MB RP07 image and move the V8 system onto it.
#
# Rebuilds all media from rp06v8.golden every run so a failed attempt can
# never poison the next one, and boots a *copy* — the golden is never the
# thing running, so N0 stays reversible.
#
# Hard timeout, watchdog, trap cleanup. pkill needs -x: a PATH-resolved
# `spawn vax780` has the bare name as its whole command line.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/work/myv8"
cd "$WORK" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"

LIMIT=${LIMIT:-4200}          # 70 min ceiling
LOG=rp07mig.log

SECT=512
RP07_SECTORS=1008000          # 50 sect * 32 surf * 630 cyl
A_SECTORS=15884               # hp7_sizes[a] == hp6_sizes[a], both at cyl 0

cleanup() {
    [[ -n "${EXP_PID:-}" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

command -v vax780 >/dev/null || { echo "mig: vax780 not on PATH"; exit 1; }
for f in bootV8 rp06v8.golden; do
    [[ -e $f ]] || { echo "mig: missing $WORK/$f"; exit 1; }
done

echo "=== preparing media ==="
rm -f rp06v8.mig rp07v8.new
cp rp06v8.golden rp06v8.mig

python3 - "$RP07_SECTORS" "$A_SECTORS" "$SECT" <<'PY'
import sys, hashlib
nsect, asect, ss = (int(x) for x in sys.argv[1:4])
with open('rp07v8.new', 'wb') as f:
    f.truncate(nsect * ss)                    # sparse: SIMH would grow it anyway
    with open('rp06v8.golden', 'rb') as g:
        root = g.read(asect * ss)
    f.seek(0); f.write(root)
with open('rp07v8.new', 'rb') as f:
    got = f.read(asect * ss)
assert hashlib.sha256(got).digest() == hashlib.sha256(root).digest(), "root copy mismatch"
print(f"rp07v8.new: {nsect*ss:,} B; root partition a copied verbatim "
      f"({asect*ss:,} B, sha256 verified)")
PY
[[ $? -eq 0 ]] || exit 1

: > "$LOG"
echo "=== running (this takes a while: 8775 files through cpio) ==="
expect "$ROOT/tools/rp07mig.exp" &
EXP_PID=$!

for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done

if kill -0 "$EXP_PID" 2>/dev/null; then
    echo "mig: TIMEOUT after ${LIMIT}s — last log lines:"; tail -30 "$LOG"; exit 2
fi

wait "$EXP_PID"; rc=$?
echo "mig: expect exited $rc"
echo "--- markers reached ---"
grep -o 'MIG-[A-Za-z-]*' "$LOG" | sort -u

if [[ $rc -eq 0 ]]; then
    ls -l rp07v8.new
    echo "N0 COMPLETE — rp07v8.new boots on its own with /usr on partition f"
fi
exit $rc
