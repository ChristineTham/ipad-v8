# The Research Unix netfs wire protocol

**Phase N4. Status: derived and measured, 2026-08-10.** Not yet exercised
against a live server — that is N5.

This describes the on-the-wire protocol spoken by the network file system built
into every Eighth Edition kernel. As far as we can tell it has never been
written down: `usr/man/man8/netfs.8` documents the *administration*, and the
protocol itself has only ever existed as the intersection of two programs that
were compiled together.

Everything here is derived from V8's own sources —

| | |
|---|---|
| `usr/sys/h/neta.h` | the two structures and the sixteen opcodes |
| `usr/sys/sys/neta.c` | the in-kernel client (710 lines); `send()` is the framing |
| `usr/src/netfs/main.c` | connection setup and `respond()` |
| `usr/src/netfs/start.c` | the server's dispatch loop |
| `usr/src/netfs/work.c` | the reference implementation of each operation |
| `usr/src/netfs/setup.c` | the client-side mount program |

— and the byte layout was **measured on the machine itself** rather than
reasoned about, with `tools/v8-netfs-probe.exp`. That mattered: both structures
contain hand-written `rsvd` padding fields, which is evidence the author was
working around his compiler's alignment rather than relying on it, and guessing
where 1985 VAX `pcc` inserts a hole is exactly the sort of assumption that has
already been wrong once in this project. The header the probe compiled is
byte-identical to the one quoted here (`sum` = `62745 1` on both the shipped
image and the TUHS copy).

## The one-sentence version

The client writes a 52-byte `struct senda` as raw memory, optionally followed
by a payload; the server writes back a 48-byte `struct rcva`, optionally
followed by a payload. There is no marshalling, no byte-order conversion, no
length prefix and no framing beyond the fixed structure sizes.

## Transport requirements — read this before writing a server

The protocol was designed for a Datakit **stream driver**, and it inherits two
assumptions from it.

**1. It is message-oriented, and the code says so three separate times.**

```c
/* usr/src/netfs/main.c, connection setup */
i = read(children[n].fd, cmdbuf, sizeof(cmdbuf));   /* cmdbuf is 256 bytes */
if(i != 1 || x->version != NETVERSION) goto awful;  /* ... but must read 1 */

/* usr/src/netfs/start.c, the request loop */
n = read(myfd, cmdbuf, sizeof(cmdbuf));
if(n != sizeof(struct senda)) leave(3);
```

Each `read()` asks for 256 bytes and then *insists* on getting exactly 1, or
exactly 52. That works when every `write()` is a message and every `read()`
returns exactly one. **Over TCP it is false in both directions**: a short read
can split a header, and Nagle can deliver a header and its payload coalesced
into one 66-byte read, which this server would reject and then `leave(3)`.

So a TCP server must read *by length* — loop until 52 bytes are in hand, then
loop for exactly the payload — and must never trust a read boundary.

**And that is the easy half.** *(Corrected 2026-08-10, after N6 ran into the
other half.)* The server can be made to read by length because we are writing
it. The client cannot, because it is a 1985 kernel — and it does something
strictly worse than mis-framing. `usr/sys/sys/streamio.c`:

```c
case M_DATA:
        n = min(count, bp->wptr - bp->rptr);
        if (n)
                bcopy(bp->rptr, addr, n);
        addr += n; nc += n; count -= n;
        freeb(bp);              /* the whole block, not just the n copied */
        continue;
```

`istread()` copies at most `count` bytes out of a stream block and then frees
**the entire block**. Anything past `count` is discarded, silently. On Datakit
that is not a bug but a definition — one write is one message is one block, and
a short read of a message is a truncation. On TCP it is data loss, and it
happens on the very first `NREAD`: the 48-byte reply header and its payload are
two `write()`s on the server but arrive as one block, so `istread(y, 48)` keeps
the header and throws the payload away. The guest reports

```
# ls -l /n/macos
read -1 expected 112
total 0
```

which is the client's own message from `send()`, after the follow-up read times
out with nothing left to read.

The same function has a second stream-hostile habit: with `count` unsatisfied
and the queue momentarily empty it returns what it has, so any reply larger
than one segment fails the caller's `n != y->count` test.

**Conclusion: netfs cannot run over a byte stream unmodified, and no amount of
server-side care fixes it.** Pacing the two writes far enough apart to land in
separate segments is a race whose failure mode is silent corruption. The honest
fix is four lines in `istread()` — keep the remainder of a partly consumed
block, and keep waiting until `count` is satisfied — and it is safe precisely
because `istread`/`istwrite` have exactly one caller in the entire kernel:

```
$ grep -rn 'istread\|istwrite' usr/sys/ | grep -v streamio.c
usr/sys/sys/neta.c:654,662,668,673,677
```

netfs is the only user, so making it a byte-stream reader changes netfs and
nothing else. This is the porting work the authors expected of anyone leaving
Datakit — `usr/src/netfs/README`: *"The code here assumes it is talking to
Datakit in several places. If you want to use another network, you'll have to
fix things."* The edit is `tools/v8/streamio-istread.ed`, applied by
`tools/drive-streamfix.sh`.

**2. Exactly one transaction may be outstanding.** The kernel serialises with a
per-connection lock (`cip->i_un.i_key`), commented "until demux works, use key
as a lock". No pipelining, no interleaving, no concurrency on one mount.

The authors did run it over a non-Datakit transport themselves: `NOTES` records
benchmarking "the server and setup connected through a pipe, instead of the
network", 12 s against 66 s to `cat` a 1 MB file. And `README` states the only
requirement outright — *"The only true requirement is that there be a stream
driver for the network."*

## Connection setup

Per connection, once, before any file operation:

| Direction | Bytes | Content |
|---|---|---|
| → server | 1 | `NETVERSION` (= 1) on its own |
| → server | 52 | a `senda` with `cmd = NSTART`, `trannum = 0` |
| ← client | 48 | an `rcva`; `errno == 0` means accepted |

Three fields of that opening `senda` are overloaded and carry setup data rather
than their names:

- **`ta`** = the client's `time(0)`. The server keeps
  `dtime = x->ta - time(0)` as the clock skew and adds it to every timestamp it
  is later asked to set (`work.c: doupdat`). Two machines with different clocks
  therefore agree about file times without either changing its own.
- **`uid`** = the *debug level* (`children[n].silent = x->uid`), not a user.
- **`dev`** = the device number the client will use for this mount.

On a version mismatch the server replies with `trannum = -1` and closes.
`doinit` never checks that `cmd` is actually `NSTART`.

After the handshake the mounting program hands the file descriptor to the
kernel and steps out of the way:

```c
gmount(RMFSTYP, p->dev, 0, fd, p->mount);
```

From that moment the kernel owns the fd and every subsequent byte on the
connection is kernel-generated.

## `struct senda` — the request, 52 bytes

VAX-11/780: **little-endian**, `long` 4, `short` 2, pointer 4, `time_t` 4.
Offsets measured, not computed.

| Off | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 1 | `version` | always 1; `send()` stamps it on every request |
| 1 | 1 | `cmd` | operation, see below |
| 2 | 1 | `flags` | **only** for `NNAMI`: `NDEL`, `NLINK` or `NCREAT` |
| 3 | 1 | `rsvd` | hand-written padding, always 0 |
| 4 | 4 | `trannum` | transaction number |
| 8 | 2 | `uid` | client's uid (the *debug level* in `NSTART`) |
| 10 | 2 | `gid` | client's gid |
| 12 | 2 | `dev` | which mount; server may serve several |
| **14** | **2** | *(hole)* | **compiler padding — not a field** |
| 16 | 4 | `tag` | the server's handle for an open file |
| 20 | 4 | `mode` | for `NUPDAT`, and for `NNAMI`+`NCREAT` |
| 24 | 2 | `newuid` | `NUPDAT` only |
| 26 | 2 | `newgid` | `NUPDAT` only |
| 28 | 4 | `ino` | inode number |
| 32 | 4 | `count` | payload length / bytes wanted |
| 36 | 4 | `offset` | file offset for `NREAD`/`NWRT` |
| 40 | 4 | `buf` | **a client-side pointer. Meaningless on the wire** |
| 44 | 4 | `ta` | access time (`NUPDAT`); client clock in `NSTART` |
| 48 | 4 | `tm` | modify time (`NUPDAT`) |

`buf` is a genuine pointer into the client's kernel address space that happens
to be inside the struct, so four bytes of a kernel address are transmitted on
every request. A server must ignore it. (`send()` tests it locally to decide
whether a payload follows, so it is load-bearing on the client and noise on the
wire.)

## `struct rcva` — the reply, 48 bytes

| Off | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 4 | `trannum` | echoed from the request; `-1` = version mismatch |
| 4 | 1 | `errno` | 0 = success, else a V8 errno |
| 5 | 1 | `flags` | `NNAMI` only: `NROOT` or `NOMATCH` |
| 6 | 2 | `dev` | device of the object |
| 8 | 4 | `size` | file size |
| 12 | 2 | `mode` | `st_mode` |
| 14 | 2 | `uid` | mapped to the client's namespace |
| 16 | 2 | `gid` | mapped to the client's namespace |
| **18** | **2** | *(hole)* | **compiler padding — not a field** |
| 20 | 4 | `tag` | handle to quote in later requests |
| 24 | 2 | `nlink` | link count |
| 26 | 2 | `rsvd` | hand-written padding |
| 28 | 4 | `ino` | inode number (result of `NNAMI`) |
| 32 | 4 | `count` | bytes that follow (`NREAD`), or a `NNAMI` location |
| 36 | 12 | `tm[3]` | atime, mtime, ctime — `NSTAT` only |

## Operations

Sixteen opcodes are defined. **The kernel emits nine.**

| # | Name | Emitted by the kernel? |
|---:|---|---|
| 1 | `NSTAT` | yes |
| 2 | `NWRT` | yes |
| 3 | `NREAD` | yes |
| 4 | `NFREE` | yes |
| 5 | `NTRUNC` | yes |
| 6 | `NUPDAT` | yes |
| 7 | `NGET` | yes |
| 8 | `NNAMI` | yes |
| 9 | `NPUT` | yes |
| 10 | `NROOT` | no — a *reply flag* on `NNAMI` |
| 11 | `NDEL` | no — a *request flag* on `NNAMI` |
| 12 | `NLINK` | no — a *request flag* on `NNAMI` |
| 13 | `NCREAT` | no — a *request flag* on `NNAMI` |
| 14 | `NOMATCH` | no — a *reply flag* on `NNAMI` |
| 15 | `NSTART` | not by the kernel; by `setup` at connection time |
| 16 | `NIOCTL` | **never used at all** — defined and dead |

So opcodes 10–14 never appear in `cmd`; they live in `flags`, sharing a number
space with the commands. A server switching on `cmd` needs exactly nine cases —
which is precisely what `start.c` has, with `default: leave(4)`.

### The eight simple ones

All send `uid`, `dev`, `ino` and (except `NGET`) `tag`, and expect a reply with
no payload.

- **`NGET`** — by `dev`+`ino`, open a handle. Reply carries `tag`, `mode`,
  `nlink`, `size`, `uid`, `gid`. This is how a client turns an inode number
  into something it can use.
- **`NPUT`** — release the handle. The kernel sends `NUPDAT` first if the
  inode is dirty.
- **`NFREE`** — "the client thinks `nlink` has reached 0". The reference
  server does nothing but acknowledge.
- **`NTRUNC`** — truncate to zero.
- **`NSTAT`** — the only operation that returns `tm[3]`.
- **`NUPDAT`** — set mode, owner and times. `newuid`/`newgid` are the target
  owner; `uid` is the *requesting* user, and the server enforces "only root may
  chown". `ta`/`tm` of 0 mean "leave it", which the server implements by
  comparing against `dtime` after adding the skew.
- **`NREAD`** / **`NWRT`** — below.

### Payload rules

Only three operations carry data, and the rule is uniform: **the payload always
follows its header as a separate write, never inside it.**

```c
/* client, sys/sys/neta.c: send() */
n = istwrite(cip, (char *)x, sizeof(*x));                 /* the header    */
if(x->count > 0 && x->buf && x->cmd != NREAD)
        n = istwrite(cip, x->buf, x->count);              /* request body  */
n = istread(cip, (char *)y, sizeof(*y), 0);               /* the reply     */
if(y->errno == 0 && x->cmd == NREAD)
        n = istread(cip, x->buf, y->count, 0);            /* reply body    */
```

| Op | Request payload | Reply payload |
|---|---|---|
| `NWRT` | `count` bytes to write at `offset` | — |
| `NNAMI` | `count` bytes of name (`count` is always `DIRSIZ` = 14, NUL-padded) | — |
| `NREAD` | — (`count` is the *request*) | `y.count` bytes |

`NREAD` is the exception that proves the rule: `count` is non-zero and `buf` is
set, but the guard `x->cmd != NREAD` suppresses the request-side write, because
for a read `count` means "how much I want".

**`count` is bounded by `BUFSIZE` = 4096** (`sys/h/param.h`), measured on the
image. The kernel loops, issuing one request per 4 KB, until the user's
`read`/`write` is satisfied.

**A short reply is not EOF — only a *zero-length* one is.** *(Corrected
2026-08-10; the N4 reading of this was wrong and it matters.)* `naread()`'s
loop is

```c
	} while(u.u_error == 0 && u.u_count != 0 && n > 0);
```

so a reply carrying fewer bytes than were asked for, but more than none, simply
makes the client come back for the rest at the new offset. That is what makes
it safe for a server to cap its replies if it ever needs to, and
it is the only signal for end of file: `y.count == 0`, nothing else.

On a read where the server returns fewer bytes than its own header promised,
the client writes a **zero-length message** and abandons the connection:

```c
printf("read %d expected %d\n", n, y.count);
istwrite(cip, (char *)x, 0);      /* shut it down */
```

### `NNAMI` — the interesting one

`NNAMI` is path resolution, one component at a time, and it carries the whole
namespace protocol. The request sends the parent's `tag`/`dev`/`ino` plus a
14-byte component name as payload; `flags` optionally asks for a side effect:

| `flags` | Meaning |
|---|---|
| 0 | plain lookup |
| `NDEL` (11) | look up **and unlink** |
| `NLINK` (12) | create a link; `dev`/`ino` name the *existing* file |
| `NCREAT` (13) | create if absent, with `mode` (already masked by `umask`) |

and the reply's `flags` answers with one of:

| `flags` | Meaning |
|---|---|
| 0 | found; `ino`, `dev`, `tag`, `mode`, `nlink`, `size`, `uid`, `gid` valid |
| `NOMATCH` (14) | no such entry — not an error unless the client wanted one |
| `NROOT` (10) | found, **and it is the server's root** |

`NROOT` is the mount-point escape hatch: it tells the client that `..` has
walked out of the exported subtree, so the client can substitute its own mount
point and continue resolving locally. Without it a remote `..` would escape the
export. The server raises it whenever the result is its root and the component
was not `"."`.

Because resolution is per-component, a path of *n* components costs *n* round
trips, each serialised by the connection lock. That, and not bandwidth, is what
makes netfs feel slow on a high-latency link.

## There is no reply-size limit in the protocol

*(Recorded 2026-08-10, and then corrected the same day.)* This section used to
say "keep each reply under about 560 bytes", with a table of measurements and a
suspicion about `rbsize[]`. That was a real measurement of a real failure and
it was **not a property of netfs**: replies over ~1024 bytes vanished because
*our* SIMH NI1010 model handed each frame to exactly one receive buffer, while
`ill.c` expects the controller to chain a frame across as many as it needs.
`allocb()` caps a block at 1024 bytes, so any larger frame needed two buffers,
got one, and left the driver waiting for an interrupt that never came.

It is written down here because the mistake is instructive for anyone
reimplementing this protocol elsewhere: **a limit you measure through an
emulator is a property of your emulator until proven otherwise.** The
correction lives in [n-track-notes.md](n-track-notes.md); the fix is in
`libsimh/patches/pdp11_il.c`. `netfsd` serves full `BUFSIZE` replies.

## Three things the structures do not tell you

These are not in `neta.h` and cost real time in N5. Each is load-bearing: get
any of them wrong and the mount either fails outright or, worse, half-works.

### The export root must be inode 2, and there is no other way to name it

Nothing in the mount hands the client a root handle. `nadomount` records the
mount point and the stream and stops. The root arrives later, from `iget()`,
which crosses a mount by rewriting the request:

```c
/* usr/sys/sys/iget.c */
if((ip->i_flag&IMOUNT) != 0) {
        for(mp = &mount[0]; mp < &mount[NMOUNT]; mp++)
                if(mp->m_inodp == ip) {
                        dev = mp->m_dev;
                        ino = ROOTINO;          /* <- always 2 */
                        fstyp = mp->m_fstyp;
                        goto loop;
                }
```

So the first request on any fresh mount is `NGET(dev, 2)`, and a server whose
export root is anything else is unreachable. The reference server gets this by
accident — it exports host `/`, whose inode number on a 1985 filesystem *is* 2
(`sys.c`: `dev = children[n].dev; newdev(statb.st_dev); newnetf("/", -1, 0);`).
A server exporting a subdirectory has to map it deliberately.

### Inode numbers are 16 bits, not 32

The wire field is a 32-bit `long`, which is misleading. `usr/sys/h/types.h`:

```c
typedef	u_short	ino_t;
typedef	u_short	dev_t;
```

and every inode number that survives a round trip through a directory is
narrowed to 16 bits on the way. **A server cannot pass host inode numbers
through.** APFS hands out 64-bit inode numbers as a matter of course, and even
truncated to 32 they would collide in the directory field. A synthetic
1…65535 namespace, stable for as long as the client holds a reference, is the
only workable design.

### There is no directory operation, so the server must forge directories

Sixteen opcodes and not one of them reads a directory. That is not an omission:
in 1985 a directory *is* a file, and `ls` opens it and `read(2)`s 16-byte
records out of it. Those reads arrive as ordinary `NREAD`s on a directory
handle.

```c
/* usr/sys/h/dir.h -- the whole format */
#define	DIRSIZ	14
struct	direct {
	ino_t	d_ino;		/* 2 bytes, little-endian */
	char	d_name[DIRSIZ];	/* 14 bytes, NUL-padded */
};
```

A modern host server therefore has to **synthesise** the directory image: `.`,
`..`, then one 16-byte record per entry. macOS will not let you `read(2)` a
directory at all, so there is nothing to pass through even in principle. Two
consequences follow. The `size` reported by `NGET`/`NSTAT` for a directory must
be the size of the *synthesised* image, not the host's `st_size`, or the
client's read loop stops in the wrong place; and because the image is a
snapshot, it should be built once per handle so that size and content cannot
disagree.

The same 14 bytes bound lookup. `NNAMI` carries `DIRSIZ` bytes of name, so a
host file whose name is longer can only ever be *named* by its truncation — and
if the server does not match truncated names in lookup, every long-named file
it lists is a file the guest can see and cannot open.

## Transaction numbers

`trannum` is **not a netfs sequence number**. It is the kernel's global
system-call counter:

```c
/* sys/h/systm.h */
long    trannum;                /* incremented each system call */
```

`send()` bumps it once more per request, purely for uniqueness. So the values a
server sees are monotonically increasing but sparse and unpredictable — do not
treat gaps as lost messages, and do not expect it to start at any value.

The client's matching rule is worth copying exactly:

- `y.trannum == tn` → this is our reply.
- `y.trannum < tn` → a stale reply from the "distant past". **Discard it and
  read again**, without complaint. This is how the client resynchronises after
  a timeout or a dropped request.
- `y.trannum > tn` → unrecoverable; the connection is torn down.
- `y.errno != 0` → accepted *without* checking `trannum` at all.

## Permissions and configuration

`/usr/net/people` maps client uid/gid to server uid/gid per machine, and
`/usr/net/friends` lists the services to mount: service name, mount point, a
unique id in 64–255, and a debug flag. Both are documented in
`usr/man/man8/netfs.8`. The server re-reads them roughly every ten minutes
(`start.c`: `if(rdnum % 20 == 4) permredo();`).

## Bugs and traps in the original source

Recorded because anyone reimplementing this will meet them.

- **`y` is declared with two different types.** `main.c` and `work.c` say
  `struct rcva y`; `start.c` says `struct senda y`. In K&R C these are
  tentative definitions that the linker merges into one common block sized to
  the largest — 52 bytes — so `respond()` still writes `sizeof(struct rcva)` =
  48 and the wire is correct. It is benign *only* because `senda` happens to be
  the bigger of the two. Anyone building this with a compiler that defaults to
  `-fno-common` (GCC 10+, Clang 11+) gets a duplicate-symbol error, and anyone
  who "fixes" it by making both `senda` would put 52 bytes on the wire and
  break every reply.
- **`doinit` ignores `cmd`.** Any opcode is accepted as the opening message.
- **The 256-byte `cmdbuf` is larger than a `senda`** and is read into with
  `sizeof(cmdbuf)`. On a message transport the excess is harmless; on a stream
  it is how header and payload get silently merged.
- **`doupdat` reads `i` uninitialised** when neither the mode nor the owner
  changed, then tests `if(i)`.
- **`x->count` is trusted** as a length to allocate and read (`getbuf(x->count)`).
  A server exposed to anything untrusted needs a ceiling; `BUFSIZE` is the
  client's own limit and the natural one.

## What N5 has to build

A host server speaking this protocol needs, in order:

1. **A length-driven reader.** Read exactly 1 byte, then exactly 52, then the
   payload by `count`. Never trust a read boundary.
2. **Little-endian VAX field packing** at the offsets tabulated above,
   including the two padding holes, and a 4-byte pointer field that is written
   as zero and ignored on receipt.
3. **A handle table** mapping `tag` → an open host file, plus `dev`/`ino`
   identities that stay stable for as long as the client holds them.
4. **Nine operations**, of which `NNAMI` is most of the work.
5. **uid/gid mapping** — even if the first version maps everything to one user,
   the fields have to be filled in coherently or the client's own permission
   checks will refuse things the server would allow.

Read-only is a genuine milestone: `NGET`, `NNAMI`, `NREAD`, `NSTAT`, `NPUT`
and `NFREE` are enough to mount a host directory and read it. `NWRT`,
`NTRUNC`, `NUPDAT` and the `NNAMI` side effects can come with N7.

## What it costs: one round trip per path component

Measured across stages 1–5 of the 2026-08-11 world build — 115,446 requests in
about 31 minutes:

| | | |
|---|---:|---|
| `NNAMI` | 34,795 | 30% |
| `NGET` | 34,184 | 30% |
| `NPUT` | 34,181 | 30% |
| `NREAD` | 6,258 | 5% |
| `NSTAT` | 5,933 | 5% |
| `NUPDAT` | 101 | |

**Only 5% of requests move data.** The rest is path resolution, and the reason
is in the client rather than the wire format. `nanami()`
(`v8/usr/sys/sys/neta.c`) copies characters into `u.u_dbuf` until `/` or NUL,
capped at `DIRSIZ` = 14, sets `x.buf = u.u_dbuf`, and sends. One component,
one exchange. So

```
/n/src/usr/src/cmd/ccom/vax/../common/reader.c
```

costs about ten `NNAMI` exchanges before a byte is read — and a compiler opens
dozens of files per translation unit. `naget`/`naput` appearing in a 1:1 ratio
says the same thing about attributes: no netfs inode survives between uses, so
every access re-fetches it and releases it again.

At ~16 ms a request the emulated VAX spends 92% of a build waiting, which is
why `vax780` sits at 6–8% CPU while compiling. That 16 ms is itself the
calibrated 10 ms clock tick plus overhead: `libsimh/patches/pdp11_il.c` polls
the NI1010 receive path with `sim_clock_coschedule(uptr, tmxr_poll)`, so a
reply that lands just after a poll waits most of a tick.

Two consequences worth keeping separate. **Bulk copying over this share is
hopeless** — about 30 files a minute regardless of file size, which is why
stage 8 lifts 2264 runtime files off a mounted disk with `cpio` in four
seconds instead. **Compiling over it is fine but slow**, and the fix is to cut
the number of round trips rather than the time each takes. We own both ends —
the client is `neta.c`, the server is `netfs/Sources/NetFS` — so resolving a
whole path in one exchange is available, and it is worth roughly ten times
more than tuning the poll interval.

## Sources

All paths relative to the V8 tree (`work/v8src/`), from TUHS.

- `usr/sys/h/neta.h`, `usr/sys/h/systm.h`, `usr/sys/h/param.h`, `usr/sys/h/dir.h`
- `usr/sys/sys/neta.c`, `usr/sys/sys/trap.c`
- `usr/src/netfs/{main,start,work,setup}.c`, `usr/src/netfs/{README,NOTES,fserv.h}`
- `usr/man/man8/netfs.8`
- Measurement: `tools/v8-netfs-probe.exp`, run against a scratch copy of
  `work/myv8/rp06v8.golden`; raw output in `work/myv8/v8-netfs-probe.log`.
