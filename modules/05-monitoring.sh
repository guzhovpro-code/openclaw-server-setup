#!/usr/bin/env bash
# ============================================================
# Модуль 5: Telegram Admin Bot (мониторинг)
# Установка бота для управления и мониторинга OpenClaw
# ============================================================
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_HOME="${DEPLOY_HOME:-/home/${DEPLOY_USER}}"
BOT_DIR="${DEPLOY_HOME}/admin-bot"
SERVICE="openclaw-admin-bot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$(dirname "${SCRIPT_DIR}")/configs"

echo "=== Модуль 5: Telegram Admin Bot ==="
echo ""

# --- Проверка: бот уже установлен? ---
if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then
    echo "  ℹ️  Бот уже запущен и работает"
    echo "  Сервис: ${SERVICE}"
    echo "  Файл:   ${BOT_DIR}/bot.py"
    echo ""
    read -p "  Переустановить бота? [y/N]: " REINSTALL
    if [[ ! "${REINSTALL}" =~ ^[yY] ]]; then
        echo ""
        echo "=== Модуль 5 завершён (бот уже установлен) ==="
        exit 0
    fi
    echo ""
fi

# --- [1/5] Зависимости ---
echo "[1/5] Установка зависимостей Python..."
sudo pip3 install "python-telegram-bot[job-queue]" httpx --break-system-packages -q 2>/dev/null || \
    pip3 install "python-telegram-bot[job-queue]" httpx --break-system-packages -q
echo "  ✅ python-telegram-bot и httpx установлены"

# --- [2/5] Копирование бота ---
echo "[2/5] Копирование файлов..."
mkdir -p "${BOT_DIR}"

if [ -f "${CONFIGS_DIR}/bot.py" ]; then
    cp "${CONFIGS_DIR}/bot.py" "${BOT_DIR}/bot.py"
    chmod +x "${BOT_DIR}/bot.py"
    echo "  ✅ bot.py скопирован"
else
    echo "  ❌ Файл configs/bot.py не найден!"
    echo "  Ожидаемый путь: ${CONFIGS_DIR}/bot.py"
    exit 1
fi

# --- [3/5] Настройка .env ---
if [ -f "${BOT_DIR}/.env" ]; then
    echo "[3/5] .env уже существует"
    cat "${BOT_DIR}/.env" | grep -v TOKEN | grep -v "^$"
    echo ""
    read -p "  Обновить .env? [y/N]: " UPDATE_ENV
    if [[ ! "${UPDATE_ENV}" =~ ^[yY] ]]; then
        echo "  Оставляю текущий .env"
    else
        rm "${BOT_DIR}/.env"
    fi
fi

if [ ! -f "${BOT_DIR}/.env" ]; then
    echo "[3/5] Настройка .env..."
    echo ""
    echo "  Для создания Telegram-бота:"
    echo "  1. Открой @BotFather в Telegram"
    echo "  2. Отправь /newbot"
    echo "  3. Скопируй токен"
    echo ""
    read -p "  Telegram Bot Token: " BOT_TOKEN
    echo ""
    echo "  Чтобы узнать свой Telegram ID:"
    echo "  Отправь /start боту @userinfobot"
    echo ""
    read -p "  Твой Telegram User ID: " TG_ID
    echo ""

    # Попробовать определить имя контейнера
    CONTAINER_NAME="repo-openclaw-gateway-1"
    DETECTED=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i openclaw | grep -i gateway | head -1 || true)
    if [ -n "${DETECTED}" ]; then
        CONTAINER_NAME="${DETECTED}"
    fi

    cat > "${BOT_DIR}/.env" << EOF
ADMIN_BOT_TOKEN=${BOT_TOKEN}
ALLOWED_TELEGRAM_ID=${TG_ID}
OPENCLAW_CONTAINER=${CONTAINER_NAME}
OPENCLAW_HEALTH_URL=http://127.0.0.1:18789/healthz
EOF
    chmod 600 "${BOT_DIR}/.env"
    echo "  ✅ .env создан (контейнер: ${CONTAINER_NAME})"
fi

# --- [4/5] Systemd-сервис ---
echo "[4/5] Настройка systemd..."

sudo tee /etc/systemd/system/${SERVICE}.service > /dev/null << EOF
[Unit]
Description=OpenClaw Admin Telegram Bot
After=network.target docker.service

[Service]
Type=simple
User=${DEPLOY_USER}
WorkingDirectory=${BOT_DIR}
EnvironmentFile=${BOT_DIR}/.env
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 ${BOT_DIR}/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE}"
sudo systemctl restart "${SERVICE}"
echo "  ✅ Сервис ${SERVICE} запущен"

# --- [5/5] Проверка ---
echo "[5/5] Проверка..."
sleep 3

if sudo systemctl is-active --quiet "${SERVICE}"; then
    echo ""
    echo "  ✅ Бот работает!"
    echo ""
    echo "  Отправь /start боту в Telegram"
    echo ""
    echo "  Команды:"
    echo "    /start  — панель управления"
    echo "    /report — полный отчёт о сервере"
    echo ""
    echo "  Мониторинг (автоматический):"
    echo "    🔴 Алерт при падении контейнера"
    echo "    🔴 Алерт при сбое healthcheck"
    echo "    🛡 Уведомление о банах fail2ban"
    echo "    🔴 Алерт при заполнении диска (≥80%)"
    echo "    🔴 Алерт при высокой нагрузке RAM/CPU"
    echo ""
    echo "  Управление сервисом:"
    echo "    sudo systemctl status ${SERVICE}"
    echo "    sudo journalctl -u ${SERVICE} -f"
else
    echo ""
    echo "  ❌ Ошибка запуска. Проверь:"
    echo "    sudo journalctl -u ${SERVICE} -n 30"
fi

echo ""
echo "=== Модуль 5 завершён ==="
