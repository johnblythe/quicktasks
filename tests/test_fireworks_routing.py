#!/usr/bin/env python3
"""Fireworks provider routing for quick-fires.

Config opt-in: {"provider": "fireworks", "model": "glm-5p3"}. A headless
claude run then gets the Fireworks overlay (ANTHROPIC_BASE_URL +
ANTHROPIC_AUTH_TOKEN, ANTHROPIC_API_KEY cleared, slot models mapped), its
short model name expands to the accounts/fireworks resource spelling, and
the per-run --settings file denies WebSearch (Fireworks rejects Anthropic's
server-side web_search outright). A model that is an Anthropic reference
(`-m sonnet[1m]`) keeps the ambient login -- no overlay, no expansion --
so the per-fire model choice can cross providers. The key comes from
FIREWORKS_API_KEY, or from the ~/.secrets.zsh line that sets it, because a
quick-fire fired from the menu bar runs under launchd and never sees zshrc.

End-to-end tests drive the real `qt` as a subprocess against a throwaway
QT_DATA with HOME pointed at a throwaway home (the secrets fallback is part
of what's under test) and a fake `claude` on PATH that logs argv and the
routing-relevant env. Nothing here reads the real ~/.quicktasks,
~/.secrets.zsh, or any live hub, and no real claude is ever started.
live_guard is imported first so the environment is fenced.
"""
import live_guard  # noqa: F401  # FIRST: sandboxes QT_DATA, clears QT_HUB, QT_NOTIFY_INBOX=0

import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"
TMP_ROOT = REPO_ROOT / "tmp"

FAKE_KEY = "fw_test_key_0123456789"

# Fake claude: logs argv (FAKE_CLAUDE_ARGV) and, separately, the
# routing-relevant slice of its own environment (FAKE_CLAUDE_ENV_LOG) --
# what qt actually handed the run -- then emits a plain json result.
FAKE_CLUDE = """#!/usr/bin/env python3
import json, os, sys
argv_log = os.environ.get("FAKE_CLAUDE_ARGV")
if argv_log:
    with open(argv_log, "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\\n")
env_log = os.environ.get("FAKE_CLAUDE_ENV_LOG")
if env_log:
    keys = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
            "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL"]
    entry = {k: os.environ.get(k) for k in keys}
    # The per-run --settings file is removed once the run finishes, so the
    # only moment its contents can be observed is right here, mid-run.
    argv = sys.argv[1:]
    if "--settings" in argv:
        try:
            with open(argv[argv.index("--settings") + 1]) as sf:
                entry["_settings"] = json.load(sf)
        except (OSError, ValueError):
            entry["_settings"] = None
    with open(env_log, "a") as f:
        f.write(json.dumps(entry) + "\\n")
result = json.loads(os.environ.get(
    "FAKE_CLAUDE_RESULT", json.dumps({"result": "done", "session_id": "sess-1"})))
sys.stdout.write(json.dumps(result) + "\\n")
sys.exit(int(os.environ.get("FAKE_CLAUDE_RC", "0")))
"""

NOOP_SHIM = """#!/usr/bin/env python3
import sys
sys.exit(0)
"""

WATCH_KEYS = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
              "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
              "ANTHROPIC_DEFAULT_HAIKU_MODEL"]


def _load_qt_module(name="qt_under_test_fw"):
    loader = importlib.machinery.SourceFileLoader(name, str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def _exe(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class RoutingBase(unittest.TestCase):
    """Throwaway QT_DATA *and home*, fake claude + notifier shims on PATH."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.qt_data = root / "qtdata"
        self.bin_dir = root / "bin"
        for d in (self.home, self.qt_data / "tasks", self.bin_dir):
            d.mkdir(parents=True)
        _exe(self.bin_dir / "claude", FAKE_CLUDE)
        for name in ("osascript", "terminal-notifier"):
            _exe(self.bin_dir / name, NOOP_SHIM)
        self.argv_log = root / "claude-argv.log"
        self.env_log = root / "claude-env.log"
        self.env = dict(os.environ)
        self.env.update({
            "QT_DATA": str(self.qt_data),
            "PATH": f"{self.bin_dir}:{os.environ.get('PATH', '')}",
            "QT_NOTIFY_INBOX": "0",
            "QT_LABEL_REFINE": "0",
            "FAKE_CLAUDE_ARGV": str(self.argv_log),
            "FAKE_CLAUDE_ENV_LOG": str(self.env_log),
            "HOME": str(self.home),
            "CLAUDE_CONFIG_DIR": str(root / "claude-config"),
        })
        for k in ("QT_HUB", "QT_PERMISSIONS", "QT_ORIGIN", "QT_PASS_URL",
                  "QT_TIMEOUT", "QT_ALLOW_FILE", "FIREWORKS_API_KEY",
                  "FIREWORKS_OPUS_MODEL", "FIREWORKS_SONNET_MODEL",
                  "FIREWORKS_HAIKU_MODEL", "ANTHROPIC_API_KEY",
                  "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"):
            self.env.pop(k, None)

    # -- helpers --
    def qt(self, *args, env=None):
        e = dict(self.env)
        e.update(env or {})
        return subprocess.run([sys.executable, str(QT_SCRIPT), *args],
                              capture_output=True, text=True, env=e, timeout=60)

    def write_config(self, **cfg):
        (self.qt_data / "config.json").write_text(json.dumps(cfg))

    def write_secrets(self, key=FAKE_KEY):
        (self.home / ".secrets.zsh").write_text(
            f"# secrets\nexport FIREWORKS_API_KEY='{key}'\n")

    def wait_done(self, timeout=15.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            files = list((self.qt_data / "tasks").glob("*.json"))
            if files:
                rec = json.loads(files[0].read_text())
                if rec.get("status") in ("done", "failed", "blocked", "question"):
                    return rec
            time.sleep(0.05)
        self.fail("task never finished")

    def runs(self):
        """One (argv, env) pair per claude invocation, in order."""
        argvs = [json.loads(l) for l in self.argv_log.read_text().splitlines() if l.strip()]
        envs = [json.loads(l) for l in self.env_log.read_text().splitlines() if l.strip()]
        self.assertEqual(len(argvs), len(envs))
        return list(zip(argvs, envs))

    def settings_path_from(self, argv):
        i = argv.index("--settings")
        return Path(argv[i + 1])


class TestFireworksRouting(RoutingBase):
    """Config provider=fireworks: the overlay, the expansion, the deny."""

    def setUp(self):
        super().setUp()
        self.write_secrets()
        self.write_config(provider="fireworks", model="glm-5p3")

    def test_run_routes_and_expands_the_model(self):
        proc = self.qt("route me a haiku about latency")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = self.wait_done()
        self.assertEqual(rec["status"], "done")
        (argv, env), = self.runs()
        self.assertIn("--model", argv)
        self.assertEqual(argv[argv.index("--model") + 1],
                         "accounts/fireworks/models/glm-5p3")
        self.assertEqual(env["ANTHROPIC_BASE_URL"],
                         "https://api.fireworks.ai/inference")
        self.assertEqual(env["ANTHROPIC_AUTH_TOKEN"], FAKE_KEY)
        self.assertIsNone(env["ANTHROPIC_API_KEY"])  # cleared, login gate stays sane
        self.assertEqual(env["ANTHROPIC_MODEL"],
                         "accounts/fireworks/models/glm-5p3")
        self.assertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"],
                         "accounts/fireworks/models/glm-5p3-flash")

    def test_settings_deny_websearch_without_a_hub_guard(self):
        # No hub configured, so the standalone qt-guard.py is the guard;
        # the per-run settings file exists either way -- what the provider
        # adds is the deny, observed mid-run (the file is removed after).
        proc = self.qt("deny check")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.wait_done()
        (argv, env), = self.runs()
        self.assertIn("--settings", argv)
        self.assertIn("WebSearch", env["_settings"]["permissions"]["deny"])

    def test_anthropic_model_reference_keeps_the_ambient_login(self):
        proc = self.qt("-m", "sonnet[1m]", "stay on anthropic for this one")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.wait_done()
        (argv, env), = self.runs()
        self.assertEqual(argv[argv.index("--model") + 1], "sonnet[1m]")
        self.assertIsNone(env["ANTHROPIC_BASE_URL"])
        self.assertIsNone(env["ANTHROPIC_AUTH_TOKEN"])

    def test_short_model_names_expand_router_and_bare_forms(self):
        for short, full in (("glm-5p3", "accounts/fireworks/models/glm-5p3"),
                            ("routers/kimi-k3-fast", "accounts/fireworks/routers/kimi-k3-fast"),
                            ("accounts/fireworks/models/glm-5p3-flash",
                             "accounts/fireworks/models/glm-5p3-flash")):
            self.qt_data.joinpath("tasks").glob  # tasks dir reused below
            for f in (self.qt_data / "tasks").glob("*.json"):
                f.unlink()
            self.argv_log.unlink(missing_ok=True)
            self.env_log.unlink(missing_ok=True)
            proc = self.qt("-m", short, f"expand {short}")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.wait_done()
            (argv, _), = self.runs()
            self.assertEqual(argv[argv.index("--model") + 1], full)

    def test_env_key_beats_the_secrets_file(self):
        proc = self.qt("key precedence", env={"FIREWORKS_API_KEY": "fw_from_env"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.wait_done()
        (_, env), = self.runs()
        self.assertEqual(env["ANTHROPIC_AUTH_TOKEN"], "fw_from_env")


class TestNoProvider(RoutingBase):
    """No provider in config: byte-compatible with yesterday."""

    def setUp(self):
        super().setUp()
        self.write_secrets()
        self.write_config(model="glm-5p3")

    def test_no_overlay_and_no_expansion_without_the_opt_in(self):
        proc = self.qt("plain old anthropic fire")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.wait_done()
        (argv, env), = self.runs()
        self.assertEqual(argv[argv.index("--model") + 1], "glm-5p3")  # raw, unexpanded
        self.assertIsNone(env["ANTHROPIC_BASE_URL"])
        self.assertIsNone(env["ANTHROPIC_AUTH_TOKEN"])

    def test_no_deny_without_the_provider_opt_in(self):
        proc = self.qt("no deny wanted")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.wait_done()
        (argv, env), = self.runs()
        # The standalone guard's settings file still exists (it always
        # does in this checkout) -- but no WebSearch deny without the
        # provider, and no overlay.
        self.assertIn("--settings", argv)
        deny = (env["_settings"] or {}).get("permissions", {}).get("deny")
        self.assertNotIn("WebSearch", deny or [])
        self.assertIsNone(env["ANTHROPIC_BASE_URL"])


class TestMissingKey(RoutingBase):
    """Provider configured but no key anywhere: fall back to the ambient
    login rather than refusing -- the run works or fails on Anthropic's
    own terms, and doctor/setup say where the key should go."""

    def setUp(self):
        super().setUp()
        self.write_config(provider="fireworks", model="glm-5p3")
        # no FIREWORKS_API_KEY in env (popped in setUp), no .secrets.zsh

    def test_no_key_means_no_overlay(self):
        proc = self.qt("keyless fire")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.wait_done()
        (argv, env), = self.runs()
        self.assertIsNone(env["ANTHROPIC_BASE_URL"])
        self.assertEqual(argv[argv.index("--model") + 1], "glm-5p3")  # unexpanded


class TestHelpers(unittest.TestCase):
    """The pure pieces, loaded as a module."""

    @classmethod
    def setUpClass(cls):
        cls.qt = _load_qt_module()

    def test_expansion(self):
        fw = self.qt.fireworks_model
        self.assertEqual(fw("glm-5p3"), "accounts/fireworks/models/glm-5p3")
        self.assertEqual(fw("routers/kimi-k3-fast"),
                         "accounts/fireworks/routers/kimi-k3-fast")
        self.assertEqual(fw("accounts/fireworks/models/x"),
                         "accounts/fireworks/models/x")
        self.assertEqual(fw(""), "accounts/fireworks/models/glm-5p3")
        self.assertEqual(fw(None), "accounts/fireworks/models/glm-5p3")

    def test_anthropic_detection(self):
        is_a = self.qt._is_anthropic_model
        for name in ("sonnet[1m]", "opus", "claude-opus-5-5", "Sonnet"):
            self.assertTrue(is_a(name), name)
        for name in ("glm-5p3", "haiku", "kimi-k3", "accounts/fireworks/models/x", ""):
            self.assertFalse(is_a(name), name)

    def test_secrets_file_parse(self):
        with tempfile.TemporaryDirectory(dir=str(TMP_ROOT)) as td:
            home = Path(td)
            (home / ".secrets.zsh").write_text(
                "# noise\n"
                "export OTHER_KEY='nope'\n"
                "export FIREWORKS_API_KEY=\"fw_parsed_key\"\n"
                "FIREWORKS_API_KEY=second_match_ignored\n")
            env = {k: v for k, v in os.environ.items()
                   if k != "FIREWORKS_API_KEY"}
            env["HOME"] = str(home)
            # reload so module-level state can't leak; the helpers read
            # the env at call time
            proc = subprocess.run(
                [sys.executable, "-c",
                 "import importlib.machinery, importlib.util, json, sys\n"
                 "loader = importlib.machinery.SourceFileLoader('qtw', sys.argv[1])\n"
                 "spec = importlib.util.spec_from_loader(loader.name, loader)\n"
                 "mod = importlib.util.module_from_spec(spec)\n"
                 "loader.exec_module(mod)\n"
                 "print(json.dumps(mod._fireworks_key()))",
                 str(QT_SCRIPT)],
                capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(proc.stdout), "fw_parsed_key")


if __name__ == "__main__":
    unittest.main(verbosity=1)
