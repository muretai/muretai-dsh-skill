#!/usr/bin/env bash
# muretai -> dsh wiring: merge the managed muretai-mcp block into
# $DSH_HOME/cordis.patch.yml. dsh has NO CLI verb for adding an MCP server row; its
# user config layer is a YAML LIST of patch ops (rows addressed by id, last write
# wins), so this merge is TEXT-level and marker-bounded — no YAML library is assumed
# on the user's box.
#   - file absent     -> the fragment (with its own comments) becomes the file
#   - markers present -> the span between them is replaced (backup kept at .bak)
#   - no markers      -> the fragment is appended at EOF (top-level list context)
# Fail-closed: after writing, the begin marker, the end marker and the
# `serverName: muretai` row must each appear exactly once, or the previous file is
# restored and this exits 1 — e.g. when a muretai serverName was already registered
# by hand (dsh refuses duplicate serverNames at load, so silently adding a second
# row would break the user's boot).
set -euo pipefail
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PATCH="$DSH_HOME/cordis.patch.yml"
HERE="$(cd "$(dirname "$0")" && pwd)"
BLOCK="$HERE/cordis.patch.muretai.yml"
MARK_B='# >>> muretai-mcp (managed by muretai install.sh; edits inside are overwritten) >>>'
MARK_E='# <<< muretai-mcp <<<'

[ -f "$BLOCK" ] || { echo "error: $BLOCK not found (run install.sh first - it renders the fragment)"; exit 1; }
if grep -qE '<(bundle|name|relay)>' "$BLOCK"; then
  echo "error: $BLOCK still contains <bundle>/<name>/<relay> placeholders - run install.sh, which fills them for this machine"
  exit 1
fi

# If the muretai dsh BUNDLE plugin is installed in any profile, the row is already
# live there — and an insert of the same id across layers COMPOSES AS A SECOND ROW
# (E2E-verified 2026-08-14, not last-write-wins), which dsh's duplicate-serverName
# guard then fails loudly at load. So: skip, don't double-register.
for _p in "$DSH_HOME"/profiles/*/node_modules/muretai-dsh-skill; do
  if [ -e "$_p" ]; then
    echo "OK: muretai is already wired via the dsh bundle plugin ($_p) - nothing to merge."
    echo "    (Remove it with: dsh plugin --profile <name> remove muretai-dsh-skill, then re-run this script.)"
    exit 0
  fi
done

mkdir -p "$DSH_HOME"
# The merge UNIT is the marked span (begin..end) — extracted here so a re-run replaces
# span-for-span and stays byte-idempotent; the fragment's leading comment header is a
# courtesy for a FRESH file only.
_spanf="$(mktemp)"
trap 'rm -f "${_spanf:-}"' EXIT
awk -v b="$MARK_B" -v e="$MARK_E" '
  index($0, b) == 1 { inb = 1 }
  inb { print }
  index($0, e) == 1 { inb = 0 }
' "$BLOCK" > "$_spanf"
grep -qF "$MARK_B" "$_spanf" || { echo "error: $BLOCK lost its managed markers"; exit 1; }

if [ ! -f "$PATCH" ]; then
  cp "$BLOCK" "$PATCH"
else
  cp "$PATCH" "$PATCH.bak"
  if grep -qF "$MARK_B" "$PATCH"; then
    # Replace the managed span in place; everything outside it is untouched.
    awk -v b="$MARK_B" -v e="$MARK_E" -v f="$_spanf" '
      index($0, b) == 1 { skip = 1; while ((getline line < f) > 0) print line; close(f); next }
      index($0, e) == 1 && skip { skip = 0; next }
      !skip { print }
    ' "$PATCH.bak" > "$PATCH"
  else
    { echo ""; cat "$_spanf"; } >> "$PATCH"
  fi
fi

# Verify, fail-closed: exactly one managed block and exactly one muretai serverName.
_b=$(grep -cF "$MARK_B" "$PATCH" || true)
_e=$(grep -cF "$MARK_E" "$PATCH" || true)
_s=$(grep -cE '^[[:space:]]*serverName:[[:space:]]*"?muretai"?[[:space:]]*$' "$PATCH" || true)
if [ "$_b" != "1" ] || [ "$_e" != "1" ] || [ "$_s" != "1" ]; then
  if [ -f "$PATCH.bak" ]; then cp "$PATCH.bak" "$PATCH"; fi
  echo "error: refusing to wire - $PATCH would hold $_b begin / $_e end markers and $_s 'serverName: muretai' row(s); exactly 1 of each is required."
  echo "A muretai MCP server is likely registered OUTSIDE the managed block (dsh fails to load duplicate serverNames)."
  echo "Merge by hand: keep one registration, using the block in $BLOCK. The previous file was restored."
  exit 1
fi
echo "OK: muretai MCP registered in $PATCH (dsh reads config at session start - start a new session, or restart the resident Web UI)."
