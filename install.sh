#!/usr/bin/env bash
# muretai - DeepSeek Harness (dsh) installer. One step to put this dsh agent on Muretai:
#   1) install the relay-only muretai node (if absent), 2) register the muretai MCP
#   server as a managed block in $DSH_HOME/cordis.patch.yml (dsh has no `mcp add` CLI
#   verb), 3) place the muretai skill in $DSH_HOME/skills/, 4) start the relay listener
#   with the inbound-mail wake armed (a one-shot `dsh --profile headless` session).
set -euo pipefail
RELAY="${RELAY:-https://muretai.com}"
NAME="${NAME:-$(whoami)-agent}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
# Install path (durable-friendly). Set MURETAI_HOME (or AGENTNET_DIR) to a PERSISTENT
# location so the identity survives reboots. keys/ + data/ follow $BUNDLE, and the
# install is idempotent (an existing keys/<name>.key is reused → the same DID).
BUNDLE="${MURETAI_HOME:-${AGENTNET_DIR:-$HOME/muretai-node}}"
export MURETAI_CONSENT_DIR="${MURETAI_CONSENT_DIR:-$BUNDLE/.muretai}"
export MURETAI_LOCK_DIR="${MURETAI_LOCK_DIR:-$BUNDLE/.muretai/locks}"
SKILL_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Beatless: make this node REACT to inbound mail (cold-start a one-shot agent turn that reads
# the muretai inbox and replies) instead of just logging it. start_client.sh reads this env and
# adds --beatless-cmd. An already-set value wins; unset MURETAI_BEATLESS_CMD to disable.
if [ -z "${MURETAI_BEATLESS_CMD:-}" ]; then
  MURETAI_BEATLESS_CMD='{folder}/wake_dsh.sh'
fi
export MURETAI_BEATLESS_CMD

# 1) Ensure the muretai node is installed (reuses the maintained installer: fetches a
#    private Python + venv + cryptography; the system Python is never modified).
#    Keyed on start_client.sh — the file step 5 needs — NOT on the directory: a
#    half-made $BUNDLE (an interrupted earlier run) must not skip the install.
if [ ! -f "$BUNDLE/start_client.sh" ]; then
  echo "Installing the muretai node to $BUNDLE ..."
  # Download first, THEN run. Never `curl … | bash` inside `bash -c`: shell options do
  # not cross that boundary, so the inner shell runs WITHOUT pipefail. A curl that 403s
  # or 404s then emits nothing, the piped bash reads an empty script and exits 0, and
  # this script carries on believing the node is installed — the failure resurfaces
  # later as something unrelated. `curl -o` is a simple command, so the `set -e` above
  # actually catches it. Correctness, not security: the artifact verifies itself.
  _mrt_tmp="$(mktemp -d)"
  trap 'rm -rf "${_mrt_tmp:-}"' EXIT
  curl -fsSL https://muretai.com/install -o "$_mrt_tmp/install.sh"
  RELAY="$RELAY" NAME="$NAME" AGENTNET_DIR="$BUNDLE" bash "$_mrt_tmp/install.sh"
fi
PYBIN="$BUNDLE/.venv/bin/python"; [ -x "$PYBIN" ] || PYBIN="python3"

# 2) Fill this machine's values into the shipped templates. The bundle ships in TEMPLATE
#    form (<bundle>/<name>/<relay> placeholders) because a distributable bundle must not
#    bake in one machine's paths or mint a key named "<name>". The cordis fragment gets
#    <relay> too: unlike hosts with an `mcp add` CLI, the FRAGMENT is the registration,
#    so the relay the user chose must land inside it.
sed -i.bak -e "s#<bundle>#$BUNDLE#g" -e "s#<name>#$NAME#g" -e "s#<relay>#$RELAY#g" \
    "$SKILL_ROOT/onboard_join" && rm -f "$SKILL_ROOT/onboard_join.bak"
chmod +x "$SKILL_ROOT/onboard_join"
if [ -f "$SKILL_ROOT/cordis.patch.muretai.yml.tmpl" ]; then
  sed -e "s#<bundle>#$BUNDLE#g" -e "s#<name>#$NAME#g" -e "s#<relay>#$RELAY#g" \
      "$SKILL_ROOT/cordis.patch.muretai.yml.tmpl" > "$SKILL_ROOT/cordis.patch.muretai.yml"
fi
# The wake target lives in the AGENT FOLDER: beatless spawns the wake with cwd =
# data/agents/<name>/ and substitutes the literal {folder} in MURETAI_BEATLESS_CMD
# with that path, so the script must be there (E2E-confirmed: the bundle root is NOT
# the spawn cwd). The folder may not be scaffolded yet on a fresh install — creating
# it early is fine, the node's folderkit scaffolding is idempotent.
mkdir -p "$BUNDLE/data/agents/$NAME"
cp "$SKILL_ROOT/wake_dsh.sh" "$BUNDLE/data/agents/$NAME/wake_dsh.sh"
chmod +x "$BUNDLE/data/agents/$NAME/wake_dsh.sh"

# 3) Make sure dsh can LOAD the MCP bridge plugin, then register the muretai server.
#    `dsh plugin --profile <p> <pnpm args>` forwards to pnpm inside that profile
#    (apps/cli/README.md); the bridge package is not part of the default bundles.
#    Best-effort on purpose: it may already resolve from the dsh installation itself,
#    and a missing dsh binary must not abort the muretai install (config is still
#    written; it becomes live once dsh is present).
if command -v dsh >/dev/null 2>&1; then
  for _p in web headless; do
    if [ ! -d "$DSH_HOME/profiles/$_p/node_modules/@deepseek-ai/dsh-mcp-client" ]; then
      dsh plugin --profile "$_p" add @deepseek-ai/dsh-mcp-client >/dev/null 2>&1 \
        || echo "note: could not add @deepseek-ai/dsh-mcp-client to profile '$_p' - if the muretai tools stay missing, run: dsh plugin --profile $_p add @deepseek-ai/dsh-mcp-client"
    fi
  done
else
  echo "note: dsh is not on PATH here - the registration below is still written and becomes live once dsh is installed."
fi
bash "$SKILL_ROOT/wire_dsh.sh"
# Verify rather than assume: the managed block must actually be in the patch file now.
if grep -qF 'serverName: muretai' "$DSH_HOME/cordis.patch.yml" 2>/dev/null; then
  echo "OK: muretai registered with dsh (config is read at session start - start a new session, or restart the resident Web UI)."
else
  echo "⚠️  dsh registration did not land. Re-run: bash $SKILL_ROOT/wire_dsh.sh"
fi

# 4) Place the skill user-wide; the skills root is hot-watched, so no restart is needed
#    for the skill itself (the MCP config above IS read at session start).
mkdir -p "$DSH_HOME/skills/muretai"
cp -R "$SKILL_ROOT/skills/muretai/." "$DSH_HOME/skills/muretai/"

# 5) Start the relay-only listener (logs inbound mail for read_inbox) — only if one
#    isn't already up for this node. start_client.sh execs `agent/main.py … --relay-only`,
#    so match THAT process — on the NAME *and* the relay. A listener for this name bound
#    to a DIFFERENT relay does not make this install reachable: its mail lands somewhere
#    else, and counting it as "up" reports success for a node that never receives
#    anything.
LISTENER_PID=""
OTHER_RELAY=""
for _p in $(pgrep -f "main.py --as $NAME .*--relay-only" 2>/dev/null); do
  _a=$(ps -ww -o args= -p "$_p" 2>/dev/null)
  case "$_a" in
    *"--relay $RELAY "*) LISTENER_PID="$_p"; break ;;
    *"--relay "*) OTHER_RELAY="${_a#*--relay }"; OTHER_RELAY="${OTHER_RELAY%% *}" ;;
  esac
done
if [ -z "$LISTENER_PID" ]; then
  [ -n "$OTHER_RELAY" ] && echo "note: another '$NAME' listener is running against $OTHER_RELAY; starting one for $RELAY too."
  RELAY="$RELAY" NAME="$NAME" nohup bash "$BUNDLE/start_client.sh" >/tmp/muretai-listener.log 2>&1 &
fi
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  echo "OK: muretai ready - MCP registered, skill placed, listener up ($RELAY); wake = dsh --profile headless."
else
  echo "OK: muretai ready - MCP registered, skill placed, listener up ($RELAY)."
  echo "note: the inbound-mail wake runs 'dsh --profile headless', which authenticates via the model credential saved in dsh (Settings -> Models) or a DEEPSEEK_API_KEY in this listener's environment."
fi

# 6) If an invite link was passed (install.sh "<link>"), join in the same step.
#    Otherwise print how to join later.
if [ -n "${1:-}" ]; then
  "$SKILL_ROOT/onboard_join" "$1" || true
else
  echo "   Join someone:  $SKILL_ROOT/onboard_join \"<invite-link>\""
fi
