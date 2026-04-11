#!/bin/bash

set -e

echo "======================================"
echo " VPNCN2 WireGuard Setup"
echo "======================================"

DEFAULT_IF="wg100"
DEFAULT_WG_IP="10.100.1.254/24"
DEFAULT_ROUTER_IP="10.100.1.1"
DEFAULT_PC_IP="10.100.1.253"
DEFAULT_PORT="51100"

########################################
# IPv4 validator
########################################

valid_ip () {
    local ip=$1
    local stat=1

    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

########################################
# INTERFACE INPUT
########################################

while true; do

read -p "WireGuard interface [$DEFAULT_IF]: " WG_IF
WG_IF=${WG_IF:-$DEFAULT_IF}

if [[ ! $WG_IF =~ ^wg ]]; then
 echo "ERROR: interface must start with wg"
 continue
fi

if ip link show "$WG_IF" &>/dev/null; then
 echo "ERROR: interface already exists"
 continue
fi

if [ -f "/etc/wireguard/$WG_IF.conf" ]; then
 echo "ERROR: config /etc/wireguard/$WG_IF.conf already exists"
 continue
fi

break
done

########################################
# WG LAN IP
########################################

while true; do

read -p "WG LAN IP [$DEFAULT_WG_IP]: " WG_IP_LAN
WG_IP_LAN=${WG_IP_LAN:-$DEFAULT_WG_IP}

if ! [[ $WG_IP_LAN =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$ ]]; then
 echo "ERROR: must be CIDR format (example 10.100.1.254/24)"
 continue
fi

WG_SERVER_IP=$(echo $WG_IP_LAN | cut -d/ -f1)

valid_ip "$WG_SERVER_IP" || { echo "ERROR: invalid IP"; continue; }

WG_PREFIX=$(echo $WG_SERVER_IP | cut -d. -f1-3)
WG_NET="$WG_PREFIX.0"

# check subnet conflict
CONFLICT=false

for conf in /etc/wireguard/*.conf; do
 [ -e "$conf" ] || continue

 EXIST_IP=$(grep Address "$conf" | head -n1 | awk '{print $3}' | cut -d/ -f1)
 EXIST_PREFIX=$(echo $EXIST_IP | cut -d. -f1-3)

 if [ "$EXIST_PREFIX" == "$WG_PREFIX" ]; then
  echo "ERROR: WG subnet conflict with $conf"
  CONFLICT=true
 fi
done

$CONFLICT && continue

break
done

########################################
# ROUTER IP
########################################

while true; do

read -p "Router WG IP [$DEFAULT_ROUTER_IP]: " ROUTER_IP
ROUTER_IP=${ROUTER_IP:-$DEFAULT_ROUTER_IP}

valid_ip "$ROUTER_IP" || { echo "ERROR: invalid IPv4"; continue; }

ROUTER_PREFIX=$(echo $ROUTER_IP | cut -d. -f1-3)

if [ "$ROUTER_PREFIX" != "$WG_PREFIX" ]; then
 echo "ERROR: Router IP must be inside $WG_PREFIX.0/24"
 continue
fi

break
done

########################################
# PC IP
########################################

while true; do

read -p "PC WG IP [$DEFAULT_PC_IP]: " PC_IP
PC_IP=${PC_IP:-$DEFAULT_PC_IP}

valid_ip "$PC_IP" || { echo "ERROR: invalid IPv4"; continue; }

PC_PREFIX=$(echo $PC_IP | cut -d. -f1-3)

if [ "$PC_PREFIX" != "$WG_PREFIX" ]; then
 echo "ERROR: PC IP must be inside $WG_PREFIX.0/24"
 continue
fi

if [ "$PC_IP" == "$ROUTER_IP" ]; then
 echo "ERROR: PC IP cannot equal Router IP"
 continue
fi

break
done

########################################
# PORT
########################################

while true; do

read -p "WG Listen Port [$DEFAULT_PORT]: " WG_PORT
WG_PORT=${WG_PORT:-$DEFAULT_PORT}

if ss -lntu | grep -q ":$WG_PORT"; then
 echo "ERROR: port already in use"
 continue
fi

break
done

########################################
# NETWORK INFO
########################################

WAN_IF=$(ip route get 1 | awk '{print $5; exit}')
WAN_IP=$(curl -4 -s https://api.ipify.org)

echo
echo "Interface : $WG_IF"
echo "WG Network: $WG_NET/24"
echo "Server IP : $WG_SERVER_IP"
echo "Router IP : $ROUTER_IP"
echo "PC IP     : $PC_IP"
echo "WAN IF    : $WAN_IF"
echo "Public IP : $WAN_IP"
echo

########################################
# INSTALL WG
########################################

if ! command -v wg >/dev/null; then
 apt update
 apt install -y wireguard iptables curl
fi

########################################
# DIR
########################################

mkdir -p /etc/wireguard/vpncn2
chmod 700 /etc/wireguard

########################################
# KEYS
########################################

echo "Generating keys..."

SERVER_PRIVATE=$(wg genkey)
SERVER_PUBLIC=$(echo $SERVER_PRIVATE | wg pubkey)

ROUTER_PRIVATE=$(wg genkey)
ROUTER_PUBLIC=$(echo $ROUTER_PRIVATE | wg pubkey)

PC_PRIVATE=$(wg genkey)
PC_PUBLIC=$(echo $PC_PRIVATE | wg pubkey)

########################################
# SERVER CONFIG
########################################

cat > /etc/wireguard/$WG_IF.conf <<EOF
[Interface]
Address = $WG_IP_LAN
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE
Table = off

PostUp = sysctl -w net.ipv4.ip_forward=1 || true

PostUp = iptables -C FORWARD -i $WG_IF -o $WG_IF -j ACCEPT || iptables -I FORWARD 1 -i $WG_IF -o $WG_IF -j ACCEPT
PostUp = iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT || iptables -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT

PostUp = iptables -t mangle -C PREROUTING -i $WG_IF -s $PC_IP -j MARK --set-mark 11 || iptables -t mangle -A PREROUTING -i $WG_IF -s $PC_IP -j MARK --set-mark 11

PostUp = ip rule add fwmark 11 table 51820 priority 100 || true
PostUp = ip route add $WG_NET/24 dev $WG_IF table 51820 || true
PostUp = ip route add default via $ROUTER_IP dev $WG_IF table 51820 || true

PostDown = iptables -t mangle -D PREROUTING -i $WG_IF -s $PC_IP -j MARK --set-mark 11 || true
PostDown = ip rule del fwmark 11 table 51820 priority 100 || true

[Peer]
PublicKey = $ROUTER_PUBLIC
AllowedIPs = $ROUTER_IP/32,0.0.0.0/0
PersistentKeepalive = 25

[Peer]
PublicKey = $PC_PUBLIC
AllowedIPs = $PC_IP/32
PersistentKeepalive = 25
EOF

########################################
# PC CONFIG
########################################

cat > /etc/wireguard/vpncn2/pc.conf <<EOF
# Connect your PC to WG server by this configuration to connect interner through Router

[Interface]
Address = $PC_IP/24
PrivateKey = $PC_PRIVATE
DNS = 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $WAN_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

########################################
# ROUTER CONFIG
########################################

cat > /etc/wireguard/vpncn2/router.conf <<EOF
# Please upload this configuration to VPNCN2 to push to Router to establish WG tunnel for PC

[Interface]
Address = $ROUTER_IP/32
PrivateKey = $ROUTER_PRIVATE
DNS = 1.1.1.1,8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $WAN_IP:$WG_PORT
AllowedIPs = $WG_NET/24
PersistentKeepalive = 25
EOF

########################################
# START WG
########################################

systemctl enable wg-quick@$WG_IF
systemctl start wg-quick@$WG_IF

echo
echo "======================================"
echo " WireGuard Status"
echo "======================================"

wg show

echo
echo "======================================"
echo " PC CONFIG"
echo "======================================"

cat /etc/wireguard/vpncn2/pc.conf

echo
echo "======================================"
echo " ROUTER CONFIG"
echo "======================================"

cat /etc/wireguard/vpncn2/router.conf
