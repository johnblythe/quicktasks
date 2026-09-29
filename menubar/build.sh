#!/bin/bash
# Builds Quicktask.app from the Swift sources in this directory.
#
# Needs only the Command Line Tools (swiftc + codesign); no Xcode project, no
# SwiftPM manifest, no signing identity. Follows the same shape as qt's own
# install-handler: assemble a bundle, write Info.plist, ad-hoc sign, install.
#
#   ./build.sh              build into ./build and install to /Applications
#   ./build.sh --no-install build into ./build only
#   ./build.sh --run        build, install, and launch it
#   ./build.sh --agent      build, install, and start it at every login
#
# The executable inside the bundle keeps the name QuicktaskStatus -- CLI
# seams, tests, and the login-agent plist all reference that path -- only the
# Finder-facing bundle and display name changed to Quicktask. The install
# target is $QT_APP_DIR (default /Applications), which is separate from
# $QT_DATA (default ~/.quicktasks): that stays the data dir -- tasks, logs,
# config, QuicktaskResume.app -- and no longer holds the app bundle itself.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SELF_DIR/build"
BUNDLE_NAME="Quicktask"
EXEC_NAME="QuicktaskStatus"
BUNDLE_ID="com.quicktasks.menubar"
DATA_DIR="${QT_DATA:-$HOME/.quicktasks}"
APP_DIR="${QT_APP_DIR:-/Applications}"
MIN_MACOS="14.0"

INSTALL=1
RUN=0
AGENT=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --run) RUN=1 ;;
    --agent) AGENT=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

command -v swiftc >/dev/null || {
  echo "swiftc not found. Install the Command Line Tools: xcode-select --install" >&2
  exit 1
}

# Polls for a process matching `pattern` to actually exit, up to ~5s, rather
# than treating a `pkill` above as instantaneous. Without this, the new
# single-instance guard the freshly installed binary runs on launch
# (App.swift's SingleInstanceGuard) could see the old copy still dying,
# conclude a live instance beat it to the punch, and quit -- instead of this
# script going on to bootstrap or open the copy it just installed.
wait_for_exit() {
  local pattern="$1" waited=0
  while pgrep -f "$pattern" >/dev/null 2>&1 && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
}

ARCH="$(uname -m)"
APP="$BUILD_DIR/$BUNDLE_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling ($ARCH, macOS $MIN_MACOS+)..."
# -parse-as-library because the entry point is @main on Entry, not top-level
# code in a main.swift.
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macosx${MIN_MACOS}" \
  -o "$APP/Contents/MacOS/$EXEC_NAME" \
  "$SELF_DIR"/Sources/*.swift

# The LaunchAgent template ships inside the bundle so the dropdown's
# "Start at login" toggle writes the same plist this script does, from the same
# source, rather than keeping a second copy of it in Swift.
cp "$SELF_DIR/com.quicktasks.menubar.plist" "$APP/Contents/Resources/"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$BUNDLE_NAME</string>
  <key>CFBundleDisplayName</key><string>$BUNDLE_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <!-- Menu-bar only: no Dock icon, no app switcher entry, no focus steal. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The plist is written after linking, so sign last. Ad-hoc is enough for a
# locally built bundle; without it macOS refuses to launch on Apple silicon.
codesign --force --sign - "$APP" >/dev/null 2>&1 || {
  echo "codesign failed; macOS may refuse to launch the app" >&2
}

echo "built: $APP"

if [ "$INSTALL" -eq 1 ]; then
  mkdir -p "$APP_DIR"
  TARGET="$APP_DIR/$BUNDLE_NAME.app"
  # Quit a running copy first, or the replace races the live binary, and wait
  # for it to actually be gone -- see wait_for_exit's own doc comment.
  pkill -f "$TARGET/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true
  wait_for_exit "$TARGET/Contents/MacOS/$EXEC_NAME"
  rm -rf "$TARGET"
  cp -R "$APP" "$TARGET"
  echo "installed: $TARGET"

  # A pre-/Applications install left the bundle inside $QT_DATA. If it's
  # still there, kill it and remove it too, so a stale copy under the old
  # path can never be what a login or a leftover Login Items entry starts.
  LEGACY="$DATA_DIR/$EXEC_NAME.app"
  if [ -e "$LEGACY" ]; then
    pkill -f "$LEGACY/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true
    wait_for_exit "$LEGACY/Contents/MacOS/$EXEC_NAME"
    rm -rf "$LEGACY"
    echo "removed legacy install: $LEGACY"
  fi

  AGENT_DIR="$HOME/Library/LaunchAgents"
  AGENT_PLIST="$AGENT_DIR/com.quicktasks.menubar.plist"
  AGENT_LABEL="gui/$(id -u)/com.quicktasks.menubar"
  # Re-render a plist that already exists too, not only on --agent: it names
  # the executable by path, and one written before the move to /Applications
  # still points at the legacy copy removed above, so login would start
  # nothing.
  if [ "$AGENT" -eq 1 ] || [ -f "$AGENT_PLIST" ]; then
    mkdir -p "$AGENT_DIR"
    # Substitute the real executable path into the template rather than
    # committing one person's home directory to the repo.
    sed "s|__EXECUTABLE__|$TARGET/Contents/MacOS/$EXEC_NAME|" \
      "$SELF_DIR/com.quicktasks.menubar.plist" >"$AGENT_PLIST"
    echo "login agent: $AGENT_PLIST"
  fi
  # A job still loaded with no plist behind it is what the Start at login
  # switch leaves when turned off mid-session; bootstrapping a missing file
  # would fail, so that case launches like a machine without the agent.
  if [ "$AGENT" -eq 1 ] || { [ -f "$AGENT_PLIST" ] && launchctl print "$AGENT_LABEL" >/dev/null 2>&1; }; then
    # The login agent owns the running copy, and the pkill above just took it
    # down (KeepAlive is deliberately off, so nothing brings it back on its
    # own). Restart through launchd. A bare `open` here would start a second,
    # unmanaged instance next to the agent's: two dots in the menu bar, which
    # is exactly what --run used to do on a machine with the agent loaded.
    # bootout + bootstrap rather than `kickstart -k`: after the bundle on
    # disk has been replaced, kickstart relaunches under the agent's old
    # registration and macOS kills the new binary with a code-signing
    # "Launch Constraint Violation" (SIGKILL, seen 2026-09-15). Re-registering
    # the plist makes launchd pick up the new bundle cleanly. Exactly one
    # bootout + bootstrap: a second pair right behind it would launch a copy,
    # kill it, and launch again, and that relaunch can see the first copy
    # still dying and quit on SingleInstanceGuard, leaving no widget at all.
    launchctl bootout "$AGENT_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
    echo "restarted through the login agent ($AGENT_LABEL)."
    if [ "$AGENT" -eq 1 ]; then
      echo "starts at every login · remove with:"
      echo "  launchctl bootout $AGENT_LABEL && rm \"$AGENT_PLIST\""
    fi
  elif [ "$RUN" -eq 1 ]; then
    open "$TARGET"
    echo "launched. Look for the status dot in the menu bar."
  else
    echo "launch with: open \"$TARGET\""
  fi
fi
