#!/usr/bin/env python3
"""Move directory trees between the host and a SIMH-emulated Research Unix.

SIMH has no host-directory passthrough (no 9p, no virtfs — the VAX-11/780 had
no such concept), so bulk transfer goes through emulated media. This packs a
tree into a SIMH .tap tape container that V8's `tar` reads natively, and
unpacks tapes the guest writes back.

    tapeio.py pack   <dir> <out.tap>     # host -> guest
    tapeio.py unpack <in.tap> <dir>      # guest -> host
    tapeio.py info   <file.tap>          # dump record structure

Guest side (nodes per docs/media-exchange.md):
    cd /v10 && tar xvfb /dev/rht0 20     # extract
    tar cvfb /dev/rht0 20 .              # write

Two format details make this work, and both are easy to get wrong:

* **V7 tar, not ustar.** `tar --format=v7` writes 100-byte names with no
  `ustar` magic and stores directories as trailing-slash names with a NUL
  typeflag. ustar would split long names into a prefix field that V7 tar
  cannot see, silently truncating them — hence the hard name-length check.
* **Tape records, not a byte stream.** The .tap container reproduces physical
  tape records, which is what the guest's tape driver returns per read. The
  default 512-byte record and the closing pair of tape marks match the TUHS
  V8 distribution tapes byte-for-byte — the layout `tar xpb 20` is already
  known to extract on this exact guest software. Guest-written tapes come
  back with blocking*512-byte records instead; unpack handles any size.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

TMK = 0xFFFFFFFF & 0x00000000  # tape mark
EOM = 0xFFFFFFFF               # end of medium
GAP = 0xFFFFFFFE               # erase gap
V7_NAME_MAX = 100              # V7 tar header name field


def _tar() -> str:
    """bsdtar, which is the only tar here that writes --format=v7."""
    return "/usr/bin/tar"


def _check_names(root: str) -> list[str]:
    """V7 tar truncates anything past 100 bytes. Find those before we ship."""
    too_long = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        for name in list(dirnames) + filenames:
            rel = name if rel_dir == "." else os.path.join(rel_dir, name)
            # Directories are stored with a trailing slash, costing one byte.
            width = len(rel.encode()) + (1 if name in dirnames else 0)
            if width > V7_NAME_MAX:
                too_long.append(rel)
    return sorted(too_long)


def pack(src: str, dest: str, blocking: int, record: int, allow_long: bool) -> None:
    if not os.path.isdir(src):
        sys.exit(f"tapeio: {src} is not a directory")

    long_names = _check_names(src)
    if long_names:
        head = "\n".join("    " + n for n in long_names[:10])
        more = f"\n    ... and {len(long_names) - 10} more" if len(long_names) > 10 else ""
        msg = (f"tapeio: {len(long_names)} path(s) exceed V7 tar's {V7_NAME_MAX}-byte "
               f"name field and would be truncated:\n{head}{more}")
        if not allow_long:
            sys.exit(msg + "\n  Split the tree, shorten paths, or pass --allow-long-names.")
        print(msg + "\n  --allow-long-names given; continuing.", file=sys.stderr)

    with tempfile.TemporaryDirectory() as tmp:
        tar_path = os.path.join(tmp, "payload.tar")
        # Name the top-level entries explicitly rather than passing ".": that
        # keeps stored paths relative to src *without* a "./" prefix, which
        # V7 tar would otherwise reproduce literally (and it has no use for a
        # "./" directory entry).
        entries = sorted(os.listdir(src))
        if not entries:
            sys.exit(f"tapeio: {src} is empty")
        subprocess.run(
            [_tar(), "--format=v7", "-b", str(blocking), "-cf", tar_path, "-C", src, *entries],
            check=True,
        )
        size = os.path.getsize(tar_path)
        if size == 0:
            sys.exit(f"tapeio: {src} produced an empty archive")
        records = 0
        with open(tar_path, "rb") as fin, open(dest, "wb") as fout:
            while True:
                chunk = fin.read(record)
                if not chunk:
                    break
                if len(chunk) < record:
                    chunk += b"\x00" * (record - len(chunk))  # tape records are fixed
                hdr = struct.pack("<I", len(chunk))
                fout.write(hdr)
                fout.write(chunk)
                fout.write(hdr)
                records += 1
            # Two tape marks and no end-of-medium word, matching the TUHS
            # distribution tapes exactly.
            fout.write(struct.pack("<I", TMK))
            fout.write(struct.pack("<I", TMK))

    print(f"{dest}: {records} record(s) of {record} B "
          f"({size} B tar), blocking factor {blocking}")


def _build_tar(src: str, tar_path: str, blocking: int, allow_long: bool) -> int:
    """v7-format tar of src's contents. Returns its size."""
    long_names = _check_names(src)
    if long_names:
        head = "\n".join("    " + n for n in long_names[:10])
        more = f"\n    ... and {len(long_names) - 10} more" if len(long_names) > 10 else ""
        msg = (f"tapeio: {len(long_names)} path(s) exceed V7 tar's {V7_NAME_MAX}-byte "
               f"name field and would be truncated:\n{head}{more}")
        if not allow_long:
            sys.exit(msg + "\n  Split the tree, shorten paths, or pass --allow-long-names.")
        print(msg + "\n  --allow-long-names given; continuing.", file=sys.stderr)

    entries = sorted(os.listdir(src))
    if not entries:
        sys.exit(f"tapeio: {src} is empty")
    subprocess.run(
        [_tar(), "--format=v7", "-b", str(blocking), "-cf", tar_path, "-C", src, *entries],
        check=True,
    )
    return os.path.getsize(tar_path)


def pack_disk(src: str, image: str, offset: int, size: int,
              blocking: int, allow_long: bool) -> None:
    """Write a tar image onto a raw disk partition.

    This is the courier that actually works on open-simh: V8's ht tape driver
    does a 16-bit read of a Massbus register that SIMH rejects (it tolerates
    that only in its VAX-750 build), panicking the kernel. The hp disk driver
    has no such problem, and tar neither knows nor cares whether the
    sequential blocks it reads come from a tape or a raw disk.

    The image is patched in place, never truncated, so a partition elsewhere
    in the same file can hold a live filesystem.
    """
    if not os.path.isdir(src):
        sys.exit(f"tapeio: {src} is not a directory")

    with tempfile.TemporaryDirectory() as tmp:
        tar_path = os.path.join(tmp, "payload.tar")
        written = _build_tar(src, tar_path, blocking, allow_long)
        if size and written > size:
            sys.exit(f"tapeio: archive is {written:,} B but the partition holds "
                     f"{size:,} B — split the tree across loads")
        mode = "r+b" if os.path.exists(image) else "wb"
        with open(image, mode) as img, open(tar_path, "rb") as fin:
            img.seek(offset)
            shutil.copyfileobj(fin, img)

    pct = f", {100.0 * written / size:.1f}% of the partition" if size else ""
    print(f"{image}: {written:,} B tar at offset {offset:,}{pct}")


def _tar_checksum_ok(header: bytes) -> bool:
    """V7 tar header checksum: sum of all bytes with the field read as spaces."""
    try:
        want = int(header[148:156].split(b"\x00")[0].strip() or b"-1", 8)
    except ValueError:
        return False
    body = header[:148] + b" " * 8 + header[156:]
    return want in (sum(body), sum(bytes(b - 256 if b > 127 else b for b in body)))


def unpack_disk(image: str, dest: str, offset: int) -> None:
    """Read a tar the guest wrote onto a raw partition.

    Walks the tar headers rather than scanning for two consecutive zero blocks.
    A raw partition has no end-of-file, so the archive's own structure is the
    only reliable terminator — and zero-block scanning is simply wrong: a VAX
    a.out binary contains runs of zeros, so it truncated the archive at the
    first padded region and reported success. That bug made a partial transfer
    look like a verified round trip.
    """
    os.makedirs(dest, exist_ok=True)
    size = os.path.getsize(image)
    blocks = bytearray()
    with open(image, "rb") as img:
        img.seek(offset)
        while True:
            header = img.read(512)
            if len(header) < 512:
                sys.exit(f"tapeio: ran off the end of {image} mid-archive — "
                         f"the transfer was truncated")
            if not header.strip(b"\x00"):
                blocks += header * 2            # end-of-archive marker
                break
            if not _tar_checksum_ok(header):
                sys.exit(f"tapeio: bad tar header checksum {offset + len(blocks)} B "
                         f"into {image} — truncated or not an archive")
            try:
                nbytes = int(header[124:136].split(b"\x00")[0].strip() or b"0", 8)
            except ValueError:
                sys.exit(f"tapeio: unreadable size field {offset + len(blocks)} B in")
            data = img.read(-(-nbytes // 512) * 512)
            blocks += header + data
            if offset + len(blocks) > size:
                sys.exit(f"tapeio: archive claims more data than {image} holds")

    with tempfile.TemporaryDirectory() as tmp:
        tar_path = os.path.join(tmp, "payload.tar")
        with open(tar_path, "wb") as out:
            out.write(blocks)
        subprocess.run([_tar(), "-xf", tar_path, "-C", dest], check=True)
    print(f"{image}@{offset:,}: {len(blocks):,} B -> {dest}")


def _read_records(path: str):
    """Yield data records, stopping at the first tape mark or end of medium."""
    with open(path, "rb") as f:
        while True:
            raw = f.read(4)
            if len(raw) < 4:
                return
            (length,) = struct.unpack("<I", raw)
            if length in (TMK, EOM):
                return
            if length == GAP:
                continue
            length &= 0x00FFFFFF  # strip the error flag; 24-bit max length
            data = f.read(length)
            f.read(length & 1)  # odd-length records carry a pad byte
            trailer = f.read(4)
            if len(trailer) < 4:
                return
            yield data


def unpack(src: str, dest: str) -> None:
    os.makedirs(dest, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tar_path = os.path.join(tmp, "payload.tar")
        total = records = 0
        with open(tar_path, "wb") as out:
            for data in _read_records(src):
                out.write(data)
                total += len(data)
                records += 1
        if not records:
            sys.exit(f"tapeio: {src} holds no data records")
        subprocess.run([_tar(), "-xf", tar_path, "-C", dest], check=True)
    print(f"{src}: {records} record(s), {total} B -> {dest}")


def info(path: str) -> None:
    """Dump the record structure. Useful for comparing against known-good tapes."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        runs = []  # (record length, count) so long tapes stay readable
        marks = 0
        while True:
            raw = f.read(4)
            if len(raw) < 4:
                break
            (length,) = struct.unpack("<I", raw)
            if length == EOM:
                runs.append(("end of medium", 1))
                break
            if length == TMK:
                marks += 1
                runs.append(("tape mark", 1))
                continue
            if length == GAP:
                runs.append(("erase gap", 1))
                continue
            length &= 0x00FFFFFF
            f.seek(length + (length & 1) + 4, os.SEEK_CUR)
            if runs and runs[-1][0] == length:
                runs[-1] = (length, runs[-1][1] + 1)
            else:
                runs.append((length, 1))

    print(f"{path}: {size} B, {marks} tape mark(s)")
    for what, count in runs:
        label = f"{what} B record" if isinstance(what, int) else what
        print(f"  {count:6d} x {label}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("pack", help="directory -> SIMH .tap")
    p.add_argument("dir")
    p.add_argument("tap")
    p.add_argument("-b", "--blocking", type=int, default=20,
                   help="tar blocking factor in 512-byte blocks (default 20)")
    p.add_argument("-r", "--record", type=int, default=512,
                   help="bytes per physical tape record (default 512, matching "
                        "the TUHS V8 tapes)")
    p.add_argument("--allow-long-names", action="store_true",
                   help="proceed despite paths V7 tar will truncate")

    u = sub.add_parser("unpack", help="SIMH .tap -> directory")
    u.add_argument("tap")
    u.add_argument("dir")

    i = sub.add_parser("info", help="dump .tap record structure")
    i.add_argument("tap")

    pd = sub.add_parser("pack-disk", help="directory -> raw disk partition")
    pd.add_argument("dir")
    pd.add_argument("image")
    pd.add_argument("--offset", type=int, default=0,
                    help="byte offset of the partition within the image")
    pd.add_argument("--size", type=int, default=0,
                    help="partition size in bytes; 0 to skip the fit check")
    pd.add_argument("-b", "--blocking", type=int, default=20)
    pd.add_argument("--allow-long-names", action="store_true")

    ud = sub.add_parser("unpack-disk", help="raw disk partition -> directory")
    ud.add_argument("image")
    ud.add_argument("dir")
    ud.add_argument("--offset", type=int, default=0)

    args = ap.parse_args()
    if args.cmd == "pack":
        pack(args.dir, args.tap, args.blocking, args.record, args.allow_long_names)
    elif args.cmd == "unpack":
        unpack(args.tap, args.dir)
    elif args.cmd == "pack-disk":
        pack_disk(args.dir, args.image, args.offset, args.size,
                  args.blocking, args.allow_long_names)
    elif args.cmd == "unpack-disk":
        unpack_disk(args.image, args.dir, args.offset)
    else:
        info(args.tap)


if __name__ == "__main__":
    if not shutil.which(_tar()):
        sys.exit(f"tapeio: {_tar()} not found")
    main()
