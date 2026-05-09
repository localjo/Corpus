#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <vault-name>"
  echo
  echo "Fixed defaults:"
  echo "  Parent dir:   /srv/vaults"
  echo "  Interval:     5 minutes"
  echo "  Branch:       main"
  echo "  Env file:     <this-dir>/.env"
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-loop.sh"
PARENT_DIR="/srv/vaults"
INTERVAL="5"
BRANCH="main"
ENV_FILE="$SCRIPT_DIR/.env"

[[ $# -eq 1 ]] || usage
VAULT_NAME="$1"
[[ "$VAULT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]] || {
  echo "Invalid vault name: $VAULT_NAME" >&2
  exit 1
}
VAULT_DIR="$PARENT_DIR/$VAULT_NAME"

[[ -x "$SYNC_SCRIPT" ]] || { echo "sync script missing/executable: $SYNC_SCRIPT" >&2; exit 1; }
[[ -d "$VAULT_DIR/.git" ]] || { echo "Vault git repo not found: $VAULT_DIR" >&2; exit 1; }

LOCK_FILE="/tmp/corpus-sync-$(basename "$VAULT_DIR").lock"
CRON_CMD="flock -n \"$LOCK_FILE\" \"$SYNC_SCRIPT\" --vault-dir \"$VAULT_DIR\" --branch \"$BRANCH\" --env-file \"$ENV_FILE\""
CRON_EXPR="*/$INTERVAL * * * * $CRON_CMD"

TMP_FILE="$(mktemp)"
crontab -l 2>/dev/null | rg -v "corpus-sync-$(basename "$VAULT_DIR")|$SYNC_SCRIPT --vault-dir \"$VAULT_DIR\"" >"$TMP_FILE" || true
echo "$CRON_EXPR" >>"$TMP_FILE"
crontab "$TMP_FILE"
rm -f "$TMP_FILE"

echo "Installed cron for $VAULT_DIR every $INTERVAL minute(s)."
