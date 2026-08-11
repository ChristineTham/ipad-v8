# The ipnx disk

`ipnx-v8-rp07.img.xz` is Research Unix 8th Edition **as this project builds
it** — an RP07 disk image, xz-compressed, with a `.sha256` of the expanded
file beside it.

```bash
python3 ../tools/image-pack.py unpack    # -> work/myv8/rp07new, sha256 checked
python3 ../tools/image-pack.py check     # verify without expanding to disk
```

It is the only binary in this repository, and it is here for one reason: it
is the **input to the next build**. Stage 8 lifts 1406 files off it that Bell
Labs shipped without source — the games, the 5620 cross-toolchain, `cfront` —
listed in `v8/mk/gen/carry.txt`. With this committed, the build's only
external input is the TUHS tapes, and `v8/MANIFEST` already accounts for
those.

Everything else on the disk is built from `v8/` or is text already in git.
Which is which, and why retiring the TUHS image loses nothing, is
[docs/golden-disk.md](../docs/golden-disk.md).

Do not add a second binary here. `.gitignore` and
`tools/hook-block-binaries.sh` both name this exact path, so the rule that
big binaries stay out of the repo is still a rule.
