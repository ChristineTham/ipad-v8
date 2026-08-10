# Releases

*How ipnx versions the system it builds. Policy, not aspiration — the numbering
below is enforced by `tools/ipnx-release.py`, which generates the two files that
carry the version so they cannot drift apart.*

## Why Research Unix had none

Bell Labs shipped editions, not releases. The tape was a snapshot of the machine
in the lab on the day it was written, and the makefiles in it are written to
patch a **running system in place** — `usr/src/cmd/ccom/vax/makefile` installs
with

```
install: comp
	cp /lib/ccom comp.sv
	cp comp /lib/ccom
```

which is not an installation step, it is an edit to a live machine, with a
one-slot undo. There is no artifact, no manifest of what went into it, and
nothing that could be reproduced next week. `usr/sys/conf/newvers.sh` is the
whole of the version machinery, and it is one line long:

```sh
echo 'char version[] = "Unix 8th Edition '`date`'\n";' > vers.c
```

A date. Which is why the running system announces itself as *"Unix 8th Edition
Mon Aug 9 10:36:06 EDT 1976"* — the clock was wrong, and the banner has no other
opinion about what it is.

That was reasonable for a research group with one machine. It is not reasonable
for something people install, so ipnx adopts a release discipline. We can,
because [Track C](build-from-source.md) gives us the thing Bell Labs never had:
a build that produces an artifact rather than mutating a system.

## The scheme

**`Edition 8 Release M.m.p`**

The **Edition** is Bell Labs' and is not ours to increment. It changes when the
underlying system does — Edition 10 arrives via Track B and starts its own
release series at 1.0.0.

The **Release** is ours, and follows NetBSD's shape (major.minor.patch) rather
than FreeBSD's two-level scheme, because we want a place to put fixes that is
visibly not a place to put features:

| | changes when |
|---|---|
| **major** | the base system breaks compatibility for anything built against it — syscalls, `libc`, kernel ABI, header layout |
| **minor** | new functionality that does not break what already builds: drivers, utilities, subsystems |
| **patch** | fixes only. No new functionality, no new files, no interface changes |

Between releases the tree is **`-CURRENT`**; a tagged release is **`-RELEASE`**.
Both appear in the boot banner, so a machine always tells you whether it is
running something reproducible or something in flight.

### `IPNX_VERSION`, and why it is one number

FreeBSD's best idea in this area is `__FreeBSD_version`: a single monotonically
increasing integer in a header, which **ports** test against rather than trying
to parse a release string. We take it directly:

```c
#define IPNX_VERSION 8010000    /* Edition 8 Release 1.0.0 */
```

encoded as `edition × 1000000 + major × 10000 + minor × 100 + patch`. It is
monotonic *across* editions — Edition 10 Release 1.0.0 is 10010000 — so a port
can say

```c
#if IPNX_VERSION >= 8010200
```

and mean it, without knowing anything about how editions relate. V8's `cc` is
1985's, but `#if` on a defined macro is older than that, so this works in the
guest with no compiler changes.

It lives in **`v8/usr/include/ipnx.h`**, deliberately not in `<sys/param.h>`
where FreeBSD keeps its equivalent. The tape hardlinks `usr/include/sys/param.h`
and `usr/sys/h/param.h` into one 5006-byte file; git cannot store a hardlink, so
they are two files in our tree and anything added to one silently rots in the
other. A new header has no such twin.

### One source of truth

`v8/RELEASE` holds the version and the date. `tools/ipnx-release.py` generates
both `v8/usr/include/ipnx.h` and the version lines of
`v8/usr/sys/conf/newvers.sh` from it, and `--check` fails if either has drifted.
FreeBSD maintains `newvers.sh` and `sys/param.h` by hand and they do occasionally
disagree; generating is cheaper than remembering.

## What a release *is*

A release is not a git tag. It is:

1. a **git tag** `v8-R1.0.0` on the tree that produced it,
2. a **disk image** built by [stage 8](build-from-source.md) entirely from `v8/`,
   with its sha256 recorded,
3. the **`MANIFEST`** the build emitted — what went in, from which source,
4. a **[CHANGELOG](../v8/CHANGELOG.md) entry**, dated, listing what changed since
   the previous release.

Point 2 is the load-bearing one and the reason this document could not have been
written before Track C. An image assembled by patching a running machine cannot
be a release, because there is no answer to "what is in it" other than "whatever
was there before, plus whatever we did". An image built from a tagged tree has an
answer.

**0.x is the honest label for everything before that.** The images this project
has shipped so far — the golden RP06, the RP07 with `il0` and the netfs stream
fix — were made by booting the tape's binaries and editing them. They are
useful, they are reproducible in the weak sense that the scripts that made them
are in the repo, and they are **not** built from source. So:

- **0.x** — derived from the tape by patching. Today's state.
- **1.0.0** — the first image built end to end from `v8/`, which is Track C's
  finish line and is what makes the number mean something.

## Ports are not part of this

The base system is what the Bell Labs distribution contained, plus what we add to
make it a working machine. Everything else — Plan 9 tools, backported games,
anything from [v11-plan.md](v11-plan.md) — is a **port**, and ports are
deliberately on a **rolling release**:

| | base system | ports |
|---|---|---|
| versioned as | `Edition 8 Release M.m.p` | each port's own upstream version |
| cadence | tagged releases | rolling; merged when ready |
| lives in | `v8/` | `ports/` |
| in the disk image | yes | only if explicitly selected |
| compatibility | defines `IPNX_VERSION` | declares the minimum `IPNX_VERSION` it needs |

This is FreeBSD's split and it exists for the same reason: the base system has to
be a coherent, testable whole that someone can boot, and a collection of
third-party software has no business freezing on its schedule. A port that needs
a newer base says so in a line of C, and the base never has to know the port
exists.

The one rule that keeps the seam honest: **a port may depend on the base, never
the reverse.** If something in `v8/` starts needing something in `ports/`, it was
never a port and should be moved.

## Changelog

[`v8/CHANGELOG.md`](../v8/CHANGELOG.md), newest first, one section per release,
dated. Entries say what changed and why, not which commits did it — `git log` is
better at that than any hand-written list.

The first entry is the import itself, because "identical to the TUHS tapes" is
the only baseline against which any later claim about this tree can be checked.
