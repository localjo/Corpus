# Corpus

Minimal tooling for a personal wiki workflow:

- One private GitHub repo per vault.
- Vault files synced to devices via Syncthing.
- Git operations run on VPS only (cron loop).
- Claude Code uses committed vault files and skills.

## What this repo provides

- Vault bootstrap templates (`raw/`, `wiki/`, `manifest.json`, `CLAUDE.md`, `.gitignore`).
- Shared skill files in `.claude/skills/` (copied into each vault).
- **`vps/sync-loop.sh`**: cron-friendly `git` loop with **automatic** safeguards:
  - Skips committing while Syncthing **pull temps** (`.syncthing.*.tmp` or `~syncthing~*.tmp`) exist, or while unresolved **conflict** files (`*.sync-conflict-*` or `.sync-conflict-*`) exist ([Syncthing docs](https://docs.syncthing.net/users/syncing.html)).
  - Creates **`.corpus-git-in-progress`** for the lifetime of each run (visibility / hooks; not read by stock Syncthing).
  - Cron entry uses per-vault **`flock -n`** so overlapping ticks skip instead of running two git loops on the same repo.

## Prerequisites

Per vault: private GitHub repo + VPS SSH access to git push.

On the VPS: `git`, `bash`, `curl`, `cron`, `flock`, `find`, `rg` (ripgrep — used by `install-cron.sh`), Docker (for Syncthing compose only).

## Quick start

1. Clone this repo on the VPS (`/opt/Corpus`).
2. Set author in `/opt/Corpus/vps/.env` (see `vps/.env.example`).
3. Start Syncthing: `cd /opt/Corpus/vps && cp .env.example .env && docker compose up -d`.
4. Bootstrap a vault: `./scripts/init-vault.sh git@github.com:you/my-vault.git` (creates **`vps/.env`** from **`.env.example`** if missing).
5. Let Syncthing’s container user own the vault tree (default **`PUID`/`PGID` `1000`** in **`vps/docker-compose.yml`**): **`sudo chown -R 1000:1000 /srv/vaults`** (avoids **`permission denied`** on **`/srv/vaults`** / **`.stfolder`**). Detail: **`docs/setup-and-operations.md`** → *Syncthing (Docker)*.
6. In Syncthing’s UI, folder path **`/srv/vaults/<name>`** (same path in container and on host).
7. Cron: `./vps/install-cron.sh <vault-name>` (default every **5** minutes; **`install-cron`** also sets **`safe.directory`** for the cron user; **`sync-loop`** trusts **`--vault-dir`** per run).

Emergency one-shot: **`CORPUS_SYNC_FORCE=1`** on **`sync-loop`** bypasses Syncthing skips.

Optional **`SYNCTHING_PAUSE_FOR_GIT=1`** — see **`docs/setup-and-operations.md`** and **`vps/.env.example`**.

**Sync webhook (optional):** HTTP on **`127.0.0.1:8780`** runs the same **`sync-loop`** as cron — **`POST /sync/<vault>`** (unauthenticated; idempotent + per-vault flock rate limit) for agents to flush on demand, and **`POST /hooks/github`** (HMAC) for pushes on **`main`**. One-time global install (vaults under **`/srv/vaults`** are auto-discovered): **`sudo /opt/Corpus/vps/install-sync-webhook.sh`** — see **`docs/setup-and-operations.md`**.

## Vault conventions

- `manifest.json` is tracked (`filename` vault-relative; `wiki_pages` paths without `wiki/` prefix; `ingested_at` ISO UTC).
- Cooperation file **`.corpus-git-in-progress`** is **gitignored** (written only during each cron git run).

See `docs/setup-and-operations.md` for fuller notes.
