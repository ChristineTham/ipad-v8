#!/bin/bash
# sim_ether.c uses gethostuuid(2), which iOS does not have.
#
#   libsimh/patches/apply-iosnet.sh [path-to-opensimh]
#
# _eth_get_system_id() fetches a host-unique string that sim_ether hashes into
# a default MAC address. Its Apple arm calls gethostuuid(2), and on the iOS
# DEVICE slice that is a hard error -- "'gethostuuid' is unavailable: not
# available on iOS" -- so the whole library fails to build. macOS and the
# simulator compile it happily, which is what makes this easy to miss: two of
# the three slices are fine.
#
# The fix is the function's OWN failure path. It already handles gethostuuid
# returning non-zero by zeroing the uuid and unparsing that, so an all-zero
# system id is a case upstream already supports. On iOS we take it directly.
#
# Nothing here depends on the id being unique. It seeds a DEFAULT MAC, and our
# NI1010 sets its own address anyway (pdp11_il.c); more to the point the guest
# lives on SLiRP's private 10.0.2.0/24 behind a NAT that never puts a frame on
# a real network, so there is no collision domain to be unique within.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIMH="${1:-$ROOT/work/opensimh}"

python3 - "$SIMH" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "sim_ether.c"
s = p.read_text()

marker = "ipnx: iOS has no gethostuuid"
if marker in s:
    print("   already applied")
    raise SystemExit

old = """if (gethostuuid (uuid, &wait))
  memset (uuid, 0, sizeof(uuid));"""
new = """#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
/* ipnx: iOS has no gethostuuid(2) -- referencing it is a build error, not a
   link-time one. Take the all-zero id this function already falls back to
   when the call fails; it only seeds a default MAC, and the guest is behind
   SLiRP's NAT on a private network with no collision domain. */
(void)&wait;
memset (uuid, 0, sizeof(uuid));
#else
if (gethostuuid (uuid, &wait))
  memset (uuid, 0, sizeof(uuid));
#endif"""

if old not in s:
    raise SystemExit("   gethostuuid call not found -- upstream changed?")

s = s.replace(old, new, 1)
p.write_text(s)
print("   sim_ether.c: gethostuuid skipped on iOS")
PY

echo "apply-iosnet: done"
