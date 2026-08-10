# Changelog — ipnx base system, Edition 8

Newest first. Policy, numbering and what counts as a release:
[docs/releases.md](../docs/releases.md).

Entries say what changed and why. They do not list commits — `git log` is better
at that, and unlike a hand-maintained list it cannot be wrong.

---

## 0.1.0 — 2026-08-10

The first numbered state of the tree, and the baseline every later claim is
measured against. Still **0.x**: these sources have not yet built a bootable
disk, so nothing here is a release in the sense
[docs/releases.md](../docs/releases.md) defines. That is 1.0.0, and it is Track
C's finish line.

### Added

- **The distribution itself**, imported from the two TUHS tapes (`v8.tar`,
  `v8jerq.tar`) by `tools/v8-import.py` — 7,819 files, verified byte-for-byte
  against the tapes by `--verify`. `jerq` and `blit` come in as first-class
  source, not as a separate concern.
- **`MANIFEST`** — every one of the 8,351 files on the tapes and what became of
  it, including the 1,389 excluded as machine code, with sizes and sha256 so the
  exclusion can be audited rather than trusted.
- **`mk/`** — the staged bootstrap Research Unix never had: a generated makefile
  per toolchain component with full transitive `#include` dependencies, plus
  `$(CC) $(CCOM) $(AS)` on every object and `$(LD) $(LIBC)` on every binary, so
  replacing the compiler rebuilds the world and replacing yacc rebuilds the
  compiler first. Nothing it runs writes outside `$(TOOLDIR)`.
- **`RELEASE`, `usr/include/ipnx.h`** — the version, and the single integer
  `IPNX_VERSION` that ports test against.

### Fixed

- **Two directories that macOS cannot hold at once.** The tape distinguishes
  `usr/src/cmd/Mail` from `usr/src/cmd/mail`, and `jerq/src/lib/C` from
  `jerq/src/lib/c`. A plain `tar x` on a case-insensitive filesystem merges them
  and drops 15 files — which means `work/v8src`, this project's reference tree
  since the A0 spike, had been quietly incomplete since the day it was made. The
  loser of each of the 16 colliding groups is now stored percent-escaped and
  restored during staging, in the guest, whose filesystem is case-sensitive.
- **21 source archives unpacked**, 878 files. V7-era practice used `ar` as a
  source container — `usr/src/libplot/lib5620/blit.c.a` holds 31 `.c` files and
  the makefile ran `ar x` before compiling. An opaque blob cannot be diffed,
  which defeats the purpose of keeping source under version control at all. The
  nine makefiles that unpacked them now copy from a directory.

### Known gaps in the distribution

Neither is a gap in our copy — both are missing from the tape as Bell Labs wrote
it, and both are recorded here so nobody rediscovers them as bugs:

- **`usr/games` ships 37 binaries with no source.** There is no `usr/src/games`
  and nothing under `usr/src/cmd` that builds them. A from-source rebuild
  provably cannot reconstruct them. V10's tape does carry games source.
- **`learn`'s lessons were never on the tape.** `usr/src/cmd/learn` builds the
  driver, whose makefile unpacks lesson archives from `/usr/lib/learn/*.a` — a
  directory the tape does not contain. The program will build and will have
  nothing to teach.

### Not yet in this tree

Changes that exist in the shipped disk images but have not been moved into `v8/`
yet, and so are not part of this release: the `il0` NI1010 kernel configuration,
the four Datakit assumptions fixed in `sys/streamio.c`'s `istread()`, and the
`nmount` netfs client. They live as `ed` scripts and loose C under `tools/v8/`
and become ordinary source here.
