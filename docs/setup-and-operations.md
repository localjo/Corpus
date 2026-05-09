# Setup and operations

## 1) VPS prerequisites

- Ubuntu/Debian-class host (Hetzner smallest tier is fine).
- Installed: `git`, `bash`, `curl`, `cron`, `flock`, `docker`, `docker compose`.
- Directory for vaults (example: `/srv/vaults`).

## 2) Per-vault GitHub prerequisites (manual)

For each vault:

1. Create the private GitHub repository manually.
2. Configure VPS push auth:
   - Preferred: SSH deploy key on the repo.
   - Fallback: PAT over HTTPS remote.

## 3) Start Syncthing

From this repo:

```bash
cd vps
cp .env.example .env
docker compose up -d
```

Then in Syncthing UI:

- Add each vault folder under `/srv/vaults/<vault-name>`.
- Share with Mac/iPhone devices.
- Keep `.git` excluded from Syncthing data flow.

## 4) Bootstrap a vault

```bash
./scripts/init-vault.sh git@github.com:you/my-vault.git
```

What this does:

- Derives vault name from repo URL and clones into `/srv/vaults/<repo-name>`.
- Creates missing `raw/`, `wiki/index.md`, `manifest.json`, `CLAUDE.md`, `.gitignore` without overwriting existing vault content.
- Copies skills to `.claude/skills/`.
- Creates bootstrap commit with starter files and skills staged.

Push bootstrap commit:

```bash
git -C /srv/vaults/<repo-name> push origin main
```

## 5) Install cron sync loop

```bash
./vps/install-cron.sh \
  --vault-dir /srv/vaults/my-vault \
  --interval-minutes 5 \
  --branch main \
  --env-file /absolute/path/to/Corpus/vps/.env
```

Cron behavior per run:

1. `git add -A`
2. commit (if changes)
3. `git pull --rebase`
4. `git push`

Safety:

- `flock` lock per vault prevents overlap of slow/stacked runs.
- Failures stop the run.

## 6) Notification setup

Webhook is the default low-maintenance option.

In `vps/.env`:

```bash
NOTIFY_WEBHOOK_URL=https://your-endpoint.example/hook
DEFAULT_BRANCH=main
COMMIT_MESSAGE_PREFIX=sync
GIT_AUTHOR_NAME=Corpus Bot
GIT_AUTHOR_EMAIL=corpus-bot@example.com
```

On failure (commit/pull-rebase/push), the script POSTs JSON:

```json
{
  "vault": "/srv/vaults/my-vault",
  "step": "pull-rebase",
  "message": "command failed: git -C ... pull --rebase origin main"
}
```

## 7) Vault content contract

- `manifest.json` must remain tracked.
- `manifest.sources[].filename` is vault-root-relative (`raw/foo.md`).
- `manifest.sources[].wiki_pages` is relative to `wiki/` only (`concepts/foo.md`).
- `manifest.sources[].ingested_at` uses ISO 8601 UTC.
- Shared `.obsidian` config is committed, local-only state is ignored.
