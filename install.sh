#!/usr/bin/env bash
# ============================================================================
#  cloak — self-configuring installer
#
#  One-liner:
#    curl -fsSL https://raw.githubusercontent.com/linoMlv/cloak/main/install.sh | sudo bash
#
#  Or from a clone:
#    git clone https://github.com/linoMlv/cloak && cd cloak && sudo ./install.sh
# ============================================================================
set -u

REPO_URL="${CLOAK_REPO:-https://github.com/linoMlv/cloak}"
BRANCH="${CLOAK_BRANCH:-main}"
PREFIX="${CLOAK_PREFIX:-/usr/local}"
BIN="$PREFIX/bin/cloak"
TORRC="/etc/tor/torrc"
SOCKS_PORT=9050; TRANS_PORT=9040; DNS_PORT=5353

G=$'\e[1;32m'; R=$'\e[1;31m'; Y=$'\e[1;33m'; N=$'\e[0m'
ok()   { printf '%s[+]%s %s\n' "$G" "$N" "$*"; }
info() { echo "[*] $*"; }
die()  { printf '%s[-]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

TOR_UNIT=""
detect_tor_unit() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    if [[ -n $(systemctl list-unit-files 'tor@.service' --no-legend 2>/dev/null | head -n1) ]]; then
      TOR_UNIT="tor@default"   # Debian/Kali modern: tor.service is an empty multi-instance master
    elif [[ -n $(systemctl list-unit-files 'tor.service' --no-legend 2>/dev/null | head -n1) ]]; then
      TOR_UNIT="tor"
    fi
  fi
}
tor_service() { # $1 = start|stop|restart
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && [[ -n $TOR_UNIT ]]; then
    systemctl reset-failed "$TOR_UNIT" 2>/dev/null   # clears a "start-limit-hit" state
    systemctl "$1" "$TOR_UNIT"
  else
    service tor "$1"
  fi
}
tor_listening() { ss -tln 2>/dev/null | grep -q ":$SOCKS_PORT[[:space:]]"; }

[[ $(id -u) -eq 0 ]] || die "must be run as root: curl -fsSL … | sudo bash"

echo "  ┌────────────────────────────────────────┐"
echo "  │   cloak — torify everything, safely    │"
echo "  └────────────────────────────────────────┘"

# --- 1) dependencies -----------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  info "Installing dependencies (apt)…"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y tor iptables curl iputils-ping \
    || die "apt-get failed"
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y tor iptables curl iputils || die "dnf failed"
elif command -v pacman >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed tor iptables curl iputils || die "pacman failed"
else
  die "unsupported package manager (apt / dnf / pacman)"
fi

# --- 2) the binary --------------------------------------------------------------
here=""
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]:-} ]]; then
  here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || here=""
fi
if [[ -n $here && -f "$here/cloak" ]]; then
  info "Installing from local repository: $here/cloak"
  install -m 0755 "$here/cloak" "$BIN"
else
  info "Downloading: $REPO_URL (branch $BRANCH)"
  tmp=$(mktemp) || die "mktemp failed"
  curl -fsSL "$REPO_URL/raw/$BRANCH/cloak" -o "$tmp" \
    || die "download failed — check REPO_URL"
  install -m 0755 "$tmp" "$BIN" && rm -f "$tmp"
fi
ok "binary installed: $BIN"

# --- 3) tor configuration (marked block, idempotent, with validation) ----------
[[ -f $TORRC ]] || touch "$TORRC"
bak="$TORRC.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$TORRC" "$bak"
sed -i '/^# >>> cloak >>>/,/^# <<< cloak <<</d' "$TORRC"
# purge legacy directives left outside the marked block by older tor-on/off setups
# (duplicated TransPort/DNSPort make tor bind against itself)
sed -i '/^# >>> cloak >>>/,/^# <<< cloak <<</!{/^[[:space:]]*\(SocksPort\|TransPort\|DNSPort\|VirtualAddrNetworkIPv4\|AutomapHostsOnResolve\)/d}' "$TORRC"
cat >>"$TORRC" <<EOF

# >>> cloak >>>
SocksPort 127.0.0.1:$SOCKS_PORT
TransPort 127.0.0.1:$TRANS_PORT
DNSPort 127.0.0.1:$DNS_PORT
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
# <<< cloak <<<
EOF

if [[ -f /usr/share/tor/tor-service-defaults-torrc ]]; then
  vout=$(tor --defaults-torrc /usr/share/tor/tor-service-defaults-torrc -f "$TORRC" --verify-config 2>&1)
else
  vout=$(tor --verify-config -f "$TORRC" 2>&1)
fi
if [[ $? -ne 0 ]]; then
  echo "$vout" >&2
  cp -a "$bak" "$TORRC"
  die "invalid torrc — backup restored: $bak"
fi
ok "torrc parsed (backup: $bak)"

# Real smoke test: --verify-config only parses, it does not bind ports, so
# duplicated listeners pass validation but crash tor at start. Start the actual
# service and wait for the SocksPort to come up; rollback on failure.
detect_tor_unit
live=""
if tor_service restart; then
  for i in $(seq 1 30); do
    if tor_listening; then live=1; break; fi
    sleep 0.5
  done
fi
if [[ -z $live ]]; then
  journalctl -u "${TOR_UNIT:-tor}" -n 20 --no-pager 1>&2 || true
  cp -a "$bak" "$TORRC"
  tor_service restart >/dev/null 2>&1 || true
  die "tor failed to start with the new torrc — backup restored: $bak"
fi
ok "tor service started and listening (unit: ${TOR_UNIT:-sysv service})"

# --- 4) migration from the tor-on / tor-off / tor-check series -------------------
for old in /usr/local/bin/tor-on /usr/local/bin/tor-off /usr/local/bin/tor-check; do
  if [[ -e $old ]]; then rm -f "$old"; ok "old script removed: $old"; fi
done
if [[ -n ${SUDO_USER:-} ]]; then
  rc="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.bashrc"
  if grep -qE 'tor-(on|off|check)' "$rc" 2>/dev/null; then
    printf '%s[!]%s old tor-on/tor-off/tor-check aliases detected in %s — remove them.\n' "$Y" "$N" "$rc"
  fi
fi

# --- 5) environment notes ------------------------------------------------------
if [[ -d /run/systemd/system ]]; then
  ok "systemd active — cloak will control tor via systemctl"
else
  printf '%s[!]%s systemd inactive (WSL?) — using "service" fallback.\n' "$Y" "$N"
  printf '    Recommended: /etc/wsl.conf → [boot] systemd=true, then "wsl --shutdown".\n'
fi
if [[ -n ${SUDO_USER:-} ]]; then
  upath=$(su -s /bin/sh "$SUDO_USER" -c 'printf %s "$PATH"' 2>/dev/null) || upath="$PATH"
else
  upath="$PATH"
fi
case ":$upath:" in *":$PREFIX/bin:"*) ;; *)
  printf '%s[!]%s %s missing from PATH.\n' "$Y" "$N" "$PREFIX/bin" ;;
esac

# --- 6) test --------------------------------------------------------------------
info "Quick test…"
"$BIN" check || true

ok "Installation complete. Torify: sudo cloak on — Status: cloak check"
