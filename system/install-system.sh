#!/bin/bash
# System-side installer. Invoked with sudo by ../install.sh — not meant to be
# run directly.
#
#     install-system.sh <target-user> <config-path>

set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

[[ $EUID -eq 0 ]] || {
  echo "install-system.sh must run as root" >&2
  exit 1
}

TARGET_USER=${1:?target user required}
CONFIG=${2:?config path required}

say() { printf '   %s\n' "$*"; }

say "helper -> /usr/local/bin/omarchy-wwan-helper"
sed "s|@CONFIG@|$CONFIG|" "$SRC/omarchy-wwan-helper" >/usr/local/bin/omarchy-wwan-helper
chmod 755 /usr/local/bin/omarchy-wwan-helper

say "systemd units"
install -m 644 "$SRC/omarchy-wwan.service" /etc/systemd/system/omarchy-wwan.service
install -m 644 "$SRC/omarchy-wwan-resume.service" /etc/systemd/system/omarchy-wwan-resume.service

say "polkit rule"
install -d -m 750 /etc/polkit-1/rules.d
install -m 644 "$SRC/50-omarchy-wwan.rules" /etc/polkit-1/rules.d/50-omarchy-wwan.rules

# The config may hold a SIM PIN.
if [[ -f $CONFIG ]]; then
  chown "$TARGET_USER" "$CONFIG"
  chmod 600 "$CONFIG"
fi

say "reloading systemd"
systemctl daemon-reload
systemctl enable --now ModemManager.service >/dev/null
systemctl enable omarchy-wwan-resume.service >/dev/null

say "generating the systemd-networkd [MobileNetwork] drop-in"
OMARCHY_WWAN_CONFIG="$CONFIG" /usr/local/bin/omarchy-wwan-helper apply

autoconnect=$(sed -n 's/^[[:space:]]*AUTOCONNECT[[:space:]]*=[[:space:]]*//p' "$CONFIG" 2>/dev/null |
  tail -1 | tr -d '[:space:]')
if [[ ${autoconnect,,} == no ]]; then
  say "autoconnect left disabled"
  systemctl disable omarchy-wwan.service >/dev/null 2>&1 || true
else
  say "enabling autoconnect at boot"
  systemctl enable omarchy-wwan.service >/dev/null
fi
