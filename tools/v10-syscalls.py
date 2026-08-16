#!/usr/bin/env python3
"""
Which system calls does a V10 program get wrong on a V8 kernel?

    tools/v10-syscalls.py              # the table diff
    tools/v10-syscalls.py --callers    # and who in the boot path calls them

WHY THIS EXISTS.  B1 proved that V10's prebuilt binaries run on the V8 kernel
(tools/v10-probe.sh, 9/9) and B2.0 proved that fifteen of the seventeen
boot-path commands compile.  Neither answers the question that decides which
of them can be USED before B3 replaces the kernel: a program can compile
cleanly, link cleanly against V10's libc.a, and still trap into a slot the V8
kernel leaves empty.  Compiling and running are different claims and the
difference is exactly one table.

WHERE THE TABLE LIVES.  Both editions split it in two.  V8 has slots 0-63 in
sys/sysent.c and #includes sys/vmsysent.c for the rest; V10 keeps both halves
in one file.  Either way the upper half numbers its rows "64 +9" rather than
"73", because the author wrote the offset from where the file is included
rather than the sum.  A scan that only understands a bare number reads a
128-entry table as a 64-entry one and then reports a clean 64/64 agreement --
which looks like a result and is the reason this is a tool rather than a
one-line grep.  (It happened here first, on 2026-08-16.)

WHAT IT FOUND.  112 of 128 slots hold the same call at the same index.  Of
the sixteen that differ, exactly two matter to the boot path: V10 mounts with
fmount (slot 26) and unmounts with funmount (slot 50), and V8 has nosys at
both.  So V10's mount(8) and umount(8) build and will not run until there is
a V10 kernel under them -- which is fine, because they are needed only by
that kernel.  Nothing else in the boot path names a call V8 lacks.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

V8_TABLE = ["v8/usr/sys/sys/sysent.c", "v8/usr/sys/sys/vmsysent.c"]
V10_TABLE = ["work/v10/src/lsys/os/sysent.c"]

# lsys/os/sysent.c and sys/os/sysent.c are byte-identical (checked
# 2026-08-16), so the choice between the two kernel trees -- B3.1 -- does not
# change the system call interface.  That is worth knowing early: it means
# B3.1 can be settled on other grounds.
V10_TABLE_ALT = "work/v10/src/sys/os/sysent.c"

ROW = re.compile(
    r'^\s*\d+,\s*([A-Za-z_]\w*)\s*,.*?/\*\s*'
    r'(?:(\d+)\s*\+\s*)?(\d+)\s*=\s*([^*]*?)\s*\*/',
    re.M)

# The seventeen the first boot depends on; `cp' is the one that lives in a
# directory rather than as a loose cmd/*.c.
BOOTPATH = ["init", "getty", "login", "mount", "umount", "mkfs", "fsck",
            "icheck", "sync", "date", "stty", "cat", "cp/cp", "mv", "rm",
            "mkdir", "echo"]


def table(paths):
    """slot -> (routine, comment)."""
    out = {}
    for p in paths:
        full = os.path.join(ROOT, p)
        if not os.path.exists(full):
            sys.exit(f"v10-syscalls: no {p} "
                     f"(work/v10 is rebuilt by tools/v10-import.py)")
        with open(full, errors="replace") as f:
            for m in ROW.finditer(f.read()):
                base = int(m.group(2)) if m.group(2) else 0
                out[base + int(m.group(3))] = (m.group(1), m.group(4))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--callers", action="store_true",
                    help="also scan the boot path for calls V8 cannot serve")
    args = ap.parse_args()

    v8 = table(V8_TABLE)
    v10 = table(V10_TABLE)

    # A 64-entry read is the failure mode this tool was written around, so it
    # is asserted rather than left to be noticed in the output.
    for name, t in (("V8", v8), ("V10", v10)):
        if len(t) < 128:
            sys.exit(f"v10-syscalls: only parsed {len(t)} {name} slots -- "
                     f"the table format has changed, and a short read here "
                     f"reports agreement it has not checked")

    both = sorted(set(v8) & set(v10))
    diff = [n for n in both if v8[n][0] != v10[n][0]]
    print(f"slots: {len(both)}   same routine: {len(both) - len(diff)}   "
          f"different: {len(diff)}\n")

    print("=== the sixteen that differ ===")
    for n in diff:
        print(f"  {n:3d}  V8: {v8[n][0]:<12} {v8[n][1]:<28} "
              f"V10: {v10[n][0]:<12} {v10[n][1]}")

    # A slot V10 fills and V8 leaves at nosys is the only genuinely fatal
    # shape: the program traps, the kernel has nothing there, and the failure
    # arrives as a bare errno rather than as anything naming a system call.
    fatal = {v10[n][0]: n for n in diff if v8[n][0] == "nosys"}
    print(f"\n=== V10 fills, V8 leaves empty ({len(fatal)}) -- these TRAP ===")
    for name, n in sorted(fatal.items(), key=lambda kv: kv[1]):
        print(f"  {n:3d}  {name}")

    if not args.callers:
        return

    print("\n=== who in the boot path calls one ===")
    hit = False
    for c in BOOTPATH:
        p = os.path.join(ROOT, "work/v10/src/cmd", c + ".c")
        if not os.path.exists(p):
            continue
        with open(p, errors="replace") as f:
            src = f.read()
        called = sorted(n for n in fatal
                        if re.search(r'\b' + n + r'\s*\(', src))
        if called:
            hit = True
            print(f"  {os.path.basename(c):<8} {' '.join(called)}")
    if not hit:
        print("  (none)")


if __name__ == "__main__":
    main()
