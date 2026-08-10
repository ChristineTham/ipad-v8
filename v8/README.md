# v8 — the system source

This is Research Unix 8th Edition, and as of 2026-08-10 it is **our tree**, not a
vendored dependency. New drivers, utilities and fixes are written here as ordinary
source, not carried as patch files or `ed` scripts against someone else's copy. The
first commit is the pristine tape, so `git log` on any file is the complete record
of how far ipnx has drifted from what Bell Labs shipped.

The layout mirrors the guest filesystem, so `v8/usr/src/cmd/ls.c` is what the running
machine sees at `/usr/src/cmd/ls.c`. `mk/` is the exception: it is ours, and holds the
build system V8 never had.

## Provenance

Two tapes from the TUHS [Dan Cross V8 archive](https://www.tuhs.org/Archive/Distributions/Research/Dan_Cross_v8/),
de-taped to `work/v8.tar` and `work/v8jerq.tar`:

| tape | sha256 | contents |
|---|---|---|
| `v8.tar` | `f2c3548d…5c8e217a` | `bin etc lib usr boot proto-dev` |
| `v8jerq.tar` | `c2c18060…f31ce8c8` | `jerq blit` — the DMD 5620 and Blit trees |

`tools/v8-import.py` produced this directory from those two files. `--verify`
re-reads the tapes and proves every imported file still matches them byte for byte;
run it whenever you want to know exactly how much of the tree is still Bell Labs'.
It refuses to overwrite `v8/` without `--force`, because after the first commit a
re-import would destroy our work rather than update it.

## What is here, and what is not

Of 8,351 files on the tapes:

| | files | size | |
|---|---|---|---|
| source and data | 6,941 | 24.1 MB | imported as-is |
| unpacked from `ar` | 21 → 878 | | see below |
| machine code | 1,389 | 23.4 MB | not imported, but listed in [MANIFEST](MANIFEST) with sizes and checksums |

Excluding the binaries is what makes this a source tree, but it is only honest if the
exclusion is auditable, so every excluded file is still named in `MANIFEST` with its
sha256. If something turns out to have no source, that is where it shows up — and
[one thing already has](#known-gaps).

## Three things had to change on the way in

Each is recorded so that "our copy is complete" stays a claim you can check.

### 1. Case collisions — 17 paths

The tape names 16 groups of paths that differ only in case. macOS is case-insensitive
by default and git cannot check out both members either, so a plain `tar x` on a Mac
silently merges them. Two of the groups are **whole directories**:

- `usr/src/cmd/Mail` and `usr/src/cmd/mail` — two different mail programs, merged into
  one directory, their `Makefile`s overwriting each other
- `jerq/src/lib/C` and `jerq/src/lib/c`

`work/v8src`, which this project has used as a reference tree since the A0 spike, has
been quietly missing 15 files the whole time for exactly this reason. Resolving that is
half the point of owning a copy.

The loser of each group is stored with its uppercase letters percent-escaped —
`Mail` → `%4Dail`, `C` → `%43` — and [CASEMAP](CASEMAP) records the mapping.
Escaping a directory de-collides everything beneath it, which is why
`usr/src/cmd/Mail/Makefile` needs no escape of its own but
`usr/src/cmd/Mail/manual/cmds/Reply` does. `mk/stage.sh` restores the true names when
the tree is staged into the guest, whose filesystem is case-sensitive and does not care.

### 2. Source archives — 21 of them, 878 files

V7-era practice used `ar`(1) as a source container. `usr/src/libplot/lib5620/blit.c.a`
holds 31 `.c` files and the makefile unpacks it before compiling:

```
lib5620.a: blit.c.a
	mkdir xplot
	cd xplot;ar x ../blit.c.a
```

An opaque blob in a version control system is worse than useless — you cannot diff it,
grep it, or see who changed what. Any archive whose members are all text is therefore
unpacked, with the archive path becoming a directory holding its members. The makefiles
that used to unpack them are edited to match; that edit is ours and lands in its own
commit.

Archives whose members are object files are build products and are excluded like any
other binary.

### 3. Empty directories

git cannot store one. [EMPTYDIRS](EMPTYDIRS) lists the 75 the tape carries with no
surviving source underneath, and `mk/stage.sh` recreates them.

## Known gaps

**`usr/games` ships 37 binaries and the V8 tape carries no source for any of them.**
There is no `usr/src/games` and nothing under `usr/src/cmd` that builds them. This is a
hole in the distribution as Bell Labs shipped it, not in our copy of it, and it is the
one thing that a from-source rebuild provably cannot reconstruct. V10's tape does carry
games source; moving it back is noted as a Track C idea in
[../docs/v11-plan.md](../docs/v11-plan.md).

Other binaries without an obvious matching source name are mostly name mismatches —
`vi` is built from `usr/src/cmd/ex`, `nroff` from `troff` — and the build itself is a
far better oracle than filename matching, so they are resolved as the world build
driver reaches them rather than guessed at here.

## Licensing

Research Unix Editions 8, 9 and 10 are distributable under Nokia's March 2017 covenant
not to assert copyright for **non-commercial** use. Keeping this source in the repo is
the same posture TUHS has taken publicly since 2017, and this project is non-commercial
by construction. The binding rules — free app, no "UNIX" in the name — are in
[../docs/licensing.md](../docs/licensing.md) and are unchanged by taking ownership of
the source.
