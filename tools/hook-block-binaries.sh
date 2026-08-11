#!/bin/bash
# PreToolUse hook (Write|Edit): deny writes of historical binary artifacts
# anywhere in the repo except under work/ (gitignored build area).
# Reads the hook JSON on stdin; emits a permission decision on match.
#
# ONE EXCEPTION, and it is named rather than left to a gap in the pattern
# list: image/ipnx-v8-rp07.img.xz is the disk Track S builds, and it is in
# git because it is the INPUT to the next build -- stage 8 lifts 1406 files
# off it that Bell Labs shipped without source (v8/mk/gen/carry.txt).  With
# it committed, the build's only external input is the tapes, which
# v8/MANIFEST already accounts for.  Write it with tools/image-pack.py.
#
# Raw *.img is blocked precisely so that the packed form is the only way in.
f=$(jq -r '.tool_input.file_path // empty')
case "$f" in
  ""|*/work/*) exit 0 ;;
  */image/ipnx-v8-rp07.img.xz|*/image/ipnx-v8-rp07.img.xz.sha256) exit 0 ;;
  *.disk|*.dsk|*.tap|*.tape|*.tar.gz|*.tar.bz2|*.tgz|*.cpio|*.iso|*.img)
    cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Historical binary artifacts (*.disk, *.tap, *.img, tarballs) must not be written into the repo - build them under work/ (gitignored). The one exception is image/ipnx-v8-rp07.img.xz, which is written by tools/image-pack.py. See CLAUDE.md conventions."}}
JSON
    ;;
esac
exit 0
