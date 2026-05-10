# Corpus

Minimal tooling for a personal wiki workflow:

- One private GitHub repo per vault.
- Vault files synced to devices via Syncthing.
- Git operations run on VPS only (cron loop).
- Claude Code uses committed vault files and skills.

## What this repo provides

- Vault bootstrap templates (`raw/`, `wiki/`, `manifest.json`, `CLAUDE.md`, `.gitignore`).
- Shared skill files in `.claude/skills/` (copied into each vault).
- **`vps/sync-loop.sh`**: cron-friendly git loop that safely coordinates with Syncthing.
- **`vps/sync_webhook.py`**: optional HTTP endpoint so agents can trigger syncs on demand.

## Quick start

1. **Set up a VPS.** Provision an Ubuntu/Debian server and install the required system packages (`git`, `docker`, `cron`, and a few others).

2. **Create a GitHub repository.** Make a new private repo for each vault. Configure SSH or HTTPS access from the VPS so it can push commits.

3. **Install Corpus.** Clone this repo onto the VPS at `/opt/Corpus`.

4. **Set environment variables.** Copy `vps/.env.example` to `vps/.env` and set your git author name, email, and any optional settings.

5. **Initialize a vault.** Run `scripts/init-vault.sh` with your vault's GitHub remote URL. This bootstraps the vault directory structure and pushes an initial commit.

6. **Connect the vault to Syncthing.** Start Syncthing via Docker Compose, then add your vault folder in the Syncthing UI and share it with your devices. A cron job runs `sync-loop.sh` to keep git in sync on the VPS side.

7. **Connect to Claude Code.** Open the vault directory in Claude Code (on the VPS or on any synced device). The bootstrapped `CLAUDE.md` and `.claude/skills/` give Claude the context it needs to work with your vault.

8. **Basic usage workflow.** Add or edit notes from any synced device. Syncthing propagates changes to the VPS; the cron loop commits and pushes to GitHub every few minutes. From Claude Code, use the vault skills to ingest, query, restructure, and manage content.

For detailed instructions, troubleshooting, and all configuration options, see [docs/setup-and-operations.md](docs/setup-and-operations.md).

## Vault conventions

- `manifest.json` is tracked (`filename` vault-relative; `wiki_pages` paths without `wiki/` prefix; `ingested_at` ISO UTC).
- Cooperation file **`.corpus-git-in-progress`** is gitignored (written only during each cron git run).
