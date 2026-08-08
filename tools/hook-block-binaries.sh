#!/bin/bash
# PreToolUse hook (Write|Edit): deny writes of historical binary artifacts
# anywhere in the repo except under work/ (gitignored build area).
# Reads the hook JSON on stdin; emits a permission decision on match.
f=$(jq -r '.tool_input.file_path // empty')
case "$f" in
  ""|*/work/*) exit 0 ;;
  *.disk|*.dsk|*.tap|*.tape|*.tar.gz|*.tar.bz2|*.tgz|*.cpio|*.iso)
    cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Historical binary artifacts (*.disk, *.tap, tarballs) must not be written into the repo - build them under work/ (gitignored). See CLAUDE.md conventions."}}
JSON
    ;;
esac
exit 0
