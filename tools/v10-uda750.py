#!/usr/bin/env python3
"""
Retarget V10's UDA50 boot ROM from a VAX-11/780 to an 11/750.

    tools/v10-uda750.py            # write work/v10boot/uda750
    tools/v10-uda750.py --check    # fail if it is stale

WHY THERE IS NO 750 ROM IN THE TAPE.  `lsys/boot/README` says V10's boot
scheme *is* the 750's: a ROM reads 512 bytes off the device and branches to
them.  On a real 750 that ROM is in hardware, so nothing had to ship.  The
`star/` directory exists because the 780 has no such ROM and its console
floppy has to do the ROM's job -- `defboo.cmd` loads `UDA.ROM` at 0xFA00 and
starts at 0xFA02.

SIMH inverts that.  Its `vax750` implements `boot` as VMB.EXE, DEC's *VMS*
bootstrap, which wants a VMS boot block and answers

    %BOOT-F-Unable to locate BOOT file

to V10's.  So on SIMH the 750 needs the console trick too, and the only thing
standing in the way is that `star/uda` has the 780's addresses compiled in.

WHY A BINARY PATCH RATHER THAN A REBUILD.  `uda.s` documents its own tables:

    ubamap:  .long 0x20006800, 0x20008800   # map regs for UNIBUS adapters
    ubabase: .long 0x20100000, 0x20140000   # UNIBUS space base addresses
    udareg:  .long 0772150, 0772160         # UDA50 addresses

and all six land as contiguous 32-bit literals at offsets 167..191 of the
380-byte image.  The machine dependence is twenty-four bytes of data, so
reassembling -- which would mean driving V10's `as` through a V8 guest -- buys
nothing over writing them here, where the arithmetic can be shown.

THE ARITHMETIC, CHECKED AGAINST SIMH BOTH WAYS.  Nexus base is 0x20000000 on
the 780 and 0xF20000 on the 750, each nexus 0x2000 wide; the UBA is TR 3 on
the 780 and TR 8 on the 750; and `UBAMAP_OF` is 0x200 *longwords* = 0x800
bytes on both.

    780   0x20000000 + 3*0x2000 + 0x800 = 0x20006800   <- matches uda.s
    750   0x00F20000 + 8*0x2000 + 0x800 = 0x00F30800

The UNIBUS window is the other half, and SIMH reports where the controller
lands, which checks the answer rather than assuming it:

    780   0x20100000 + 0772150 = 0x2013F468   `RQ address=2013F468'
    750   0x00FC0000 + 0772150 = 0x00FFF468   `RQ address=FFF468'

Only entry [0] of each table is touched.  The 750 has one UNIBUS adapter, so
entry [1] is unreachable, and `udareg` is unchanged because a UNIBUS device
address is a property of the device.
"""
import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "work/v10/src/lsys/boot/star/uda")
OUTDIR = os.path.join(ROOT, "work/v10boot")
OUT = os.path.join(OUTDIR, "uda750")

# (offset, what it is, 780 value, 750 value)
PATCHES = [
    (167, "ubamap[0]  UBA map registers", 0x20006800, 0x00F30800),
    (175, "ubabase[0] UNIBUS address window", 0x20100000, 0x00FC0000),
]


def build():
    d = bytearray(open(SRC, "rb").read())
    if d[:2] != b"UD":
        sys.exit("v10-uda750: %s does not open with `UD' -- wrong file?" % SRC)
    notes = []
    for off, what, old, new in PATCHES:
        got = struct.unpack_from("<I", d, off)[0]
        if got != old:
            sys.exit("v10-uda750: offset %d holds 0x%08x, expected the 780's "
                     "0x%08x -- the ROM has changed" % (off, got, old))
        struct.pack_into("<I", d, off, new)
        notes.append("  %-34s 0x%08x -> 0x%08x" % (what, old, new))
    return bytes(d), notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(SRC):
        sys.exit("v10-uda750: no %s -- run tools/v10-import.py" % SRC)

    data, notes = build()
    old = open(OUT, "rb").read() if os.path.exists(OUT) else None
    if args.check:
        if old != data:
            print("stale, re-run tools/v10-uda750.py")
            return 1
        print("work/v10boot/uda750 is up to date")
        return 0

    os.makedirs(OUTDIR, exist_ok=True)
    if old != data:
        open(OUT, "wb").write(data)
    print("work/v10boot/uda750: %d bytes, retargeted 780 -> 750" % len(data))
    for n in notes:
        print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
