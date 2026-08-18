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

# CONFIG names a path in the user's home, but everything here runs as root. A
# symlink at that path could point anywhere, so following it — to read, and
# especially to chown or chmod — would let an unprivileged user hand themselves
# an arbitrary root-owned file. Refuse a symlink outright, and never touch the
# config's ownership or mode from root: that is the unprivileged user-side
# installer's job, and root can read the user's private config regardless of
# who owns it.
if [[ -L $CONFIG ]]; then
  echo "refusing: $CONFIG is a symlink, not a regular file" >&2
  exit 1
fi

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
