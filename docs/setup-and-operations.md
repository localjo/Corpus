# Setup and operations

## VPS packages

Ubuntu/Debian: `git`, `bash`, `curl`, `cron`, `findutils`, `flock` (often in `util-linux`), `ripgrep` (package `ripgrep`, provides `rg` for `install-cron.sh`), `docker.io`, Docker Compose plugin.

## GitHub access

Manual private repo creation per vault + SSH deploy key (or HTTPS + PAT).

## Corpus clone

`/opt/Corpus` from GitHub — `git pull --rebase origin main` when tools update.

`/opt/Corpus/vps/.env` from `.env.example` — set webhook and git author strings as needed.

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

Each invocation:

- Exits **`0` skip** if Syncthing **pull temps** (`.syncthing.*.tmp` or `~syncthing~*.tmp`) or unresolved **sync-conflict** files exist under the vault (incoming batch / conflict cleanup not finished).
- Touches `.corpus-git-in-progress`, runs `git add`/`commit` (if dirty) / `pull --rebase` / `push`, removes `.corpus-git-in-progress` in a `trap` on exit.

`flock -n` in the cron line means a tick **skips immediately** if the previous run has not finished (no queueing).

## Stale coordination files

If a run is killed `-9`, remove stale `.corpus-git-in-progress` by hand once. Optionally `CORPUS_SYNC_FORCE=1` for recovery.

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
