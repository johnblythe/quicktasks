"""Shared fixtures for the ask-feed tests (Q2, contract section 1).

`AskFixturePass` is a real loopback HTTP server standing in for the hub's ask
API: GET /asks.json (with since_rev), GET /asks/<id>.json, GET /status.json,
and POST /asks/<id>/<move>, recording every request. Real rather than mocked
for the reason test_menubar_model.FixturePass gives: the widget's Pass path is
a URLSession round trip.

`build_once()` builds the widget exactly once per process through the same
build script test_menubar_model uses (`menubar/build.sh --no-install`, swiftc
only, never installs or launches) and returns the binary path or the reason it
could not be built. Tests drive the exit-before-UI seams only
(`--dump-model --ask-dump-model`, `--ask-dump-thread`, `--ask-post`).

Nothing here touches ~/.quicktasks, the notify inbox, or any live hub file:
every test points QT_DATA / QT_HUB at a temp dir and QT_PASS_URL at a fixture.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import test_menubar_model as tmm  # the shared builder and /status.json fixtures

REPO_ROOT = tmm.REPO_ROOT
BINARY = tmm.BINARY
BUILD_SCRIPT = tmm.BUILD_SCRIPT
status_fixture = tmm.status_fixture
job = tmm.job

# Nothing listens here; used for "the Pass is configured but does not answer".
DEAD_URL = "http://127.0.0.1:2"

_built = False
_build_error = None


def build_once():
    """Returns (binary_path, error). error is None when the binary is usable."""
    global _built, _build_error
    if _built:
        return BINARY, _build_error
    _built = True
    if sys.platform != "darwin":
        _build_error = "macOS only"
    elif shutil.which("swiftc") is None:
        _build_error = "swiftc not on PATH (xcode-select --install)"
    else:
        proc = subprocess.run(["bash", str(BUILD_SCRIPT), "--no-install"],
                              capture_output=True, text=True, timeout=300)
        if proc.returncode != 0 or not BINARY.is_file():
            _build_error = f"build failed: {proc.stdout}\n{proc.stderr}"
    return BINARY, _build_error


# --- contract fixtures ------------------------------------------------------

PLACE_OF = {
    "heard": "working", "working": "working",
    "wants_ok": "needs", "question": "needs", "blocked": "needs",
    "failed": "needs", "answer": "needs",
    "done": "done", "yours": "yours",
}

MOVES_OF = {
    "heard": ["undo", "edit"],
    "wants_ok": ["run", "edit_and_run", "mine", "drop"],
    "working": ["stop", "note"],
    "question": ["follow_up", "stop", "mine", "drop"],
    "blocked": ["allow_once", "allow_always", "skip", "follow_up", "stop"],
    "failed": ["retry_with_changes", "retry", "mine", "drop"],
    "answer": ["follow_up", "retry", "retry_with_changes", "copy", "done"],
    "done": ["reopen", "follow_up", "retry"],
    "yours": ["done", "remind", "run", "drop"],
}


def ask_row(ask_id="qt-261117-094512-who-owns-the", state="answer", **over):
    """One /asks.json row with the full section 1.4 key set."""
    row = {
        "v": 1,
        "id": ask_id,
        "kind": "agent",
        "title": "Billing contact for the GitHub renewal",
        "words": "who owns the billing contact for our GitHub renewal",
        "state": state,
        "place": PLACE_OF.get(state, "needs"),
        "unseen": state == "answer",
        "suggested": False,
        "door": "typed",
        "ledger": "qt",
        "ref": ask_id[3:] if ask_id.startswith("qt-") else ask_id,
        "item_id": ask_id,
        "created_at": "2026-11-17T09:45:12-05:00",
        "updated_at": "2026-11-17T09:48:16-05:00",
        "finished_at": "2026-11-17T09:48:16-05:00",
        "now_line": None,
        "reason": None,
        "question": None,
        "blocked_tools": [],
        "answer_excerpt": "Procurement owns it, through the vendor-renewals alias.",
        "facts": {"elapsed_s": 184, "cost_usd": 0.41, "model": "sonnet",
                  "run_dir": "~/code/management", "runs": 1,
                  "session_id": "sess-1", "tools_used": ["Slack", "Drive"]},
        "moves": MOVES_OF.get(state, []),
        "can_run": False,
        "remind_at": None,
        "filed": None,
        "url": f"http://127.0.0.1:8811/ask/{ask_id}",
    }
    row.update(over)
    return row


def thread_payload(row=None, **over):
    """GET /asks/<id>.json: the row plus the section 1.5 extras."""
    payload = dict(row or ask_row())
    payload.update({
        "answer_text": "Procurement owns it, through the vendor-renewals alias.\n\nRenewal is Jan 14.",
        "answer_truncated": False,
        "timeline": [{"at": "2026-11-17T09:45:12-05:00", "text": "heard"},
                     {"at": "2026-11-17T09:45:14-05:00", "text": "started"},
                     {"at": "2026-11-17T09:48:16-05:00", "text": "finished"}],
        "runs": [{"n": 1, "kind": "first", "prompt": "who owns the billing contact",
                  "status": "done", "started": "2026-11-17T09:45:14-05:00",
                  "finished": "2026-11-17T09:48:16-05:00",
                  "result_text": "Procurement owns it.", "result_truncated": False,
                  "files": [{"name": "summary.md",
                             "url": "/job/qt-x/output/summary.md"}],
                  "cost_usd": 0.41, "model": "sonnet", "session_id": "sess-1",
                  "events": []}],
    })
    payload.update(over)
    return payload


def counts_for(rows):
    rows = [r for r in rows if isinstance(r, dict)]
    needs = [r for r in rows if r.get("place") == "needs"]
    return {
        "badge": len([r for r in needs if not (r.get("state") == "answer" and not r.get("unseen"))]),
        "needs": len(needs),
        "working": len([r for r in rows if r.get("place") == "working"]),
        "done": len([r for r in rows if r.get("place") == "done"]),
        "yours": len([r for r in rows if r.get("place") == "yours"]),
        "unseen": len([r for r in rows if r.get("unseen")]),
    }


# --- the fixture hub --------------------------------------------------------

class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        owner = self.owner
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        owner.gets.append({"path": url.path, "query": query, "raw": self.path})
        if url.path == "/asks.json":
            if owner.list_code != 200:
                return self._send(owner.list_code, owner.list_body or b"not found", "text/plain")
            if owner.list_raw is not None:
                return self._send(200, owner.list_raw)
            if query.get("since_rev") and query["since_rev"] == str(owner.rev):
                return self._send(200, {"unchanged": True, "rev": owner.rev})
            return self._send(200, {"v": 1, "rev": owner.rev,
                                    "generated_at": "2026-11-17T09:50:00-05:00",
                                    "counts": owner.counts or counts_for(owner.asks),
                                    "asks": owner.asks})
        if url.path.startswith("/asks/") and url.path.endswith(".json"):
            ask_id = url.path[len("/asks/"):-len(".json")]
            if ask_id in owner.threads:
                return self._send(200, owner.threads[ask_id])
            return self._send(404, b"unknown ask", "text/plain")
        if url.path == "/status.json":
            if owner.status_payload is None:
                return self._send(404, b"not found", "text/plain")
            return self._send(200, owner.status_payload)
        return self._send(404, b"not found", "text/plain")

    def do_POST(self):
        owner = self.owner
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = None
        parts = urlparse(self.path).path.strip("/").split("/")
        move = parts[2] if len(parts) == 3 and parts[0] == "asks" else None
        ask_id = parts[1] if move else None
        owner.posts.append({"path": self.path, "id": ask_id, "move": move,
                            "body": body, "content_type": self.headers.get("Content-Type")})
        code, reply = owner.post_replies.get(move, (200, None))
        if reply is None:
            reply = {"ok": True, "ask": ask_row(ask_id or "x", state="done"),
                     "undo": {"token": "tok-1", "expires_at": "2026-11-17T10:00:00-05:00"},
                     "message": f"{move} done"}
        if isinstance(reply, str):
            return self._send(code, reply.encode(), "text/plain")
        return self._send(code, reply)


class AskFixturePass:
    """The hub's ask API on an ephemeral loopback port.

    asks / threads / rev / counts feed GET /asks.json and /asks/<id>.json;
    list_code != 200 makes /asks.json answer that status (404 = a hub that
    predates the ask API); status_payload feeds /status.json (None = 404);
    post_replies maps a move to (http_code, body-or-text).
    """

    def __init__(self, asks=None, threads=None, rev="rev-1", counts=None,
                 list_code=200, list_body=None, list_raw=None,
                 status_payload=None, post_replies=None):
        self.asks = list(asks or [])
        self.threads = dict(threads or {})
        self.rev = rev
        self.counts = counts
        self.list_code = list_code
        self.list_body = list_body
        self.list_raw = list_raw
        self.status_payload = status_payload
        self.post_replies = dict(post_replies or {})
        self.gets = []
        self.posts = []
        self._srv = None

    def gets_to(self, path):
        return [g for g in self.gets if g["path"] == path]

    def start(self):
        handler = type("H", (_Handler,), {"owner": self})
        self._srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()
        return f"http://127.0.0.1:{self._srv.server_address[1]}"

    def stop(self):
        if self._srv is not None:
            self._srv.shutdown()
            self._srv.server_close()
            self._srv = None


# --- test base --------------------------------------------------------------

class AskCase(unittest.TestCase):
    """Temp QT_DATA / QT_HUB, a way to run the ask seams, a way to start a
    fixture hub. QT_PASS_URL is always set explicitly so the real Pass on 8811
    can never answer."""

    def setUp(self):
        _, error = build_once()
        if error:
            self.skipTest(error)
        tmp_root = REPO_ROOT / "tmp"
        self.tmp = Path(tempfile.mkdtemp(prefix="asks-", dir=tmp_root if tmp_root.is_dir() else None))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.qt_data = self.tmp / "qtdata"
        self.hub = self.tmp / "hub"
        (self.qt_data / "tasks").mkdir(parents=True)
        (self.hub / "jobs").mkdir(parents=True)

    def serve(self, **kwargs):
        server = AskFixturePass(**kwargs)
        base = server.start()
        self.addCleanup(server.stop)
        self.server = server
        return base

    def write_task(self, tid, **fields):
        """One record in qt's ledger, <qt_data>/tasks/<id>.json."""
        rec = {
            "id": tid,
            "prompt": fields.pop("prompt", f"prompt for {tid}"),
            "status": fields.pop("status", "done"),
            "created": fields.pop("created", "2026-11-17T09:45:12"),
            "origin": fields.pop("origin", "qt"),
            "invoked_from": "/tmp",
            "session_id": fields.pop("session_id", "sess-" + tid),
            "denials": fields.pop("denials", []),
        }
        rec.update(fields)
        (self.qt_data / "tasks" / f"{tid}.json").write_text(json.dumps(rec))

    def env(self, pass_url, extra=None):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["QT_HUB"] = str(self.hub)
        env["QT_PASS_URL"] = pass_url
        env["QT_MENUBAR_AGENT_PLIST"] = str(self.tmp / "agents" / "never-written.plist")
        env["QT_MENUBAR_DEFAULTS_SUITE"] = "com.quicktasks.menubar.testasks"
        env["QT_NOTIFY_INBOX"] = "0"
        env.update(extra or {})
        return env

    def seam(self, *args, pass_url="", expect=0, extra_env=None):
        """Runs `QuicktaskStatus --dump-model <args>` and returns the parsed
        JSON. `--dump-model` is the flag Entry dispatches on; DumpModel hands
        the `--ask-*` arguments to AskSeams."""
        proc = subprocess.run([str(BINARY), "--dump-model", *args],
                              capture_output=True, text=True, timeout=60,
                              env=self.env(pass_url, extra_env))
        self.assertEqual(proc.returncode, expect,
                         f"{args} exited {proc.returncode}: {proc.stderr}\n{proc.stdout}")
        return json.loads(proc.stdout) if proc.stdout.strip() else None

    def ask_model(self, pass_url="", *extra):
        return self.seam("--ask-dump-model", *extra, pass_url=pass_url)

    @staticmethod
    def by_id(model, ask_id):
        for row in model["asks"]:
            if row["id"] == ask_id:
                return row
        raise AssertionError(f"{ask_id} not in {[r['id'] for r in model['asks']]}")
