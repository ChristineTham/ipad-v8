# Track B infrastructure: a bigger disk, real networking, a real file server

*Design doc, written 2026-08-09. Supersedes the disk-courier approach in
[media-exchange.md](media-exchange.md), which stays valid as a bootstrap but is
too small and too manual to build V10 on. Every claim here was checked against
the sources named; nothing is from memory.*

## Why scope up

The courier moves 8.1 MB per load through a raw disk partition. V10's source is
**243.3 MB expanded across 23,977 files**, and `/usr` currently has ~88 MB free.
Compiling V10 needs far more room than that, and a manual pack/attach/extract
cycle is the wrong shape for iterative work.

Three changes fix it properly, and the third is work the iPad app needs anyway
(mounting user-chosen folders from the Files app):

1. A **516 MB disk** instead of 174 MB.
2. **Real TCP/IP** out of the emulated VAX, including to the Internet.
3. A **host-side file server** over that network, replacing the courier.

## Where the sources live

| What | Path |
|---|---|
| Extracted V8 distribution | `work/v8src/` |
| V8 kernel source | `work/v8src/usr/sys/` |
| Kernel config actually built | `work/v8src/usr/sys/alice/conf` |
| netfs client (in-kernel) | `work/v8src/usr/sys/sys/neta.c` (710 lines) |
| netfs wire protocol | `work/v8src/usr/sys/h/neta.h` |
| netfs server + client, source | `work/v8src/usr/src/netfs/` |
| A second server implementation | `work/v8src/usr/net/face/` |
| Interlan NI1010 driver | `work/v8src/usr/sys/dev/il.c` (663 lines) |
| NI1010 registers | `work/v8src/usr/sys/h/ilreg.h`, `h/ill_reg.h` |
| V8 TCP/IP stack | `work/v8src/usr/sys/inet/` |
| open-simh checkout | `work/opensimh/` |
| V10 tarballs | `work/v10src.tar.bz2`, `work/v10blit.tar.bz2` |

---

## 1. Disk: RP07, and no new code on either side

**SIMH and V8 agree exactly.** `opensimh/PDP11/pdp11_rp.c` defines
`RP07_SECT 50`, `RP07_SURF 32`, `RP07_CYL 630`, and lists `RP07` in `drv_tab`.
V8's `dev/hp.c` has an `hpst[]` entry `50, 32, 50*32, 630, hp7_sizes`. Identical
geometry, so `set rp0 rp07` is all the simulator needs and V8's `hp` driver
autoconfigures the type from the drive.

`hp7_sizes` (units are 512-byte sectors):

| Partition | Sectors | Size | Extent |
|---|---|---|---|
| `a` | 15,884 | 8.1 MB | cyl 0–9 — **root** |
| `b` | 64,000 | 32.8 MB | cyl 10–49 — **swap** |
| `c` | 1,008,000 | 516 MB | whole disk (overlaps everything) |
| `d` | 504,000 | 258 MB | cyl 0–314 |
| `e` | 504,000 | 258 MB | cyl 315–629 |
| **`f`** | **928,000** | **475 MB** | cyl 50–629 — **`/usr`** |

`a` + `b` + `f` tile the disk without overlap, so that is the layout. 475 MB of
`/usr` holds the whole 243 MB V10 tree with ~230 MB spare for objects.

**The filesystem was never the limit.** From `h/ino.h`: the inode's 40 address
bytes are "39 used; 13 addresses of 3 bytes each" — **24-bit block numbers**, so
16,777,216 blocks × 1 KB = a 16 GB ceiling. `h/filsys.h` has `s_fsize` as
`daddr_t` (32-bit) and `s_isize` as `unsigned short`; at `INOPB` 16 that caps the
i-list near a million inodes. RP07 is nowhere near any of these.

RP07 is the largest type the `hp` driver knows (`eagle` is 371 MB, `eag48`
414 MB). MSCP could reach 622 MB with an RA82 — SIMH's `RQ` supports RA60/70/71/
72/73/80/81/82/90/92 — but that means trusting V8's 1985 `uda` driver against
drive types it may predate, for 20% more space. Not worth it.

**Reminder from the courier work:** `mkfs` takes **1 K blocks**, while the
partition table is in 512-byte sectors. Partition `f` is 928,000 sectors, so the
argument is **464,000**. Passing the sector count silently builds a filesystem
twice the size of its partition.

### Migration

Booting does not depend on a boot block: the harness does `load -o bootV8 0`
then `run 2`, and `bootV8` reads `hp(0,0)unix`. So the new disk needs correct
filesystems and `/unix` in the root of partition `a` — nothing more exotic.

Sketch: attach the RP06 golden as `rp0` and a fresh RP07 as `rp1`; `mkfs` the
RP07's `a` and `f`; `mklost+found` on both (see below); copy root and `/usr`
across; fix `/etc/fstab` to `/dev/rp0a:/:rw` and `/dev/rp0f:/usr:rw`; make the
device nodes for `f`; halt; re-attach the RP07 alone as `rp0` and boot.

`hp` minor numbers are `unit << 3 | partition`, so unit 0 gives `a` = 0,
`b` = 1, `f` = 5. Majors: block 0, char 4. So `/dev/rp0f` is `b 0 5` and
`/dev/rrp0f` is `c 4 5`.

**Carry the `lost+found` fix forward.** The current golden image shipped without
one on either filesystem, so an autoboot `fsck` that needed to reconnect an
orphaned inode aborted to a single-user shell instead of `login:`. Run
`/etc/mklost+found` in `/` and `/usr` on the new image; `work/fix-lostfound.exp`
is the existing recipe.

---

## 2. Networking

### The SIMH half is already done

The built simulator reports:

```
ETH devices:
 eth0	nat:{optional-nat-parameters}        (Integrated NAT (SLiRP) support)
 eth1	udp:sourceport:remotehost:remoteport (Integrated UDP bridge support)
```

**Integrated NAT (SLiRP)** — userspace NAT, no libpcap, no root, no host
interface configuration. This matters well beyond convenience: it is the only
form of networking available inside an App Store sandbox, so the same mechanism
serves desktop Track B *and* the eventual iPad app. No entitlement is needed for
a userspace NAT that never touches a raw socket.

### The gap

SIMH's only VAX-780 Ethernet is **XU (DEUNA/DELUA)**, `opensimh/PDP11/pdp11_xu.c`.

V8 has **no DEUNA driver**. `dev/` contains exactly two Ethernet drivers:
`il.c` (Interlan NI1010) and `ec.c` (3Com). Neither is emulated by SIMH, and
neither is in the current kernel config.

Also worth knowing before touching this: **V8 has no `ifnet` abstraction.** Its
TCP/IP is streams-based — `inet/` holds `ip_ld.c`, `tcp_ld.c`, `udp_ld.c`, and
`ip_ld.c` opens with *"ip line discipline, to be pushed on an ethernet
controller."* BSD network driver source cannot be ported across directly.

### Decision: model the NI1010 in SIMH

| Option | Effort | Risk | Verdict |
|---|---|---|---|
| **SIMH NI1010 device model** | ~500 lines | Low–moderate | **Chosen** |
| V8 DEUNA driver | Larger | High | Rejected |

The NI1010 is a trivially simple UNIBUS DMA controller — **three 16-bit
registers** (`h/ilreg.h`):

```c
short il_csr;   /* command and status */
short il_bar;   /* buffer address */
short il_bcr;   /* byte count */
```

CSR bits: `IL_EUA 0xC000` (extended Unibus address), `IL_CMD 0x3f00` (command),
`IL_CDONE 0x0080`, `IL_CIE 0x0040` (command interrupt enable), `IL_RDONE 0x0020`,
`IL_RIE 0x0010` (receive interrupt enable), `IL_STATUS 0x000f`.

Nineteen commands, of which only a handful matter operationally — `ILC_RESET`
(0x3f00), `ILC_ONLINE` (0x0900), `ILC_OFFLINE` (0x0800), `ILC_RCV` (0x2000,
supply receive buffer), `ILC_XMIT` (0x2900) and `ILC_LDXMIT` (0x2800). Loopback
(`ILC_MLPBAK`/`ILC_ILPBAK`/`ILC_CLPBAK`), promiscuous (`ILC_PRMSC`/`ILC_CLPRMSC`),
receive-on-error, multicast (`ILC_LDGRPS`/`ILC_RMGRPS`), `ILC_STAT`, `ILC_DELAYS`,
`ILC_DIAG` and `ILC_FLUSH` can be stubbed or minimally answered.

Standard CSR is `0164040` (`ilstd[] = {0164040}` in `dev/il.c`); the driver
registers `uba_driver ildriver = { ilprobe, 0, ilattach, 0, ilstd, "il", ildinfo }`.

By contrast the DEUNA is a ring-buffer/port architecture, and we would have to
drive it from V8's unfamiliar streams framework rather than porting `if_de.c`.

**We are not reverse-engineering.** `h/ilreg.h` plus `dev/il.c` is a complete
specification of everything the model must satisfy — the driver *is* the
conformance test.

### Use 4.3BSD twice

The TUHS 4.x BSD VAX images are worth pulling in for two distinct reasons:

1. **As a control experiment.** Boot 4.3BSD under SIMH with `XU` + `nat:` and
   reach the Internet. That proves the SIMH NAT plumbing independently of our
   own device model, so if the NI1010 misbehaves later we know the fault is
   ours. Cheap, and it tests the riskiest assumption first.
2. **As a second independent spec.** 4.2/4.3BSD ships **`if_il.c`**, its own
   NI1010 driver. Two independent driver implementations to validate the
   hardware model against is a real argument for the NI1010 over the 3Com part.

### Kernel work

`alice/conf` already carries the software side, added during `installV8`:

```
pseudo-device   inet    6
pseudo-device   uarp    1
pseudo-device   tcp     32
pseudo-device   udp     32
```

but **no Ethernet device at all**. Adding `device il0 at uba? csr 0164040 ...`
and rebuilding is the change. `installV8` already rebuilds the kernel
(`/etc/config`, `make` in `/usr/sys/alice`), so the mechanism is proven — but
configuring a device that has never been present in this image is new, and is
the second-largest risk after the device model itself.

---

## 3. The file server, over TCP

With real networking the earlier serial-transport problem disappears.

**The client is already in the kernel.** `conf/files` lists
`sys/neta.c standard` — compiled into every V8 kernel, including the one running
now. No rebuild needed for netfs itself.

**The transport is explicitly pluggable.** From `usr/src/netfs/README`:

> "The code here assumes it is talking to Datakit in several places. If you want
> to use another network, you'll have to fix things. **The only true requirement
> is that there be a stream driver for the network.**"

And `usr/src/netfs/NOTES` records the authors benchmarking it with "the server
and setup connected through a pipe, instead of the network" — 12 s versus 66 s
to `cat` the same 1 MB file. Non-Datakit transports are the authors' own tested
configuration, not our speculation.

**The mount takes a file descriptor.** From `usr/src/netfs/setup.c`:

```c
fd = callfs(p->who);                        /* Datakit dial -> a stream fd */
write(fd, &version, 1);                     /* version handshake */
write(fd, (char *)&x, sizeof(x));
read(fd, (char *)&y, sizeof(y));
gmount(RMFSTYP, p->dev, 0, fd, p->mount);   /* mount the fd */
```

So a **TCP socket** works: V8 has `inet/socket.c`. Replacing `callfs()` with a
connect is the whole client-side change, and the shipped `/usr/net/setup` binary
(which dials Datakit and cannot work here) gets replaced by a small custom
client rather than patched.

### Wire protocol

`h/neta.h`, `NETVERSION 1`. Sixteen operations:

| | | | |
|---|---|---|---|
| `NSTAT` 1 | `NWRT` 2 | `NREAD` 3 | `NFREE` 4 |
| `NTRUNC` 5 | `NUPDAT` 6 | `NGET` 7 | `NNAMI` 8 |
| `NPUT` 9 | `NROOT` 10 | `NDEL` 11 | `NLINK` 12 |
| `NCREAT` 13 | `NOMATCH` 14 | `NSTART` 15 | `NIOCTL` 16 |

Request `struct senda` carries version, cmd, flags, `trannum`, uid/gid, dev,
tag, mode, newuid/newgid, ino, count, offset, a `char *buf` (a pointer in the
struct — the payload follows on the wire, exact framing to be read out of
`neta.c`), and `ta`/`tm` times. Reply `struct rcva` carries `trannum`, errno,
flags, dev, size, mode, uid, gid, tag, nlink, ino, count and `tm[3]`.

Deriving the exact on-wire layout — field order, VAX alignment and padding, how
payloads follow the header, which ops the kernel actually emits — is a careful
read of `neta.c` and is the first task of this phase. `usr/src/netfs/work.c` and
`sys.c` are the reference server implementations to check the reading against.

Permissions come from `/usr/net/people` (client uid/gid → server uid/gid, per
machine); mounts from `/usr/net/friends` (service name, mount point, unique id
64–255, debug flag). Both are documented in `usr/man/man8/netfs.8`.

**Documenting this wire format is a preservation artifact in its own right** —
it has never been written down outside the source.

---

## Plan

Results as phases land: [n-track-notes.md](n-track-notes.md).

| Phase | Work | Risk |
|---|---|---|
| **N0** | RP07 image + migration + `lost+found`. No new code — **done** | Low |
| **N1** | 4.3BSD under SIMH with `XU` + `nat:` reaching the Internet — control experiment | Low |
| **N2** | `pdp11_il.c`: NI1010 model wired to `sim_ether` | **Highest** |
| **N3** | V8 kernel rebuild with `il0`; ping the outside world | High |
| **N4** | Derive and document the netfs wire format (`docs/netfs-protocol.md`) | Moderate |
| **N5** | Host netfs server over TCP, read-only first | Moderate |
| **N6** | Guest client (~50 lines: socket, handshake, `gmount`) | Low |
| **N7** | Widen to read/write; then port the server into the app for Files access | Moderate |

Order matters: N0 unblocks everything and cannot fail interestingly; N1 tests
the riskiest external assumption cheaply, before N2 commits to building on it.

**Fallbacks.** The RP06 golden image stays untouched, so N0 is reversible. If
the NI1010 model stalls at N2, the courier still works for the B1 subset
(14.87 MB, which fits `/usr` today) and Track B can proceed on the toolchain
while networking is sorted out separately. Nothing in the ladder's first five
rungs actually requires the network.

**Unknowns worth stating.** UNIBUS DMA mapping in N2 is the part most likely to
bite. `neta.c`'s exact framing in N4 is unread. And no V8 kernel in this project
has ever been configured with an Ethernet device, so N3's config line is
untested.
