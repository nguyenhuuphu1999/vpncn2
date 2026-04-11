#!/usr/bin/env bash
# Interactive WireGuard setup: output matches labno_02 (server_labno_02.sh + router.sh + pc.sh).
set -euo pipefail
umask 077

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "======================================"
echo " VPNCN2 WireGuard Setup (labno_02)"
echo "======================================"

DEFAULT_IF="wg100"
DEFAULT_WG_IP="10.100.1.254/24"
DEFAULT_ROUTER_IP="10.100.1.1"
DEFAULT_PC_IP="10.100.1.253"
DEFAULT_PORT="51100"
DEFAULT_ROUTER_NAME="fomi"
WG_DIR="${WG_DIR:-/etc/wireguard}"

########################################
# Root
########################################
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

########################################
# IPv4 / helpers
########################################
valid_ip() {
  local ip=$1
  local stat=1
  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local OIFS=$IFS
    IFS='.'
    local -a oct=($ip)
    IFS=$OIFS
    [[ ${oct[0]} -le 255 && ${oct[1]} -le 255 && ${oct[2]} -le 255 && ${oct[3]} -le 255 ]]
    stat=$?
  fi
  return $stat
}

port_in_use() {
  local p="$1"
  ss -tuln 2>/dev/null | awk -v p="$p" '$5 ~ (":" p) "$" { found=1 } END { exit !found }'
}

########################################
# INTERFACE
########################################
while true; do
  read -r -p "WireGuard interface [$DEFAULT_IF]: " WG_IF
  WG_IF=${WG_IF:-$DEFAULT_IF}
  if [[ ! $WG_IF =~ ^wg ]]; then
    echo "ERROR: interface must start with wg"
    continue
  fi
  break
done

########################################
# ROUTER_NAME (output dir = \$WG_DIR/\$ROUTER_NAME)
########################################
while true; do
  read -r -p "Output folder name under ${WG_DIR} [$DEFAULT_ROUTER_NAME]: " ROUTER_NAME
  ROUTER_NAME=${ROUTER_NAME:-$DEFAULT_ROUTER_NAME}
  if [[ -z "$ROUTER_NAME" || "$ROUTER_NAME" == *"/"* ]]; then
    echo "ERROR: invalid folder name"
    continue
  fi
  break
done

OUT_DIR="${WG_DIR}/${ROUTER_NAME}"

########################################
# WG LAN (must be /24 — same as server_labno_02.sh)
########################################
while true; do
  read -r -p "WG server Address (CIDR, /24 only) [$DEFAULT_WG_IP]: " WG_IP_LAN
  WG_IP_LAN=${WG_IP_LAN:-$DEFAULT_WG_IP}
  if ! [[ $WG_IP_LAN =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/24$ ]]; then
    echo "ERROR: must be IPv4 /24 (example 10.100.1.254/24)"
    continue
  fi
  WG_SERVER_IP="${WG_IP_LAN%/24}"
  valid_ip "$WG_SERVER_IP" || { echo "ERROR: invalid IP"; continue; }
  WG_PREFIX=$(echo "$WG_SERVER_IP" | cut -d. -f1-3)
  WG_NET="${WG_PREFIX}.0"

  CONFLICT=false
  for conf in /etc/wireguard/*.conf; do
    [[ -e "$conf" ]] || continue
    [[ "$(basename "$conf")" == "${WG_IF}.conf" ]] && continue
    EXIST_LINE=$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$conf" | head -n1 || true)
    [[ -z "$EXIST_LINE" ]] && continue
    EXIST_IP=$(echo "$EXIST_LINE" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' | cut -d/ -f1)
    [[ -z "$EXIST_IP" ]] && continue
    EXIST_PREFIX=$(echo "$EXIST_IP" | cut -d. -f1-3)
    if [[ "$EXIST_PREFIX" == "$WG_PREFIX" ]]; then
      echo "ERROR: WG subnet conflict with $conf"
      CONFLICT=true
    fi
  done
  if [[ "$CONFLICT" == true ]]; then
    continue
  fi
  break
done

WG_SERVER_ADDR="$WG_IP_LAN"

########################################
# ROUTER IP
########################################
while true; do
  read -r -p "Router WG IP (host, same /24) [$DEFAULT_ROUTER_IP]: " ROUTER_IP
  ROUTER_IP=${ROUTER_IP:-$DEFAULT_ROUTER_IP}
  valid_ip "$ROUTER_IP" || { echo "ERROR: invalid IPv4"; continue; }
  ROUTER_PREFIX=$(echo "$ROUTER_IP" | cut -d. -f1-3)
  if [[ "$ROUTER_PREFIX" != "$WG_PREFIX" ]]; then
    echo "ERROR: Router IP must be inside ${WG_PREFIX}.0/24"
    continue
  fi
  break
done
ROUTER_ADDR="${ROUTER_IP}/24"

########################################
# PC IP
########################################
while true; do
  read -r -p "PC WG IP (host, same /24) [$DEFAULT_PC_IP]: " PC_IP
  PC_IP=${PC_IP:-$DEFAULT_PC_IP}
  valid_ip "$PC_IP" || { echo "ERROR: invalid IPv4"; continue; }
  PC_PREFIX=$(echo "$PC_IP" | cut -d. -f1-3)
  if [[ "$PC_PREFIX" != "$WG_PREFIX" ]]; then
    echo "ERROR: PC IP must be inside ${WG_PREFIX}.0/24"
    continue
  fi
  if [[ "$PC_IP" == "$ROUTER_IP" ]]; then
    echo "ERROR: PC IP cannot equal Router IP"
    continue
  fi
  break
done
PC_ADDR="${PC_IP}/24"
PC_IP_ONLY="$PC_IP"

########################################
# PORT
########################################
while true; do
  read -r -p "WG Listen Port [$DEFAULT_PORT]: " WG_PORT
  WG_PORT=${WG_PORT:-$DEFAULT_PORT}
  if ! [[ "$WG_PORT" =~ ^[0-9]+$ ]] || ((WG_PORT < 1 || WG_PORT > 65535)); then
    echo "ERROR: port must be 1-65535"
    continue
  fi
  if port_in_use "$WG_PORT"; then
    echo "ERROR: port already in use"
    continue
  fi
  break
done
WG_LISTENPORT="$WG_PORT"

########################################
# WAN_IF (for iptables/NAT in server_labno_02)
########################################
WAN_IF_AUTO=""
if command -v ip >/dev/null 2>&1; then
  WAN_IF_AUTO="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
fi
read -r -p "WAN interface for NAT/FORWARD [${WAN_IF_AUTO:-eth0}]: " WAN_IF_INPUT
WAN_IF="${WAN_IF_INPUT:-${WAN_IF_AUTO:-eth0}}"

########################################
# SERVER_NAME / SERVER_PUBLIC_IP (same logic as up_labno_02.sh)
########################################
echo "Auto-detecting SERVER_NAME..."
SERVER_NAME="$(hostname -f 2>/dev/null || true)"
if [[ -z "$SERVER_NAME" ]]; then
  SERVER_NAME="$(hostname 2>/dev/null || true)"
fi
if [[ -z "$SERVER_NAME" ]]; then
  SERVER_NAME="$(uname -n 2>/dev/null || true)"
fi
if [[ -z "$SERVER_NAME" ]]; then
  SERVER_NAME="server"
fi
echo "SERVER_NAME detected: $SERVER_NAME"

echo "Auto-detecting SERVER_PUBLIC_IP..."
SERVER_PUBLIC_IP="$(ip route get 1.1.1.1 2>/dev/null \
  | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  SERVER_PUBLIC_IP="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
fi
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  SERVER_PUBLIC_IP="$(curl -fsS --max-time 3 https://ipinfo.io/ip 2>/dev/null || true)"
fi
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  SERVER_PUBLIC_IP="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
fi
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  read -r -p "Could not detect public IP. Enter SERVER_PUBLIC_IP: " SERVER_PUBLIC_IP
fi
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  echo "ERROR: SERVER_PUBLIC_IP is required"
  exit 1
fi
echo "SERVER_PUBLIC_IP detected: $SERVER_PUBLIC_IP"

########################################
# Optional DNS for client configs (router.sh / pc.sh defaults)
########################################
read -r -p "Client DNS list [8.8.8.8, 8.8.4.4]: " DNS_LIST
DNS_LIST="${DNS_LIST:-8.8.8.8, 8.8.4.4}"

########################################
# Summary
########################################
echo
echo "Interface : $WG_IF"
echo "WG Network: ${WG_NET}/24"
echo "Server    : $WG_SERVER_ADDR"
echo "Router    : $ROUTER_ADDR"
echo "PC        : $PC_ADDR"
echo "WAN IF    : $WAN_IF"
echo "Public IP : $SERVER_PUBLIC_IP"
echo "Port      : $WG_LISTENPORT"
echo "OUT_DIR   : $OUT_DIR"
echo

read -r -p "Proceed? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y(es)?$ ]]; then
  echo "Aborted."
  exit 0
fi

########################################
# Packages
########################################
if ! command -v wg >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y wireguard iptables curl iproute2
fi

mkdir -p "$WG_DIR" "$OUT_DIR"
chmod 700 "$WG_DIR" 2>/dev/null || true

########################################
# Keys (same pattern as up_labno_02.sh)
########################################
gen_keypair() {
  local priv="$1"
  local pub="$2"
  if [[ ! -f "$priv" || ! -f "$pub" ]]; then
    wg genkey | tee "$priv" | wg pubkey >"$pub"
    chmod 600 "$priv"
    chmod 644 "$pub"
  fi
}

gen_psk() {
  local file="$1"
  [[ -f "$file" ]] || wg genpsk >"$file"
  chmod 600 "$file"
}

WG_PRIV="${WG_DIR}/${WG_IF}_privatekey"
WG_PUB="${WG_DIR}/${WG_IF}_publickey"
gen_keypair "$WG_PRIV" "$WG_PUB"
gen_keypair "${OUT_DIR}/router_privatekey" "${OUT_DIR}/router_publickey"
gen_keypair "${OUT_DIR}/pc_privatekey" "${OUT_DIR}/pc_publickey"
gen_psk "${OUT_DIR}/router_psk"
gen_psk "${OUT_DIR}/pc_psk"

########################################
# labno_02 defaults for routing blocks
########################################
KEEPALIVE="${KEEPALIVE:-25}"
WG_USE_MARK_ROUTING="${WG_USE_MARK_ROUTING:-1}"
WG_RP_FILTER="${WG_RP_FILTER:-0}"
WG_POLICY_TABLE="${WG_POLICY_TABLE:-51820}"
WG_TABLE="${WG_TABLE:-}"
ROUTER_ALLOWED_IPS="${ROUTER_ALLOWED_IPS:-}"

########################################
# EXPORT + same modules as up_labno_02.sh
########################################
export WG_IF WG_DIR OUT_DIR
export WG_PRIV WG_PUB
export ROUTER_NAME
export SERVER_NAME SERVER_PUBLIC_IP WG_LISTENPORT
export WG_SERVER_ADDR ROUTER_ADDR PC_ADDR PC_IP_ONLY WAN_IF
export DNS_LIST ALLOWED_ALL KEEPALIVE
export WG_TABLE WG_RP_FILTER WG_USE_MARK_ROUTING WG_POLICY_TABLE ROUTER_ALLOWED_IPS

# shellcheck source=server_labno_02.sh
source "${BASE_DIR}/server_labno_02.sh"
# shellcheck source=router.sh
source "${BASE_DIR}/router.sh"
# shellcheck source=pc.sh
source "${BASE_DIR}/pc.sh"

########################################
# APPLY (same as up_labno_02.sh)
########################################
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

SERVER_ADDR_CIDR="${WG_SERVER_ADDR}"
SERVER_ADDR_IP="${SERVER_ADDR_CIDR%/*}"

cleanup_server_ip() {
  if ! command -v ip >/dev/null 2>&1; then
    return 0
  fi
  while read -r CIDR DEV; do
    if [[ -n "$CIDR" && -n "$DEV" ]]; then
      echo "Removing ${CIDR} from interface ${DEV} to avoid conflict..."
      ip addr del "$CIDR" dev "$DEV" 2>/dev/null || true
    fi
  done < <(ip -4 addr show | awk -v ip="$SERVER_ADDR_IP" '
    $1 == "inet" && index($2, ip"/") == 1 {
      print $2, $NF
    }
  ') || true
}

kill_other_wg_using_same_port() {
  local port="${1:-$WG_LISTENPORT}"
  local used_port
  local iface
  if ! command -v wg >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
    return 0
  fi
  while read -r iface; do
    [[ -z "$iface" ]] && continue
    [[ "$iface" == "$WG_IF" ]] && continue
    used_port="$(wg show "$iface" listen-port 2>/dev/null || true)"
    if [[ "$used_port" == "$port" ]]; then
      echo "Stopping interface ${iface} (using same port ${port})..."
      wg-quick down "$iface" 2>/dev/null || true
      ip link del "$iface" 2>/dev/null || true
    fi
  done < <(ip link show type wireguard 2>/dev/null | awk -F: '{print $2}' | tr -d ' ') || true
}

cleanup_server_ip
kill_other_wg_using_same_port "$WG_LISTENPORT"

if ip link show "$WG_IF" &>/dev/null; then
  wg-quick down "$WG_IF" 2>/dev/null || wg down "$WG_IF" 2>/dev/null || ip link del "$WG_IF" 2>/dev/null || true
fi

if ! wg-quick up "$WG_IF"; then
  echo "wg-quick up ${WG_IF} failed, attempting force cleanup and retry..."
  cleanup_server_ip
  kill_other_wg_using_same_port "$WG_LISTENPORT"
  ip link del "$WG_IF" 2>/dev/null || true
  wg-quick up "$WG_IF"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable "wg-quick@${WG_IF}" 2>/dev/null || true
fi

echo
echo "======================================"
echo " WireGuard (labno_02 layout)"
echo "======================================"
echo "Server config : ${WG_DIR}/${WG_IF}.conf"
echo "Router config : ${OUT_DIR}/router.conf"
echo "PC config     : ${OUT_DIR}/pc.conf"
echo
wg show "$WG_IF" 2>/dev/null || wg show
echo
echo "All done (configs are not printed here to avoid leaking PrivateKey)."
