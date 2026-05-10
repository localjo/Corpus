# Setup and operations

Step-by-step guide to setting up Corpus from scratch on a VPS.

## 1. Provision a VPS

Use any Ubuntu/Debian server. Install the required packages:

```bash
sudo apt-get update
sudo apt-get install -y git bash curl cron util-linux findutils ripgrep docker.io
sudo apt-get install -y docker-compose-plugin
sudo systemctl enable --now docker
```

Package notes:
- `util-linux` provides `flock`, used by `install-cron.sh` and the cron entries.
- `ripgrep` (provides `rg`) is used by `install-cron.sh`.
- `docker-compose-plugin` gives you `docker compose` (v2). Install separately if your distro doesn't have it.

## 2. Create a GitHub repository for your vault

1. Go to GitHub and create a new **private** repository (e.g. `my-vault`).
2. Set up SSH access from the VPS so it can push commits:
   - Generate a key: `ssh-keygen -t ed25519 -C "your-email@example.com"`
   - Add the public key to the repo under **Settings → Deploy keys → Add deploy key** (enable write access).
   - Alternatively, use HTTPS with a personal access token (PAT).
3. Note your SSH remote URL (e.g. `git@github.com:you/my-vault.git`) — you'll need it in step 5.

## 3. Install Corpus on the VPS

```bash
sudo git clone https://github.com/localjo/corpus.git /opt/Corpus
```

Keep it up to date when tools change:

```bash
sudo git -C /opt/Corpus pull --rebase origin main
```

## 4. Set environment variables

```bash
cd /opt/Corpus/vps
cp .env.example .env
```

Open `.env` and set at minimum:

- `GIT_AUTHOR_NAME` — your name (used for vault git commits)
- `GIT_AUTHOR_EMAIL` — your email (used for vault git commits)

See `.env.example` for all optional settings: notify webhook URL, Syncthing pause-for-git, sync webhook secret, etc.

## 5. Start Syncthing

```bash
cd /opt/Corpus/vps
docker compose up -d
```

The Syncthing web UI is available at `http://<your-vps-ip>:8384`. Don't expose this port publicly without authentication — use an SSH tunnel or a reverse proxy with auth for remote access.

**Set host ownership** so Syncthing can write vault directories. The image runs as `PUID`/`PGID` from `docker-compose.yml` (default `1000:1000`):

```bash
sudo mkdir -p /srv/vaults
sudo chown -R 1000:1000 /srv/vaults
```

If you change `PUID`/`PGID` in compose, match the values here and recreate the container:

```bash
cd /opt/Corpus/vps && docker compose up -d --force-recreate
```

**Verify Syncthing is running correctly:**

```bash
cd /opt/Corpus/vps && docker compose ps
docker exec syncthing id                  # should show uid=1000
docker exec syncthing ls -la /srv/vaults  # should show your vault directories
docker compose config                     # confirm /srv/vaults:/srv/vaults volume binding
```

## 6. Initialize a vault

```bash
/opt/Corpus/scripts/init-vault.sh git@github.com:you/my-vault.git
```

This creates `/srv/vaults/my-vault` with the standard structure:

```
/srv/vaults/my-vault/
  raw/            # source files before ingestion
  wiki/           # processed wiki pages
  manifest.json   # tracks ingested files
  CLAUDE.md       # Claude Code context for this vault
  .gitignore
  .claude/skills/ # vault skill files (copied from Corpus)
```

Then push the initial commit:

```bash
git -C /srv/vaults/my-vault push origin main
```

If you ran `init-vault.sh` as root, fix ownership so Syncthing can write the vault:

```bash
sudo chown -R 1000:1000 /srv/vaults/my-vault
```

## 7. Connect the vault to Syncthing

1. Open the Syncthing UI at `http://<your-vps-ip>:8384`.
2. Click **Add Folder** and set the folder path to `/srv/vaults/my-vault`.
   - Use this exact path — `docker-compose.yml` binds host `/srv/vaults` to the same path inside the container, so the UI path and the host path are the same.
3. Share the folder with your other devices (Mac, iPhone, etc.) — no custom ignore rules are required for Corpus.
4. On each device, accept the share and let Syncthing complete the initial sync.

**Troubleshooting Syncthing:**

| Symptom | Likely cause |
|---------|-------------|
| `mkdir /srv/vaults`: permission denied | Bind mount not active — run `docker compose up -d --force-recreate`. Or host `/srv/vaults` not writable by UID 1000: run `sudo chown -R 1000:1000 /srv/vaults`. |
| `mkdir …/.stfolder`: permission denied | Vault directory owned by root or wrong UID. Run `sudo chown -R 1000:1000 /srv/vaults/<vault-name>`. |
| If you previously used `/var/syncthing/vaults/…` in the UI | Remove and re-add the folder with the correct path `/srv/vaults/<name>`, then run `docker compose up -d --force-recreate`. |

## 8. Install the cron sync loop

```bash
/opt/Corpus/vps/install-cron.sh my-vault
```

This installs a cron entry that runs `sync-loop.sh` every 5 minutes. The loop:

- Skips committing while Syncthing pull temps (`.syncthing.*.tmp` or `~syncthing~*.tmp`) exist, or while unresolved conflict files (`*.sync-conflict-*` or `.sync-conflict-*`) exist.
- Writes `.corpus-git-in-progress` for the lifetime of each run (for visibility and hooks).
- Commits any changes, pulls with rebase, and pushes to GitHub.
- Uses `flock -n` so overlapping cron ticks skip rather than running two git loops on the same vault.
- Also runs `git config --global --add safe.directory <vault>` for the cron user, so ad-hoc `git` commands from that user work without "dubious ownership" errors.

Re-running `install-cron.sh` replaces the previous Corpus cron entry for that vault.

**Run a sync manually** (same flock path as the cron entry):

```bash
flock -n /tmp/corpus-sync-<vault-basename>.lock \
  /opt/Corpus/vps/sync-loop.sh \
  --vault-dir /srv/vaults/<vault-basename> \
  --env-file /opt/Corpus/vps/.env
```

**Emergency bypass** (skips Syncthing temp/conflict guards — use for recovery only):

```bash
CORPUS_SYNC_FORCE=1 /opt/Corpus/vps/sync-loop.sh \
  --vault-dir /srv/vaults/<vault-basename> \
  --env-file /opt/Corpus/vps/.env
```

## 9. Connect to Claude Code

Open the vault in Claude Code. On the VPS:

```bash
claude /srv/vaults/my-vault
```

On a device with the vault synced locally, open that folder in Claude Code instead. The `CLAUDE.md` and `.claude/skills/` files bootstrapped by `init-vault.sh` give Claude the context and skills it needs to work with vault content.

## 10. Basic usage workflow

- **Add or edit notes** from any synced device — Obsidian, a text editor, or Claude Code.
- **Syncthing** propagates changes to the VPS within seconds to minutes.
- **The cron loop** commits and pushes to GitHub every 5 minutes. You can also trigger an on-demand sync via the optional webhook (see below).
- **From Claude Code**, use the vault skills to ingest files, query content, restructure wiki pages, and manage the vault.

---

## Reference

### Sync webhook (optional)

A small Python listener on `127.0.0.1:8780` runs the same `sync-loop` as cron, on demand. Useful for agents that need to flush changes immediately without waiting for the next cron tick.

**Install (one-time, global):**

```bash
sudo /opt/Corpus/vps/install-sync-webhook.sh
```

This is idempotent. Each run:
- Creates `vps/.env` from `vps/.env.example` if missing (mode 0600).
- Generates `CORPUS_GITHUB_WEBHOOK_SECRET` with `secrets.token_hex(32)` if missing or empty (existing value preserved).
- Installs `corpus-sync-webhook.service` and (re)starts it.

Re-run after editing `vps/.env` or pulling a new Corpus version.

**Verify:**

```bash
journalctl -u corpus-sync-webhook -f
curl -sSf http://127.0.0.1:8780/healthz
# → {"ok": true, "agent_sync": true, "github_push_webhook": true}
```

Syntax-only check (no port binding):

```bash
cd /opt/Corpus/vps && set -a && . ./.env && set +a && \
  CORPUS_SYNC_WEBHOOK_SYNTAX_ONLY=1 python3 ./sync_webhook.py
```

**Endpoints:**

- `POST /sync/<vault>` — unauthenticated; triggers an immediate sync for the named vault. A per-vault `flock` returns `503 Retry-After: 5` if a sync is already in flight.
- `POST /hooks/github` with `X-Hub-Signature-256` — GitHub push webhook, signed with `CORPUS_GITHUB_WEBHOOK_SECRET`; only `refs/heads/main` triggers a sync.

**Response codes for `POST /sync/<vault>`:**

| Code | Meaning |
|------|---------|
| `200 sync_completed: true` | `sync-loop` exited 0 (commit / pull --rebase / push). |
| `503 skipped: "busy"` + `Retry-After: 5` | A sync for this vault is already in flight; retry shortly. |
| `502 exit: <n>` | `sync-loop` itself failed; check `journalctl -u corpus-sync-webhook`. |
| `404 vault_unknown` | The basename is not a directory under `/srv/vaults/` with a `.git/`. |

Vaults are auto-discovered from `/srv/vaults/*/.git/`, so adding more vaults requires no listener config — just run `scripts/init-vault.sh` and `vps/install-cron.sh` for each new vault.

**Public exposure (Caddy / nginx):**

GitHub cannot reach `127.0.0.1:8780` directly. Front the listener with HTTPS and expose only `/hooks/github` and `/sync/*`:

```
corpus.example.com {
    @public path /hooks/github /sync/*
    handle @public {
        reverse_proxy 127.0.0.1:8780
    }
    handle {
        respond 404
    }
}
```

Verify from any machine:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -X POST https://corpus.example.com/hooks/github
# → 401  (no signature on purpose; means the public path reaches the listener)

curl -sS -o /dev/null -w "%{http_code}\n" https://corpus.example.com/healthz
# → 404  (intentionally not exposed)
```

**GitHub webhook setup (per repository):**

1. Repository **Settings → Webhooks → Add webhook**
2. **Payload URL**: `https://corpus.example.com/hooks/github`
3. **Content type**: `application/json`
4. **Secret**: value of `CORPUS_GITHUB_WEBHOOK_SECRET` from `vps/.env` (one secret for every Corpus-managed repo behind this VPS)
5. **Events**: push events only — only `refs/heads/main` triggers a sync; others return `skipped: "wrong_ref"` with 200
6. **Save** and watch **Recent Deliveries** for 200

If you rotate `CORPUS_GITHUB_WEBHOOK_SECRET`, update every GitHub webhook and restart the service: `sudo systemctl restart corpus-sync-webhook`.

**Trigger a sync from an agent:**

```bash
curl -sSf -X POST https://corpus.example.com/sync/YOUR_VAULT_BASENAME
# → {"ok": true, "sync_completed": true}
```

Threat model for the unauthenticated `/sync/*` path: an attacker who knows a vault basename can trigger repeated idempotent syncs (extra `git fetch`/`push` on the VPS). The 503 fast-fail bounds the rate to roughly one `sync-loop` runtime per vault. No vault contents are exposed over this path. If that's not acceptable, add Caddy basic auth or an IP allowlist.

### Optional: pause Syncthing while git runs

Usually not needed — the temp/conflict guards are sufficient for most setups. After those guards, commits take only a few seconds; overlap with an inbound sync is uncommon.

Enable in `vps/.env` if you want stricter mutual exclusion:

- `SYNCTHING_PAUSE_FOR_GIT=1`
- `SYNCTHING_API_KEY=…` (from Syncthing **Actions → Settings → API**)
- `SYNCTHING_API_URL` (optional; defaults to `http://127.0.0.1:8384`)

Implementation: `sync-loop` calls `POST /rest/system/pause` before git operations and `POST /rest/system/resume` after. A host-wide `flock` serializes all vault sync-loop runs using pause, so Vault A cannot resume while Vault B still holds peers paused. `CORPUS_SYNC_FORCE=1` skips the pause as well.

### Lock semantics

- Cron **skips commit** when: pull temps (`.syncthing.*.tmp` or `~syncthing~*.tmp`) exist under the vault, or conflict files (`*.sync-conflict-*` or `.sync-conflict-*`) exist.
- Cron does **not** skip for non-temp `.syncthing.*` filenames (Syncthing ignores that namespace anyway).
- `.corpus-git-in-progress` is written by `sync-loop` only; nothing in stock Syncthing or Obsidian reads it. It's for visibility and future hooks.
- Stale `.syncthing….tmp` files: Syncthing may retain a `.tmp` for up to ~a day after some errors. Cron stays blocked until Syncthing removes it or you delete it manually.

### Git "dubious ownership"

If the vault is owned by UID `1000` but `git` runs as root, Git 2.35+ may refuse the repo with *dubious ownership detected*.

- `sync-loop.sh` exports `GIT_CONFIG_*` to trust only the vault directory for that run (requires Git 2.31+).
- `install-cron.sh` idempotently runs `git config --global --add safe.directory <vault>` for the cron user so ad-hoc `git` commands from that user also work.

This marks one absolute path you control as trusted — it does not open `*` (all directories). Don't add paths writable by untrusted users. If your VPS has Git older than 2.31, upgrade `git` or run `sync-loop` as the same UID that owns the vault.

### Stale coordination files

If a sync-loop run is killed with `-9`, remove the stale marker manually:

```bash
rm /srv/vaults/<vault-name>/.corpus-git-in-progress
```

**If `.corpus-git-in-progress` was accidentally committed to git**, remove it from the index:

```bash
cd /srv/vaults/<vault-name>
git pull --rebase origin main
grep -qxF '.corpus-git-in-progress' .gitignore || \
  printf '\n# Corpus sync coordination (never commit)\n.corpus-git-in-progress\n' >> .gitignore
git rm --cached .corpus-git-in-progress
git commit -m "Stop tracking Corpus sync marker; add .gitignore rule"
git push origin main
```

On other clones (Mac, etc.) run `git pull`. `sync-loop` also runs `git rm --cached` after `git add -A` on each run to avoid re-committing a mis-ignored marker, but `.gitignore` must stay correct on `main`.

Legacy `.corpus-syncthing-folder-id` files from older Corpus versions can be deleted — they are unused.
