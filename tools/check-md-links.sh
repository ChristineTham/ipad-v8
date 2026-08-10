#!/bin/bash
# PostToolUse hook (Write|Edit): verify that relative markdown links in an
# edited .md file resolve to existing files. Reads the hook JSON on stdin —
# or takes a path as $1, so it can also be run by hand:
#
#     tools/check-md-links.sh README.md
#
# The argument form matters more than it looks. Without it, running this with a
# filename left `jq` reading a terminal: it either blocked forever or, with
# stdin closed, returned an empty path and the script exited 0 having checked
# nothing at all. A checker that silently passes is worse than no checker.
if [ -n "$1" ]; then
  f="$1"
else
  f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty')
fi
case "$f" in *.md) ;; *) exit 0 ;; esac
[ -f "$f" ] || exit 0
dir=$(cd "$(dirname "$f")" && pwd) || exit 0
missing=""
while IFS= read -r link; do
  case "$link" in http*|mailto:*|"#"*|"") continue ;; esac
  t="${link%%#*}"
  case "$t" in *:[0-9]*) t="${t%%:*}" ;; esac
  [ -z "$t" ] && continue
  [ -e "$dir/$t" ] || missing="$missing $link"
done < <(grep -oE '\]\([^)]*\)' "$f" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//')
if [ -n "$missing" ]; then
  esc=$(printf '%s' "$missing" | tr '"' "'")
  printf '{"decision":"block","reason":"Broken relative link(s) in %s:%s"}' "$(basename "$f")" "$esc"
fi
exit 0
