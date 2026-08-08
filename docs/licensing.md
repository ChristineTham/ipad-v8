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
| SwiftTerm | MIT | Clean |
| Musashi (optional 68K Blit mode) | MIT-terms text in its readme (no SPDX file) | Fine; note in credits |
| Original 68000 Blit ROMs (optional mode) | **No permission statement exists anywhere** | Do not ship. If the mode is ever built: seek permission or bring-your-own-ROM |
| This repository's original content | MIT ([LICENSE](../LICENSE)) | — |

## Open items

- [ ] Email Seth Morabito re: dmd_core license clarity (MIT repo vs. CC BY-NC-SA page footer)
- [ ] Decide bundled-vs-first-launch-download for disk images (legally equivalent under the
      covenant; bundling preferred for 2.5.2 and offline use)
- [ ] Before any 68K Blit mode: resolve Blit ROM provenance/permissions
