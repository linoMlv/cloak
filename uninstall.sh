#!/usr/bin/env bash
# cloak — uninstaller (tor/iptables packages are kept)
set -u
[[ $(id -u) -eq 0 ]] || { echo "sudo required" >&2; exit 1; }

command -v cloak >/dev/null 2>&1 && cloak off >/dev/null 2>&1 || true
rm -f /usr/local/bin/cloak
sed -i '/^# >>> cloak >>>/,/^# <<< cloak <<</d' /etc/tor/torrc 2>/dev/null || true
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  systemctl restart tor 2>/dev/null || true
else
  service tor restart >/dev/null 2>&1 || true
fi
echo "[+] cloak uninstalled (cloak block removed from torrc, tor kept)."
