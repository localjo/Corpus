#!/usr/bin/env python3
"""
On-demand vault sync over HTTP — runs the SAME sync-loop.sh as cron.

Two endpoints, both block until sync-loop exits:

  POST /sync/<vault>
    Authorization: Bearer <CORPUS_SYNC_WEBHOOK_SECRET>
    Use: Claude / operators trigger a sync before reading or after writing,
    and wait for {"ok": true, "sync_completed": true} before proceeding.

  POST /hooks/github
    X-GitHub-Event: push (refs/heads/main only)
    X-Hub-Signature-256: sha256=<hex>
    Use: GitHub redelivery on every push.

Vaults are discovered automatically:
  - Bearer endpoint accepts any directory under /srv/vaults that is a git repo.
  - GitHub endpoint maps `repository.full_name` to a vault by reading each
    vault's `origin` URL from .git/config — no CORPUS_GITHUB_REPO_MAP needed.

GET /healthz reports which modes are enabled (agent_sync / github_push_webhook).

Env (at least one of the two secrets is required):
  CORPUS_SYNC_WEBHOOK_SECRET   — Bearer for POST /sync/<vault>
  CORPUS_GITHUB_WEBHOOK_SECRET — GitHub HMAC

Bind/port/parent are intentionally hardcoded:
  127.0.0.1:8780 / /srv/vaults / refs/heads/main

One-off CLI check: CORPUS_SYNC_WEBHOOK_SYNTAX_ONLY=1
"""

from __future__ import annotations

import configparser
import fcntl
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Mapping
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
VAULT_PARENT = Path("/srv/vaults")
GITHUB_PUSH_REF = "refs/heads/main"
LISTEN_BIND = "127.0.0.1"
LISTEN_PORT = 8780
LOCK_DIR = Path("/tmp")

VAULT_RE = re.compile(r"^[a-zA-Z0-9._-]+$")
MAX_BODY = 384 * 1024

_REPO_FROM_URL = re.compile(
    r"github\.com[/:]([^/\s:]+)/([^/\s:#]+?)(?:\.git)?(?:[#?].*)?$"
)


def env_bool(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def derive_repo_full(url: str) -> str | None:
    """Return 'owner/repo' from common GitHub clone URLs."""
    if not url:
        return None
    m = _REPO_FROM_URL.search(url.strip())
    if not m:
        return None
    owner, name = m.group(1).strip(), m.group(2).strip()
    if owner and name:
        return f"{owner}/{name}"
    return None


def vault_origin_url(vault_dir: Path) -> str | None:
    """Read remote.origin.url from <vault>/.git/config, or None if unreadable."""
    cfg = vault_dir / ".git" / "config"
    if not cfg.is_file():
        return None
    cp = configparser.ConfigParser(strict=False)
    try:
        cp.read(cfg)
    except configparser.Error:
        return None
    section = 'remote "origin"'
    if cp.has_section(section):
        return cp.get(section, "url", fallback=None)
    return None


def is_valid_vault(name: str) -> bool:
    """True iff /srv/vaults/<name>/.git exists and the path stays under VAULT_PARENT."""
    if not VAULT_RE.fullmatch(name):
        return False
    try:
        path = (VAULT_PARENT / name).resolve()
        path.relative_to(VAULT_PARENT.resolve())
    except (OSError, ValueError):
        return False
    return path.is_dir() and (path / ".git").exists()


def find_vault_for_repo(repo_full_name: str) -> str | None:
    """Locate the vault basename under /srv/vaults whose origin matches owner/repo."""
    if not repo_full_name or not VAULT_PARENT.is_dir():
        return None
    target = repo_full_name.casefold()
    try:
        entries = sorted(VAULT_PARENT.iterdir())
    except OSError:
        return None
    for entry in entries:
        if not entry.is_dir() or not VAULT_RE.fullmatch(entry.name):
            continue
        url = vault_origin_url(entry)
        if not url:
            continue
        derived = derive_repo_full(url)
        if derived and derived.casefold() == target:
            return entry.name
    return None


def bearer_ok(got: str, want: str) -> bool:
    gb, wb = got.encode("utf-8"), want.encode("utf-8")
    if len(gb) != len(wb):
        return False
    return hmac.compare_digest(gb, wb)


def github_sig_ok(secret: str, payload: bytes, sig_header: str | None) -> bool:
    if not sig_header or not sig_header.startswith("sha256="):
        return False
    recv = sig_header[7:].strip().lower()
    if len(recv) != 64 or any(c not in "0123456789abcdef" for c in recv):
        return False
    exp = hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest().lower()
    return hmac.compare_digest(recv.encode("ascii"), exp.encode("ascii"))


def main() -> None:
    bearer_secret = os.environ.get("CORPUS_SYNC_WEBHOOK_SECRET", "").strip()
    gh_secret = os.environ.get("CORPUS_GITHUB_WEBHOOK_SECRET", "").strip()

    if not bearer_secret and not gh_secret:
        print(
            "Need at least one of CORPUS_SYNC_WEBHOOK_SECRET (Bearer) "
            "or CORPUS_GITHUB_WEBHOOK_SECRET (GitHub).",
            file=sys.stderr,
        )
        sys.exit(1)

    sync_loop = SCRIPT_DIR / "sync-loop.sh"
    if not sync_loop.is_file():
        print(f"sync-loop.sh missing next to listener: {sync_loop}", file=sys.stderr)
        sys.exit(1)

    env_file = SCRIPT_DIR / ".env"

    if env_bool("CORPUS_SYNC_WEBHOOK_SYNTAX_ONLY"):
        modes = []
        if bearer_secret:
            modes.append("bearer /sync")
        if gh_secret:
            modes.append("github /hooks/github")
        print(f"CORPUS_SYNC_WEBHOOK_SYNTAX_ONLY=1 OK — {', '.join(modes)}", file=sys.stderr)
        sys.exit(0)

    class Handler(BaseHTTPRequestHandler):
        server_version = "CorpusSyncWebhook/1.0"

        def log_message(self, fmt: str, *args: object) -> None:
            sys.stderr.write(
                f"{self.address_string()} - [{self.log_date_time_string()}] {fmt % args}\n"
            )

        def _json(self, code: int, payload: Mapping[str, object]) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _run_sync(self, vault: str) -> subprocess.CompletedProcess[str]:
            # Blocking exclusive lock per vault — interoperates with cron's flock(1) on the
            # same path. Multiple concurrent webhook requests for the same vault serialize
            # rather than fail-fast, so callers always get a definitive sync_completed.
            lock_path = LOCK_DIR / f"corpus-sync-{vault}.lock"
            fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                argv = [
                    str(sync_loop),
                    "--vault-dir",
                    str((VAULT_PARENT / vault).resolve()),
                ]
                if env_file.is_file():
                    argv += ["--env-file", str(env_file)]
                return subprocess.run(
                    argv, capture_output=True, text=True, cwd=str(SCRIPT_DIR)
                )
            finally:
                try:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                except OSError:
                    pass
                os.close(fd)

        def _respond_after_sync(self, proc: subprocess.CompletedProcess[str]) -> None:
            if proc.returncode != 0:
                self._json(
                    502,
                    {"ok": False, "sync_completed": False, "exit": proc.returncode},
                )
                return
            self._json(200, {"ok": True, "sync_completed": True})

        def _sync_endpoint(self) -> None:
            if not bearer_secret:
                self._json(503, {"ok": False, "sync_completed": False, "error": "agent_sync_disabled"})
                return
            auth = self.headers.get("Authorization") or ""
            bearer = auth[7:].strip() if auth.casefold().startswith("bearer ") else ""
            if not bearer:
                bearer = (self.headers.get("X-Corpus-Webhook-Secret") or "").strip()
            if not bearer_ok(bearer, bearer_secret):
                self._json(401, {"ok": False, "sync_completed": False, "error": "unauthorized"})
                return
            path = urlparse(self.path).path.rstrip("/")
            vault = path[len("/sync/") :].split("/", maxsplit=1)[0]
            if not vault or not is_valid_vault(vault):
                self._json(404, {"ok": False, "sync_completed": False, "error": "vault_unknown"})
                return
            self._respond_after_sync(self._run_sync(vault))

        def _github_endpoint(self) -> None:
            if not gh_secret:
                self.send_response(404)
                self.end_headers()
                return
            sig = self.headers.get("X-Hub-Signature-256")
            event = (self.headers.get("X-GitHub-Event") or "").strip()
            cl_raw = self.headers.get("Content-Length")
            if cl_raw is None:
                self._json(411, {"ok": False, "sync_completed": False, "error": "length_required"})
                return
            try:
                cl = int(cl_raw)
            except ValueError:
                self._json(400, {"ok": False, "sync_completed": False, "error": "bad_request"})
                return
            if cl > MAX_BODY:
                self._json(413, {"ok": False, "sync_completed": False, "error": "payload_too_large"})
                return
            raw = self.rfile.read(cl)
            if len(raw) != cl:
                self._json(400, {"ok": False, "sync_completed": False, "error": "short_read"})
                return
            if not github_sig_ok(gh_secret, raw, sig):
                self._json(401, {"ok": False, "sync_completed": False, "error": "unauthorized"})
                return
            ev = event.casefold()
            if ev == "ping":
                self._json(200, {"ok": True, "sync_completed": False, "skipped": "github_ping"})
                return
            if ev != "push":
                self._json(200, {"ok": True, "sync_completed": False, "skipped": "github_event"})
                return
            try:
                payload = json.loads(raw.decode("utf-8") or "{}")
            except (UnicodeDecodeError, json.JSONDecodeError):
                self._json(400, {"ok": False, "sync_completed": False, "error": "json"})
                return
            if not isinstance(payload, dict):
                payload = {}
            if payload.get("ref") != GITHUB_PUSH_REF:
                self._json(200, {"ok": True, "sync_completed": False, "skipped": "wrong_ref"})
                return
            repo = payload.get("repository") or {}
            full_name = repo.get("full_name") if isinstance(repo, dict) else None
            full_s = full_name.strip() if isinstance(full_name, str) else ""
            vault = find_vault_for_repo(full_s)
            if not vault:
                self._json(200, {"ok": True, "sync_completed": False, "skipped": "no_vault_for_repo"})
                return
            self._respond_after_sync(self._run_sync(vault))

        def do_POST(self) -> None:  # noqa: N802 — stdlib
            path = urlparse(self.path).path.rstrip("/").casefold() or "/"
            if path.startswith("/sync/"):
                self._sync_endpoint()
                return
            if path == "/hooks/github":
                self._github_endpoint()
                return
            self.send_response(404)
            self.end_headers()

        def do_GET(self) -> None:  # noqa: N802
            slug = urlparse(self.path).path.strip("/").casefold()
            if slug in {"", "health", "healthz"}:
                cap: dict[str, object] = {"ok": True}
                if bearer_secret:
                    cap["agent_sync"] = True
                if gh_secret:
                    cap["github_push_webhook"] = True
                self._json(200, cap)
                return
            self.send_response(404)
            self.end_headers()

    httpd = ThreadingHTTPServer((LISTEN_BIND, LISTEN_PORT), Handler)
    modes = []
    if bearer_secret:
        modes.append("POST /sync/<vault>")
    if gh_secret:
        modes.append("POST /hooks/github")
    print(
        f"listening http://{LISTEN_BIND}:{LISTEN_PORT} — {'; '.join(modes)}",
        file=sys.stderr,
    )
    httpd.serve_forever()


if __name__ == "__main__":
    main()
