#!/usr/bin/env bash
# ============================================================
# Модуль 3: Установка Docker
# Docker Engine + Compose plugin
# ============================================================
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"

echo "=== Модуль 3: Docker ==="
echo ""

# --- Проверка: Docker уже установлен? ---
if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version)
    echo "  ℹ️  Docker уже установлен: ${DOCKER_VER}"

    if docker compose version &>/dev/null; then
        COMPOSE_VER=$(docker compose version --short)
        echo "  ℹ️  Compose plugin: v${COMPOSE_VER}"
    fi

    # Проверить группу docker
    if groups "${DEPLOY_USER}" 2>/dev/null | grep -q docker; then
        echo "  ℹ️  ${DEPLOY_USER} уже в группе docker"
    else
        sudo usermod -aG docker "${DEPLOY_USER}"
        echo "  ✅ ${DEPLOY_USER} добавлен в группу docker"
        echo "  ⚠️  Перезайди в SSH для применения"
    fi

    echo ""
    echo "=== Модуль 3 завершён (Docker уже был установлен) ==="
    exit 0
fi

# --- Установка Docker ---
echo "[1/3] Установка Docker Engine..."

# Удалить старые версии
sudo apt remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

# Определяем дистрибутив (ubuntu или debian)
DISTRO_ID=$(. /etc/os-release && echo "${ID}")
if [[ "${DISTRO_ID}" != "ubuntu" && "${DISTRO_ID}" != "debian" ]]; then
    echo "  ⚠️  Неизвестный дистрибутив: ${DISTRO_ID}, пробуем как ubuntu"
    DISTRO_ID="ubuntu"
fi

# Репозиторий Docker
sudo apt update -qq
sudo apt install -y -qq ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update -qq
sudo apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
echo "  ✅ Docker установлен: $(docker --version)"

# --- Группа docker ---
echo "[2/3] Настройка доступа..."
sudo usermod -aG docker "${DEPLOY_USER}"
echo "  ✅ ${DEPLOY_USER} добавлен в группу docker"

# --- Проверка ---
echo "[3/3] Проверка..."
sudo docker run --rm hello-world > /dev/null 2>&1 && echo "  ✅ Docker работает" || echo "  ❌ Docker не работает"
echo "  Docker: $(docker --version)"
echo "  Compose: $(docker compose version 2>/dev/null || echo 'не установлен')"
echo ""
echo "=== Модуль 3 завершён ==="
echo ""
echo "⚠️  Перезайди в SSH чтобы группа docker применилась:"
echo "   exit && ssh ${DEPLOY_USER}@$(hostname -I | awk '{print $1}')"
