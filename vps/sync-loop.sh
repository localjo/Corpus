#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --vault-dir <path> [--branch <name>] [--env-file <path>]"
  exit 1
}

VAULT_DIR=""
BRANCH=""
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-dir)
      VAULT_DIR="${2:-}"
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
[[ -d "$VAULT_DIR/.git" ]] || { echo "Not a git repo: $VAULT_DIR" >&2; exit 1; }

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="${DEFAULT_BRANCH:-main}"
fi

notify_failure() {
  local step="$1"
  local message="$2"
  if [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]; then
    curl -fsS -X POST "$NOTIFY_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"vault\":\"$VAULT_DIR\",\"step\":\"$step\",\"message\":\"$message\"}" >/dev/null || true
  fi
}

run_or_fail() {
  local step="$1"
  shift
  if ! "$@"; then
    notify_failure "$step" "command failed: $*"
    exit 1
  fi
}

run_or_fail "add" git -C "$VAULT_DIR" add -A

if ! git -C "$VAULT_DIR" diff --cached --quiet; then
  if [[ -n "${GIT_AUTHOR_NAME:-}" && -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
    run_or_fail "commit" git -C "$VAULT_DIR" -c user.name="$GIT_AUTHOR_NAME" -c user.email="$GIT_AUTHOR_EMAIL" \
      commit -m "${COMMIT_MESSAGE_PREFIX:-sync}: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  else
    run_or_fail "commit" git -C "$VAULT_DIR" commit -m "${COMMIT_MESSAGE_PREFIX:-sync}: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi
fi

run_or_fail "pull-rebase" git -C "$VAULT_DIR" pull --rebase origin "$BRANCH"
run_or_fail "push" git -C "$VAULT_DIR" push origin "$BRANCH"
