#!/bin/bash
# System-side uninstaller. Invoked with sudo by ../uninstall.sh.

set -uo pipefail

[[ $EUID -eq 0 ]] || {
  echo "uninstall-system.sh must run as root" >&2
  exit 1
}

say() { printf '   %s\n' "$*"; }

say "stopping and disabling units"
systemctl disable --now omarchy-wwan.service >/dev/null 2>&1
systemctl disable --now omarchy-wwan-resume.service >/dev/null 2>&1
systemctl reset-failed omarchy-wwan.service >/dev/null 2>&1

say "removing units"
rm -f /etc/systemd/system/omarchy-wwan.service
rm -f /etc/systemd/system/omarchy-wwan-resume.service
systemctl daemon-reload

say "removing the networkd drop-in"
rm -f /etc/systemd/network/20-wwan.network.d/10-omarchy-mobile.conf
rmdir --ignore-fail-on-non-empty /etc/systemd/network/20-wwan.network.d 2>/dev/null
networkctl reload >/dev/null 2>&1

say "removing the polkit rule"
rm -f /etc/polkit-1/rules.d/50-omarchy-wwan.rules

say "removing the helper"
rm -f /usr/local/bin/omarchy-wwan-helper

# Leave the radio usable rather than silently switched off for the next owner
# of this machine; systemd-rfkill would otherwise persist a block forever.
rfkill unblock wwan 2>/dev/null

say "left untouched: ModemManager, /etc/systemd/network/20-wwan.network"
