#!/bin/bash
# PreToolUse hook (Bash): surface a confirmation prompt when a command
# force-adds historical binary artifacts past .gitignore.
c=$(jq -r '.tool_input.command // empty')
printf '%s' "$c" | grep -qE 'git[[:space:]]+add[[:space:]]' || exit 0
printf '%s' "$c" | grep -qE '(^|[[:space:]])(-f|--force)([[:space:]]|$)' || exit 0
printf '%s' "$c" | grep -qE '\.(disk|dsk|tap|tape|tgz|cpio|iso|tar\.gz|tar\.bz2)' || exit 0
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"This command force-adds historical binary artifacts past .gitignore. They must never enter git history (see CLAUDE.md)."}}
JSON
exit 0
