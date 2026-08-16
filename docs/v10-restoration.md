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
- **V9 is not part of this track.** The surviving V9 is a Sun-3 port with no VAX kernel
  code; it contributes nothing to a VAX lineage.

### Why the binaries went unnoticed

They are not hidden. `tar tjf` lists them, and the CSRC machines' own build
leftovers (`main.o` beside `main.c`) are scattered through the tree in plain
sight. But the tarball is 243 MB of a system nobody could run, the summaries
that describe it say "source", and nothing before this project had a V8 to try
them on. The lesson is narrow and worth keeping: **the archive was never
audited by file type**, and one pass over the magic numbers answered a question
the plan had assumed for nine years.

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
