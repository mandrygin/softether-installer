#!/usr/bin/env bash
set -Eeuo pipefail

SOFTETHER_TAG="${SOFTETHER_TAG:-stable}"
CONTAINER_NAME="${CONTAINER_NAME:-softether-vpn-server}"
INSTALL_DIR="${INSTALL_DIR:-/opt/softether}"
HUB="${HUB:-VPN}"
VPN_USER="${VPN_USER:-vpnuser}"
ENABLE_L2TP="${ENABLE_L2TP:-yes}"
ENABLE_OPENVPN="${ENABLE_OPENVPN:-yes}"
FORCE="${FORCE:-no}"

if [[ "$EUID" -ne 0 ]]; then
echo "Запусти от root"
exit 1
fi

echo "=== SoftEther VPN installer ==="

gen_pass() {
openssl rand -hex 12
}

install_docker() {
echo "[1/6] Проверка Docker..."

apt-get update
apt-get install -y ca-certificates curl gnupg openssl

if command -v docker >/dev/null 2>&1; then
systemctl enable --now docker || true
return
fi

echo "Docker не найден, ставлю..."

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg
gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

UBUNTU_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' 
"$(dpkg --print-architecture)" 
"$UBUNTU_CODENAME" 
> /etc/apt/sources.list.d/docker.list

apt-get update

if ! apt-get install -y docker-ce docker-ce-cli containerd.io; then
echo "docker-ce не поставился, пробую docker.io..."
apt-get install -y docker.io
fi

systemctl enable --now docker
}

install_docker

ADMIN_PASS="${ADMIN_PASS:-$(gen_pass)}"
HUB_PASS="${HUB_PASS:-$(gen_pass)}"
VPN_PASS="${VPN_PASS:-$(gen_pass)}"
IPSEC_PSK="${IPSEC_PSK:-$(gen_pass)}"

if [[ "$SOFTETHER_TAG" != "stable" && "$ENABLE_L2TP" == "yes" ]]; then
echo "Для версии ${SOFTETHER_TAG} L2TP отключён."
ENABLE_L2TP="no"
fi

mkdir -p "$INSTALL_DIR"

echo "[2/6] Проверка старого контейнера..."

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
if [[ "$FORCE" == "yes" ]]; then
docker rm -f "$CONTAINER_NAME" || true
else
echo "Контейнер $CONTAINER_NAME уже существует."
echo "Для переустановки:"
echo "FORCE=yes curl -fsSL URL | bash"
exit 1
fi
fi

echo "[3/6] Запуск SoftEther..."

docker volume create softetherdata >/dev/null

RUN_ARGS=(
-d
--name "$CONTAINER_NAME"
--hostname "$CONTAINER_NAME"
--cap-add NET_ADMIN
--restart unless-stopped
-p 443:443/tcp
-p 992:992/tcp
-p 5555:5555/tcp
-v softetherdata:/mnt
)

if [[ "$ENABLE_OPENVPN" == "yes" ]]; then
RUN_ARGS+=(-p 1194:1194/udp)
fi

if [[ "$ENABLE_L2TP" == "yes" ]]; then
RUN_ARGS+=(-p 500:500/udp)
RUN_ARGS+=(-p 4500:4500/udp)
RUN_ARGS+=(-p 1701:1701/udp)
fi

RUN_ARGS+=("softethervpn/vpnserver:${SOFTETHER_TAG}")

docker run "${RUN_ARGS[@]}"

echo "[4/6] Ожидание запуска..."

for i in {1..30}; do
if docker exec "$CONTAINER_NAME" vpncmd /TOOLS /CMD About >/dev/null 2>&1; then
break
fi

if [[ "$i" == "30" ]]; then
echo "SoftEther не запустился."
docker logs "$CONTAINER_NAME"
exit 1
fi

sleep 2
done

echo "[5/6] Настройка SoftEther..."

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

echo "[6/6] Сохранение данных..."

PUBLIC_IP="$(curl -4 -fsS https://api.ipify.org || hostname -I | awk '{print $1}')"

cat > /root/softether-install-info.txt <<EOF
SoftEther VPN установлен.

Server IP: ${PUBLIC_IP}
Container: ${CONTAINER_NAME}
Install dir: ${INSTALL_DIR}

Admin:
Host: ${PUBLIC_IP}
Port: 5555
Password: ${ADMIN_PASS}

VPN:
Hub: ${HUB}
User: ${VPN_USER}
Password: ${VPN_PASS}

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

Commands:
docker ps
docker logs ${CONTAINER_NAME}
docker exec -it ${CONTAINER_NAME} vpncmd localhost /SERVER /PASSWORD:${ADMIN_PASS}
docker rm -f ${CONTAINER_NAME}
EOF

chmod 600 /root/softether-install-info.txt

echo
echo "ГОТОВО."
echo
cat /root/softether-install-info.txt
