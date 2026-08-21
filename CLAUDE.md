# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A native iPad app that runs Research Unix (V8 first, V10 as the end goal) on an emulated
VAX — open-simh `vax780` — displayed through an emulated DMD 5620 terminal (`dmd_core`),
joined by a virtual serial line inside one iOS process. Full-system emulation is the load-
bearing decision: the Research Unix kernel forks processes inside the emulated machine, so
iOS's no-fork/no-JIT restrictions never apply, and both cores are plain AOT-compiled
interpreters (App Store-legal per UTM SE / iAltair precedent).

**Current state: Track A complete (A1–A3), on iPad *and* Mac.** `libsimh/` and
`libdmd/` package both emulator cores as xcframeworks (ios, ios-simulator,
macos slices); `app/` is the ipnx app, one source folder built by two targets:
V8 boots to `login:` in ~25–30 s with save/restore instant-on
([docs/a1-notes.md](docs/a1-notes.md)); the DMD 5620 runs as a Metal phosphor
screen — `mux` and `jim` work end-to-end on iPad
([docs/a2-notes.md](docs/a2-notes.md)); A3 added settings, media management,
licences, App Store prep and the macOS app ([docs/a3-notes.md](docs/a3-notes.md),
[docs/app-store.md](docs/app-store.md)). Next: **submission** (needs the Apple
account) and **Track B**. [RESEARCH.md](RESEARCH.md) is the evidence base for every
decision; trust it over memory, and record decision changes in the living docs, not by
rewriting the study.

## Commands

Track A commands (media prerequisites still come from the A0 workbench below —
`work/myv8/rp06v8.golden` + `bootV8` must exist before the app build embeds them):

```bash
# Build SimhVAX.xcframework (clones open-simh into work/ pinned to the verified rev)
libsimh/build-xcframework.sh
```

```bash
# Build DmdCore.xcframework (clones + patches canonical dmd_core, needs rust iOS targets)
libdmd/build-xcframework.sh
```

```bash
# Build the ipnx iPad app for the simulator
cd app && xcodebuild -project ipnx.xcodeproj -scheme ipnx -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

```bash
# Build the ipnx Mac app (same sources, second target)
cd app && xcodebuild -project ipnx.xcodeproj -scheme ipnxMac -destination 'platform=macOS,arch=arm64' build
```

```bash
# Desktop round-trip of the full app protocol against the library (boot → suspend/save → restore)
bash work/verify-libcli.sh
```

```bash
# Is the app you would launch RIGHT NOW the latest? (a Stop hook runs this)
tools/app-check.sh --full
```

```bash
# The network self-test, one command: builds netfsd, serves a share, drives
# the guest through TCP-to-host, TCP-to-the-Internet and DNS, cleans up
bash tools/net-selftest.sh rp07new
```

```bash
# How fast is the share, in FILES (the ruler that matters for netfs)
bash tools/netfs-latency.sh rp07new
```

Track B (V10). The tree is **not** in git — `v10/` holds only MANIFEST and
CASEMAP, and `work/v10/` is rebuilt from the TUHS tarballs:

```bash
# Unpack v10src + v10blit + r70include into work/v10/ (25,682 files)
tools/v10-import.py            # --verify re-checks every hash in ~15 s
```

```bash
# Does a 1995 V10 binary run on the 1985 V8 kernel?  (9 assertions)
bash tools/v10-probe.sh rp07new
```

```bash
# Assemble a V10 toolchain inside V8 and compile V10 programs with it
bash tools/v10-toolchain.sh rp07new     # ~6 min, 10 assertions
```

```bash
# Do the 17 programs the first boot needs compile?  Twice: V8 headers, then r70
bash tools/v10-bootpath.sh rp07new      # ~25 min, 46 assertions
```

```bash
# Which syscalls does a V10 program get wrong on a V8 kernel?  (host-side, 1 s)
tools/v10-syscalls.py --callers
```

```bash
# What is actually ON a V10 disk?  (host-side, no simulator, one second)
python3 tools/v10fs.py sum   work/v10gold/ipnx-v10-ra81.img:a   # a=root c=/usr
python3 tools/v10fs.py find  work/v10gold/ipnx-v10-made.img:c
python3 tools/v10fs.py prov  work/v10gold/ipnx-v10-ra81.img:a   # tape's vs ours
```

```bash
# Regenerate the V10 build metadata (all three have --check; all are host-side)
tools/v10-where.py        # install paths, from V10's manual + V8's measurements
tools/v10-overlay.py      # v10/src/ -- our corrections, derived from the tarball
v10/mk/mkdep.py           # v10/mk/gen/*.mk -- the makefiles V10 never had
```

```bash
# Do those makefiles actually build the boot path, under V8's make?
bash tools/v10-make.sh rp07new          # ~30 min, 29 assertions
```

**Run every guest harness against a CLONE, never the golden.** Booting a disk
mounts it, and mounting rewrites the superblock — so a clean, successful,
properly halted run still leaves the image with a different hash than the one
in git. That is what "golden drift" was. `cp -c` makes an APFS clone in no
time and no space.

**The rule now lives in `tools/v8clone.sh`, because stating it here was not
enough.** Three harnesses defaulted to booting `rp07new` — the golden —
directly: `net-selftest.sh`, `netfs-latency.sh` and `boot-newdisk.sh`, the
first of which claimed in its own header that "a pass leaves the disk exactly
as it found it". On 2026-08-16 one net-selftest run, made to check an unrelated
change, moved the golden from `8ccbf05614e8` to `396f994339f8`. **Nothing was
damaged and that is what made it dangerous** — the run halted cleanly, every
assertion passed, and the exit status was 0. Only `tools/app-check.sh` noticed,
which is exactly why `image/ipnx-v8-rp07.img.xz` is committed:

```bash
# put the golden back, in eight seconds, hash-checked
python3 tools/image-pack.py unpack
```

New harnesses source the helper and boot what it returns:

```bash
source "$ROOT/tools/v8clone.sh"
IMG=$(v8_clone "${1:-rp07new}" mytag) || exit 1
```

**AND TWO SIMULATORS MUST NEVER RUN AT ONCE — that is now a check, not a
habit** (`tools/norun.sh`, `tools/norun.exp`). On 2026-08-17 a stage-2 run and a
source-disk rebuild overlapped for the rebuild's last minute:
`tools/v10-srcdisk.sh` ends with `dd if=/dev/zero of=…/ipnx-v10-src.img` and
`v10-stage2.sh` had **that exact path attached, uncloned, as `rq1`**. The
srcdisk finished at 12:11:21 and the stage-2 log closed at 12:12.

**Both runs exited 0**, the srcdisk reported 36/36, and stage 2 reported a full
set of numbers — a member list, a DIFF list, four compiler trials — every one of
them measured against an image that changed mid-run. The only evidence was two
mtimes fifty-one seconds apart. Each harness's own guard was blind to the other
because they run **different binaries**: stage 2 checked `pgrep -f BIN/vax750`
and the srcdisk builder boots a `vax780`. So the guard asks about every
simulator name, and asks a second question the first cannot answer — *is
anything holding this file?* (the 2026 overlap's writer was a `dd`). It is
called from `v8_boot`/`v10_boot`, at the instant of `spawn`, which is the one
choke point all twenty-nine harnesses already share.

**A run finishing in seconds is not evidence that it did nothing.** The
"ten-second build" of 261 objects was taken for a skipped build, and that was
wrong: a whole stage-2 run — boot, 260 compiles, archive, ranlib, 261 `cmp`s,
four whole-library compiler trials, install, link, halt — takes about **seventy
seconds of host time**. A real 11/750 was half a MIPS and open-simh on an
M-series Mac is two orders of magnitude quicker, so a tenth of a second per
small C file is right, and the *guest's* clock under-reports besides. The
evidence against the wrong reading was in the same output: 150 members came out
byte-identical to Bell Labs' 1989 archive, which no skipped build can do.
Iterate freely — these runs are cheap.

The **Phase A0 desktop spike** commands are in [docs/spike-a0.md](docs/spike-a0.md)
(build SIMH `vax780`, produce `v8.disk` via timnewsham/myv8, connect a 5620/Blit terminal
emulator, run `mux`), all inside the gitignored `work/` directory.

The A0 workbench ran on a local **SIMH 3.12** build at `work/simh312/`, which was
deleted in the 2026-08-12 cleanup. `work/boot-hold.exp` and `work/dztalk.py` survive
but **must not simply be repointed at `work/opensimh/BIN/vax780`**: that build has
async I/O compiled in and `boot-hold.exp` predates the rule, so it opens without
`set noasynch` and walks into the corruption trap documented below
(`hp06: hard error er1=5<RMR,ILF>` and silent file loss). The current equivalents,
which do set it, are:

```bash
# Boot an image alone and check it end to end (13 assertions, then a clean halt)
IMG=rp07new tools/boot-newdisk.sh
```

```bash
# Content-only verification of the built disk, no VAX required (about a second)
tools/verify-golden.sh
```

**What in `work/` is load-bearing**, since the rest is scratch and was cleaned out:
`rp07new` (the built golden — the RP06 variant `rp06new` holds the *same system* in
a different container and nothing consumes it, so it is not kept; one stage-8 run
rebuilds it, `tools/drive-stages48.sh "" "" 8 8 rp07new rp06`), `rp06build` (stages 1–3 —
`drive-stages48.sh` refuses to start without it and rebuilding costs ~50 min),
`rp07v8.net` (the build machine itself, plus `.net.bak`, its only rollback),
`rp06v8.golden` (the TUHS reference — still the default `--tuhs` for
`retire-check.py`, `compare-built.py` and `verify-golden.sh`), the `*.tap.gz`
archives and `work/v8.tar`/`v8jerq.tar` (what `v8-import.py --verify` reads).
Tools for finished phases still name images that are gone — `drive-widemux.sh`
wants `rp06v8.wide`, `rp07mig.sh` wants `rp06v8.mig`, `n3-ilkernel.sh` wants
`rp07v8.golden`, `idle-probe.py` wants `idle-probe.disk`. Each fails with a plain
"no such file"; their outputs are all committed, so recreate the image only if you
genuinely need to re-run that experiment.

Toolchains:
- App shell (real since A1): Swift/SwiftUI, `app/ipnx.xcodeproj` — hand-authored,
  synchronized-folder format. **Code signing: always the Hello Tham Pty. Ltd. org team —
  `DEVELOPMENT_TEAM = RPL5R637DS` — never the personal team** (set at creation, verified
  2026-08-09). Two targets (`ipnx` iPad, `ipnxMac`) share the one `app/ipnx/`
  folder; platform differences go behind `#if os(macOS)` and the
  `PlatformViewRepresentable` shim in `Platform.swift`, never a forked file.
  Everything was named **Edition** until 2026-08-10 — project, targets, schemes,
  folder, `EditionApp` — and is now `ipnx`/`ipnxMac`/`IpnxApp`. The product was
  always `ipnx.app`; only the scaffolding lagged.
- VAX core (real since A1): open-simh as a C static library — `libsimh/` (CMake →
  xcframework; scp's `main` renamed via `-Dmain` only; no async/network/SDL).
- Terminal core (real since A2): dmd_core as a Rust `aarch64-apple-ios` staticlib via
  its **built-in** C FFI — `libdmd/` (never wrap it in another crate: the unmangled
  exports collide; extend via logged patch, e.g. the A2 BREAK exports). Both
  xcframeworks' Swift modules are declared in `app/ipnx/Modules/module.modulemap` —
  two frameworks cannot each bundle a modulemap (flat `include/` collision).

## Architecture (the big picture)

Two interpreters and a wire, mirroring the real 1985 topology (smart terminal ↔ serial line
↔ headless host):

- **SIMH thread** boots the disk image; its DZ11 line 0 is the wire's host end
  (`set noasync` mandatory).
- **dmd thread** runs the WE32100 terminal; its DUART port A is the wire's other end;
  its 800×1024×1 framebuffer is what the user sees.
- **Serial transport** is a localhost telnet loopback (zero-patch, proven shape). An
  in-process byte queue was planned but proved unnecessary: the throttles were the DUART
  divisor and SIMH's guest-speed-controlled DZ, both raised by config/patch, so the
  transport was never the bottleneck. `mux` downloads in ~15 s.
- The shell is **edition-agnostic**: machines = SIMH simulator + disk image + wiring. V10
  arrives later as just another image (Track B builds it *inside* the running V8 — V10 has
  never been booted by anyone; that restoration is half the project).

Full spec: [docs/architecture.md](docs/architecture.md) · Phases:
[docs/roadmap.md](docs/roadmap.md) · V10 plan: [docs/v10-restoration.md](docs/v10-restoration.md)

## Decisions (settled — don't relitigate without new evidence)

- Full-system emulation, native code. **Not** WASM, **not** iSH-style user-mode.
- End goal is V10, staged through V8. **V9 is skipped** (surviving V9 = Sun-3 port, no VAX
  kernel code).
- **V10 WAS NEVER BUILT FROM SCRATCH, and that is the single most useful thing to know
  about Track B.** It accreted over years of patching, so there is no coherent "the V10
  toolchain" — the requirement is **per file, mixed, and undocumented**. Measured, not
  inferred: the `libc/mkfile` that produced the shipped `libc.a` names `cc` for members
  only `lcc` can compile, 25 of its 261 members are ANSI, and the tree carries **two
  generations of stdio at the same time** (K&R `doprnt.c`/`doscan.c`, which `omakefile`
  builds, and ANSI `_dtoa`/`vfprintf`/`snprintf`, which the archive contains).
  **Consequence: no makefile on the tape is a reliable guide to which compiler a file
  needs.** Expect this again and expect it to look like a defect in our build — `cfront`
  is the next likely one. When a source fails on `syntax error` at a prototype, the
  answer is usually "this file was an lcc file", not "our compiler is wrong". Both
  compilers are Bell Labs' own 1995 binaries on the tape, so using either is faithful:
  `lcc` = `cmd/lcc/etc/lcc` + `gen2/vax-v9/rcc` + `ph/cpp` (installed as
  `/usr/bin/lcc`, `/usr/lib/rcc`, `/usr/lib/gcc-cpp` — the driver's compiled-in paths;
  there is no `gcc-cpp` in the tree, so lcc's own cpp stands in). Proven running on
  our machine by `tools/v10-stage2.sh`.
- **THE PREBUILT lcc SILENTLY PRODUCES EMPTY OBJECTS, and it exits 0 doing it.**
  `cmd/lcc/etc/lcc` is compiled from `bowell.c`, whose cpp line is
  `{"/usr/lib/gcc-cpp", "-undef", "-Dvax", "-DV9", …}`. There is no `gcc-cpp` in
  the tree, so lcc's own `ph/cpp` has to stand in — and it **rejects `-undef`**:

	/usr/lib/gcc-cpp: illegal option -- u
	0: warning: empty input file

  cpp writes nothing, `rcc` compiles the empty file, `as` assembles it into a
  valid empty `.o`, and **lcc exits 0**. So a probe asserting "lcc compiled it"
  and "an object appeared" passes on nothing — both of mine did, and stage 2
  reported all 261 members built while 26 of them were empty. *An object file
  is not evidence that a compiler ran; `test -s` cannot tell an empty a.out
  from a real one.* Compare against the tape, or check the text size.
  **The fix is `etc/realvax.c`**, whose cpp line is `{"…/cpp", "-N",
  "-D__STDC__=1", "-Dvax", …}` with no `-undef` — exactly what `ph/cpp`
  accepts. Both `lcc.c` (563 lines) and `realvax.c` are pure K&R — no
  prototypes, no `void *`, no `stdarg` — so **pcc2 can build the driver from
  source**, which is the honest fix rather than patching a binary's string
  table.
- **THE TAPE'S `libc.a` IS NOT A BUILD PRODUCT, SO IT IS NOT AN ORACLE FOR BYTES.**
  Christine's reading, and the archive's own `ar` headers prove it outright — a clean
  build dates every member within minutes of itself, and this one spans **4.1 years
  across 27 distinct days**:

	1989-06   199 members      <- one build
	1989-08 … 1993-07   62 members, in ones and twos across 26 more days

  So it is a June 1989 archive with four years of piecemeal `ar r` on top: someone's
  working tree, not a system that was built. Exactly the reading CLAUDE.md already
  applies to the 46 prebuilt command binaries — *"what survived is whatever was last
  compiled in place"* — and it applies here too.
  **The consequence is measured, not inferred:**

	C members from June 1989   105, of which 90 differ from ours   (86%)
	C members recompiled later  59, of which 19 differ             (32%)

  The members we CANNOT reproduce are the **old** ones. Our compiler is stage 1's,
  built from the tape's *1995* `cmd/ccom/vax/` source, so it resembles the late
  compiler and not the 1989 one — **and the 1989 compiler is not on the tape**. All 97
  assembly members match (`as` is stable across the whole span); the differences are
  entirely in C compiled by a compiler that no longer exists.
  - **Therefore a byte-perfect `libc.a` is impossible, and chasing one is chasing a
    ghost.** Ruled out by measurement, not by giving up: neither stage 1's `ccom`, nor
    the tape's own prebuilt `comp`, nor `cc` without `-O`, nor `lcc` reproduces those 90
    — because none of them is the compiler that did.
  - **What the archive IS still good for**: a per-member witness. `atof.o` (dated
    1991-12-19) matches `lcc` and nothing else, which is how we know the tree really
    was mid-migration between compilers.
  - **The 1989 members are most likely NINTH EDITION** (Christine), and the tooling
    corroborates it rather than only the dates. lcc's VAX back end on that machine is
    `cmd/lcc/gen2/`**`vax-v9`**`/rcc`, and the prebuilt driver's own cpp line —
    `bowell.c`, compiled into `etc/lcc` — passes **`-DV9`**, while libc's `mkfile`
    passes `-DV10`. So the archive is a V9 libc being migrated to V10 one member at a
    time, and the compiler that built the June 1989 bulk was V9's. **We have no V9 VAX
    source at all** (the surviving V9 is the Sun-3 port — see Decisions), so those
    objects are unreproducible in principle and not merely in practice. `-DV9` in a
    V10 tree is the kind of detail that looks like noise until it is the answer.
  - So the goal becomes the best archive we can build **from a single compiler**, and
    the tape's own mixture is evidence of an unfinished port rather than a design to
    reproduce. See `tools/v10-stage2.sh`, which reports the breakdown every run.
- **The printf/scanf family cannot compile under EITHER compiler, and `iolib.h` says
  why.** `stdio/iolib.h` is a three-way `#ifdef` and none of its branches fits a V10
  VAX:

	#ifdef V10
	    #ifdef sgi
	    #include <stdarg.h>        <- only when `sgi' is ALSO defined
	    #else
	    #define _IOREAD 01 ...     <- no stdarg, so va_list is undeclared
	#else
	    #define _POSIX_SOURCE      <- pANS branch; wants <stdlib.h>, <unistd.h>
	    ...

  libc's `mkfile` passes `-DV10`, which selects the branch that declares `va_list`
  only on an SGI — so `printf.c`'s `va_list args;` fails as `syntax error; found
  'args' expecting ';'` under lcc and as a bare syntax error under pcc2. It is not a
  compiler problem and not an include-path problem: the header supports *V10 without
  stdarg*, *pANS with stdarg* and *SGI*, and not *V10 with stdarg on a VAX*. That is
  the unfinished V9→V10 port in miniature, and the fix is a named one-line patch in
  `v10/src/` (the `mv.c`/`fsck.c` model), not a `-Dsgi` on a VAX.
- **ONE COMPILER BUILDS 249 OF 261 — more than the tape's own mixture. This
  RETIRES "neither compiler can build libc alone".** That claim was true of the
  tape as it stands and was read as a property of the tree, which it is not: 14
  of the 15 failures were repairable, and the repairs are a named overlay plus
  two makefile lines. Measured, all four configurations run:

	cc + lcc, the tape's mixture     246 of 261
	lcc alone                        202 of 261
	cc + lcc, with the repairs       260 of 261
	cc alone, after B2.2b/c          249 of 261
	cc ALONE, EVERY conversion done    260 of 261  <- THE CEILING

  `LIBC_LCC` is now **empty**, so there is no per-member compiler choice left to
  get wrong. **Do not reinstate lcc to close a member** — it still hits the
  `bowell.c` defect (`0: unknown flag -undef`), so those members become **empty
  objects that exit 0**. A loud failure beats a silent hole.
  - **"THE CEILING IS REACHED, `setupshares` IS THE ONLY FAILURE" WAS WRONG BY
    ONE, AND THE RUN THAT SAID SO WAS RIGHT.** `atof.o` was missing too, so the
    measured figure was **259**. The claim survived because the host-side
    counter in `tools/v10-stage2.sh` dropped the line — see the splice gotcha —
    while the guest's own `all 261 members compiled: NO` sat four lines above
    it in the same log. **Stage 3 is what finally reported it**, as `ccom` and
    `as` failing to link with `Undefined: _atof`, which is what an absent libc
    member looks like two stages downstream.
  - **One compile error accounted for three separate stage-2 failures**, two of
    which were being carried as open questions in their own right:
    `all 261 members compiled` (the prototype), `member list and order match
    the tape` (the member is absent from the archive) and `install`
    (`make install` retries the missing object and dies on the same line). The
    standing hypothesis that `install` failed on a `-mkdir` V10's make did not
    honour was **false** — it honours the dash exactly as documented
    (`*** Error code 1(ignored)`) and install never reached the mkdir. *When
    several assertions fail together, look for one cause before theorising
    three.*
- **THE 1993 MEMBERS ARE ADDRESSED TO A HEADER SET THAT IS NOT INSTALLED, which
  is the two-generations split one layer below stdio.** The eleven `lcc`-only
  members carry `/* Copyright AT&T Bell Laboratories, 1993 */` and want
  `<stddef.h>`, `<stdlib.h>` and `size_t` — and r70's `/usr/include` has none of
  the three at top level; they exist only under `include/lcc/` and
  `include/CC/`. So these are not files with a prototype to strip, they are
  files written in a different C. Converting one means `void *` → `char *` and
  `size_t` → `unsigned int`, which changes no generated code (same widths on a
  VAX, and it is how V8's own libc declares these functions).
- **`-DV10` IS MISSING FROM THE TAPE'S OWN `cc` RULE, AND EVERYTHING DOWNSTREAM
  LOOKS LIKE A DIFFERENT BUG.** `libc/mkfile` line 123 is the default C recipe —
  `cc -O -c $prereq`, no `-D`, no `-I` — while line 69 gives lcc
  `LCCARGS = … -DV10`. So `-DV10` *is* this tree's answer and simply never
  reached the cc rule. Without it every `#ifdef V10` block is skipped, and the
  two symptoms point away from the cause: `stdio/iolib.h` takes its pANS `#else`
  branch and dies on `Can't find include file stdlib.h` (r70 has no top-level
  `stdlib.h` or `unistd.h`, so that branch cannot be the intended one), and
  `sprintf.c`'s hand-built `FILE _strbuf` is replaced by a call to `sopenw()`,
  which does not exist. It belongs in **our** makefile, not in a source patch:
  V10 never had these makefiles.
- **`<shares.h>` AND `<sys/lnode.h>` ARE RECONSTRUCTIBLE, AND FIVE OF THE SIX
  MEMBERS BUILD.** "Six members cannot be built by anything" treated the
  *source tree* as the only evidence. **The tape also carries its own manual**,
  and `man/manx/lnode.5` reproduces the header field by field under the words
  *"The layout as given in the include file is:"* — `struct lnode`, the five
  `l_flags` bits, `typedef short uid_t`, `struct kern_lnode` — while `limits(2)`
  tabulates the twelve `L_*` numbers and `shares(5)` gives both installed paths.
  Then **checked against machine code**, because a manual can drift and an
  object cannot; disassembling Bell Labs' own June 1989 members:

	putshares.o   subl2 $20,sp   cmpw (r11),$10000   movc3 $16,(r11),(r0)
	getshares.o   clrw 2/4/6(r11)   movf …,8(r11)   movf …,12(r11)
	setlimits.o   subl2 $16,sp   tstw 6(r11)   pushl $3      (= L_SETLIM)
	openshares.o  its only string constant is "/etc/shares"

  Every field lands where `lnode(5)` says, both sizes agree at five independent
  sites, `MAXUID = 10000` appears twice. **`setupshares.o` is the only real
  casualty** — it also needs `struct sh_consts` from `<sys/share.h>`, which is
  printed nowhere and referenced nowhere in *either* kernel tree, and
  `L_GETCOSTS` has the **kernel** write through that pointer, so a guessed size
  overwrites the caller's stack. The ceiling from source is **260, not 255**.
  Two traps met on the way: the header needs `<sys/types.h>` for `u_short`
  (`"sys/lnode.h":22:syntax error / saw NAME` — line 22 is `u_short l_flags`,
  *not* the `uid_t` line above it), and it goes in `shares.h` because that is
  the include order the tape shows (`lsys/os/limits.C` reaches `lnode.h` only
  after `sys/param.h`, and `setlimits.c` includes `<shares.h>` and nothing
  else).
- **A SHIPPED `v10.disk` CARRIES WHAT V10 BUILT, AND THE TAPE'S BINARIES ONLY
  WHERE WE CANNOT BUILD THE PROGRAM** (decision 2026-08-21, rung 10). The
  instinct is the reverse — keep Bell Labs' binary wherever one exists — and
  this file rules it out in its own words: the 46 prebuilt commands are
  *"developers' working directories, so what survived is whatever was last
  compiled in place"*, and they are *"an ORACLE, not a shortcut … use the 46 to
  check what we build, never to skip building it"*. **Build detritus is not a
  specification; the source is**, and K10.3's 203 commands were built from it by
  V10's own compiler. Stage 2 settled the identical question the identical way,
  by building libc rather than shipping the tape's archive and accepting a
  *falling* byte-identical count as progress. So the 40 prebuilt commands we
  cannot build — `2500 adb bcp picasso lcc lex …` — keep Bell Labs' bytes
  exactly where they are, because nothing overlays them. Our build where we have
  one, theirs where we do not.
  - Measured before deciding, host-side: of K10.3's 203 staged files, **50
    collide** with a path the builder already has and **153 are new**. Of the
    50, nineteen are the tape's own bytes and thirty-one are ours already — and
    **nine of ten sampled collisions have byte-identical text+data**, differing
    only by twelve bytes of symbol table (one entry, the source path). So the
    build is deterministic in generated code and "which build wins" is a real
    question for almost none of them. The exception is `/etc/login`, genuinely
    smaller in K10.3's build (text 22528 → 20480), which is the documented
    Share-scheduler removal.
- **V10 MUST STAY AUTHENTIC. This outranks convenience, tidiness and our own
  taste** (Christine, 2026-08-17). V10 is a restoration: the artefact is worth
  something because it is what Bell Labs left, not because it is what we would
  have written. Three working rules follow, and they decide real questions:
  - **The tape is the specification, including where it is untidy.** Its mixed
    per-file cc/lcc toolchain, its two generations of stdio, its makefiles that
    name the wrong compiler — all of that is restored, not corrected.
  - **A deviation is allowed only when the tape cannot run as-is, and then it is
    a NAMED patch with a stated reason** — `v10/src/` plus `v10/src/PATCHES.md`,
    never an edit in place, so `v10/MANIFEST` keeps meaning what it says. `mv.c`
    and `fsck.c` are the model: one line each, both recorded.
  - **Where the tape's own artefacts can settle a question, they do.** Member
    order comes out of `libc.a` rather than from `lorder | tsort`; and when our
    bytes differ from the tape's, the tape's bytes are the authority — which is
    what makes the which-compiler oracle in `tools/v10-stage2.sh` an
    authenticity test and not a curiosity.

  Tidying belongs to V11, which is a new edition and may do as it likes.
- **THE MESS STAYS IN V10; V11 STANDARDISES THE COMPILER** (decision 2026-08-17,
  Christine, superseding the same day's "V11 uses the Plan 9 compiler" — see Track D
  in [docs/roadmap.md](docs/roadmap.md)). V10 is a *restoration*, and its mixed
  per-file cc/lcc toolchain is part of what is being restored — so the build follows
  the tape wherever it leads and does not tidy it. `v10/mk/mkdep.py`'s `LIBC_LCC` is
  that policy made explicit: a measured list of which members need which compiler,
  carried as data. **V11** is where there is one language and one compiler, so the
  per-file question is ended rather than managed. Which compiler is V11's decision,
  not V10's.
- **THE 5620's COMPILER IS NOT ON THE TAPE, SO A FULLY-AUTHENTIC `muxterm`
  CANNOT BE BUILT — and the tape says so in four places.** This settles rung 8,
  which was carried for weeks as "an authenticity decision" when it is a
  measurement. `src/history/ix/src/jerq/mux/term/makefile` — `muxterm`'s own
  build — names `CC = 3cc`, `AS = 3as`, `3ld`, `3nm`; and
  `src/man/man9/3cc.9` says what those are, verbatim: *"3cc is the C compiler for
  the MAC-32 microprocessor in the Teletype DMD-5620 terminal"*, heading a family
  of eight (`3cc 3as 3ar 3ld 3nm 3size 3strip cprs`). **The man page is the only
  one of the eight that survived** — no binary, no source, searched by name across
  all 25,682 files and by every makefile that references them. The WE32100
  `libj.a`/`liblayer.a`/`libsys`/`libc` on that link line are absent too, and the
  second route fails one layer up: `src/630/makefile` line 67 is
  `DMDCC=src/dmdcc`, a prerequisite of its own `all` target, and
  `src/630/src/dmdcc` does not exist. Same shape as the 1989 libc compiler —
  documented, not shipped.
  - **There is no prebuilt fallback on the V10 side.** The golden has **no
    `/usr/jerq` at all** (K10.2's transcript shows the harness creating it), so
    unlike V8 there is no `muxterm`, no `jim`, no 5620 userland on the disk. The
    tape's one prebuilt WE32100 `muxterm` is `src/630/src/muxterm` — COFF
    `f_magic` **0560**, 218,450 bytes — and it is the **630 MTG's**, a different
    terminal from the 5620 `dmd_core` emulates. (`blit/lib/muxterm` is magic
    **0407**, the 68000 Blit's; `blit/Road.map` states the naming trap itself:
    *"programs to run the Blit, the 256Kbyte 68000-based research terminal.
    /usr/jerq has the DMD-5620 code"*.)
  - **`mux` IS NOT IN V10's LIVE SOURCE TREE**, which reframes the rung rather
    than merely blocking it. `src/cmd/` has no jerq, mux, blit, 5620 or dmd
    directory; every `mux.c` on the tape is in `blit/src/mux/` (68000),
    `src/630/src/` or `src/history/ix/src/jerq/` — and **`ix` is the NINTH
    edition**. On a real V10 the 5620 software arrived as a separate 5620
    distribution tape installed into `/usr/jerq`, which is exactly what V8's
    golden has and V10's has not.
  - **The host half IS buildable**: `history/ix/src/jerq/mux/mux.c`, 1,144 lines
    of plain VAX C naming `$CC` not `3cc`, linking a seven-member `lib.a`, with
    every include present.
  - **AND THE WIRE FORMAT DIFFERS BY EXACTLY ONE CONSTANT**, which is a `diff`
    rather than a judgement because both trees carry the protocol headers.
    `packets.h` differs only in trailing annotations on `#else`/`#endif`;
    `pconfig.h`'s difference is behind `#ifndef Blit` and muxterm compiles
    `-DBlit`; and `proto.h` replaced VAX bitfields with masks that reproduce **the
    same byte** — `P_seq(b) = b & (SEQMOD-1)` is bits 0–1, `P_channel(b) =
    (b>>SBITS) & (MAXPCHAN-1)` is 2–5, `P_CNTL 0x40` is bit 6, `P_PTYPE 0x80` is
    bit 7, matching V8's `seq:2, channel:4, cntl:1, ptyp:1` exactly. What changed
    is `MAXPKTDSIZE`, **64 → 124**, and the tape annotates it `/* was 64 */`. It
    is **never negotiated** — `proto.h` sizes the receive buffer statically and
    `precv.c:89` *rejects* an oversized packet — so a 124-byte host against a
    64-byte terminal fails cleanly rather than corrupting, and matching is
    necessary and sufficient.
    - **"BUILDING IT AT 64 RESTORES THE TAPE'S OWN EARLIER VALUE" WAS WRONG, AND
      BELL LABS' OWN OBJECT SAYS SO.** That claim stood here on the strength of
      the `/* was 64 */` annotation, which is a comment about the *source*. The
      tape also ships the *compiled* `lib.a` beside it, and `mux.o` declares
      `_buf` as a **common** symbol — where the symbol's value **is** its size:

	124  _buf         (`char buf[MAXPKTDSIZE]`, mux.c:57)
	132  _precvpkt    (`struct Pktstate` = Packet 128 + state + timo)

      So the shipped artefact was built at **124**, and the annotation records a
      change made *before* 1989. Building at 64 is therefore a **deviation for
      interoperability**, not a restoration — and the authenticity rule allows a
      deviation only when the tape cannot run as-is, which here it can. K15 builds
      124 and asserts it through `sizeof(struct Packet) == 128`; 64 remains a
      separate decision, needed only when V10's `mux` is actually pointed at V8's
      `muxterm`. *A comment in a header is evidence about intent; an object is
      evidence about what ran.*
  - So the reachable result is V10's own host-side `mux` driving the 5620
    `muxterm` this project already builds and widens, with one measured constant
    matched. Rung 9 (`sam`/`samterm`) inherits all of this, because `samterm` is
    a 5620 program too.
- **PLAN 9 DID TARGET THE VAX-11/750 — and it is the same machine we emulate.** From
  the Plan 9 wiki's [Other hardware](https://9p.io/wiki/plan9/Other_hardware/index.html)
  page, verbatim:

	Vax 750 - The earliest file server port.  The compiler binary was
	recently found but the source appears to have been lost in the mists
	of time.

  **This corrects a claim that stood in this file and in the roadmap**: "Plan 9 never
  had a VAX back end" is false. The *released* editions dropped it, which is why
  neither [Plan 9 C Compilers](https://9p.io/sys/doc/compiler.html) (`v` MIPS, `k`
  SPARC, `8` i386, `2` 68020, `x` AT&T 3210, `9` i960, `z` Hobbit) nor
  [The Various Ports](https://9p.io/sys/doc/port.html) mentions it — absence from the
  released suite is not absence from history, and two primary sources agreeing on a
  negative did not make it true. Christine had the fact; the papers did not.
  - **The constraint that survives is provenance, not existence.** A recovered
    *binary* with no source cannot be the standard compiler of an edition this project
    builds from source — that is the whole argument of stages 1–3. It can be an
    excellent **oracle**, exactly as V10's own prebuilt `ccom` and `as` are.
  - So the open questions are now concrete: does that binary survive anywhere
    fetchable, and what does it accept? Until then, `lcc` remains the only ANSI VAX
    compiler we actually hold, and it **is** buildable from source — front end
    `cmd/lcc/c/` (18 sources matching `gen3`'s objects), VAX back end `gen3/gen.c` plus
    `gen2/vax/`, preprocessor `cmd/lcc/ph/`.
  - There is still **no Plan 9 C compiler in the V10 tarball** (no `1c`/`2c`/`5c`/`8c`/
    `vc`/`kc`/`qc`, by directory and by grep); the Plan 9 lineage on the tape is
    `cmd/u9fs` (9P) and `cmd/mk`.
- Free app, self-contained, no ads/IAP — required by the 2017 non-commercial covenant;
  **"UNIX" must not appear in the app name** (Open Group trademark) — the app is
  **ipnx** ("iPad is not Unix"; the name itself carries no mark). Binding rules:
  [docs/licensing.md](docs/licensing.md).

## The one rule that outranks everything else

**NEVER LEAVE A MACHINE INCONSISTENT. A machine that was not cleanly halted has
a corrupted disk — assume it, do not hope otherwise.**

The only correct way to stop a running guest is a clean halt:

```
cd /; sync; sync        # userland flush
/etc/halt               # RB_HALT: boot() calls update(), waits for the I/O,
                        # then spins at IPL 31 -- SIMH reports "Infinite loop"
```

Wait for that marker, *then* `quit`. Never `pkill` a `vax780`, never kill the
app, never quit an emulator with the guest still running, and never delete a
`state.sav` while keeping the disk it belongs to (snapshot and disk are
consistent only as a **pair** — keep both or discard both).

**`fsck` is not a recovery tool.** It restores metadata *consistency* so the
filesystem will mount; it does not restore *data*. Blocks that were in core and
never written are gone, and several of its repairs destroy data by design —
truncating a file to a provable length, clearing an unreconcilable inode,
dumping a directory into `lost+found` under numeric names. A clean `fsck` pass
is not evidence that anything survived. Real data loss from unhalted Research
Unix machines is well attested; treat every uncleanly-stopped disk as damaged
until a **hash against a known-good artefact** says otherwise. That is proof;
"it booted fine" is not.

If a disk must be recovered, **copy the damaged image first**. `fsck` gets one
attempt at the original and its repairs cannot be undone.

This is why `image/ipnx-v8-rp07.img.xz` is in git: it turns "is this disk
intact?" into a three-second `shasum` instead of a judgement call.

## The app must always be the latest, and that is checked

**"It is in the golden, it will arrive on Reset" is not shipping it.** The app
copies its system image into Application Support on first launch and then used
that working copy forever, so a rebuilt golden reached the bundle and stopped
there: `/etc/motd`, `/etc/copyright` and `/usr/inet/lib/services` were all
correct in the repo, on the disk, and absent from the running machine. Nothing
failed. Every test passed. The tests were not looking at the artefact the user
opens.

The working copy diverges from the golden the moment the guest writes to it, so
it cannot be recognised by hashing its own content — it needs a record of its
ORIGIN. The `Embed V8 media` build phase writes `v8.disk.id` (the golden's
sha256) beside the image; `Machine.provision()` compares it with `image.id` in
the support directory and **replaces the working disk, the snapshot and the
provisioning markers whenever they differ**. No prompt, no Reset: an app update
is not a user decision. Reset stays user-initiated and is a different thing.

`tools/app-check.sh` asserts the whole chain — no stray simulators, golden
present and matching the committed image, every built bundle carrying that
golden, and no source newer than the binary — and `tools/hook-app-current.sh`
runs it as a **Stop hook**, so the work cannot be reported finished while the
app is stale. Prove the gate still bites (`touch app/ipnx/Machine.swift`) before
trusting a pass; a check that cannot fail is not a check.

Machine state lives at `~/Library/Application Support/ipnx/v8` — app first,
edition inside, because V10 will be a second machine beside this one. Anything
at the old flat `v8/` is moved on first launch, never abandoned.

## Gotchas (each cost the community real debugging time)

- Naming trap: in Research tapes, `jerq/` = DMD 5620 (WE32100); `blit/` = original 68000
  Blit. The "current" V8/V10 terminal is the 5620.
- dmd_core must run firmware **8;7;3** for Research Unix `mux` (default 8;7;5 fails).
- SIMH newer than 3.9 needs `set noasync` or V8 corrupts RP06 I/O (simh issue #425).
- V8's getty sends the first `login:` with **mark parity** (bit 7 set) — byte-matchers must
  strip the high bit until after login.
- `mux` is not on root's PATH in a *stock* V8 — invoke `/usr/jerq/bin/mux` (same for
  `jim`). The shipped golden image no longer has this problem: `work/fix-identity.exp`
  gives root a `/.profile` with `/usr/games` and `/usr/jerq/bin` on PATH, `TERM=dmd`
  (V8 ships **no** `/.profile`, `/.login` or `/etc/profile` at all, which is why `vi`
  used to die — `TERM` was simply unset), `kill ^U` and `intr ^C`. Leave `erase` at
  V8's own **^H**: the app maps a Mac/iPad Delete key to 0x08, so ^H is what that key
  sends. The machine's name is `/etc/whoami` and nowhere else — V8 has no
  `hostname(1)`, no `uname(1)`, and `/etc/rc` never sets one.
- mux's B3 menu pops centered on the cursor: park the cursor mid-screen first or the
  menu clips at the screen edge and the selection is lost. After selecting New, the
  sweep-corner cursor is the confirmation that the B3 sweep is armed.
- **Idling needs `set cpu idle=4.1BSD` *and* three `UNIT_IDLE` flags upstream forgot**
  (`libsimh/patches/apply.sh`). `sim_idle()` sleeps only when the unit at the *head* of
  the event queue has `UNIT_IDLE`, so one periodic unit without it pins a core: the
  telnet-console poll unit (1 s), `clk_unit`/TODR and `tmr_unit`/TMR (10 ms each). Fix
  them together — unblocking one only promotes the next to the head. Stock `vax780`
  burns ~97% of a core at an idle `login:`; patched, the app's SIMH thread sits at
  **2.7%**, with V8's clock still exact (90 guest seconds per 90.1 host seconds). The
  flags survive `save`/`restore` because `UNIT_IDLE` is not in `UNIT_RFLAGS`, but
  `cpu_idle_mask` does *not*, so `resume.conf` must re-issue `set cpu idle=`.
  Diagnose with `tools/idle-probe.py --why`, which histograms `sim_idle()`'s own
  "Can't idle: <unit>" messages; measure the app with `tools/app-cpu.sh`.
- The **dmd (5620) thread does not idle at all** and is now the app's whole CPU cost
  (63.5% at the default 2× = 20 MHz; dmd_core tops out near 28.5 MHz on an M-series
  Mac). `libdmd/test/idle-scope.c` shows a settled terminal spends ~86% of its time in
  a 54-byte PC window (0x5354–0x5389) and `dmd_get_pc()` is exported, so the same trick
  is available from Swift — not done yet.
- dmd_core's GitHub HEAD embeds only the **8;7;5** ROM, which V8's `32ld` download crashes
  (unimplemented `MOVTRW` + unaligned access in the WE32100 core, ~30 KB in) — this is the
  mechanism behind the documented "use firmware 8;7;3" requirement. dmd_core's DUART is
  *one* serial pacer (wall-clock per-char at programmed baud; fresh NVRAM = 1200 baud) —
  A2 wrongly concluded it was the only one; see the DZ-throttle bullet below.
  Details: docs/spike-a0-results.md, Session 2.
- The **canonical** dmd repos are on git.loomcom.com (Gitea; HTML bot-walled, `git clone` +
  API work) — GitHub mirrors are stale. Canonical dmd_core 0.7.1: `reset(1)` = 8;7;3.
  Three emulator gotchas cost this project a day: the 8;7;3 self-test needs BREAK delivered
  as a 0x00 byte (patched); the kb FIFO drops keys typed faster than ~ms (type at 100 ms);
  the DUART needs a ~real-time-paced CPU (~10 MHz), never flat-out. Patches:
  tools/dmdbridge/patches/.
- **5620 screen size: widen freely, never shorten below 983 px.** Boot stock and call
  `dmd_resize_screen()` on the running terminal — it rewrites the one 20-byte `Bitmap`
  (`display`, ROM `0x9ca8`, AT&T's own `bootrom.s`: *"The display bitmap in rom at
  last!"*) — it is `.data` linked into ROM and never copied down, so **there is no RAM
  shadow to chase**. RAM is never reallocated: the emulator always carries 1 MB + a
  512 KB reserve at `0x800000`, which the firmware structurally cannot reach (its
  `maxaddr` table at `0xa37c` has exactly two entries, ceiling `0x00800000`). But the
  text grid is *compile-time* — `XCMAX`/`YCMAX` from `setup.h` fold to 87/69 — so a
  resized screen alone keeps 88 columns; `dmd_set_columns()` rewrites the 24 byte
  immediates (`6F 57`/`6F 58`) that hold it, **ceiling 127** because the operand is a
  sign-extended byte. It scrolls at pixel row 969, so a screen under 983 tall silently
  collapses its text. `mux` layers are exempt: `windowproc.c` recomputes the grid per
  layer from the layer rect — **and so is everything running *in* a layer**.
  `jerq/include/mux.h` defines `display` as `(*Jdisplayp)`, a pointer the layer
  system fills in at runtime, so `jim` and the rest of `/usr/jerq/mbin` follow a
  resized screen for free and have nothing to patch (`3nm` shows jim exports
  `Jdisplayp`, a `*struct-Bitmap`, and no `display` at all). **`muxterm` is the sole
  exception** — it *is* the layer system, owns the screen, and carries a real 20-byte
  Bitmap in `.data` at file offset 50512. `tools/widen-jerq.exp` copies it to
  `muxterm.w` with **`base` 0x700000→0x800000**, stride 25→36 and `corner.x`
  800→1152, and `/usr/jerq/bin/wmux` selects it through `$MUXTERM`, which `mux`
  already honours. **`base` is the field that matters, and it fails silently**: a
  resized screen moves the framebuffer to `0x800000`, so stock muxterm on a wide
  screen downloads all 55,156 bytes, runs, and draws into the vacated `0x700000` —
  presenting as a hang with the ROM's text still on screen. **On a wide screen
  `mux` must be `wmux`**, and never patch the stock binaries: `muxterm.w`
  hardcodes `0x800000` and is wrong at the Original preset. Proven end to end by
  `tools/drive-widemux.sh` — rightmost lit pixel x=1151 of 1152, against x=648 for
  stock. Do **not** chase the fault it throws when `base` is wrong: it is always
  `RAM_BASE + ram_visible()`, which looks like a decode-window bug and is not.
  **Three things will wedge or corrupt the power-on
  self-test, all found the hard way**: it blanks screen memory at a hardcoded
  `0x700000` (so it must run at 800×1024 — resize *after*); it stalls in `t_kbd()`
  under "WAITING FOR KEYBOARD STATUS" with a *still screen*, so wait for the idle PC
  window `0x5354`–`0x5389`, never for a quiet framebuffer; and it sizes RAM by probing,
  so the reserve above 1 MB must stay undecoded (`ram_visible()`) or it indexes past
  `maxaddr` and reads `0x0000000a` as its memory limit. Full evidence and the
  measurements: [docs/screen-size.md](docs/screen-size.md); harness
  `libdmd/test/resize-scope.c`.
- AT&T published the 5620 ROM **source** (GPL, Dave Dykstra, 1994 —
  [dmdmtg/5620rom](https://github.com/dmdmtg/5620rom); its README names `lsys.8;7;3`,
  the firmware we run). It answers firmware questions faster than any experiment:
  `src/xt/layersys/rdpatch/lsys.nm.1.1` is the **symbol table for `lsym.8;7;3`** with
  ROM addresses. Read it, don't link it — the boundary is in
  [docs/licensing.md](docs/licensing.md).
- **The DZ line is throttled to the guest's baud rate.** `pdp11_dz.c` calls
  `tmxr_set_port_speed_control`, so every LPR write by V8's tty driver makes SIMH
  rate-limit the socket to whatever V8 asks for — 9600, measured as ~950 B/s with an
  empty injector backlog. Fix without patching: `att dz -m Speed=*32,127.0.0.1:PORT`.
  tmxr keeps the bps *factor* separately (only reset for real serial ports) so it
  survives reprogramming, and its attach parser deliberately allows a bare factor for
  guest-speed-controlled devices. Measured: sustained rx 950 -> ~4,300 B/s and the mux
  download ~100 s -> **~15 s** (55,473 B on the wire, matching the documented 55,156 B
  payload plus overhead — so the transfer is complete, not truncated). This **corrects
  A2**: pacing was never "in the DUART" alone — there were two 9600 throttles in series
  (DUART at ÷8 = 9600-equivalent, and this), which is why changing only one gave 1.7x.
  Diagnose with queue depth, not throughput: a permanently empty inbound queue means the
  bottleneck is upstream, and no downstream tuning can help.
- The infamous "55K download stall" was **not a stall**: 32ld sends only muxterm's
  text+data (**50,324 B** per its COFF header; entry 0x71e85c), not the 144,603-B file —
  the rest is symbol table. ~55K on the wire = complete download + idle mux desktop.
  Measure protocol progress against *loadable* size, never `ls -l`.
- The 5620 mouse registers (0x400000 y, 0x400002 x) are free-running counters; muxterm
  integrates sample deltas with **y counting up the screen** from a (0,0) cursor. Feed
  deltas, not absolute positions (see the bridge's mouse model).
- **V10's kernel does NOT sync on halt, and V8's does.** This changes what stopping
  a machine safely means, so do not carry V8's habits across. `lsys/md/machdep.c`,
  entire: `boot(howto) { if (howto&RB_HALT) death(); reboot(1); }` and
  `death() { splx(0x1f); printf("death\n"); for (;;) ; }`. V8's `boot()` calls
  `update()`, prints `syncing disks... ` and sleeps five `lbolt` ticks for the I/O;
  V10 deleted all of it, and **`RB_NOSYNC` is defined in `lsys/sys/reboot.h` and
  referenced nowhere in the kernel**. So the userland `sync` is the whole flush --
  and it does not wait either, since `sync(2)` → `update()` → `bflush(NODEV)` sets
  `B_ASYNC` and returns before the disk has the block (`lsys/io/bio.c:692`). Hence
  `v10_halt` syncs, sleeps and syncs again. Consequence worth knowing: on V10
  `sync; sleep; ^E; quit` leaves the same disk as `/etc/halt` (whose only extra
  contribution is the `death` marker) — **on V8 that substitution would skip a real
  flush and be wrong**.
- **V10's `cc` has three `-t` letters, not six. `-t02palc` is OURS.** V10's
  `cmd/cc.c` handles `0` (ccom), `2` (c2) and `p` (cpp) and nothing else; `a`, `l`
  and `c` — as, ld, crt0.o+libc.a — were added to *V8's* `cc.c` in S5. So on V10
  `as` and `ld` cannot be redirected by a `-B` prefix, and an unknown letter is
  silently ignored rather than rejected. A hermetic stage 3 must either port that
  extension into our overlay or install stage 1 over the system first — decide on
  evidence, and never assume the seal is there because V8 has it.
- **There is no netfs on V10, for two independent reasons.** `lsys/astro/seki.m`
  configures `netafs 0` and `netbfs 0` — the network filesystem types are compiled
  in with **zero instances** — and SIMH's `vax750` has no Interlan at all (`show
  devices` lists only a disabled XU). seki's config *does* carry the card
  (`ni1010a 0 ub 0 reg 0164000 vec 0340`), so the simulator half is ours to fix;
  note the driver is `ni1010a` where V8's is `ill`, so grepping the generated
  config for `il` finds nothing and reads as "no card". Source therefore reaches
  V10 on a **disk** (`tools/v10-srcdisk.sh`), not a share.
- **The V10 golden has no `ar`, `cmp`, `tail`, `grep`, `wc`, `dd`, `find`, `sort`
  or `mknod`** — measured against `v10/mk/gen/prebuilt.txt` plus the boot path, not
  discovered one at a time. (`sort` cost K10.3 a run: `sed … | sort -u >
  /tmp/dests` answered `sort: not found`, the staged root was never created, and
  eleven assertions said NO about a tree that did not exist while the link half
  had worked perfectly. The dedup was not even needed — `mkdir` on an existing
  directory prints `File exists` and a loop can ignore it. `mknod` cost K11 a run
  the same way — `/etc/mknod: not found`, and `mkdep.py` had the makefile all
  along as the FSTOOL `v10mknod`.)
  - **`ls X && echo OK` IS NOT AN EXISTENCE TEST ON V10, because `ls` exits 0 for
    a file that does not exist.** `cmd/ls.c` calls `perror()` on the stat failure
    and falls through to `exit(0)`, so K11's node assertion reported ok over
    `ls: /dev/ra2h: No such file or directory` while `mknod` had never run. `test`
    has `-b` and `-c` (`cmd/test.c`); use them. Two are load-bearing for the bootstrap: stage 2 *is* an archive
  (`AR = /bin/ar` names a file that is not there) and stage 3 *is* a byte
  comparison. They are built in stage 1 as `BUILDTOOLS`. `/n` was missing too,
  and cost a whole run: `mkdir` makes one level, so `mkdir /n/v10` failed, the
  source disk had no mount point, and 26 assertions failed with nothing naming
  the cause.
  - **The V8 idioms do not transfer, and that is how `find` was found.** K10.2
    copied the 5620 include tree with `find . -print | cpio -pd`, which is
    exactly what `tools/v10-srcdisk.exp` does — on **V8**. On V10 it answers
    `find: not found`, cpio then reads nothing, and the failure surfaces as
    `cannot write in </usr/jerq/include>` with *three* assertions saying NO about
    a tree that was never copied. When a guest-side copy fails, check the tool
    exists on **that** edition before reading the error.
  - `dd` cost a run the same way (K10.1's space probe), so the general rule is
    worth more than the list: **on V10, assume a tool is absent until the boot
    path or `prebuilt.txt` says otherwise.**
  - **And a tool that is present may still be missing its DATA.** The golden has
    prebuilt `lex` at `/usr/bin/lex` and no `/usr/lib/lex` at all, so it answers
    `(Error) Lex driver missing, file /usr/lib/lex/ncform`. `ncform` is on the
    tape beside the lex source (`cmd/lex/ncform`), so it installs exactly as a
    header does — but until it does, every lex unit fails and the failure reads
    as a grammar the tape cannot process. `test -s /usr/bin/lex` is not
    "lex works".
- **ONE netfs DEVICE NUMBER PER MOUNT, AND `neta.h` SAYS SO IN EIGHT WORDS.**
  `short dev; /* server may be using several */`, and `nadomount()` is the
  mechanism: `iget(&pi, dev, ROOTINO)` then EBUSY when `i_count > 1`. Two shares
  mounted with the same dev give `nafsmnt: fmount: In use` on the second, because
  both asked for `(fstyp 1, dev 0, ino 2)` and the first still holds that inode.
  **V8's `nmount` computed the number from a `unique` argument for exactly this
  reason** — and `nafsmnt.c`'s own comment had reasoned it away ("V8's unique-id
  … simply disappears"). Only the *zero-minor* rule disappeared. `nafsmnt` takes
  the dev as an optional fourth argument.
- **pcc DOES NOT NEST COMMENTS, and the error names neither the comment nor the
  line.** Quoting a header's own comment verbatim inside a patch note — `short
  dev; /* server may be using several */` — puts a `/*` inside the block, its
  closing pair ends the block early, and every line after it becomes code.
  `nafsmnt.c` failed to compile with nothing pointing at the cause.
  `tools/v10-overlay.py` checks for it now, and **the first version of that check
  did not bite**: it walked `build()`'s output, and the file at fault is a
  hand-maintained addition `build()` knows nothing about — the same half-truth as
  the orphan prune. It walks the disk. Prove a guard bites; that is the only
  reason the useless version was found.
- **A PATTERN ACROSS FOUR DRIVERS IS NOT EVIDENCE ABOUT A FIFTH WHOSE JOB IS
  DIFFERENT: `tcp_device.c` LEAVES QDELIM CLEAR ON PURPOSE.** `tcp_ld.c` sets
  `QDELIM` on both its queues and `ni1010a.c`, `deqna.c`, `kdi.c` and `debna.c`
  all write `QDELIM|QBIGB` together, so `tcp_device.c`'s `QBIGB` alone reads as an
  omission. Setting it **hangs the machine**, and the counter-evidence was in the
  same file all along: `stread()` and `istread()` both short-return only when the
  downstream read queue lacks QDELIM, and otherwise sleep — `stread` with
  `tsleep(…, STIPRI, 0)`, **timeout zero, for ever**. A TCP byte stream never sends
  a delimiter to end that wait. Measured: `nafsmnt` connected, completed the netfs
  NSTART handshake (netfsd logged `mounted … as dev 0`) and then blocked in
  `read()` of the reply until the harness watchdog stopped the machine —
  `connection closed after 0 requests`. Every driver that sets the flag is
  **message-oriented** (Ethernet frames, Datakit), and `tcp_ld.c` sets it on the
  *discipline*, which frames its own messages; the tcp **device** hands userland a
  byte stream and says so by leaving the flag clear. **The real fault was the other
  one** — `istread()` freeing a block whose tail the caller had not read yet, which
  the kernel itself reported as `neta: read -1 expected 48`.
- **`v10/src/` IS NOT WHOLLY GENERATED, so nothing may prune it.**
  `tools/v10-overlay.py` produces patched copies of tape files, but the directory
  also holds hand-maintained **additions** the generator knows nothing about:
  `cmd/nafsmnt.c`, `include/jioctl.h`, `libplot/libpen/openpl.c` and
  `lsys/astro/ipnx780.m` — the 780 kernel config the whole of K7 depends on. A
  prune of "everything `build()` does not produce" deleted all four in one run;
  they were committed, so `git checkout -- v10/src/` restored them, and that is the
  only reason it cost nothing. The gap it was reaching for is real and still open:
  **retracting a patch leaves the previous generation's file behind**, `--check`
  compares only what it generates and says "up to date", and a downstream consumer
  keeps naming it — `v10/mk/gen/kobj.order` went on listing `tcp_device.x` after
  the patch was withdrawn, so the kernel harness went on rebuilding it. Delete a
  withdrawn overlay file by hand until the generator records what it wrote.
- **`cpio -pd` DOES NOT MAKE THE DIRECTORY YOU COPY INTO, and every existing use
  of the idiom got away with it by accident.** `-d` creates the directories that
  appear *inside* the archive; the destination itself must exist, and when it does
  not the failure is `cannot write in </mnt/src/ipc/internet>` **on stderr with a
  zero exit status** — so a run that copied nothing looks like a run that worked.
  `v10-srcdisk.exp` has carried that warning in a comment since the `cmd/` copies
  were written, and it still cost a 20-minute rebuild, because the reason the
  other copies work is not the idiom: `libs.cpio` had already created `netfs/` and
  `ipc/` as **path components** of `netfs/libnetb/…` and `ipc/libin/…`, and never
  `ipc/internet`. So a new top-level copy needs its own `mkdir`, one level at a
  time (V8's `mkdir` makes one), added to the loop at the top rather than beside
  the copy. What made this cheap rather than silent was the `&& echo NI$OK` marker
  and the stamp-on-failure guard: two assertions said NO, `v10-srcdisk.sh` skipped
  the assemble *and* the stamp, and the chained runner refused to boot the next
  harness at all.
- **DEVICE MAJORS AND LINE-DISCIPLINE INDICES ARE PROPERTIES OF THE TAPE, NOT OF
  OUR CONFIG — `lsys/lib/tab` says so, and that is why our 780 kernel boots a
  `/dev` that was made for `seki`.** The obvious reading of a generated
  `cdevsw[]` is that it follows the config's device list, so a machine with a
  different `.m` would number its devices differently and every node in
  `v10/mk/gen/proto-dev` would be wrong under `ipnx780`. It is not so. `tab` is
  the `-t` argument K7 already passes to `mkconf`, and it is a fixed assignment:

	cdev 0 console   cdev 4 hp    cdev 28 ra    cdev 42 ip
	cdev 1 dz11      cdev 8 starcons            cdev 43 tcp
	cdev 44 ni1010a  cdev 50 udp

	ld 0 ttyld   ld 10 ipld   ld 11 tcpld   ld 14 udpld

  So `il` is char major 44 on any V10 kernel, `/dev/ip6` and `/dev/ip17` are IP
  **protocol numbers** rather than unit numbers (6 = TCP, 17 = UDP, which is what
  V8's `/etc/rc` pushes onto them), and the `ld` numbers match `libc/gen/
  linedis.c`'s table exactly — `ip_ld = 10`, `tcp_ld = 11`, `arp_ld = 13`,
  `udp_ld = 14`, the same integers V8 uses. **Read `tab` before writing a
  `mknod`**: a wrong major is not a harmless one, since on V8 a node built into
  the wrong `bdevsw` slot panicked the kernel through a wild pointer.
  - **`tcpld 0` DOES NOT REMOVE THE LINE DISCIPLINE, and the tape proves it
    rather than the reasoning.** Our `ipnx780.m` carries `ipld 0 / udpld 0 /
    tcpld 0` — copied from `alice.m`, a real working CSRC 780 — which reads as
    "no TCP", the same way `netafs 0` really did mean no netfs. The counts are
    different animals: a filesystem type needs instances, a line discipline
    needs a `streamtab[]` slot. `lsys/misc/europa.m` has all three at zero and
    the generated `europa.c.c` beside it still says `&ipstream /* 10 */`,
    `&tcpstream /* 11 */`, `&udpstream /* 14 */`. **The tarball ships mkconf's
    own output for eight machines** (`lsys/misc/*.c.c`) — when a question is
    "what would the generator do", read one instead of running one.
  - `arp` is the exception worth knowing: it has **no `ld` line in `tab`** and
    `arp_ld = 13` indexes a NULL slot. Nothing pushes it — `ipconfig`/`dipconfig`
    set `IPIOARP` and then do ARP in *userland* over a raw ether minor.
- **EDITING A `tools/*.sh` MID-RUN MADE BASH RESUME INSIDE A WORD, AND IT SKIPPED
  THE VERIFICATION WITHOUT FAILING.** The rule was already here — *"during a run,
  `docs/`, `CLAUDE.md` and brand-new files are safe; `v8/**` and the
  `tools/*.sh|*.exp` that bash is still reading are not"* — and it was broken to fix
  a **comment**. bash reads a script incrementally by byte offset, so the edit moved
  the ground under it:

	tools/v10-mkdisk.sh: line 124: ding.: command not found

  `ding.` is the tail of `hiding.`, the last word of line 120. **The guest-side
  14/14 was unaffected**, because expect's script is read whole by Tcl at startup —
  which is exactly what makes this dangerous, since the part that vanished was the
  driver's *host-side* verification, the half that had caught the
  sectors-versus-blocks error in the first place. It had to be re-run by hand. *A
  run can pass every one of its own assertions and silently skip the instrument that
  would contradict them.* Tcl is safe to edit mid-run and bash is not; when in
  doubt, wait.
- **`pwd` IS NOT ON THE V10 GOLDEN EITHER** (`sh: pwd: not found`, printed by
  `cpio -pd` during a copy that nonetheless succeeded). Add it beside
  `ar cmp tail grep wc dd find sort mknod chmod`. It is in neither
  `bootpath.order` nor `prebuilt.txt`, which is the standing test.
- **A WHOLE-DRIVE ROOT FILESYSTEM SWAPS OVER ITS OWN DATA BLOCKS, AND THE DISK
  BOOTS FIRST.** `lsys/io/ra.c`'s `ra_sizes[]` is the whole layout, and the two
  entries that matter both begin at sector 0:

	a   10240 blocks at 0        root
	b   20480 blocks at 10240    SWAP, and `dump' shares it
	c  249848 blocks at 30720    /usr
	h    HUGE blocks at 0        the whole drive

  So a filesystem built on `h` contains partition `b`, and `ipnx780.m`'s
  `swap ra 01 20480` then writes swap through blocks 10240..30720 of a live
  filesystem. **Nothing complains**: the disk boots, and the corruption arrives
  only when something swaps. K14 reached for `h` because a 111,384-block
  filesystem cannot be rooted on `a` — `ra.c`'s clamp is
  `limit = min(radsize - blkoff, nblocks)`, and since K11 puts the free-block
  bitmap in the **last** blocks of a large filesystem, the mount reads past
  10,240, gets `ENOSPC`, sets `u.u_error` and `iinit` panics:

	unix
	mem = 6062080
	panic: iinit mount

  **The fix is to move the DISK, not the kernel**, and the authenticity rule is
  what settles it: `alice.m` and `seki.m` both say `root regfs ra 0100`, so a
  whole-drive root is *our* deviation and needs no patch once the disk is laid
  out the way V10 lays out disks.
  - **AND `ra_sizes[]` IS IN 512-BYTE SECTORS, WHICH IS THE V8 RP06 TRAP ON A
    DIFFERENT DISK.** Reading `10240` as blocks made the harness ask `mkbitfs`
    for eight times partition `a`, and the guest said nothing — `mkbitfs` wrote
    an `s_fsize` of 0 and every later step failed on a filesystem that was never
    made. **`tools/v10-free.py` caught it host-side and named the number**, which
    is the whole argument for reading a disk from the host:

	v10-free: s_fsize reads 0, which is not a size partition a can hold (max 1280)

    Converted once (÷8), the table explains the golden exactly: `a` = **1,280
    blocks / 5.0 MB**, and the golden's own root filesystem **is 1,280 blocks**,
    so Bell Labs sized it to the partition to the block; `c` = 31,231 blocks /
    122 MB, of which the golden uses 30,752 = MAXSMALL exactly. CLAUDE.md already
    carried this warning for V8 — *"RP06 partition `a` is 15,884 **sectors**, not
    blocks"* — and `v10-free.py` carried the conversion in a comment. Neither was
    read.
  - **SO A V10 SYSTEM DISK HAS TWO FILESYSTEMS — root on `a`, swap on `b`, `/usr`
    on `c`, mounted by the `/etc/rc` the golden already ships.** Root cannot move
    even if you wanted it to: `lsys/boot/README` requires `/unix` to be *"in the
    filesystem beginning at the front of the boot device"* and `star/uda.s` carries
    no partition offset, so root is the filesystem at **sector 0** — `a` or `h`,
    and `h` is the one that overlaps swap.
  - **AND `used = s_fsize - s_tfree` INCLUDES THE I-LIST, WHICH IS NOT CONTENT.**
    That difference on a 111,384-block filesystem read as 1,626 blocks and was
    written up as "6.4 MB of content that cannot fit a 5 MB root" — **wrong by 4
    MB**, because 1,024 of those blocks are the filesystem's own i-list, a property
    of its *size*. A direct probe (`cat dir/* | wc -c`) measures the boot path at
    **2.1 MB**: bin 833,811 + etc 526,152 + lib 631,774 + unix 228,310. It would
    have fitted `a` all along. The two-filesystem layout is right because it is
    V10's own and needs no kernel patch — never because of the size — and keeping
    those two claims apart matters, because the size one is false.
  - **`/usr` on the golden is EXACTLY 30,752 blocks, which is `MAXSMALL` to the
    block** (`BITMAP*BITCELL` = 961*32, `cmd/mkbitfs.c`). Bell Labs sized it to
    the largest filesystem an in-superblock bitmap can address — precisely the
    ceiling K11 broke. Consequence for a *root* filesystem: 10,240 blocks is
    inside MAXSMALL (as is `/usr` at 30,752), so `mkbitfs` chooses `smallfree()`
    and the bitmap stays in the superblock, **`flag=0`**. An assertion demanding K11's `flag=1` therefore
    fails on a perfectly correct root disk, which is what it did here. K11's
    N-arm bitmap is not retired by this; it is just not what a 5 MB root uses.
  - **Derive the minor, never write it down.** `64 | (unit<<3) | part` reproduces
    every value this project has measured — `/dev/ra0a` 64 and `/dev/ra0c` 66 off
    Bell Labs' own nodes, K11's 87 on rq2, K14's 79 on rq1 — so a computed minor
    cannot repeat K11's failure of addressing unit 1 while the disk sat on unit 2.
- **AN ARCHIVE MEMBER'S UNDEFINED EXTERNALS NAME THE OTHER ARCHIVES YOU NEED, and
  reading them is cheaper than a boot.** Calling the tape's own `tcp_sock()` and
  `tcp_connect()` instead of hand-rolling them pulls `libin.a(tcp_lib.o)` in, and
  that object leaves `_errstr` and `_flabclr` undefined — neither of which is in
  libin, and one of which (`flabclr`, "for security unix") looks like a symbol
  from a Bell Labs variant we do not have. Both resolve: `flabclr` is
  `libc/sys/label.c` and `errstr` is `libipc/ipcopen.c`. **Which is also why
  `LIBIN` in `ipc/internet/mkfile` is TWO archives** — `../libin/libin.a
  ../libipc/libipc.a` — and that is load-bearing rather than decorative:
  `in_address()` calls `qvalue()` from `libipc/qns.o` for the not-a-dotted-quad
  case. A 20-line symbol-table dump over the tape's own `.a` answered all of it
  in a second.
- **`dipconfig` IS THE ipconfig THAT NEEDS NO 27TH LIBRARY, and the mkfile's own
  link lines are the whole argument.** `ipconfig: cc -o ipconfig ipconfig.o
  $LIBIN $LIBCOMMON` against `dipconfig: cc -o dipconfig dipconfig.o $LIBIN`.
  `libcommon` is `ipc/mgrs/common/` — `logevent`, `logconsole`, `detach`,
  `print`, `fprint` — a library in no manifest, wanted for a program whose extra
  features over `dipconfig` are a subnet mask and a syslog. `dipconfig` is the
  earlier generation of the same program, does the identical five ioctls
  (`FIOPUSHLD ip_ld`, `IPIOLOCAL`, `IPIOHOST`/`IPIONET`, `IPIOARP`, `ENIOTYPE`)
  and needs only what K10.2 built. **And `tcpconfig` has no rule in that mkfile
  at all** (`MGRS=ipconfig routed dkipconfig udpconfig`) while a prebuilt binary
  of it sits in the directory — the working-directory pattern again, in the
  opposite direction to the 46 commands.
- **A HEADER WITH NO INCLUDE GUARD, NAMED TWICE, BLAMES BELL LABS FOR YOUR BUG.**
  r70's `<sys/inet/tcp.h>` has no guard and `<sys/inet/tcp_user.h>` includes it
  itself under `#ifndef KERNEL`, so naming both gives pcc2 the same two typedefs
  twice — and the second time round `tcp_port` is already a type name, so
  `typedef unsigned short tcp_port` reads as three type specifiers combined:

	"/usr/include/sys/inet/tcp.h":3:illegal type combination
	"/usr/include/sys/inet/tcp.h":5:illegal type combination

  Two errors pointing at a 1983 header and none at the file that caused them,
  which reads as pcc2 not accepting `unsigned short` — a claim contradicted by
  every other file in the tree. `<sys/inet/in.h>` escaped only because its first
  line happens to be `#ifndef INADDR_ANY`. **The tape's own idiom is one header**:
  `ipc/libin/tcp_lib.c` includes `<sys/inet/tcp_user.h>` and nothing else.
- **`chmod` IS NOT ON THE V10 GOLDEN EITHER** (`chmod: not found`), which matters
  less than it sounds: a program built with `cc -o` is already executable, so the
  fix is usually to build rather than to copy-and-chmod. Add it to the absent
  list beside `ar cmp tail grep wc dd find sort mknod`.
- **A HOST-SIDE MODEL OF `/usr/include` IS WORTH NOTHING UNLESS THE HARNESS
  INSTALLS WHAT IT MODELS, and this ran in the flattering direction for a whole
  phase.** `tools/v10-world.py` has always resolved `<stdlib.h>`, `<float.h>`
  and `<stdarg.h>`: stage 2 chose which of r70's four copies of each pcc2 can
  read and recorded the evidence. But **only `tools/v10-stage2.exp` performed the
  copies**, on the `.s2` image chain, and `tools/v10-compile.sh` runs on a
  `.stage1` clone that has none of them. So K10.1 surveyed one machine and
  compiled on another, and fourteen units failed:

	2500 awk ed eqn grap idiff join map pic sort zero   stdlib.h
	cb ed sum                                          stddef.h

  Eleven of those name a decision *already made*. They went into K10.1's
  write-up as header facts about the tape. Same shape as the app's *"it is in
  the golden, it will arrive on Reset" is not shipping it*, and the same answer:
  the list lives once, in the generated `v10/mk/gen/inc.extra`, `v10_inc_extra`
  in `tools/v10drive.exp` applies it in every harness, and `v10-world.py
  --check` refuses when it disagrees with the copies stage 2 makes.
  - **The mechanical test reproduces all three of stage 2's choices, including
    the one no regex should have caught.** `installable()` rejects a variant
    carrying `extern "C"`, `void *`, `const`, a prototype, an anonymous struct
    — or **an ANSI `U` suffix**, which is why `lcc/stdarg.h` is wrong: it is
    pure `#define`s and parses perfectly, but its macro says
    `_littleendian_va_arg(list, mode, 3U)` and pcc2 lexes `3U` as 3 followed by
    the identifier `U`. The header compiles; the *expansion* fails hundreds of
    lines away. `CC/stdarg.h` is the one installed, and this table said lcc's
    for a week.
  - Extending past libc's three closes 11 unit-mentions and the rest are a
    finding, not a shortfall: **`malloc.h`, `memory.h` and `sysent.h` exist only
    as C++** (`extern "C" {` — they are cfront's) and **`locale.h` only as ANSI
    prototypes**. Those need converting like the printf family; they are not a
    layout question.
- **`gets` WAS DELETED FROM libc BY BELL LABS, ON PURPOSE, IN 1988 — so a
  command that will not link over `_gets` is the tape working as intended.**
  K10.3's `clear` and `dired` compile and then fail on `Undefined: _gets`, which
  reads as a hole in the libc we built. It is not. There is **no**
  `libc/stdio/gets.c`; there is `libc/stdio/gets.c-1`, and it opens:

	/* @(#)gets.c	4.1 (Berkeley) 12/21/80 */
	/*
	 * Deleted from libc.a by td, 88.11.07
	 * gets is an unacceptable security hole.
	 */

  `gets.o` is absent from Bell Labs' own `libc.a`, and so are `gtty.o` and
  `stty.o` — **eleven years before C99 deprecated `gets` and twenty-three before
  the standard removed it**. Those commands could not have linked on the tape's
  own machine either. Restoring it would undo a documented security decision,
  which the authenticity rule settles: the tape is the specification, including
  where it is inconvenient.
  - **The `-1` suffix means two different things in the same tree, and only one
    of them is a decision.** `libc/gen/rand.c-1` and `libc/math/hypot.c-1` sit
    beside a live `rand.c` and `hypot.c` and are ordinary superseded copies —
    both `rand.o` and `hypot.o` are in the archive. `gets.c-1` has no live
    counterpart and carries the note. **Read the file, not the suffix.**
- **A UNIT'S DIRECTORY HOLDS FILES ITS BUILD DOES NOT COMPILE, and a survey that
  compiles every `.c` fails the unit on them.** `cmd/sh` dies on
  `"cmd/sh/profile.c":18: illegal pointer/integer combination`, and `profile.c` is
  not among the 24 objects in sh's own `$OFILES`. Fifty units are like that, and
  what they hold is what a working directory accumulates: `hello.c`, `x.c`, awk's
  `maketab` helper, other machines' back ends in `cmd/gcc`, superseded
  generations (`osed0.c`, `olint1.c`, `OLDex_temp.c`), `2.test.c`. Reading each
  unit's object list is a **fidelity** change, not a way to raise a number.
  - **Three witnesses, in the KEEP direction, and each is the tape's own
    statement**: the object is named in a build file's object list; a leftover
    `.o` sits beside the source (developers' working directories, so what was
    compiled in place is evidence); or **the build names the source itself** —
    `cmd/docgen`'s makefile says `docgen: docgen.c` and lets make's implicit rule
    do the rest, so no `docgen.o` exists anywhere and without that witness the
    test dropped the program the unit is named after.
  - **Join continuation lines FIRST.** sh's `$OFILES` spans three lines; read
    separately they name eight of twenty-four objects, which would "prove" that
    sixteen of the shell's own sources are not in its build.
  - **Two refusals, because dropping a source raises the score** — never drop a
    unit's only `main()`, and never drop more than half its sources (`cmd/xref`
    would have lost 4 of 5). Both are recorded in `v10/mk/gen/world.drop` with
    every drop, because *a rule that quietly declines to fire is
    indistinguishable from one that had nothing to do.*
- **THE ASSERTION DISCIPLINE, because six of them could not fail across K11 and
  K12 and the failures came in three shapes.** Every assertion here is
  `<command> && echo TOKEN$OK` matched against `TOKEN-ok`, and the whole value of
  that form is that **the thing being tested is what produces the token**. Break
  that and the assertion reports the weather. The three ways it broke, all in one
  week:
  - **A semicolon where `&&` was meant.** `icheck /dev/x ; echo IK$OK` prints
    `IK-ok` whatever icheck did, and duly reported *"icheck reads it back: ok"*
    directly above `cannot open /dev/ra2h`. Three separate assertions had this.
  - **A command whose exit status does not mean what it looks like.**
    `ls X && echo OK` is not an existence test on V10 because `ls` exits 0 for a
    missing file; `test -s foo.log` is not "it compiled" because a successful
    compile writes nothing.
  - **A test whose subject does not exist, so it tests something else.** A write
    to `$MP/probe` after a failed mount writes to the mount point's own directory
    and passes. Anything downstream of a mount, an attach or a build must be
    **gated on it**, and a skipped assertion reported as a failure: *a phase that
    did not run is not a phase that passed.*
  The general form, worth more than the three cases: **assert the RESULT through a
  marker the success path alone can write, and never the absence of a complaint.**
  And prove it bites — a permanently-passing assertion is worse than a
  permanently-failing one, because the failing kind eventually gets read.
- **A GUEST CAN REPORT SUCCESS ABOUT THE WRONG DISK, and K11 did — nineteen
  assertions, all true, all about a filesystem written over the source disk.** The
  minor was `64 | (1<<3) | 7 = 79`, so a node *named* `/dev/ra2h` addressed
  **unit 1** — `UNIT(79) = (79>>3)&07` is 1, not 2 — while the blank disk was
  attached as `rq2`. The comment above it even read *"unit 1, the blank disk"*,
  contradicting the attachment three lines up. `mkbitfs` made a perfectly good
  111,384-block filesystem, V10 mounted it, wrote to it, unmounted and remounted
  it, and only the host's read of the blank image — still all zeroes — said
  anything was wrong. The right minor is **87**.
  - **The clone rule is what saved it**: the disk the guest destroyed was
    `.k11src`, and `ipnx-v10-src.img`'s own stamp still matched the repo
    afterwards. This is the case the rule was not written for and covered anyway.
  - So a harness that writes to a device should re-check something it is *not*
    aiming at. K11 now re-reads a file off the courier mount immediately after
    `mkbitfs`, which is one line and would have caught it in the guest.
  - The block major was the one number that needed no debugging, because it was
    measured: `/dev/ra0a` and `/dev/ra0c` print `7, 64` and `7, 66` —
    `BITFS|unit0|part0` and `BITFS|unit0|part2`, the same arithmetic on nodes Bell
    Labs made.
- **A `cmd/` DIRECTORY IS NOT NECESSARILY A COMMAND: 71 of the 358 units carry
  more than one `main()`.** `cmd/worm` has 22 programs in it, `cmd/qsnap` 17,
  `cmd/uucp` 11, and `cmd/compact` is the small clear case — `compact.c` and
  `uncompact.c`, two programs with no shared code. This changes what "the 283
  commands" means and it changes what a link survey can do: linking a unit's
  objects together fails on `multiply defined _main`, and the obvious repair is
  worse than the skip — pairing each `main` with *all* the unit's other objects
  would give `cmd/awk` a `maketab` carrying the whole of awk, because `ld` pulls
  in every `.o` it is named. Which objects belong to which program is in each
  unit's own makefile, which is exactly why the boot path has generated
  makefiles. `world.link` names all 71 and builds none of them.
- **yacc is at `/usr/s1/usr/bin/yacc`, not `/usr/s1/bin/yacc`, and the path
  belongs in `tc.order` rather than in a harness.** `yacc.mk` installs to
  `$(TOOLDIR)/usr/bin/yacc` and stage 1 sets `TOOLDIR=/usr/s1`. Written out by
  hand in `v10-compile.exp` it failed for all fifty generator rows —
  `/usr/s1/bin/yacc: not found` — and turned 241 compiled units into 232, which
  reads as a regression and was a typo. `tc.order`'s third column is the install
  path *and* is what stage 1 installs from, so read it: a component list that
  appears twice will disagree.
- **A GENERATOR STEP IS PART OF THE BUILD, AND A SURVEY THAT SKIPS IT REPORTS
  ITS OWN OMISSION AS A FACT ABOUT THE TAPE.** `v10-world.py`'s `csources()`
  takes `.c` files, so nine units were reported `blocked: missing:y.tab.h` — a
  header **yacc writes** — and `expr` and `ipa` were not surveyed at all,
  because their only source is a grammar. Four things to get right, all of which
  were got wrong first:
  - **Four suffixes, not two.** `cmd/ratfor`'s grammar is **`r.g`** and
    `cmd/ipa`'s lexer is **`ipa_trans.lex`**; a scan for `*.y` and `*.l` finds
    neither, and ratfor's makefile says `yacc -d r.g` in as many words.
  - **`-d` is the tape's own flag** — sixteen makefiles write `yacc -d` outright
    and four more write `$YFLAGS` over `YFLAGS = -d`. It is also what makes
    `y.tab.h` exist.
  - **A recipe is a BLOCK, not a line.** `cmd/ccom` runs `yacc` and then
    `sed`s `y.tab.c` into `cgram.c` on the next line; `cmd/2500` edits it with
    `ed`. Judged a line at a time both look like a plain yacc call, and the
    survey would compile a generated source the tape never compiles. A *rename*
    (`cmd/cpp`'s `mv y.tab.c cpy.c`) is not a transform, and the first version of
    the test could not tell the two apart.
  - **The object is the generator's natural output, not a name we invent.**
    `cmd/config`'s `OBJS` names `y.tab.o` and `lex.yy.o` outright, and deriving
    from the grammar gave `config.y` and `config.l` the *same* object.
  - And **a unit with its own generated makefile already has this described,
    correctly**: `ccom.mk` and `cpp.mk` carry the tape's recipe including the
    `sed`, so `world.gen` skips those units rather than emitting a weaker generic
    row. That also removed the row this survey had no business emitting —
    `cmd/ccom/common/sty.y`, a grammar named in no object list in ccom's
    makefile.
- **`v10-srcdisk.sh` STAMPED A CURRENT srcid ON A FAILED RUN**, which defeats the
  one guard that exists for the source disk being a copy. It assembled the image
  and called `srcid_write` unconditionally and only then exited with the guest's
  status — so a run that bailed left a possibly-truncated disk claiming to carry
  the current `v10/mk/gen` and `v10/src`, and `srcid_check` would pass it. The
  fix is *not* to delete the stamp: a **missing** `.id` is deliberately only a
  warning. It is to skip the assemble entirely on failure, leaving the previous
  image and stamp to be judged on their own merits. Found when SLiRP answered
  `attach il nat:` with `Sockets: bind error 13 - Permission denied` several
  hundred times and the guest quit at `sim>` — transient, and a retry worked, but
  the hole was not transient.
- **`echo MAKE$OK` in a makefile prints `MAKEK`.** make's `$` takes a *single*
  character unparenthesised, so `$OK` is `$(O)` then `K`, and `$(O)` is empty —
  make working exactly as specified, reported by a test as make being broken. Pass
  the marker as a command-line macro (`make -f m.mk V=MACRO$OK`) so the **shell**
  expands it before make sees a dollar; the marker discipline still holds, because
  the tty echoes the literal `MACRO$OK`.
- **A TALLY CANNOT LEAVE A REDIRECTED LOOP IN A VARIABLE, and the failure is
  flattering.** 1970s `sh` **forks** for a compound command carrying an input
  redirection, so in

	nf=""
	while read obj src
	do	... nf="$nf." ; echo "MISS $obj" >> mem.log
	done < objs.lst
	if test -z "$nf" ; then echo GOOD ; else echo BAD ; fi

  the `echo >>` survives (it is a *file*) and the `nf=` does not (a variable in a
  dead child), so the verdict always reads GOOD. K10.2's first run reported
  **26 of 26 libraries with every member compiled while its own `TALLYM` said 42
  members had not built** — both numbers written by the same `else` branch,
  contradicting each other in one report. **Keep the tally in a file**
  (`echo . >> nf.cnt`, then `test -f nf.cnt`), which is immune either way and so
  needs no theory about which shell forks when.
  - **`ar cr` accepts object names that do not exist**, produces an archive from
    whatever it *can* open, and `ranlib` blesses the result — which is why all 26
    archives appeared and installed. So **"an archive was built" is never the
    question; "does it hold every member" is.** Check with
    `ar t | sed -e '/__\.SYMDEF/d' | sed -n '$='` against the manifest count.
    An archive of 30 objects out of 33 links until the day something needs the
    other three.
  - **A test asserting a non-empty log is inverted for a compiler**, because a
    compile that *succeeds* writes nothing: `test -s can.log` reported the canary
    as failed while `LCANARY-cc-ok` sat in the same transcript. Assert a marker
    the success path writes, never the absence or presence of diagnostics.
    **This was in `v10-compile.exp` too, and it is why K10.1 HAD NEVER EXITED
    0**: `test -s $OBJ/can.log` as *"the canary compiled"* is true only when the
    canary **failed**, so the run reported 6/7 on a pass in which 241 units
    compiled — which no wrong set of flags can do. A permanently-failing
    assertion stops being read, which is how `atof` hid in stage 2; the same
    mechanism, one harness over.
  - And the meta-lesson, since the guest/host cross-check was in place and blind
    to all of it: **two readings agreeing is not two readings being right.** Both
    instruments were counting the same tokens. What was missing was an *internal*
    consistency check — if any member failed, at least one library must have.
- **V10 is not source-only, and its own toolchain runs on V8.** The tarball carries
  **483 linked VAX executables** — `cmd/ccom/vax/comp` (the C compiler), `cmd/as/as`,
  a complete 262-member `libc.a` — plus 1,525 objects. `tools/v10-probe.sh` proved 9/9
  that they run unmodified on a V8 kernel, so there is **no cross-build**: only `cpp`,
  `c2` and `ld` had to be built from source. The syscall tables explain why — 111 of 129
  slots hold the same call at the same index, and every one a compiler uses is among
  them; the notable difference is slot 11, V7's vestigial `exec` in V8 and a 64-bit
  `lseek` in V10, which nothing in a compiler calls. **`cmd/ld.c` exists** (1,946 lines,
  "string table version for VAX"); the plan said it did not, because it is a loose file
  under `cmd/` rather than a `cmd/ld/` directory — the same reason `cmd/cc.c` is easy to
  miss. Details: [docs/v10-log/2026-08-16.md](docs/v10-log/2026-08-16.md).
- **`-B` crosses the edition boundary.** V8's `cc.c` and V10's are the same program eight
  years apart — same passes, same `-B` prefix, same `-t` selection — so S5's extended
  `-t02palc`, built to stop V8's own build reaching into the running system, is what
  points a `cc` at a *V10* toolchain: `cc -B/usr/v10/lib/ -t02palc` uses nothing of V8's
  but the driver and `/usr/include`.
- **V10's prebuilt binaries are an ORACLE, not a shortcut.** 46 of ~283 command source
  units have a linked binary, and the split is not random: `sh`, `sed`, `ls`, `ps`,
  `make`, `cpio`, `cron` are present; `init`, `getty`, `login`, `mount`, `mkfs`, `fsck`,
  `cat`, `cp`, `rm`, `echo`, `date` are **not**. These are developers' working
  directories, so what survived is whatever was last compiled in place — the boot path
  was *installed* elsewhere and has to be built regardless. Use the 46 to check what we
  build, never to skip building it.
- **V10 has drivers for the machine we already emulate**: `lsys/io/hp.c` (Massbus RP),
  `dz.c` (DZ11) and **`ni1010a.c`** (Interlan). So `libsimh/patches/pdp11_il.c` may serve
  V10 unchanged — but V8's driver is `ill.c` and V10's carries an **A**, so confirm it is
  the same card rather than assuming. `star` is the VAX-11/780 family (`md/machstar.c`,
  `consstar.c`, `nexstar.c`, `ubastar.c`, `ml/trapstar.s`) and `astro/alice.m` is a real
  CSRC 780 config (`ms780`, `dw780`, `mba`). The configs are named after comets, plus
  `research` (the main CSRC machine) and `r70` (where `r70include.tar` came from).
- **There are TWO V10 kernel trees.** `sys/` (756 files) and `lsys/` (763) share 522 files
  of which **131 differ**, with different machine-config sets (10 against 17). Settle
  which one is the kernel before compiling anything, not halfway through.
- **`vaxpcc2` in a binary does NOT mean it came from V10.** It looks like a signature and
  is not: V8's own `/bin/echo`, off our golden disk, carries the same `.stabs` string,
  because both editions' `ccom` descend from pcc2. Provenance comes from where a thing
  was built, never from grepping it.
- **Scan for `^[ \t]*#[ \t]*include`, never `#include`.** V10's `cpp.c` opens with
  `# include <libc.h>` — a space after the `#`, ordinary 1970s style and common in that
  tree. A host-side scan that missed it declared every header present and cost a whole
  boot, because the build then died on the one that was not.
- V10's `/usr/include` is a 1997 reconstruction of a 1995 tree (`r70include.tar`, now
  imported as `work/v10/include`) — expect header/source skew during Track B and log every
  reconciliation as a patch. Measured: `ranlib.h`, `pagsiz.h`, `ctype.h`, `setjmp.h`,
  `sys/dir.h`, `utmp.h`, `sys/ino.h` and `struct _iobuf` are **identical** to V8's;
  `a.out.h` differs by one bit-field *name* in the relocation record at the same width, so
  the object formats agree; V10's `stdio.h` includes a `<tmpnam.h>` V8 has never had; and
  V8 has **no** `sys/ttyio.h`, `sys/nttyio.h`, `sys/filio.h`, `utsname.h` or `libc.h` at
  all. **But the r70 tree is the right default for V10 source** — B2.0 built 15 of 17
  boot-path commands against it and 10 against V8's. Reserve V8's headers for programs
  linking V8's libc.
- **Before blaming r70 skew, `cmp` — the tarball ships its own control.** `sys/` and
  `lsys/` carry **1995** copies of the very headers `r70include.tar` reconstructs in
  1997, so "is this reconstruction skew or is this the source?" is a one-command
  question, never a judgement. It was got backwards once, on 2026-08-16: V10's `mv.c`
  uses `ROOTINO` and includes nothing that defines it, compiling only against V8's
  headers because **V8's `sys/types.h` includes `sys/param.h`** — which read as r70
  having dropped a line, and is not. `src/sys/sys/types.h` is **byte-identical** to
  r70's `include/sys/types.h`: the reconstruction is faithful and **`mv.c` is the
  defect**. (Same for `fsck.c`, which includes a bare `<stat.h>` where every other
  command says `<sys/stat.h>`.) Both are one-line patches to V10 source — and both are
  commands with no prebuilt binary, which is consistent: nobody had compiled them in
  place when the tape was cut.
- **The V10 tty interface is a header repackaging, not a new kernel interface.** V8 uses
  `sgtty.h`, V10 `sys/ttyio.h`, which looks like a wall and is not: every `TIOC*` V10
  shares with V8 has the same `(('t'<<8)|N)` number, `struct sgttyb` is unchanged in
  layout, and V10 adds exactly two ioctls — `TIOCGDEV` (23) and `TIOCSDEV` (24), into
  slots V8 leaves free — to move line speed out into a separate `ttydevb`. So `init`,
  `getty`, `login` and `stty` need the *header*, not a kernel change.
- **Compiling is not running, and one table separates them** (`tools/v10-syscalls.py`).
  **112 of 128 syscall slots hold the same call at the same index.** Six are filled in
  V10 and `nosys` in V8 — `fmount` 26, `funmount` 50, `setruid` 56, `getlogname` 67,
  `setgroups` 74, `getgroups` 75 — and a program reaching one of those traps with a bare
  errno naming nothing. In the whole boot path exactly two callers exist: **`mount` uses
  `fmount` and `umount` uses `funmount`**, so both build, link, and cannot run until a
  V10 kernel is under them. That costs nothing (they are only ever needed by that
  kernel), but do not read their failure as a build problem.
- **Both editions number the upper half of `sysent[]` `64 +9`, not `73`** — the author
  wrote the offset from where the file is `#include`d rather than the sum, and V8 splits
  the table across `sysent.c` and `vmsysent.c` besides. A scan understanding only a bare
  number reads a 128-entry table as a 64-entry one and then reports a **clean 64/64
  agreement**, which looks exactly like a result. `v10-syscalls.py` refuses to run on a
  short parse for this reason.
- The Alhadis GitHub mirrors are incomplete (v10 mirror omits `630/`) — TUHS tarballs are
  the source of truth.
- SIMH channel semantics differ per path: ^E stops the sim **only** on a local-tty
  console; it's an inert data byte on a telnet console, and a suspend-to-command-mode on
  the remote console; scp's `sim>` lives on stdin, never on the console socket. Read the
  table in [docs/a1-notes.md](docs/a1-notes.md) before touching console/control plumbing.
- The SIMH remote-console dialect (the app's control channel): never reply to telnet IAC
  (the session goes permanently silent), lead every command with a sacrificial space
  (multi-command-mode typeahead loses its first byte), and prove completion with
  output-anchored `echo` markers (`"\nMARKER"`) — the `sim>` prompt prints lazily.
- In-app SIMH listeners must rotate ports per launch: tmxr binds without `SO_REUSEADDR`,
  so a quick relaunch hits the previous incarnation's TIME_WAIT pairs ("bind error 48")
  and scp runs with **no listeners**; a failed console re-attach also leaves the restore
  path one `cont` from a NULL-deref segfault (`_tmxr_activate_delay`) — `save` persists
  `UNIT_TM_POLL` in the unit's dynflags, but never the `uptr->tmxr` pointer that only a
  *successful* `tmxr_attach` sets, and restore reports success either way (filed upstream
  as [open-simh/simh#576](https://github.com/open-simh/simh/issues/576)). Don't "fix" the
  crash with `reset tti` — that zeroes the guest-configured CSR and V8 stops seeing
  console input.
- **A mux connection dropped across save/restore is by design; only the segfault was
  ever a bug.** Upstream's answer on #576 (markpizz, 2026-08-11): a device is restorable
  only to the extent its whole state lives in its `REG`s, and TMXR's per-line connection
  state lives in the simulator's *host* memory, which no `REG` describes — the most
  `restore` can do is replay the ATTACH string. So `restore -D -Q` plus manual attach is
  **the correct way to use the mechanism**, not a workaround. The general rule is worth
  more than the case: state held inside the *guest* survives a snapshot (it is just RAM),
  state held inside the *simulator* does not. Hence upstream's escape hatch — reach the
  guest over TCP and let its own stack own the session, which V8 can do (it ships
  `usr/src/cmd/inet/etc/telnetd.c`) — and hence why it is no use here: the far end of our
  DZ is a second emulated CPU in the same process, so we checkpoint **both** machines and
  keep the wire stateless.
- A `state.sav` is only disk-consistent while the machine stays paused — the app deletes
  it the moment the machine runs again; unclean kills cold-boot and V8's autoboot fsck
  self-heals (with a telnet console V8 autoboots straight to `login:`, no single-user
  stop).
- **`restore` must be `restore -D -Q`, with every unit attached by hand.** A plain
  `restore` re-attaches each saved unit in device order to the filename in the snapshot
  — and for a mux that "filename" is the *previous launch's port*, which the terminal
  connection that was live a moment ago still holds in TIME_WAIT (tmxr binds without
  `SO_REUSEADDR`). The bind fails. That alone is survivable; scp.c's loop is not: it is
  gated on `r == SCPE_OK` and never resets `r`, so the **first** failure silently skips
  **every remaining attach** — and the DZ precedes RP0 in device order, so the machine
  comes back **with no disk**. Still true of open-simh at `scp.c:9065` (verified
  2026-08-11); **fixed in `simh/simh`**, which attempts every attach and reports each
  failure as it happens — the one concrete cherry-pick target from that codebase. The console still answers (the kernel is in memory) and
  the shell still echoes `# ` from memory, so it presents as a terminal that has gone
  quiet, which is nothing like the truth: `exec` SIGKILLs (`Killed`), `login` never
  reaches a shell, getty is stuck. Proof either way:
  `tools/restore-attach-probe.py` holds the saved port and prints `RP0 ... not attached`
  vs `attached to v8.disk`. Attach the **disk before** the restore and the **DZ after**
  it — that order matters, because `dz_attach`'s `lp->rcve`/DTR fixup only runs when
  CSR_MSE is already set, i.e. against *restored* registers.
- **A restored session has nothing left to say, so the terminal must ask — and it must
  ask *late*.** getty prints its banner and `login:` exactly once, when it starts, then
  blocks in `getname()`; a logged-in shell prints nothing unasked at all. A cold boot
  therefore gets a prompt for free and a restore never does, so the terminal's own CR
  nudge is the *only* thing that makes a resumed far end speak. Three ways to get that
  wrong, all of which shipped at some point and all of which look identical to the user
  (a picture with a dead keyboard): sending it only when no saved screen was restored;
  skipping it because the screen was already the right size, so the whole
  post-self-test block was conditional on a resize; and keying it to a raw step count —
  20M steps is ~1.0 s at the default 2× clock, but the 5620's self-test does not finish
  until ~1.2 s, so V8 answered into a terminal that was still testing itself. Gate every
  start-of-session action on the firmware reaching its idle PC window, never on a timer
  and never on the resize.
- NWConnection to loopback parks in `.waiting(ECONNREFUSED)` forever when it races the
  listener (no reachability change is coming) — treat `.waiting` as a failed attempt and
  redial fresh.
- **Every DZ line gets its own listen port; never one mux-wide listener.**
  `tmxr_poll_conn` hands a connection on the shared port to the next *free* line, so the
  tty a session lands on would depend on the order tabs were opened — and `/.profile`
  picks TERM from `` `tty` ``, so connection order would decide what terminal V8 thinks
  you are. `att dz Line=N,...` per line makes it a property of the port dialled
  (`Machine.dzPort(_:)`); `sim_tmxr.c` supports this explicitly and `tmxr_attach_ex` sets
  the polling unit on whichever attach comes first, so no mux-wide attach is needed.
  `-m` rides the **first** attach only — modem control is device-wide (`dz_mctl`).
- **`Machine.start()` must guard on its own flag, not on `phase`.** It only *schedules*
  `bringUp()`, so two windows appearing in one runloop turn both saw `.idle` and both
  spawned a SIMH thread — two VAX-11/780s in one process, binding the same ports and
  attached to the same `v8.disk`. It crashed immediately, which was the lucky outcome.
- The app's UI is **nine sessions in windows grouped by terminal shape** — forced by the
  missing `TIOCGWINSZ`, not chosen. A session owns its `TerminalView` (scrollback lives
  there, so SwiftUI owning it makes a tab switch a silent `clear`), the console session
  starts before the VAX so the boot transcript has somewhere to land, and a window holding
  one terminal hangs up its line when closed. Full record, including the traps:
  [docs/ui-redesign.md](docs/ui-redesign.md).
- **The app's SIMH needs THREE defines to have a network, and each missing one
  fails differently.** `USE_NETWORK` is the master switch: without it
  `sim_ether.c` compiles a stub `eth_open` returning SCPE_NOFNC, so
  `attach il nat:` answers **"Command not allowed"** while the NI1010 is
  compiled in and autoconfig cheerfully reports `il0` — a guest that boots and
  cannot pass a packet. `HAVE_SLIRP_NETWORK` then selects the `nat:` transport;
  with only that one, all of `slirp/` compiles and links and *nothing
  references it*, so the linker drops every object and the error is unchanged —
  the archive reads as correct under `nm` (56 slirp symbols) while the app
  binary has none. **Check for an UNDEFINED `_sim_slirp_open`, never a defined
  one.** `USE_READER_THREAD` is not optional either: `eth_open` →
  `eth_reflect` → `eth_check_address_conflict_ex` drains with
  `do { eth_read(...) } while (recv.len > 0)`, which ends only on a read that
  returns nothing, and polling SLiRP synchronously it never does — SIMH spins
  at 100% *inside* `attach_cmd`, `boot.conf` never reaches `run 2`, and the app
  comes up with no guest at all. Upstream's own vax780 command line carries it.
  Not `USE_SHARED` (that means dlopen'd pcap and force-defines
  `HAVE_PCAP_NETWORK`). iOS also needs `apply-iosnet.sh`: `sim_ether.c` calls
  `gethostuuid(2)`, which iOS lacks, and only the *device* slice fails — macOS
  and the simulator build it happily.
- **A netfs mount is released by `nmount -u <id>`, never by `umount(8)`.** It is
  a `gmount(2)` object keyed by **device number** (`gmount(RMFSTYP, id*256, 1,
  0, 0)`), and umount knows only ordinary block filesystems, so it answers a
  bare `/n/macos: I/O error` — which reads as the connection being at fault and
  is not: it fails identically on a *live* mount. Unmounting by id needs
  neither the connection nor the mount point, which is exactly why it still
  works after the far end has gone. Consequence for the app: a snapshot taken
  with a share mounted comes back with a mount that cannot speak *and* cannot
  be cleared, because the mount table is guest RAM and survives while the TCP
  connection is host state and does not — so the shares are dropped **before**
  the save and remounted after the restore (`SessionStore`).
- `libsimh` compiles without `SIM_ASYNCH_IO`, so `set noasynch` errors ("Command not
  allowed") and is unnecessary — the V8-safe synchronous mode is a build-time guarantee.
  **The desktop `work/opensimh/BIN/vax780` is the opposite**: it *is* built with async
  I/O, so every hand-written config must open with `set noasynch` (verify with
  `show asynch`). Omitting it looks like a hardware fault, not a config error —
  `hp06: hard error er1=5<RMR,ILF>` on both drives and silent file loss — and only
  once two units have overlapping transfers, so light I/O hides it entirely.
- **The 2026-08-10 rename left build caches pinned to the old absolute path**, and they
  fail in ways that do not mention it. `netfs/.build` gave *"missing required module
  'SwiftShims'"*; `libsimh/build` gave a CMake cache-directory error that only appears in
  `libsimh/build/cmake-*.log`, so the top-level script just exited 1 with the last line
  being `apply: done`. Both were fixed by deleting the directory. If a build fails
  strangely and the repo has not changed, check for `ipad-v8` first:
  `grep -rl ipad-v8 <builddir> | head`. Still present in `app/build` and
  `tools/dmdbridge`, both of which build correctly anyway; clear them only if they start
  misbehaving.
- macOS gotchas (A3): our preferences type `Settings` **shadows SwiftUI's `Settings`
  scene** — write `SwiftUI.Settings { … }` or the scene silently resolves to the wrong
  initialiser. Exec'ing the app binary directly gets **no WindowServer connection** (it
  boots V8 and binds sockets but never shows a window) — test with
  `open -n Edition.app --stdout <log>`. The Mac deliberately suspends **only on quit**
  (via `applicationShouldTerminate` + `.terminateLater`, since the save handshake is
  async), never on hide: nothing reclaims the CPU there and a long build should keep
  running.
- Integer ("Crisp") screen scaling must be allowed to fail: forcing a minimum factor of
  1 makes small windows request a screen *larger* than the space available. Below 1:1
  there is no integral scale — fall back to filling.
- **Host↔guest file transfer (Track B): one role per disk unit, 512-byte raw transfers.**
  Full recipe in [docs/media-exchange.md](docs/media-exchange.md). SIMH has no
  host-directory passthrough of any kind, so everything goes through emulated media.
  The **tape route is dead**: V8's `ht` driver does a 16-bit read of a Massbus register
  that `mba_rdreg` rejects (tolerated only in SIMH's VAX-750 build), panicking the
  kernel with `panic: mchk`; classic 3.12-5 has the same guard, and `installV8` only
  avoids it by running under 4.1BSD. Use `rp1` as a **raw-only courier**
  (`/dev/rrp1a` = `c 4 8`) with the work area on `/usr` — mixing raw and buffered I/O
  on one `hp` unit corrupts the filesystem *after* everything appears to work. Raw
  transfers were believed to need **512-byte** records, on the strength of 4 KB+
  writes failing with `er1=5<RMR,ILF>` after one record. **That rule is wrong and
  is now retired.** `er1=5` was the signature of a missing `set noasynch`, and
  `work/rawwrite.exp` — the script the rule came from — never set it.
  `tools/rawsize-probe.exp` re-tested it with `set noasynch` on, writing to
  `/dev/rrp2a` and reading each one back:

	512 B    4+0 records in/out   RS-512-ok
	1024 B   4+0 records in/out   RS-1024-ok
	4096 B   4+0 records in/out   RS-4096-ok
	10240 B  4+0 records in/out   RS-10240-ok

  Every size byte-identical on readback, including the two that were supposed to
  be impossible. Stage 8 is the same result at scale and had been proving it all
  along without anyone noticing: `mkfs` writes `BSIZE` — **1024** — through the
  raw device, and the disk it builds fscks, mounts and boots. **The `tar`
  blocking-20 trap is independent and still real**: it silently drops everything
  past the first 10,240 bytes and still exits 0.
- **V8's libc is more ANSI than its reputation; its compiler is not.** Measured with
  `tools/v8-libc-probe.exp` (`nm /lib/libc.a` on a scratch boot): `strchr`, `strrchr`,
  `strpbrk`, `strspn`, `strcspn`, `strtok`, `memcpy`, `memcmp`, `memset`, `qsort` and
  `/usr/include/string.h` are all **present**; `strtol`, `strtod`, `strstr`, `memmove`,
  `atexit`, `vprintf`, `vfprintf` and — counter-intuitively — **`bcopy`/`bzero`** are
  not. So do *not* "port backwards" to `index`/`bcopy`: that is the wrong direction and
  `bcopy` is the one that will not link. The genuine wall is `/bin/cc` (1985), which
  rejects a prototype outright (`expected a NAME in list` / `saw TYPE`); there is no
  `stdlib.h`/`stddef.h`/`unistd.h`, and variadics use `varargs.h`. **V10 differs on both
  counts** — its `libc/gen` adds the missing seven, and its tree ships `cmd/lcc` (ANSI C,
  with a `gen2/vax-v9` back end and an `lccmkfile` in `sys/inet`) plus `cmd/gcc`.
- **Never write a sockets layer for Research Unix — it already has TCP/IP.** V8 carries
  `/usr/include/sys/inet/` (`in.h`, `ip.h`, `tcp.h`, `tcp_user.h`, `udp_user.h`,
  `mbuf.h`, its own `socket.h`, …) and `/usr/lib/libin.a`; V10 has the sources in
  `sys/inet/` — including `tcp_ld.c`/`ip_ld.c`/`udp_ld.c`, i.e. the stack is built as
  **stream line disciplines** — with the userland in `ipc/internet/` (`routed`, `arp`,
  `netstat`, `gettable`/`htable`, `tcpconfig`, `interlan.c`) and `ipc/libin/`. The API is
  `open("/dev/tcpNN")` then a `struct tcpuser` written to the fd — Plan 9's `/net` model,
  predating Plan 9. N3 already drove it end to end.
- **Three things stand between you and a TCP connection out of V8**, none of them
  obvious. `tcpconfig` must push the TCP line discipline onto `/dev/ip6`
  (`./tcpconfig /dev/ip6 &`, exactly as N3 pushed UDP onto `/dev/ip17`) — without it
  `open("/dev/tcp01")` succeeds, the `tcpuser` write succeeds, and the connect blocks
  **forever with no diagnostic**, because there is nothing underneath the device. The
  minor must be **odd**: `tcp_device.c` refuses an even one whose socket is not already
  active (`if((dev&01) == 0 && (so->so_state&SS_ACTIVE) == 0) return(0);`) because even
  minors are the accept side — libin's `tcp_sock()` encodes this as
  `for(n = 01; n < 100; n += 2)` and never says why. And the guest reaches the host at
  **10.0.2.2 = 127.0.0.1**: SLiRP rewrites every address inside its virtual network to
  the host's loopback (`tcp_fconnect`, *"It's an alias"*), so nothing needs forwarding
  and the same mechanism works inside the iOS sandbox.
- **netfs does not run over a byte stream unmodified, and "there is a stream driver"
  is not enough.** `usr/src/netfs/README` says so — *"you'll have to fix things"* — and
  four separate Datakit assumptions live in `istread()` (`sys/streamio.c`), which is
  netfs's *only* caller in the kernel and therefore safe to change: it discards the
  unread remainder of a block, returns short when a queue momentarily empties, waits
  forever for the `M_DELIM` a zero-length Datakit write used to produce (so every EOF
  hangs), and sits behind a stream head only **512 bytes** wide
  (`strdata`; `q->count` is bytes, and `tcpdisrv` only drains
  `while((q->next->flag&QFULL) == 0)`). Each is invisible until the one before it is
  fixed and each presents as the same bare `EIO`. `tools/drive-streamfix.sh` applies
  all of it. Also **`doupdat`'s clock skew is applied backwards upstream**
  (`x->ta += dtime` where dtime is `client - server`), harmless between machines whose
  clocks agree and a century of error against a V8 that thinks it is 1976 — subtract.
- **The NI1010 must CHAIN a received frame across receive buffers**, and getting that
  wrong looks like nothing at all. `ill.c` subtracts each buffer's programmed byte count
  from `ilr_length` and waits for another interrupt while any remains, supplying the next
  buffer from inside `ilrint` (`ILOUTSTANDING` is 1). `allocb()` caps a block at
  `rbsize[3]` = **1024 bytes**, so every frame larger than that needs two buffers — and
  our model delivered one and truncated, leaving the driver waiting for an interrupt that
  never came. Not a dropped packet: the receive path *stops*, and every layer above
  reports a timeout on something it never saw. It survived N2, N3 and most of N6 because
  nothing before netfs ever sent a frame over 1024 bytes. Fixed by `il_rxpump()` in
  `libsimh/patches/pdp11_il.c`. The general form is worth keeping: **a limit you measure
  through an emulator is a property of your emulator until proven otherwise** — this one
  spent a day written up as a netfs reply-size bound.
- **The `/n/src` share is LIVE, so never edit `v8/` while a build is running.**
  netfsd serves the working tree directly and the guest compiles straight off it, so
  an edit to `v8/mk/build1.sh` lands in a run already in flight — that is excellent for
  iteration and lethal for a two-hour build. Editing `build1.sh` mid-run once made
  stage 3 fail on all fourteen components (`Don't know how to make /b/tools/lib/as`),
  because the new script wanted a file that run's stage 1 had not been told to install.
  During a run, `docs/`, `CLAUDE.md` and brand-new files are safe; `v8/**` and the
  `tools/*.sh|*.exp` that bash is still reading are not.
- **V10 IS THE OPPOSITE, AND THAT IS THE TRAP: its source disk is a BUILD
  ARTEFACT, so regenerating a makefile changes nothing the guest sees.** There is
  no netfs on V10, so `tools/v10-srcdisk.sh` *copies* `v10/mk/gen/` and
  `v10/src/` onto an RA81 and every stage reads them from there as `/n/v10/mk`
  and `/n/v10/ours`. Run `v10/mk/mkdep.py`, commit, and start a stage: it boots,
  compiles, asserts and reports — **against the previous generation of the build
  description, with no symptom.** `libc.ord` went from 261 names to 260 and three
  assertions kept failing on a build that was already correct. Host and guest
  then disagreed about the member list, so the summary mixed a 260-member total
  with a difference count read off a 261-member walk and printed a
  byte-identical figure that was true of neither. Same shape as the app's *"it is
  in the golden, it will arrive on Reset" is not shipping it*, and the same
  answer: `tools/srcid.sh` stamps `<image>.id` at build time and both stages
  refuse a disagreeing one. `mkdep.py --check` is **not** this check — it proves
  the repo's generated files are current and says nothing about the disk's.
- **A generated list read by 1985 shell must hold exactly one kind of thing.**
  `v8/mk/gen/destdirs.txt` briefly held both the directories stage 8 copies and
  the 458 exact installed paths `mkcarry.py` needs, told apart by a leading tab
  — and `builddisk.sh` reads it as `` for d in `grep -v '^#' destdirs.txt` ``,
  which splits on `IFS`. Tab is in `IFS`, so the marker was gone before the
  shell saw a word and `mkdir` got all 458: `/bin/sh`, `/bin/cc`, `/etc/init`
  and 96 more became empty **directories**, and the copy pass skipped each
  (it is guarded by `test -d $DEST/$d`, false for a file). Carried files were
  untouched, so `/bin` came out with its Bell Labs binaries intact and
  everything we build missing. The disk mounted, `fsck`'d clean, walked
  4,507 files — and stopped dead after autoconfig with the CPU idle, because
  there was no `/etc/init` to exec. Exact paths now live in
  `gen/destfiles.txt`; never merge them back.
  **And the check that should have caught it compared paths, not types**: a
  directory named `/bin/sh` satisfied a search for the file `/bin/sh`, so
  `retire-check.py` said UNIQUE 0 about an unbootable disk. It now compares
  the inode type — same image, 424 failures. *A containment check that ignores
  inode type is not a containment check.*
- **V8's `ld` is single-pass only without a valid `__.SYMDEF`** — archive member order
  is *not* unconditionally correctness. `getfile()` returns 1 (no table of contents),
  2 (current) or 3 (stale, because the archive's mtime is newer). Case 2 runs
  `while (ldrand()) continue;` under the tape's own comment *"you can get away with
  backward references when there is a table of contents!"*; cases 1 and 3 fall back to
  one sequential pass **and warn on stderr naming `ranlib`**. Consequence worth
  remembering: **any rule that copies an archive must re-`ranlib` it at the
  destination**, since `cp` bumps the mtime and that alone demotes a good archive to
  case 3. `lorder | tsort` on libc is defence against that, not a hard requirement.
- **`ar` BUNDLES SOURCE AS WELL AS OBJECTS, AND THIS HAS NOW CAUGHT ME REPEATEDLY.**
  `ar` predates `tar` being everywhere and was the ordinary way to package *any*
  file set, so on this tape a `.a` is **not** evidence of a link library. The
  naming convention distinguishes them and nothing else does: **`X.c.a` is an
  archive of `.c` files; `libX.a` is an archive of `.o` files.**
  `libplot/libplot/plot.c.a` holds `subr.c` and `whoami.c`; `libplot/libpen/`
  carries *both* `libpen.a` (21 objects) and `pen.c.a` (22 sources).
  - **It is the tape's own designated build route for the whole libplot family,
    not a stray artefact.** Every one of those makefiles reads:

	lib4014.a: tek.c.a
		mkdir xplot
		cd xplot;ar x ../tek.c.a
		cd xplot;cc -c -O *.c
		cd xplot;ar rc ../lib4014.a *.o

    So `ar x` is step one of the recipe. This is what explains `libtr`, whose
    archive has **30 objects while its directory has 6 `.c` files** — the other
    24 are inside `tr.c.a`, waiting to be extracted exactly as the makefile
    says. Read as "24 members have no source" it looks like tape rot; it is not.
  - **Four libraries have their source ONLY in a bundle** — `lib2621`,
    `libblit`, `libram`, `libplot` — so a survey that reads directories finds
    them empty and concludes `-lplot` cannot be built. It can.
  - **Decide by CONTENT, never by suffix**: read the first member's name.
    `tools/v10-libs.py`'s `ar_members()` returns `objects`/`sources` on that
    test, which is also what stops a fidelity comparison being run against 1980s
    source text and reported as bytes that differ.
  - Two more shapes in the same family, both of which also read as breakage:
    **not every `lib*.a` is an archive at all** (`libdbm` is `mv dbm.o
    libdbm.a`, `libsdb` is `as dbxxx.s -o libsdb.a` — bare objects wearing a
    `.a` name, which `ld` accepts because it reads the magic number and which
    `ar t`/`ranlib` reject), and **an archive's name need not match its `-l`
    flag** (`libtermlib` builds `termcap.a`, installs it as `libtermcap.a`, and
    hard-links `libtermlib.a` to that; `libcurses` calls its archive **`crlib`**;
    `libl` builds `libl.a` beside a prebuilt `libln.a`).
  - **AND `libln.a` IS `libl.a` UNDER THAT SECOND NAME — the tape's own archive
    proves it member for member.** `cmd/pret` and `cmd/struct` link `-lln`, and
    libl's makefile builds and installs only `libl.a`, so `-lln` was being
    reported as a flag nothing in the tarball provides. Reading the prebuilt
    archive answers it: `allprint.o main.o reject.o yyless.o yywrap.o`, which is
    exactly what the makefile puts in `libl.a`. So this is the `libtermlib`
    pattern again — one build, two `-l` names — and it is a *system-layout*
    question the tape settles, not a library we lack. `ALSO_ANSWERS` in
    `tools/v10-libs.py` records it and `sanity()` **compares the two member
    lists** rather than trusting the claim, because a drifted prebuilt would put
    different code behind a `-l` flag and `ld` would find it anyway. Our build
    is installed under the second name; the prebuilt archive stays an oracle and
    is never copied.
- **Patching guest sources: replace whole functions, and rehearse on the host.**
  `streamio.c`'s `stread()` and `istread()` share whole lines verbatim, so
  context-anchored `ed` edits landed in the wrong one and the kernel failed to compile
  at a line number nowhere near the target — while a `sed -n '/^istread/,/^}/p'` of the
  result looked perfect, because it only printed the function that was fine. Anchor on
  the one unique line (`/^istread(ip, addr, count)/`), `.,/^}/d`, insert a known-good
  body; that is also idempotent and repairs prior damage. macOS `ed` runs the same
  script against `work/v8src/` in a second, against ten minutes for boot-and-build.
  Two traps in the guest's own tools: a backup called `streamio.c.orig` is **15
  characters** and fails with a bare `cp: cannot create` (14-byte names apply to *your*
  filenames too), and V8's `grep` is 1985's, so `\|` is a literal and a pattern using
  it matches nothing while looking like it asked a question — use `egrep`.
- **Fourteen bytes, and it has now cost four separate debugging sessions.**
  `streamio.c.orig` (15) failed with `cp: cannot create`; `install-prebuilt.sh` (19)
  with `sh: cannot open`; `toolchain.order` (15) was **truncated silently to
  `toolchain.orde` with a successful exit status**, which is the worst of the three
  because nothing failed at all. Each was fixed and none of them stopped the next,
  so the rule is now a guard rather than a habit: `v10/mk/mkdep.py`'s `put()`
  refuses to emit any generated name over 14 characters, and the file is `tc.order`.
  Anything that generates a filename destined for a guest disk needs the same check.
- The golden image shipped **no `lost+found` on either filesystem**, so an autoboot
  `fsck` needing to reconnect an orphaned inode aborted to a single-user shell instead
  of `login:` ("Automatic reboot failed... help!") — reachable in the app whenever a
  hard kill interrupts a compile. Fixed 2026-08-09 via `/etc/mklost+found` on `/` and
  `/usr`; `work/fix-lostfound.exp` reapplies it if the image is ever rebuilt.
  A run that *is* hard-killed still needs `tools/fsck-repair.exp`: the autoboot
  `fsck -p` can't answer its own questions, so it aborts to single-user and the machine
  never reaches `login:`. **In that one case** drop to `sim>` with ^E and quit, which
  avoids syncing the stale in-core root superblock back over `fsck`'s repair.
- **`/etc/halt` is the clean shutdown, and it works.** This file used to say the
  opposite, on the strength of one test with `/etc/reboot **-n**` — and `-n` is
  `RB_NOSYNC`, the single flag that skips the part you wanted. `boot()`
  (`usr/sys/sys/machdep.c:477`) does `update()`, prints `syncing disks... `, sleeps
  five `lbolt` ticks for the I/O to drain, prints `done`, and only *then* looks at
  `RB_HALT`: set, it prints `halting (in tight loop)` and spins at IPL 31; clear, it
  falls through to the console-subsystem reboot request the simulator does not
  implement, which is where *"Reboot request failed"* comes from. So the failure is
  the **reboot** branch and the sync has already happened either way — but
  `/etc/halt` (RB_HALT, `usr/src/cmd/halt.c`) is the one to use, because it stops
  deterministically and SIMH reports the spin as `Infinite loop`, an
  output-anchored marker. The proven sequence is `tools/boot-newdisk.exp`'s, and it
  passes on every run:

	sh "cd /; sync; sync"     ;# flush from userland first
	sendline "/etc/halt"      ;# boot() syncs again, then spins
	must "Infinite loop"      ;# SIMH sees the tight loop at IPL 31
	simh "quit"               ;# disk is clean; no snapshot needed

  **Suspending is not halting, and the app is right to do both differently.**
  `Machine.background()` sends ^E then `save state.sav`: it snapshots a *running*
  machine, and disk+snapshot are consistent only as a **pair**. That is the
  correct behaviour for **quit** and for iOS backgrounding — it is what buys
  instant-on, and the pair is safe as long as both are kept. Do not "fix" quit
  to halt instead. **Halting is user-initiated**: a menu action, or Reset.
  The failure mode to avoid is breaking the pair — deleting the snapshot and
  keeping the disk leaves neither state, and the disk has unflushed buffers.
  Two traps if you ever do wire a halt to a control: `/etc/halt` has to be typed
  at a shell, and the **console is read-only behind a lock with no shell on it**
  — the root login is `tty01`. Sending it to the console types into nothing,
  times out, and leaves the machine stopped with neither a snapshot nor a halt.
- **`hp` is block major 0 and char major 4** — `bdevsw` and `cdevsw` are unrelated
  tables and the indices don't match (`sys/dev/conf.c`). Block major 2 is `up`, a
  Unibus disk our machines don't have, so `mknod /dev/rp1g b 2 14` builds a node into
  `upstrategy` on absent hardware and `mount` dies on a wild pointer (`type 8 ... code
  xae50d144`, `panic: trap`). It cost two runs because `fsck` had just passed on that
  exact filesystem through the **raw** node, which was right — so a verified filesystem
  panicking on mount reads as a mount-table bug. **When raw works and block doesn't,
  suspect the majors first.** Minor is `drive<<3 | partition`, and `mknod` does **not**
  replace an existing node — it prints "File exists" and leaves the old one, so a bad
  node outlives the fix and the next run fails identically with a correct script.
- **RP06 partition `a` is 15,884 *sectors*, not blocks** (`hp6_sizes`, `sys/dev/hp.c`):
  `a` 15884, `b` 33440, `c` 340670 (whole disk), `g` 291280 from cyl 118. `mkfs` lays
  its free list down from the top, so an oversized filesystem fails on its *first*
  write ("write error: 39968") rather than partway. `mkfs n` gives `n/25` i-list blocks
  at 16 inodes each — state the inode count, since V8 fixes it at `mkfs` time and
  exhausting it presents as `mkdir` answering "cannot access .".
- **The guest's year comes from the root superblock, not the TODR.** `clkinit()`
  (`sys/sys/machdep.c`) takes only the position-within-year from the TODR; a superblock
  time under `5*SECYR` trips *"preposterous time in file system"*, whose fallback is the
  hardcoded `6*SECYR + 186*SECDAY` — mid-1976 exactly. So `attach TODR` fixes nothing.
  And `date(1)` can't set the year out of it: Berkeley's 1980 `date.c` does a bare
  `year += 1900` on two digits, so `26` means 1926. `v8/usr/src/cmd/date.c` now carries
  the 69/70 window; set the time with `-u` and UTC digits (`stime(2)` takes GMT), then
  `sync` so the superblock carries the year forward. Safe while running — `cron`'s
  `slp()` resynchronises on any delta over an hour.
- **Every guest harness sources `tools/v8drive.exp`; none rolls its own.** Three
  scripts (net-selftest, netfs-latency, show-fetch) each grew a private "log in
  and run a command" built on matching a PS1 prompt, and all three hung — while
  `boot-newdisk.exp`, which matched markers, never failed once. The library now
  holds the boot, the login, the marker protocol, the safe bail and the clean
  halt, and all four harnesses use it. Two traps it exists to make unrepeatable:
  **`spawn` inside a proc sets `spawn_id` in that proc's scope**, so every other
  proc then talks to the global default, which is stdin — expect reads EOF at
  once and reports *"simulator exited"*, so a scoping bug arrives dressed as a
  simulator that started and died (`global spawn_id` fixes it; boot-newdisk
  escaped only by spawning at top level). And **a bare `exit` closes the spawn**,
  killing a running guest — the one thing this project never does. Dry-run any
  change under `tclsh` with the interactive verbs stubbed before spending a boot
  on it.
- **A command that takes the tty needs `v8_run`, not `v8_sh`.** `v8_sh` sends
  the command and its `echo $M+` marker together, so against `telnet` the marker
  is read by telnet and transmitted to the far end — and the script then waits
  forever for a string nobody will print. `v8_run` waits for the program's own
  closing output and re-syncs with a fresh marker afterwards. **It is also the
  fix for a corrupted LIST**: a `cat` of two hundred lines under `v8_sh` comes
  back with the marker's echo spliced through it character by character, so
  stage 2's first member comparison reported names like `fchmodo.o`,
  `closec.o` and `fioroead.o` — real output with echo mixed in, which then
  defeated every count made from the log.
- **`v10_run` FIXES THE BODY OF A DUMP AND NOT ITS FIRST LINE, so never anchor
  a host-side counter at `^`.** The splice above is bounded but not eliminated:
  `v10_run` sends the command and then reads, so the tty echoes the tail of what
  was typed *into the first line of output*, every time. `MISS atof.o` arrived as

	MMISS atof.o

  `grep -oE '^MISS ...'` dropped it, stage 2 reported one missing member where
  there were two, and this file recorded the wrong ceiling for a week.
  **Match the token unanchored** — but only after making sure the token is not
  in the *question*: `echo SAME $name` puts `SAME yacc` in the log whatever the
  answer, so unanchored matching would count every comparison as a match. Both
  halves are needed and they fix different faults: spell the verdict through a
  guest variable (`echo $S $name`) so the echo carries no literal token, *then*
  match unanchored so a splice cannot hide the answer. Same rule as the marker
  discipline, applied to data instead of markers.
  **And cross-check the count against something that did not come from the same
  parse**: the guest's own `all 261 members compiled` assertion had the right
  answer, four lines above a summary that contradicted it, and nothing in the run
  compared them. `tools/v10-stage2.sh` now refuses to print a measurement when
  those two disagree.
- **A FULL V10 FILESYSTEM HANGS INSTEAD OF FAILING, SO NO GUEST-SIDE PROBE CAN
  GUARD AGAINST IT.** `lsys/fs/alloc.c` prints `file system full` and then
  **sleeps**, waiting for space that is not coming — so the process blocks in
  the kernel rather than getting an error, and every guest-side check breaks the
  same way: a `dd` or `cat` probe blocks in the identical `alloc()` sleep as the
  thing it is meant to protect, and a count-consecutive-failures detector never
  counts because nothing fails. It presents as a simulator at 100% CPU with a
  kernel message every few seconds and a run that neither progresses nor dies.
  **`tools/v10-free.py` is the answer** — it reads the superblock out of the
  image file host-side, before the boot, on the same argument `tools/v8fs.py`
  was written from. Two traps in writing it: **`s_tfree` is a hint, not the
  truth** (`alloc.c` assigns `fp->s_tfree = 0` on failure under Bell Labs' own
  commented-out *"but it would be wrong FIX"*), so count the **bitmap**; and a
  struct offset computed from a header is a guess until something confirms it,
  so the tool refuses to answer unless `struct filsys` computes to exactly one
  4096-byte block, `s_fsmnt` is printable, and the popcount matches `s_tfree`.
  - **What filled it was an unbounded log, not a full image, and I blamed the
    image twice.** A compile whose output went to `>> u.log` with no limit wrote
    the same `Can't find include file config.h` until 120 MB was gone — while
    `/usr` had **111.8 MB free** the whole time, measured. The transcript showed
    the message three times only because the *display* was `sed -e 3q`. The fix
    is structural: pipe the compiler through `sed -e 40q`, so the pipe closes
    and it gets EPIPE. No counting, no truncation, and a faster loop cannot
    outrun it. Keep the exit status by having the subshell `echo "CCST=$?"`
    through the same pipe — a pipeline's status is `sed`'s and 1985 `sh` has no
    `PIPESTATUS`.
- **A GUEST-SIDE SCRIPT THAT EXITS WITHOUT ITS END MARKER STRANDS THE DRIVER.**
  `v10_run` sends a command and waits for the program's own closing output, so a
  script that `exit`s early — a failed probe, a missing tool — leaves the driver
  blocked for its whole timeout with a simulator running and no console to reach
  it. "A harness must terminate itself; needing to kill one is the bug" has to
  hold *inside* the guest too: every top-level exit prints the marker. An exit
  inside a `sed | while` pipeline is safe, because it ends only the subshell and
  the tallies still run.
- **`bash tools/norun.sh` IS NOT A CHECK — it is a library to source.** Running
  it defines two functions and exits 0 silently, which reads exactly like a
  pass. Use `source tools/norun.sh; no_other_sims` (or just let the harness's
  own `no_overlap` do it — every one of them already calls it). This wasted two
  launches while the real guards were working perfectly: `v10-srcdisk.sh`
  refused with *"norun: a simulator is already running"* and `v10-compile.sh`
  refused on a stale srcid, and both refusals were misread because a 42/42 was
  read out of the *previous* run's log file. **When a harness reports success,
  check that the log you are reading was written by the run you just made.**
  - **AND THE SAME MISTAKE FITS INSIDE A WAIT CONDITION**, where it is worse
    because it corrupts the schedule rather than one reading. Waiting for a
    background run with `until grep -q "v10-compile exit" work/compile-run.log`
    returns **immediately** when that file still holds the previous run's
    output — so the next command read a complete, consistent, forty-minute-old
    report of a run that had not started, while the real one was nine assertions
    into a source-disk rebuild. Wait on something the invocation itself created,
    or truncate the log before starting; never on a predicate a stale file can
    satisfy.
- **A RE-RUN OF AN INCREMENTAL `make` IS NOT A PROBE OF THE BUILD.** V10's `ld`
  **writes its output file even when symbols are undefined** — it reports them
  and clears the execute bits — so a failed link still leaves an `a.out` newer
  than its prerequisites. A diagnostic added to re-run a failing target
  unfiltered therefore printed

	cp comp /usr/s3/lib/ccom
	RAW3RC=0

  for a component that had just failed with `Undefined: _atof`: make skipped the
  link entirely and ran only the install step, whose status is what got printed.
  Reading the return code alone would have closed the bug as nonexistent, and
  the probe *installed the broken binary* on its way. A probe that can report
  success for a failed build is worse than no probe — "it only prints things"
  is not the same as "it cannot lie".
- **`expect` has three spellings and two of them fail silently, in opposite
  directions.** Measured on expect 5.45, each variant its own process with an
  `after` watchdog:

	expect -timeout 15 -- "sim>" {} timeout {}       CORRECT
	expect { -timeout 15 "sim>" {} timeout {} }      never times out
	expect -timeout 15 { "sim>" {} timeout {} }      never MATCHES

  The third is the dangerous one and `exp_internal 1` names it in one line:
  **a braced body following a flag is taken as ONE glob pattern**, braces and
  action bodies included — `does "death\r\n" match glob pattern " death {set
  halted 1} timeout {...} "? no`. Expect only re-splits a braced body into
  pattern/action pairs when that body is the command's *only* argument, which
  is why `v8_must`/`v10_try` have always worked. Inside the braces the flag is
  honoured with **two** pattern pairs and ignored with **one**, so the middle
  form appears to work wherever it was first tried. Both cost real runs: the
  middle form held two completed stage-1 runs at `sim>` with the guest already
  halted and the disk already consistent, and "converting to the third form"
  as the fix made every teardown terminate on time and stop matching `death`,
  so the halt path fell through to its `^E` fallback on a machine that had
  halted perfectly. **A run that ends 120 s late looks like a slow machine,
  not a broken pattern.** Use the flat form; `tools/v10drive.exp` carries the
  measurements.
- **THE DEADLINE PATH LEFT AN ORPHANED SIMULATOR SPINNING AT 98% OF A CORE, AND
  `close` IS WHY.** `v10_reap` is `close` plus `wait -nowait`, and **close only
  ends the simulator if the simulator is READING its console** — a guest wedged
  in a netfs read is not, so SIMH never sees the EOF. `v10_expired` then ran
  `exit 3` and left it behind. Measured 2026-08-20 after a `v10-netread` run hit
  its 3600 s deadline: `vax780` pid 83844, **PPID 1**, 97.9% CPU, still holding
  its disk image, with no pty left to reach it through — so nothing but a signal
  could stop it, which is exactly what the rule below forbids. The bug was in the
  deadline path, not in the response to it. `v10_expired` now sends **^E then
  `quit`** (bounded, non-fatal, the same fallback `v10_halt` already uses) before
  reaping. *A watchdog that cannot stop what it is watching is not a watchdog.*
  - **And the run was mis-sized, which is what fired the deadline.** Seven files
    × 3 passes × 2 readers is 42 verdicts, and at ~7 s a netfs request that is
    ~150 s a verdict — 6300 s against a 3600 s bound. **A probe that cannot
    finish inside its own deadline is badly sized, not unlucky**; the list is
    four files now (one per interesting block count, plus the historical
    casualty) and the bound is 5400.
  - Only a **clone** was ever at risk, which is the clone rule earning its keep
    for the third time: the harness had already declared that image damaged, all
    three baselines were verified untouched before and after, and `lsof` confirmed
    the orphan held nothing else.
- **A harness must terminate itself; needing to kill one is the bug.** A run
  that hangs still *owns* the disk image, so the next round cannot start — and
  overlapping simulators are how images get corrupted here. Both drivers now
  end every path in a `close`-based reap (`close` hangs up the pty so SIMH's
  console read returns EOF; `wait -nowait` never blocks) and carry a watchdog
  built on `after`, which is serviced by `Tcl_DoOneEvent` — the very thing
  `expect` blocks in — so it fires even while an expect waits for a pattern
  that will never arrive. **The watchdog must exceed the legitimate worst
  case**: teardown's own bounded waits total ~740 s, and a watchdog that can
  fire during a real `sync` is worse than the hang it guards against.
- **V10's `umount` takes the MOUNT POINT, not the device, and `/usr` must be
  unmounted or the next boot loses it.** `cmd/umount.c`'s `umountone()` calls
  `funmount(f)` on exactly the string given and then matches it against
  mtab's *file* field, so `umount /dev/ra0c` — which is what V8 takes —
  answers `/dev/ra0c: Invalid argument`. Use `umount -a`, the tape's own
  idiom: `umountall()` walks mtab backwards, "in reverse order in case of
  nesting", so no caller has to name anything and root (absent from mtab) is
  never at risk. **Skipping it is not untidiness.** `/etc/rc` mounts `/usr`
  from `/dev/ra0c` and V10's superblock records that a filesystem is mounted,
  so a halt without unmounting leaves the flag set and the *next* boot of that
  image answers `mount /dev/ra0c on /usr type 0: In use` and carries on into
  multi-user with the root filesystem's empty `/usr` showing through. Nothing
  reports an error after that line: it cost a stage-2 run in which `/usr/s1`
  (stage 1's whole toolchain) and `/usr/bin/ranlib` were invisible, so 255 of
  261 libc members failed to compile and the run read as a compiler problem.
- **`sh` WAS SPECIFIED INTO `/usr/bin`, AND `/usr` IS A SEPARATE FILESYSTEM.**
  `world.link` said `sh /usr/bin default` — `default` meaning *"ours, because it
  had to go somewhere"* — because `where.txt` had **no row for `sh` at all**:
  `commands()` asked *"does `cmd/X` hold `X.c`"* and `cmd/sh`'s main is
  `main.c`. The same blind spot the `MK` comment already recorded for the
  toolchain, and it silently dropped **92 units**. The consequence is not
  cosmetic: `/etc/init` execs **`/bin/sh`** (read out of the golden's own
  binary, not assumed) and `/etc/rc` — which init runs *through* that shell — is
  the four-liner that mounts `/usr`. So a shell only in `/usr/bin` does not
  exist at the moment it is needed: V8 stage 8's disk that *"walked 4,507 files
  and then stopped dead after autoconfig with the CPU idle"*, on the Tenth
  Edition.
  - **The fix is to READ what the tape already says.** `mk_paths()` in
    `tools/v10-where.py` scans every unit's own makefile for `cp <name> <dir>`
    and finds **43** rules. Ten commands moved to the directory the tape names
    (`sh make tp kasb` → `/bin`, `config dump` → `/etc`, `diff3 apsend style` →
    `/usr/lib`, `map` → `/usr/maps`) and thirty more kept their directory and
    gained real evidence. Two look odd and are historically right: `diff3`
    belongs in `/usr/lib` because `diff -3` invokes it, and `map` really does
    install to `/usr/maps`.
  - **THE SOURCE TOKEN MUST BE THE PRODUCT'S NAME, which is what separates an
    install from a backup.** `cmd/sh/makefile:37` is three commands on one line
    — `mv /bin/sh /bin/osh;	cp sh /bin/sh;	strip /bin/sh` — of which the
    **first** would answer `/bin/osh` to a scanner reading destinations.
  - **And it caught a second list saying otherwise**: `prebuilt.txt` hardcoded
    `TOOLCHAIN = {as, ranlib, lex, make, sh, sed}` to fill that very hole, and
    the scan contradicts one of the six — it said `sed → /bin` where the tape
    (`cp sed /usr/bin`) and V8's measured disk both say `/usr/bin`. Both
    generators now **halt** on a disagreement, and both guards were proved to
    bite before being trusted.
- **A component list that appears twice will disagree, silently.**
  `v10/mk/mkdep.py` emits `tc.order`, `shutdown.order` and `buildtools.ord`;
  `v10-stage1.exp` also carried `set BUILDTOOLS {ar cmp tail}`. The day `ed`
  was added to the generator the makefile existed, the source disk carried
  `ed.c` and `ed.mk`, and stage 1 built ar, cmp and tail — reporting 42/44
  with `ed edits from a script NO` and no line anywhere saying `ed` had never
  been built. `v10_order` in `v10drive.exp` reads the generated files instead;
  column 2 gives each tool's install path, so the copy loop does not restate
  those either.
- **Driving V8 over the console: markers, never prompts, and never a literal.** The tty
  echoes typed characters as they arrive and they interleave *into* whatever is
  printing, so a marker lands mid-line (`echC3-CASE-clean`) — which defeats a
  `^`-anchored grep exactly as reliably as an unanchored one matches the command's own
  echo. Spell every marker through a shell variable (`echo C3-CLOCK$OK`) so the echo
  carries `C3-CLOCK$OK` and only the result carries `C3-CLOCK-ok`. Keep every line under
  **`CANBSIZ` = 256** (`sys/h/param.h`) or the tty discards it silently, and never wrap a
  command that doesn't return (`/etc/halt`) in the marker helper. Dry-run an expect
  driver under `tclsh` with the interactive verbs stubbed: Tcl only reports a syntax
  error when it *reaches* the command, so a typo in the last block surfaces three hours
  in.
- **The tape's makefiles assume you build in the source directory.** Out-of-tree, off a
  read-only share, three things break and none are visible in-tree: a script invoked
  bare from beside the source (`:yyfix` — and `pcc1/pcc/makefile` writes `./:yyfix` for
  the same script, so the tape contradicts itself); a data file copied by relative name
  (`y.debug.sv`); and a generated file that exists only in the object directory
  (`rodata.c`, written by `:yyfix` as a *side effect* of making `cpy.c`, so it has no
  rule and no file on the share). Also **a command is not a path**: `$(CC)` = `cc` used
  as a *prerequisite* gives `Make: Don't know how to make cc` on every component at
  once, so `cc`/`yacc`/`lex` each need a second `*PATH` macro. Stage-0 tools live at
  `/bin/{cc,as,ld,ar,nm,size,make}`, `/lib/{cpp,ccom,c2,libc.a}`,
  `/usr/bin/{yacc,lex,ranlib}`, `/usr/lib/yaccpar` — there is no `/bin/strip`.
  `cc -B` is a bare `strspl`, so the prefix must name the passes' actual directory
  (`-B$(TOOLDIR)/lib/`), and `as`/`ld`/`crt0.o` have no `-B` equivalent at all.
- **READ A V10 DISK FROM THE HOST TOO — `tools/v10fs.py`, and it is PROVEN
  against the tape rather than reviewed.** `v8fs.py`'s argument applies twice
  over on the Tenth Edition, because a V10 guest is a poor witness about its own
  filesystem: `ls` exits 0 for a file that does not exist, and a full filesystem
  **sleeps** instead of failing. The trap is that a block address has **two
  encodings**: the inode packs 13 addresses at three bytes each (`l3tol`, whose
  **vax** arm is three bytes little-endian with a zero high byte, where the
  pdp11 arm of the same file packs the identical bytes in a different order),
  while the **indirect blocks hold full 4-byte `daddr_t`** — `bmap()` reads them
  as `b_un.b_daddr` sized `BSIZE/sizeof(daddr_t)` = 1024. Constants:
  `lsys/sys/ino.h` (64-byte dinode), `lsys/sys/dir.h` (DIRSIZ 14, so 16 bytes),
  `NADDR` 13 (`lsys/sys/inode.h:12`), `itod`/`itoo` (`param.h:86`), `fsbtodb =
  b*8` (`param.h:88`).
  - **The proof is nine binaries byte-identical to the tape's own prebuilt
    copies** — `sh ls ps make sed diff pr test as` — extracted from the golden
    with no simulator. `as` at 57,203 bytes spans fourteen blocks, so it goes
    through the single indirect; that cannot come out right unless `itod`,
    `itoo`, the `l3tol` arm, the 3-vs-4-byte split, `NADDR`, `NSHIFT` and
    `NMASK` are *all* right at once. Block accounting against the bitmap's own
    free count agrees to within four blocks of 516.
  - **`prov` is the audit that answers "whose bytes are these?"**, and both of
    its false readings ran in the FLATTERING direction. **An empty file is not
    evidence**: `/etc/mtab` and `/etc/utmp` are zero bytes, every empty file has
    the same sha256, and the tape carries one — so the oracle credited Bell Labs
    with two files this project truncated. **And an archive identical in every
    member read as foreign**: the golden's `/lib/libc.a` differs from the tape's
    in exactly **ten bytes**, all the `__.SYMDEF` ar-header timestamp
    (743340498 against 1786908310), because this file's own rule requires
    re-`ranlib`ing an archive at its destination. The re-ranlib is *correct*;
    the whole-file hash called the correct thing foreign. Archives are
    fingerprinted per member with `__.SYMDEF` dropped.
  - **NEVER put it in a BUILD path.** It is an instrument. Using it to extract a
    tree *and* to bless the result makes the verification circular — if the
    reader is wrong it writes and approves the same wrong bytes.
- **`"$IMG:c"` IN zsh SILENTLY DROPS THE `:c`, so the tool reads the WRONG
  FILESYSTEM and tells the truth about it.** `$K:c` is a history modifier, so

	K=work/v10gold/ipnx-v10-ra81.img.stage1.k102.k7.k13
	python3 tools/v10fs.py stat "$K:c" /bin/lex     # reads partition a

  arrives with no partition, defaults to root, and correctly reports that
  `/bin/lex` is not there. **Nine files read as MISSING when all nine existed.**
  An RA81 image holds two filesystems, so this is K11's *"a guest can report
  success about the wrong disk"* moved to the host. `${K}:c` is the fix in the
  shell; `v10fs.py` prints the filesystem it read on **stderr** every time,
  because a banner is the only thing that makes the wrong answer visible instead
  of plausible.
- **`nohup … &` INSIDE A BACKGROUNDED CALL REPORTS "exit 0" OVER A RUN THAT IS
  STILL BOOTING.** The ampersand makes the wrapping shell exit at once, so the
  harness announces completion while `vax780`, `expect` and the driver are all
  still alive — and the log, read at that moment, stops mid-`attach il nat:`,
  which looks exactly like the documented SLiRP bind failure. Nothing was
  damaged, and only *not* starting the next run on top of it kept that true.
  Background the call and let the tool track it; wait on the driver's own pid.
- **Read a V8 disk from the host — don't boot one to look.** `tools/v8fs.py` walks a
  SIMH RP06/RP07 image directly (`ls`/`cat`/`stat`/`diff`, `IMAGE:PART`); every
  constant is quoted from the tree (`param.h`, `ino.h`, `dir.h`, `subr.c`'s `bmap`,
  `hp.c`'s tables in *sectors* with *cylinder* offsets). The one trap is
  `usr/src/libc/gen/l3tol.c`: on the **vax** a 3-byte disk address is little-endian
  with a zero high byte, and the **pdp11 arm of the same file** packs the identical
  bytes in a different order — pick wrong and the inode addresses look almost
  plausible. This turned "what is actually on that disk?" from a five-minute boot
  into a one-second question, which is what made the retirement audit possible at all.
- **A netfs READ ON V10 STOPPED AFTER ONE BLOCK, SILENTLY, AND IT WAS A
  512-BYTE STREAM HEAD — FIXED 2026-08-20, and the two numbers are the whole
  story:**

	V8    struct qinit strdata = { strput, NULL, nulldev, nulldev, 8192, 4096 };
	V10   struct qinit strdata = { strput, NULL, nilopen, nulldev,  512,  256 };

  The N track raised V8's stream head sixteenfold as part of the netfs fix and
  V10's copy was never touched, while `tcp_device.c:265` drains only
  `while ((q->next->flag&QFULL) == 0)` — so every netfs reply squeezed through a
  512-byte queue. Our V10 overlay had fixed **two** of `streamio.c`'s Datakit
  assumptions (the freed block tail, the zero-length read) and left this one. The
  patch is one line with V8's own values, in `v10/src` with its reasoning in
  `PATCHES.md`.
  - **The before/after could hardly be tighter** — `tools/v10-netread.sh`, same
    file, same tag, same request number, one variable changed:

	                        before            after
	#249 NREAD 4096 off=0   4096 served       4096 served
	#250                    CONNECTION CLOSED NREAD 4096 off=4096

    The second `read(2)` that never reached the wire *is* the K15 failure, and it
    is gone. **`streamio.c` is kernel source, so a change needs
    `v10-srcdisk.sh` → `v10-kernel.sh` → `v10-netboot.sh`** before any harness
    sees it; K7's own assertions (*"streamio.x replaces the tape's in os.a"*)
    are what prove it arrived.
  - **THE LATENCY IS A SEPARATE FAULT AND IS STILL OPEN**: 6.92 s per request
    after the fix against 6.67–7.50 before. Do not assume one patch cured both.
  - **AND THE REPLY-SIZE DISTRIBUTION IS HOW TO READ A netfs FAULT.** Twelve
    replies of 744 and 1905 bytes were complete; the FIRST reply that filled a
    whole 4096-byte request killed the connection, after which every read
    returned **0 bytes** — EOF, not an error. So a dead share reads as an empty
    file, and 20 assertions flew past with the request count frozen.
- **The diagnosis, kept because the reasoning is reusable.** K15's build died on

	"/n/tree/.../32ld.c":214:syntax error
	"/n/tree/.../32ld.c":214:saw EOF

  and `32ld.c` is **295 lines**. netfsd's own trace names the cause: one
  `NREAD count=4096 off=0` serving 4096 bytes of a 5870-byte file, and **no
  second read anywhere in the trace** — so `cpp` reached EOF three-quarters of
  the way through, at about line 214. Nothing said "short read". Sixty requests
  later the transport failed outright (`connection closed after 399 requests`),
  which is where `lib.a: I/O error`, `nafsmnt: funmount: I/O error` and
  `Make: Don't know how to make .../32ld.c` came from — three symptoms whose
  cause was invisible where each appeared.
  - **It is intermittent, and K14 is the control.** The same shape read
    correctly there: `4096` at off 0, `1010` at off 4096, `0` at off 5106 for a
    5106-byte `mkbitfs.c`. So multi-block reads are not broken in general.
  - **Slow is survivable; silently wrong is not.** The syntax error is the
    *lucky* outcome — it is what made this visible at all. A truncated source
    that happened to compile cleanly would put wrong bytes into a build with
    nothing to say so, which is the app's *"it is in the golden, it will arrive
    on Reset"* in a new place.
  - **Consequence for reading results**: any V10 measurement that read a file
    over 4096 bytes off a share is suspect until checked. K14 checks out (its
    `mkbitfs.c` read whole, and its verification was host-side and independent);
    K10.1/K10.3 used the courier disk; K12's files were small.
  - **THE TRUNCATION POINT IS EXACTLY ONE BLOCK, PROVED HOST-SIDE WITH NO
    SIMULATOR.** `32ld.c` is 5870 bytes and 295 lines, and
    `head -c 4096 | wc -l` is **213** — against cpp's error at line **214**. So
    cpp really did see the first block and take it for the whole file. One
    command, no boot.
  - **AND IT IS NOT A FRAME-SIZE PROBLEM: three 4096-byte replies were served
    perfectly in the very run that failed.** That retracts the frame-loss
    suspicion this bullet used to carry (*"a 4096-byte reply is roughly three
    Ethernet frames and `pdp11_il.c:659` drops one"*):

	mpx.h      4096 @ 0,  804 @ 4096, 0 @ 4900    complete
	pads.h     4096 @ 0, 1247 @ 4096, 0 @ 5343    complete
	filehdr.h  4096 @ 0, 1134 @ 4096, 0 @ 5230    complete
	32ld.c     4096 @ 0   -- and nothing, ever    TRUNCATED

    A full-size reply is not what breaks. The failing read also never sent
    `NPUT` for its tag where every completed read does — the shape of an
    abandoned handle.
  - **`naread()` IS NOT THE BUG, so do not go looking there.**
    `lsys/fs/neta.c:222` is a clean read-until-short loop —
    `while(u.u_error == 0 && u.u_count != 0 && n > 0)` — that never consults
    `i_size`. The caller asked 4096, got 4096, `u_count` hit zero, the loop
    ended correctly. The fault is a **second `read(2)`** that never reached the
    wire.
  - **The probe is `tools/v10-netread.sh`, and it uses TWO READERS because one
    cannot localise it.** `wc` reads with `NBUF` = 64\*1024 (`cmd/wc.c:3`), so it
    issues one `read(2)` and `naread()`'s own loop does the work; `cat` reads
    4096 at a time (`cmd/cat.c:8`), which is exactly cpp's pattern —
    `refill()` calls `read(fileno(fin), pbuf, BUFSIZ)` and r70's `stdio.h` makes
    `BUFSIZ` 4096. **A probe with only `wc` could pass while the bug stands.**
- **"~9.6 s PER REQUEST" WAS A REQUEST *RATE*, NOT A SERVICE TIME, AND THE GUEST
  IS NOT STARVED. Both halves of that diagnosis were mine and both are
  withdrawn** (2026-08-20). netfsd's trace carried **no timestamps**, so the
  figure could only ever have been K15's elapsed time over `connection closed
  after 399 requests` — and a guest that spends its time compiling produces
  exactly that number without the server being slow at all. The units read as
  latency because of the words "per request". Same shape as the withdrawn "530
  file reads in 2 s" and as `used = s_fsize - s_tfree` counting the i-list as
  content: **a quotient whose divisor does not mean what the units imply.**
  - **`tools/v10-clock.sh` settled the starvation half and the answer is no.**
    228,310 bytes read off local disk: **72 ms** with the card attached, **44 ms**
    without (46/44/44, tight to ±2 ms). The harness declines to interpret the
    1.64× and is right to — 44 ms is near the tty round trip that measures it,
    and the `on` arm has an outlier — but the question it was built for is
    answered: a guest that fast is not too starved to issue requests. There is
    probably a real ~64% cost to having the card attached; that is worth knowing
    and is a different bug. Grow the workload before quoting the ratio.
  - **The honest figure is 7.50 s per request**, sampled over a 90-second window
    of `tools/v10-netread.sh` — a workload of `wc -c` and `cat` with *no*
    compilation, so the divisor means what it says. So netfs really is
    seconds-per-request slow; the old number simply could not have shown it.
  - **netfsd now measures this itself**, so it need never be inferred again: the
    connection loop reports its own service time separately from time blocked in
    `readExactly()` waiting for the guest, on a monotonic clock (`DispatchTime`,
    not `Date` — this process runs for hours beside a guest that thinks it is
    1976).
  - **The mechanism is Bell Labs', in their own words, and it is the GUEST DRIVER
    rather than our device model.** `lsys/io/ni1010a.c`'s receive-buffer poster
    carries the comment *"let it be an ordinary command, interrupt when complete,
    for now. **this is probably too slow**"*, and it is: `ilrcvbufs()` posts ONE
    buffer per command and refuses to post while any command is active
    (`if (is->flags & CMDACT) return (0)`), wanting `ILRBYTES` = 3000 bytes in
    `ILRSIZE` = 1024-byte blocks — three buffers, three command round trips.
    **V8's `ill.c` chains instead**, supplying the next buffer from *inside*
    `ilrint()`, so it never pays that. Same card, same device model, different
    driver — which is the right shape for 7.5 s against the ~16 ms per request
    `pdp11_il.c:775` records for *unpatched* V8.
  - A near miss worth not repeating: `ilincmd()` waits for command completion
    with `tsleep(…, PZERO, 5)` and `slp.c:86` declares that argument **seconds**,
    which is tantalisingly close to 7.5. It is **not** the cause — its only
    callers are lines 180/195/207, all `ILC_RESET`/`ILC_STAT`/`ILC_ONLINE`, i.e.
    init.
  - **CPU share cannot answer any of this** (the V10 config never sets `set cpu
    idle`, so the simulator burns a core either way — measured 43:20 of CPU in
    44:24 elapsed, which carries no information). And after any change to
    `pdp11_il.c`, re-run `tools/net-selftest.sh` against V8: its 290 s → 11 s is
    measured and must not regress to fix V10.
- **`show il stats` HAS NEVER WORKED, so every V10 halt has silently recorded
  nothing.** `pdp11_il.c`'s MTAB row names the parameter **`STATISTICS`** and
  SIMH matches it in full, so the command answered `%SIM-ERROR: Non-existent
  parameter: STATS` — which was not one of `v10_ilstats`'s patterns either, so it
  fell through to a 30-second timeout and produced no reading at all. Fixed
  2026-08-20, with the error text matched explicitly so a future rename is loud
  rather than slow. *A diagnostic that cannot fail is not a diagnostic.*
- **netfs costs a round trip per path component, not per byte** — so diagnose it by
  counting *files*, never bytes, and never benchmark it with one big read.
  **The round trip was the emulator's, not the protocol's.** `il_svc()` ended in
  `sim_clock_coschedule (uptr, tmxr_poll)`, which rides the calibrated 10 ms clock,
  so every reply waited for the next tick to be noticed — and a path is several
  exchanges, so the cost compounded with directory depth. A bounded fast-poll window
  after each received frame (`IL_BURST`, `libsimh/patches/pdp11_il.c`) took stage 7's
  copy of usr/sys — 389 small files off the share — from **290 s to 11 s, 26×**,
  measured between the `NETFS-COPY-START`/`END` stamps `buildkernel.sh` now prints on
  every build. The window is bounded so an idle machine falls back to the clock
  within 200 service calls and keeps the 2.7% idle property: sampled across an
  identical boot-and-assert run, patched and unpatched are the same distribution
  (peaks 79.8 vs 78.6, lows 7.6 vs 6.6). Bulk installs are still better off with
  `cpio` off a mounted disk, but "hopeless" was a property of our device model.
  One pass over the 107 headers finishes inside a single second — a fine
  result and a useless measurement, since the guest's clock has one-second
  resolution and would report zero again if it got four times slower. **When
  the workload outruns the ruler, grow the workload** (the script does five
  passes), and never let a "0 seconds" reading stand as a number.

  **The "530 file reads in 2 s (~265 files/s)" figure that stood here is
  withdrawn — it does not reproduce.** Measured 2026-08-16 on the desktop
  `vax780`, five runs of the same five-pass workload, three on the committed
  device model and two on the hardened one:

  	committed model   32 s   47 s   49 s
  	hardened model    50 s   60 s

  So ~530 reads take **32–60 s**, or 9–17 files/s — an order of magnitude off
  the retired claim, on an unmodified model. Two lessons, and the second
  matters more:

  - **`netfs-latency.sh` has ~50% run-to-run variance**, so it cannot detect a
    regression smaller than about 2×. The overlap above is why the hardened
    model is reported as "no measurable difference" rather than "1.3× slower":
    the baseline's own spread (32→49) is wider than the gap between the groups,
    and a ring-size constant has no mechanism to slow a driver that queues one
    buffer. Treat this script as a smoke test, not a benchmark, until it is
    made repeatable.
  - The withdrawn number was almost certainly a one-pass timing written up as
    if it were the five-pass one — which is precisely the error the paragraph
    above warns against, committed in the same breath as the warning.
- **`cp` per file is what makes stage 8 slow, not I/O.** 400 copies took longer than
  the `mkfs` of a 475 MB filesystem. `cpio -p` reads its path list from stdin, which
  is exactly the shape of a generated manifest — one process for the whole set.
- **A command can be built and still not be on the disk.** Stage 8's copy loop has its
  own directory list, unrelated to `provenance.txt`, and `usr/games` was missing from
  it — so `bcd` was built, reported built, and absent. Symmetrically, `TOOLDIR` serves
  *two* roles (the staging toolchain, and the system being built, since stage 6 aims
  it at `DESTDIR`), so an install path in `stage1.order` is a **system-layout**
  decision: `yacc` and `strip` installed to `bin/` reached the toolchain and never
  `/usr/bin`, where `where.txt`, the reference image and `provenance.txt` all say they
  live — and where `mkdep.py`'s own generated makefiles default `YACCPATH` to look.
  Neither is visible from a boot test; both were found by `tools/retire-check.py`.
- **`mkfs` does not clear data blocks.** A second stage 8 over the same image file
  leaves the previous run's contents in what the new filesystem calls free space:
  invisible to the guest, very visible to a compressor. Recreate the file from
  `/dev/zero` before the run that produces a committed artefact.

## Conventions

- Big binaries (disk images, tapes, tarballs) never enter git — rebuild locally per the
  runbook (gitignored: `*.disk`, `*.tap`, `*.img`, `work/`). **Exactly one exception**,
  named in `.gitignore` and in `tools/hook-block-binaries.sh` rather than left to a gap
  in a pattern list: `image/ipnx-v8-rp07.img.xz`, the disk *we* build, because it is the
  **input to the next build** — stage 8 lifts `v8/mk/gen/carry.txt` off it. With it
  committed the build's only external input is the tapes, which `v8/MANIFEST` already
  accounts for. Written only by `tools/image-pack.py`
  ([docs/golden-disk.md](docs/golden-disk.md)).
- **VERIFY** marks a documented step assembled from research but not yet executed here.
  Resolving one means executing it and correcting the doc, *or* recording that the step was
  superseded — never silently deleting the marker. None remain open
  ([docs/spike-a0.md](docs/spike-a0.md)'s last four were closed 2026-08-09).
- Track B keeps pristine upstream sources separate from our patches; every fix is a logged
  patch with a rationale, plus a dated lab-notebook entry (`docs/v10-log/`).
- Cite primary sources (TUHS preferred) for factual claims in docs.
- Project automation: use `/verify-step` to resolve runbook VERIFY markers and `/v10-log`
  for Track B lab-notebook entries. Hooks (`.claude/settings.json` + `tools/*.sh`) enforce
  the no-binaries rule and check markdown links on edit.

## The version, and where it lives

The system is **`ipnx Edition 8 Release 1.0`** (2026-08-16). Two numbers owned by
two different parties: the **edition** is Bell Labs' and is not ours to increment;
the **release** counts what this project has made of it, and started at 1.0 when the
disk began being built from source rather than patched out of the tape.

`v8/RELEASE` is the single source of truth and `tools/ipnx-release.py` generates both
consumers from it — `v8/usr/include/ipnx.h` (userland) and `v8/usr/sys/conf/newvers.sh`
(the kernel banner); `--check` fails if either drifts. Two presentation rules live in
the generator so no call site has to remember them: **`PATCH` is omitted when zero**
(`Release 1.0`, not `1.0.0`) and **the branch suffix appears only off a tag** (never
`Release 1.0-RELEASE`). Print `IPNX_RELSTR`, which arrives composed — `uname` and
`ipnxfetch` each glued `IPNX_RELEASE` to `IPNX_BRANCH` themselves and both printed the
stutter.

**Changing the version means rebuilding the guest**, because three artefacts carry it:
`uname` and `ipnxfetch` (stage 6) and `/unix` (stage 7, via `newvers.sh`). The route is
`tools/drive-stages48.sh "" "" 4 8 rp07ref rp07` — about twenty minutes — and the target
image must be recreated from `/dev/zero` first, since `mkfs` does not clear data blocks
and this artefact is committed. The carry reference must be a *different* file from the
target (`rp07ref`, not `rp07new`), or the precondition checks the file the run is about
to overwrite.

## Shipping: the website and the Mac release

Full record in [docs/website-and-release.md](docs/website-and-release.md). The
short form:

```bash
# archive → notarise app → dmg → notarise dmg → staple → assert Gatekeeper
tools/release-mac.sh
```

- **The site is `website/`** (Astro 7 + Tailwind v4), published to
  <https://christham.net/ipnx/> by a Pages workflow. It is a **project page under
  the user-site custom domain**, so `site` is `christham.net`, not github.io,
  which 301s. `base` must equal the repo name.
- **`build.format: 'file'` is an App Store requirement in disguise** — it makes
  `/privacy` *and* `/privacy.html` both resolve, and App Store Connect's Privacy
  Policy and Support URLs get quoted both ways. Astro `redirects` cannot fix this
  and a `public/privacy.html` shadows the real route into a loop.
- **Never hard-code the base**; use `href()` in `src/lib/paths.ts`.
- **`<Crt text={...}>` takes a PROP, not a slot.** Astro normalises whitespace
  between element children, so a multi-line transcript passed as slot content
  arrives as one line inside a `<pre>`. Same family of bug as SVG collapsing
  whitespace in the OG card, which needs `xml:space="preserve"`.
- **`… | grep -q` under `pipefail` fails on SIGPIPE**, so a check can fail
  exactly when it should pass — the release script printed "hardened runtime is
  NOT enabled" under a line saying `flags=0x10000(runtime)`. Capture, then test.
- **`notarytool submit --wait` exits 0 for a REJECTED submission**; insist on
  `status: Accepted`.
- **Both the app and the dmg are notarised and stapled.** The dmg is what gets
  downloaded, so it is what must carry the ticket.
- The signature names **Hello Tham Pty. Ltd.** (a Developer ID needs an enrolled
  team) while the project is personal and non-commercial, per the 2017 covenant.
  That difference is explained on the download page, not hidden.

## Status / next step

**Track A is complete** (A1–A3, all 2026-08-09) — see
[docs/a1-notes.md](docs/a1-notes.md), [docs/a2-notes.md](docs/a2-notes.md) and
[docs/a3-notes.md](docs/a3-notes.md). The app boots V8 to `login:` in ~25–30 s with
save/restore instant-on; the 5620 delivers the full Blit experience on iPad — DZ login,
`mux` download (~100 s at the ÷8 DUART turbo), B3 menu → sweep → layer with a root
shell, `jim` in a layer; A3 added settings (phosphor, "Crisp" scaling — the moiré fix,
pointer speed), 5620 NVRAM persistence, "Restart terminal" (the fix for a restored mux
session with no muxterm), staged disk import/export/reset, a licences screen and App
Store prep — plus a **native Mac app** sharing every line of app code. Evidence:
`work/shots-a1-final/`, `work/shots-a2/`, `work/shots-a3/`.

**A4 — the screen** (2026-08-10, [docs/screen-size.md](docs/screen-size.md)): two fixed
presets (Original 800×1024/88 columns, Wide 1152×1024/127) with the window locked to
the CRT's shape rather than the reverse; the screen *and* the session both survive a
quit (`screen.bin` repainted, plus a CR nudge gated on the firmware's idle PC window —
the fix for what looked like a mute restore); area-average sampling in the fragment
shader so fractional scale no longer shimmers, driven off `MTKView.drawableSize` so
Retina panels are actually used; controls out of the terminal field into a real
`NSToolbar` (Mac) or a chrome bar (iPad), with a plain bezel around the tube.

**A5 — the interface** (2026-08-10, [docs/ui-redesign.md](docs/ui-redesign.md)): the
three-face picker is gone. The app is now the machine as it actually is — an operator
console plus a getty on `tty00`..`tty07`, each openable and independent, in windows
grouped by terminal shape (vt100 / vt100w / dmd) because nothing can be reflowed on a
kernel with no `TIOCGWINSZ`. Every DZ line has its own listen port, so a tab labelled
`tty03` *is* `tty03`. The console is read-only behind a lock, `tty01` logs itself in as
root on seeing `login:`, chrome is Liquid Glass (never over the emulated raster), and the
deployment targets are iOS 26 / macOS 26. The app was renamed from **Edition** to
**ipnx** at the same time — project, targets, schemes, folder, `@main` struct — and the
icon is now a stylised licence plate reading `ipnx` over LIVE FREE OR DIE, after the
plate Armando Stettner handed out at USENIX (`tools/gen-icons.swift`).

**B0.6 — a machine to live in is COMPLETE** (2026-08-15/16,
[docs/machine-config.md](docs/machine-config.md)). Build-time identity lives in the
golden; a first-boot provisioner in the app creates an account named after the host
user (uid 1000, no password — a deliberate decision recorded in `Provisioner.swift`,
not an omission), and `tty01` logs in as that user rather than as root. The network
comes up from `/etc/rc`, and the host shares mount at `/n/macos` and `/n/home` —
deliberately **not** the home directory, since V8's 14-byte filenames and case
sensitivity rule that out. Networking can be switched off in Settings (**Machine →
Ethernet card**), which gates the `attach il nat:` pair; `/etc/rc` guards on
`/dev/il0`, so a card-less machine boots exactly as it did before the N track.

**Track B's ingest path is settled** (2026-08-09, phase B0): host↔guest file
transfer is proven end to end — [docs/media-exchange.md](docs/media-exchange.md),
`tools/tapeio.py`, `work/mediatest.sh` — including a VAX binary compiled inside V8 and
carried back out. The golden image's missing `lost+found` was fixed at the same time.

**B0.5 — the N track — is complete** (N0–N7, 2026-08-09/10). Plan in
[docs/networking-plan.md](docs/networking-plan.md), results in
[docs/n-track-notes.md](docs/n-track-notes.md), wire format in
[docs/netfs-protocol.md](docs/netfs-protocol.md).

**A macOS folder is mounted inside Research Unix 8th Edition, read/write.**
`work/myv8/rp07v8.net` boots a 516 MB RP07 with an Interlan NI1010 we modelled
for SIMH, reaches the real Internet through SLiRP's NAT, and mounts a host
directory at `/n/macos` over TCP using Weinberger's netfs — whose client has
been compiled into every V8 kernel since 1985 and has had nothing to talk to
since Datakit was switched off. Proven both directions with checksums: a
13,200-byte file reads out byte-exact, and 65,385 bytes written *by V8* land
byte-identical on APFS (`tools/drive-netfs.sh`, `tools/drive-netfs-rw.sh`).

The server is `netfs/`, a SwiftPM package whose `NetFS` target compiles
unchanged into both app targets — `app/ipnx/FileShare.swift` runs it behind a
folder picker. The guest reaches it at 10.0.2.2, which SLiRP aliases to the
host's loopback, so it needs no forwarding and works inside the iOS sandbox.

**The app now ships the RP07 golden we build** (`work/myv8/rp07new`, embedded
as `v8.disk` by both targets), with the `il0` kernel, the netfs stream fix,
the network up from `/etc/rc`, and both mount points. Two faults that hid
behind each other were fixed on 2026-08-15 and are worth not re-introducing:
libsimh was built with **no network layer at all**, so `attach il nat:`
answered "Command not allowed" while autoconfig cheerfully reported `il0`
(needs **`USE_NETWORK` *and* `HAVE_SLIRP_NETWORK`** — the first is the master
switch, and with only the second every slirp object links and nothing
references it); and V8 ships **no `/dev/udp*` nodes and no `udpconfig`**, so
name resolution failed while TCP worked perfectly. Assert traffic, not files:
`tools/net-selftest.exp <image>` mounts a share and resolves a name, and is
the only check that would have caught either.

**B1 — the V10 toolchain is COMPLETE** (2026-08-16,
[docs/v10-log/2026-08-16.md](docs/v10-log/2026-08-16.md)). The plan was a
cross-build and did not need to be: V10's own `ccom`, `as` and `libc.a` are in
the tarball as linked VAX binaries and **run on the V8 kernel**
(`tools/v10-probe.sh`, 9/9). `tools/v10-toolchain.sh` builds the three passes
that have no binary — `cpp`, `c2`, `ld` — assembles all seven into one
directory, and drives them with `cc -B/usr/v10/lib/ -t02palc`: **10/10**,
including V10's compiler rebuilding V10's linker and that linker linking a
working program. The two linkers' output is byte-identical but for a `time_t`
in a `.stabs` record.

Also settled by B1: the whole 243 MB tree is **served over netfs at `/n/v10`**
and read in place. Nothing is copied to guest disk, so the courier disk and the
subset it forced are both out of the picture for source.

**B2.0 — the boot path already compiles** (2026-08-16, same log). Run ahead of
the build mechanism on purpose: B1 was won by putting the decisive experiment
before the machinery, and the risk in B2 sat in the headers, not the makefiles.
`tools/v10-bootpath.sh` builds the seventeen programs the first boot needs,
twice — against V8's headers and against r70's — and **fifteen build against
r70**, with all five that are safe to execute then running. The two that do not
are each one line: `fsck` includes a bare `<stat.h>` that exists only as
`sys/stat.h`, and `mv` wants `ROOTINO`, which reaches it through V8's
`sys/types.h` including `sys/param.h` where r70's does not — so the 1995
source is evidence the 1997 reconstruction dropped that include, not the
reverse. Three claims fell: **V10 does not "build with `mk`"** (205 `mkfile`
against 153 `Makefile` and 209 `makefile`, and `cmd/make/make` is a prebuilt
0413 binary), **V10 has no world build** (`src/makefile` builds a Datakit
daemon), and the **boot path has no build file at all** — seventeen loose `.c`
files under a `cmd/` with no makefile, which is the same shape as V8's and
settles B2.1 as "reuse `v8/mk/mkdep.py`".

**V10 SELF-HOSTS, AND STAGE 1 IS DONE** (2026-08-16). The golden reaches
multi-user on a VAX-11/750 and compiles its own C; `tools/v10-stage1.sh` then
rebuilt **the whole toolchain on V10** — `yacc cpp ccom as c2 ld cc`, plus
`halt`, `sleep`, `ar` and `cmp`, none of which the golden had — **42/43**.
That matters for one specific reason: the golden's `cpp`, `c2` and `ld` had
been compiled by *V8's* cc (`tools/v10tc.exp`, the only compiler that existed
before there was a V10 to run one on), and those three are now V10's own. No
binary on that machine was built by the Eighth Edition any more. The one
failure, `tail`, is a finding rather than a defect — it is the only file in
the entire `src/` tree that includes the ANSI-prototyped `<libc/libc.h>`,
which pcc2 cannot parse. Source reaches the machine on a second RA81
(`tools/v10-srcdisk.sh`), because there is no netfs on V10.

**STAGE 2 BUILDS 237 OF THE 261 libc MEMBERS, AND 147 ARE BYTE-IDENTICAL TO
BELL LABS'** (2026-08-17, `tools/v10-stage2.sh`, 19/27). The tape's
`libc/mkfile` turned out to be a complete machine-readable build description —
all 261 objects carry an explicit `obj: dir/src.c` line, and that set is
*exactly* the 261 objects in the tape's own `libc.a`, which `mkdep.py`'s
`libc_from_tape()` now asserts rather than assumes. Member **order** is read
out of the archive instead of recomputed: V8's recipe uses
`` ar cr libc.a `lorder *.o | tsort` `` and the V10 golden has neither tool,
but the tape's archive is Bell Labs' own answer to the ordering question.

The 24 that will not compile are **a finding, not a defect**, and they are not
random: nine of the ten the mkfile hands to `lcc` are among them, plus the
ANSI-era stdio family. Every failure is a construct pcc2 cannot parse —
`int fprintf(FILE *f, const char *fmt, ...)`, `extern void *memcpy(void*,
void*, size_t)`, `static void swapfunc(char *a, char *b, size_t n, int)`,
`#include <stdarg.h>`. **So V10's libc has two generations in one tree** and
the tape's archive is the ANSI one.

**ONE COMPILER NOW BUILDS 252 OF THE 261, WHICH IS MORE THAN THE TAPE'S OWN
MIXTURE MANAGED** (2026-08-17, 27/39; `LIBC_LCC` is empty). Every
configuration was run, not inferred:

	                                built   byte-identical to the tape
	cc + lcc, the tape's mixture      246        150
	cc + lcc, with the 14 repairs     260        150
	cc alone, after B2.2b/c           249        148
	cc ALONE, every conversion done   260        148

Fifteen members could be built by nothing, and they had **three** causes, not
the two recorded here for a week:

- **Eight were a language problem** — the `printf`/`scanf` family, now converted
  ANSI→K&R in the overlay. Which fix, and where, is settled by the tape:
  `vfprintf.c` and `vfscanf.c` are the only two of that family that carry
  `#include <stdarg.h>` themselves *and* the only two that build, so the missing
  line is a per-file omission rather than a missing branch in `iolib.h`.
- **Six were a missing header, and it is RECOVERABLE** — see the `<shares.h>`
  entry in Decisions, which is now largely withdrawn.
- **One, `jterm.o`, was never ANSI at all** and spent two runs listed as an lcc
  member on the strength of its failure. It wants
  `#include "/usr/jerq/include/jioctl.h"`, an absolute path into the 5620 tree,
  which is in the **v10blit** tarball rather than v10src — so lcc could no more
  find it than `cc` could. *A failure under compiler X is not evidence that
  compiler Y would succeed.*

Seven remain, and **six of them are now known to be a MISSING-HEADER problem
rather than a language one** — which is the finding that reframes the rest of
B2.2d. The build's own diagnostics, once the error filter stopped matching
filenames:

	malloc.c: 8:     Can't find include file stdlib.h
	fconv.h: 29/33:  Can't find include file stdlib.h / float.h
	vfprintf.c: 6/8: Can't find include file stdarg.h / stdlib.h
	vfscanf.c: 6/8:  the same two
	setupshares.c:   Can't find include file sys/share.h

So `_dtoa`, `_fconv` and `strtod` share ONE blocker (`stdio/fconv.h`, which is
Gay's header and includes both), `vfprintf`/`vfscanf` share another, and
`malloc` wants only `stdlib.h`. **r70 has all three headers — under
`include/lcc/`, `include/CC/`, `include/olcc/` and `include/oCC/`, never at top
level.** So the question is not "convert six ANSI files" but "which of the
tape's four variants belongs at `/usr/include`", which is a *system-layout*
decision of the same kind as installing `shares.h`. Measured so far:
`lcc/float.h` and `CC/float.h` have **no prototypes at all** (pure `#define`s,
so either will parse), `lcc/stdarg.h` is already known K&R-compatible, and
`CC/stdlib.h` is a **three-line shim** — `#include <libc.h>` — onto a header r70
*does* have at top level.

**PULLED, AND IT WORKED — the headers are installed and the failures have
changed shape.** `stdlib.h` ← `CC/stdlib.h`, `float.h` ← `lcc/float.h`,
`stdarg.h` ← `lcc/stdarg.h`, all three copied to `/usr/include` by
`tools/v10-stage2.exp` on the same argument as `shares.h`: the tape holds four
variants of each and the job is to pick the one pcc2 can parse, not to write
one. `CC/stdlib.h` is six lines onto `include/libc.h`, which is **36 lines of
`extern char *sbrk();` and zero prototypes**. Not put on `-I`, because
`include/CC` also holds cfront's `stdio.h` and `math.h` and would shadow the
system's for all 261 members.

It did **not** close the six on its own — the same seven still fail — but they
now fail on their own prototypes instead of on a missing file, which is the
ordinary conversion work the printf family already went through:

	malloc.c:70  extern void *sbrk(int);            saw TYPE
	malloc.c:82  static union store *stdmalloc(size_t);
	malloc.c:86  extern void ialloc(void *, size_t);
	atof.c:4     (its own prototype, newly reached)

And it gained a member's worth of fidelity: byte-identical 147 → 148.

`fconv.h` also carries `#define CONST const` and twelve prototypes, and its
`#if defined(A) + defined(B) != 1` needs a cpp that understands `defined()` —
so it will need work beyond the includes. B2.2d's first five (`fgets`, `fputs`,
`memmove`, `qsort`, `rdwr`) are done and measured.

**A byte-identical count going DOWN is not necessarily a regression.** 150 → 148
→ 147 across these rounds, while the number that *build* went 246 → 249 → 252.
Each converted member leaves the tape's own bytes behind by construction — the
tape's `fgets.o` was compiled by `lcc` from ANSI source and ours is `cc` from
K&R source, so it *must* differ. Read the two numbers together or neither means
anything.

**AND EVERY ONE OF THOSE FIGURES WAS INFLATED, because the channel they were
measured through was dropping lines. The number is 143.** The DIFF list came
back over a tty whose marker echo interleaved into it, so a member whose
"differs" line was damaged **counted as byte-identical** — the error ran in the
flattering direction, which is why it never looked like an error. Fixing
`v10_run` (it was matching the *echo* of its own end token, then typing a marker
into a still-running command) and re-running the identical build:

	                        before   after
	byte-identical            148      143
	differ                    113      118

Deterministic build, same source disk, same stage-1 image — so the *set* cannot
have changed and the second reading is simply the complete one. Six real names
had been destroyed outright (`_assert.o`, `besjn.o`, `cttyname.o`, `ftw.o`,
`timezone.o`, `vprintf.o`) and three more were being counted under corrupted
spellings (`getpoass.o` for `getpass.o`, `p8error.o` for `perror.o`, `scanf6.o`
for `scanf.o`). Treat 150/148/147 as historical and overstated by about this
much; **143 is the first one measured through an uncorrupted transcript.**
*A fidelity metric read out of a tty is only as good as the tty.*

**STAGE 2 IS AT ITS CEILING AND STAGE 3 IS A FIXPOINT** — `tools/v10-stage2.sh`
**38/38** and `tools/v10-stage3.sh` **33/33**, both exit 0 (2026-08-17). Stage 2
builds **260 of 261**, 143 byte-identical; `setupshares` is a **named exclusion**
(`LIBC_DROP` in `mkdep.py`), not a shortfall — `<sys/share.h>` is printed nowhere
and reconstructible from nothing, and nothing we build calls it now that the
Share scheduler is out of `login`. `libc.a` is built by the makefile from
`$(OBJS)` in **the tape's own member order**, and the archive's member list is
asserted against that order.

Then stage 3, which is the test the whole bootstrap exists to pass:

	stage 3   built by stage 1's passes, linked against stage 2's libc
	stage 3b  built by STAGE 3's passes, same libc
	stripped with `ld -x -r' (there is no strip on V10)

	components reproducing themselves   7      <- yacc cpp ccom as c2 ld cc
	components that do NOT              0

**Every one of the seven is byte-identical to the copy its own output built.**
The toolchain is a fixpoint on V10, from source, against a libc we built. The
strong test measures 7 differ / 0 same, exactly as predicted: stage 1 linked the
*tape's* `libc.a` and stage 3 links ours, and only 143 of 261 members agree.

Three things worth carrying forward from how it was reached, because all three
were faults in *measurement* and none in the code being measured:
- `atof.o` was missing from `libc.a` and **stage 3's link was the first thing to
  say so** (`Undefined: _atof`). Stage 2 had reported it and an anchored grep
  dropped the line.
- The fixpoint's first run reported **seven differences from zero comparisons** —
  `v10_order` returns one column and the harness destructured it as rows, so
  every install path was empty and `ld` was handed a directory. `v10_rows` now
  checks the column count, and the strip is asserted separately from the
  comparison, because `cmp` on a missing file reports as a difference.
- A diagnostic that re-ran a failing `make` **reported success**, because V10's
  `ld` writes its output even when symbols are undefined.
- The **fidelity metric itself was inflated** — 148 → 143 on the identical
  build — because the DIFF list arrived over a tty that was dropping lines.
- Three stage-2 assertions **could never pass**, and that is what let `atof`
  hide: `all 261 members compiled: NO` was permanently NO, so it stopped being
  read. They are achievable now, and the four `lcc` probes whose negative answer
  *is* the finding print `yes`/`no` and are not counted — so the tally means
  "nothing unexpected" and any `NO` in it is news.
- Regenerating a makefile changed **nothing the guest saw**, because the source
  disk is a copy. `tools/srcid.sh` stamps and checks it now.

**AND IT BOOTS UNDER THE CODE THAT SHIPS** (K9, 2026-08-17,
`bash tools/v10-boot780.sh app`, 5/5) — `libsimh/build/macos/vax780cli`, the CLI
over the static library *both app targets link*:

	sim> run FA02
	unix
	Unix 10e ipnx 780
	mem = 6062080
	login: root

One harness drives both simulators, selected by one argument, so the assertions
cannot drift between "it boots" and "it boots in the app". The library already
had every device the config needs — `RQ` UDA50A at `2013F468` = **`0772150`,
exactly the address compiled into the tape's own boot ROM**. Three differences,
all expected: it needs a config-file argument (`V10_SIMH_ARGS` supplies one, and
it then reads stdin like the desktop build); `set noasynch` answers *Command not
allowed*, because synchronous operation is a build-time guarantee there rather
than a setting; `set il enable` works, since the NI1010 model is ours and is in
both builds.

**Beware the plan's own stale checkboxes.** `docs/v10-restoration.md` carried
`[ ] K8` and `[ ] K9` *below* the `[x] K8/K9 — IT BOOTS` that superseded them,
and they were read as the current state and reported as the next step. They are
resolved in place now. A plan with two answers to the same question gets read at
the wrong one.

**K10.1 — THE WORLD COMPILES, 251 OF 358, AND K10.1 EXITS 0 FOR THE FIRST TIME**
(2026-08-18, `bash tools/v10-compile.sh`, **21/21**).  247 of those came from
fixing the three faults below; the last four came from **K10.4**, which stopped
compiling files the tape's own build does not compile. The 241 below was measured
through a machine that did not have the headers the survey said it had, a survey
that never ran yacc, and an assertion that was inverted. All three are fixed and
each is written up in [docs/v10-log/2026-08-18.md](docs/v10-log/2026-08-18.md);
the short form is that **six of the fourteen units that "failed on the tape's
headers" were failing on a decision stage 2 had already made and nobody had
installed**, and that the yacc/lex step the survey skipped is step one of the
build for fifty-one units. The 241 paragraph below is kept because its *controls*
argument is what made the number honest, and it still holds at 247.

**K10.1 — THE WORLD COMPILES, 241 OF 356, AND THAT IS A FLOOR** (2026-08-18,
`bash tools/v10-compile.sh`, [docs/v10-log/2026-08-18.md](docs/v10-log/2026-08-18.md)).
V10's own compiler — stage 1's passes, `cc -B/usr/s1/lib/ -t02p` — over every
command unit under `cmd/`, compile only: no libraries, no linking, no install,
because compiling needs only the compiler and the headers and so a failure is a
**language or header fact** rather than a missing `-l`.

**The controls are what make 241 a floor rather than an answer.** `as`, `cc`,
`ld`, `mv` and `cpp` all appear in the failing list and stage 1 builds every one
of them on that machine — so a failure in this survey is not evidence that V10
cannot compile the file. Three causes, all measured: the survey uses generic
flags where each unit's makefile has its own (`as.h:217 unknown size`); it never
runs `yacc`, so eight units want a `y.tab.h` that was never generated; and it
read only the tape until `worldc.sh` was taught to prefer `v10/src/`.
**That last fix is worth stating as a number: our five one-line corrections are
worth three commands** (238 → 241, with `mv`, `fsck` and `cc` crossing over).

What *is* a fact about the tape: 23 `syntax error` plus 7 `expected a NAME in
list` and 7 `expected , or ;` — the same ANSI-versus-K&R wall libc hit, now in
the commands; 11 `stdlib.h` and 3 `stddef.h`, the variant-header decision
already made once for libc needing to extend; 5 `n_un undefined` clustering on
exactly the five programs that read object files (`ld nm prof prof.old ranlib`),
which is `a.out.h` skew; and 3 units naming `/usr/jerq/include/jioctl.h` by
**absolute** path, which no `-I` can satisfy — the `jterm.o` finding again.

`tools/v10-world.py` predicts this host-side in a second and was **optimistic
three times, always in the flattering direction** (348 → 332 → 318 of 356), each
caught by a control and never by review: a missing `re.M` meant an include was
found only in a file whose first character began one; then the cross-unit search
ran *before* the system path, so `ccom`'s `#include "stdio.h"` resolved to
`cmd/lcc/include/sparc_sun/stdio.h` — a **Sun** header. `sanity()` now refuses to
print a measurement taken through a scan that read implausibly little.

**K10.2 — THE LIBRARIES ARE BUILT: 500 of 500 members, 26 of 26 libraries**
(2026-08-18, `bash tools/v10-libs.sh`, **24/24 assertions, exit 0**). Nineteen libraries: `libc`, which stage 2 built, and eighteen more
whose 500 members are compiled with stage 1's passes, archived in **the tape's
own member order**, `ranlib`'d and installed to `/usr/lib` under every `-l` name
each answers to. `tools/v10-libs.py` predicts host-side which members can
resolve every header and the run measures what the compiler accepts, exactly as
K10.1's pair does.

**The demand table is misleading and `-lm` is why.** It is the most requested
flag in the whole command tree — 51 uses — and libm is a **dummy**, in Bell
Labs' own words: *"libm is now a dummy for those who still want to say -lm"*,
one object holding `int ________ = 0;`. The mathematics moved into libc, which
stage 2 already built (`asin atan exp floor fmod gamma besjn log pow pow10 sin
sinh sqrt` are all in `libc/mkfile`'s OBJ list). And **thirteen `-l` flags name
libraries that exist nowhere in the tarball** — `-lbsd` 13, `-lport` 7,
`-lether`/`-lmodel`/`-lgc`/`-ld` 4 each, plus `-lresolv`, `-ltroff`, `-layout`,
`-lcoexpr`, `-large`, `-lsocket`, `-lpost` — the fingerprint of makefiles
written for other machines. So **a makefile's `-l` list is no more a statement
about V10 than its `CC` line is.**

Two per-library facts were worth 149 members between them, and neither is
guessable: **`-DKR_headers`** decides 146 (libF77's 113 and libI77's 33), because
`libI77/Version.c` says *"23 July 1992: switch to ANSI prototypes unless
KR_headers is #defined"* — without it pcc2 cannot parse them; and **`-I../h`**
decides libipc's 9 and libin's, `ipc/h` being a sibling directory that is not a
library and so was in no manifest. `libF77/mkfile` names `CC = lcc` where
`libI77`'s names `cc`, so we compile both with `cc` and the tape's own K&R
switch — lcc is unusable here (`bowell.c`'s `-undef` makes it emit empty objects
and exit 0).

Five faults, four of them mine and one a discovery, took the number 458 → 496 →
499 → 500. All are recorded in
[docs/v10-log/2026-08-18.md](docs/v10-log/2026-08-18.md); the durable ones are
gotchas above (`ar` bundles source; a tally cannot leave a redirected loop; the
golden has no `find`). The discovery: **`JMUX` is defined by no header on the
tape** — four `jioctl.h` survive and all four call that request `JMPX` at
`(JTYPE|3)`, while `lib5620/openpl.c` and `32ld.c` use `JMUX`. One alias in
`v10/src/include/jioctl.h`, with four pieces of evidence in `PATCHES.md`,
including that `lib5620`'s and `libblit`'s `openpl.c` are the same file differing
in three places (`/usr/jerq/` vs `/usr/blit/`, `32ld` vs `68ld`, and that
identifier) — the 5620-versus-Blit naming trap in a pair of *libraries*.

**K10.3 — THE WORLD LINKS AND INSTALLS: 203 commands, built and placed by V10**
(2026-08-18, `bash tools/v10-link.sh`, **35/35, exit 0**). Of 358 units, 251
compile, **203 of those link**, and all 203 install — into a **staged root** at
`/usr/w10`, never over the machine's own `/bin` and `/etc`. That is a decision
with three reasons and the first two settle it: the 46 prebuilt binaries are the
**oracle** and installing over them destroys the comparison on the only machine
that has both; and V10's `ld` writes its output even when symbols are undefined,
so a bad `/etc/init` is an unbootable disk — v8's stage 8 built empty
*directories* named `/bin/sh` and `/etc/init`, and that disk walked 4,507 files
and then stopped dead after autoconfig with the CPU idle. K11 wants a tree to
copy in, which is exactly what this produces.

`worldc.sh` takes an optional DESTDIR, so **one script does K10.1 and K10.3** and
the compile numbers in both come from the same lines — which is how the 5620
header drift was caught: 247 against 244 between two runs of the same code, and
the difference had to be the machine.

What the 23 link failures are, and none of them is "our libc is short":

	_gets           clear dired    DELETED FROM libc BY BELL LABS IN 1988
	_N_BADMAG etc.  size file      a.out.h skew, the n_un family again
	_ipcpath        settod         the makefile does not say -lipc
	_stdscr         plot           nor -lcurses
	-lbsd -lfb      u9fs pico      libraries that exist nowhere on the tape

Twenty-four more units have **no row in `world.link` at all**, which is a
statement rather than a shortfall: 71 units carry more than one `main()` and are
subsystems rather than programs (see the gotcha), and `ed/` and `sort/` are the
tape's second generation of each.

**K10.4 — COMPILE THE FILES THE BUILD COMPILES** (2026-08-18, same runs). The
survey read every `.c` in a unit's directory, and `cmd/sh` failed on a
`profile.c` that is **not in its own `$OFILES`** — so it compiled a file the tape
never compiles and failed the shell on it. Reading each unit's own object list is
a *fidelity* change, not a way to raise a number, and it is worth **247 → 251
compiled and 200 → 203 linked**. Three witnesses and two guards, all in the
gotcha above; every drop and every refusal is in `v10/mk/gen/world.drop`.

A second inconsistency fell out of the first: **`world_link` counted `main()`s
among sources the build does not compile**, so `cmd/sed` was filed as a subsystem
over `osed0.c` and `cmd/tbl` over `oot1.c`. `csources()` honours the drop, so the
main count must too — 281 link rows became 288.

**K11 — THE CEILING WAS V8'S, AND V10 REMOVED IT** (2026-08-18,
`bash tools/v10-bigfs.sh`, **20/20, exit 0**). V10 made, checked, mounted, wrote
to, unmounted and **remounted** a 111,384-block, 435 MB filesystem — 3.6× the
30,752 every previous V10 disk stopped at — and the host reads `flag=1` off it:
the free-block bitmap **outside the superblock**, in the N arm of `filsys`'s
union, which V8's `filsys.h` does not have. `cmd/mkbitfs.c` switches to it
unprompted (`if (size - isize <= MAXSMALL) smallfree(); else largefree(fd);`) and
refuses only when the bitmap reaches `BITMAP-1` blocks of 32,768 bits, so the new
ceiling is **31,457,280 blocks of 4096 = 128 GB** — four hundred times the largest
disk this project emulates.

The two free-space figures agree exactly while coming from different places:
`s_tfree` 110,311, against 110,311 counted bit by bit out of the four bitmap
blocks at the end of the volume. `tools/v10-free.py` reads that arm now, having
answered `None` for it before — and the host is the only place the question can be
asked, because *a full V10 filesystem does not fail, it sleeps*.

The tape's own `mkbitfs` is what built it, via `mkbitfs.mk`: our `v10mkbitfs`
overlay exists only because V8's `hp` driver reads bit 6 of the minor as part of
the drive number, and on V10 the original check is exactly right. So K11 retires
that overlay's reason as well as V8's ceiling.

**K12.0 — NETFS RUNS ON V10** (2026-08-18, `bash tools/v10-netfs.sh`,
**16/16, exit 0**). K12 was scoped as a phase — kernel stream work, a transport,
then a mount — and this is the decisive measurement put ahead of the machinery.
V10 ships `runfs`, which mounts a netfs filesystem on a **pipe** via `fmount(2)`:
no device node, no Interlan, no TCP, no line discipline. `zarf` serves `/usr`, the
mount is `/n/local`, so the whole test is a loopback and `cmp` can hold the
protocol to the byte:

	# ls /n/local     adm bin blit include jerq k10lib lib obj s1 tmp
	# cmp /n/local/include/stdio.h /usr/include/stdio.h    byte-identical
	# cp /etc/motd /n/local/tmp/nbprobe                    and it writes

So **the client, the netb protocol library and the mount all work**, and what
remains of K12 is transport and nothing else. It runs on **K7's kernel built on
top of K10.2's libraries** — `bash tools/v10-kernel.sh
ipnx-v10-ra81.img.stage1.k102`, 17/17 — because `seki` configures `netbfs 0` and
cannot mount one however good the userland is, and `zarf` needs `libnetb.a`.

**`serv/makefile` names the System V directory reader on a Research Unix tree**,
which is the `libc/mkfile names cc for lcc members` finding in another subsystem:
`libdir.c` includes `<dirent.h>`, which r70 does not have, while `resdir.c` sits
beside it saying *"read directories, research-style / uses dirread system call,
which does just what we want"*. **`dirread` is V10 syscall 22** — the slot V8
fills with `sumount` — and `resdir.c` is a complete drop-in at 33 lines against
104, since `libdir`'s extra function is `static`.

**K12 IS COMPLETE — A macOS FOLDER IS MOUNTED INSIDE THE TENTH EDITION,
READ/WRITE** (2026-08-18, `bash tools/v10-tcpfs.sh`, **24/24, exit 0**). V10
autoconfigured the Interlan, brought IP up with the tape's own `dipconfig`, pushed
the TCP line discipline onto `/dev/ip6`, resolved the host by ARP, connected to
`netfsd` and mounted a netafs filesystem with `fmount(2)`. Then it read the share
and wrote to it — a 209-byte file written by the guest lands byte-for-byte on
APFS, and netfsd's trace witnesses both directions (`NNAMI flags=13`, `NWRT
count=209`, `NUPDAT`, `NPUT`; and `NGET`, `NREAD 512 -> 52`, `NREAD off=52 -> 0`
for EOF). **The courier disk is retired.**

**One patch did it, and the machine chose it over the other one.**
`lsys/os/streamio.c`'s `istread()` copied `min(count, …)` and then `freeb(bp)`
regardless, so the read of a reply *header* discarded the payload sharing its
block and the read of the *data* timed out — `neta: read -1 expected 48`, the
kernel's own words. Fixed on V8's proven model and built into `os.a` by the new
overlay-object step in K7 (`cc -S`, `sed -f asm.sed`, `as`, `ar r`, relink; 20/20).
The QDELIM half was **retracted after it hung the machine** — see Gotchas.

**K13 — AND IT NETWORKS BY ITSELF** (2026-08-18, `bash tools/v10-netboot.sh`,
**18/18, exit 0**). K12's transport was built on the spot on every run; this
installs it. `/etc/mknod`, `/dev/ip6`, `/dev/ip17`, `/dev/il1`, `/etc/dipconfig`,
`/etc/tcpconfig` and `/etc/nafsmnt` go onto the image, `/etc/rc` brings the
interface up guarded on `/dev/il0` exactly as V8's does, and then the machine is
**halted and booted again**: the second boot compiles nothing, and two source trees
mount with one installed command each — the 243 MB tape at `/n/tree` and our own
overlay at `/n/ours`, so the guest reads our patched `istread` straight off the
working tree. **`tools/v10-srcdisk.sh` is no longer on the path for reading
source.** This is B0.6 for the Tenth Edition, and it is on the way to Edition 10 in
the app rather than beside it.

**K13.1 — AND IT CAN BUILD A DISK** (same harness, **33/33**). The golden has no
`find`, `chmod`, `ls`, `cpio`, `grep` or `wc`, so a V10 that is to populate a
filesystem cannot walk one. All six are in `mkdep.py`'s `BOOTPATH` now and the
provisioning harness installs them at the paths `bootpath.order`'s third column
names — `/usr/bin/find`, `/bin/chmod`, `/bin/ls`, `/usr/bin/cpio`, `/bin/grep`,
`/usr/bin/wc` — and then **exercises** them: `find` walks `/etc` and
`find . -print | cpio -pd` copies a file. `cpio` appearing in both `FSTOOL_SRC` and
`BOOTPATH` is deliberate, not a duplicated list: the first builds `v10cpio` for the
*Eighth* Edition host that makes V10 media, the second is `/bin/cpio` on the Tenth.

**K14 — AND THE DISK V10 BUILT BOOTS** (2026-08-19,
`bash tools/v10-mkdisk.sh`, **14/14, exit 0**). V10 made two filesystems on a
blank RA81, filled them, halted, and the disk it built **came up to a login
prompt**. Every byte of source arrived over TCP — the 243 MB tape at `/n/tree`,
our overlay at `/n/ours`, the generated makefiles at `/n/mk`, on netfs devices 0,
1 and 2 — so no courier disk appears anywhere in the run. **This settles the
mechanism of rung 10**; what remains for a shippable `v10.disk` is *what to copy*.

The layout is V10's own, and getting there retracted a deviation rather than
adding one — root on `a`, swap on `b`, `/usr` on `c`, mounted by the `/etc/rc` the
golden already ships. The host's independent reading agrees, and the geometry is
Bell Labs':

	                       root (a)        /usr (c)
	filesystem size    1280 blocks     30752 blocks
	i-list               19 blocks       473 blocks
	s_tfree             826 blocks     30115 blocks
	free BY BITMAP      826 blocks     30115 blocks   <- counted, not read
	block 0                            475 of 512 bytes non-zero

**Both i-list figures are identical to the golden's own.** They follow from the
filesystem size and we used Bell Labs' sizes, so what V10 built has the geometry of
what Bell Labs shipped. Three faults on the way, all in the *measurement* rather
than the thing measured, and each is a gotcha above: `ra_sizes[]` is in **sectors**
(so the harness asked for eight times partition `a`, and only the host-side read
said so); `used = s_fsize - s_tfree` **includes the i-list**, which inflated the
content from 2.1 MB to a reported 6.4 and produced a *false* justification for the
two-filesystem layout; and editing `v10-mkdisk.sh` mid-run made bash resume inside
a word and **silently skip the host-side verification** while the guest still
reported 14/14.

**K14's two blemishes are fixed and verified** (same harness, 14/14, exit 0):
`/lib` is back on root where the golden keeps it, and the copied `/etc/mtab` is
truncated so the new disk no longer boots believing the builder's mounts. Both were
confirmed by their **effects** — root free 826 → 664 and `/usr` free 30115 → 30278,
the same 162/163 blocks moving in opposite directions, which is `/lib`'s 631,774
bytes; and boot 2's `cat /etc/mtab` and `umount -a` both print nothing where they
previously printed three stale entries and three errors.

**Rung 8 is answered, and the answer is that the terminal half cannot be built**
(2026-08-19, host-side, no simulator). `muxterm`'s own makefile names `3cc`/`3as`/
`3ld`/`3nm`; `src/man/man9/3cc.9` documents all eight of those tools as the DMD-5620
cross-compiler; and **the man page is the only one of the eight on the tape**. See
Decisions for the full evidence, including that `mux` is absent from V10's live
source tree entirely and that the wire format differs from V8's by exactly one
never-negotiated constant.

**Superseded, kept for the measurements: K12.1 at 21/24.**
V10 autoconfigured the Interlan, brought IP up on it with the tape's own
`dipconfig`, pushed the TCP line discipline onto `/dev/ip6` with `tcpconfig`, put
an ARP frame on the wire, opened a TCP connection to the host and **mounted a
netafs filesystem over it** with `fmount(2)`. netfsd's own trace is the
independent witness: `connection accepted`, `NSTART`, `NSTAT ino=2`, then
`NREAD count=4096 -> 48 bytes` — three 16-byte V8 directory entries, `.`, `..`
and `hello.txt`.

What remains is **one line of kernel**, and the guest printed its own diagnostic:

	# ls /n/host
	neta: read -1 expected 48

`istread()` copies `min(count, …)` and then `freeb(bp)` regardless, so the read of
the reply *header* discards the payload sharing its block and the read of the
*data* times out. That is the N track's own finding — `usr/src/netfs/README` asked
for it ("you'll have to fix things") — and V8's fix is the model. Two named
overlay patches now exist: `lsys/os/streamio.c` (keep the partial block; return
0 for a zero-length read) and `lsys/inet/tcp_device.c` (QDELIM beside QBIGB).
**QDELIM is not what bit** — the header read succeeded — but it stays, because the
short-return branch it guards is reachable on a larger transfer.
- **`fmount`'s FOURTH ARGUMENT IS THE DEVICE NUMBER, NOT A FLAG**, and the
  kernel's own parameter name misleads. `namount(sip, ip, flag, mnt, fstyp)`
  hands it to `nadomount()`, which does `pi.i_dev = flag; iget(&pi, flag,
  ROOTINO)` and builds the root's tag as `(flag<<16)|ROOTINO`. V8 passed dev as
  `gmount`'s *second* argument; V10 moved it to the last.
- **V10's CLIENT FAKES THE ROOT AND INVENTS ITS OWN TAG, and Bell Labs wrote down
  why.** `lsys/fs/neta.c`'s `nadomount()`: *"fake the root, rather than sending
  NAGET now, to avoid a deadlock when a server mounts itself / the next stat will
  correct it"*, with `rip->i_un.i_tag = (flag<<16)|ROOTINO`. V8's client opens
  every mount with `NGET(dev, ROOTINO)`, which is what allocates a tag in our
  server; V10 skips it, and `nastat()` copies mode/nlink/uid/gid/size/tm out of
  the reply and **not** `y.tag`, so it keeps that tag for the life of the mount.
  Answering ENOENT to it gave a mount that succeeded and then had no root — `ls`
  said *No such file or directory* while the server logged six requests it had
  answered correctly. `Export.handle(tag:orRootIno:)` binds the root handle to the
  client's tag, and only for `rootIno`: an unknown tag on any other inode really
  is a protocol error.
- **A FLOATING VECTOR AND AN ADDRESS 040 OUT.** `ipnx780.m` carries `ni1010a 0 ub
  0 reg 0764000 vec 0350` while `libsimh/patches/apply-il.sh` puts the card at
  I/O-page offset **04040** (= 0764040, because 0164040 is what V8's kernel
  declares and what `dev/il.c`'s `ilstd[]` calls the board's standard address) and
  marks the vector `flt VEC`. The Unibus-to-SIMH mapping is a measurement, not a
  header: the UDA50A shows as `2013F468` against the config's `0772150`, so
  `IOPAGEBASE` is `0x20100000` and Unibus 0764000 is SIMH `2013E800`. **`show rq`
  is the wrong control for the vector** — an MSCP controller reports "no vector"
  because the driver hands it one at initialisation, so `vec 0154` proves nothing.
  The right control is this file's own note that `dz11 0 vec 0300` is SIMH's `C0`:
  plain octal-to-hex of the same number, so 0350 is **0xE8**. The `C8-CC` *range*
  SIMH prints is `il_rint_ack` returning `il_dib.vec` and `il_cint_ack` returning
  `il_dib.vec + 4`, which is why the config names only the base.

**RUNG 8's HOST HALF IS DONE — V10 BUILT `mux`** (2026-08-21,
`bash tools/v10-mux.sh`, **15/15**). Ten objects compiled and linked by V10's own
toolchain: the seven from the `ix` tree, `labEQ.o`/`labLE.o` from Bell Labs' own
IX libc **unchanged**, and our `muxix.o` supplying `unsafe`/`pex`/`unpex`. It
links, is executable, and installs to `/usr/w15/usr/jerq/bin/mux`, and
`MAXPKTDSIZE` is asserted **on the machine** at the tape's 124 through
`sizeof(struct Packet) == 128`.

Six runs, six named faults, and three of them are durable lessons:

- **THE BUILD MUST BE IN-TREE, because V10's cpp cannot resolve a QUOTED include
  for an out-of-tree source and `-I` does not help.** `mux.c` includes five
  headers with quotes; with `-I/n/mux` explicitly on the command line cpp still
  answered `Can't find include file` for all five, and **never looked for any of
  them** — each name appears once in netfsd's trace and that once is *make*
  stat'ing a prerequisite. The control is in the same run: `aouthdr.h`, which
  `32ld.c` includes with **angle** brackets, appears three times because cpp
  really did search there. `cpp.c`'s loop is
  `for (dirp = dirs + inctype; *dirp; ++dirp)` with `inctype` 1 for angle and
  **0 for quoted**, and `dirs[0]` is a pointer into `argv` that `trmdir()`
  truncated in place. The tape never meets it because `mkfile:53` compiles in the
  source directory over a *relative* `INCL = $PDIR`. **So: if the build compiles
  it, it lives locally.** The same fault recurred one directory over as
  `0: No source file .../labLE.c`, again after a successful lookup.
- **`JTOOB`, `JLABEL` and `JPEX` are used in three IX files and defined NOWHERE
  in the 25,682** — IX's own `jioctl.h` is lost, like the `3cc` family. They are
  **wire-protocol opcodes**, not ioctls (`ctlvec[0]=JLABEL`), and `mux.c:232`'s
  `buf[0]=JTIMO` proves the family is `JTYPE|n` put through a char. The surviving
  headers use 1–10 and **disagree about 9 and 10**, so IX's numbers cannot be
  deduced. Ours are a **recorded deviation** in `v10/src/include/jioctl.h`,
  admissible only because both paths are dead twice over — labels and pex are
  unused on V10, and the terminal that would read them cannot be built.
- **The oracle is 0 of 7 byte-identical, and that is the right answer.** Same
  finding as libc: Bell Labs' 1989 objects were built by a compiler that no
  longer exists. What the archive was good for it already gave — `_buf` as a
  124-byte common.

What remains for a *full* rung 8 is pointing this `mux` at the 5620 `muxterm`
this project builds for V8, which needs `MAXPKTDSIZE` matched at **64** — a
deviation for interoperability with its own patch and its own decision.

Next, in order of what is blocked by what:
- **What to copy** for a shippable `v10.disk` — K10.3's 203 commands, K10.2's 26
  libraries, stage 1's toolchain — then the Swift work to carry a second machine
  beside V8 (two committed images with identity stamps, two working copies under
  `~/Library/Application Support/ipnx/`, `app-check` proving both chains).
- **Rung 8's reachable half** is K15 — `bash tools/v10-mux.sh`, generator in
  `v10/mk/mkdep.py`'s `emit_mux()`. Built at the tape's **124**, not 64: see the
  correction under the 5620-compiler entry in Decisions.
  - **THE MISSING-HEADER COUNT WAS FOUR AND IS SIX, because a scan of the seven
    sources' own includes is not the requirement — the TRANSITIVE closure is.**
    `sys/xtproto.h` is reached only through `proto.h`/`packets.h` and
    `sys/jlabel.h` only through `sys/label.h`, so **no `.c` file names either**
    and two rounds of reading the sources missed both. And two entries in the
    old list were wrong rather than merely incomplete: `tty.h` and `jioctl.h`
    are **already installed** (`tty.h` is one of the 21 in the v10blit tree that
    `v10_jerq_inc` copies; `jioctl.h` comes from our overlay), and `sys/label.h`
    is taken from the **ix** tree, not from "r70's top-level `include/label.h`"
    — r70's copy includes `sys/jlabel.h` and **r70 has no `jlabel.h` anywhere**,
    so V10's own copy is unusable as shipped. What is actually needed:

	aouthdr.h filehdr.h scnhdr.h   630/3binc     COFF, for 32ld.c
	sys/label.h sys/pex.h          history/ix    the V9 path convention
	sys/jlabel.h                   history/ix    reached via label.h

    They install into `/usr/jerq/include`, never `/usr/include`: all 44
    consumers of `<sys/label.h>` and every consumer of `<sys/pex.h>` are under
    `src/history/ix/`, so this is the **Ninth** edition's path convention rather
    than a gap in V10, whose own tree writes `<label.h>` unprefixed.
  - **`sys/xtproto.h` IS A FALSE ALARM and the tape says so in both files.**
    `proto.h` and `packets.h` each wrap it in `#ifdef XT` with every definition
    inline in the `#else`, and the mkfile never defines `XT`. V8's copies are
    structurally identical and V8 *does* ship `jerq/include/sys/xtproto.h`, so
    the header is real — it is the XT variant's, and no V10 build of mux wants
    it. Named in `MUX_UNREACHED` with that reason, because a resolver that
    *drops* what it cannot find is how a missing header becomes a mystery three
    hours into a build.
  - **The COFF variant was measured, not preferred.** Two copies of each survive
    and a probe compiled against both prints identical sizes and offsets for
    every field `32ld.c` touches (`filehdr` 40, `f_magic@0`, `f_nscns@2`,
    `f_opthdr@32`; `aouthdr` 56; `scnhdr` 72). So provenance decides: the 5620 is
    a WE32100, `630/3binc` is the BELLMAC-32 include tree and its `filehdr.h`
    carries the `F_BM32*` identification flags, while `cmd/kasb` is a **KMC11**
    assembler opening `#define pdp11`. `32ld.c` takes no magic number from a
    header at all — it defines `FBOMAGIC 0560` itself.
  - **Neither directory goes on `-I`, only the six named files.** `630/3binc`
    also holds `ctype.h`, `string.h`, `memory.h`, `search.h`; `history/ix/include`
    holds V9 copies of `sys/param.h`, `sys/types.h`, `sys/stat.h`, `sys/stream.h`,
    `sys/ttyio.h`, `sys/filio.h`. Putting either on `-I` silently replaces V10
    headers with someone else's — the trap already recorded for `include/CC`. mux
    must see **V10's** kernel interface however old its source is.
  - **`pcheck.c` is inline VAX assembly and it compiles.** Its `#ifdef vax` arm
    is four `asm()` lines using the VAX `crc` instruction; `asm` is in V10 ccom's
    keyword table (`scan.c:862`) and V10's `as` knows `crc` at opcode `0x0b` with
    exactly the four operands it writes (`cmd/as/instrs:101`). The 1989 object
    confirms that arm was the one built: `pcheck.o` carries a 64-byte `.data`,
    which is `crc16t[16]`.

Also **submit** — the remaining steps need the Apple account and a
final name decision, all listed in [docs/app-store.md](docs/app-store.md).
**Not yet exercised — one thing, and it needs a human at a mouse**: `mux`/`jim`
driven by the Mac's real pointer, and `jim` looked at inside a *widened* layer.
Everything around it is proven and the claims that used to sit here were stale:
"Crisp" scaling was compared on screen on 2026-08-09 and measured at exactly
2.000× ([docs/a3-notes.md](docs/a3-notes.md)); `muxterm.w` at 1152 lights x=1151
under `tools/drive-widemux.sh` ([docs/screen-size.md](docs/screen-size.md)); and
`jim` needs no widening at all — `3nm` shows it exports `Jdisplayp`, a
`*struct-Bitmap` the layer system fills in at runtime, and no `display` of its
own, so it follows a resized screen for free. Update the checkboxes in
[docs/roadmap.md](docs/roadmap.md) as phases complete.

**Driving the Mac app from a script**: `open -n app --stdout LOG` *appends*, so
truncate the log first or one file accumulates every run and looks like concurrent
instances. Never use AppleScript `activate`/`keystroke` against the app — both resolve
the *bundle* through LaunchServices and can launch a second copy, and two VAXes sharing
one `v8.disk` is a filesystem-corruption hazard. Target `tell application id "..."` (or
`System Events` `process`), and assert `pgrep -x ipnx | wc -l` is 1 at every step.
