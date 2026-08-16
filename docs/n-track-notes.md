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

### IP, and the one-word bug that hid it

**V8 resolves names on the real Internet.**

```
# /tmp/dnsq www.bell-labs.com 10.0.2.3
asking 10.0.2.3 for www.bell-labs.com (35 byte query)
reply: 130 bytes, id 4b21, rcode 0, 1 question(s), 3 answer(s)
www.bell-labs.com has address 184.24.254.233
THE INTERNET IS REACHABLE FROM V8
```

That answer travelled from a real nameserver, through SLiRP's NAT, across our
NI1010 model, up V8's streams IP and UDP, and into a program compiled by a 1985
C compiler. `tools/n3-internet.exp` sets it all up the way the CSRC's own
`usr/src/cmd/inet/READ_ME` prescribes; `tools/v8/dnsq.c` builds the query by
hand, because V8 predates every resolver library.

**The bug was one number, and it failed in total silence.** SLiRP offers
10.0.2.0/24, so the interface's network was declared as `10.0.2.0` — the
obvious reading. But V8 is strictly **classful**: `ip_subr.c`'s `in_netof()`
masks a 10.x address with `IN_CLASSA_NET`, giving **10.0.0.0**. So
`ip_ifonnetof()` compared 10.0.0.0 against the interface's 10.0.2.0, matched
nothing, returned 0, and every outbound datagram was dropped without a
diagnostic anywhere. Subnetting did not exist when this code was written.

The interface's network must therefore be `10.0.0.0`:

```
$ cat /usr/inet/lib/networks
10.0.0.0	slirp-net
$ ipconfig /dev/il0 v8 slirp-net /dev/il1 &
```

What made it findable was the device model's own tracing rather than anything
in the guest. With `set il debug=CMD`, a whole failing session logged exactly
five commands — `ILC_OFFLINE`, `ILC_RESET`, `ILC_STAT`, `ILC_ONLINE`, one
`ILC_RCV` — and **no transmit command at all**. That put the fault above the
driver and above SLiRP in one step, which is worth remembering: the emulator is
the only honest observer in a stack this old.

**The first query after boot always times out.** Resolution is asynchronous —
`arp_resolve` drops the datagram and asks `ipconfig` to ARP for the next hop —
so the datagram that triggers the ARP is itself lost. The second query
succeeds against a warm cache. That is 1985 behaviour, not a defect.

Other things worth knowing:

- **`route(8)` reaches the IP layer through `/dev/ip0` specifically.** The
  minor number of a `/dev/ip*` node is the IP protocol number — hence `ip6` for
  TCP and `ip17` for UDP — and 0 serves as a control channel. Without that node
  `route add` fails, quietly enough to miss.
- The kernel config has `pseudo-device uarp 1` and no `arp`, so `NARP` is 0 and
  `NUARP` is 1. That is correct: `ipconfig` *is* the ARP daemon. But note
  `ip_ld.c` guards its `IPIOARP` case with `#if NARP > 0` while still setting
  `IFF_ARP` and ACKing when that is false, so a genuinely half-configured
  interface would still look healthy.
- `ipdstate[]` is `[256]`, so protocol 17 is in bounds; `pseudo-device inet 6`
  bounds the *interface* array `ipif[]`, not the protocol table.

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

## N4/N5/N6 — a macOS folder mounted inside V8 *(2026-08-10)*

The wire format is [netfs-protocol.md](netfs-protocol.md) (N4). This is the
implementation and what it cost.

### Getting there needs nothing forwarded, on either platform

The guest dials **10.0.2.2** and lands on the host's **127.0.0.1**. That is not
a coincidence or a SIMH feature — it is SLiRP's alias rule, `tcp_fconnect()` in
`slirp/tcp_subr.c`:

```c
if ((so->so_faddr.s_addr & slirp->vnetwork_mask.s_addr) ==
    slirp->vnetwork_addr.s_addr) {
  /* It's an alias */
  if (so->so_faddr.s_addr == slirp->vnameserver_addr.s_addr) { ... }
  else addr.sin_addr = loopback_addr;
}
```

Any address inside the virtual network that is not the nameserver is rewritten
to loopback. So the server binds `127.0.0.1` and needs no port forwarding, no
host interface, and no entitlement — **which is what makes this work inside the
iOS sandbox unchanged**, where an app may talk to its own loopback and nothing
else. The same mechanism the DZ terminal lines already rely on.

### The server: Swift, and shared with the app from the start

`netfs/` is a SwiftPM package with two targets. `NetFS` is the whole server and
depends on Foundation and POSIX sockets only — no Network.framework, no
Dispatch assumptions — because N7 compiles these same files into the iPad app.
`netfsd` is a thin `main()` so the desktop can drive it.

Four decisions came out of V8's headers rather than out of taste:

- **Synthetic inode numbers.** `types.h` has `typedef u_short ino_t`, and every
  inode number that passes through a directory is 16 bits wide. APFS hands out
  64-bit ones. The server keeps a 1…65535 namespace with a stable
  host(dev,ino) → ours map.
- **The export root is inode 2.** `iget()` crosses a mount by rewriting `ino`
  to `ROOTINO` and re-looking-up, so `NGET(dev, 2)` is the first request on
  every fresh mount and there is no other way to name the root.
- **Directories are forged.** There is no readdir opcode; `ls` `read(2)`s
  16-byte `struct direct` records out of the directory as if it were a file.
  macOS will not let you read a directory at all, so the server builds the
  image itself, once per handle, so that the size it reports and the bytes a
  later `NREAD` returns cannot disagree.
- **14-byte names, in lookup as well as listing.** A host file whose name is
  longer can only be *named* by its truncation, so `NNAMI` matches truncated
  names too. Otherwise every long-named file is one the guest can see and
  cannot open.

`tools/netfs-probe.py` speaks the protocol exactly as `neta.c` does and answers
a dozen questions in under a second, against five minutes for a cold boot. It
found every framing bug before a VAX was involved, and it doubles as the
executable form of the protocol document.

### The client: fifty lines, and two traps

`tools/v8/nmount.c` is the whole guest side. `gmount` is **syscall 49** and has
been in libc since 1985 (`usr/src/libc/sys/gmount.s`), `/dev/tcp*` is a stream
device (`&tcpdinfo` in `conf.c`'s cdevsw), and `nadomount` only wants a
connected stream — so there is no new file system code anywhere in this phase.

Two things cost time:

- **`tcpconfig` is not optional.** N3 pushed the UDP line discipline onto
  `/dev/ip17`; TCP needs the same onto `/dev/ip6` (`./tcpconfig /dev/ip6 &`,
  prescribed in `usr/src/cmd/inet/READ_ME`). Without it, opening `/dev/tcp01`
  succeeds, writing the `tcpuser` succeeds, and the connect then blocks
  forever with no diagnostic anywhere — there is simply nothing underneath the
  device.
- **The `/dev/tcp` minor must be odd.** `tcp_device.c` refuses an even minor
  whose socket is not already active, because even minors are the accept side:

  ```c
  if((dev&01) == 0 && (so->so_state&SS_ACTIVE) == 0)
          return(0);
  ```

  libin's `tcp_sock()` encodes this as `for(n = 01; n < 100; n += 2)` and never
  says why. The CSRC's own READ_ME shows it in the file modes: `/dev/tcp00` is
  `crw-------`, `/dev/tcp01` is `crw-rw-rw-`.

### The real work: netfs cannot run over a byte stream unmodified

The mount succeeded on the first try and `ls` immediately failed:

```
# ls -l /n/macos
read -1 expected 112
total 0
```

That is the client's own message, from `send()` in `neta.c`. The cause is four
lines in `usr/sys/sys/streamio.c`:

```c
case M_DATA:
        n = min(count, bp->wptr - bp->rptr);
        if (n) bcopy(bp->rptr, addr, n);
        addr += n; nc += n; count -= n;
        freeb(bp);              /* the whole block, not just the n copied */
        continue;
```

`istread()` copies at most `count` bytes out of a stream block and frees the
**entire** block. On Datakit that is a definition, not a bug: one write is one
message is one block. On TCP the 48-byte reply header and its payload are two
`write()`s on the server that arrive as one block, so the header read keeps 48
bytes and discards the payload, and the next read times out with nothing left.

**No amount of server-side care fixes this.** Pacing the two writes far enough
apart to land in separate segments is a race against SLiRP's poll, and its
failure mode is silent data loss.

Fixing that exposes a third bug behind it, and the message barely changes:

```
# ls -l /n/macos
read -1 expected 0
```

`naread()` sends `NREAD` unconditionally and lets a short answer end the loop,
so the last read of every file gets `y.count == 0` and `send()` calls
`istread(cip, buf, 0)`. On Datakit that returned 0, because a zero-length
`write()` arrives as an `M_DELIM` and `istread` has a case for it. TCP has no
zero-length anything, so the read waits for a block that will never come and
times out at −1. The count in that message is the only thing distinguishing
this from the first bug, which is worth knowing before staring at it.

The fix is to make `istread` a byte-stream reader — return 0 for a zero-length
read, keep the remainder of a partly consumed block, and keep waiting until
`count` is satisfied — and it is safe because the function has exactly one
caller in the entire kernel:

```
$ grep -rn 'istread\|istwrite' usr/sys/ | grep -v streamio.c
usr/sys/sys/neta.c:654,662,668,673,677
```

netfs is the only user, so this changes netfs and nothing else. It is also the
porting work the authors expected — `usr/src/netfs/README`: *"The code here
assumes it is talking to Datakit in several places. If you want to use another
network, you'll have to fix things."*

The edit is `tools/v8/streamio-istread.ed`, applied and rebuilt by
`tools/drive-streamfix.sh`; `/unix.n3` keeps the pre-fix kernel and
`/usr/sys/sys/streamio.c.orig` the pristine source, so the script is
idempotent and reversible.

### And a fourth: the stream head is 512 bytes wide

`istread` fixed, small files worked and the first big one did not. The guest
said

```
istread: timeout, got 0 want 48 more
```

— not a truncated reply but *no reply at all*, while the server's log showed it
written. That is a different failure from the first three, and it needed the
`printf`s: `send()` turns every stream failure into a bare `EIO` at the system
call, so from userland a netfs read that dies has five possible causes and no
way to tell them apart. Three one-line diagnostics in `istread`/`istwrite` —
no logic change — named the path in one run, and they stay in.

`q->count` on a stream queue is **bytes**, not blocks (`putq` adds
`bsize[bp->class]`), and the stream head's read queue is declared

```c
struct	qinit strdata = { strput, NULL, nulldev, nulldev, 512, 256 };
```

so it goes `QFULL` at 512. `tcpdisrv` only moves data upward
`while((q->next->flag&QFULL) == 0)`, so a reply larger than that cannot all
reach the reader. Widened to 8192/4096 — a buffering limit on a read queue, so
the cost is memory, and every stream gets more slack before flow control,
which is not a behaviour anyone can observe on a tty.

### The fifth bug was ours, and it was in the Ethernet controller

Widening the stream head was necessary and not sufficient. Replies of 48+512
bytes worked indefinitely; 48+1024 never arrived at all, with the server's log
showing the reply written and the guest saying `istread: timeout, got 0 want 48
more`. I capped the server at 512, wrote the limit up as a **measured bound**
with `rbsize[] = { 4, 16, 64, 1024 }` named as a suspect, and said plainly that
it was a hypothesis rather than a diagnosis.

It was not a V8 limitation at all. It was `libsimh/patches/pdp11_il.c` — our
own NI1010 model, written in N2 and exercised since only by 42-byte ARP
requests and 130-byte DNS replies.

`ill.c` expects the controller to **chain** a frame across as many receive
buffers as it needs, one interrupt per buffer:

```c
is->len -= (bp->wptr - bp->rptr);          /* this buffer's programmed size */
if(is->len <= 0) goto done;                /* frame complete -- deliver */
if((bp->wptr - bp->rptr) % 8) goto done;   /* "not chaining" marker */
if(is->nbp == 0) ilsetup(is, addr, is->len);   /* ask for another buffer */
return;                                    /* wait for the next interrupt */
```

`ILOUTSTANDING` is **1**, so the driver supplies the next buffer from inside
that same handler. Our model did this instead:

```c
n = total + IL_HDRLEN;
if (n > rb->bc)                            /* truncate, as asked */
    n = rb->bc;
```

— one buffer per frame, truncate the rest. And `allocb()` caps a block at
`rbsize[3]` = 1024 bytes, so **every frame over ~1024 bytes needed two buffers
and got one**. `ilrint()` was left with `is->len > 0`, waiting for an interrupt
that was never coming. The receive path did not drop a packet; it stopped.

That is why the symptom was so unhelpful. A truncating controller loses data
and says so; a controller that forgets to chain simply goes quiet, and every
layer above it reports a timeout on something it never saw.

The comment in our own model is where the error is preserved: *"A frame longer
than the supplied buffer is truncated rather than dropped: ilsetup() explicitly
asks for truncation by shortening the last buffer."* That reads `ilsetup`
backwards. It shortens a buffer by 2 — making its size not a multiple of 8,
which is the "stop here" marker — **only** when the remaining length exceeds
`ETHERMTU`, i.e. for a genuinely oversized frame. In the ordinary case it
supplies full buffers and expects them to be filled in sequence.

Fixed by `il_rxpump()`: hand over as much as the buffer at the head of the
queue will take, interrupt, and continue when `ILC_RCV` supplies the next one.
One buffer per call, which is not a simplification but the contract. The
in-flight frame is in the register list, so a `save` mid-chain restores
correctly.

**With that fixed the cap is gone**: `netfsd` serves full `BUFSIZE` replies and
all 23 checks pass with `-m 0`. The same read that took 241 requests at 512
bytes takes 184 uncapped.

The lesson is worth more than the fix. **A limit you measure through an
emulator is a property of your emulator until proven otherwise** — and I had
written it into the protocol document, where it would have misled anyone
reimplementing netfs on real hardware. It is now recorded there as the mistake
it was.

### What it does, measured### What it does, measured

With that in place, `tools/drive-netfs.sh` passes all 23 checks:

```
# ls -l /n/macos
total 3
-rw-r--r--  1  root    0         23 Aug 10  2026 README
-rw-r--r--  1  root    0         27 Aug 10  2026 a-name-that-is
drwxr-xr-x  2  root    0         32 Aug 10  2026 empty
-rw-r--r--  1L root    0         23 Aug 10  2026 link-to-readme
drwxr-xr-x  5  root    0         80 Aug 10  2026 src
# cat /n/macos/README
hello from macOS, 2026
```

The one that matters is the checksum. V8's own `sum(1)` over a 13,200-byte
file read through netfs agrees with the same V7 rotate-and-add computed on the
host, both in place and after `cp`-ing it to local disk — so every 512-byte
round trip carried exactly what it claimed to. The truncated name
`a-name-that-is` opens and reads the file whose real name is 34 characters,
the symlink is resolved by the client, and a write to the read-only export is
refused with `EROFS`.

## N7 — Research Unix writes to macOS *(2026-08-10)*

The write half needed no new protocol work: `NWRT`, `NTRUNC`, `NUPDAT` and the
`NNAMI` side effects (`NCREAT`, `NDEL`, `NLINK`) were written alongside the read
side and gated behind one flag, so N7 was mostly a matter of turning it on and
checking what actually landed. `tools/drive-netfs-rw.sh` asserts against the
**host filesystem**, not against what the guest said:

```
== verdict: what actually landed on macOS ==
  ok    from-v8 exists with its content
  ok    the appended line is there
  ok    fromv8dir/inner exists
  ok    the unlinked file is gone from the host too
  ok    chmod 600 reached APFS
  guest sum of /tmp/big.h : 26092 64
  host  sum of big.h      : 26092 64
  ok    a 65385-byte file written by V8 is byte-identical on APFS
  ok    mtime is 2026, not a century out
```

65,385 bytes assembled inside V8 (`cat /usr/include/*.h`), summed there by V8's
own `sum(1)`, copied out through netfs, and summed again on the host with the
same V7 rotate-and-add. Equal, so every round trip carried what it claimed to.

### The century-old timestamps

Files arrived on APFS dated **1926**. That is not a rounding error, it is a
sign:

```c
/* usr/src/netfs/work.c, doupdat */
x->ta += dtime;
```

`dtime` is `client_clock - server_clock` (`main.c`: `x->ta - time(...)`), so a
client time converts to a host time by *subtracting* it. Adding gives
`2*client - server`. On two machines whose clocks agree — which is every pair
of machines the authors had — `dtime` is 0 and the bug is invisible. Ours are a
half-century apart, because V8 boots believing it is 1976, so the error is the
whole skew and it shows up in Finder.

Corrected in `Export.update`, with the reference behaviour quoted next to it so
nobody "fixes" it back. Worth noting how it was caught: not by a test that knew
to look, but by the `ls -lR` the driver prints at the end for context. The
check now exists.

### What did not need doing

Ownership is deliberately not forwarded. Every file is presented as the
configured uid/gid, so a `chown` from the guest would be changing a mapping the
guest cannot see — and applying it to the host would hand a 1985 machine
control over macOS file ownership. `NUPDAT` accepts mode and times and stops
there.

## How fast is it, and what that means for B1

`tools/drive-throughput.sh` times a multi-megabyte read out of the host and
checks the bytes as well as the clock, because a fast wrong answer is not an
answer. 4,194,304 bytes, arriving byte-exact (v7sum `07677 4096` on both
sides):

| | elapsed | rate |
|---|---|---|
| `cp /n/macos/bulk /tmp/bulk` | 42 s | **97.5 KB/s** |
| `cat /n/macos/bulk > /dev/null` | 41 s | **99.9 KB/s** |

One second in forty separates "read it and write it to the RP07" from "read it
and throw it away", so **netfs is the bottleneck and the disk is not** — which
is the useful thing to know, because it means the number does not improve by
touching the guest's storage.

Extrapolated:

- 14.87 MB — what the courier plan called the B1 subset: about 2.5 minutes.
- The whole 243 MB V10 tree: about 40 minutes.

  *(B1 in the end copied neither: the tree is served at `/n/v10` and read in
  place. These remain the right numbers for moving bulk over netfs.)*

Both are fine. For comparison the courier moved 8.1 MB per manual
attach/extract cycle, so this is not merely faster but a different kind of
activity — a mount you forget about rather than a procedure you schedule.

Measured on the desktop `vax780` with SLiRP and the default 4096-byte
`BUFSIZE` replies. V8's clock has one-second resolution and no shell can reach
anything finer, which is why the test moves megabytes: whole seconds are only a
usable ruler when there are enough of them.

## Patch whole functions, not context

The first version of that edit was four small `ed` commands anchored on
context — `/stenter(ip)) == NULL/`, `/nc && (OTHERQ/`, `/freeb(bp);/`. Every
one of those lines appears **verbatim in `stread()` as well**, eighty lines
earlier, because `stread` is the same loop written for user reads. One edit
landed there instead, and since `stread` takes no `count` argument the kernel
failed to compile with

```
"../sys/streamio.c":249:count undefined
```

at a line number nowhere near the one being aimed at — while a `sed -n
'/^istread/,/^}/p'` of the result looked perfect, because it only ever printed
the function that was fine.

Two things came out of that. **Replace the whole function from its one unique
anchor** (`/^istread(ip, addr, count)/` then `.,/^}/d` and insert), so the
result cannot depend on what the rest of the file happens to look like. And
**rehearse guest edits on the host**: `ed` on macOS runs the same script against
`work/v8src/`'s copy in about a second, against ten minutes for a boot-and-
build cycle, and a `diff` of the neighbouring function proves the edit stayed
where it was put. The verification step now also prints `sum` of the pristine
source, because "does the guest's copy match TUHS?" was the question the
failure actually turned on and there was no way to answer it after the fact.

### A test that fails honestly

The first verdict run reported nine failures, of which several were the *test's*
fault: `grep -E` matches a line at a time, so every check written as one
multi-line regex (`'MARKER(.|\n)*README'`) could never match no matter what the
guest did. A check that cannot pass looks exactly like a feature that does not
work. Both drivers now cut the section out with `sed` first and grep single
lines, which is the only way to spell this that fails for the right reason.

## Idling — one config line and three missing flags *(2026-08-09)*

SIMH ships an idle pattern for **4.1BSD**, and V8's kernel is 4.1BSD-derived,
so it already matches. `vax_cpu.c` looks for an `FFS` that finds nothing, at
IPL 0, in system space below 0x3000. `sys/locore.s` obliges exactly:

```
sw1:	ffs	$0,$32,_whichqs,r0	# look for non-empty queue
	bneq	sw1a
	mtpr	$0,$IPL			# must allow interrupts here
	brw	sw1			# this is an idle loop!
```

The config line is necessary but nowhere near sufficient. **`sim_idle()` sleeps
only when the unit at the *head* of the event queue carries `UNIT_IDLE`**
(`sim_timer.c`) — so a single periodic unit without the flag pins the host CPU
no matter how well the guest's idle loop is recognised. Three units on this
machine were missing it, and they had to be fixed together: unblocking one just
promotes the next one to the head of the queue.

| Unit | Rescheduled | Present when |
|---|---|---|
| `sim_con_units[0]` (CON-TELNET) | every 1 s | `set console telnet=` — i.e. always, in the app |
| `clk_unit` (TODR) | every 10 ms | always: the calibrated 100 Hz clock |
| `tmr_unit` (TMR) | every 10 ms | always: V8 programs the interval timer and leaves it running |

All three are upstream omissions rather than decisions, and `UNIT_IDLE` is read
nowhere in SIMH except `sim_idle()` and the `SHOW QUEUE` label, so setting it
cannot change device behaviour:

- **CON-TELNET** — `sim_console.c` sets `UNIT_IDLE` explicitly on both *remote*
  console units a few hundred lines further down, but not on the local one.
  Keystroke latency is unaffected either way: console input arrives through
  `tti_unit`, which is already `UNIT_IDLE` and polls at the clock rate.
- **TODR** — every other VAX in the tree sets it, including the 730 and 750
  whose TOY-clock unit is byte-identical (`UDATA (&clk_svc, UNIT_FIX,
  sizeof(TOY))` plus the same `sim_rtcn_init_unit(&clk_unit, CLK_DELAY,
  TMR_CLK)`) and which are declared `UNIT_IDLE+UNIT_FIX`. Only 780, 820 and 860
  drop it — one omission copied twice.
- **TMR** — missing on all five big VAXen (730/750/780/820/860, exactly the
  models with a separate interval timer; the MicroVAX-class models fold it into
  `clk_unit` and mark that idle-capable). Sleeping until the guest's own tick is
  precisely what idling *means*, and `sim_idle()` is only ever reached from
  `cpu_idle()` — i.e. when the guest is already in its recognised do-nothing
  loop — so there is nothing to lose by waiting for it.

All three are in `libsimh/patches/apply.sh`.

### Measurements

`tools/idle-probe.py` runs the app's exact SIMH topology under the library
build, boots V8 to `login:`, samples host CPU in three windows, dumps
`SHOW QUEUE` (which annotates each entry `(Idle capable)`), and with `--why`
turns on `INT-CLOCK debug=IDLE` for half a second and histograms
`sim_idle()`'s own "Can't idle: <unit>" messages — which name the offender
outright.

| State | Idle CPU | `--why` says |
|---|---|---|
| console patch only | 31–42% | head of queue is TODR or TMR |
| + TODR `UNIT_IDLE` | 41% | **100%** of refusals: TMR |
| + TMR `UNIT_IDLE` | **3.1%** | no refusals at all |

In the Mac app, cold-booted to `login:` and measured per thread
(`tools/app-cpu.sh`, which also runs `sample(1)` to name the threads):

| Thread | Before | After |
|---|---|---|
| `simh-vax780` | ~72% | **2.7%** — `sample` shows it in `sim_idle` → `nanosleep` in 1321 of 1373 samples |
| `dmd-5620` | — | 63.5% (unchanged; see below) |

Correctness checks, all passed: V8's own clock advanced **90 s while the host
advanced 90.1 s** (`--clock 90`), so nothing is lost by sleeping through ticks;
login, `date` and the shell stay responsive; and `work/verify-libcli.sh`'s
boot → suspend → save → restore round trip is unaffected.

Two things worth knowing:

- The **dmd (5620) thread is a separate 63.5%** (at the default "Fast" 2× =
  20 MHz) and never idles at all — dmd_core has no idle detection. It is not
  the same problem, but it *is* tractable: `libdmd/test/idle-scope.c` shows a
  settled terminal spends ~86% of its time in a 54-byte PC window
  (0x5354–0x5389), and `dmd_get_pc()` is already exported, so the same
  recognise-the-idle-loop trick could be done from Swift with no core changes.
- Idling must be re-established **after** `restore`. `save` records
  `sim_idle_enab` and `cpu_idle_type` (both are `REG`s) but not
  `cpu_idle_mask`, and the mask is what the FFS test actually reads — so a
  restored machine would come back looking idle-enabled while matching VMS's
  pattern instead of 4.1BSD's, and quietly spin. The `UNIT_IDLE` flags
  themselves are safe across a snapshot: restore only takes the bits in
  `UNIT_RFLAGS` (`UNIT_UFMASK|UNIT_DIS`), and `UNIT_IDLE` is not among them, so
  the compiled-in value always wins.
