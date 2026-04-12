#!/usr/bin/env bash
set -euo pipefail
umask 077

echo "======================================"
echo " VPNCN2 WireGuard Setup (standalone)"
echo "======================================"

DEFAULT_IF="wg98"
DEFAULT_WG_IP="10.100.6.254/24"
DEFAULT_ROUTER_IP="10.100.6.1"
DEFAULT_PC_IP="10.100.6.253"
DEFAULT_PORT="51830"
DEFAULT_ROUTER_NAME="fomi"
DEFAULT_MTU="1420"
WG_DIR="${WG_DIR:-/etc/wireguard}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

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

detect_wan_if() {
  local dev=""

  if command -v ip >/dev/null 2>&1; then
    dev="$(ip route get 1.1.1.1 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") { print $(i + 1); exit }
      }
    }')"
  fi

  if [[ -z "$dev" ]] && command -v ip >/dev/null 2>&1; then
    dev="$(ip -4 route show default 2>/dev/null | awk '/default/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") { print $(i + 1); exit }
      }
    }')"
  fi

  echo "${dev:-}"
}

detect_public_ip() {
  local ip=""
  local token=""

  ip="$(curl -4 -fsS --max-time 2 \
    -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' \
    2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  token="$(curl -4 -fsS --max-time 2 -X PUT \
    'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    2>/dev/null || true)"

  if [[ -n "$token" ]]; then
    ip="$(curl -4 -fsS --max-time 2 \
      -H "X-aws-ec2-metadata-token: $token" \
      'http://169.254.169.254/latest/meta-data/public-ipv4' \
      2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
  fi

  ip="$(curl -4 -fsS --max-time 2 \
    'http://169.254.169.254/latest/meta-data/public-ipv4' \
    2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  ip="$(curl -4 -fsS --max-time 2 \
    -H 'Metadata: true' \
    'http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text' \
    2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  ip="$(curl -4 -fsS --max-time 2 \
    -H 'Authorization: Bearer Oracle' \
    'http://169.254.169.254/opc/v2/instance/' \
    2>/dev/null | awk -F'"' '/"publicIp"/ {print $4; exit}' || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  ip="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  ip="$(curl -4 -fsS --max-time 3 https://ifconfig.me/ip 2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  ip="$(curl -4 -fsS --max-time 3 https://ipinfo.io/ip 2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  return 1
}

while true; do
  read -r -p "WireGuard interface [$DEFAULT_IF]: " WG_IF
  WG_IF=${WG_IF:-$DEFAULT_IF}
  if [[ ! $WG_IF =~ ^wg ]]; then
    echo "ERROR: interface must start with wg"
    continue
  fi
  break
done

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

while true; do
  read -r -p "WG server Address (CIDR, /24 only) [$DEFAULT_WG_IP]: " WG_IP_LAN
  WG_IP_LAN=${WG_IP_LAN:-$DEFAULT_WG_IP}
  if ! [[ $WG_IP_LAN =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/24$ ]]; then
    echo "ERROR: must be IPv4 /24 (example 10.100.6.254/24)"
    continue
  fi

  WG_SERVER_IP="${WG_IP_LAN%/24}"
  valid_ip "$WG_SERVER_IP" || { echo "ERROR: invalid IP"; continue; }
  WG_PREFIX="$(echo "$WG_SERVER_IP" | cut -d. -f1-3)"
  WG_NET="${WG_PREFIX}.0"

  CONFLICT=false
  for conf in /etc/wireguard/*.conf; do
    [[ -e "$conf" ]] || continue
    [[ "$(basename "$conf")" == "${WG_IF}.conf" ]] && continue

    EXIST_LINE="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$conf" | head -n1 || true)"
    [[ -z "$EXIST_LINE" ]] && continue

    EXIST_IP="$(echo "$EXIST_LINE" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' | cut -d/ -f1)"
    [[ -z "$EXIST_IP" ]] && continue

    EXIST_PREFIX="$(echo "$EXIST_IP" | cut -d. -f1-3)"
    if [[ "$EXIST_PREFIX" == "$WG_PREFIX" ]]; then
      echo "ERROR: WG subnet conflict with $conf"
      CONFLICT=true
    fi
  done

  [[ "$CONFLICT" == true ]] && continue
  break
done

WG_SERVER_ADDR="$WG_IP_LAN"

while true; do
  read -r -p "Router WG IP (host, same /24) [$DEFAULT_ROUTER_IP]: " ROUTER_IP
  ROUTER_IP=${ROUTER_IP:-$DEFAULT_ROUTER_IP}
  valid_ip "$ROUTER_IP" || { echo "ERROR: invalid IPv4"; continue; }
  ROUTER_PREFIX="$(echo "$ROUTER_IP" | cut -d. -f1-3)"
  if [[ "$ROUTER_PREFIX" != "$WG_PREFIX" ]]; then
    echo "ERROR: Router IP must be inside ${WG_PREFIX}.0/24"
    continue
  fi
  if [[ "$ROUTER_IP" == "$WG_SERVER_IP" ]]; then
    echo "ERROR: Router IP cannot equal Server IP"
    continue
  fi
  break
done
ROUTER_ADDR="${ROUTER_IP}/24"

while true; do
  read -r -p "PC WG IP (host, same /24) [$DEFAULT_PC_IP]: " PC_IP
  PC_IP=${PC_IP:-$DEFAULT_PC_IP}
  valid_ip "$PC_IP" || { echo "ERROR: invalid IPv4"; continue; }
  PC_PREFIX="$(echo "$PC_IP" | cut -d. -f1-3)"
  if [[ "$PC_PREFIX" != "$WG_PREFIX" ]]; then
    echo "ERROR: PC IP must be inside ${WG_PREFIX}.0/24"
    continue
  fi
  if [[ "$PC_IP" == "$ROUTER_IP" || "$PC_IP" == "$WG_SERVER_IP" ]]; then
    echo "ERROR: PC IP cannot equal Router IP or Server IP"
    continue
  fi
  break
done
PC_ADDR="${PC_IP}/24"
PC_IP_ONLY="$PC_IP"

while true; do
  read -r -p "WG Listen Port [$DEFAULT_PORT]: " WG_PORT
  WG_PORT=${WG_PORT:-$DEFAULT_PORT}
  if ! [[ "$WG_PORT" =~ ^[0-9]+$ ]] || ((WG_PORT < 1 || WG_PORT > 65535)); then
    echo "ERROR: port must be 1-65535"
    continue
  fi
  break
done
WG_LISTENPORT="$WG_PORT"

WAN_IF_AUTO="$(detect_wan_if)"
if [[ -z "$WAN_IF_AUTO" ]]; then
  echo "WARNING: cannot auto-detect WAN interface, fallback to eth0"
  WAN_IF_AUTO="eth0"
fi

read -r -p "WAN interface for NAT/FORWARD [${WAN_IF_AUTO}]: " WAN_IF_INPUT
WAN_IF="${WAN_IF_INPUT:-$WAN_IF_AUTO}"

if ! ip link show "$WAN_IF" >/dev/null 2>&1; then
  echo "ERROR: interface '$WAN_IF' does not exist"
  echo "Available interfaces:"
  ip -o link show | awk -F': ' '{print $2}'
  exit 1
fi

if [[ ! -d "/proc/sys/net/ipv4/conf/${WAN_IF}" ]]; then
  echo "ERROR: /proc/sys/net/ipv4/conf/${WAN_IF} not found"
  echo "Available sysctl interfaces:"
  ls /proc/sys/net/ipv4/conf
  exit 1
fi

echo "Using WAN_IF=$WAN_IF"

MTU_VAL="${WG_MTU:-$DEFAULT_MTU}"

if [[ -z "${SERVER_NAME:-}" ]]; then
  SERVER_NAME="$(hostname -f 2>/dev/null || true)"
  [[ -z "$SERVER_NAME" ]] && SERVER_NAME="$(hostname 2>/dev/null || true)"
  [[ -z "$SERVER_NAME" ]] && SERVER_NAME="$(uname -n 2>/dev/null || true)"
  [[ -z "$SERVER_NAME" ]] && SERVER_NAME="server"
fi

if [[ -z "${SERVER_PUBLIC_IP:-}" ]]; then
  echo "Auto-detecting SERVER_PUBLIC_IP..."
  if ! SERVER_PUBLIC_IP="$(detect_public_ip)"; then
    echo "ERROR: Cannot auto-detect public IP from cloud metadata or external services"
    exit 1
  fi
fi

valid_ip "$SERVER_PUBLIC_IP" || {
  echo "ERROR: detected SERVER_PUBLIC_IP is invalid: $SERVER_PUBLIC_IP"
  exit 1
}

echo "SERVER_NAME detected: $SERVER_NAME"
echo "SERVER_PUBLIC_IP detected: $SERVER_PUBLIC_IP"

if [[ -z "${DNS_LIST:-}" ]]; then
  read -r -p "Client DNS list [8.8.8.8, 8.8.4.4]: " DNS_LIST
  DNS_LIST="${DNS_LIST:-8.8.8.8, 8.8.4.4}"
fi

echo
echo "Interface : $WG_IF"
echo "WG Network: ${WG_NET}/24"
echo "Server    : $WG_SERVER_ADDR"
echo "Router    : $ROUTER_ADDR"
echo "PC        : $PC_ADDR"
echo "WAN IF    : $WAN_IF"
echo "Public IP : $SERVER_PUBLIC_IP"
echo "Port      : $WG_LISTENPORT"
echo "MTU       : $MTU_VAL"
echo "OUT_DIR   : $OUT_DIR"
echo

read -r -p "Proceed? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y(es)?$ ]]; then
  echo "Aborted."
  exit 0
fi

if ! command -v wg >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y wireguard iptables curl iproute2
fi

mkdir -p "$WG_DIR" "$OUT_DIR"

gen_keypair() {
  local priv="$1"
  local pub="$2"
  if [[ ! -f "$priv" || ! -f "$pub" ]]; then
    wg genkey | tee "$priv" | wg pubkey > "$pub"
    chmod 600 "$priv"
    chmod 644 "$pub"
  fi
}

gen_psk() {
  local file="$1"
  [[ -f "$file" ]] || wg genpsk > "$file"
  chmod 600 "$file"
}

WG_PRIV="${WG_DIR}/${WG_IF}_privatekey"
WG_PUB="${WG_DIR}/${WG_IF}_publickey"
gen_keypair "$WG_PRIV" "$WG_PUB"
gen_keypair "${OUT_DIR}/router_privatekey" "${OUT_DIR}/router_publickey"
gen_keypair "${OUT_DIR}/pc_privatekey" "${OUT_DIR}/pc_publickey"
gen_psk "${OUT_DIR}/router_psk"
gen_psk "${OUT_DIR}/pc_psk"

KEEPALIVE="${KEEPALIVE:-25}"
WG_USE_MARK_ROUTING="${WG_USE_MARK_ROUTING:-1}"
WG_RP_FILTER="${WG_RP_FILTER:-0}"
WG_TABLE="${WG_TABLE:-}"

ROUTER_ADDR_EFFECTIVE="${ROUTER_ADDR}"
ROUTER_IP_32="${ROUTER_ADDR_EFFECTIVE%/*}"

SERVER_IP_CIDR="${WG_SERVER_ADDR}"
SERVER_IP="${SERVER_IP_CIDR%/*}"
SUBNET="${SERVER_IP%.*}.0/24"



if [[ "${WG_USE_MARK_ROUTING}" == "1" ]]; then
  TABLE_VAL="off"
else
  TABLE_VAL="${WG_TABLE:-${WG_LISTENPORT}}"
fi

WG_CONF="${WG_DIR}/${WG_IF}.conf"

WG_NO="$(echo "$WG_IF" | sed -E 's/^wg([0-9]+)$/\1/')"

if [[ ! "$WG_NO" =~ ^[0-9]+$ ]]; then
  echo "ERROR: cannot extract wg number from interface '$WG_IF'"
  exit 1
fi

WG_FWMARK="$WG_NO"
WG_POLICY_TABLE="$((WG_LISTENPORT + 1))"
WG_RULE_PRIORITY="$((WG_NO + 1))"
POLICY_TABLE="${WG_POLICY_TABLE}"

{
  echo "[Interface]"
  echo "Address = ${WG_SERVER_ADDR}"
  echo "ListenPort = ${WG_LISTENPORT}"
  echo "PrivateKey = $(cat "$WG_PRIV")"
  echo "Table = ${TABLE_VAL}"
  echo "MTU = ${MTU_VAL}"
  echo ""

  if [[ "${WG_USE_MARK_ROUTING}" == "1" ]]; then
    echo "# ========= SYSCTL ========="
    echo "PostUp   = sysctl -w net.ipv4.ip_forward=1"

    if [[ "${WG_RP_FILTER}" == "0" ]]; then
      echo "PostUp   = sysctl -w net.ipv4.conf.all.rp_filter=0"
      echo "PostUp   = sysctl -w net.ipv4.conf.default.rp_filter=0"
      echo "PostUp   = sysctl -w net.ipv4.conf.${WG_IF}.rp_filter=0"
      echo "PostUp   = sysctl -w net.ipv4.conf.${WAN_IF}.rp_filter=0"
    fi

    echo ""
    echo "# ========= FORWARD ========="
    echo "PostUp   = iptables -I FORWARD 1 -i ${WG_IF} -o ${WG_IF} -j ACCEPT"
    echo "PostUp   = iptables -I FORWARD 1 -i ${WG_IF} -o ${WAN_IF} -j ACCEPT"
    echo "PostUp   = iptables -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT"
    echo "PostDown = iptables -D FORWARD -i ${WG_IF} -o ${WG_IF} -j ACCEPT 2>/dev/null || true"
    echo "PostDown = iptables -D FORWARD -i ${WG_IF} -o ${WAN_IF} -j ACCEPT 2>/dev/null || true"
    echo "PostDown = iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true"

    echo ""
    echo "# ========= MARK PC TRAFFIC ========="
    echo "PostUp   = iptables -t mangle -A PREROUTING -i ${WG_IF} -s ${PC_IP_ONLY} -d ${SUBNET} -j ACCEPT"
    echo "PostUp   = iptables -t mangle -A PREROUTING -i ${WG_IF} -s ${PC_IP_ONLY} -j MARK --set-mark ${WG_FWMARK}"
    echo "PostDown = iptables -t mangle -D PREROUTING -i ${WG_IF} -s ${PC_IP_ONLY} -d ${SUBNET} -j ACCEPT 2>/dev/null || true"
    echo "PostDown = iptables -t mangle -D PREROUTING -i ${WG_IF} -s ${PC_IP_ONLY} -j MARK --set-mark ${WG_FWMARK} 2>/dev/null || true"

    echo ""
    echo "# ========= POLICY ROUTING: PC -> Router ========="
    echo "PostUp   = ip rule del fwmark ${WG_FWMARK} lookup ${POLICY_TABLE} priority ${WG_RULE_PRIORITY} 2>/dev/null || true"
    echo "PostUp   = ip rule add fwmark ${WG_FWMARK} lookup ${POLICY_TABLE} priority ${WG_RULE_PRIORITY}"
    echo "PostDown = ip rule del fwmark ${WG_FWMARK} lookup ${POLICY_TABLE} priority ${WG_RULE_PRIORITY} 2>/dev/null || true"

    echo ""
    echo "PostUp   = ip route add ${SUBNET} dev ${WG_IF} table ${POLICY_TABLE} 2>/dev/null || ip route replace ${SUBNET} dev ${WG_IF} table ${POLICY_TABLE}"
    echo "PostUp   = ip route add default via ${ROUTER_IP_32} dev ${WG_IF} table ${POLICY_TABLE} 2>/dev/null || ip route replace default via ${ROUTER_IP_32} dev ${WG_IF} table ${POLICY_TABLE}"
    echo "PostDown = ip route del default via ${ROUTER_IP_32} dev ${WG_IF} table ${POLICY_TABLE} 2>/dev/null || true"
    echo "PostDown = ip route del ${SUBNET} dev ${WG_IF} table ${POLICY_TABLE} 2>/dev/null || true"

    echo ""
    echo "# ========= NAT ========="
    echo "PostUp   = iptables -t nat -A POSTROUTING -s ${SUBNET} -o ${WAN_IF} -j MASQUERADE"
    echo "PostDown = iptables -t nat -D POSTROUTING -s ${SUBNET} -o ${WAN_IF} -j MASQUERADE 2>/dev/null || true"
  else
    echo "# Note: sysctl net.ipv4.ip_forward should be set at host/Docker level"
    echo "PostUp = iptables -A FORWARD -i ${WG_IF} -o ${WG_IF} -j ACCEPT"
    echo "PostUp = iptables -I FORWARD -i ${WAN_IF} -o ${WG_IF} -j ACCEPT"
    echo "PostUp = iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE"
    echo "PostUp = ip rule del from ${PC_IP_ONLY} lookup ${TABLE_VAL} priority ${WG_RULE_PRIORITY} 2>/dev/null || true"
    echo "PostUp = ip rule add from ${PC_IP_ONLY} lookup ${TABLE_VAL} priority ${WG_RULE_PRIORITY}"
    echo ""
    echo "PostDown = iptables -D FORWARD -i ${WG_IF} -o ${WG_IF} -j ACCEPT"
    echo "PostDown = ip rule del from ${PC_IP_ONLY} lookup ${TABLE_VAL} priority ${WG_RULE_PRIORITY}"
    echo "PostDown = iptables -D FORWARD -i ${WAN_IF} -o ${WG_IF} -j ACCEPT"
    echo "PostDown = iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE"
  fi

  echo ""
  echo "# ------ ROUTER (exit node for PC) ------"
  echo "[Peer]"
  echo "PublicKey = $(cat "${OUT_DIR}/router_publickey")"
  echo "PresharedKey = $(cat "${OUT_DIR}/router_psk")"
  echo "AllowedIPs = 0.0.0.0/0"
  echo "PersistentKeepalive = ${KEEPALIVE}"

  echo ""
  echo "# ------ PC ------"
  echo "[Peer]"
  echo "PublicKey = $(cat "${OUT_DIR}/pc_publickey")"
  echo "PresharedKey = $(cat "${OUT_DIR}/pc_psk")"
  echo "AllowedIPs = ${PC_IP_ONLY}/32"
  echo "PersistentKeepalive = ${KEEPALIVE}"
} > "$WG_CONF"

chmod 600 "$WG_CONF"

ROUTER_CONF="${OUT_DIR}/router.conf"
cat > "$ROUTER_CONF" <<EOF
#===============================================================================
# ${ROUTER_NAME}.conf PEER to ${SERVER_NAME}-${SERVER_PUBLIC_IP}
#===============================================================================
[Interface]
PrivateKey = $(cat "${OUT_DIR}/router_privatekey")
Address = ${ROUTER_ADDR}
DNS = ${DNS_LIST}
MTU = ${MTU_VAL}

[Peer]
PublicKey = $(cat "$WG_PUB")
PresharedKey = $(cat "${OUT_DIR}/router_psk")
Endpoint = ${SERVER_PUBLIC_IP}:${WG_LISTENPORT}
AllowedIPs = ${WG_NET}/24
PersistentKeepalive = ${KEEPALIVE}
EOF

chmod 600 "$ROUTER_CONF"

PC_CONF="${OUT_DIR}/pc.conf"
cat > "$PC_CONF" <<EOF
#===============================================================================
# PC(ClientA).conf PEER to ${SERVER_NAME}-${SERVER_PUBLIC_IP}
#===============================================================================
[Interface]
PrivateKey = $(cat "${OUT_DIR}/pc_privatekey")
Address = ${PC_ADDR}
DNS = ${DNS_LIST}
MTU = ${MTU_VAL}

[Peer]
PublicKey = $(cat "$WG_PUB")
PresharedKey = $(cat "${OUT_DIR}/pc_psk")
Endpoint = ${SERVER_PUBLIC_IP}:${WG_LISTENPORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = ${KEEPALIVE}
EOF

chmod 600 "$PC_CONF"

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

if ip link show "$WG_IF" &>/dev/null; then
  wg-quick down "$WG_IF" 2>/dev/null || wg down "$WG_IF" 2>/dev/null || ip link del "$WG_IF" 2>/dev/null || true
fi

cleanup_server_ip

if ! wg-quick up "$WG_IF"; then
  echo "wg-quick up ${WG_IF} failed"
  exit 1
fi

echo
echo "Done."
echo "Server config : ${WG_CONF}"
echo "Router config : ${ROUTER_CONF}"
echo "PC config     : ${PC_CONF}"
echo "FWMARK    : $WG_FWMARK"
echo "POLICY_TB : $WG_POLICY_TABLE"
echo "PRIORITY  : $WG_RULE_PRIORITY"
echo
echo "IMPORTANT:"
echo "1) Make sure cloud firewall/security group allows UDP ${WG_LISTENPORT}"
echo "2) Import/apply router.conf on router"
echo "3) Import/apply pc.conf on PC"
echo "4) Check handshake on server with: wg show"
