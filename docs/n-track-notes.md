# B0.5 (the N track) — implementation notes

*Results and gotchas as each phase of [networking-plan.md](networking-plan.md)
lands. The plan is the design; this is what actually happened.*

## N0 — the 516 MB RP07 disk *(done 2026-08-09)*

`work/myv8/rp07v8.golden` — 516,096,000 B, boots on its own, `/usr` grown from
141,578 KB to **459,905 KB with 408,364 KB free**. That is 399 MB of headroom
against the 243 MB V10 tree, where the RP06 had 88 MB.

Scripts: `tools/rp07probe.{exp,sh}` (fact-finding) and `tools/rp07mig.{exp,sh}`
(the migration) — in `tools/` rather than `work/` precisely because the 516 MB
image cannot enter git, so the script that rebuilds it must. Both rebuild their
media from the golden image every run and boot a *copy*, so the RP06 golden is
never the thing running and N0 stays reversible. Run it with:

```bash
tools/rp07mig.sh
```

Log: `work/myv8/rp07mig.log`.

### Root needed no filesystem copy at all

The plan assumed root would be migrated like `/usr`. It doesn't have to be:

| | RP06 (`hp6_sizes`) | RP07 (`hp7_sizes`) |
|---|---|---|
| partition `a` | 15,884 sectors, cyl offset 0 | 15,884 sectors, cyl offset 0 |

Identical extent, and both drivers compute the partition base as
`cyloff * nspc`, so partition `a` is LBA 0..15,883 on both. A host-side byte
copy of the first **8,132,608 B** is therefore a complete, valid root
filesystem — no `dump`, no `tar`, no fidelity questions about device nodes,
setuid bits or hard links. `fsck` on the result is the oracle, and it passed
before anything else was attempted.

This matters because **the image has no `/etc/dump`**. `restor` is there,
`dump` is not, so the classic `dump | restor` migration was never available.

### `/usr`, and how we know the copy is complete

`cd /usr; find . -print | cpio -pdm /mnt` — 95,238 blocks, no diagnostics.
`cpio -p` chowns, preserves mtimes and tracks multiply-linked files, and
unlike `tar` it has no 100-byte path limit.

The proof is the autoboot `fsck` on the migrated disk:

```
/dev/rp0a: 533 files 2320 blocks 5303 free
/dev/rrp0f: 8775 files 51541 blocks 408364 free
```

**8,775 files on both sides** — the source `/usr` reported exactly 8,775.
Blocks differ by 2 (51,543 → 51,541), which is directory compaction on a fresh
copy, not loss. `cc` then compiled and linked a program on the migrated `/usr`,
which exercises `ccom`, `as` and `ld`'s passes — all of which live there.

### `mkfs` is the test that V8 really saw an RP07

`hp6_sizes` has **no partition `f`** — the entry is zero. So
`/etc/mkfs /dev/rrp1f 464000` succeeding is positive proof that V8
autoconfigured the drive as an RP07 and used `hp7_sizes`, not merely that the
simulator was told `set rp1 rp07`. It reported `isize = 65488`.

That number is a ceiling, not a calculation: for the numeric-size form `mkfs`
wants `size/25` i-list blocks (18,560 here) but clamps to `MAXISIZE/NIPB` =
4,095 blocks = **65,520 inodes**, because `ino_t` is a 16-bit type. 65,520 is
comfortable against V8's 8,775 files plus V10's 23,977, but it is a hard
ceiling on any V8 filesystem and worth knowing before Track B fills it.

Remember `mkfs` counts **1 KB blocks** while the partition table counts
512-byte sectors: partition `f` is 928,000 sectors, so the argument is
**464,000**. Passing the sector count builds a filesystem twice the size of its
partition.

### Gotchas earned

- **`set noasynch` is mandatory for the desktop `vax780`, and its absence
  looks exactly like a hardware fault.** The first migration attempt threw
  `hp06: hard error sn26426 er1=5<RMR,ILF>` on *both* drives and cpio lost a
  file. The standalone open-simh binary is built **with** `SIM_ASYNCH_IO`;
  `libsimh` is not, which is why the app never needs this and why it is easy
  to forget in a hand-written config. `work/myv8/run-opensimh.conf` had it all
  along. Light I/O hides it — the probe ran without it and still fsck'd clean —
  so it only appears once two units have overlapping transfers.
- **This casts doubt on B0's "raw transfers must be 512 bytes" rule.**
  [media-exchange.md](media-exchange.md) attributes 4 KB+ raw write failures to
  a transfer-size limit, on the evidence of `er1=5<RMR,ILF>` — the identical
  signature that turned out to be nothing but a missing `set noasynch`.
  `work/rawwrite.exp` never set it either. The rule may be an artefact; it is
  flagged rather than corrected because it has not been re-tested.
- **The standalone boot's RP07 partition table disagrees with the kernel's.**
  `boot/stand/hp.c` has `hp7_off = { 0, 10, 0, 330, 340, 500, 330, 50 }`;
  the kernel's `hp7_sizes` puts `d` at 0, `e` at 315, `f` at **50**, and `g`/`h`
  at zero size. They agree only on `a`, `b` and `c`. Booting is unaffected —
  `hp(0,0)unix` is partition `a` at offset 0 on both — but anything that tries
  to boot from another partition will read the wrong cylinder.
- **A second `hp` drive is a swap device whether you want it or not.**
  `dev/swapalice.c` lists `makedev(0,9)` = `hp1b` in `swdevt`. On the RP07 that
  is cylinders 10–49, clear of partition `a` (0–9) and `f` (50–629), so it
  cannot corrupt a migration — but it is worth knowing before putting anything
  useful on a second drive's partition `b`.
- The RP07 image is **sparse**: 492 MiB logical, 98 MiB actually allocated.
  Relevant if it ever ships in the app, since the empty space is all zeros.

### Not done here

The **app still ships the RP06**. Switching the bundled image to the RP07 is a
separate decision with App Store size implications, and Track B does not need
it. `rp06v8.golden` is untouched and still boots — it now carries three extra
`/dev/rp1*` nodes that the probe created, which are inert.
