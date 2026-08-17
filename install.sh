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

# --------------------------------------------------------------- shell plugin

PLUGIN_DIR="$HOME/.config/omarchy/plugins/erruviel.wwan"

if [[ $REPO == "$PLUGIN_DIR" ]]; then
  # Installed via `omarchy plugin add` — the repo already is the plugin.
  say "shell plugin already in place ($PLUGIN_DIR)"
else
  say "installing the shell plugin into $PLUGIN_DIR"
  mkdir -p "$PLUGIN_DIR/shell"
  install -m 644 "$REPO/manifest.json" "$PLUGIN_DIR/manifest.json"
  install -m 644 "$REPO"/shell/*.qml "$PLUGIN_DIR/shell/"
  # Entry points renamed across versions leave stale QML behind; keep only
  # what the repo ships.
  for f in "$PLUGIN_DIR"/shell/*.qml; do
    [[ -f "$REPO/shell/$(basename "$f")" ]] || rm -f "$f"
  done
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

# Put the widget in the bar next to the Wi-Fi indicator — but only when it is
# not already placed, so re-running the installer never duplicates or moves it.
SHELL_JSON="$HOME/.config/omarchy/shell.json"
if ! jq -e '[.bar.layout[]?[]? | select(.id == "erruviel.wwan")] | length > 0' \
  "$SHELL_JSON" >/dev/null 2>&1; then
  say "enabling the bar widget"
  if omarchy-plugin-enable erruviel.wwan --section right; then
    # Sit next to the Wi-Fi indicator, like the old waybar module did. The
    # placement flag on `plugin enable` does not land reliably; `bar move` does.
    omarchy-bar move erruviel.wwan --before omarchy.network >/dev/null 2>&1 || true
  else
    echo "   warning: could not enable the widget — run: omarchy plugin enable erruviel.wwan"
  fi
fi

# ---------------------------------------------------------------- menu entries

MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$MENU")"
[[ -f $MENU ]] || printf '{\n}\n' >"$MENU"

say "installing the Setup → Mobile menu entries"
backup_once "$MENU"
strip_block "$MENU"
# Insert right after the opening brace: our block's rows all end in commas, so
# leading the object keeps the file valid whether or not the user's own last
# entry has a trailing comma (JSONC tolerates a trailing one either way).
python3 - "$MENU" "$REPO/config/menu.jsonc.part" <<'PY'
import sys

path, part = sys.argv[1], sys.argv[2]
s = open(path).read()
block = open(part).read()
i = s.find("{")
if i < 0:
    sys.exit(f"no opening brace in {path}")
s = s[: i + 1] + "\n" + block + s[i + 1 :]
open(path, "w").write(s)
PY

# --------------------------------------------------- leftovers from Omarchy 3

# Pre-quattro installs patched waybar and the walker menu. Those files are
# ignored by Omarchy 4, but leaving our blocks in them would only confuse.
strip_block "$HOME/.config/omarchy/extensions/menu.sh"
strip_block "$HOME/.config/waybar/config.jsonc"
strip_block "$HOME/.config/waybar/style.css"
[[ -f $HOME/.config/waybar/config.jsonc ]] &&
  sed -i '/^[[:space:]]*"custom\/wwan",[[:space:]]*$/d' "$HOME/.config/waybar/config.jsonc"
rm -f "$STATE/upstream-setup-menu.sha"

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

echo
echo "Done. Connect with:  omarchy-wwan connect"
echo "Check the patch:     omarchy-wwan doctor"
echo "Remove everything:   $REPO/uninstall.sh"
