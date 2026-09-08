#!/bin/bash
# Builds QuicktaskStatus.app from the Swift sources in this directory.
#
# Needs only the Command Line Tools (swiftc + codesign); no Xcode project, no
# SwiftPM manifest, no signing identity. Follows the same shape as qt's own
# install-handler: assemble a bundle, write Info.plist, ad-hoc sign, install.
#
#   ./build.sh              build into ./build and install to ~/.quicktasks
#   ./build.sh --no-install build into ./build only
#   ./build.sh --run        build, install, and launch it
#   ./build.sh --agent      build, install, and start it at every login
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SELF_DIR/build"
APP_NAME="QuicktaskStatus"
BUNDLE_ID="com.quicktasks.menubar"
DEST_DIR="${QT_DATA:-$HOME/.quicktasks}"
MIN_MACOS="14.0"

INSTALL=1
RUN=0
AGENT=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --run) RUN=1 ;;
    --agent) AGENT=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

command -v swiftc >/dev/null || {
  echo "swiftc not found. Install the Command Line Tools: xcode-select --install" >&2
  exit 1
}

ARCH="$(uname -m)"
APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling ($ARCH, macOS $MIN_MACOS+)..."
# -parse-as-library because the entry point is @main on Entry, not top-level
# code in a main.swift.
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macosx${MIN_MACOS}" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
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
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Quicktask Status</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
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
  mkdir -p "$DEST_DIR"
  TARGET="$DEST_DIR/$APP_NAME.app"
  # Quit a running copy first, or the replace races the live binary.
  pkill -f "$TARGET/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  rm -rf "$TARGET"
  cp -R "$APP" "$TARGET"
  echo "installed: $TARGET"
  if [ "$AGENT" -eq 1 ]; then
    AGENT_DIR="$HOME/Library/LaunchAgents"
    AGENT_PLIST="$AGENT_DIR/com.quicktasks.menubar.plist"
    mkdir -p "$AGENT_DIR"
    # Substitute the real executable path into the template rather than
    # committing one person's home directory to the repo.
    sed "s|__EXECUTABLE__|$TARGET/Contents/MacOS/$APP_NAME|" \
      "$SELF_DIR/com.quicktasks.menubar.plist" >"$AGENT_PLIST"
    # bootout first so a re-run picks up the new plist instead of silently
    # keeping the previously loaded definition.
    launchctl bootout "gui/$(id -u)/com.quicktasks.menubar" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
    echo "login agent: $AGENT_PLIST"
    echo "starts at every login · remove with:"
    echo "  launchctl bootout gui/$(id -u)/com.quicktasks.menubar && rm \"$AGENT_PLIST\""
  fi
  AGENT_LABEL="gui/$(id -u)/com.quicktasks.menubar"
  if launchctl print "$AGENT_LABEL" >/dev/null 2>&1; then
    # The login agent owns the running copy, and the pkill above just took it
    # down (KeepAlive is deliberately off, so nothing brings it back on its
    # own). Restart through launchd. A bare `open` here would start a second,
    # unmanaged instance next to the agent's: two dots in the menu bar, which
    # is exactly what --run used to do on a machine with the agent loaded.
    launchctl kickstart -k "$AGENT_LABEL"
    echo "restarted through the login agent ($AGENT_LABEL)."
  elif [ "$RUN" -eq 1 ]; then
    open "$TARGET"
    echo "launched. Look for the status dot in the menu bar."
  else
    echo "launch with: open \"$TARGET\""
  fi
fi
