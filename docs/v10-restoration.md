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
- [x] **K5c — write OUR 780 config. DONE** — `v10/src/lsys/astro/ipnx780.m` exists,
      K7 links a kernel from it and K8/K9 boot that kernel on both simulators. This box
      was still `[ ]` on 2026-08-18, a day after the config it asks for had booted twice;
      see the "stale checkboxes" note under K9. The original text follows, unchanged,
      because it is an accurate description of what was written. This is
      the "generate a new config we can build from" instruction applied to the kernel:
      one Unibus adapter, one UDA50 at SIMH's address, `il` enabled, `netafs`/`netbfs`
      non-zero, swap sized for the image we actually build. Derived from `alice.m` and
      diffed against it in `v10/src/PATCHES.md`, so what is Bell Labs' and what is ours
      stays visible.
- [x] **K6/K7 ARE FIVE COMMANDS, NOT A 750-FILE BUILD.** Found 2026-08-17 by reading
      `lsys/lib/mk.star`, which is 23 lines. **Only two files are compiled** — the
      generated `conf.c` and a `vers.c` date stamp — because the kernel is on the tape
      as prebuilt archives, one per subsystem:

	asstar.o  fs.a  io.a  star.a  bvax.a  os.a  vm.a  inet.a

      and `lsys/lib/` carries the whole star (780) tool-set beside them: `mkconf`,
      `devs`, `tab`, **`conf.star`** (the 780's standard table sizes), **`low.star`**,
      `hupdate`, `listdep`, `mkall`. The recipe, translated out of `mk` syntax into the
      commands to run, with `$M` the config name:

	1  mkconf -t tab -l low.star -d devs -s $M.s.s -c $M.c.c conf.star $M.m
	2  as -o $M.l.o ../ml/param.s ../ml/logen.s $M.s.s
	3  cc -DKERNEL -I.. -c $M.c.c
	4  echo 'char version[] = "Unix 10e <date>";' >vers.c ; cc -c vers.c
	5  ld -n -X -o $M.u -T 80000000 -e start $M.l.o $M.c.o $LIBS vers.o

      Three things follow, and they are the reason this was worth reading before
      writing any harness:
      - **The stage-1 toolchain is barely exercised by a kernel build** — one `cc -c`,
        one `as`, one `ld`. So "can stage 1 build a kernel" is nearly free to answer,
        and a failure will be in `mkconf`'s output or the link, not in 750 compiles.
      - **`-T 80000000 -e start`** is the load address and entry point, which is exactly
        what the boot block and the console must agree with. `ld -n` is shared text.
      - **The archives are prebuilt 1995 binaries**, same provenance as `ccom` and `as`,
        so a first bootable 780 kernel needs no world build. Rebuilding those `.a` from
        `lsys/` source is a later, separable step — and `lsys/` is now on the source
        disk (36/36) for exactly that.
- [x] **K8/K9 — IT BOOTS.** 2026-08-17, `tools/v10-boot780.exp`, 5/5:

	Unix 10e ipnx 780
	mem = 6062080
	login: root

      That banner is ours — `vers.c` says `"Unix 10e ipnx 780"`, a string no Bell
      Labs kernel carries — and the assertion for it searches the running `/unix`
      with `sed` (V10 has no `strings`), because `v10_boot` consumes the banner on
      its way to `ogin`.

      **No new boot block was needed.** `lsys/boot/star/uda` is used *unpatched*:
      its compiled-in addresses — `ubamap 0x20006800`, `ubabase 0x20100000`,
      `udareg 0772150` — are the 780's already, which is exactly what
      `tools/v10-uda750.py` had to move for the 750. The one retargeting this
      project ever did to a V10 binary turns out to be the 750's problem alone.
      Load at `FA00`, enter at `FA02`, as `lsys/boot/star/defboo.cmd` does on real
      hardware.

      So the chain is complete and every link is V10's: stage 1 rebuilt V10's
      compiler with V10's compiler (45/46) → `mkconf`/`as`/`cc`/`ld` built a
      226,263-byte kernel from our config (17/17) → it boots on open-simh's
      **vax780**, the same simulator the app already ships for V8.
> **The five entries that used to stand here are RESOLVED, and they are kept rather than
> deleted because the marker convention says so — a superseded step is recorded as
> superseded, never silently dropped.** They were written before the work and were
> overtaken by the `[x]` entries above, which is a real hazard and not just untidiness:
> the stale `[ ] K8` and `[ ] K9` sat *below* the `[x] K8/K9 — IT BOOTS` that supersedes
> them, and on 2026-08-17 they were read as the current state and reported as the next
> step. **A plan with two answers to the same question will be read at the wrong one.**
>
> - ~~**K5c — write OUR 780 config**~~ → done: `v10/src/lsys/astro/ipnx780.m`, derived
>   from `alice.m`, one Unibus adapter, one UDA50 at SIMH's address, `il` enabled.
> - ~~**K6b — run the prebuilt `mkconf`**~~ → done, on **our** config rather than
>   `alice.m` verbatim, which is the same instruction one level up. `tools/v10-kernel.sh`
>   asserts `mkconf accepted our config`, `mkconf wrote conf.c` and `mkconf wrote low.s`.
> - ~~**K7 — compile the 780 kernel with the STAGE 1 toolchain**~~ → done, **17/17**,
>   and the prediction held: no kernel file needed a patch. Also much smaller than
>   planned — `lsys/lib/mk.star` compiles **two** files, not ~750, because the kernel
>   ships as eight prebuilt per-subsystem archives.
> - ~~**K8 — a bootable 780 disk**~~ → done, **5/5**. The plan expected an RP07 image and
>   an `hpboot`-equivalent; both were wrong. Root is `ra` (UDA50/RA81), and
>   `lsys/boot/star/uda` needed **no** patching — its compiled-in addresses are the
>   780's already, which is what `tools/v10-uda750.py` had to move for the 750.
> - ~~**K9 — boot it under the app's own `vax780`**~~ → done, **5/5** (2026-08-17). See
>   below.

- [x] **K9 — IT BOOTS UNDER THE CODE THAT SHIPS.** 2026-08-17,
      `bash tools/v10-boot780.sh app`, 5/5 — `libsimh/build/macos/vax780cli`, the CLI
      over the *static library both app targets link*, not the desktop open-simh build:

	sim> run FA02
	unix
	Unix 10e ipnx 780
	mem = 6062080
	login: root

      **One harness, two simulators**, selected by a single argument, so the assertions
      cannot drift between "it boots" and "it boots in the app" — the only difference
      between the runs is which binary is spawned. Three things differ about the library
      and all three are expected: it requires a config-file argument (`test/main.c`
      returns 2 without one, so `V10_SIMH_ARGS` hands it a throwaway config and it then
      reads stdin as the desktop build does); `set noasynch` answers *Command not
      allowed*, because synchronous operation is a **build-time guarantee** there rather
      than a setting; and `set il enable` works, since the NI1010 model is this project's
      own patch and is in both builds.

      The library already had every device V10's 780 config needs — `RQ` UDA50A at
      `2013F468`, which is `0772150`, **exactly the address compiled into the tape's own
      boot ROM**.

      `tools/v10-boot780.sh` is new and is the wrapper this harness never had: it was
      being run by hand, so the clone rule was whoever typed it. It writes `/etc/motd`,
      and booting rewrites the superblock, so it must have its own copy.
- [x] **K10 — recompile the world on it.** Done in three measured stages, all
      inside V10, with V10's own compiler
      ([docs/v10-log/2026-08-18.md](v10-log/2026-08-18.md)):

	K10.1  bash tools/v10-compile.sh    247 of 358 units compile     20/20
	K10.2  bash tools/v10-libs.sh       500 of 500 library members   24/24
	K10.3  bash tools/v10-link.sh       200 linked and installed     34/35

      K10.1 compiles only — no libraries, no linking — so a failure there is a
      **language or header** fact. K10.3 links against K10.2's archives and
      installs into a **staged root** at `/usr/w10`, never over the machine's own
      `/bin` and `/etc`: the 46 prebuilt binaries stay available as the oracle,
      a bad `/etc/init` cannot make the disk unbootable, and K11 gets the tree it
      wants to copy in.

      Three things K10 measured that change what the phase *means*:
      **a `cmd/` directory is not necessarily a command** — 71 units carry more
      than one `main()`, `cmd/worm` alone holding 22 programs; **`gets` was
      deleted from libc by Bell Labs in 1988**, in the tape's own words, so the
      two commands that will not link over it are the tape working as intended;
      and **one generic recipe has a limit** — `cmd/sh` fails on a `profile.c`
      that is not in its own `$OFILES`, which is K10.4's work.

Sequenced this way, the libc questions below are no longer on the critical path — they
are what K10 cleans up once there is a machine to clean it up on.

- [x] **K10.4 — read each unit's own object list. DONE** (2026-08-18) and worth
      **247 → 251 compiled, 200 → 203 linked**. Three keep-witnesses and two refusals,
      all recorded in CLAUDE.md and in `v10/mk/gen/world.drop`; the second inconsistency
      it exposed was that `world_link` counted `main()`s among sources the build does not
      compile, so `cmd/sed` was filed as a subsystem over `osed0.c`. As planned: `worldc.sh` compiles every
      `.c` it finds, and a unit's directory holds files its build does not use.
      Parsing `OFILES`/`OBJS`/`OBJECTS` where a unit has one would close `sh`
      and probably several more; it also changes the basis of the measurement, so
      the new number is not directly comparable to 247/200 and must be reported
      as its own reading.

### What the 780 kernel unlocks, and it is more than a kernel

Christine, 2026-08-17: *"Once you have a working V10 kernel and toolchain, you are no
longer bound by V8 filesystem limitations and can generate a good image spanning full
capacity. You can then get netfs working so you don't have to copy source."*

Both of those are constraints this project **imposed on itself** to get started, and a
V10 kernel we configure ourselves removes both. Worth writing down so they are not
carried forward out of habit:

- [x] **K11 — a full-capacity filesystem. DONE** (2026-08-18,
      `bash tools/v10-bigfs.sh`, **20/20, exit 0**). V10 made, checked, mounted,
      wrote to, unmounted and remounted a **111,384-block, 435 MB** filesystem —
      3.6× the 30,752 every previous V10 disk stopped at — and the host reads
      `flag=1` off it, the out-of-superblock bitmap arm V8's `filsys.h` does not
      have. The two free-space figures agree exactly from different sources:
      `s_tfree` 110,311 against 110,311 counted bit by bit out of the four bitmap
      blocks at the end of the volume. Details, including four assertions that
      could not fail and one minor number that wrote to the wrong disk, in
      [docs/v10-log/2026-08-18.md](v10-log/2026-08-18.md).

      The analysis this item was written from was exactly right and is worth
      keeping: the V10 disks were built *by V8*, so they had to be readable by V8,
      and V8's `filsys.h` has only the R and B arms of the superblock union — no N
      — which caps a filesystem at `MAXSMALL = BITMAP*BITCELL = 961*32 = 30752`
      blocks. That is why the source disk is 16,384 blocks on a 456 MB RA81. Once
      V10 ran its own `mkbitfs`, V8 never had to read the result and the ceiling
      was gone. What the run added to the prediction is the size of the new one:
      `largefree()` refuses only when its bitmap reaches `BITMAP-1` blocks of
      32,768 bits, so the ceiling is now **31,457,280 blocks of 4096 = 128 GB**,
      four hundred times the largest disk this project emulates. The whole 243 MB
      tree fits on one filesystem with room to spare.
- [x] **K12 — netfs on V10, and no more courier disks. COMPLETE** (24/24). K12.0 — netfs
      mounts over a pipe, 16/16 — so the client, the netb protocol library and `fmount(2)`
      all work and only the transport is open. K12.1 below is that transport and is the
      one live item in this plan. "There is no netfs on V10" was
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

      **Both of those two reasons are already discharged, which is worth saying plainly
      before the phase starts.** `v10/src/lsys/astro/ipnx780.m` configures `netafs 4` and
      `netbfs 4` at lines 127–128 and carries `ni1010a 0 ub 0 reg 0764000 vec 0350`; K7
      builds that kernel and K9 boots it to `login:` under the library the app links. So
      K12 is not "give V10 a network filesystem" — the client is compiled in, with
      instances, on a machine that runs. What is left is the same four-fault list the N
      track worked through, and **reading V10's own `lsys/os/streamio.c` changes the size
      of it** (measured 2026-08-18, host-side, before any run):

      - **The hang is already fixed.** V8's `istread()` waited forever for the `M_DELIM`
        a zero-length Datakit write used to produce, so every EOF hung. V10's sleeps
        `tsleep(..., PRIBIO, 30)` and returns −1 on `TS_TIME`, with a `printf` behind a
        parameter whose declaration reads *"flag is for timeout debugging"*. That fault
        does not transfer.
      - **The 512-byte stream head does.** `struct qinit strdata = { strput, NULL,
        nilopen, nulldev, 512, 256 }` — the same high-water mark V8 had. But V10 has a
        path V8 did not: `if (count >= 512 && stq->wrq->next->flag&QBIGB)` at two sites
        in the same file, so a **QBIGB** queue takes big transfers whole. Whether pushing
        that flag is enough is the first thing to measure, and it is cheaper than
        patching a constant.
      - **The short read and the discarded remainder both transfer.** `istread()` returns
        `nc` whenever a queue momentarily empties and the peer has not set `QDELIM`, and
        it copies `min(count, wptr-rptr)` and then frees the block either way.
      - The userland is *better* than V8's: `src/netfs/` ships `libnetb` (which K10.2
        already builds and installs as `libnetb.a`), `serv/zarf` to present a local
        filesystem, and `runfs`/`setup` to start and supervise servers — where V8 had the
        client only.

      Sequenced that way K12 is a phase, not a run: kernel stream work, then a transport,
      then `nmount`. The N track was N0–N7 for the same ground on V8.

- [x] **K12.0 — NETFS RUNS ON V10, over a pipe. DONE** (2026-08-18,
      `bash tools/v10-netfs.sh`, **16/16, exit 0**). The decisive measurement put
      ahead of the machinery, and it settles which half of K12 is real. V10 ships
      `runfs`, which mounts a netfs filesystem on a **pipe** via `fmount(2)` —
      no device node, no Interlan, no TCP, no line discipline — with `zarf` as the
      server. Serving `/usr` and mounting it at `/n/local` made the whole test a
      loopback, so `cmp` could hold the protocol to the byte:

	# ls /n/local          adm bin blit include jerq k10lib lib obj s1 tmp
	# cmp /n/local/include/stdio.h /usr/include/stdio.h     byte-identical
	# cp /etc/motd /n/local/tmp/nbprobe                     and it writes

      So **the client, the netb protocol library and the mount all work**, and the
      remaining work is transport and nothing else. It runs on K7's kernel built
      on top of K10.2's libraries (`bash tools/v10-kernel.sh
      ipnx-v10-ra81.img.stage1.k102`, 17/17), because `seki` cannot mount a
      `netbfs` at all — zero instances — and `zarf` needs `libnetb.a`.

      One finding on the way, and it is the tape's usual one: `serv/makefile`
      names the **System V** directory reader (`libdir.c`, `#include <dirent.h>`,
      which r70 does not have) on a Research Unix tree, while `resdir.c` sits
      beside it saying *"read directories, research-style / uses dirread system
      call, which does just what we want"*. `dirread` is V10 syscall 22, the slot
      V8 fills with `sumount`.

- [x] **K12.1/K12.2 — the transport. DONE, 24/24** (2026-08-18, `tools/v10-tcpfs.sh`):
      V10 mounts a macOS folder over TCP and writes to it; a 209-byte file written by
      the guest lands byte-for-byte on APFS. One overlay patch did it —
      `lsys/os/streamio.c`'s `istread()` freeing a block whose tail the caller had
      not read — built into `os.a` by the new overlay-object step in K7. The QDELIM
      half was **retracted**: it hung the machine, and `tcp_device.c` leaves the flag
      clear on purpose. Original plan text follows.
- [ ] ~~**K12.1 — the transport.**~~ What is left after K12.0, and every input to it is
      already measured: the config carries `ni1010a 0 ub 0 reg 0764000 vec 0350`,
      the SIMH model is `libsimh/patches/pdp11_il.c`, and of the N track's four
      stream faults only three transfer (the hang is fixed; the 512-byte head, the
      short read and the discarded remainder are not). Start with **QBIGB** —
      `lsys/os/streamio.c` takes big transfers whole on a queue carrying that flag,
      which V8 had no equivalent of, and pushing it is cheaper to measure than
      patching a constant.
      **First two attempts: 7/15 then 9/15**, and the six named causes are written up
      in [v10-log/2026-08-18.md](v10-log/2026-08-18.md) — `ipc/internet` was on no
      manifest, `dipconfig` is the `ipconfig` that needs no `libcommon`, a header
      with no include guard named twice blamed Bell Labs for our bug, `lsys/lib/tab`
      fixes every major and `ld` index, and **the Interlan is 040 off the address
      the config compiles in**.

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

**Outcome (same day): `cc` alone reached 260 of 261**, so the numbers in the table above
are the *starting* measurement and not the current one. Reason 4 was the load-bearing
one — stage 3 is now a fixpoint, 7 of 7, which is precisely the statement that could not
have been made about the tape's mixture.

### The work, in dependency order

- [x] **B2.2a is HALF a header fix, and the other half is per-file.** Measured
      2026-08-17: `include/lcc/stdarg.h` is itself **K&R-compatible** —

	typedef char *va_list;
	#define va_start(list, start) ((void)(list = ...))
	#define va_arg(list, mode) __va_arg(list, mode, 3U)

      no prototypes, no `void *`, just casts and `sizeof`. So **`cc` can have
      `va_list` and the two-argument ANSI `va_start`** simply by reaching that
      header, which `iolib.h`'s V10 branch declines to include except `#ifdef sgi`.
      That is the enabling fact for B2.2c: the printf family can be converted to
      K&R *without* losing varargs and without falling back to `varargs.h`'s
      incompatible `va_alist`/`va_dcl` form.

      **But the header alone is not enough**, and it is worth being exact about
      why: the sources also carry ANSI *definitions* —
      `int printf(const char *fmt, ...){` — which pcc2 cannot parse whatever the
      header says. So each of the nine needs its parameter list rewritten
      old-style with the `...` dropped, keeping `va_start(args, fmt)` working off
      the last named parameter. Nine small, reviewable, per-file patches.
- [x] ~~**B2.2a-2 — fix `stdio/iolib.h`.**~~ **SUPERSEDED, not done** — the premise was
      wrong and the tape said so. The claim was that `iolib.h` has no branch for a V10
      VAX and therefore needs one. But `vfprintf.c` and `vfscanf.c` are the only two
      members of the family that carry `#include <stdarg.h>` **themselves** and the only
      two that build, so the missing line is a *per-file omission*, not a missing branch
      in the header. Fixed per file with `#include <lcc/stdarg.h>` (the r70 variant that
      is K&R-compatible), which leaves `iolib.h` byte-identical to the tape's — the more
      authentic outcome of the two. See `v10/src/PATCHES.md` under `libc/stdio/printf.c`.
- [x] **B2.2b — reconstruct `<shares.h>`.** Done, and verified against machine code
      rather than only against the manual: `man/manx/lnode.5` prints the struct field by
      field, and disassembling Bell Labs' own June 1989 `putshares.o`, `getshares.o`,
      `setlimits.o` and `openshares.o` confirms every offset, both sizes at five
      independent sites, and `MAXUID = 10000` twice. **Unblocked 5, not 6** — the
      ceiling is **260**: `setupshares` also needs `struct sh_consts` from
      `<sys/share.h>`, which is printed nowhere and referenced nowhere in either kernel
      tree, and `L_GETCOSTS` has the *kernel* write through that pointer, so a guessed
      size overwrites the caller's stack.
- [x] **B2.2c — K&R the remaining ANSI members.** Done, as named overlay patches. One
      correction to the recipe as written: `size_t` → **`unsigned int`**, not `int`, and
      `<stdarg.h>` → **`<lcc/stdarg.h>`**, not `<varargs.h>`. Three of the batch also
      needed a *system-layout* decision rather than a source edit — `stdlib.h`,
      `float.h` and `stdarg.h` installed at `/usr/include` from r70's `CC/` and `lcc/`
      variants, because r70 has all three but never at top level.
- [x] **B2.2d — delete `LIBC_LCC` and the second compiler.** Done; `LIBC_LCC = []`, so
      `libc.mk` uses `$(COMPILE)` for every member and there is one compiler by
      construction. Do **not** reinstate lcc to close a member: the prebuilt driver hits
      the `bowell.c` defect and emits empty objects while exiting 0, so a routed member
      becomes a silent hole rather than a member.
- [x] **B2.2e — re-measure, and keep the witness.** Done, and stage 2 now reports
      **38/38**: **260 of 261 build with `cc` alone** — more than the tape's own mixed toolchain managed (246) — with 148
      byte-identical to the tape, reported as information. The prediction that identity
      would *fall* was right and is recorded: 150 → 148 → 147 → **143** while the
      number that build went 246 → 249 → 252 → 260. The last step is not a further
      refactor: it is the first reading taken through an uncorrupted transcript, and
      the earlier three were inflated by a tty that dropped "differs" lines. The assertion is **260**, not 261: an assertion
      that can never pass is not an assertion, and `all 261 members compiled: NO` being
      permanently NO is exactly what let a *second* missing member (`atof.o`) hide behind
      it for a week.
- [x] **B2.2f — then stage 3.** Done, **33/33** (`tools/v10-stage3.sh`). All seven
      components — `yacc cpp ccom as c2 ld cc` — are byte-identical to the copy built by
      their own output, stripped with `ld -x -r` because V10 has no `strip`. The strong
      test measures 7 differ / 0 same, as predicted. Note two things the harness had to
      learn: the seal is option (a) (stage 2's `libc.a` installed over `/lib/libc.a` and
      asserted before anything is built, since V10's `cc` has no `-t a/l/c`), and the
      strip must be asserted **separately** from the comparison — `cmp` on a missing file
      reports as a difference, so a fixpoint that compared nothing read as a compiler
      that does not reproduce itself.

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
3. ~~V10 libc builds~~ — **done 2026-08-17**, `tools/v10-stage2.sh` 38/38: **260 of
   261 members**, 143 byte-identical to Bell Labs'. `setupshares` is a named
   exclusion, not a shortfall. The r70 header skew did bite, and the answer was a
   *system-layout* decision three times over (`shares.h`, `stdlib.h`, `float.h`,
   `stdarg.h` — picking which of the tape's four variants pcc2 can parse)
4. ~~Core userland builds~~ — **done 2026-08-18**, `tools/v10-link.sh` 35/35: of 358
   units, 251 compile and **203 link and install** into a staged root. `mux`'s host
   side is the exception and is discussed at rung 8
5. ~~`star` kernel links~~ — **done 2026-08-17**, `tools/v10-kernel.sh` 20/20, and it
   is our own `ipnx780.m` rather than a Bell Labs machine
6. ~~Boot block + filesystem image assemble~~ — **done 2026-08-19** (K14,
   `bash tools/v10-mkdisk.sh` **14/14**, exit 0). V10 made two filesystems on a
   blank RA81, filled them, halted, and **the disk it built came up to a login
   prompt** — with every byte of source arriving over TCP and no courier disk in
   the run. The host's own reading agrees and the geometry is Bell Labs': root
   1,280 blocks with a **19**-block i-list and `/usr` 30,752 with **473**, both
   identical to the golden's, and both free counts agreeing between `s_tfree` and a
   bit-by-bit count of the bitmap. The boot
   block is written host-side, `/unix` is copied first because
   `lsys/boot/README` requires it to be at most singly indirect, and the disk gets
   V10's own layout — root on `a` (1,280 blocks, which is what the golden's root
   is), swap on `b`, `/usr` on `c` — which needs no kernel patch where a whole-drive
   root needs one *and* swaps over its own data blocks. `ra_sizes[]` is in
   **sectors**, which cost a run. See
   [v10-log/2026-08-19.md](v10-log/2026-08-19.md)
7. ~~**Kernel reaches single-user on SIMH**~~ — **done 2026-08-17**, and it went
   straight past single-user to **multi-user with a login prompt** (K9,
   `tools/v10-boot780.sh app` 5/5, on the static library both app targets link)
8. Multi-user; `mux` from a dmd_core 5620 — **ANSWERED 2026-08-19, AND THE
   TERMINAL HALF IS IMPOSSIBLE FROM THE TAPE.** This rung was written on the
   assumption "protocol unchanged from V8", and that is half right in a way worth
   stating precisely:
   - **The terminal-side compiler is not on the tape.** `muxterm`'s own makefile
     names `CC = 3cc`, `AS = 3as`, `3ld`, `3nm`, and `src/man/man9/3cc.9` says what
     those are — *"the C compiler for the MAC-32 microprocessor in the Teletype
     DMD-5620 terminal"*. **The man page is the only one of the eight that
     survived**; the WE32100 `libj.a`/`liblayer.a`/`libsys`/`libc` it links are
     absent too, and `src/630`'s alternative route names a `src/dmdcc` that does
     not exist. Same shape as the 1989 libc compiler: documented, not shipped.
   - **There is no prebuilt fallback.** The V10 golden has no `/usr/jerq` at all
     (K10.2's harness creates it), and the tape's one prebuilt WE32100 `muxterm`
     is the **630's**, a different terminal from the 5620 `dmd_core` emulates.
   - **`mux` is not in V10's live source tree.** `src/cmd/` has no jerq/mux/5620
     directory; every `mux.c` is in `blit/` (68000), `src/630/` or
     `src/history/ix/` (the *Ninth* Edition's archive). On a real V10 the 5620
     software arrived as a separate distribution tape.
   - **The host half IS buildable** — `history/ix/src/jerq/mux/mux.c`, 1,144 lines
     of plain VAX C naming `$CC` not `3cc`, linking a seven-member `lib.a`.
   - **And the wire format differs by exactly one constant.** The packet header
     byte is identical (V10 replaced VAX bitfields with `P_seq`/`P_channel` masks
     that reproduce the same bits); `packets.h` differs only in `#else`/`#endif`
     annotations; `pconfig.h`'s difference is behind `#ifndef Blit` and muxterm
     compiles `-DBlit`. What changed is `MAXPKTDSIZE`, **64 → 124**, and the tape
     annotates it `/* was 64 */`. It is never negotiated — `precv.c:89` rejects an
     oversized packet — so matching is necessary and sufficient.
   - **BUT "BUILDING THE HOST AT 64 RESTORES THE TAPE'S OWN EARLIER VALUE" IS
     WITHDRAWN, and Bell Labs' own object is what withdraws it.** The annotation
     is a comment about the *source*; the tape also ships the *compiled* `lib.a`
     beside it, and `mux.o` declares `_buf` as a **common** symbol whose value —
     for a common, its size — is **124**. So the shipped artefact was built at
     124 and the annotation records a change made *before* 1989. 64 is a
     deviation for interoperability, not a restoration, and the authenticity rule
     permits one only when the tape cannot run as-is. It can.

   So the reachable result is V10's own host-side `mux`, built at the tape's own
   124, and a fully-authentic 5620 `muxterm` cannot be produced from what
   survived. Matching V8's `muxterm` at 64 is a *second*, separate decision,
   needed only when the two are actually wired together — and it needs V8's
   `muxterm` binary on the V10 disk as the download payload, since V10's golden
   has no `/usr/jerq/bin` at all.

   **K15 is the host half**: `bash tools/v10-mux.sh`, generated by `emit_mux()` in
   `v10/mk/mkdep.py`. Six headers install into `/usr/jerq/include` from
   `v10/mk/gen/mux.inc` — three COFF headers for `32ld.c` chosen from `630/3binc`
   on measured-identical layouts plus BELLMAC-32 provenance, and
   `sys/label.h`/`sys/pex.h`/`sys/jlabel.h` from the ix tree, which is the Ninth
   Edition's path convention rather than a gap in V10. Details and the two faults
   caught before a boot was spent: [v10-log/2026-08-19.md](v10-log/2026-08-19.md).
9. `sam`/`samterm` running — depends on rung 8, and on the same absent `3cc` for
   `samterm`, which is also a 5620 program
10. Reproducible `v10.disk` build script → merge into the app as "Edition 10" —
    K14 is its mechanism; what remains after it is choosing what to copy (K10.3's
    203 commands, K10.2's 26 libraries, stage 1's toolchain) and the Swift work
    for a second machine beside V8
