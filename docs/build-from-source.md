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

It stops short of the whole toolchain: `as`, `ld` and `crt0.o` are still hardcoded to
`/bin/as`, `/bin/ld`, `/lib/crt0.o`. Extending `-B` to cover them is our change, and it
is the kind of change owning the source is for — a handful of lines in `cc.c` rather
than a wrapper script fighting absolute paths.

## The stages

`TOOLDIR=/bld/tools`, `DESTDIR=/bld/root`, `OBJDIR=/bld/obj`. **Nothing is ever
installed into `/`.** The running system stays the system that works, all the way to
the end, and the new system is only ever a directory tree until `mkfs` turns it into a
disk.

| stage | builds | with | into |
|---|---|---|---|
| **0** | — | the tape's `/bin/cc`, `/bin/make`, `/lib/libc.a` | — |
| **1** | yacc, then make, lex, cpp, ccom, c2, as, ld, ar, ranlib, nm, size, strip, cc | stage 0 | `TOOLDIR` |
| **2** | libc | stage 1 | `TOOLDIR/lib` |
| **3** | the whole toolchain **again** | stage 1 + stage 2 libc | `TOOLDIR2` |
| **4** | headers | — | `DESTDIR/usr/include` |
| **5** | libraries | stage 3 | `DESTDIR/lib`, `DESTDIR/usr/lib` |
| **6** | 113 makefile commands + 163 loose `.c` + 6 `.sh` | stage 3 | `DESTDIR/bin`, `DESTDIR/usr/bin`, `DESTDIR/etc` |
| **7** | the kernel, via `config` | stage 3 | `DESTDIR/unix` |
| **8** | a bootable disk | `mkfs` + `DESTDIR` + `hpboot` + `proto-dev` | a new RP06/RP07 image |
| **9** | the whole system, again, from inside itself | `chroot DESTDIR` | the completeness proof |

### Why stage 3 exists

Stage 1's compiler was built by the *tape's* compiler. Stage 3's was built by stage 1's.
If the two are identical after stripping, the build is a **fixpoint**: the compiler our
source describes reproduces itself exactly, which is the strongest evidence available
that the source is complete and that nothing in the running system leaked into the
result. It is the same three-stage comparison GCC has used for decades, and it costs one
extra toolchain build.

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
   The only writes outside `/bld` are to `/tmp`.
2. **`PATH=$TOOLDIR/bin:/bin:/usr/bin`** — new tools win, old tools remain as a fallback
   the moment a new one is deleted.
3. **The compiler is selected explicitly**, via `-B`, never by shadowing `/lib/ccom`.
4. **The new system is a directory until the last step.** `mkfs` writes a *second* drive;
   the drive we booted from is never the drive we are building.
5. A stage that fails leaves `/bld` in whatever state it reached and the running system
   untouched, so the recovery is always "look at the log and run the stage again".

## Status

- [x] Ordering derived from the source, not assumed
- [x] Determinism measured: code generation reproducible, symbol table is not
- [ ] `cc -B` extended to `as`, `ld`, `crt0.o`
- [ ] `v8/mk/mkdep.py` — dependency scanner and makefile generator
- [ ] Stages 1–3, with the fixpoint comparison
- [ ] Stages 4–7
- [ ] Stage 8, and a boot
- [ ] Stage 9 — the new system rebuilds itself under `chroot`

## Sources

- [FreeBSD `Makefile.inc1`](https://github.com/freebsd/freebsd-src/blob/main/Makefile.inc1) — stage comments and the lib-before-bin rationale
- [NetBSD `BUILDING`](https://web.mit.edu/netbsd/src/BUILDING) — `TOOLDIR`/`DESTDIR`/`OBJDIR`
- [NetBSD guide, ch. 33](https://www.netbsd.org/docs/guide/en/chap-build.html) — `build.sh` operations
- `v8/usr/doc/v8directions` — V8's own installation notes, in this repo
