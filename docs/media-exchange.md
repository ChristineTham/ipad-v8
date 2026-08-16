# Moving files between the host and V8

*How Track B gets the V10 source into a running V8 and gets patches, logs and
built artifacts back out. Written 2026-08-09, after testing every claim here
against open-simh `vax780` + the A1 golden V8 image.*

> **Superseded for Track B ingest, 2026-08-10.** The first sentence below is
> still true of SIMH and always will be — there is no host-directory
> passthrough. But V8 turns out not to need one: it has had a network file
> system in its kernel since 1985, and the N track gave it a server to talk to.
> A macOS folder now mounts at `/n/macos` read/write over TCP, so **B1 ingests
> through netfs, not through this courier** —
> [n-track-notes.md](n-track-notes.md), [netfs-protocol.md](netfs-protocol.md),
> `tools/drive-netfs.sh`.
>
> This document stays because the courier still works, needs no networking, and
> is the fallback if netfs is ever unavailable — and because the RP07 migration
> and the `mkfs` arithmetic below are still the reference for anything that
> touches emulated media. Note that its "raw transfers must be 512 bytes" rule
> is **flagged as suspect** (see N0's gotchas: `er1=5<RMR,ILF>` turned out to be
> the signature of a missing `set noasynch`) and has not been re-tested, since
> the path it governs is no longer on Track B's critical path.

## There is no shared directory, and there cannot be

SIMH has **no host-directory passthrough** — no 9p, no virtfs, no shared
folder. Verified by grepping every `.c`/`.h` in the open-simh tree for
`9p|virtfs|shared.?folder|host.?director`: nothing. This is not an omission.
SIMH models hardware, and a VAX-11/780 has no concept of a filesystem exposed
by its host. Any exchange has to go through emulated media.

What SIMH *does* give you is media that can be attached and swapped while the
machine sits paused at `sim>`. That is enough.

## What the machine actually offers

| SIMH device | Emulates | V8 driver | Usable? |
|---|---|---|---|
| `RP` (Massbus adapter 0, 8 units) | RP06, 174 MB each | `hp` — block major 0, char major 4 | **Yes.** The kernel declares `hp0` *and* `hp1` |
| `TU` (Massbus adapter 1) | TM03 formatter + TE16 | `ht` — block 1, char 5 | **No** — panics the kernel, see below |
| `TS` | TS11 | `ts` — block 6, char 16 | Driver exists but is **not in the kernel config** |
| `TQ` | TU81 / TMSCP | none | No driver |
| `RQ` (UDA50A, 4 units) | RD54 by default | `uda` — block 7, char 28 | Configured as `uda1`; `ra1`/`ra3`/`ra5` attach at boot. Untested |
| `LPT` | line printer | `lp` — char 15 | One-way guest→host text. Needs a `mknod`; no `lp` node ships |

The kernel config that decides all of this is `work/v8src/usr/sys/alice/conf`
in the extracted distribution. Read it before assuming a device is reachable:
`show devices` tells you what the *emulator* offers, `alice/conf` tells you
what the *guest* can see, and both have to agree.

The single most useful line in it was already there:

```
disk		hp0	at mba0 drive 0
disk		hp1	at mba0 drive 1
```

A second RP06 needs no kernel rebuild. The boot log confirms it:

```
mba0 at tr8
hp0 at mba0 drive 0
hp1 at mba0 drive 1
```

## The mechanism: one role per disk unit

**This separation is the whole design, and it was learned the hard way.**

| Unit | Role |
|---|---|
| `rp0` (`hp0`) | The system disk. **Filesystems only.** Work area is `/usr/v10` |
| `rp1` (`hp1`) | **Raw sector I/O only.** The courier. Never a filesystem |

The tempting arrangement is a 149 MB work filesystem on partition `g` of
`rp1` and the raw courier on partition `a` of the same unit — the partitions
do not overlap, so it looks free. Every step works in isolation: `mkfs`
succeeds, the filesystem mounts, a tar extracts onto it, `cc` compiles what
arrived. Then filesystem I/O on partition `g` starts failing:

```
hp1: not ready
hp16: hard error sn8 er1=5<RMR,ILF> er2=0
```

and `tar` stops after four of six files while still exiting 0. Mixing raw and
buffered access on one `hp` unit does not work. Splitting them by unit does.

The cost is capacity: the work area becomes `/usr` on the system disk, which
has about **88 MB free**, rather than a dedicated 149 MB filesystem. See
capacity planning below.

Host side:

```bash
tools/tapeio.py pack-disk   <dir> work/courier.disk --offset 0 --size 8132608
tools/tapeio.py unpack-disk work/courier.disk <dir> --offset 0
```

Guest side — the courier is treated as a tape, because tar neither knows nor
cares where its sequential blocks come from:

```
/etc/mknod /dev/rrp1a c 4 8        # unit 1, partition a
chmod 600 /dev/rrp1a
mkdir /usr/v10
cd /usr/v10 && tar xvfb /dev/rrp1a 1        # in
cd /usr/v10 && tar cvfb /dev/rrp1a 1 .      # out
sync
```

`hp` minor numbers are `unit << 3 | partition`, so unit 1 gives `a` = 8,
`b` = 9, `g` = 14. Majors are block 0 / char 4. RP06 geometry is 22 sectors ×
19 surfaces = 418 sectors/cylinder × 815 cylinders = 340,670 sectors, matching
`hp6_sizes` in `sys/dev/hp.c` exactly; partition `a` is the first 8.1 MB.

**Do not stage the archive through an intermediate file.**
`tar cvfb /tmp/out.tar 20 .` writes exactly one 10,240-byte record, stops
mid-file, and exits 0 — in testing it captured 5 of the 8 blocks of the first
file and nothing else. `ulimit` does not exist on V8, so this is not a
file-size limit; it is tar's blocking-20 write path. Writing straight to the
device with blocking 1 archives everything.

## Raw transfers must be 512 bytes. This is not optional

Every raw transfer to or from the `hp` character device has to be one sector.
`work/rawwrite.exp` walks the sizes and writes back what it wrote:

| Transfer | Write | Read back |
|---|---|---|
| 512 B (1 sector) | 128/128 records | 128/128, `cmp` silent |
| 1024 B (2 sectors) | 64/64 records | **short: 11 records** |
| 2048 B (4 sectors) | 32/32 records | **short: 4 records** |
| 4096 B (8 sectors) | **1 record, then `write: I/O error`** | short |
| 10240 B (20 sectors) | **1 record, then `write: I/O error`** | short |

```
hp10: hard error sn0 er1=5<RMR,ILF> er2=0
write: I/O error
```

`RMR` is "register modification refused", `ILF` "illegal function". Partition
`g` fails identically, so this is the device, not the partition, and it is not
contention — nothing else was mounted during the probe.

**The dangerous part is that `tar` hides it.** `tar xvfb … 20` *appears* to
work on input, because tar tolerates short reads. `tar cvfb /dev/rrp1a 20`
also appears to work on output — it lists every file and reports no error —
but only the first 10,240 bytes reach the disk. A 30,720-byte archive silently
became 10,240 bytes. Trust `dd`'s record counts, never tar's file list.

This bit the verification script too, which is worth recording: it compared
only the five small files, all of which fitted inside the one record that did
get written, and so printed "ROUND-TRIP VERIFIED" for a transfer that had lost
its tail. A round-trip check has to include the *last and largest* item in the
archive or it proves nothing about truncation.

For Track B, note that much of the "get it out" problem is illusory: anything
the guest builds onto a disk is *already* a host file. The courier only matters
for patches, logs and small artifacts.

## Traps, each of which cost real time here

**The tape route panics the kernel.** V8's `ht` driver does a 16-bit read of a
Massbus device register, and SIMH refuses it:

```
>>MBA1: invalid adapter read mask, pa = 0x20012404, lnt = 2
machine check type x0: rd timeout fault
panic: mchk
```

`mba_rdreg` in `VAX/vax7x0_mba.c` rejects any non-longword access — *except*
when compiled for the VAX 750, where a comment concedes that the 750's own
boot ROMs do exactly this and "this code works on real hardware". Classic SIMH
3.12-5 carries the same guard, so this is a long-standing limitation rather
than an open-simh regression. `installV8` never hit it because that tape
extraction runs under **4.1BSD**, not V8. Do not spend an afternoon on tape:
use the disk.

**`mkfs` counts 1K blocks; the partition table counts 512-byte sectors.**
Partition `g` is 291,280 sectors, so the argument is **145,640**. Passing the
sector count builds a filesystem claiming twice the space it has — which
appears to work, then corrupts. (Only relevant if you do build a second
filesystem; the design above does not.)

**Neither filesystem in the golden image has a `lost+found`.** So an autoboot
`fsck` that needs to reconnect an unreferenced inode cannot, and gives up:

```
/dev/rrp0g: SORRY. NO lost+found DIRECTORY
/dev/rrp0g: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.
Automatic reboot failed... help!
```

leaving a single-user shell instead of `login:`. This is a crash-resilience
hole in the shipped app, not just a test annoyance: `cc` leaves temp files in
`/usr/tmp`, and an abrupt kill orphans them. Reproduced twice here. The repair
is one command per filesystem, and belongs in the image build:

```
cd /     && /etc/mklost+found
cd /usr  && /etc/mklost+found
```

**V7 tar's name field is 100 bytes, with no prefix field.** ustar splits long
paths into `prefix` + `name`; V7 tar cannot see `prefix`, so a ustar archive
silently truncates. `tapeio.py` writes `--format=v7` and refuses to build an
archive containing an over-long path unless told `--allow-long-names`. Expect
this to matter for the V10 tree.

**The golden image's own tape nodes address hardware that isn't there.**
`/dev/rmt1` is `c 22 0`, and char major 22 is the `mt` driver — a TU78. SIMH
emulates no TU78. The nodes are faithful to the real Alice machine, which had
one; they are simply wrong for this emulator. (`installV8`'s throwaway proto
`/dev` used `c 5 0`, the correct `ht` major, which is why it looked like tape
worked.)

**Directories are trailing-slash names, not typeflag `5`.** `--format=v7`
gets this right; a Python `tarfile` USTAR archive would not.

## Verification

`work/mediatest.sh` is a one-shot proof with a watchdog and trap cleanup. It
rebuilds its media from `rp06v8.golden` every run — a previous failure left
the system disk dirty and the next boot's autoboot fsck gave up, so the
harness must not inherit state. It boots V8 with the courier attached, makes
the node, repairs `lost+found`, extracts a host-built tar into `/usr/v10`,
compiles it with V8's own `cc`, runs it, writes a tar back onto the courier,
restarts the simulator, and confirms the work area survived. The host then
unpacks the courier and compares.

Result, 2026-08-09 — all markers reached, `expect` exit 0:

```
a ./binary.dat 8 blocks        same: hello.c
a ./hello.c 1 blocks           same: makefile
a ./makefile 1 blocks          same: marker.txt
a ./marker.txt 1 blocks        same: binary.dat
a ./sys/dev/skew.h 1 blocks    same: sys/dev/skew.h
a ./hello 17 blocks            plus: hello — 8239 B, a.out little-endian
                                     32-bit demand paged pure executable
ROUND-TRIP THROUGH V8 VERIFIED
```

That last line is the interesting one: a VAX binary compiled *inside* V8,
carried out on the courier, and identified as a genuine `a.out` by the host.

The round-trip check deliberately includes the largest, last item in the
archive. An earlier version compared only the five small files, all of which
fitted inside the single record that a truncated write did deliver — and so
reported success for a transfer that had lost its tail. A truncation check
that does not test the tail tests nothing.

## Capacity planning for Track B — superseded

**This section is history.** It sized the V10 tree against a courier disk and
concluded that ingest had to be selective. netfs (B0.5, N5-N7) deleted the
problem rather than easing it: the tree is **served, not copied**, so nothing
lands on guest disk, no subtree has to be chosen, and B1 mounted all 25,682
files at `/n/v10` (`tools/v10-probe.sh`, `tools/v10-toolchain.sh`). The
courier survives for the one thing netfs cannot carry -- a whole disk image.

The measurements were right and are kept because they are what made the
courier route look as bad as it is:

| Archive | Compressed | Expanded | Files |
|---|---|---|---|
| `v10src.tar.bz2` | 74.9 MB | **243.3 MB** | 23,977 in 1,100 dirs |
| `v10blit.tar.bz2` | 2.6 MB | 8.6 MB | 1,373 in 100 dirs |

The work area was `/usr`, with about **88 MB free**, and one courier load is
**8.1 MB** (25 MB using partition `b` as well). V8 has no `bzip2`, `gzip` or
`compress`, so everything arrives expanded. 243 MB against 88 MB does not fit,
and would not fit a 149 MB RP06 partition either; `cmd/` alone is 125.5 MB
across 14,642 files. At 8.1 MB a load that is thirty round trips of manual
staging, which is why B0.5 was scoped up instead.

**One good surprise, still true:** the longest stored path in `v10src` is
**51 bytes** and in `v10blit` **35** -- nothing anywhere near V7 tar's 100-byte
name field. The truncation risk that `tapeio.py` guards against does not
materialise for V10.

If the full tree is ever wanted in one place, give the work filesystem its own
controller: `RQ` is already configured as `uda1` with `ra1`/`ra3`/`ra5`
attaching at boot, so an MSCP disk is a different controller from `hp`
entirely — exactly what the one-role-per-unit rule wants. Untested; V8's 1985
`uda` driver predates SIMH's default RD54, so the drive type would need setting
explicitly (V8 knows the RA81 at 456 MB).
