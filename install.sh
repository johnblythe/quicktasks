#!/bin/bash
# quicktasks installer: symlinks qt onto your PATH and points you at setup.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.local/bin"
chmod +x "$SELF_DIR/qt" "$SELF_DIR"/raycast/*.sh
ln -sf "$SELF_DIR/qt" "$HOME/.local/bin/qt"
echo "linked: ~/.local/bin/qt -> $SELF_DIR/qt"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: ~/.local/bin is not on your PATH; add it to your shell rc" ;;
esac

if [ -t 0 ]; then
  printf "run qt setup now? [Y/n]: "
  read -r run_setup
  case "$run_setup" in
    [nN]*) ;;
    *) "$HOME/.local/bin/qt" setup ;;
  esac
fi

echo
echo "next steps:"
echo "  qt setup                   pick your terminal, trusted dirs, permission mode"
echo "  qt doctor                  read-only environment health check"
echo "  Raycast script commands:   Settings → Extensions → + → Add Script Directory:"
echo "                             $SELF_DIR/raycast"
echo "                             (Quick Task · Quick Task List · Quick Task Resume)"
echo "  Raycast extension:         cd $SELF_DIR/raycast-ext && npm install && npm run dev"
