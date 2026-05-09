#!/usr/bin/env bash
# One-time global install for the Corpus sync webhook (corpus-sync-webhook.service).
#
# Idempotent: ensures CORPUS_SYNC_WEBHOOK_SECRET and CORPUS_GITHUB_WEBHOOK_SECRET
# are set in vps/.env (auto-generates with secrets.token_hex(32) when missing),
# then installs / restarts the systemd unit when run as root.
#
# Vaults are auto-discovered from /srv/vaults at request time — no per-vault step.
#
#   ./install-sync-webhook.sh        # ensure secrets only (re-run with sudo for systemd)
#   sudo ./install-sync-webhook.sh   # ensure secrets + install/restart unit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
UNIT_SRC="$SCRIPT_DIR/corpus-sync-webhook.service.example"
UNIT_DST="/etc/systemd/system/corpus-sync-webhook.service"

for p in "$SCRIPT_DIR/sync_webhook.py" "$SCRIPT_DIR/sync-loop.sh" "$UNIT_SRC" "$ENV_EXAMPLE"; do
  if [[ ! -f "$p" ]]; then
    echo "Missing $p — clone or pull Corpus." >&2
    exit 1
  fi
done

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
fi

# Ensure KEY=<non-empty> in $ENV_FILE; append a fresh hex secret if missing/blank.
ensure_secret() {
  local key="$1"
  python3 - "$ENV_FILE" "$key" <<'PY'
import secrets, sys
from pathlib import Path

path, key = Path(sys.argv[1]), sys.argv[2]
lines = path.read_text().splitlines() if path.is_file() else []
prefix = f"{key}="

for ln in lines:
    s = ln.strip()
    if s.startswith("#") or "=" not in s:
        continue
    k, _, v = s.partition("=")
    if k.strip() == key and v.strip().strip('"').strip("'"):
        sys.exit(0)  # already set with a non-empty value

kept = [ln for ln in lines if not ln.lstrip().startswith(prefix)]
kept.append(f"{key}={secrets.token_hex(32)}")
path.write_text("\n".join(kept) + "\n", encoding="utf-8")
try:
    path.chmod(0o600)
except OSError:
    pass
PY
}

ensure_secret CORPUS_SYNC_WEBHOOK_SECRET
ensure_secret CORPUS_GITHUB_WEBHOOK_SECRET

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Secrets ensured in $ENV_FILE." >&2
  echo "Re-run with sudo to install/restart corpus-sync-webhook.service." >&2
  exit 0
fi

if ! cmp -s "$UNIT_SRC" "$UNIT_DST" 2>/dev/null; then
  cp "$UNIT_SRC" "$UNIT_DST"
  systemctl daemon-reload
fi

systemctl enable corpus-sync-webhook >/dev/null
systemctl restart corpus-sync-webhook
echo "OK — corpus-sync-webhook installed and restarted." >&2
echo "Smoke: curl -sSf http://127.0.0.1:8780/healthz" >&2
