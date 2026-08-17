# Track B — the V10 restoration

*Goal: the first bootable Tenth Edition Research Unix, ever — assembled on a running V8
under SIMH, targeted at an emulated VAX, and ultimately shipped in the app as
"Edition 10". Evidence for every claim: [RESEARCH.md](../RESEARCH.md) §7.*

> **This document was written for a cross-build and no longer describes one.** V10's own
> compiler, assembler and libc are in the tarball as linked VAX binaries and run on the
> V8 kernel unmodified, so V8 is the *host*, not a cross-compilation platform. Corrected
> throughout on 2026-08-16; the working record is
> [v10-log/2026-08-16.md](v10-log/2026-08-16.md).

## Ground truth

- **THERE WAS NEVER A PURE V10 DISTRIBUTION, SO OUR V10 IS A RECONSTRUCTION — AND SO
  WAS EVERY REAL ONE.** This is the most important thing on this page and it was
  established on 2026-08-17, from the tape's own artefacts. V10 was not built and
  shipped; it was **hand-built on each machine by upgrading V9 in place**, one piece at
  a time, and the tarball is one such machine's working tree caught mid-migration
  rather than a release. The consequence is not a caveat, it is a definition: an ipnx
  V10 cannot "correspond to" a real V10 machine, because no two real V10 machines
  corresponded to each other either. What we can be faithful to is *this tree*.

  The evidence, all of it re-derivable:

  | | |
  |---|---|
  | `libc.a` member dates span **4.1 years** | 1989-06 → 1993-07, across **27 distinct days**. 199 of 261 members from one June 1989 build; the other 62 recompiled in ones and twos over the next four years. A clean build dates every member within minutes of itself. |
  | The old members are **V9's** | 86% of the June 1989 C members differ from anything we can build; only 32% of the later ones do. Our compiler is built from the tape's *1995* `ccom` source, so it resembles the late compiler — and the 1989 one is not on the tape. |
  | The tooling straddles both editions | lcc's back end is `cmd/lcc/gen2/`**`vax-v9`**`/rcc`; the prebuilt lcc driver (`bowell.c`) passes **`-DV9`**; libc's `mkfile` passes **`-DV10`**. |
  | `stdio/iolib.h` has no branch for a V10 VAX | It covers *V10 without stdarg*, *pANS with stdarg* and *SGI*. Under the mkfile's own `-DV10`, `va_list` is declared only on an SGI — so the nine `printf`/`scanf` members compile under **neither** compiler. |
  | Neither compiler can build libc alone | Measured over all 261: `cc` fails 15, `lcc` fails 59. The tree needs both *because it was left half-converted*. |
  | `<shares.h>` is on no machine we have | Six members include it; it is in none of the 25,682 files, though their objects sit in `libc.a`. It existed once, on the machine that compiled them. |
  | Two kernel trees, 131 differing shared files | `sys/` and `lsys/` — see below. Consistent with a tree being migrated, not a tree being released. |

  **What follows from it, practically:**
  - **`libc.a` is a witness, not an oracle for bytes.** Byte-identity with it is
    unreachable in principle for the 1989 members, and chasing it is chasing a ghost.
    It is still excellent per-member evidence: `atof.o` (1991-12-19) matches `lcc` and
    nothing else, which is how the migration was detected at all.
  - **The right target is a coherent V10 built from the source we have**, measured
    against the tape wherever the tape can speak, with every deviation named. The
    ceiling from source is **255 of 261** libc members.
  - **Authenticity still means the tape**, not tidiness — but it means being faithful
    to *a working machine in mid-upgrade*, which is a different and more honest thing
    than pretending a release existed. See CLAUDE.md's authenticity rule.
- **Nobody has ever booted V10.** Warren Toomey's
  [2017 call for volunteers](https://www.tuhs.org/pipermail/tuhs/2017-April/011079.html)
  is still unanswered. There is **no boot media**, and that is what B3 has to make.
- **It is not a source-only snapshot.** This document said so until 2026-08-16, and
  so did [RESEARCH.md](../RESEARCH.md) §7; both were wrong, and the error shaped the
  whole plan. `tools/v10-import.py` classifies every one of the 25,346 files by its
  first four bytes, and **483 are linked VAX a.out executables** (0410/0413), with
  1,525 more object files and 150 `ar` archives. Among them:

  | | |
  |---|---|
  | `src/cmd/ccom/vax/comp` | 340,498 B — **the V10 C compiler** |
  | `src/cmd/as/as` | 57,203 B — the V10 assembler |
  | `src/libc/libc.a` | 169,296 B — **V10 libc**, 262 members, valid `__.SYMDEF` |
  | `src/cmd/adb/vax/hello` | 11,215 B — `hello, world`, linked in 1995 |
  | `src/cmd/lcc/gen2/vax-v9/rcc` | 304,392 B — lcc (ANSI), targeting V10 VAX |

  `v10/MANIFEST` records all of them with size, mode and sha256, so this is
  re-derivable rather than asserted; `tools/v10-import.py --verify` re-checks it.
- **And they run on V8.** Proven 2026-08-16 by `tools/v10-probe.sh`, 9 of 9:
  V10's `hello` printed, V10's `as` assembled, V10's `ccom` compiled, and a
  program built by all three and linked against V10's libc ran on the V8 kernel.
  Full record: [v10-log/2026-08-16.md](v10-log/2026-08-16.md).
- The source is also **remarkably complete**: full VAX kernel (six machine
  families), structurally complete libc, 378 commands, the whole 5620 stack (`v10blit` =
  `/usr/jerq` with `mux`, `32ld`, **`sam` + `samterm`**), and docs.
- **V9 is not part of this track — but it is part of this TAPE, and that is new.** The
  surviving V9 is a Sun-3 port with no VAX kernel code, so it still contributes nothing
  we can *build* from. What changed on 2026-08-17 is that V9 turns out to be causally
  central anyway: the tarball is a V9 machine part-way through becoming a V10 one, so
  roughly two hundred of `libc.a`'s members are V9 objects and the V9 VAX compiler that
  made them is lost. **We are not skipping V9; we are standing on top of it without a
  copy of it.** Anything unreproducible in this tree should be checked against that
  reading first.

### Why the binaries went unnoticed

They are not hidden. `tar tjf` lists them, and the CSRC machines' own build
leftovers (`main.o` beside `main.c`) are scattered through the tree in plain
sight. But the tarball is 243 MB of a system nobody could run, the summaries
that describe it say "source", and nothing before this project had a V8 to try
them on. The lesson is narrow and worth keeping: **the archive was never
audited by file type**, and one pass over the magic numbers answered a question
the plan had assumed for nine years.

## THE PRIORITY: a toolchain that can build a 780 kernel (2026-08-17)

Christine, setting the focus after the stage-2 investigation: *"a toolchain that will
enable us to generate a proper V10 kernel targeting VAX 11/780 that we can use to
recompile the rest of the sources."*

**This goes ahead of finishing libc, and the reason is structural: a kernel does not
link against libc.** It is built from its own sources with `cc`, `as` and `ld`, and
`crt0.o`/`libc.a` are userland concerns. So every one of the fifteen libc members we
cannot yet build — the `printf` family, the `shares` family — blocks *nothing* on this
path. The libc work below (B2.2) is real and still wanted; it is not a prerequisite and
should stop being treated as one.

**And the target is the 11/780, not the 750 we boot today.** That is the strategic
choice, not a detail:

- The app already ships a **vax780** (`libsimh/`), with our NI1010 device model, the
  idle patches, and a proven RP06/RP07 disk path. A V10/780 kernel runs on the machine
  ipnx *already has*, so V8 and V10 become one simulator instead of two.
- V10's own 780 support is complete and named `star` — `lsys/md/machstar.c`,
  `consstar.c`, `nexstar.c`, `ubastar.c`, `lsys/ml/trapstar.s` — and
  `lsys/astro/alice.m` is a real CSRC 780 configuration (`ms780`, `dw780`, `mba`).
- `lsys/io/hp.c` is the Massbus RP driver, i.e. **the same disks V8 uses here**, so the
  disk half of the machine is already proven end to end by Track A and the S track.
- The 750 was only ever the shortest road to *a* booting kernel (`seki` + MSCP), and it
  did its job: it proved the golden, stage 1 and stage 2. It is scaffolding.

Then the payoff Christine names: **a booting 780 kernel is the machine that recompiles
everything else**, which is stage 9's chroot argument arriving early and on real
hardware terms.

### The work

- [x] **K5 — `lsys/` is the kernel.** Settled 2026-08-17 on three pieces of evidence,
      none of them preference:
      - `sys/` carries **126 `.O` files**, `lsys/` **zero**. `sys/` is a tree that was
        compiled in place; `lsys/` is clean source.
      - **`seki` exists only in `lsys/`**, and `tools/v10-golden.exp:167` copies
        `lsys/astro/seki.u` as the `/unix` this project already boots. The kernel we
        have running came from this tree.
      - Both trees carry `alice.m`, `mkconf`, `io/hp.c` and `io/ni1010a.c`, and the two
        `alice.m` **differ substantially** (`sys/`'s carries machine-specific comments
        `855bb-ce`/`ba11-aw` and a different swap layout), so this could not have been
        left to chance.

      `lsys/astro/` also has the larger config set — 17 against 10, and the extra ones
      are the comets, where `sys/` instead keeps `o.alice.m`/`o.bowell.m` backups.
- [x] **K5b — the 780 target is real, and `alice.m` needed reading rather than
      quoting.** Two of this project's own notes were wrong about it:
      - **Root is `ra`, not `hp`.** `root regfs ra 0100` — UDA50/RA81, with 0100 being
        the BITFS bit. `mba 1` is present only for the `tm78`/`tu78` tape, so "alice
        uses the same Massbus disks V8 does" is false. That is fine, and arguably
        better: the golden is already an RA81 and `v10mkbitfs` already writes for it.
      - **`ni1010a` and the whole TCP/IP stack are already configured** (`ni1010a 0 ub 1
        reg 0764000 vec 0350`; `ip 4 udp 16 tcp 96 arp 4`). What is *not* configured is
        `netafs 0`/`netbfs 0` — so K12 is a two-line change to a config we write, exactly
        as predicted.

      Measured against our own simulator (`show devices` on `work/opensimh/BIN/vax780`),
      the machine is a close match and the deltas are known:

      | `alice.m` | our `vax780` | action |
      |---|---|---|
      | `ms780 0/1` | `MCTL0`, `MCTL1` | as-is |
      | `dw780 0` **and** `1` | `UBA` — **one only** | move everything on `ub 1` to `ub 0` |
      | `uda50 0` **and** `1` | `RQ` (UDA50A) + `RQB/C/D` disabled | one controller, or enable RQB |
      | `ni1010a 0` | `IL` — present but **disabled** | `set il enable`; it is our own device model |
      | `dz11 0/4/5` | `DZ`, 32 lines | as-is |
      | `mba 1`, `tu78` | `MBA1`, `TU` | as-is |

      alice's UDA50 addresses are, in its own words, *"annoyingly nonstandard"*
      (`0772160`) where SIMH's RQ defaults to `0772150` — so either the config moves or
      `set rq addr=` does.
- [ ] **K5c — write OUR 780 config** rather than compiling `alice.m` verbatim. This is
      the "generate a new config we can build from" instruction applied to the kernel:
      one Unibus adapter, one UDA50 at SIMH's address, `il` enabled, `netafs`/`netbfs`
      non-zero, swap sized for the image we actually build. Derived from `alice.m` and
      diffed against it in `v10/src/PATCHES.md`, so what is Bell Labs' and what is ours
      stays visible.
- [ ] **K6 — run the prebuilt `mkconf`** (`lsys/lib/mkconf`, 37,932 B) on `alice.m` to
      generate the kernel makefile, exactly as V8's `config`(8) does for its own tree.
      It is a 1995 V10 binary, so it runs on the machine we already have — same status
      as `ccom` and `as`.
- [ ] **K7 — compile the 780 kernel with the STAGE 1 toolchain**, on V10, and let the
      failures name themselves. This is the first real test of stage 1 against something
      other than itself: ~750 files of K&R C and VAX assembler, none of it ANSI, so the
      `iolib.h`/`lcc` class of problem should not appear at all.

      **THE KERNEL IS NOT REFACTORED** (Christine, 2026-08-17) — refactoring libc is
      enough. It is compiled as it stands, which the evidence says should work: the
      kernel is K&R throughout and `cc` is a K&R compiler, so there is nothing to
      convert and no second compiler to reach for. If a kernel file *does* fail, treat
      it as `mv.c` and `fsck.c` were treated — a one-line named patch with the reason
      recorded — and not as licence to start a conversion.
- [ ] **K8 — a bootable 780 disk**: RP07 image, V10 root filesystem, `hpboot`-equivalent
      boot block from `lsys/boot/star/`, and the 780's own console protocol rather than
      the retargeted `uda750` ROM this project wrote for the 750.
- [ ] **K9 — boot it under the app's own `vax780`**, not the desktop build, which is
      what makes V10 shippable rather than merely demonstrable.
- [ ] **K10 — recompile the world on it.** At that point the mixed-compiler libc, the
      283 commands and the fixpoint all become work done *inside* V10 rather than
      against it.

Sequenced this way, the libc questions below are no longer on the critical path — they
are what K10 cleans up once there is a machine to clean it up on.

### What the 780 kernel unlocks, and it is more than a kernel

Christine, 2026-08-17: *"Once you have a working V10 kernel and toolchain, you are no
longer bound by V8 filesystem limitations and can generate a good image spanning full
capacity. You can then get netfs working so you don't have to copy source."*

Both of those are constraints this project **imposed on itself** to get started, and a
V10 kernel we configure ourselves removes both. Worth writing down so they are not
carried forward out of habit:

- [ ] **K11 — a full-capacity filesystem.** Today the V10 disks are built *by V8*, so
      they must be readable by V8 — and V8's `filsys.h` has only the R and B arms of the
      superblock union, no N, which caps a filesystem at
      `MAXSMALL = BITMAP*BITCELL = 961*32 = 30752` blocks. That is why the source disk
      is 16,384 blocks on a 456 MB RA81. **Once V10 runs its own `mkfs`/`mkbitfs`, V8
      never has to read the result and the ceiling is gone** — full RP07 or RA81
      capacity, and the whole 243 MB tree fits with room to spare.
- [ ] **K12 — netfs on V10, and no more courier disks.** "There is no netfs on V10" was
      true of *`seki`*, for two reasons that are both ours to change once we generate the
      config:
      - `lsys/astro/seki.m` configures `netafs 0` and `netbfs 0` — the filesystem types
        are compiled in with **zero instances**. We write the 780 config, so we give it
        instances.
      - SIMH's `vax750` has no Interlan. **The app's `vax780` does** — this project
        modelled the NI1010 for it (`libsimh/patches/pdp11_il.c`) and V10 ships
        `lsys/io/ni1010a.c` for the same card.

      So the 780 kernel plus `netfs/` (the SwiftPM server already in the app) gives V10
      the same `/n/src` live share V8 has had since the N track — and
      `tools/v10-srcdisk.sh`, the second RA81, and the whole copy-then-mount dance
      become scaffolding to retire. It also removes the "never edit `v10/` while a build
      is running" hazard's *cause* rather than just its warning.

That is the real argument for the 780: not one kernel, but the end of three workarounds
at once — two simulators, a block ceiling, and source arriving on a disk.

## B2.2 — a libc we can BUILD (the replan, 2026-08-17)

Christine, closing the stage-2 investigation: *"This is no longer a game of replicating
a config, we need to generate a new config that we can build from."*

That is the right reading of everything above. The tape's `libc.a` is a four-year
accretion whose oldest 199 members were compiled by a V9 compiler nobody has, so
reproducing it is impossible and aiming at it is aiming at a ghost. The target is a
**coherent libc that one compiler builds from source we hold** — and the tape becomes a
witness we consult, not a specification we chase.

### The compiler is `cc`, V10's own pcc2

Measured over all 261 members, not chosen by preference:

| | builds | fails |
|---|---|---|
| `cc` alone | **246** | 9 `printf` family + 6 `shares` |
| `lcc` alone | 202 | ~50 K&R members + the same 15 |
| `cc` + `lcc` | 246 | the same 15 |

Four reasons it is `cc`:

1. **It is already closest** — 246 against 202, so the refactoring bill is ~20 files
   rather than ~50.
2. **It is what the rest of the edition uses.** The kernel and all ~283 commands are
   K&R compiled by `cc`. Standardising libc on `lcc` would give the *edition* two
   compilers again, which is the disease and not the cure.
3. **It is fully buildable from source, on V10, today** — stage 1 does exactly that
   (`yacc cpp ccom as c2 ld cc`, 45/46). `lcc` is buildable too (front end
   `cmd/lcc/c/`, back end `gen3/gen.c`) but needs an ANSI compiler to bootstrap
   itself, i.e. the prebuilt `rcc` we cannot rebuild.
4. **Stage 3's fixpoint only means something with one compiler.** "The toolchain
   reproduces itself" is not a statement you can make about a mixture.

So the direction of conversion is **ANSI → K&R**, which is the opposite of V11's and
correct for exactly that reason: V10 keeps the 1989 language, V11 changes it.

### The work, in dependency order

- [ ] **B2.2a — fix `stdio/iolib.h`.** It has branches for *V10 without stdarg*, *pANS
      with stdarg* and *SGI*, and none for a V10 VAX, so nine members fail under both
      compilers. r70 ships `varargs.h`, which is the K&R spelling; the V10 branch needs
      it. One named patch in `v10/src/`, `mv.c`/`fsck.c` model. **Unblocks 9.**
- [ ] **B2.2b — reconstruct `<shares.h>`.** Six members include it and it is in none of
      the 25,682 files, but it is recoverable rather than lost: the six `.c` files name
      every field they touch, their compiled objects are in `libc.a` to check offsets
      against, and V10's share scheduler is in the kernel tree — so the struct can be
      derived and verified. **Unblocks 6, and takes the ceiling to 261.**
- [ ] **B2.2c — K&R the remaining ANSI members** (~20, listed in `mkdep.py`'s
      `LIBC_LCC`). Mechanical and reviewable: prototypes → old-style definitions,
      `void *` → `char *`, `size_t` → `int`, `<stdarg.h>`/`va_list` →
      `<varargs.h>`/`va_list`, `const` dropped. Behaviour is unchanged; only the
      spelling moves back. Each file a named patch.
- [ ] **B2.2d — delete `LIBC_LCC` and the second compiler** from the generated
      makefile, so `libc.mk` uses `$(COMPILE)` for all 261 and there is one compiler in
      the build by construction rather than by policy.
- [ ] **B2.2e — re-measure, and keep the witness.** Assert 261/261 build with `cc`
      alone and that the archive links and runs a program; report byte-identity with the
      tape as information, never as a pass condition. Expect it to *fall* as members are
      refactored, and that is correct: we are no longer trying to match a V9 artefact.
- [ ] **B2.2f — then stage 3**, on **stripped** binaries (V10's `cc.c` puts `getpid()`
      into its temp filenames exactly as V8's does), with `stage 3 == stage 3b` as the
      required test and `stage 1 == stage 3` as the interesting one.

### What this costs, stated plainly

The result is **not** the archive Bell Labs shipped, and it cannot be. It is a libc
built from Bell Labs' source by Bell Labs' compiler, coherent in a way the original
never was, with every departure from the tape named in `v10/src/PATCHES.md`. That is
the honest form of this restoration — and it is worth saying that the alternative, a
mixture that reproduces 150 members of a V9/V10 hybrid and cannot build 15 at all, is
less faithful, not more: it reproduces an accident.

## Source inventory

| Artifact | Contents | Get it from |
|---|---|---|
| `v10src.tar.bz2` (71 MB) | The source tree (kernel `sys`/`lsys`, `cmd`, `libc`, `630/`…) | [TUHS Dan_Cross_v10](https://www.tuhs.org/Archive/Distributions/Research/Dan_Cross_v10/) |
| `v10blit.tar.bz2` (2.5 MB) | `/usr/jerq` — 5620 software incl. sam/samterm, prebuilt `.m` terminal binaries | same |
| `secombe.gz` / `milligan.gz` / `sellers.gz` | Norman Wilson's 1995 snapshot: src / jerq / docs (overlaps Dan Cross's; equivalence unverified) | [TUHS Norman_v10](https://www.tuhs.org/Archive/Distributions/Research/Norman_v10/) |
| `r70include.tar` | `/usr/include` reconstruction — from the *1997* r70 system; "probably is not precisely concordant" with the 1995 tree | same |

Note: the [Alhadis GitHub mirror](https://github.com/Alhadis/Research-Unix-v10) omits the
`630/` tree and others — use the TUHS tarballs as the source of truth.

## The bootstrap chain

There is no cross-build. V10's own passes run on the V8 kernel, so the chain
that mattered collapsed to one step on 2026-08-16:

```
4.1BSD ──(myv8, proven)──▶ V8 on SIMH vax780
  V10's own comp + as + libc.a, run on V8   ← they just run: 9/9, v10-probe.sh
    + cpp, c2, ld built from V10 source     ← the only three with no binary
  that toolchain builds ──▶ V10 userland    ← reconcile /usr/include skew here
                       ──▶ V10 kernel + boot block  ← lsys/boot constraints
  mkfs + dd  ──▶ v10.disk ──▶ first boot attempt
```

**One directory holds the toolchain, and `-B` points a `cc` at it.** V8's
`cc.c` and V10's are the same program eight years apart — same passes
(`/lib/cpp`, `/lib/ccom`, `/lib/c2`, `/bin/as`, `/bin/ld`, `/lib/crt0.o`),
same `-B` prefix, same `-t` pass selection. Ours carries S5's extension, where
`-t` also covers `as`, `ld`, `crt0.o` and `libc.a`, so `-B/usr/v10/lib/
-t02palc` uses nothing of V8's but the driver and `/usr/include`. That seal was
built to stop V8's own build reaching into the running system; it turns out to
be the lever that points a `cc` at a different *edition*. `tools/v10-toolchain.sh`
assembles the set and uses it.

**Toolchain names, corrected against the actual tree.** Earlier drafts said
"pcc2". The tarball has no `pcc2`: the compiler is **`cmd/ccom`** (1.66 MB,
127 files, with `common/` and a `vax/` code generator — and a **linked `comp`
binary** in `vax/`), alongside an older **`cmd/pcc1/pcc`**, the peephole
optimiser **`cmd/c2`**, the assembler **`cmd/as`** (also prebuilt), and
`libcc`.

**There IS a system linker: `cmd/ld.c`.** This document claimed until
2026-08-16 that none was present and that the only `ld` source belonged to the
terminal. It is 1,946 lines, *"ld - string table version for VAX"*, complete,
and it supports the `-X` our `cc` passes. It was missed because it is a loose
file under `cmd/` rather than a `cmd/ld/` directory — the same reason
`cmd/cc.c` is easy to miss.

Why through V8: the toolchain is written to be built *on a Research Unix system*, and V8
under SIMH is the only bootable one in existence. The community assumed this route in 2017
(Warner Losh: "reconstruct v8, v9 and v10 to varying degrees"); nobody has demonstrated it.

**The escape hatch is retired.** It read: *if V8-hosted builds prove
intractable, reconstruct pcc2 + SGS as modern cross-tools on macOS.* They did
not prove intractable — the V10 compiler ran on V8 at the first attempt — and
a modern cross-toolchain would now be strictly more work for a less authentic
result.

## Machine target

| Target | V10 kernel support | SIMH | Call |
|---|---|---|---|
| VAX-11/780 (`star`) | trap/boot code + real CSRC configs (`alice.m`) | `vax780` | **First attempt** — continuity with the app's existing core; risk: 780 code may be stale (Labs mainline was the 8550) |
| MicroVAX II (`mflow`, KA630) | Boot via DEC VMB documented in-tree | `microvax2` | Fallback #1 — exact match both sides |
| VAX 8200 (`bvax`, KA820) | ROM-boot supported | `vax8200` | Fallback #2 — exact match both sides |
| VAX 8550/8700 (`naut`) | Labs mainline | **not emulated** | Unavailable |

## Boot-block constraints (from `lsys/boot/README`)

- The 512-byte boot block "does it all": the kernel must sit **at the start of the
  filesystem** and be **no more than singly indirect**.
- ROM-boot path covers 11/750, 8200, 6200, 8550; MicroVAX II/III boot via DEC **VMB** with
  a special 1024-byte first-sector scheme.
- Read the README in full before building images:
  [V10/lsys/boot/README](https://www.tuhs.org/cgi-bin/utree.pl?file=V10/lsys/boot/README).

## Known gaps to engineer around

- **`/usr/include` skew**: the r70 (1997) headers vs. the 1995 source — expect compile
  failures; reconcile per-failure and log each one. Now imported as
  `work/v10/include` (349 headers) and **partly measured** (2026-08-16):
  `ranlib.h`, `pagsiz.h`, `ctype.h`, `setjmp.h` and `struct _iobuf` are
  **identical** to V8's; `a.out.h` differs by one bit-field *name* at the same
  width, so the object formats agree; `ar.h` differs only by an addition. But
  V10's `stdio.h` includes a `<tmpnam.h>` V8 lacks and its `sys/types.h` drops
  the `major()`/`minor()` macros — so **do not point `-I` at the whole tree by
  reflex**: anything linking against V8's libc wants V8's headers, and B1 took
  exactly one header (`libc.h`) rather than the set.
- **`mk`, not `make`.** V10 builds with `mk` and its `mkfile`s assume a source
  directory you can write to — which an out-of-tree build off a read-only
  share is not. B1 dodged this by copying seven files and writing the `cc`
  lines by hand; a userland cannot. `cmd/mk/` is in the tree, with a prebuilt
  binary, so building `mk` is the obvious first move of B2.
- **`rc` shell source absent** (man pages survive) — use `sh`, which is present.
- **pcc2 provenance**: System III/V-derived; stays inside the image; see
  [licensing.md](licensing.md). Note this now covers a **binary** we run, not
  just source we compile — the licensing question is unchanged (the 2017
  covenant covers the distribution either way) but the fact is worth stating
  plainly rather than discovering later.
- These are "snapshots, not formal releases" (Norman Wilson) — expect makefile paths,
  usernames, and machine names from the CSRC environment baked into configs.

## Working conventions

- Pristine TUHS tarballs stay pristine; **every change is a patch in a logged series** with
  a one-line rationale. The patch log is a publishable preservation artifact in its own
  right, win or lose.
- Keep a lab notebook per session (`docs/v10-log/YYYY-MM-DD.md`): what was tried, what
  broke, exact error text (searchable later, citable on TUHS).
- **Announce early on TUHS.** This answers an open 2017 challenge; the people who ran these
  systems (and wrote these tools) still read that list. Recruit rather than grind alone.

## Success ladder

1. ~~pcc2 built by V8's cc compiles a V10 hello.c~~ — **done 2026-08-16**, and
   not the way this rung was written. V10's `ccom` needed no building; it runs
   on V8 as it stands. `cpp`, `c2` and `ld` were built by V8's `cc` from V10
   source, and `cc -B/usr/v10/lib/ -t02palc` compiled and ran a hello.c
2. ~~One mid-size V10 command builds and runs on V8 (toolchain trusted)~~ —
   **done 2026-08-16**: `cmd/ld.c`, 1,946 lines, compiled by V10's own
   compiler. The resulting linker then linked hello, producing a binary whose
   text and data are identical to the one the first linker made
3. V10 libc builds — **next**, and where the r70 header skew starts to bite
4. Core userland builds (sh, init, getty, login, mount, fs tools, mux host side)
5. `star` kernel links
6. Boot block + filesystem image assemble
7. **Kernel reaches single-user on SIMH** ← the headline moment; announce
8. Multi-user; `mux` from a dmd_core 5620 (firmware 8;7;3 — protocol unchanged from V8)
9. `sam`/`samterm` running
10. Reproducible `v10.disk` build script → merge into the app as "Edition 10"
