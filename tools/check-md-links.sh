#!/bin/bash
# PostToolUse hook (Write|Edit): verify that relative markdown links in an
# edited .md file resolve to existing files. Reads the hook JSON on stdin.
f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty')
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
