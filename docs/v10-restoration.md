# Track B — the V10 restoration

*Goal: the first bootable Tenth Edition Research Unix, ever — built from the surviving
source using a running V8 as the cross-build host, targeted at a SIMH-emulated VAX, and
ultimately shipped in the app as "Edition 10". Evidence for every claim:
[RESEARCH.md](../RESEARCH.md) §7.*

## Ground truth

- **Nobody has ever booted V10.** It survives as a source-only snapshot of the post-Tenth-
  Edition CSRC tree (~1995): no binaries, no boot media. Warren Toomey's
  [2017 call for volunteers](https://www.tuhs.org/pipermail/tuhs/2017-April/011079.html)
  is still unanswered.
- The source is nevertheless **remarkably complete**: full VAX kernel (six machine
  families), structurally complete libc, 378 commands, the whole 5620 stack (`v10blit` =
  `/usr/jerq` with `mux`, `32ld`, **`sam` + `samterm`**), and docs.
- **V9 is not part of this track.** The surviving V9 is a Sun-3 port with no VAX kernel
  code; it contributes nothing to a VAX lineage.

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

```
4.1BSD ──(myv8, proven)──▶ V8 on SIMH vax780
  V8 cc builds ──▶ V10 toolchain (ccom, as, c2)
  ccom builds  ──▶ V10 libc + userland      ← reconcile /usr/include skew here
  ccom builds  ──▶ V10 kernel + boot block  ← lsys/boot constraints (below)
  mkfs + dd    ──▶ v10.disk ──▶ first boot attempt
```

**Toolchain names, corrected against the actual tree (2026-08-09).** Earlier
drafts of this plan said "pcc2". The tarball has no `pcc2`: the compiler is
**`cmd/ccom`** (1.66 MB, 127 files, with `common/` and a `vax/` code
generator), alongside an older **`cmd/pcc1/pcc`**, the peephole optimiser
**`cmd/c2`**, the assembler **`cmd/as`**, and `libcc`. **No system linker is
present under `cmd/`** — the only `ld` source in the tree is `630/src/630ld.c`,
which belongs to the terminal. Whether V10 expects the host's `ld` (the a.out
format is shared with V8) or the loader is simply absent from this snapshot —
as `rc`'s source is — is the first thing B1 has to settle, because it decides
whether V8's own `ld` can close the loop.

Why through V8: the toolchain is written to be built *on a Research Unix system*, and V8
under SIMH is the only bootable one in existence. The community assumed this route in 2017
(Warner Losh: "reconstruct v8, v9 and v10 to varying degrees"); nobody has demonstrated it.

**Escape hatch** (if V8-hosted builds prove intractable): reconstruct pcc2 + SGS as modern
cross-tools on macOS. More total work, less authentic, but decouples from V8's 1985 limits.

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
  failures; reconcile per-failure and log each one.
- **`rc` shell source absent** (man pages survive) — use `sh`, which is present.
- **pcc2 provenance**: System III/V-derived; stays inside the image; see
  [licensing.md](licensing.md).
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

1. pcc2 built by V8's cc compiles a V10 hello.c
2. One mid-size V10 command builds and runs on V8 (toolchain trusted)
3. V10 libc builds
4. Core userland builds (sh, init, getty, login, mount, fs tools, mux host side)
5. `star` kernel links
6. Boot block + filesystem image assemble
7. **Kernel reaches single-user on SIMH** ← the headline moment; announce
8. Multi-user; `mux` from a dmd_core 5620 (firmware 8;7;3 — protocol unchanged from V8)
9. `sam`/`samterm` running
10. Reproducible `v10.disk` build script → merge into the app as "Edition 10"
