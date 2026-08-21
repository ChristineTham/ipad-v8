#!/usr/bin/env bash
# K14: can V10 build a bootable disk of its own?
#
#	bash tools/v10-mkdisk.sh [k13-image]
#
# Rung 10's decisive experiment.  K11 proved V10 can MAKE a 111,384-block
# filesystem; this asks whether it can put a system in one and boot it.  No
# courier disk: the tape, our overlay and the generated makefiles all arrive over
# TCP, which is what K13 was for.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"

for fn in no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-mkdisk: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

GOLD="${1:-ipnx-v10-ra81.img.stage1.k102.k7.k13}"
BLANK="$ROOT/work/v10gold/ipnx-v10-made.img"
TPORT="${TPORT:-9290}"; OPORT="${OPORT:-9291}"; MPORT="${MPORT:-9292}"

# THE LAYOUT, IN THE UNITS ra_sizes[] ACTUALLY USES, CONVERTED ONCE HERE.
#
# `ra_sizes[]' IS IN 512-BYTE SECTORS, NOT BLOCKS, and asking mkbitfs for 10,240
# *blocks* of partition `a' is asking for eight times the partition.  That is the
# V8 RP06 trap word for word -- CLAUDE.md: "RP06 partition `a' is 15,884 SECTORS,
# not blocks" -- on a different disk, and `tools/v10-free.py' had the conversion
# right in a comment the whole time.  It caught the error rather than the harness:
#
#	v10-free: s_fsize reads 0, which is not a size partition a can hold (max 1280)
#
# The numbers, therefore, and they explain the golden's own layout exactly:
#
#	part  sectors  offset   4K blocks       MB
#	a      10240        0       1280       5.0   root -- and the golden's root
#	                                             filesystem IS 1280 blocks, so
#	                                             Bell Labs sized it to the
#	                                             partition to the block
#	b      20480    10240       2560      10.0   swap, and dump shares it
#	c     249848    30720      31231     122.0   /usr -- the golden uses 30752,
#	                                             which is MAXSMALL exactly
#	h     891072        0     111384     435.1   the whole drive
#
# SO THERE ARE TWO FILESYSTEMS, BECAUSE THAT IS V10's OWN LAYOUT -- not because of
# any size limit.  (An earlier version of this comment said a 5 MB root could not
# hold "6.4 MB of content"; that figure was `s_fsize - s_tfree', which INCLUDES the
# filesystem's 1,024-block i-list.  The boot path measures 2.1 MB and fits `a'
# easily.  The real argument is that root cannot go anywhere else:
# `lsys/boot/README' requires /unix to be "in the filesystem beginning at the front
# of the boot device" and `star/uda.s' carries no partition offset, so root is the
# filesystem at sector 0 -- `a' or `h' and nothing else.  `h' overlaps swap (see
# v10-mkdisk.exp).  That leaves the layout V10 itself uses, which needs no kernel
# patch at all: root on `a', swap on `b', /usr on `c', mounted by the /etc/rc the
# golden already ships -- and a whole-drive root would need `root regfs ra 0107',
# a kernel patch, and would then swap over its own data blocks.)
SECT_PER_BLK=8
RA_SECT_A=10240
ROOTPART="${ROOTPART:-a}"; USRPART="${USRPART:-c}"
ROOTBLKS="${ROOTBLKS:-$(( RA_SECT_A / SECT_PER_BLK ))}"   # 1280, the whole of `a'
USRBLKS="${USRBLKS:-30752}"                               # MAXSMALL, as the golden does
NETFSD="$ROOT/netfs/.build/release/netfsd"
LOG="$ROOT/work/v10-mkdisk.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-mkdisk: no $GOLD -- bash tools/v10-netboot.sh builds it."
    exit 1
}
# NO srcid_check HERE, AND THAT IS THE POINT: this run reads no source disk at
# all.  The repository working tree IS the source, served live, so there is no
# stamp to disagree with.  The two --check calls below are what replace it.
python3 "$ROOT/tools/v10-overlay.py" --check || exit 1
python3 "$ROOT/v10/mk/mkdep.py"      --check || exit 1

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) >/dev/null || exit 1

# A FRESH ZEROED RA81 EVERY RUN.  mkbitfs does not clear data blocks, so a second
# run over the same file leaves the previous one's contents in what the new
# filesystem calls free space -- invisible to the guest, very visible to anything
# that reads the image, which is exactly what the verification below does.
echo "== creating a blank RA81 =="
rm -f "$BLANK" "$BLANK.id"
dd if=/dev/zero of="$BLANK" bs=512 count=891072 2>/dev/null

PIDS=()
serve() { "$NETFSD" -p "$1" -v "$2" > "$ROOT/work/netfs-$3.log" 2>&1 & PIDS+=($!); }
serve "$TPORT" "$ROOT/work/v10"      mktree
serve "$OPORT" "$ROOT/v10/src"       mkours
serve "$MPORT" "$ROOT/v10/mk/gen"    mkmk
sleep 1
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || { echo "netfsd died"; tail -5 "$ROOT"/work/netfs-mk*.log; exit 1; }
done
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done' EXIT

no_overlap "$BLANK" "$ROOT/work/v10gold/$GOLD" || exit 1
IMG=$(v10_clone "$GOLD" k14) || exit 1

# THE BOOT BLOCK, HOST-SIDE AND BEFORE THE RUN, because that is how the one V10
# disk this project already boots gets one -- tools/v10-golden.sh:202:
#
#	dd if=.../lsys/boot/bb/4kb of="$OUT" bs=512 count=1 conv=notrunc
#
# Two guest-side attempts failed instead: reading `bb/4kb' off a share after
# `umount -a' gave `cp: I/O error', and `cp' to the block device left block 0 all
# zero -- 508 bytes at offset 0 is a read-modify-write of a 4096-byte buffer, which
# V10's cp may not do to a block special at all.  None of that needs answering: the
# block is 508 bytes of position-independent code at sector 0 and the host can
# place it.
#
# BEFORE the run, not after, because boot 2 -- the boot of the copy -- happens
# INSIDE the expect script, and a boot block written afterwards would be tested by
# nothing.  The risk is the opposite one: if `mkbitfs' zeroes sector 0 on its way
# past, this is lost.  That is exactly what the block-0 check below measures, so a
# wrong guess here reports itself instead of hiding.
# WILL IT FIT?  ASKED HERE, BECAUSE A FULL V10 FILESYSTEM DOES NOT FAIL -- IT
# SLEEPS.  lsys/fs/alloc.c prints `file system full' and then waits for space
# that is not coming, so the process blocks in the kernel rather than getting an
# error, and no guest-side probe can guard against it: a `dd' or `cat' canary
# blocks in the identical alloc() sleep as the thing it is meant to protect.  It
# presents as a simulator at 100% CPU with a run that neither progresses nor dies.
#
# So the question is asked on the HOST, off the source image, before a simulator
# starts -- the same argument that produced tools/v10-free.py.  And it is not
# theoretical on root: partition `a' is 1,280 blocks and the copy needs about
# 1,115 of them, so the disk ships about 87% full.  /usr has 106 MB spare.
echo "== will it fit?  (asked host-side: a full V10 filesystem SLEEPS) =="
python3 - "$ROOT/work/v10gold/$GOLD" "$ROOTBLKS" "$USRBLKS" <<'PYFIT' || exit 1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("v10fs", "tools/v10fs.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
img, rootblks, usrblks = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

def cost(size):
    """Data blocks plus the indirect blocks bmap() would need for them."""
    n = -(-size // m.BSIZE)
    if n > 10:
        n += 1
        rest = n - 10 - m.NINDIR
        if rest > 0:
            n += 1 + -(-rest // m.NINDIR)
    return n

root, usr = m.Fs(img, "a"), m.Fs(img, "c")

# The builder's own root, minus what K14 does not copy.  Device nodes occupy no
# data blocks, which is why /dev is nearly free.
have, base = {}, 0
for p, ino in root.walk("/"):
    k = ino["mode"] & m.IFMT
    if k == m.IFREG:
        base += cost(ino["size"]); have[p] = ino["size"]
    elif k == m.IFDIR:
        base += cost(ino["size"]) or 1

# /usr: only the directories K14 carries.  obj/k13obj/k14obj/k10lib/s1/w10 are
# deliberately not among them, and w10 is accounted for separately below.
ucost = 0
for d in ("/bin", "/lib", "/include", "/jerq", "/blit"):
    try:
        for p, ino in usr.walk(d):
            k = ino["mode"] & m.IFMT
            if k == m.IFREG:
                ucost += cost(ino["size"])
            elif k == m.IFDIR:
                ucost += cost(ino["size"]) or 1
    except SystemExit:
        pass                      # absent on an image without it; not fatal

# The staged root, split the way it actually lands.
radd = uadd = 0
staged = 0
for top, dest in (("/bin", "root"), ("/etc", "root"), ("/lib", "root"),
                  ("/usr/bin", "usr"), ("/usr/games", "usr"), ("/usr/lib", "usr")):
    try:
        walk = list(usr.walk("/w10" + top))
    except SystemExit:
        continue
    for p, ino in walk:
        if (ino["mode"] & m.IFMT) != m.IFREG:
            continue
        staged += 1
        real = p[len("/w10"):]
        if dest == "root":
            radd += cost(ino["size"]) - (cost(have[real]) if real in have else 0)
        else:
            uadd += cost(ino["size"])

OVER = 2                                   # block 0 and the superblock
rneed = OVER + root.isize + base + radd
uneed = OVER + usr.isize + ucost + uadd
bad = False
for label, need, have_blocks in (("root", rneed, rootblks), ("/usr", uneed, usrblks)):
    pct = 100.0 * need / have_blocks
    flag = ""
    if need >= have_blocks:
        flag = "   <-- DOES NOT FIT"; bad = True
    elif pct > 95:
        flag = "   <-- under 5% spare"
    print("   %-5s needs %6d of %6d blocks (%.0f%% full, %d spare)%s"
          % (label, need, have_blocks, pct, have_blocks - need, flag))
print("   (%d staged files counted)" % staged)
if bad:
    print("\n== NO RUN: the copy does not fit, and V10 would HANG rather than")
    print("   say so.  Trim what ships, or grow the partition.")
    sys.exit(1)
PYFIT

echo "== placing the tape's own 4K boot block at sector 0 =="
dd if="$ROOT/work/v10/src/lsys/boot/bb/4kb" of="$BLANK" \
   bs=512 count=1 conv=notrunc 2>/dev/null

echo "== V10 builds a disk on $(basename "$BLANK") =="
expect "$ROOT/tools/v10-mkdisk.exp" "$IMG" "$BLANK" "$TPORT" "$OPORT" "$MPORT" \
    "$ROOTBLKS" "$ROOTPART" "$USRBLKS" "$USRPART" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# THE HOST READS WHAT THE GUEST WROTE, because a full V10 filesystem SLEEPS rather
# than failing and no guest-side probe can see past that.
echo
echo "== what is actually on the disk V10 built =="
python3 "$ROOT/tools/v10-free.py" "$BLANK" "$ROOTPART" || rc=1
python3 "$ROOT/tools/v10-free.py" "$BLANK" "$USRPART" || rc=1
# BLOCK 0, READ FROM THE IMAGE.  The ROM jumps to offset 0xC inside it, so an
# all-zero block 0 is a HALT at PC 0000000D and nothing past it is ever read.
BB0=$(python3 -c "print(sum(1 for b in open('$BLANK','rb').read(512) if b))")
printf '   block 0: %s of 512 bytes non-zero%s\n' "$BB0" \
    "$( [[ "$BB0" == 0 ]] && echo '   <- NO BOOT BLOCK, it cannot boot' )"
[[ "$BB0" != 0 ]] || rc=1

# THE SIZE, AND THE TWO FREE READINGS AGAINST EACH OTHER.  This check used to
# assert `flag=1' -- K11's bitmap outside the superblock -- which was right for one
# whole-drive filesystem and is WRONG for a root on partition `a': 10,240 blocks is
# inside MAXSMALL (BITMAP*BITCELL = 961*32 = 30,752), so V10's own mkbitfs chooses
# smallfree() and flag reads 0, exactly as it does on the golden's own root and
# /usr.  Asserting flag=1 here would fail on a correct disk.  What IS load-bearing
# is that the filesystem is the size we asked for and that s_tfree agrees with the
# bitmap -- two readings from different places in the superblock, so a disagreement
# is real news rather than a restatement.
FREE=$(python3 "$ROOT/tools/v10-free.py" "$BLANK" "$ROOTPART" 2>/dev/null)
FS=$(printf '%s\n' "$FREE" | sed -n 's/^  filesystem size *\([0-9]*\) blocks.*/\1/p')
if [[ "$FS" != "$ROOTBLKS" ]]; then
    echo "== NO MEASUREMENT: root filesystem size reads '${FS:-nothing}', not $ROOTBLKS =="
    rc=1
fi
UFS=$(python3 "$ROOT/tools/v10-free.py" "$BLANK" "$USRPART" 2>/dev/null | \
      sed -n 's/^  filesystem size *\([0-9]*\) blocks.*/\1/p')
if [[ "$UFS" != "$USRBLKS" ]]; then
    echo "== NO MEASUREMENT: /usr filesystem size reads '${UFS:-nothing}', not $USRBLKS =="
    rc=1
fi
if printf '%s\n' "$FREE" | grep -q 'disagrees'; then
    echo "== NO MEASUREMENT: s_tfree and the bitmap disagree =="
    rc=1
fi

# AND THE HOST READS THE CONTENTS, not just the superblock.  tools/v10fs.py
# walks the finished image directly, so this is an independent witness to what the
# guest asserted -- the guest said "test -s" about seven files, and this counts
# every one and checks the properties that decide whether the disk is a SYSTEM
# rather than merely a bootable filesystem.
#
# /bin/sh IS THE ONE THAT MATTERS MOST, and it is checked here because it is the
# one a guest-side test would have flattered.  /etc/init execs `/bin/sh' -- read
# out of init's own binary -- and /etc/rc, which init runs THROUGH that shell, is
# what mounts /usr.  So a shell at /usr/bin/sh and not /bin/sh gives a disk that
# autoconfigures and then stops dead with the CPU idle, which is exactly what
# world.link used to specify before the tape's own install rules were read.
echo
echo "== the CONTENTS of the disk V10 built, read from the image =="
python3 - "$BLANK" <<'PYCHECK' || rc=1
import importlib.util, os, sys
here = os.path.dirname(os.path.abspath("tools/v10fs.py"))
spec = importlib.util.spec_from_file_location("v10fs", "tools/v10fs.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
img = sys.argv[1]
bad = []
counts = {}
for part, label in (("a", "root"), ("c", "/usr")):
    fs = m.Fs(img, part)
    files = dirs = execs = 0
    total = 0
    for p, ino in fs.walk("/"):
        k = ino["mode"] & m.IFMT
        if k == m.IFDIR:
            dirs += 1
        elif k == m.IFREG:
            files += 1
            total += ino["size"]
            if ino["mode"] & 0o111:
                execs += 1
    counts[part] = (dirs, files, execs, total)
    print("   %-5s %4d directories %5d files %5d executable %10d bytes (%.1f MB)"
          % (label, dirs, files, execs, total, total / 1048576.0))

# The boot path, by property and not by name-existence: a file, non-empty, with
# the execute bit set.  V10's ld clears x on an undefined symbol, so x IS the
# link's verdict.
root = m.Fs(img, "a")
for p in ("/unix", "/bin/sh", "/etc/init", "/etc/getty", "/etc/login",
          "/etc/mount", "/bin/cat", "/etc/rc"):
    try:
        ino = root.lookup(p)
    except SystemExit:
        bad.append("%s is MISSING" % p)
        continue
    if (ino["mode"] & m.IFMT) != m.IFREG:
        bad.append("%s is not a regular file" % p)
    elif ino["size"] == 0:
        bad.append("%s is empty" % p)
    elif p != "/etc/rc" and not (ino["mode"] & 0o111):
        bad.append("%s is not executable -- ld left symbols undefined" % p)

usr = m.Fs(img, "c")
if counts["c"][1] == 0:
    bad.append("/usr holds no files at all, so this is not a system")
for d in ("/w10", "/s1", "/obj", "/k13obj", "/k14obj", "/k10lib"):
    try:
        usr.lookup(d)
    except SystemExit:
        continue
    bad.append("/usr%s shipped -- build scratch wearing a system path" % d)

# EVERY EXECUTABLE THAT EXISTS TWICE, REPORTED RATHER THAN REMOVED.
#
# A shipped disk carries a few names at two paths, and the cause is known: the
# golden was built under an OLDER prebuilt.txt, so it holds the tape's copy where
# that table used to put it, while our build installs at the path the tape's own
# makefile specifies.  A rebuilt golden puts them at the same path and ours would
# overlay.
#
# A REMOVAL PASS WAS DESIGNED, COMPUTED AND REJECTED ON EVIDENCE.  The naive rule
# -- "delete a copied file whose name our tables place elsewhere" -- matched FORTY
# paths, almost all of them build scratch this harness never copies (/usr/obj,
# /usr/s1, /usr/k13obj, /tmp/ct).  Restricted to what is actually copied it
# matches three, and one of those must not be touched: removing /bin/sleep would
# leave `sleep' only under /usr, which /etc/rc mounts -- so it would not exist in
# SINGLE-USER mode, and V10's kernel does not sync on halt (lsys/md/machdep.c's
# boot() is two lines), which makes the userland `sync; sleep; sync' the whole
# flush.  Deleting from a shipped disk to tidy a path is not worth breaking a safe
# shutdown.
#
# So it is reported.  A duplicate that every build names is a known property; one
# that needs an ad-hoc audit to find is not.
dups = {}
for part, pfx in (("a", ""), ("c", "/usr")):
    fs = m.Fs(img, part)
    for p, ino in fs.walk("/"):
        if (ino["mode"] & m.IFMT) != m.IFREG or not (ino["mode"] & 0o111):
            continue
        dups.setdefault(p.rsplit("/", 1)[1], []).append((pfx + p, ino["size"]))
dups = {k: v for k, v in dups.items() if len(v) > 1}
if dups:
    print("   executables at more than one path (%d) -- see the note in this"
          % len(dups))
    print("   script; they are reported, not removed:")
    for k in sorted(dups):
        print("     %-9s %s" % (k, "  ".join("%s (%d)" % t for t in sorted(dups[k]))))

if bad:
    print("\n== NO MEASUREMENT: the disk is not a shippable system ==")
    for b in bad:
        print("   %s" % b)
    sys.exit(1)
print("   the boot path is present, executable and non-empty; no scratch shipped")
PYCHECK

echo
echo "== K14: DID V10 BUILD A BOOTABLE DISK? =="
if [[ "$rc" == 0 ]]; then
    echo "   Yes.  A filesystem V10 made, filled and booted -- with its source"
    echo "   arriving over TCP and no courier disk anywhere in the run."
else
    echo "   Not yet.  The first NO names the step: the shares, mkbitfs, the"
    echo "   node, the copy, or the boot of the copy."
fi
echo "   the disk is $BLANK"
echo "   full transcript $LOG"
echo "== v10-mkdisk exit $rc =="
exit "$rc"
