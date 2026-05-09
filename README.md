# Corpus

Minimal tooling for a personal wiki workflow:

- One private GitHub repo per vault.
- Vault files synced to devices via Syncthing.
- Git operations run on VPS only (cron loop).
- Claude Code uses committed vault files and skills.

## What this repo provides

- Vault bootstrap templates:
  - `raw/`
  - `wiki/index.md`
  - `manifest.json`
  - `CLAUDE.md`
  - `.gitignore`
- Shared skill files copied into each vault's `.claude/skills/`.
- VPS scripts for:
  - Syncthing with Docker Compose
  - Per-vault cron sync loop (`commit -> pull --rebase -> push`)
  - Optional webhook notifications
  - `flock` lock to prevent overlapping cron runs

## Prerequisites

For each vault:

1. Create the private GitHub repository manually.
2. Configure VPS auth for push access:
   - Preferred: SSH deploy key
   - Fallback: PAT over HTTPS
3. Ensure `git`, `bash`, `curl`, and `flock` are installed on VPS.

## Quick start

1. Create a local clone of this tooling repo on VPS.
2. Set commit identity (either global git config or `vps/.env` author fields).
3. Bootstrap a vault repo:

```bash
./scripts/init-vault.sh git@github.com:you/my-vault.git
```

1. Configure Syncthing folder for `/srv/vaults/my-vault` and devices.
1. Install cron entry:

```bash
./vps/install-cron.sh \
  --vault-dir /srv/vaults/my-vault \
  --interval-minutes 5
```

## Notifications

Webhook notifications are optional and simplest for VPS maintenance.

- Set `NOTIFY_WEBHOOK_URL` in `vps/.env` (copy from `vps/.env.example`).
- On pull/rebase conflicts or sync errors, the cron loop sends a JSON payload.
- You can point this to a relay/service of your choice (for example Telegram bridge).

Optional: use local mail on hosts where outbound mail is already configured.

## Vault conventions

- `manifest.json` is tracked and required.
- `manifest.sources[].filename` paths are vault-root-relative (for example `raw/foo.md`).
- `manifest.sources[].wiki_pages` paths are relative to `wiki/` with no `wiki/` prefix (for example `concepts/foo.md`).
- `manifest.sources[].ingested_at` uses ISO 8601 UTC.

## Cron sync semantics

For each run:

1. Stage and commit local working tree changes (if any).
2. `git pull --rebase`.
3. `git push`.

If any step fails, the run stops and sends notification (when configured).
