# Changelog — ipnx base system, Edition 8

Newest first. Policy, numbering and what counts as a release:
[docs/releases.md](../docs/releases.md).

Entries say what changed and why. They do not list commits — `git log` is better
at that, and unlike a hand-maintained list it cannot be wrong.

---

## 1.0 — 2026-08-16

**The first release, and the first the number means anything about.**

Nothing in the system changed here except what it calls itself. The reason it
is worth a release is everything that already had: since 0.3.0 the disk stopped
being patched out of the tape and started being *built* — stages 4–7 produce
the headers, libraries, commands and kernel from this tree, stage 8 lays down a
filesystem from that `DESTDIR`, and stage 9 has the result rebuild itself under
`chroot`. That was the stated criterion for 1.0 in
[docs/releases.md](../docs/releases.md), and it has been met since 2026-08-15.

The system is now **`ipnx Edition 8 Release 1.0`**. Two numbers belonging to
two different people: the edition is Bell Labs' and is not ours to increment,
the release counts what this project has made of it.

### Changed

- **`RELEASE`: `0.3.0-CURRENT` → `1.0-RELEASE`.** Both halves of the old string
  were wrong. A leading `0` is semantic versioning's way of saying "not stable
  yet", which is an odd claim about a system finished in 1985 and unmoved
  since — the instability was ours, and 1.0 records the end of it. `-CURRENT`
  is a branch marker borrowed from projects with a moving trunk; on a legacy
  base there is no trunk for it to distinguish.
- **`PATCH` is omitted from the displayed version when it is zero**, so this
  reads `Release 1.0` rather than `Release 1.0.0`; a fix release would read
  `Release 1.0.1`.
- **The branch suffix shows only when the branch is not `RELEASE`**, so a
  tagged system never says `Release 1.0-RELEASE`.
- **`/etc/whoami` is unchanged** (`ipnx-v8`) — the machine's name and the
  system's version are different questions and V8 keeps them in different
  places.

### Added

- **`IPNX_RELSTR`** in `<ipnx.h>` — the composed release string, suffix and
  all. `uname` and `ipnxfetch` each glued `IPNX_RELEASE` and `IPNX_BRANCH`
  together at their own call site, and both therefore printed `1.0-RELEASE`.
  A formatting rule that two places implement is a rule that two places can get
  wrong; it now lives in `tools/ipnx-release.py` and arrives pre-composed.

### Verified

Built by `tools/drive-stages48.sh "" "" 4 8 rp07ref rp07` onto an image
recreated from `/dev/zero` (`mkfs` does not clear data blocks, and this one is
committed). Stages 4–8 all green, clean halt. On the booted disk:

    OS:      ipnx Edition 8 Release 1.0
    Kernel:  ipnx Edition 8 Release 1.0 (2026-08-16)
    uname:   ipnx ipnx-v8 1.0 ipnx Edition 8 Release 1.0 (2026-08-16) vax

`config-audit` OK (7,955 files compared, 467 installed paths); `boot-newdisk`
10/10 with a clean halt; no occurrence of `0.3.0-CURRENT` remains anywhere on
the image.

---

## 0.3.0 — 2026-08-10

**libc builds from this tree, and the system reproduces itself.**

The pipeline is now stage 1 (toolchain, with the tape's compiler) → stage 2
(libc, with stage 1) → stage 3 (the toolchain again, with stage 1 *and* our
libc). Stage 3 is the first set of binaries in which every component came from
our source, and all fourteen are byte-identical to stage 1's:

    cmpstage: same=14 differ=0 missing=0

Our `libc.a` is **104,810 bytes over 229 members**, against the tape's
**104,770**. Forty bytes apart, and the gap is accounted for below.

### Added

- **`mk/libc.mk`** — 233 objects across `crt/ gen/ math/ stdio/ sys/`, plus
  `crt0.o` and `mcrt0.o`. Four steps of the tape's recipe are not derivable and
  are carried across with the reason recorded: `errlst.c` is compiled to
  assembly and then *edited* (`gen/:errfix` moves the error table from `.data`
  to `.text`); `doprnt.S` is assembly needing cpp, so it is renamed to `.c` to
  get `-E`; `ld -x -r` re-emits every object relocatable; and
  `ar cr libc.a `lorder *.o | tsort`` plus two `ar m` fixups order the archive,
  because **V8's `ld` is single-pass** and a member needing a symbol from a
  later member never resolves.

### Fixed

- **Four libc basenames appear in two directories**, and all 233 objects share
  one namespace: `cerror` and `mcount` are byte-identical in `crt/` and `sys/`,
  but `abs` and `fabs` are a real choice — portable C in `gen/`/`math/` against
  hand-written VAX assembly in `sys/` (`mnegl`, `movd`/`mnegd`). The tape
  resolves this by *overwrite order* — it compiles `sys/` last — so the
  assembly is intended. V8's `make` resolves a duplicate target the other way
  (first rule wins, second reports `Too many command lines`), so generating
  both rules silently linked the C versions. The generator now applies the
  tape's order explicitly.
- **`libc.a` could never be up to date.** `ld -x -r` rewrites every `.o` in
  place *inside* the `libc.a` recipe, leaving all 233 prerequisites newer than
  the target the moment it finishes — so `make install` rebuilt the whole
  archive a second time and an incremental build would never converge. Split
  into a `stripped` stamp target.
- **`$(LIBC)` was a prerequisite but never on the link line.** `cc` appends an
  implicit `-lc`, which `ld` resolves from `/lib/libc.a` — so a stage that had
  built its own libc would have gone on linking against the tape's, and the
  stage-3 comparison would have been measuring nothing.

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
