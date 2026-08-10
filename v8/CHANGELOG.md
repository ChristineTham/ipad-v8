# Changelog — ipnx base system, Edition 8

Newest first. Policy, numbering and what counts as a release:
[docs/releases.md](../docs/releases.md).

Entries say what changed and why. They do not list commits — `git log` is better
at that, and unlike a hand-maintained list it cannot be wrong.

---

## 0.2.0 — 2026-08-10

**The bootstrap toolchain builds from this tree, and it is a fixpoint.** All fourteen stage-1
components — `yacc make lex cpp ccom c2 as ld ar ranlib nm size strip cc` —
compile straight off the read-only netfs share into a separate build
filesystem, and the compiler they produce is a fixpoint: `cmp` of a binary
built by our `ccom` against one built by the 1985 `/lib/ccom` returns **0**,
byte for byte, stripped.

Stage 2 then rebuilds the same fourteen components *with* the stage-1 result,
and all fourteen binaries are identical to stage 1's:

    cmpstage: same=14 differ=0 missing=0

So the compiler this tree describes builds itself, and agrees with the compiler
Bell Labs shipped. Driver `tools/drive-stage1.sh`, evidence
`work/myv8/c2-stage1.log`, method [docs/build-from-source.md](../docs/build-from-source.md).

Still 0.x: a toolchain is not a system, and nothing here has produced a
bootable disk yet.

### Fixed

- **`usr/src/cmd/date.c` — a Y2K bug, and the reason the machine lived in
  1976.** `gtime()` read two digits and did a bare `year += 1900`, so `26`
  meant 1926. That is before `YRREF`, so `clkinit()`'s year loop contributed
  nothing and the date collapsed to 1970. It matters more than a display
  nuisance: the kernel takes the **year from the root filesystem's superblock**
  and only the position within it from the TODR (`sys/sys/machdep.c`), so an
  unsettable year is an unsettable clock — and `make(1)` cannot compare a 2026
  source served over netfs against a 1976 object. Now windowed at 69/70, the
  same fix everyone applied in 1999.

### Changed

- **`mk/` understands out-of-tree builds.** The tape's makefiles assume the
  current directory *is* the source directory; ours compiles from a read-only
  mount into a separate object directory. Three assumptions had to be named
  explicitly — a script beside the source (`:yyfix`), a data file beside the
  source (`y.debug.sv`), and a generated file that exists only in the object
  directory (`rodata.c`, a side effect of making `cpy.c`). One entry in the
  `ccom` object table was simply wrong: `t2print.c` is in `common/`, not
  `vax/`.
- **Tool macros split into command and path.** `$(CC)` is what a rule runs;
  `$(CCPATH)` is the binary whose mtime means the compiler changed and is what
  belongs in a prerequisite. Likewise `$(YACC)`/`$(YACCPATH)` and
  `$(LEX)`/`$(LEXPATH)`.
- `yaccpar` installs to `usr/lib/`, matching the unconditional
  `# define PARSER "/usr/lib/yaccpar"` in `usr/src/cmd/yacc/files`.

## 0.1.0 — 2026-08-10

The first numbered state of the tree, and the baseline every later claim is
measured against. Still **0.x**: these sources have not yet built a bootable
disk, so nothing here is a release in the sense
[docs/releases.md](../docs/releases.md) defines. That is 1.0.0, and it is Track
S's finish line (Track C is ports — see [docs/roadmap.md](../docs/roadmap.md)).

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
