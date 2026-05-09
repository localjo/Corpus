# Setup and operations

## VPS packages

Ubuntu/Debian: `git`, `bash`, `curl`, `cron`, `findutils`, `flock` (often in `util-linux`), `ripgrep` (package `ripgrep`, provides `rg` for `install-cron.sh`), `docker.io`, Docker Compose plugin.

## GitHub access

Manual private repo creation per vault + SSH deploy key (or HTTPS + PAT).

## Corpus clone

`/opt/Corpus` from GitHub — `git pull --rebase origin main` when tools update.

`/opt/Corpus/vps/.env` from `.env.example` — set webhook and git author strings as needed.

## Syncthing (Docker)

```bash
cd /opt/Corpus/vps
docker compose up -d
```

In the Syncthing UI, add a folder whose path is `/srv/vaults/<vault-name>`. Share with Mac/iPhone — **nothing else required** for Corpus locking: per [Syncthing’s “Temporary files”](https://docs.syncthing.net/users/syncing.html), in-flight pulls write **`basename.tmp`** files prefixed **`\.syncthing.`** or **`~syncthing~`**; unresolved [conflicts](https://docs.syncthing.net/users/syncing.html) use **`basename.sync-conflict-…`** (or a leading **`\.sync-conflict-…`**). **`sync-loop` skips commits only for those**, not for other reserved-namespace names without **`.tmp`** (e.g. a stray **`\.syncthing.notes.md`** Syncthing would ignore anyway).

## Vault bootstrap

```bash
/opt/Corpus/scripts/init-vault.sh git@github.com:you/repo.git
git -C /srv/vaults/<repo-base> push origin main
```

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
