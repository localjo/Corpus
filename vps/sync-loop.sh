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

# Syncthing often chowns the vault to PUID (e.g. 1000) while cron runs git as root — Git refuses
# "dubious ownership" unless the directory is explicitly trusted. Use per-invocation config (Git 2.31+)
# so we never require a manual ~/.gitconfig step for sync-loop itself.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$VAULT_DIR"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="${DEFAULT_BRANCH:-main}"
fi

FORCE="${CORPUS_SYNC_FORCE:-0}"
SKIP_LOCKS="${CORPUS_SKIP_SYNC_LOCK_CHECKS:-0}"

GIT_LOCK_FILE="${CORPUS_GIT_LOCK_BASENAME:-.corpus-git-in-progress}"
GIT_LOCK_PATH="$VAULT_DIR/$GIT_LOCK_FILE"

SYNCTHING_API_URL="${SYNCTHING_API_URL:-http://127.0.0.1:8384}"
GLOCK_FD=""
ST_SYNCTHING_PAUSED=0

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

on_exit_cleanup() {
  local ec=$?
  if [[ "$ST_SYNCTHING_PAUSED" == "1" ]]; then
    curl -fsS -X POST -H "X-API-Key: ${SYNCTHING_API_KEY}" "${SYNCTHING_API_URL%/}/rest/system/resume" >/dev/null 2>&1 || true
    ST_SYNCTHING_PAUSED=0
  fi
  rm -f "$GIT_LOCK_PATH"
  if [[ "${GLOCK_FD}" =~ ^[0-9]+$ ]]; then
    eval "exec ${GLOCK_FD}>&-" 2>/dev/null || true
    GLOCK_FD=""
  fi
  exit "$ec"
}

trap on_exit_cleanup EXIT INT TERM HUP

# Syncthing docs ("Temporary files"): in-progress pulls use names ending in .tmp with prefix .syncthing. or ~syncthing~
# Conflicts rename to filenames containing .sync-conflict-*.
syncthing_commit_guard_matches() {
  find "$VAULT_DIR" \( -path '*/.git/*' -o -path '*/.stversions/*' \) -prune -o \
    \( \
      -name '.syncthing.*.tmp' -o \
      -name '~syncthing~*.tmp' -o \
      -name '*.sync-conflict-*' -o \
      -name '.sync-conflict-*' \
    \) -print -quit | grep -q .
}

should_skip_precheck() {
  [[ "$SKIP_LOCKS" == "1" ]] || [[ "$FORCE" == "1" ]]
}

maybe_pause_syncthing_for_git() {
  [[ "${SYNCTHING_PAUSE_FOR_GIT:-0}" == "1" ]] || return 0
  [[ "$FORCE" == "1" ]] && return 0

  [[ -n "${SYNCTHING_API_KEY:-}" ]] || {
    echo "sync-loop: SYNCTHING_PAUSE_FOR_GIT=1 requires SYNCTHING_API_KEY in env" >&2
    notify_failure "syncthing-pause-config" "SYNCTHING_API_KEY unset"
    exit 1
  }

  local lock_path="${CORPUS_SYNCTHING_PAUSE_SERIAL_LOCK:-/tmp/corpus-syncthing-git-serial.lock}"
  local wait_sec="${CORPUS_SYNCTHING_PAUSE_FLOCK_WAIT_SEC:-240}"

  exec {GLOCK_FD}>"$lock_path"
  if ! flock -w "$wait_sec" "$GLOCK_FD"; then
    notify_failure "syncthing-pause-serial" "flock timeout on $lock_path (${wait_sec}s)"
    exec {GLOCK_FD}>&-
    GLOCK_FD=""
    exit 1
  fi

  if curl -fsS -X POST -H "X-API-Key: ${SYNCTHING_API_KEY}" "${SYNCTHING_API_URL%/}/rest/system/pause" >/dev/null; then
    ST_SYNCTHING_PAUSED=1
    return 0
  fi

  notify_failure "syncthing-pause" "POST /rest/system/pause failed"
  exec {GLOCK_FD}>&-
  GLOCK_FD=""
  exit 1
}

if ! should_skip_precheck; then
  if syncthing_commit_guard_matches; then
    echo "sync-loop: skip (Syncthing incomplete .tmp pull file, or unresolved *sync-conflict* under vault)" >&2
    exit 0
  fi
fi

maybe_pause_syncthing_for_git

touch "$GIT_LOCK_PATH"

if ! should_skip_precheck; then
  if syncthing_commit_guard_matches; then
    echo "sync-loop: abort after git-lock (Syncthing guard raced)" >&2
    exit 0
  fi
fi

if [[ -n "$(git -C "$VAULT_DIR" status --porcelain)" ]]; then
  run_or_fail "add" git -C "$VAULT_DIR" add -A
  if ! git -C "$VAULT_DIR" diff --cached --quiet; then
    if [[ -n "${GIT_AUTHOR_NAME:-}" && -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
      run_or_fail "commit" git -C "$VAULT_DIR" -c user.name="$GIT_AUTHOR_NAME" -c user.email="$GIT_AUTHOR_EMAIL" \
        commit -m "${COMMIT_MESSAGE_PREFIX:-sync}: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    else
      run_or_fail "commit" git -C "$VAULT_DIR" commit -m "${COMMIT_MESSAGE_PREFIX:-sync}: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    fi
  fi
fi

run_or_fail "pull-rebase" git -C "$VAULT_DIR" pull --rebase origin "$BRANCH"
run_or_fail "push" git -C "$VAULT_DIR" push origin "$BRANCH"
