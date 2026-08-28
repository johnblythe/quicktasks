#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Quick Task List
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.icon 📋
# @raycast.packageName Quicktasks
#
# Documentation:
# @raycast.description Recent quicktasks: status, prompt, result
# @raycast.author johnblythe

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
QT="${QT_BIN:-$SELF_DIR/../qt}"
[ -x "$QT" ] || QT="$HOME/.local/bin/qt"

exec "$QT" list 20
