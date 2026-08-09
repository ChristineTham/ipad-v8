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

## N1 — SLiRP, reduced *(2026-08-09)*

N1 was specified as "boot 4.3BSD under SIMH with XU + `nat:` and reach the
Internet", as a control experiment proving the NAT plumbing before N2 built on
it. It was **reduced rather than run**, for a reason worth recording: there is
no ready-made 4.3BSD SIMH image at TUHS, only distribution tapes, so the
control experiment turns out to cost a multi-hour install or a large download
from a third party — far more than the risk it retires.

What was actually done, and what it establishes:

- `attach xu nat:` succeeds and SLiRP initialises, reporting the network it
  offers: **10.0.2.0/24, gateway 10.0.2.2, DNS 10.0.2.3, DHCP from 10.0.2.15**.
  Frames pass (`Packets Sent: 2` from its own loopback self-test). So SLiRP is
  compiled in and functional at the `sim_ether` boundary.
- The rest of N1's value — a second, independent NI1010 specification in
  4.2/4.3BSD's `if_il.c` — was unnecessary. V8's own `dev/ill.c` is the driver
  that has to work, so it *is* the conformance test, and N2/N3 used it directly.

The diagnostic N1 was meant to provide (is a failure ours or SLiRP's?) is
available anyway through `set il debug=CMD;INT;PKT;DAT`, which shows every
frame at the model's own boundary. In the event N3 worked first time, so the
question never arose.

## N2/N3 — the NI1010 works, and V8 is on Ethernet *(2026-08-09)*

**V8 sends and receives real Ethernet frames.** The proof:

```
# /tmp/arping 10.0.2.2
controller address: 02:07:01:00:00:01
sent 42 byte arp request for 10.0.2.2
got 42 bytes, op 2
sender  hardware address: 52:55:0a:00:02:02
ARP ROUND TRIP OK
```

`52:55:0a:00:02:02` is SLiRP's synthetic MAC for 10.0.2.2 — the `52:55` prefix
followed by the address in hex. A second request to 10.0.2.3 answered from
`52:55:0a:00:02:03`. `ilstat` afterwards: 2 in, 3 out, **no errors of any
kind**.

Device: `libsimh/patches/pdp11_il.c` plus `apply.sh` for the four integration
edits. Scripts: `tools/n3-ilkernel.{exp,sh}` (kernel rebuild),
`tools/n3-arp.exp` and `tools/v8/arping.c` (the test), run by
`tools/run-v8exp.sh`.

### The plan named the wrong driver

`conf/files` says `dev/ill.c optional il device-driver`. **`dev/il.c` is never
built.** The two differ in ways that matter: `ill.c` is the streams driver
(`#include "../h/stream.h"`, a `streamtab`), it uses the richer `h/ill_reg.h`
rather than `h/ilreg.h`, and its `ilstd[]` is `{ 0 }` — no default CSR, so the
config line must carry `csr 0164040`.

### What the driver pins down

Reading `ill.c` closely was the whole job; four details would each have been a
silent failure:

- **Reading the CSR clears CDONE and RDONE but must preserve STATUS.**
  `ilattach` spins until CDONE and *then* reads the status back.
- **The board inserts the source address.** `ilfixheader` copies the
  destination over the source field and skips six bytes, so what reaches the
  controller is destination (6), type (2), data — "the normal ethernet header
  with the source field removed".
- **A received frame is a 4-byte prefix then the frame including its CRC**, and
  `ilr_length` counts the CRC but not the prefix. `ilrint` checks
  `ilr_length - sizeof(struct il_rheader)` against [46, 1500] and later
  re-derives the frame as `ilr_length - 4`. Host networks strip the CRC, so the
  model appends four bytes to keep that arithmetic true.
- **`ILC_LDXMIT` accumulates; only `ILC_XMIT` transmits.** `ill.c` defines
  `BOGUS` — commented "CDONE doesn't work" — and because of it feeds the
  controller one buffer at a time.

### Two vectors, and where they had to go

`ilprobe` writes `ILC_OFFLINE|IL_CIE`, waits for a command interrupt, then does
`cvec -= 4`. So the command vector is base+4 and the receive vector is the
base. V8 confirms the arithmetic:

```
il0 at uba0 csr 164040 vec 0340 ipl x14
```

SIMH assigned vectors 0xE0/0xE4 = 0340/0344 octal, the probe saw 0344 and
reported 0340. BR5 has all 16 interrupt bits allocated in `vax780_defs.h`, so
IL's two live on BR4 — they must be *consecutive* bits, because SIMH maps a
multi-vector DIB's ack routines to consecutive bits from `IVCL`'s base. BR4
costs nothing: V8 guards with `spl6()`, which blocks both levels.

### auto_tab addresses are relative to the I/O page

`{0164040}` in SIMH's autoconfigure table puts the device at
`IOPAGEBASE + 0164040`, which is outside the 8 KB I/O page entirely. The table
stores the offset from `0160000`, so the entry is **`{04040}`** — compare the
CH11 at 0164140, which appears there as `04140`.

### The MAC proves the DMA

`ilattach` learns the controller's address from the `ILC_STAT` DMA and from
nothing else, so `ENIOADDR` returning `02:07:01:00:00:01` is the end-to-end
check that a 66-byte DMA landed exactly where the UNIBUS map said it would.

### Odds and ends

- **`attach il nat:` is flaky immediately after a previous NAT session** —
  repeated `Sockets: bind error 13 - Permission denied` and a hung attach.
  Waiting a few seconds and retrying works. Same family as the documented tmxr
  "bind error 48" trap: SLiRP's sockets outlive the process briefly.
- **`telnet` is useless in a scripted test.** It sits in its command loop
  printing prompts forever when stdin is not a terminal. `tools/v8/arping.c`
  exists because of that, and is a better instrument anyway — it needs none of
  the IP stack, so a failure points at the device model.
- **V8's userland libc has no `bcopy`.** It is a kernel routine.

## Idling — one config line, no kernel change *(2026-08-09)*

SIMH ships an idle pattern for **4.1BSD**, and V8's kernel is 4.1BSD-derived,
so it already matches. `vax_cpu.c` looks for an `FFS` that finds nothing, at
IPL 0, in system space below 0x3000. `sys/locore.s` obliges exactly:

```
sw1:	ffs	$0,$32,_whichqs,r0	# look for non-empty queue
	bneq	sw1a
	mtpr	$0,$IPL			# must allow interrupts here
	brw	sw1			# this is an idle loop!
```

Measured at the `login:` prompt with `set cpu idle=4.1BSD`:

| Configuration | CPU |
|---|---|
| desktop `vax780`, no idle setting | **97%** |
| desktop `vax780`, idle enabled | **18%** |
| ditto with the DZ attached | **25%** |
| `libsimh` CLI, local console | **30%** |

**A telnet console blocks idling entirely.** `sim_idle()` refuses whenever the
next scheduled event belongs to a unit without `UNIT_IDLE`, and
`sim_con_poll_svc` reschedules itself every second for as long as a telnet
console is configured — from a `sim_con_unit` declared without that flag. This
reads as an oversight: `sim_console.c` sets `UNIT_IDLE` explicitly on both
*remote* console units a few hundred lines further down. `libsimh/patches/apply.sh`
adds it. Keystroke latency is unaffected, because console input arrives through
`tti_unit`, which is already `UNIT_IDLE` and polls at the clock rate.

In the app (`set cpu idle=4.1BSD` in both `boot.conf` and `resume.conf`), the
SIMH thread went from **100% to ~72%** — a real gain, but not the ~25% the
desktop reaches, so **something further is still suppressing it** and this is
not finished. Two things are worth knowing before picking it up:

- The **dmd (5620) thread is a separate ~33%** and never idles at all.
  dmd_core paces its WE32100 against the wall clock and has no idle detection;
  that is an unrelated problem with a different fix.
- Idling must be re-established **after** `restore`. `save` records
  `sim_idle_enab` and `cpu_idle_type` (both are `REG`s) but not
  `cpu_idle_mask`, and the mask is what the FFS test actually reads — so a
  restored machine would come back looking idle-enabled while matching VMS's
  pattern instead of 4.1BSD's, and quietly spin.
