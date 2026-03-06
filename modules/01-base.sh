#!/usr/bin/env bash
# ============================================================
# Модуль 1: Подготовка VPS
# Создание пользователя, SSH-ключи, базовые пакеты
# ============================================================
set -euo pipefail

echo "=== Модуль 1: Подготовка VPS ==="
echo ""

# --- Проверка: запущено от root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ОШИБКА: Этот скрипт нужно запускать от root"
    exit 1
fi

# --- Обновление системы ---
echo "[1/5] Обновление системы..."
apt update -qq && apt upgrade -y -qq
echo "  ✅ Система обновлена"

# --- Базовые пакеты ---
echo "[2/5] Установка базовых пакетов..."
apt install -y -qq curl git htop jq unzip ufw fail2ban
echo "  ✅ Пакеты установлены"

# --- Создание пользователя ---
DEPLOY_USER="${DEPLOY_USER:-deploy}"
echo "[3/5] Создание пользователя ${DEPLOY_USER}..."

if id "${DEPLOY_USER}" &>/dev/null; then
    echo "  ℹ️  Пользователь ${DEPLOY_USER} уже существует"
else
    adduser "${DEPLOY_USER}" --gecos "" --disabled-password
    echo "  ✅ Пользователь ${DEPLOY_USER} создан"
fi

# Sudo без пароля
usermod -aG sudo "${DEPLOY_USER}"
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEPLOY_USER}"
chmod 440 "/etc/sudoers.d/${DEPLOY_USER}"
echo "  ✅ Sudo NOPASSWD настроен"

# --- SSH-ключи ---
echo "[4/5] Настройка SSH-ключей..."
DEPLOY_HOME=$(eval echo "~${DEPLOY_USER}")
SSH_DIR="${DEPLOY_HOME}/.ssh"
mkdir -p "${SSH_DIR}"

if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys "${SSH_DIR}/authorized_keys"
    echo "  ✅ SSH-ключи скопированы от root"
else
    echo "  ⚠️  У root нет authorized_keys."
    echo "     Добавь свой публичный ключ вручную:"
    echo "     echo 'ssh-ed25519 AAAA...' >> ${SSH_DIR}/authorized_keys"
fi

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chmod 600 "${SSH_DIR}/authorized_keys" 2>/dev/null || true

# --- Проверка ---
echo "[5/5] Проверка..."
echo "  Пользователь: $(id ${DEPLOY_USER})"
echo "  SSH-ключи: $(wc -l < ${SSH_DIR}/authorized_keys 2>/dev/null || echo 0) шт."
echo "  Sudo: $(sudo -l -U ${DEPLOY_USER} 2>/dev/null | grep -c NOPASSWD || echo 0) правил"
echo ""
echo "=== Модуль 1 завершён ==="
echo ""
echo "Теперь проверь SSH-подключение от ${DEPLOY_USER}:"
echo "  ssh ${DEPLOY_USER}@$(hostname -I | awk '{print $1}')"
