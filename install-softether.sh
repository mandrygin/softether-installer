#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SOFTETHER_TAG="${SOFTETHER_TAG:-stable}"
CONTAINER_NAME="${CONTAINER_NAME:-softether-vpn-server}"
VOLUME_NAME="${VOLUME_NAME:-softetherdata}"
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
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  fail "запусти скрипт от root"
fi

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

case "$FORCE" in
  yes|no) ;;
  *) fail "FORCE должен быть yes или no" ;;
esac

echo "=== SoftEther VPN installer ==="

echo "[1/6] Установка Docker и зависимостей..."

mkdir -p /etc/needrestart/conf.d 2>/dev/null || true
echo '$nrconf{restart} = "a";' > /etc/needrestart/conf.d/99-softether-installer.conf 2>/dev/null || true

rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/keyrings/docker.gpg
rm -f /tmp/docker.gpg

apt-get update
apt-get install -y ca-certificates curl openssl software-properties-common

if ! apt-get install -y docker.io; then
  add-apt-repository -y universe
  apt-get update
  apt-get install -y docker.io
fi

systemctl enable --now docker

if ! docker version >/dev/null 2>&1; then
  fail "Docker установлен, но не запускается"
fi

ADMIN_PASS="$(openssl rand -hex 12)"
HUB_PASS="$(openssl rand -hex 12)"
VPN_PASS="$(openssl rand -hex 12)"
IPSEC_PSK="$(openssl rand -hex 12)"

if [ "$SOFTETHER_TAG" != "stable" ] && [ "$ENABLE_L2TP" = "yes" ]; then
  echo "Для версии $SOFTETHER_TAG L2TP отключён. Для L2TP используй stable."
  ENABLE_L2TP="no"
fi

mkdir -p "$INSTALL_DIR"

echo "[2/6] Проверка старой установки..."

if [ "$FORCE" = "yes" ]; then
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "$VOLUME_NAME" 2>/dev/null || true
else
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    fail "контейнер $CONTAINER_NAME уже существует. Для переустановки: curl -fsSL RAW_URL | FORCE=yes bash"
  fi

  if docker volume ls --format '{{.Name}}' | grep -qx "$VOLUME_NAME"; then
    fail "volume $VOLUME_NAME уже существует. Для переустановки: curl -fsSL RAW_URL | FORCE=yes bash"
  fi
fi

echo "[3/6] Запуск SoftEther..."

docker volume create "$VOLUME_NAME" >/dev/null

RUN_ARGS=(
  -d
  --name "$CONTAINER_NAME"
  --hostname "$CONTAINER_NAME"
  --cap-add NET_ADMIN
  --restart unless-stopped
  -p 443:443/tcp
  -p 992:992/tcp
  -p 5555:5555/tcp
  -v "$VOLUME_NAME:/mnt"
)

if [ "$ENABLE_OPENVPN" = "yes" ]; then
  RUN_ARGS+=(-p 1194:1194/udp)
fi

if [ "$ENABLE_L2TP" = "yes" ]; then
  RUN_ARGS+=(-p 500:500/udp)
  RUN_ARGS+=(-p 4500:4500/udp)
  RUN_ARGS+=(-p 1701:1701/udp)
fi

DOCKER_IMAGE="softethervpn/vpnserver:${SOFTETHER_TAG}"

echo "Docker image: $DOCKER_IMAGE"

docker run "${RUN_ARGS[@]}" "$DOCKER_IMAGE"

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
  docker logs "$CONTAINER_NAME" || true
  fail "SoftEther не запустился"
fi

echo "[5/6] Настройка SoftEther..."

docker exec -i "$CONTAINER_NAME" vpncmd localhost /SERVER <<EOF
ServerPasswordSet
${ADMIN_PASS}
${ADMIN_PASS}
HubCreate ${HUB} /PASSWORD:${HUB_PASS}
Hub ${HUB}
UserCreate ${VPN_USER} /GROUP:none /REALNAME:none /NOTE:none
UserPasswordSet ${VPN_USER}
${VPN_PASS}
${VPN_PASS}
SecureNatEnable
EOF

if [ "$ENABLE_OPENVPN" = "yes" ]; then
  docker exec "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" /CMD OpenVpnEnable yes /PORTS:1194
fi

if [ "$ENABLE_L2TP" = "yes" ]; then
  docker exec "$CONTAINER_NAME" vpncmd localhost /SERVER /PASSWORD:"$ADMIN_PASS" /CMD IPsecEnable /L2TP:yes /L2TPRAW:no /ETHERIP:no /PSK:"$IPSEC_PSK" /DEFAULTHUB:"$HUB"
fi

if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q "Status: active"; then
    ufw allow 443/tcp || true
    ufw allow 992/tcp || true
    ufw allow 5555/tcp || true

    if [ "$ENABLE_OPENVPN" = "yes" ]; then
      ufw allow 1194/udp || true
    fi

    if [ "$ENABLE_L2TP" = "yes" ]; then
      ufw allow 500/udp || true
      ufw allow 4500/udp || true
      ufw allow 1701/udp || true
    fi
  fi
fi

echo "[6/6] Сохранение данных..."

PUBLIC_IP="$(curl -4 -fsS https://api.ipify.org || hostname -I | awk '{print $1}')"

cat > /root/softether-install-info.txt <<EOF
SoftEther VPN установлен.

Server IP: ${PUBLIC_IP}
Container: ${CONTAINER_NAME}
Volume: ${VOLUME_NAME}
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
  docker volume rm ${VOLUME_NAME}
EOF

chmod 600 /root/softether-install-info.txt

echo
echo "ГОТОВО."
echo
cat /root/softether-install-info.txt
