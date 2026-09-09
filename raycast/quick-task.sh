#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Quick Task
# @raycast.mode silent
#
# Optional parameters:
# @raycast.icon 🪄
# @raycast.packageName Quicktasks
# @raycast.argument1 { "type": "text", "placeholder": "what should Claude do?" }
# @raycast.argument2 { "type": "text", "placeholder": "dir (optional)", "optional": true }
#
# Documentation:
# @raycast.description Fire a one-shot Claude Code task; desktop notification on completion
# @raycast.author johnblythe

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
QT="${QT_BIN:-$SELF_DIR/../qt}"
[ -x "$QT" ] || QT="$HOME/.local/bin/qt"

if [ -n "$2" ]; then
  exec QT_ORIGIN=raycast "$QT" --in "$2" "$1"
else
  exec QT_ORIGIN=raycast "$QT" "$1"
fi
