#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SOFTETHER_TAG="${SOFTETHER_TAG:-stable}"
CONTAINER_NAME="${CONTAINER_NAME:-softether-vpn-server}"
INSTALL_DIR="${INSTALL_DIR:-/opt/softether}"
HUB="${HUB:-VPN}"
VPN_USER="${VPN_USER:-vpnuser}"
ENABLE_L2TP="${ENABLE_L2TP:-yes}"
ENABLE_OPENVPN="${ENABLE_OPENVPN:-yes}"
FORCE="${FORCE:-no}"

fail() {
echo
echo "ОШИБКА: $1"
echo
if command -v docker >/dev/null 2>&1; then
docker ps -a --filter "name=${CONTAINER_NAME}" || true
docker logs --tail 80 "${CONTAINER_NAME}" 2>/dev/null || true
fi
exit 1
}

on_error() {
echo
echo "Скрипт остановился на строке: $1"
if command -v docker >/dev/null 2>&1; then
docker logs --tail 80 "${CONTAINER_NAME}" 2>/dev/null || true
fi
}

trap 'on_error $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
fail "запусти от root"
fi

echo "=== SoftEther VPN installer ==="

case "$SOFTETHER_TAG" in
stable|5.2.5188) ;;
*) fail "SOFTETHER_TAG должен быть stable или 5.2.5188" ;;
esac

case "$ENABLE_L2TP" in
yes|no) ;;
*) fail "ENABLE_L2TP должен быть yes или no" ;;
esac

case "$ENABLE_OPENVPN" in
yes|no) ;;
*) fail "ENABLE_OPENVPN должен быть yes или no" ;;
esac

echo "[1/6] Подготовка Ubuntu и установка Docker..."

rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/keyrings/docker.gpg
rm -f /tmp/docker.gpg

apt-get update
apt-get install -y ca-certificates curl openssl lsb-release software-properties-common

if ! apt-cache policy docker.io | grep -q "Candidate:"; then
add-apt-repository -y universe || true
apt-get update
fi

if apt-cache policy docker.io | grep -q "Candidate: (none)"; then
add-apt-repository -y universe || true
apt-get update
fi

apt-get install -y docker.io

systemctl enable --now docker

if ! docker version >/dev/null 2>&1; then
fail "Docker установлен, но не запускается"
fi

ADMIN_PASS="$(openssl rand -hex 12)"
HUB_PASS="$(openssl rand -hex 12)"
VPN_PASS="$(openssl rand -hex 12)"
IPSEC_PSK="$(openssl rand -hex 12)"

if [ "$SOFTETHER_TAG" != "stable" ] && [ "$ENABLE_L2TP" = "yes" ]; then
echo "Для версии ${SOFTETHER_TAG} L2TP отключён. Для L2TP используй stable."
ENABLE_L2TP="no"
fi

mkdir -p "$INSTALL_DIR"

echo "[2/6] Проверка старой установки..."

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
if [ "$FORCE" = "yes" ]; then
echo "Удаляю старый контейнер..."
docker rm -f "$CONTAINER_NAME" || true
docker volume rm softetherdata 2>/dev/null || true
else
echo "Контейнер ${CONTAINER_NAME} уже существует."
echo "Для переустановки запусти:"
echo "curl -fsSL RAW_URL | FORCE=yes bash"
exit 1
fi
fi

echo "[3/6] Запуск SoftEther..."

docker volume create softetherdata >/dev/null

DOCKER_PORTS="-p 443:443/tcp -p 992:992/tcp -p 5555:5555/tcp"

if [ "$ENABLE_OPENVPN" = "yes" ]; then
DOCKER_PORTS="$DOCKER_PORTS -p 1194:1194/udp"
fi

if [ "$ENABLE_L2TP" = "yes" ]; then
DOCKER_PORTS="$DOCKER_PORTS -p 500:500/udp -p 4500:4500/udp -p 1701:1701/udp"
fi

docker run -d --name "$CONTAINER_NAME" --hostname "$CONTAINER_NAME" --cap-add NET_ADMIN --restart unless-stopped $DOCKER_PORTS -v softetherdata:/mnt "softethervpn/vpnserver:$SOFTETHER_TAG"

echo "[4/6] Ожидание запуска SoftEther..."

READY="no"

for i in $(seq 1 60); do
if docker exec "$CONTAINER_NAME" vpncmd localhost /SERVER /CMD ServerInfoGet >/dev/null 2>&1; then
READY="yes"
break
fi
sleep 2
done

if [ "$READY" != "yes" ]; then
fail "SoftEther не запустился"
fi

echo "[5/6] Настройка SoftEther..."

printf "%s\n%s\n" "$ADMIN_PASS" "$ADMIN_PASS" | docker exec -i "$CONTAINER_NAME" vpncmd localhost /SERVER /CMD ServerPasswordSet

docker exec "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" /CMD HubCreate "$HUB" /PASSWORD:"$HUB_PASS"

docker exec "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" /HUB:"$HUB" /CMD UserCreate "$VPN_USER" /GROUP:none /REALNAME:none /NOTE:none

docker exec "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" /HUB:"$HUB" /CMD UserPasswordSet "$VPN_USER" /PASSWORD:"$VPN_PASS"

docker exec "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" /HUB:"$HUB" /CMD SecureNatEnable

if [ "$ENABLE_OPENVPN" = "yes" ]; then
docker exec "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" /CMD OpenVpnEnable yes /PORTS:1194
fi

if [ "$ENABLE_L2TP" = "yes" ]; then
docker exec "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" /CMD IPsecEnable /L2TP:yes /L2TPRAW:no /ETHERIP:no /PSK:"$IPSEC_PSK" /DEFAULTHUB:"$HUB"
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

L2TP/IPsec:
Enabled: ${ENABLE_L2TP}
Server: ${PUBLIC_IP}
Username: ${VPN_USER}
Password: ${VPN_PASS}
IPsec PSK: ${IPSEC_PSK}

OpenVPN:
Enabled: ${ENABLE_OPENVPN}
Server: ${PUBLIC_IP}
Port: 1194/udp

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
