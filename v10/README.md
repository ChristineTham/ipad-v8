# v10/ — the record, not the tree

Two generated files and this note. **The Tenth Edition source is not committed
here**, and that is deliberate.

`v8/` is different: that tape became *our* source tree, we own it, and later
divergence from Bell Labs is what `git log` is for. V10 is not ours in the
same way. The working convention for Track B
([docs/v10-restoration.md](../docs/v10-restoration.md)) is that **the pristine
tarballs stay pristine and every change of ours is a logged patch**, because
the patch series is the publishable artifact — the thing someone else can
apply to their own copy from TUHS. A 243 MB tree with our edits stirred into
it would be worth much less to the people who have been waiting for this since
2017, and would be a fifth of a gigabyte in every clone of this repository
forever.

So the tree lives in `work/v10/` (gitignored) and what git keeps is the record
that our copy is complete and unaltered.

| | |
|---|---|
| `MANIFEST` | every one of the 25,682 files: kind, mode, size, sha256, true path, stored path |
| `CASEMAP` | how the 196 case collisions were resolved |

Both are generated. Rebuild the tree, or check it:

```bash
tools/v10-import.py            # write work/v10/ from the three tarballs
tools/v10-import.py --verify   # 25,682/25,682, in about fifteen seconds
```

The tarballs it wants are `work/v10src.tar.bz2`, `work/v10blit.tar.bz2` and
`work/r70include.tar`, all from
[TUHS](https://www.tuhs.org/Archive/Distributions/Research/); the tool names
the right subdirectory when one is missing.

## The `kind` column is the interesting one

Every file is classified by its first four bytes, and the counts are the
correction that reshaped Track B:

| kind | count |
|---|---|
| text | 22,315 |
| object — VAX a.out 0407 | 1,525 |
| binary | 1,209 |
| **exec — VAX a.out 0410/0413** | **483** |
| archive — `ar(1)` | 150 |

V10 is described everywhere, including in this repository's own docs until
2026-08-16, as a source-only snapshot with no binaries. It is not: those 483
include the C compiler, the assembler and a complete `libc.a`, and they run on
V8. [docs/v10-log/2026-08-16.md](../docs/v10-log/2026-08-16.md).

## Why CASEMAP has to exist

196 paths in the tarballs differ from another only by case, and macOS is
case-insensitive, so a plain `tar xjf` merges them and drops files — silently,
with a zero exit status. Most are the CSRC machines' build litter (`main.O`
beside `main.o`), but two are real source: `sys/io/Nttyld.c` beside
`nttyld.c`, in the kernel, and `libc/stdio/ostdio/doprnt.S` beside `doprnt.s`.

The loser of each group is stored with its capitals percent-escaped
(`Nttyld.c` → `%4Ettyld.c`) and `netfs/Sources/NetFS/CaseMap.swift` serves the
true name to the guest, whose filesystem is case-sensitive and does not care.
The escaped spelling must never reach the guest, and not for tidiness: a
`struct direct` name field is 14 bytes and `%43%49%52%43%4C%45` is 18.
