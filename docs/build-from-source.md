# Building V8 from source

*Track C. The goal is a disk built entirely from [`v8/`](../v8/README.md) that is
functionally the golden image — which is the only real proof that our source is
complete and that the ownership claim in `v8/README.md` means anything.*

## Research Unix has no world build, and never did

This is the first thing to establish, because everything else follows from it.

| | |
|---|---|
| `usr/src/Makefile` | does not exist |
| `usr/src/cmd/Makefile` | does not exist |
| command directories with their own makefile | 113 |
| loose `.c` files in `usr/src/cmd` with no makefile at all | 163 |
| loose `.sh` files | 6 |

V8's own installation notes say so outright (`v8/usr/doc/v8directions`, §*How to
bootstrap*):

> The distribution is not set up for bootstrapping to an empty machine. You will have to
> have a running system, extract the tape, build your own kernel, and then convert to it.

The tape ships binaries; the source is there so you can fix and rebuild **parts**. The
only build the directions walk through is the kernel, via `config`(8).

So there is no order to recover and no driver to port. We are inventing one. The BSDs
are the right place to steal from, because they solved exactly this problem — on the
same codebase's descendants — and converged on the same shape.

### What V8 *does* document is the last stage

The same section is a precise recipe for turning a populated tree into a bootable disk,
which is stage 8 below, and our tree carries what it asks for:

1. extract the distribution into a partition, call it `/v8`
2. `chroot` into it and build a kernel — via `usr/src/cmd/v8.c`, a 13-line helper that
   does `chroot("/v8")`, drops to uid 3 / gid 4, and execs a shell
3. copy `bin`, `lib`, `etc` and `boot` to an empty 0-origin partition
4. write a boot block from `usr/sys/boot/bb` to block 0 — for our Massbus disk that is
   `hpboot.s`, which is in the tree even though the assembled `hpboot` was excluded
5. make a `/dev` with at least `console` and `null`; `v8/proto-dev` is Bell Labs' own
   `ls -l` of a working `/dev`, 395 entries with major and minor numbers
6. `fsck` the new root, which is what converts a 4.1BSD filesystem into a V8 one
7. boot it single-user, write-protected for the first few attempts

That `chroot` helper is worth noticing twice: it is V8's own answer to "do not build in
the live system", and it gives stage 8 a much stronger acceptance test than booting.
Once `DESTDIR` is populated we can `chroot` into it and **build the whole system again
from inside itself**. A system that can rebuild itself is complete by demonstration
rather than by inventory.

## What the BSDs converged on

FreeBSD's `Makefile.inc1` names its stages in comments:

```
>>> stage 1.1: legacy release compatibility shims
>>> stage 1.2: bootstrap tools
>>> stage 2.1: cleaning up the object tree
>>> stage 2.2: rebuilding the object tree
>>> stage 2.3: build tools
>>> stage 3: cross tools
>>> stage 4.1: building includes
>>> stage 4.2: building libraries
>>> stage 4.4: building everything
```

NetBSD's `build.sh` splits the same idea across two directories: **`TOOLDIR`** for the
toolchain it builds first, **`DESTDIR`** for the system it builds with that toolchain,
and it takes care that *"special compiler options prevent use of the host system's
standard library and header locations"*.

Two rules matter more than the stage names:

- **The toolchain is built first and lives somewhere else.** Nothing is installed over
  the running system while the build depends on it.
- **Libraries before programs.** FreeBSD says why, and the reason is ours exactly:
  *"We must do lib/ and libexec/ before bin/ in case of a mid-install error to keep the
  users system reasonably usable."*

## The ordering V8's own source dictates

Not a guess — this is what the tree says. Grepping for grammars gives the tool graph:

| tool | source | needs |
|---|---|---|
| `yacc` | `cmd/yacc/y1.c`–`y4.c` | nothing but `cc` and `libc` — **the root** |
| `make` | `cmd/make/gram.y` | yacc |
| `lex` | `cmd/lex/parser.y` | yacc |
| `cpp` | `cmd/cpp/cpy.y` | yacc |
| **`ccom`** | `cmd/ccom/common/cgram.y` | **yacc** |
| `c2`, `as`, `ld`, `ar`, `ranlib`, `nm`, `size`, `strip`, `cc` | plain C | `cc`, `libc` |
| `libc` | `libc/*/*.[cs]` | `cc`, `as`, `ar`, `ranlib` |
| `config` | `cmd/config/config.y` + `config.l` | yacc **and** lex |

The C compiler is a yacc grammar, so changing yacc really does invalidate the compiler,
and changing the compiler invalidates everything. That is the whole reason this needs
stages rather than a loop over directories.

## Stage isolation: `cc -B`, which V8 already has

The mechanism was sitting in `cmd/cc.c` since 1985 — GCC's `-B` by another name:

```c
case 'B':  npassname = optarg;          /* prefix for the passes   */
case 't':  chpass = optarg;             /* which passes to replace */
...
if (npassname && chpass == 0) chpass = "012p";
case '0': ccom = strspl(npassname, "ccom");
case '2': c2   = strspl(npassname, "c2");
case 'p': cpp  = strspl(npassname, "cpp");
```

`cc -B$TOOLDIR/ -t02p` compiles with our `ccom`, `c2` and `cpp` instead of the running
system's, touching nothing in `/lib`. That is stage isolation for free.

It stopped short of the whole toolchain: `as`, `ld` and `crt0.o` were hardcoded to
`/bin/as`, `/bin/ld`, `/lib/crt0.o`. **Extended 2026-08-10 (S5)** — three more letters,
all off the same `-B` prefix:

| `-t` | sets | |
|---|---|---|
| `a` | `as` | |
| `l` | `ld` | |
| `c` | `crt0.o`, `mcrt0.o` **and `libc.a`** | the C library and its startup file are one release |

so `-B$TOOLDIR/lib/ -t02palc` names one directory holding every program `cc` executes.
`as` and `ld` therefore install into `TOOLDIR/lib` as well as `TOOLDIR/bin`: `bin` is
for people and makefiles, `lib` is the compiler's pass directory.

**`-t c` also stops `cc` appending `-lc`, and that half matters more than the other
three.** V8's `ld` has no `-L` at all. `getfile()` builds the library name into one
template string and tries three fixed directories by rewriting it — the `/lib` case is
literally `filname+4`, skipping the `/usr` prefix by pointer arithmetic:

```c
filname = "/usr/lib/libxxxxxxxxxxxxxxx";
...
if ((infil = open(filname+4, 0)) >= 0)      /* /lib/libc.a     */
    filname += 4;
else if ((infil = open(filname, 0)) < 0)    /* /usr/lib/libc.a */
    filname = locfilname;                   /* /usr/local/lib  */
```

So a hermetic build cannot use `-lc`; it has to name the archive. Quietly not doing so
is how a stage borrows from the system it is replacing and still reports success.

**Still open after S5: `lorder`.** It is a shell script (`usr/bin/lorder`, and it is in
our tree) that pipes a bare `nm -g` through `sed`, `sort` and `join` — all resolved from
`PATH`, so libc's archive order is computed by the *running system's* `nm`. This is a
reproducibility gap rather than a correctness one: with a valid `__.SYMDEF` the order
does not affect linking at all (see below), only whether `libc.a` comes out byte-identical.
Closing it needs `PATH=$TOOLDIR/bin:$PATH` around the `lorder` call, and full closure
waits on `sed`, `sort` and `join` from stage 6.

**`yacc` had the same problem one level up.** `yaccpar` is copied verbatim into every
`y.tab.c`, so it is part of yacc's *output* — a stage whose yacc emits the tape's parser
text has borrowed from the tape. `y1.c` now reads `$YACCPAR` ahead of the compiled-in
default. Deliberately a *runtime* override: compiling the path in would make stage 1's
yacc and stage 3's yacc differ by an embedded string and fail the fixpoint test for a
reason that means nothing.

## The stages

`TOOLDIR=/usr/bld/tools`, `DESTDIR=/usr/bld/root`, `OBJDIR=/usr/bld/obj`. **Nothing is ever
installed into `/`.** The running system stays the system that works, all the way to
the end, and the new system is only ever a directory tree until `mkfs` turns it into a
disk.

| stage | builds | with | into | |
|---|---|---|---|---|
| **0** | — | the tape's `/bin/cc`, `/bin/make`, `/lib/libc.a` | — | |
| **1** | yacc, then make, lex, cpp, ccom, c2, as, ld, ar, ranlib, nm, size, strip, cc | stage 0 | `TOOLDIR` | ✅ |
| **2** | libc | stage 1 | `TOOLDIR/lib` | ✅ |
| **3** | the whole toolchain **again** | stage 1 + stage 2 libc | `TOOLDIR3` | ✅ |
| **4** | 224 headers | — | `DESTDIR/usr/include` |
| **5** | 19 libraries | stage 3 | `DESTDIR/usr/lib` |
| **6** | 113 makefile commands + 164 loose `.c` + 2 `.y` + 6 `.sh` | stage 3 | `DESTDIR/bin`, `DESTDIR/usr/bin`, `DESTDIR/etc` |
| **7** | the kernel, via `config` | stage 3 | `DESTDIR/unix` |
| **8** | a bootable disk | `mkfs` + `DESTDIR` + `hpboot` + `proto-dev` | a new RP06/RP07 image |
| **9** | the whole system, again, from inside itself | `chroot DESTDIR` | the completeness proof |

**libc must come before the second toolchain, and the order is not
arbitrary.** Every stage-1 binary is linked against the *tape's* `libc.a`,
because that is the only one that exists when stage 1 runs. Rebuilding the
toolchain before libc therefore produces fourteen binaries that still carry the
old library, and they have to be built a third time once libc exists — the
round buys nothing. Build libc with stage 1, then rebuild the toolchain against
it, and stage 3 is the first set of binaries in which *every* component came
from our source.

An earlier version of this ran the toolchain rebuild first and measured
`same=14 differ=0` — the compiler does reproduce itself with libc held
constant. That is a true result and a wasted round: it is not on the path to a
system, and it cost ten minutes of every run. Recorded because the reasoning
that produced it ("prove one variable at a time") sounds like good method and
ignored what the pipeline is actually for.

### libc is where the tape stops being derivable

Stage 2 is the first library rather than a program, and four steps of
`usr/src/libc/Makefile` cannot be worked out from first principles. They are
carried across verbatim, with the reason recorded in `mkdep.py`'s
`emit_libc()`:

- **`errlst.c` is compiled to assembly and then edited.** `gen/:errfix` moves
  the error-message table from `.data` to `.text` so it lands in shared text.
- **`doprnt.S` is assembly that needs the C preprocessor**, which `cc` will not
  run on a `.s` — so the tape renames it to `.c` to get `-E` and pipes the
  result to `as`.
- **`ld -x -r` on every object** strips local symbols and re-emits it
  relocatable. Skipping it fails nothing; it just inflates every binary that
  links libc.
- **`ar cr libc.a `lorder *.o | tsort`` and two `ar m` fixups.** Archive order,
  and the two fixups are what the topological sort cannot know.

  **Corrected 2026-08-10.** This used to say "V8's `ld` is single pass, so
  archive order is correctness", full stop. That is only true for an archive
  with no usable table of contents. `ld.c`'s `getfile()` returns **1** (no
  `__.SYMDEF`), **2** (present and current) or **3** (present but the archive's
  mtime is newer, so stale). Case 2 runs `while (ldrand()) continue;` — passes
  until nothing changes — under the tape's own comment:

  > you can get away with backward references when there is a table of contents!

  Cases 1 and 3 fall back to one sequential pass *and print a warning naming
  `ranlib`*. So order is load-bearing only when the table is missing or stale,
  and `ld` tells you on stderr when that is. `lorder | tsort` is defence
  against exactly that, which is worth keeping for libc and is why the smaller
  libraries in stage 5 do not need it.

  It has one consequence that is easy to get wrong: **any rule that copies an
  archive must re-run `ranlib` at the destination**, because `cp` updates the
  mtime and that alone turns a good table of contents into case 3. libc's
  install has always done this and it was not obvious why.

The tape's `install` target is *not* carried across — it begins
`cp $(DESTDIR)/lib/libc.a liboc.a; cp libc.a $(DESTDIR)/lib/libc.a`, replacing
the C library you are compiling against, from a possibly half-built tree, with
the old one saved under a name nothing looks for.

### Why stage 3 exists

Stage 1's compiler was built by the *tape's* compiler. Stage 3's was built by stage 1's.
If the two are identical after stripping, the build is a **fixpoint**: the compiler our
source describes reproduces itself exactly, which is the strongest evidence available
that the source is complete and that nothing in the running system leaked into the
result. It costs one extra toolchain build.

### There are two fixpoint tests, and only one of them is required

`stage 1 == stage 3` is the **strong** test: our tools reproduce the *tape's* binaries.
Since S5 sealed `as`, `ld` and `libc` into the stage boundary, that comparison now spans
two different assemblers and two different loaders, so it can fail for reasons that have
nothing to do with whether we have a working system.

`stage 3 == stage 3b` is the **required** test — the same sources a fourth time,
compiled by stage 3 instead of stage 1. This is the classic three-stage bootstrap
comparison (GCC compares *stage2 with stage3*, not stage1 with stage2, for exactly this
reason: stage 1 was built by a foreign compiler). It asks the weaker, sufficient
question — are our tools a fixpoint *of themselves*? A compiler can be a perfectly good
compiler and still not reproduce a 1985 assembler's byte layout.

`v8/mk/fixpoint.sh` runs the strong test first, because stage 3 already exists and it is
free, and only builds stage 3b if that fails. If the strong test passes, 3b is not just
unnecessary but *implied*: the comparison is stripped, so it says stage 1 and stage 3
have the same text and data, and the symbol table is not loaded at exec time — they are
the same program. Stage 3 was built *by* stage 1. Building it again by stage 3 is
building it by the same program from the same source.

The distinction is worth keeping on the record either way: "we do not match the tape" is
a curiosity, "we do not even match ourselves" means stage 4 must not be built on top.

The comparison must be of **stripped** binaries. `cc.c` names its temporary files
`sprintf(tmp0, "/tmp/ctm%05.5d", getpid())`, and that PID reaches the symbol table, so
two compiles of one source file differ there and nowhere else. Measured on `ls.c`:
the two outputs first differ at byte 16441, past the 16384-byte stripped size — so
**code generation is already deterministic**, and stripping is all that is needed to see
it.

## Dependency analysis

V8's `make` is V7's: suffix rules, macros, `.SUFFIXES`, `.PRECIOUS`, `.SILENT`,
`.IGNORE`. No `include`, no pattern rules, no automatic header scanning. It does
compare mtimes against an explicit prerequisite list, and that is enough, provided
something else writes the list.

So the makefiles are **generated**, by `v8/mk/mkdep.py` on the host, and committed. This
is not a modern imposition: it is what V8 already does for the kernel, where `config`(8)
reads `conf/files` and writes the makefile. We are doing for userland what Bell Labs did
for the kernel.

Each generated rule carries the dependencies that actually invalidate it:

```make
ls.o: ls.c $(HDRS) $(CC) $(CCOM) $(CPP) $(C2) $(AS)
ls:   ls.o  $(LD) $(LIBC)
```

- `#include` chains are followed transitively from the source, so touching a header
  rebuilds what includes it
- every object depends on the compiler passes and the assembler that produced it
- every executable depends on the linker and on `libc.a`
- every yacc output depends on `$(YACC)`, every lex output on `$(LEX)`

That is the invalidation the user asked for, expressed in a way 1985's make can execute:
replacing `TOOLDIR/ccom` makes it newer than every `.o`, and the world rebuilds.

## Safety

The failure mode to avoid is turning a working system into a non-working one halfway
through a build, leaving nothing to build with. The rules that prevent it:

1. **Never install into `/`.** Not `/bin`, not `/lib`, not `/usr/lib`, not `/usr/include`.
   The only writes outside `/usr/bld` are to `/tmp`.
2. **`PATH=$TOOLDIR/bin:/bin:/usr/bin`** — new tools win, old tools remain as a fallback
   the moment a new one is deleted.
3. **The compiler is selected explicitly**, via `-B`, never by shadowing `/lib/ccom`.
4. **The new system is a directory until the last step.** `mkfs` writes a *second* drive;
   the drive we booted from is never the drive we are building.
5. A stage that fails leaves `/usr/bld` in whatever state it reached and the running system
   untouched, so the recovery is always "look at the log and run the stage again".

## How the build is laid out

**Source is never copied.** It stays on the netfs share at `/n/src`, read-only,
served straight out of the repo's `v8/`. netfsd applies `CASEMAP` so the guest
sees `usr/src/cmd/Mail` and `usr/src/cmd/mail` as the distinct directories they
are — which is not a nicety: a `struct direct` name field is 14 bytes and the
escaped spelling of `CIRCLE` is 18, so the repo's on-disk names cannot appear in
a V8 directory entry at all.

**Only products touch disk**, on `/b` — rp1, its own filesystem, `mkfs`'d per
run. Real Unix mounted `/usr/src` as a separate disk for exactly this reason.
Here the source needs no disk, but objects do, and V8 fixes a filesystem's inode
count at `mkfs` time: dropping a build tree into `/usr` (8,799 files' worth)
exhausted them and V7 `mkdir` began answering `cannot access .`.

Each component builds in `/b/obj/<name>`, compiling `$(SRC)/…` off the wire.
The share being read-only enforces the out-of-tree build rather than us policing
it.

*An earlier version of this copied the whole tree to local disk first. That was
a mistake — 25 minutes a run, and every disk problem above was downstream of it.
It is recorded here because the reasoning that produced it («a long compile
should not depend on a live mount») sounds prudent and was wrong: the mount is
the design.*

## Stages 4 to 7: four different problems

They look like one phase and are not. Each is blocked on the one before, and each
breaks differently.

**Stage 4 — headers.** No compilation at all; 224 copies. It exists as a stage because
everything after it must compile against *our* headers, and that is a property of where
`-I` points rather than of anything stage 4 does. Per-file rules, so touching a header
reinstalls it and everything including it rebuilds — the dependency rule the whole build
is organised around, and headers are where it bites hardest. The prerequisite lists are
grouped and split at 50: V8's make reads a line into `INMAX` = 5000 and expands a
target's prerequisites into `tgsbuf[QBUFMAX]`, also 5000, and all 224 paths at once is
about 7,800 characters.

**Stage 5 — libraries.** 19 archives, and no `lorder | tsort` on any of them: with a
valid `__.SYMDEF` the member order stops mattering (see above). Two are not what they
look like. `libg.a` is **not an archive** — `as dbxxx.s -o libg.a`, one assembled object
that happens to end in `.a`, which `ld` loads as a plain file. And `libtermlib` builds
`termcap.a`, installs it as `libtermcap.a`, and hard-links `libtermlib.a` to it, so
`-ltermlib` and `-ltermcap` are one file.

**Stage 6 — commands.** A *list*, not a loop. The tape's 113 makefiles are not a family:
`awk`'s opens by saying it is wrong, `sed` links with `cc -o sed -n *.o`, `troff` builds
two programs from overlapping object sets under different `CFLAGS`. Only six state an
object macro, one link line and nothing exotic. The list starts with what later stages
need and grows. **One rule applies to every entry: never `-l`, always the path** — for
the `ld`-has-no-`-L` reason above, `-ll` would resolve out of the running system's
`/usr/lib` in preference to the `libl.a` stage 5 just built, silently, and the build
would succeed.

**Stage 7 — the kernel.** The only stage that copies source, and not by choice:
`config` resolves its global inputs by literal string concatenation —
`strcpy(cp, "../conf/")` in `main.c`'s `gpath()` — and the makefile it generates
compiles `../sys/*.c`, `../dev/*.c`. The whole build is relative-path bound to a
directory sitting beside `conf/`, `sys/`, `dev/` and `h/`. The invariant that actually
matters is untouched: the copy goes into `$BLD`, and the share is still never written.

Two things about `config` that are not what they appear:

- **`config alice unix` is not (machine, kernel).** `mkconf(dev, sysname)` records the
  first name as `f_fn`, and the generated makefile then compiles `../dev/swap$(f_fn).c`.
  The first name selects a **swap configuration that must exist as a file**.
- **It emitted a literal `ld`** for the one command whose output *is* the product.
  Everything else it generates goes through `${CC}`, `${C2}` or `${AS}`; only the kernel
  link and `vers.c` were hardwired, so a fully staged build would have compiled every
  object with our toolchain and linked the result with the running system's loader. Now
  `${LD}` and `${CC}`, with defaults added to `conf/makefile` — V8's make has no built-in
  `LD` (`dfltmacro[]` defines `CC`, `AS`, `AR`, `YACC`, `LEX` and stops), so without one
  the link line would begin with a space and fail at the last command.

## Stage 8: a disk, and what the tree already has for it

Not built yet. Written down now because the survey came out better than expected:
**every ingredient is in `v8/`, including the boot program.**

| need | where it is |
|---|---|
| the kernel | stage 7 → `DESTDIR/unix` |
| userland | stages 4–6 → `DESTDIR` |
| a filesystem | `mkfs` on a fresh image, sized per `hp6_sizes` |
| device nodes | `v8/proto-dev` — 395 lines of `ls -l /dev`, so major, minor, owner and mode are all recoverable |
| empty directories | `v8/EMPTYDIRS` — 79 of them, listed because git cannot store an empty directory |
| `/etc` config | `v8/etc/` — `rc`, `ttys`, `passwd`, `group`, `fstab`, `termcap`, … |
| the **boot program** | `usr/sys/boot/stand/` |
| a boot block | `usr/sys/boot/bb/hpboot.s` |

That last pair is the surprise. The app never uses a boot block — the harness does
`load -o bootV8 0` then `run 2`, and `bootV8` reads `hp(0,0)unix`. `bootV8` is an
8,904-byte artefact sitting in `work/`, and it is exactly what `boot/stand` builds. So
a from-source disk needs **no third-party binary at all**: the secondary boot program
can come out of the tree like everything else, and `boot/bb/hpboot.s` is there for a
disk that has to boot without the harness.

`boot/README` is worth reading before starting: on a 780 the console `BOOT` command
runs a command file from the floppy that loads `boot` and starts it, which is why the
780 path never needed the disk's block 0 — a difference from the 750, where a ROM reads
block 0 and starts it at `0xC`.

## Status

- [x] Ordering derived from the source, not assumed
- [x] Determinism measured: code generation reproducible, symbol table is not
- [x] `v8/mk/mkdep.py` — dependency scanner and makefile generator, 14 components
- [x] Source served, not staged; case collisions resolved in netfsd
- [x] Guest clock fixed — see below
- [x] **Stage 1 builds the toolchain from the repo's source**, compiled straight
      off the share into `/b`. `tools/drive-stage1.sh` runs it end to end in
      about ten minutes.
- [x] **Stage 2: libc builds from our source** — 104,810 bytes, 229 members,
      against the tape's 104,770
- [x] **Stage 3: the system reproduces itself** — the toolchain rebuilt with
      our compiler *and* our libc is byte-identical to stage 1, all fourteen
- [ ] `cc -B` extended to `as`, `ld`, `crt0.o`
- [ ] Stages 2–3, with the fixpoint comparison
- [ ] Stages 4–7
- [ ] Stage 8, and a boot
- [ ] Stage 9 — the new system rebuilds itself under `chroot`

### The clock: not the TODR

Recorded earlier as "the TODR starts in 1976 unless `attach TODR` is used".
That was wrong, and the correction is worth keeping because it points at the
right file.

`sys/sys/machdep.c`'s `clkinit()` takes the **year from the root filesystem's
superblock** and only the position within that year from the TODR. So no TODR
setting can fix the year, and SIMH was never implicated. 1976 specifically is
the hardcoded `6*SECYR + 186*SECDAY` fallback behind *"preposterous time in
file system"*, which trips whenever the superblock time is below `5*SECYR`.

And `date(1)` cannot set it out of that: Berkeley's 1980 `date.c` does a bare
`year += 1900` on the two digits `gp()` reads, so `26` means 1926 — before
`YRREF`, so `clkinit`'s year loop contributes nothing. That is a Y2K bug in
source we now own, and `v8/usr/src/cmd/date.c` carries the usual 69/70 window
as the first substantive ipnx change to the tree.

The driver compiles our `date.c` off the share and runs it with `-u` and UTC
digits — `stime(2)` takes GMT, and going through local time would apply V8's
configured zone against the host's — then `sync`s, so the superblock carries
the year to every later boot. Jumping fifty years while the machine runs is
safe: `cron`'s `slp()` resynchronises on any delta over an hour.

### What out-of-tree building actually costs

Every stage-1 failure after the environment was sorted came from the same
place: **the tape's makefiles were written to run in the source directory**,
and we run in an object directory with the source on a read-only mount. Three
distinct shapes, each invisible in-tree:

- a script beside the source invoked bare (`:yyfix`, which needs `.` on PATH —
  and `pcc1/pcc/makefile` writes `./:yyfix` for the same script, so the tape
  disagrees with itself)
- a data file beside the source copied by relative name (`y.debug.sv`)
- a generated file that exists only in the object directory — `rodata.c`, which
  `:yyfix` writes as a *side effect* of making `cpy.c`, so it has no rule of
  its own and no file on the share. `mkdep.py` models this as `sidegen`: a rule
  with a prerequisite and no commands.

A fourth was mine rather than the tape's, and is the one to remember:
`$(CC)` was `cc`, a command resolved on PATH, used as a **prerequisite**, which
is a pathname. Thirteen components failed at once with `Don't know how to make
cc`. `cc`, `yacc` and `lex` now each carry two macros — `$(CC)` for what a rule
runs, `$(CCPATH)` for the binary whose mtime means it changed.

`cc -B` is a plain string concatenation (`ccom = strspl(npassname, "ccom")`),
so the prefix must name the directory the passes are really in:
`-B$(TOOLDIR)/lib/`, not `-B$(TOOLDIR)/`.

## Sources

- [FreeBSD `Makefile.inc1`](https://github.com/freebsd/freebsd-src/blob/main/Makefile.inc1) — stage comments and the lib-before-bin rationale
- [NetBSD `BUILDING`](https://web.mit.edu/netbsd/src/BUILDING) — `TOOLDIR`/`DESTDIR`/`OBJDIR`
- [NetBSD guide, ch. 33](https://www.netbsd.org/docs/guide/en/chap-build.html) — `build.sh` operations
- `v8/usr/doc/v8directions` — V8's own installation notes, in this repo
