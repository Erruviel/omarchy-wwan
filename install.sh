#!/bin/bash
# Install WWAN (mobile broadband) support for Omarchy.
#
# Run as your normal user; it calls sudo only for the system-side pieces:
#
#     ./install.sh
#
# Safe to re-run — every step is idempotent, so this doubles as the repair
# command after an Omarchy update has clobbered part of the patch.

set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$HOME/.config/omarchy/wwan.conf"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-wwan"
BACKUP="$STATE/backups"

BEGIN=">>> omarchy-wwan >>>"

[[ $EUID -ne 0 ]] || {
  echo "Run this as your normal user, not as root — it uses sudo where needed." >&2
  exit 1
}

say() { printf ':: %s\n' "$*"; }

backup_once() {
  local f="$1"
  [[ -f $f ]] || return 0
  mkdir -p "$BACKUP"
  local dest="$BACKUP/$(basename "$f").orig"
  [[ -e $dest ]] || cp "$f" "$dest"
}

has_block() { grep -qF "$BEGIN" "$1" 2>/dev/null; }

# Cut out any block we installed previously so it can be replaced with the
# current one. Without this, re-running after a `git pull` would leave the old
# version in place — the opposite of what a repair command should do.
strip_block() {
  local f="$1"
  has_block "$f" || return 0
  python3 - "$f" <<'PY'
import re, sys
path = sys.argv[1]
s = open(path).read()
s = re.sub(r"[^\n]*>>> omarchy-wwan >>>.*?<<< omarchy-wwan <<<[^\n]*\n", "", s, flags=re.S)
open(path, "w").write(s)
PY
}

# ---------------------------------------------------------------- user scripts

say "installing CLI into ~/.local/bin"
mkdir -p "$HOME/.local/bin"
install -m 755 "$REPO/bin/omarchy-wwan" "$HOME/.local/bin/omarchy-wwan"
install -m 755 "$REPO/bin/omarchy-launch-wwan" "$HOME/.local/bin/omarchy-launch-wwan"
install -m 755 "$REPO/bin/omarchy-wwan-providers" "$HOME/.local/bin/omarchy-wwan-providers"

[[ -f /usr/share/mobile-broadband-provider-info/serviceproviders.xml ]] ||
  echo "   warning: mobile-broadband-provider-info is not installed — the carrier
            wizard will not work. Install it with: omarchy pkg add mobile-broadband-provider-info"

case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) echo "   warning: ~/.local/bin is not on your PATH" ;;
esac

# ----------------------------------------------------------------- user config

mkdir -p "$HOME/.config/omarchy"
if [[ -f $CONFIG ]]; then
  say "keeping existing $CONFIG"
else
  say "creating $CONFIG"
  install -m 600 "$REPO/config/wwan.conf" "$CONFIG"
fi

# ---------------------------------------------------------------- menu entry

MENU="$HOME/.config/omarchy/extensions/menu.sh"
mkdir -p "$(dirname "$MENU")"
[[ -f $MENU ]] || : >"$MENU"

say "installing the Mobile entry in the Omarchy menu"
backup_once "$MENU"
strip_block "$MENU"
cat "$REPO/config/menu.sh.part" >>"$MENU"

# Record which upstream Setup menu we forked, so `doctor` can detect drift.
mkdir -p "$STATE"
if [[ -r $HOME/.local/share/omarchy/bin/omarchy-menu ]]; then
  awk '/^show_setup_menu\(\) \{/, /^\}/' "$HOME/.local/share/omarchy/bin/omarchy-menu" |
    sha256sum | cut -d' ' -f1 >"$STATE/upstream-setup-menu.sha"
fi

# --------------------------------------------------------------------- waybar

WB="$HOME/.config/waybar/config.jsonc"
CSS="$HOME/.config/waybar/style.css"

if [[ -f $WB ]]; then
  say "installing the waybar module"
  backup_once "$WB"
  strip_block "$WB"
  # The entry in modules-right lives outside the marked block.
  sed -i '/^[[:space:]]*"custom\/wwan",[[:space:]]*$/d' "$WB"
  MODULE_FILE="$REPO/config/waybar-module.jsonc" python3 - "$WB" <<'PY'
import os, sys

path = sys.argv[1]
block = open(os.environ["MODULE_FILE"]).read()
lines = open(path).read().splitlines(keepends=True)
out, placed_entry, placed_block = [], False, False

for line in lines:
    # Sit next to the Wi-Fi indicator in the right-hand module list.
    if not placed_entry and line.strip() == '"network",':
        out.append('    "custom/wwan",\n')
        placed_entry = True
    out.append(line)
    # Module definitions are plain object keys; order does not matter, so the
    # top of the object is the one anchor that cannot drift.
    if not placed_block and line.lstrip().startswith("{"):
        out.append(block)
        placed_block = True

if not placed_block:
    sys.exit("could not find the opening brace of the waybar config")
if not placed_entry:
    print("   warning: no \"network\" entry in modules-right; module defined but not shown")

open(path, "w").write("".join(out))
PY
else
  echo "   warning: $WB not found, skipping waybar module"
fi

if [[ -f $CSS ]]; then
  say "installing the waybar style"
  backup_once "$CSS"
  strip_block "$CSS"
  cat "$REPO/config/waybar-style.css" >>"$CSS"
else
  echo "   warning: $CSS not found, skipping waybar style"
fi

# ----------------------------------------------------------------- update hook

say "installing the post-update check"
mkdir -p "$HOME/.config/omarchy/hooks/post-update.d"
install -m 755 "$REPO/hooks/post-update" "$HOME/.config/omarchy/hooks/post-update.d/omarchy-wwan"

# --------------------------------------------------------------- system pieces

# Set OMARCHY_WWAN_SKIP_SYSTEM=1 to install only the user-side pieces, e.g. when
# repairing the desktop integration on a machine where the system half is
# already in place and you would rather not be asked for a password.
if [[ ${OMARCHY_WWAN_SKIP_SYSTEM:-0} == 1 ]]; then
  say "skipping the system pieces (OMARCHY_WWAN_SKIP_SYSTEM=1)"
else
  say "installing the system pieces (sudo)"
  sudo "$REPO/system/install-system.sh" "$USER" "$CONFIG"
fi

# ---------------------------------------------------------------------- finish

if command -v omarchy >/dev/null; then
  say "restarting waybar"
  omarchy restart waybar >/dev/null 2>&1 || true
fi

echo
echo "Done. Connect with:  omarchy-wwan connect"
echo "Check the patch:     omarchy-wwan doctor"
echo "Remove everything:   $REPO/uninstall.sh"
