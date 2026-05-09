#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --vault-dir <path> [--interval-minutes <n>] [--branch <name>] [--env-file <path>]"
  exit 1
}

VAULT_DIR=""
INTERVAL="5"
BRANCH="main"
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-loop.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-dir)
      VAULT_DIR="${2:-}"
      shift 2
      ;;
    --interval-minutes)
      INTERVAL="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$VAULT_DIR" ]] || usage
[[ -x "$SYNC_SCRIPT" ]] || { echo "sync script missing/executable: $SYNC_SCRIPT" >&2; exit 1; }

LOCK_FILE="/tmp/corpus-sync-$(basename "$VAULT_DIR").lock"
CRON_CMD="flock -n \"$LOCK_FILE\" \"$SYNC_SCRIPT\" --vault-dir \"$VAULT_DIR\" --branch \"$BRANCH\" --env-file \"$ENV_FILE\""
CRON_EXPR="*/$INTERVAL * * * * $CRON_CMD"

TMP_FILE="$(mktemp)"
crontab -l 2>/dev/null | rg -v "corpus-sync-$(basename "$VAULT_DIR")|$SYNC_SCRIPT --vault-dir \"$VAULT_DIR\"" >"$TMP_FILE" || true
echo "$CRON_EXPR" >>"$TMP_FILE"
crontab "$TMP_FILE"
rm -f "$TMP_FILE"

echo "Installed cron for $VAULT_DIR every $INTERVAL minute(s)."
