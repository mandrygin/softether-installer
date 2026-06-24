#!/usr/bin/env bash
set -euo pipefail

# ===== Настройки по умолчанию =====

SOFTETHER_TAG="${SOFTETHER_TAG:-stable}"       # stable или 5.2.5188
CONTAINER_NAME="${CONTAINER_NAME:-softether-vpn-server}"
INSTALL_DIR="${INSTALL_DIR:-/opt/softether}"
HUB="${HUB:-VPN}"
VPN_USER="${VPN_USER:-vpnuser}"
ENABLE_L2TP="${ENABLE_L2TP:-yes}"             # yes/no
ENABLE_OPENVPN="${ENABLE_OPENVPN:-yes}"       # yes/no

# ===== Проверка root =====

if [[ "$EUID" -ne 0 ]]; then
echo "Запусти от root: sudo bash $0"
exit 1
fi

echo "[1/6] Установка зависимостей..."
apt-get update
apt-get install -y docker.io docker-compose-plugin curl openssl ca-certificates

systemctl enable --now docker

# ===== Генерация паролей =====

gen_pass() {
openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24
}

ADMIN_PASS="${ADMIN_PASS:-$(gen_pass)}"
HUB_PASS="${HUB_PASS:-$(gen_pass)}"
VPN_PASS="${VPN_PASS:-$(gen_pass)}"
IPSEC_PSK="${IPSEC_PSK:-$(gen_pass)}"

# ===== Безопасность для 5.2.5188 =====

if [[ "$SOFTETHER_TAG" != "stable" && "$ENABLE_L2TP" == "yes" ]]; then
echo "ВНИМАНИЕ: для SOFTETHER_TAG=$SOFTETHER_TAG L2TP будет отключён."
echo "Используй stable, если нужен L2TP/IPsec."
ENABLE_L2TP="no"
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "[2/6] Создание docker-compose.yml..."

cat > docker-compose.yml <<EOF
services:
softether:
image: softethervpn/vpnserver:${SOFTETHER_TAG}
container_name: ${CONTAINER_NAME}
hostname: ${CONTAINER_NAME}
cap_add:
- NET_ADMIN
restart: unless-stopped
ports:
- "443:443/tcp"
- "992:992/tcp"
- "5555:5555/tcp"
EOF

if [[ "$ENABLE_OPENVPN" == "yes" ]]; then
cat >> docker-compose.yml <<EOF
- "1194:1194/udp"
EOF
fi

if [[ "$ENABLE_L2TP" == "yes" ]]; then
cat >> docker-compose.yml <<EOF
- "500:500/udp"
- "4500:4500/udp"
- "1701:1701/udp"
EOF
fi

cat >> docker-compose.yml <<EOF
volumes:
- softetherdata:/mnt

volumes:
softetherdata:
EOF

echo "[3/6] Запуск контейнера..."
docker compose up -d

echo "[4/6] Ожидание запуска SoftEther..."
sleep 10

echo "[5/6] Первичная настройка SoftEther..."

docker exec -i "$CONTAINER_NAME" vpncmd localhost /SERVER <<EOF
ServerPasswordSet
${ADMIN_PASS}
${ADMIN_PASS}
HubCreate ${HUB}
${HUB_PASS}
${HUB_PASS}
Hub ${HUB}
UserCreate ${VPN_USER} /GROUP:none /REALNAME:none /NOTE:none
UserPasswordSet ${VPN_USER}
${VPN_PASS}
${VPN_PASS}
SecureNatEnable
EOF

if [[ "$ENABLE_OPENVPN" == "yes" ]]; then
docker exec -i "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" <<EOF
OpenVpnEnable yes /PORTS:1194
OpenVpnMakeConfig /mnt/openvpn_config.zip
EOF

docker cp "${CONTAINER_NAME}:/mnt/openvpn_config.zip" "${INSTALL_DIR}/openvpn_config.zip" || true
fi

if [[ "$ENABLE_L2TP" == "yes" ]]; then
docker exec -i "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" <<EOF
IPsecEnable /L2TP:yes /L2TPRAW:no /ETHERIP:no /PSK:${IPSEC_PSK} /DEFAULTHUB:${HUB}
EOF
fi

echo "[6/6] Сохранение данных доступа..."

PUBLIC_IP="$(curl -4 -fsS https://api.ipify.org || hostname -I | awk '{print $1}')"

cat > /root/softether-install-info.txt <<EOF
SoftEther VPN установлен.

Server IP: ${PUBLIC_IP}
Docker container: ${CONTAINER_NAME}
Install dir: ${INSTALL_DIR}

Admin port: 5555
Admin password: ${ADMIN_PASS}

Hub: ${HUB}
Hub password: ${HUB_PASS}

VPN user: ${VPN_USER}
VPN password: ${VPN_PASS}

OpenVPN:
Enabled: ${ENABLE_OPENVPN}
Port: 1194/udp
Config: ${INSTALL_DIR}/openvpn_config.zip

L2TP/IPsec:
Enabled: ${ENABLE_L2TP}
Server: ${PUBLIC_IP}
Username: ${VPN_USER}
Password: ${VPN_PASS}
IPsec PSK: ${IPSEC_PSK}

Useful commands:
docker logs ${CONTAINER_NAME}
docker exec -it ${CONTAINER_NAME} vpncmd localhost /SERVER /PASSWORD:${ADMIN_PASS}
cd ${INSTALL_DIR} && docker compose ps
cd ${INSTALL_DIR} && docker compose down
EOF

chmod 600 /root/softether-install-info.txt

echo
echo "ГОТОВО."
echo "Данные доступа сохранены в:"
echo "  /root/softether-install-info.txt"
echo
cat /root/softether-install-info.txt
