# ipnx-v11 — the edition that never was

*Scope framing, 2026-08-10. Nothing here is committed and nothing should start before
B4 (V10 boots). The purpose of this document is to make the question answerable:
**what could an Eleventh Edition contain without ceasing to be Research Unix?***

## The admission rule

"Pure Research Unix" is the constraint, and it is a sharper one than it sounds, because
it is not about vintage or taste. What makes this system Research Unix is not its
utilities — it is the kernel's model of itself. V8 answered "how do I talk to a device?"
with **streams**, "how do I attach a foreign file system?" with the **file system
switch**, "how do I reach another machine?" with **netfs** and Datakit. 4.2BSD answered
the same three questions with sockets, vnodes and TCP-in-the-kernel, and those answers
are *why* BSD is a different system rather than a variant of this one.

So the test for any candidate is one question:

> **Does this change the system's model of itself?**

- **Sockets, vnodes, a 4.4BSD VFS, a wholesale ANSI libc** — yes. Refuse. There are
  a dozen good BSDs and this is not one of them.
- **`snake`** — no. It reads a terminal and prints characters. Port it freely.

Everything below sorts into three classes by that test:

| Class | What it means | Licence estate |
|---|---|---|
| **Restoration** | The tree had it and lost it, or has half of it | 2017 covenant — already ours |
| **Continuation** | What the same people built next, brought back | Plan 9 / Inferno (MIT) |
| **Furniture** | Third-party programs that make the machine livable | BSD, and case by case |

Restoration first. It is the cheapest, the most defensible, and the most interesting.

## The surprise: a good deal of v11 is already in the tree

Before planning any backport, I listed the V10 source tarball (`work/v10src.tar.bz2`,
25,077 entries) and looked. Research Unix was not sitting still while Plan 9 was being
written down the corridor — the two were the same people, and it shows:

| Found | Where | What it actually is |
|---|---|---|
| **9P** | `cmd/u9fs/` — `u9fs.c`, `9p.h`, `conv.o` | A Plan 9 file server for Unix, in the V10 tree |
| **mk** | `cmd/mk/src/` — `mk.c`, `graph.c`, `run.c`, plus `agh3`/`agh4` | Andrew Hume's `mk`, which Plan 9 later adopted |
| **sam** | `630/bin/sam`, `630/lib/sam.m`, `man/man9/sam.9`, `vol2/sam/` | The terminal half and the paper — see below |
| **netfs** | `netfs/README`, `netfs/serv/`, `netfs/libnetb/` | Deliberately protocol-agnostic; ships servers for 4BSD, V6, V7 and FILES-11 file systems |

The `9p.h` header is worth reading in full, because it dates itself. It opens *"Plan 9
file protocol definitions for use on Unix with ANSI C"*, and the protocol it declares is
the **original 9P, not 9P2000**: `NAMELEN` 28, `Tnop = 50`, and messages that later
vanished — `Tclone`, `Tclwalk`, `Tsession` with DES tickets, a fixed 116-byte `Dir`.

That single file changes the framing of this whole track. **9P is not something ipnx
would be adding to Research Unix. Research Unix already speaks it, and the source is
in the tarball we have.** The V10 machines were serving files to the Plan 9 machines.
Reconnecting that is restoration, not importation.

The `netfs/README` makes the same point from the other side: the servers "may be
compiled with any protocol library", and `libnetb` is merely the one Research used.
A netfs server that speaks 9P instead of netb is a design the tree anticipated.

### The gap worth naming: sam's host side is missing

There is **no `cmd/sam/`** in the V10 source tarball. What survives is the 630 terminal
half (`630/bin/sam`, `630/lib/sam.m`, and `630/bin/samuel`), the manual page
`man/man9/sam.9`, and the paper in `vol2/sam/`. The editor's host side — the half that
does the editing — is not in the distribution.

Pike's `sam` is in plan9port, MIT-licensed, and its terminal protocol is documented in
the very paper the tree still carries. So one of the more compelling things v11 could
do is **put sam's host side back**, against a terminal half that is already sitting on
the disk. That is a restoration with a working target to test against on day one.

## Stream 1 — Plan 9 *(the strongest case)*

**Licensing is clean.** On 23 March 2021 Nokia Bell Labs transferred the Plan 9
copyright to the Plan 9 Foundation, which relicensed all previous editions under the
**MIT licence**; plan9port carries the same MIT terms. That is compatible with this
repository's MIT content and with a free app, and it is a far easier estate to reason
about than the 2017 covenant.

[Plan 9 from User Space](https://9fans.github.io/plan9port/) is the porting reference,
not the source of truth: it is exactly the exercise of adapting Plan 9 code to a Unix,
already done once, with the awkward parts visible in its diffs. v11 runs the same
exercise against a much older Unix.

Ranked by value against tractability:

1. **`sam`** — restores a missing half, has a live terminal target, MIT. Start here.
2. **9P revival** — build `cmd/u9fs` as it stands, then decide whether to modernise it
   to 9P2000 or keep the 1989 dialect. This overlaps the N track directly (N4–N7 are
   already about a host file server), so the honest question is whether netfs's
   successor should be *9P* rather than a documented netb.
3. **`rc`** — Duff's shell. Self-contained, small, and the one Plan 9 program whose
   absence is felt daily. No kernel dependency.
4. **`mk`** — already present; the work is building it, not porting it, and it makes
   every subsequent port easier.
5. **Later, if at all**: `acme` (wants a mouse-and-windows environment — the 5620 is
   the obvious host and this is genuinely interesting), `plumber`, `factotum`.

## Stream 2 — Inferno *(split it in two)*

Inferno divides cleanly into a tractable half and a moonshot, and conflating them is
the main risk to this stream.

**Tractable: Styx.** Inferno's protocol is 9P — in the 4th edition, Styx *is* 9P2000.
Since V10 already carries a 9P server, "Inferno interoperability" at the protocol level
is the same work item as the 9P revival above. An ipnx that can mount an Inferno
namespace, or be mounted by one, needs no VM at all.

**Moonshot: Dis and Limbo.** Inferno's own literature says it runs useful applications
in as little as 1 MB and needs no memory-mapping hardware, which sounds encouraging
until you count what `emu` actually wants from its host: ANSI C, threads, and a
`select`-shaped event loop. V10's compiler is pre-ANSI, and the process model is not
BSD's. This is a research question, not a plan — and if it is ever attempted it is
plausibly its own edition rather than part of v11.

Licensing needs a pass before any of it: Inferno's history runs Lucent → Vita Nuova,
with GPLv2 and MIT terms at different points, and a v11 image would then be mixing
**three** estates (the 2017 covenant, Plan 9's MIT, Inferno's whichever). That is a
tractable problem but it must be answered before code, not after.

## Stream 3 — BSD *(userland only, and mostly the games)*

The rule from the admission test: **take programs, refuse personality.** No sockets, no
VFS, no libc replacement. What is left is genuinely worth having, and the games are the
clearest case — they are pure userland, they were mostly Berkeley-original, and they are
the part of BSD that has no modern substitute worth using.

### What V8 actually has

From a scratch boot of the golden image (`work/myv8/v8-inspect-name.log`), `/usr/games`
on V8 is richer than expected:

```
Mail  arithmetic  atc  back  banner  bcd  bigp  canfield  cbrogue  festoon
fish  fortune  hack  hangman  hanoi  mille  ogre  ppt  quiz  rogomatic
rogue  rogue52  rogue53  sail  say  scapegoat  snake  sread  thanks
tictactoe  tso  worm  zork
```

Three versions of `rogue`, plus **`rogomatic`** — the rogue-playing program — plus
`hack`, `zork` and `sail`. This machine was played on.

### The free win nobody would look for: V10 → V8

`v10src/games/` contains games V8 does not have, in the same copyright estate, under the
same 2017 covenant, compiled by the same compiler:

> `adv` · `boggle` · `doctor` · `morse` · `pacman` · `psych` · `rain` · `rot` ·
> `trek` · `wump` · `imp` · `word_clout` · `crypt`/`des`

**These are not ports.** They are intra-family transfers: no licence question, no
ANSI problem, no API skew of any consequence, and the ingest path (B0, and netfs after
N7) already exists. They should be the first thing Track C's machinery is tested on,
precisely *because* they are easy — a ports tree whose first entry is a hard port is a
ports tree that never gets debugged.

It also cuts the other way, and is worth recording: `festoon`, `doctor`, `psych`,
`word_clout`, `say`, `thanks`, `imp`, `tso` are **Research-only** games with no BSD
equivalent. The traffic was never one-directional.

### What neither has, from BSD

Against the NetBSD-derived `bsd-games` collection, the genuine additions are:

| Candidate | Why | Difficulty |
|---|---|---|
| `robots`, `worms`, `battlestar`, `cribbage`, `monop`, `gomoku` | Self-contained curses games with no equivalent here | Low — curses + de-ANSI-fication |
| `phantasia` | Multi-user persistent RPG; uses shared score files | Medium |
| `pom`, `number`, `caesar`, `primes`, `random` | Trivial filters, an afternoon each | Trivial |
| **`hunt`** | **Real-time multiplayer over a network** | **High — and that is the point** |

`hunt` is the one to aim at. It is the only game in the collection that needs the
machine to be a *networked* machine, so it lands squarely on the N track: two ipnx
instances, or an ipnx and a Mac, playing hunt over the `il0` interface that N3 already
proved. That is a demonstration nothing else in this project can make.

**Provenance rule: port from 4.4BSD-Lite or its descendants, never from 4.3BSD.**
4.4BSD-Lite was the release constructed after the 1994 USL settlement specifically to
contain no AT&T source, and UCB dropped the advertising clause in 1999, so the modern
`bsd-games` lineage is 3-clause BSD with traceable provenance. 4.3BSD is a worse
starting point for identical code.

## The real cost, and it is not the games

Every BSD or Plan 9 port lands on the same wall, and it is worth naming once so that no
port has to rediscover it:

- **The compiler is pre-ANSI.** No prototypes, no `void *`, no `<stdlib.h>`.
- **The libc is 4.1BSD-era.** `index`/`rindex`/`bcopy`/`bzero` are native; `strchr`,
  `memcpy`, `strtol` are not. Modern sources need the *reverse* of the usual
  ANSI-ification pass.
- **Filenames are 14 bytes.** `cfscores.c` is fine; anything with a long name is not.
- **No symlinks, no `select`, no sockets** — V8 is 4.1BSD-derived and 4.2 never happened
  here.

The single highest-leverage deliverable across both Track C and Track D is therefore a
shared compatibility layer in the ports infrastructure — a header and a small archive
supplying the ANSI names in terms of the BSD ones, and a prototype-eliding macro. Get
that right once and most of the games become an evening's work each; skip it and every
port re-solves it slightly differently.

## Where this sits relative to ipnx-ports

These two tracks are easy to confuse and should not be:

- **ipnx-ports (Track C) is the mechanism.** How anything third-party is fetched,
  patched, built and installed. It is infrastructure and it is edition-agnostic.
- **ipnx-v11 (Track D) is the editorial question.** *What belongs in the edition* —
  which of the above is Research Unix continuing, and which is merely software that
  runs on it.

The BSD games are built by Track C and chosen by Track D. `sam` is the same. Nothing
about v11 requires new machinery; it requires a decision about what the edition is.

## Open questions

- Does the V10 `u9fs` build under V10's own compiler, or was it maintained on another
  machine? (`cmd/u9fs/*.o` are present — objects for *some* target.)
- Should netfs's successor be 9P outright, making N4–N7 a Plan 9 story rather than a
  netb one? This is a fork in the road and it arrives before v11 does.
- Is `630/bin/sam` the terminal half only, or does the 630 support tree also carry a
  host binary? (Determines whether "restore sam" starts from a working reference.)
- Which Inferno licence applies to which components, and does a three-estate image
  create any obligation the covenant does not already impose?
- Is v11 an *image* (a bootable `v11.disk`) or a *layer* over v10? The former is
  cleaner to reason about; the latter is what actually happens if ports are how things
  arrive.

## Sources

- [Plan 9 copyright transferred to the Plan 9 Foundation, MIT-licensed (2021)](https://www.phoronix.com/news/Plan-9-2021)
  · [The Register's account](https://www.theregister.com/2021/03/24/bell_labs_transfers_plan9pto_foundation/)
- [Plan 9 from User Space](https://9fans.github.io/plan9port/) — MIT, per its `LICENSE`
- [Inferno — Vita Nuova](https://www.vitanuova.com/inferno/) ·
  [The Inferno operating system (BLTJ)](https://www.vitanuova.com/inferno/papers/bltj.html)
- [4.4BSD and the Lite releases](https://gunkies.org/wiki/4.4BSD) ·
  [bsd-games, NetBSD-derived](https://github.com/jsm28/bsd-games)
- Primary, in this repository: `work/v10src.tar.bz2` (`cmd/u9fs/9p.h`, `cmd/mk/src/`,
  `netfs/README`, `games/`) and `work/myv8/v8-inspect-name.log`
