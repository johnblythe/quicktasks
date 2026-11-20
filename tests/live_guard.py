"""Live-data guard for the quicktasks test suite.

Import this FIRST in any test module (before loading `qt`, which reads its
paths from the environment at import time):

    import live_guard  # noqa: F401  (tests/ is on sys.path under discover)

On import it
  * points QT_DATA at a fresh temp dir (removed at exit),
  * clears QT_HUB so no hub is configured,
  * disables the menu bar notify inbox and label refinement,
  * snapshots the mtimes of John's live qt data and the installed app
    (stat only, never reads contents), and
  * registers an atexit check that the snapshot is unchanged. On a change it
    prints what moved and forces exit status 1.

A real qt task or the live menu bar writing to ~/.quicktasks while a suite
runs will trip the check; rerun when the machine is quiet.
"""
import atexit
import os
import shutil
import sys
import tempfile

_HOME = os.path.expanduser("~")
LIVE_PATHS = [
    os.path.join(_HOME, ".quicktasks", "tasks"),
    os.path.join(_HOME, ".quicktasks", "notify-inbox"),
    os.path.join(_HOME, ".quicktasks", "config.json"),
    "/Applications/Quicktask.app",
]


def _stat_tree(path):
    """(exists, entry count, newest mtime_ns) for path and everything under it."""
    try:
        st = os.lstat(path)
    except OSError:
        return (False, 0, 0)
    count, newest = 1, st.st_mtime_ns
    if os.path.isdir(path) and not os.path.islink(path):
        for root, dirs, files in os.walk(path):
            for name in dirs + files:
                try:
                    s = os.lstat(os.path.join(root, name))
                except OSError:
                    continue
                count += 1
                newest = max(newest, s.st_mtime_ns)
            try:
                newest = max(newest, os.lstat(root).st_mtime_ns)
            except OSError:
                pass
    return (True, count, newest)


def snapshot():
    return {p: _stat_tree(p) for p in LIVE_PATHS}


_BASELINE = snapshot()


def assert_untouched():
    """Raise AssertionError if any live path changed since import."""
    now = snapshot()
    changed = [p for p in LIVE_PATHS if now[p] != _BASELINE[p]]
    if changed:
        raise AssertionError(
            "tests touched live data: " + ", ".join(changed))


def _check_at_exit():
    try:
        assert_untouched()
    except AssertionError as e:
        sys.stderr.write("live_guard: %s\n" % e)
        sys.stderr.flush()
        os._exit(1)


# Registered first so it runs last (atexit is LIFO), after temp cleanup.
atexit.register(_check_at_exit)

TMP_QT_DATA = tempfile.mkdtemp(prefix="qt-test-data-")
atexit.register(shutil.rmtree, TMP_QT_DATA, True)

os.environ["QT_DATA"] = TMP_QT_DATA
os.environ["QT_HUB"] = ""
os.environ["QT_NOTIFY_INBOX"] = "0"
os.environ["QT_LABEL_REFINE"] = "0"
