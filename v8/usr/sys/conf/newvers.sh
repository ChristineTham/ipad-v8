#!/bin/sh
# Stamp the kernel's boot banner.
#
# Generated from v8/RELEASE by tools/ipnx-release.py.  Do not edit.
#
# What shipped on the tape was one line -- `date` and nothing else -- which is
# why a Research Unix kernel announces itself as "Unix 8th Edition" followed by
# whatever the clock happened to say, and says nothing whatsoever about what is
# actually in it.  A machine should be able to tell you which build it is
# running, so it now does.
#
# The build date is still stamped, because knowing when a -CURRENT tree was
# compiled matters; for a tagged -RELEASE the release date in RELEASE is the
# one that means anything.

REL="1.0"
BRANCH="RELEASE"
EDITION="Edition 8"
RELDATE="2026-08-16"
SUFFIX=""

echo "char version[] = \"Unix -- ipnx $EDITION Release $REL$SUFFIX ($RELDATE)\\nbuilt `date`\\n\";" > vers.c
