#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Quick Task Resume
# @raycast.mode silent
#
# Optional parameters:
# @raycast.icon 🔓
# @raycast.packageName Quicktasks
# @raycast.argument1 { "type": "text", "placeholder": "id fragment (empty = latest blocked)", "optional": true }
#
# Documentation:
# @raycast.description Reopen a blocked quicktask in your preferred terminal to approve and continue
# @raycast.author johnblythe

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
QT="${QT_BIN:-$SELF_DIR/../qt}"
[ -x "$QT" ] || QT="$HOME/.local/bin/qt"

if [ -n "$1" ]; then
  exec "$QT" _resume-launch "$1"
else
  exec "$QT" _resume-launch
fi
