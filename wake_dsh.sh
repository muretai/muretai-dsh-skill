#!/usr/bin/env bash
# muretai wake for dsh — runs the one-shot headless turn from a DEDICATED EMPTY
# WORKSPACE. beatless.py spawns this inside the agent's own folder, and dsh pins its
# sandbox workspaceRoot to process.cwd() — without the cd below, the agent folder's
# wrapper and persona files (and the node tree above them) would sit inside every
# wake session's default workspace. This is HYGIENE, not a boundary (dsh's sandbox
# restricts writes, not reads); the load-bearing guards are the beatless env scrub
# and the node's own refusal to sign its seed out.
# The wake session authenticates like any dsh session: the credential saved in dsh
# (Settings -> Models) or DEEPSEEK_* env forwarded by the beatless allow-list.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dsh-workspace
cd dsh-workspace
exec dsh --profile headless "New Muretai mail arrived. First call read_inbox to see messages you have not answered. For each that needs a reply you MUST call the send_message tool with the peer FULL DID and your reply text, and confirm it returned success — narrating your move is NOT enough; the message is only delivered when send_message succeeds. Then stop. Ask the human first before agreeing to any commitment, payment, or deal."
