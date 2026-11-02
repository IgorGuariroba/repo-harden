#!/usr/bin/env bash
# Every item ID that audit.sh emits must be defined in references/checklist.md.
# Sub-items `<id>:<ecosystem>` and `<id>/<setting>` count as their parent <id>.
# Usage: test-checklist-ids.sh   (exits 0 when every ID is defined)
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)
audit="$dir/scripts/audit.sh" checklist="$dir/references/checklist.md"

emitted=$( {
  grep -oE '\b(row|chk) "?[a-z][a-z.-]*' "$audit" | sed -E 's/^(row|chk) "?//'
  grep -oE '^\s*for i in [a-z. -]+;' "$audit" | sed -E 's/^\s*for i in //; s/;$//' | tr ' ' '\n'
} | grep -vxE 'platform|ecosystems|' | sort -u)

defined=$(grep -oE '^\| `[a-z][a-z.-]*`' "$checklist" | tr -d '|` ' | sort -u)

undefined=$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$defined"))
if [ -n "$undefined" ]; then
  printf 'FAIL: emitted by audit.sh but not defined in checklist.md:\n%s\n' "$undefined"
  exit 1
fi
echo "OK: $(printf '%s\n' "$emitted" | wc -l) audit IDs all defined in checklist.md"
