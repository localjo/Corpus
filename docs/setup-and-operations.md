# Setup and operations

## VPS packages

Ubuntu/Debian: `git`, `bash`, `curl`, `cron`, `findutils`, `flock` (often in `util-linux`), `ripgrep` (package `ripgrep`, provides `rg` for `install-cron.sh`), `docker.io`, Docker Compose plugin.

## GitHub access

Manual private repo creation per vault + SSH deploy key (or HTTPS + PAT).

## Corpus clone

`/opt/Corpus` from GitHub — `git pull --rebase origin main` when tools update.

`/opt/Corpus/vps/.env` from **`vps/.env.example`** (minimal). Optional **`NOTIFY_WEBHOOK_URL`**, **`CORPUS_SYNC_FORCE`**, Syncthing pause-for-git (`SYNCTHING_*`), etc.: see later sections here.

## Syncthing (Docker)

### Start

```bash
cd /opt/Corpus/vps
docker compose up -d
```

After changing **`vps/docker-compose.yml`** (volumes, `PUID`, etc.), recreate the container so the new mounts apply:

```bash
cd /opt/Corpus/vps && docker compose up -d --force-recreate
```

### Host ownership (do this before expecting sync to work)

The image runs Syncthing as **`PUID` / `PGID`** from compose (default **`1000:1000`** in `vps/docker-compose.yml`). Inside the container that user must be able to **create subdirectories of `/srv/vaults`** and write the **`.stfolder`** marker inside each shared vault.

If `init-vault.sh` or `mkdir` ran as **root**, the tree is often **`root:root`** and Syncthing **cannot** write — you see **`permission denied`** on **`mkdir /srv/vaults`**, **`.stfolder`**, or similar.

**On the VPS host** (match `PUID`/`PGID` if you changed them in compose):

```bash
sudo mkdir -p /srv/vaults
sudo chown -R 1000:1000 /srv/vaults
```

For a single vault after the fact:

```bash
sudo chown -R 1000:1000 /srv/vaults/<vault-name>
```

**Cron note:** `sync-loop` is often run as **root** via cron; root can still read/write a vault owned by **1000**. If git runs as a **non-root** deploy user, align ownership or use a shared group and `chmod g+rwX` so both that user and UID **1000** can update the repo.

### Folder path in the Syncthing UI

Use **`/srv/vaults/<vault-name>`**. `docker-compose.yml` binds host **`/srv/vaults`** to the **same** path in the container (not `/var/syncthing/vaults/...`), so it matches `init-vault.sh` and cron.

If you ever used an older layout (`/var/syncthing/vaults/...` in the UI), change the folder path (or remove and re-add) after updating compose, then **Recreate** as above.

### Troubleshooting (common log lines)

| Symptom | Likely cause |
|---------|-------------|
| `mkdir /srv/vaults`: permission denied | Bind mount not active (run **`docker compose up -d --force-recreate`**). Or host **`/srv/vaults`** not writable by Syncthing’s UID (default **1000**): use **Host ownership** above. |
| `mkdir …/.stfolder`: permission denied | Vault directory owned by **root** or wrong UID. **`sudo chown -R 1000:1000 /srv/vaults/<vault-name>`** on the host. |

**Sanity checks:**

```bash
cd /opt/Corpus/vps && docker compose ps
docker exec syncthing id
docker exec syncthing ls -la /srv/vaults
docker compose config   # confirm volumes include /srv/vaults:/srv/vaults
```

You want **`syncthing` / UID `1000`** (unless you changed `PUID`) and **`ls`** inside the container to show your vault directories.

### Corpus locking (nothing extra in Syncthing config)

Share the folder with Mac/iPhone — no Folder ID or custom ignore rules required for Corpus. Per [Syncthing “Temporary files”](https://docs.syncthing.net/users/syncing.html), in-flight pulls use **`basename.tmp`** with prefixes **`\.syncthing.`** or **`~syncthing~`**; [conflicts](https://docs.syncthing.net/users/syncing.html) use **`*.sync-conflict-*`** / **`.sync-conflict-*`**. **`sync-loop` skips commits only for those** patterns, not for other **`\.syncthing.*`** names without **`.tmp`** (e.g. a stray **`\.syncthing.notes.md`** Syncthing would ignore anyway).

## Vault bootstrap

```bash
/opt/Corpus/scripts/init-vault.sh git@github.com:you/repo.git
git -C /srv/vaults/<repo-base> push origin main
```

Then ensure Syncthing can write the vault tree (see **Host ownership** above), especially if **`init-vault.sh`** was run with **`sudo`**.

## Cron

```bash
/opt/Corpus/vps/install-cron.sh <vault-name>
```

Re-running replaces the previous Corpus line for that vault. **`flock -n`** skips a tick if the last run has not finished.

One manual **`sync-loop`** (same **`flock`** path as **`install-cron.sh`** installs):

```bash
flock -n /tmp/corpus-sync-<vault-basename>.lock \
  /opt/Corpus/vps/sync-loop.sh \
  --vault-dir /srv/vaults/<vault-basename> \
  --env-file /opt/Corpus/vps/.env
```

## Sync webhook (same `sync-loop` over HTTP)

A small Python listener on **`127.0.0.1:8780`** runs the same **`sync-loop`** as cron, on demand:

- **`POST /sync/<vault>`** — **unauthenticated.** The vault basename is the path; **`sync-loop`** is idempotent (worst case is an extra `git fetch`); a non-blocking per-vault flock returns **`503` `Retry-After: 5`** when a sync is already in flight, so concurrent calls cap the per-vault rate at ~1 per `sync-loop` run. Used by agents that cannot hold a secret (e.g. Claude Code in cloud) to flush on demand.
- **`POST /hooks/github`** with **`X-Hub-Signature-256`** — GitHub triggers a sync on every push to **`refs/heads/main`**, signed with **`CORPUS_GITHUB_WEBHOOK_SECRET`**. This is the **only** signed entry point.

Vaults are auto-discovered from **`/srv/vaults/*/.git/`**, so there is **no per-vault config**. Once the listener is installed, every vault under **`/srv/vaults`** is reachable by basename and routed by **`origin`** URL for GitHub events. Skip this section entirely if cron alone is enough.

### **Setup (one-time, global)**

```bash
sudo /opt/Corpus/vps/install-sync-webhook.sh
```

Idempotent. This:

- Creates **`vps/.env`** from **`vps/.env.example`** if missing (mode 0600).
- Generates **`CORPUS_GITHUB_WEBHOOK_SECRET`** with **`secrets.token_hex(32)`** if missing or empty (existing value preserved).
- Installs **`corpus-sync-webhook.service`** and **(re)starts** it; copies a fresh unit on each run when the file content changed.

Re-run any time after editing **`vps/.env`** or pulling a new Corpus version. Without **`sudo`** the script only ensures the secret — no systemd changes.

Logs: **`journalctl -u corpus-sync-webhook -f`**. Smoke: **`curl -sSf http://127.0.0.1:8780/healthz`** returns **`{"ok": true, "agent_sync": true, "github_push_webhook": true}`**. Syntax-only sanity check (no port binding):

```bash
cd /opt/Corpus/vps && set -a && . ./.env && set +a && \
  CORPUS_SYNC_WEBHOOK_SYNTAX_ONLY=1 python3 ./sync_webhook.py
```

### **Adding more vaults**

Run **`scripts/init-vault.sh git@github.com:owner/<name>.git`**, register cron with **`vps/install-cron.sh <name>`** (recommended as a steady-state fallback), and the listener picks up **`/srv/vaults/<name>`** at the next request — no listener restart, no env edit.

### **Public exposure (Caddy / nginx / tunnel)**

GitHub cannot reach **`127.0.0.1:8780`** directly, and you'll usually want **`/sync/*`** reachable to agents on the public internet. Front the listener with an HTTPS endpoint and forward **`/hooks/github`** + **`/sync/*`** only — keep **`/healthz`** private.

Caddyfile snippet (replace the host with your subdomain):

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

`reload caddy`, then verify from any machine:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -X POST https://corpus.example.com/hooks/github
# → 401  (no signature on purpose; means the public path reaches the listener)

curl -sS -o /dev/null -w "%{http_code}\n" https://corpus.example.com/healthz
# → 404  (intentionally not exposed)
```

### **GitHub (per repository)**

For each repo whose vault should auto-sync:

1. **Settings** → **Webhooks** → **Add webhook**.
2. **Payload URL**: your public HTTPS URL ending in **`/hooks/github`** (e.g. **`https://corpus.example.com/hooks/github`**).
3. **Content type**: **`application/json`**.
4. **Secret**: paste the value of **`CORPUS_GITHUB_WEBHOOK_SECRET`** from **`vps/.env`** (one secret for **every** Corpus-managed repo behind this VPS).
5. **Events**: just push events — only **`refs/heads/main`** triggers a sync; others return **`skipped: "wrong_ref"`** with **200**.
6. **Save** and watch **Recent Deliveries** for **200**.

The listener routes each delivery to the vault under **`/srv/vaults/`** whose **`.git/config`** **`origin`** URL matches **`repository.full_name`**. If you rotate **`CORPUS_GITHUB_WEBHOOK_SECRET`**, update each GitHub webhook **and** **`sudo systemctl restart corpus-sync-webhook`**.

### **Agents / operators (`POST /sync/<vault>`)**

No secret to manage. From any machine that can reach the public endpoint:

```bash
curl -sSf -X POST https://corpus.example.com/sync/YOUR_VAULT_BASENAME
# → {"ok": true, "sync_completed": true}
```

**`200 sync_completed: true`** — `sync-loop` exited **0** (commit / pull --rebase / push).
**`503 skipped: "busy"` + `Retry-After: 5`** — a sync for this vault is already in flight; retry shortly. The `Retry-After` value is conservative — most syncs finish in a second or two.
**`502 exit: <n>`** — `sync-loop` itself failed; check **`journalctl -u corpus-sync-webhook`**.
**`404 vault_unknown`** — the basename is not a directory under `/srv/vaults/` with a `.git/`.

Threat model for the unauthenticated path: an attacker who learns a vault basename can cause repeated **idempotent** syncs (extra `git fetch`/`push` on the VPS). The 503 fast-fail bounds the rate to roughly one `sync-loop` runtime per vault. There is no read of vault contents over this path; sync-loop only manipulates git state. If that's not acceptable for your deployment, add Caddy basic auth or a path-scoped allowlist on the public site.

### Git “dubious ownership” (Syncthing `chown 1000` + cron as root)

If the vault is owned by **`1000`** but **`git`** runs as **root**, Git **2.35+** can refuse the repo: *dubious ownership detected…*

**What we do in Corpus**

- **`sync-loop.sh`** exports **`GIT_CONFIG_*`** so this run trusts **only** `--vault-dir` (Git **2.31+**), with no manual config.
- **`install-cron.sh`** idempotently runs **`git config --global --add safe.directory <that vault>`** for **whoever installs cron** so ad-hoc **`git -C /srv/vaults/…`** from the same user works too.

**Is that safe?** Yes in the usual sense: you are not opening **`*`** (all directories). You are marking **one absolute path you control** as trusted for Git’s directory-ownership check (mitigation for [CVE-2022-24765](https://github.blog/2022-04-12-git-security-vulnerability-announced/)–style issues). Don’t add paths writable by untrusted users.

Older than Git **2.31**: upgrade **`git`** on the VPS, or run **`sync-loop`** / **`git`** as the same UID that owns the vault directory (heavy).

Each invocation:

- Exits **`0` skip** if Syncthing **pull temps** (`.syncthing.*.tmp` or `~syncthing~*.tmp`) or unresolved **sync-conflict** files exist under the vault (incoming batch / conflict cleanup not finished).
- Touches `.corpus-git-in-progress`, runs `git add`/`commit` (if dirty) / `pull --rebase` / `push`, removes `.corpus-git-in-progress` in a `trap` on exit.

## Stale coordination files

If a run is killed `-9`, remove stale `.corpus-git-in-progress` by hand once. Optionally `CORPUS_SYNC_FORCE=1` for recovery.

**Tracked by mistake (`.corpus-git-in-progress`):** Putting a path in **`.gitignore` does nothing for files Git already tracks** — you must **edit `.gitignore` and** run **`git rm --cached`** once, then **commit and push** from one place (VPS vault dir or a local clone; same **`main`** as GitHub).

Do this sequence at the vault root (example path on the VPS: **`/srv/vaults/festival-wiki-vault`** — use your directory name):

```bash
cd /srv/vaults/<vault-name>
git pull --rebase origin main

# Append the rule only if it is not already present (avoid duplicate lines).
grep -qxF '.corpus-git-in-progress' .gitignore || printf '\n# Corpus sync coordination (never commit)\n.corpus-git-in-progress\n' >> .gitignore

# Remove from Git’s index only; the file stays on disk for cron/Syncthing.
git rm --cached .corpus-git-in-progress

git status   # Expect: modified `.gitignore` + staged deletion of `.corpus-git-in-progress` (not removing the physical file).

git commit -m "Stop tracking Corpus sync marker; add .gitignore rule"
git push origin main
```

On other clones (Mac, etc.) run **`git pull`** — Git drops the tracked copy of the marker from the revision; **`git`** may leave a leftover untracked file or remove it cleanly; Syncthing/cron recreate **`touch .corpus-git-in-progress`** briefly during runs anyway. **`sync-loop`** also runs **`git rm --cached`** after **`git add -A`** on each run so a mis‑ignored marker is less likely to be recommitted—but **`.gitignore`** must stay correct **on `main`** or the marker can be picked up again by **`git add -A`** as an untracked file.

Legacy **`.corpus-syncthing-folder-id`** from older Corpus can be deleted; it is unused.

### Lock semantics (what blocks what)

- **Cron skips commit** when: pull temps `.syncthing.*.tmp` or `~syncthing~*.tmp` exist; or conflict copies match `*.sync-conflict-*` or `.sync-conflict-*`.
- **Cron does not skip** solely because a non-temp `.syncthing.whatever` name exists (Syncthing ignores that namespace anyway).
- **`.corpus-git-in-progress`** is written only by `sync-loop`; it does **not** stop Syncthing or editors unless **you** add something that watches it.

`.corpus-git-in-progress` is for **visibility and future hooks**; nothing in stock Syncthing or Obsidian listens to it today.

**Stale `.syncthing….tmp`**: Syncthing may retain a `.tmp` for up to ~a day after some errors ([docs](https://docs.syncthing.net/users/syncing.html)) — cron stays blocked until Syncthing removes it or you delete it.

Syncthing’s reserved prefix without `.tmp` does **not** block cron anymore; prefer not to use `.syncthing…` or `~syncthing~` prefixes in your **own** filenames anyway (Syncthing ignores those paths).

### Optional: pause Syncthing while git runs

**Do you need this?** Often **no**. After the `.syncthing.*.tmp` / conflict guards, commits are usually a few seconds; overlap with inbound sync is uncommon. Turning pause on buys a stricter mutual-exclusion window at the cost of **API setup** (`SYNCTHING_API_URL` + `SYNCTHING_API_KEY` only — still no Folder ID).

Implementation: **`POST /rest/system/pause`** pauses connections to remote **devices**; **`POST /rest/system/resume`** restores ([docs](https://docs.syncthing.net/rest/system-pause-post.html)). A host-wide **`flock`** serializes all vault **`sync-loop`** runs that use pause, so Vault A cannot `resume` while Vault B still holds peers paused.

Enable in `vps/.env`:

- `SYNCTHING_PAUSE_FOR_GIT=1`
- `SYNCTHING_API_KEY=…` (from Syncthing **Actions → Settings → API**)
- Optionally `SYNCTHING_API_URL` if not `http://127.0.0.1:8384`

`CORPUS_SYNC_FORCE=1` skips pause as well.

## Agent / multi-device edits

Agent and device edits reach the VPS through **git** or **Syncthing**; cron coordinates with Syncthing via temp/conflict skips and optionally **pause during git**. Prefer coherent **`git commit` + `git push`** when batches should land as atomic commits on GitHub.
