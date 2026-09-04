#!/usr/bin/env bash
# Drift check: this repo's bytes must be reproducible from the muretai core
# render — the same rule as the other skill repos ("issues welcome; hand-edits
# are overwritten by the next re-render").
#
# Usage:  MURETAI_CORE=/path/to/core ./tools/check_render.sh
# The core checkout must contain the dsh connector adapter
# (connector/adapters/dsh.py).
set -euo pipefail

CORE="${MURETAI_CORE:-${1:-}}"
if [ -z "$CORE" ] || [ ! -f "$CORE/connector_cli.py" ]; then
  echo "usage: MURETAI_CORE=/path/to/muretai-core $0" >&2
  exit 2
fi
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d /tmp/dsh-render-check.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

(cd "$CORE" && python3 connector_cli.py --framework dsh \
  package --out "$OUT" >/dev/null)

# Every rendered artifact must match this repo byte-for-byte. README/LICENSE/
# tools/ are repo-local (not rendered) and deliberately absent from this list.
ARTIFACTS="
cordis.patch.muretai.yml.tmpl
cordis.patch.yml
package.json
wire_dsh.sh
wake_dsh.sh
install.sh
onboard_join
skills/muretai/SKILL.md
skills/muretai/references/cli-reference.md
"
stale=0
for f in $ARTIFACTS; do
  if ! cmp -s "$OUT/$f" "$REPO/$f"; then
    echo "DRIFT: $f"
    stale=1
  fi
done
# ...and the render must not have grown artifacts this repo doesn't carry.
while IFS= read -r -d '' rendered; do
  rel="${rendered#"$OUT/"}"
  case "$ARTIFACTS" in *"$rel"*) ;; *) echo "NEW ARTIFACT not in repo: $rel"; stale=1 ;; esac
done < <(find "$OUT" -type f -print0)

if [ "$stale" -ne 0 ]; then
  echo "stale: re-render with: (cd core && python3 connector_cli.py --framework dsh package) and copy over this repo." >&2
  exit 1
fi
echo "OK: repo bytes == core render (9 artifacts)"
