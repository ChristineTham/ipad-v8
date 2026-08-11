# The ipnx golden disk

The disk this project runs is now one we build. This is the record of what is
on it, where each file comes from, and why the TUHS image it replaces can be
retired without losing anything.

Built by [stage 8](build-from-source.md) — `v8/mk/builddisk.sh` — onto an
RP07: root 7942 blocks (partition `a`), `/usr` 464,000 blocks (partition `f`).
Committed to git as `image/ipnx-v8-rp07.img.xz`.

## Where every file comes from

Four origins, each decided by a generated file rather than by a person, so
none of them can quietly drift from the tree:

| origin | decided by | what it is |
| --- | --- | --- |
| **built** | `v8/mk/gen/provenance.txt` (`build`) | 206 commands, 19 libraries, 224 headers, the kernel — stages 4 to 7 |
| **carried** | `v8/mk/gen/carry.txt` | 1406 files that exist *only* on the reference image |
| **fast-path** | `v8/mk/gen/fromgold.txt` | 2263 runtime files whose image copy is byte-identical to `v8/` |
| **ours** | `v8/mk/gen/fromsrc.txt`, plus three named in `builddisk.sh` | files where `v8/` and the image differ |

`tools/mkcarry.py` generates the last three from the reference image and
`v8/MANIFEST`. `tools/drive-stages48.sh` refuses to build against a stale
set, the same way it already refuses a stale `mkdep.py`.

### Why "carried" is not a defect

The 1985 tape is not a complete system. Bell Labs shipped binaries whose
sources they never released — all 34 games among them, the whole `sgs`
cross-toolchain for the 5620, `cfront`, `compat`. `v8/MANIFEST` records
every one as `excluded`, with size and sha256, so the gap is auditable
rather than implicit.

`carry.txt` is exactly that set, plus what is on the image and not on the
tape at all: the Labs' own kernel build directory (`/usr/sys/alice`), the
`config(8)` binary, `/usr/inet`'s networking commands, and the ar archives
that the import unpacked into directories.

### Why "fast-path" is not a shortcut

2263 of the 2264 runtime files — nroff's macros, terminal tables, the
manual, the games' data, the 5620's fonts and icons — are byte-identical on
the image and in `v8/`. `mkcarry.py` establishes that with sha256 **every
time it regenerates the lists**, and any file that stops matching moves to
`fromsrc.txt` by itself. The repo stays authoritative; the image is used as
a local cache of bytes we have already proven we own.

It matters because netfs costs a round trip per file through an emulated
VAX, an emulated Interlan and SLiRP — measured at about 30 files a minute.
All 2264 over the wire is ninety minutes, of which eighty-nine deliver bytes
the machine already has mounted. `cpio` does the same set in four seconds.

## Retiring the TUHS image

The question is not "does our disk equal theirs". It does not, and should
not: we build newer binaries from the same source, and we skip their local
state. The question that gates retirement is containment —

> every file on the TUHS image is either on ours, or in git, or deliberately
> regenerated

— and `tools/retire-check.py` decides it. Every file falls into one of:

- **on ours** — built or carried.
- **in git** — `MANIFEST` calls it `source`, and the stored file is present.
  The tape's text lives in the repo, so the image is not the only copy.
  Content is proven separately by `tools/v8-import.py --verify`, which
  re-hashes every stored file against `MANIFEST`.
- **by policy** — `/dev` (`makedev.sh` builds it from `v8/proto-dev`), the
  kernel (stage 7 builds it), `/tmp`, `/usr/adm`, `/usr/spool`, `lost+found`,
  `/etc/utmp`, `/etc/mtab`. Each named individually, never a wildcard.

Anything left over is a file that exists nowhere but that disk, and the check
fails while even one remains.

```bash
python3 tools/retire-check.py -v
```

### What the first run found

Four files, none of which a boot test would ever have noticed — the disk
booted cleanly without them:

- **`bcd`** — built into `DESTDIR/usr/games`, and stage 8's copy loop never
  listed `usr/games`. A command we build was absent from the disk while
  every report said it had been built.
- **`yacc`**, **`strip`** — installed to `TOOLDIR/bin`, so they reached the
  toolchain and never the system. `where.txt`, the reference image and our
  own `provenance.txt` all say `/usr/bin`; the build was the odd one out.
  This one had teeth: `mkdep.py` defaults `YACCPATH` to `/usr/bin/yacc`, so
  the system we built could not run its own generated makefiles without an
  override.
- **`wmux`** — ours, from A4. On the tape nowhere, so no `MANIFEST` row
  describes it and no generated list picks it up. It had to be named in
  `builddisk.sh` or it silently did not ship.

Moving `yacc` and `strip` invalidates the stage-3 toolchain, so that fix
needed a full rebuild from stage 1, not a stage-8 re-run.

## Reading a disk without booting it

`tools/v8fs.py` reads a V8 filesystem out of a SIMH RP06/RP07 image directly
from macOS. It made the whole audit above cheap: a question that used to
mean booting a VAX and reading `find` off a serial line now takes a second.

```bash
python3 tools/v8fs.py stat work/myv8/rp07new:a       # superblock + counts
python3 tools/v8fs.py ls   work/myv8/rp07new:f /jerq/bin
python3 tools/v8fs.py cat  work/myv8/rp07new:a /etc/rc
python3 tools/v8fs.py diff work/myv8/rp06v8.golden:g work/myv8/rp07new:f
```

`IMAGE:PART` selects the partition — `a` is root, `g` is `/usr` on an RP06
and `f` on an RP07. The drive type is inferred from the file size.

Every constant is quoted from the tree rather than remembered:

| what | where |
| --- | --- |
| `BSIZE` 1024, `INOPB` 16, `SUPERB` 1, `ROOTINO` 2, `itod`/`itoo` | `usr/include/sys/param.h` |
| 64-byte dinode, "39 used; 13 addresses of 3 bytes each" | `usr/include/sys/ino.h` |
| 16-byte `direct`: `ino_t` + `char[14]` | `usr/include/sys/dir.h` |
| "blocks 0..NADDR-4 are direct blocks" → 10 direct, then single/double/triple | `usr/sys/sys/subr.c` `bmap` |
| partition tables in **sectors**, offsets in **cylinders** | `usr/sys/dev/hp.c` |

The one trap is `usr/src/libc/gen/l3tol.c`: on the VAX a 3-byte disk address
is little-endian with a zero high byte, and the **pdp11 arm of the same
file** packs the identical bytes in a different order. Using the wrong one
gives inode addresses that look almost plausible.

## The image in git

`CLAUDE.md` says big binaries never enter the repo. This is the one
exception, and it is narrow on purpose: exactly one path, our own output,
and only because it is the **input to the next build** — stage 8 lifts
`carry.txt` off it. With it committed, the build's only external input is
the tapes, which `v8/MANIFEST` already accounts for.

```bash
python3 tools/image-pack.py pack     # work/myv8/rp07new -> image/*.img.xz
python3 tools/image-pack.py unpack   # and back
python3 tools/image-pack.py check    # verify the committed copy
```

xz, not gzip: measured on the dense 40 MB of a V8 image, gzip -9 gives
14.3%, bzip2 -9 11.5%, xz 8.8% — and the gap widens across a 516 MB volume
that is mostly free blocks. Python's `lzma` is the same compressor and is in
the standard library, so this needs no `xz(1)` on the host; macOS ships none.

**Zero the file before the build that makes the artefact.** `mkfs` writes a
fresh i-list and free list but does not clear data blocks, so a second stage
8 over the same file leaves the previous run's contents in what the new
filesystem calls free space. Invisible to the guest; extremely visible to the
compressor. `image-pack.py pack` reports the nonzero fraction for exactly
this reason.
