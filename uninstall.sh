#!/usr/bin/env bash
# cloak — uninstaller (tor/iptables packages are kept)
set -u
[[ $(id -u) -eq 0 ]] || { echo "sudo required" >&2; exit 1; }

TORRC="/etc/tor/torrc"

command -v cloak >/dev/null 2>&1 && cloak off >/dev/null 2>&1 || true
rm -f /usr/local/bin/cloak

# remove the marked cloak block, then purge legacy directives left outside it by
# older tor-on/off setups (duplicates make tor bind against itself)
sed -i '/^# >>> cloak >>>/,/^# <<< cloak <<</d' "$TORRC" 2>/dev/null || true
sed -i '/^# >>> cloak >>>/,/^# <<< cloak <<</!{/^[[:space:]]*\(SocksPort\|TransPort\|DNSPort\|VirtualAddrNetworkIPv4\|AutomapHostsOnResolve\)/d}' "$TORRC" 2>/dev/null || true

# restart the real tor unit (tor.service is an empty multi-instance master on
# modern Debian/Kali; tor@default is the actual daemon), clearing a possible
# "start-limit-hit" state first
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  if [[ -n $(systemctl list-unit-files 'tor@.service' --no-legend 2>/dev/null | head -n1) ]]; then
    UNIT="tor@default"
  else
    UNIT="tor"
  fi
  systemctl reset-failed "$UNIT" 2>/dev/null || true
  systemctl restart "$UNIT" >/dev/null 2>&1 || true
else
  service tor restart >/dev/null 2>&1 || true
fi

# remove the real-IP leak-detection caches
rm -rf "${XDG_CACHE_HOME:-/root/.cache}/cloak" 2>/dev/null || true
if [[ -n ${SUDO_USER:-} ]]; then
  uc="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.cache/cloak"
  [[ -d $uc ]] && rm -rf "$uc"
fi

echo "[+] cloak uninstalled (cloak block and legacy directives removed, tor kept)."
