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

# ---------------------------------------------------------------- shell plugin

PLUGIN_DIR="$HOME/.config/omarchy/plugins/erruviel.wwan"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

# Take the widget out of the bar layout before deleting its code, or the shell
# logs a missing-plugin warning on every reload until the user cleans up.
if [[ -f $SHELL_JSON ]] && grep -q 'erruviel\.wwan' "$SHELL_JSON"; then
  say "removing the widget from the bar layout"
  tmp=$(mktemp)
  if jq '
    if (.bar.layout? | type) == "object" then
      .bar.layout |= with_entries(
        .value |= (if type == "array" then map(select(.id != "erruviel.wwan")) else . end)
      )
    else . end
    | if (.plugins? | type) == "array" then
        .plugins |= map(select((.id? // .) != "erruviel.wwan"))
      else . end
  ' "$SHELL_JSON" >"$tmp"; then
    mv "$tmp" "$SHELL_JSON"
  else
    rm -f "$tmp"
    echo "   warning: could not edit $SHELL_JSON — remove erruviel.wwan by hand" >&2
  fi
fi

if [[ -d $PLUGIN_DIR ]]; then
  say "removing the shell plugin"
  rm -rf "$PLUGIN_DIR"
fi
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

# ----------------------------------------------------------------- menu blocks

strip_block "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" "menu"

# Leftovers from a pre-quattro (waybar/walker) install of this repo.
strip_block "$HOME/.config/omarchy/extensions/menu.sh" "legacy menu"
strip_block "$HOME/.config/waybar/config.jsonc" "legacy waybar module"
strip_block "$HOME/.config/waybar/style.css" "legacy waybar style"
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

echo
echo "Done. Mobile data is off and every patched file is back to stock."
