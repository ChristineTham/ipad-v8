# Licensing posture

*Constraints in this document are binding on product decisions. Not legal advice; the
posture below deliberately mirrors what the preservation community (TUHS) has done publicly
since 2017. Sources for every claim: [RESEARCH.md](../RESEARCH.md) §9.*

## The governing instrument

Research Unix Editions 8, 9, and 10 are distributable because of the March 2017
Alcatel-Lucent/Nokia statement
([PDF at TUHS](https://www.tuhs.org/Archive/Distributions/Research/Dan_Cross_v8/statement_regarding_Unix_3-7-17.pdf)):

> "…it will not assert its copyright rights with respect to any **non-commercial** copying,
> distribution, performance, display or creation of derivative works of Research Unix®
> Editions 8, 9, and 10."

Three properties matter:

1. It is a **covenant not to assert, not a license** — hedged "to the extent of its ability
   to do so", and it grants no third-party rights.
2. It is **non-commercial only** (clause iv excludes "any rights for commercial purposes").
3. It covers all three editions equally — no per-edition carve-outs.

## Hard product rules derived from it

- The app is **free**. No price, no ads, no in-app purchases tied to Research Unix content.
- The app name and branding **must not contain "UNIX"** (registered trademark of The Open
  Group; the statement grants no trademark rights). "V8", "Edition 8/10", "Research",
  "Blit", "jerq", "5620" are all safe vocabulary.
- The app bundles the statement PDF and a credits screen (TUHS, contributors, UCB).
- Disk images are **bundled**, keeping the app self-contained (App Store rule 2.5.2 —
  the rule that hit iSH in 2020 and iDOS 2 in 2021).

## Component table

| Component | Terms | Implication |
|---|---|---|
| V8 system + `v8.disk` | 2017 covenant (non-commercial) | Bundle in free app; ship statement PDF; credit TUHS |
| V10 source + future `v10.disk` | Same covenant | Same posture |
| 4.1BSD-derived code inside V8/V10 | UCB BSD license | Attribution in credits |
| pcc2 (V10's native compiler) | Research-modified **System III/V-derived** code; outside both the covenant's power ("to the extent of its ability") and the Caldera V1–V7/32V license | Sharpest open item. It stays *inside* the disk image (as at TUHS since 2017, unchallenged); documented here; never linked into app code |
| V10 manual (Saunders, 1990) | Published copyrighted book; Norman Wilson: treat docs as encumbered | Don't bundle scans; link out (cat-v, TUHS) |
| open-simh | MIT | Clean |
| dmd_core + embedded 5620 firmware | Crate/repo: MIT. Firmware: AT&T released the ROM **source** under GPL, 1994 ([5620rom](https://github.com/dmdmtg/5620rom)) | Clean. One loomcom web page shows a CC BY-NC-SA site notice — almost certainly the blog prose, not the code; **TODO: courtesy email to Seth Morabito to confirm** |
| AT&T 5620 ROM source (`5620rom`) | AT&T copyright, **GPL-2.0**, released by Dave Dykstra 25 Mar 1994 | **Read, not linked** — see below |
| SwiftTerm | MIT | Clean |
| Musashi (optional 68K Blit mode) | MIT-terms text in its readme (no SPDX file) | Fine; note in credits |
| Original 68000 Blit ROMs (optional mode) | **No permission statement exists anywhere** | Do not ship. If the mode is ever built: seek permission or bring-your-own-ROM |
| This repository's original content | MIT ([LICENSE](../LICENSE)) | — |

## The GPL 5620 ROM source, and exactly how far we used it *(2026-08-10)*

AT&T's own 5620 firmware source was published: Dave Dykstra of Bell Labs released
the ROM source tape on **25 March 1994** — AT&T copyright, distributable under the
**GPL** — and it survives as [dmdmtg/5620rom](https://github.com/dmdmtg/5620rom).
Its README names `lsys.8;7;3`, the exact firmware ipnx runs.

We used it to make the terminal work at screen sizes other than 800×1024, and the
boundary matters, so it is written down precisely:

- **What ships is unchanged.** The app embeds the ROM **binary** that dmd_core
  already carries. We have not built a ROM from the GPL source, and we do not
  distribute that source or anything compiled from it.
- **What we read** was `5620rom/src/term/selftest.c` — specifically `rom()`, the
  power-on ROM checksum. It is a six-line algorithm (add byte, rotate the 16-bit
  accumulator left, ones-complement, two check bytes at the end of the image).
  Our `repair_rom_checksum()` in `tools/dmdbridge/patches/dmd_core-screen-size.diff`
  is an independent Rust expression of that algorithm, written against the shipped
  binaries and **verified against them numerically** before the source was
  transcribed: 8;7;3 → `0xb425` at `0xFFFE`, 8;7;5 → `0xb1ef` at `0x1FFFE`.
  The comment there cites the file it came from.
- **Why this is the conservative reading.** A checksum formula is an unpatentable
  method, the expression is ours, and nothing GPL-licensed is copied, linked or
  distributed. But it *was* learned from GPL source, so it is disclosed here rather
  than quietly absorbed.
- **The exposure shrank again on 2026-08-10.** The terminal now boots at the stock
  800×1024 and is resized while running ([screen-size.md](screen-size.md)), so the
  power-on self-test runs against the **pristine** ROM and the checksum is no longer
  on the boot path at all. At the default size every byte the resize code writes is
  the byte already in the image — a default boot re-stamps the firmware with itself.
- We also read `bootrom.s`, `setup.h`, `vitty.c`, `windowproc.c`, the linker script
  and `doc/memmap/map3` to locate the geometry, and the namelist
  `lsys.nm.1.1` for ROM symbol addresses. Nothing was copied: what the code uses from
  all of that is four addresses and two integers — `display` at `0x9ca8`, `maxaddr`
  at `0xa37c`, and the constants 800 and 1024 — every one of which is also directly
  observable in the ROM binary we already ship, and each was verified against it.

**The line not to cross without deciding first:** building a modified 5620 ROM from
that tree — which is the obvious way to get a natively wide-screen terminal — makes
the shipped firmware a GPL derivative. That is compatible with a free app, but it
would oblige us to offer the corresponding source and would put a GPL component
inside an App Store binary, which has a contested history. Take that decision
deliberately, in the open, and only if the alternative (patching the existing image,
as now) proves insufficient.

## Open items

- [ ] Email Seth Morabito re: dmd_core license clarity (MIT repo vs. CC BY-NC-SA page footer)
- [ ] If a rebuilt 5620 ROM is ever wanted: decide the GPL question above **before**
      writing the build, not after
- [ ] Decide bundled-vs-first-launch-download for disk images (legally equivalent under the
      covenant; bundling preferred for 2.5.2 and offline use)
- [ ] Before any 68K Blit mode: resolve Blit ROM provenance/permissions
