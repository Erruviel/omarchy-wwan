#!/bin/bash
# Remove WWAN support and put every file this patch touched back the way it was.
#
#     ./uninstall.sh            keep ~/.config/omarchy/wwan.conf
#     ./uninstall.sh --purge    remove it too
#
# Run as your normal user; it calls sudo for the system-side pieces.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$HOME/.config/omarchy/wwan.conf"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-wwan"

PURGE=no
[[ ${1:-} == --purge ]] && PURGE=yes

[[ $EUID -ne 0 ]] || {
  echo "Run this as your normal user, not as root." >&2
  exit 1
}

say() { printf ':: %s\n' "$*"; }

# Cuts our marked block out of a file the user also owns, leaving their own
# content — and any edits they made around it — intact.
strip_block() {
  local f="$1" label="$2"
  [[ -f $f ]] || return 0
  grep -qF '>>> omarchy-wwan >>>' "$f" || return 0

  say "removing the $label block"
  python3 - "$f" <<'PY'
import re, sys

path = sys.argv[1]
s = open(path).read()
# Match the markers whatever comment syntax wraps them (#, //, /* */).
s = re.sub(
    r"[^\n]*>>> omarchy-wwan >>>.*?<<< omarchy-wwan <<<[^\n]*\n",
    "",
    s,
    flags=re.S,
)
open(path, "w").write(s.rstrip() + "\n")
PY
}

# ------------------------------------------------------------- system pieces

say "removing the system pieces (sudo)"
sudo "$REPO/system/uninstall-system.sh"

# --------------------------------------------------------------- user pieces

say "removing the CLI"
rm -f "$HOME/.local/bin/omarchy-wwan" \
  "$HOME/.local/bin/omarchy-launch-wwan" \
  "$HOME/.local/bin/omarchy-wwan-providers"

say "removing the post-update check"
rm -f "$HOME/.config/omarchy/hooks/post-update.d/omarchy-wwan"

strip_block "$HOME/.config/omarchy/extensions/menu.sh" "menu"
strip_block "$HOME/.config/waybar/config.jsonc" "waybar module"
strip_block "$HOME/.config/waybar/style.css" "waybar style"

# The module name in modules-right sits outside the marked block.
if [[ -f $HOME/.config/waybar/config.jsonc ]]; then
  sed -i '/^[[:space:]]*"custom\/wwan",[[:space:]]*$/d' "$HOME/.config/waybar/config.jsonc"
fi

if [[ $PURGE == yes ]]; then
  say "removing $CONFIG and saved state"
  rm -f "$CONFIG"
  rm -rf "$STATE"
else
  say "keeping $CONFIG (use --purge to remove it)"
  [[ -d $STATE/backups ]] && say "original files kept in $STATE/backups"
fi

if command -v omarchy >/dev/null; then
  say "restarting waybar"
  omarchy restart waybar >/dev/null 2>&1 || true
fi

echo
echo "Done. Mobile data is off and every patched file is back to stock."
