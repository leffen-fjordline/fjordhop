#!/usr/bin/env zsh
# Install Fjordhop (menu bar app) and `cs` (terminal command).
#   ./install.sh              build + install both, launch the app
#   ./install.sh --uninstall  remove both
set -euo pipefail
cd "${0:A:h}"

app="$HOME/Applications/Fjordhop.app"
bindir="$HOME/.local/bin"

if [[ ${1:-} == --uninstall ]]; then
  pkill -x Fjordhop 2>/dev/null || true
  rm -rf "$app"
  [[ -L $bindir/cs ]] && rm "$bindir/cs"
  echo "removed: $app and $bindir/cs"
  echo "settings remain in: defaults read local.fjordhop (delete with: defaults delete local.fjordhop)"
  exit 0
fi

# Preflight: these are the only requirements.
[[ -d /Applications/Ghostty.app ]] || { echo "Ghostty not found in /Applications (needs 1.3+ for AppleScript)"; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found: run  xcode-select --install"; exit 1; }
command -v fzf >/dev/null || echo "note: fzf not found; \`cs\` needs it for the picker (brew install fzf)"

app/build.sh

mkdir -p "$bindir"
ln -sf "$PWD/bin/cs" "$bindir/cs"
echo "linked: $bindir/cs -> $PWD/bin/cs"
[[ :$PATH: == *:$bindir:* ]] || echo "note: $bindir is not on your PATH; add it to use \`cs\`"
