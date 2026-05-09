#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <repo-url>"
  echo
  echo "Fixed defaults:"
  echo "  Parent dir:   /srv/vaults"
  echo "  Branch:       main"
  exit 1
}

[[ $# -eq 1 ]] || usage
REPO_URL="$1"

PARENT_DIR="/srv/vaults"
BRANCH="main"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/templates/vault"
ENV_FILE="$ROOT_DIR/vps/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT_DIR/vps/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
fi

repo_basename="$(basename "$REPO_URL")"
VAULT_NAME="${repo_basename%.git}"
[[ "$VAULT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]] || {
  echo "Could not derive safe vault name from repo URL: $REPO_URL" >&2
  exit 1
}

VAULT_DIR="${PARENT_DIR}/${VAULT_NAME}"
VAULT_LABEL="$VAULT_NAME"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Corpus Bot}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-corpus-bot@example.com}"

if [[ ! -d "$VAULT_DIR/.git" ]]; then
  mkdir -p "$PARENT_DIR"
  git clone "$REPO_URL" "$VAULT_DIR"
fi

if git -C "$VAULT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$VAULT_DIR" checkout "$BRANCH"
else
  git -C "$VAULT_DIR" checkout -b "$BRANCH"
fi

mkdir -p "$VAULT_DIR/raw" "$VAULT_DIR/wiki" "$VAULT_DIR/.obsidian"

if [[ ! -f "$VAULT_DIR/manifest.json" ]]; then
  cp -f "$TEMPLATE_DIR/manifest.json" "$VAULT_DIR/manifest.json"
fi
if [[ ! -f "$VAULT_DIR/.gitignore" ]]; then
  cp -f "$TEMPLATE_DIR/.gitignore.tmpl" "$VAULT_DIR/.gitignore"
fi
if [[ ! -f "$VAULT_DIR/wiki/index.md" ]]; then
  cp -f "$TEMPLATE_DIR/wiki/index.md.tmpl" "$VAULT_DIR/wiki/index.md"
fi

if [[ ! -f "$VAULT_DIR/CLAUDE.md" ]]; then
  sed "s/{{VAULT_LABEL}}/$VAULT_LABEL/g" "$TEMPLATE_DIR/CLAUDE.md.tmpl" > "$VAULT_DIR/CLAUDE.md"
fi

"$ROOT_DIR/scripts/install-skills.sh" --vault-dir "$VAULT_DIR"

git -C "$VAULT_DIR" add raw wiki manifest.json CLAUDE.md .gitignore .claude/skills

if ! git -C "$VAULT_DIR" diff --cached --quiet; then
  git -C "$VAULT_DIR" -c user.name="$GIT_AUTHOR_NAME" -c user.email="$GIT_AUTHOR_EMAIL" \
    commit -m "Bootstrap vault with templates and shared skills"
fi

echo "Vault initialized at $VAULT_DIR"
echo "Remote: $REPO_URL"
echo "Next: git -C \"$VAULT_DIR\" push origin \"$BRANCH\""
echo "Then: /opt/Corpus/vps/install-cron.sh \"$VAULT_NAME\""
echo "(Sync webhook, if installed, picks up this vault automatically — no per-vault step.)"
