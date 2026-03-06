#!/usr/bin/env bash
# ============================================================
# Модуль 4: Развёртывание OpenClaw
# Клонирование, сборка, настройка, проверка
# ============================================================
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_HOME="${DEPLOY_HOME:-/home/${DEPLOY_USER}}"
OPENCLAW_DIR="/srv/openclaw"
REPO_DIR="${OPENCLAW_DIR}/repo"
OPENCLAW_REPO="${OPENCLAW_REPO:-https://github.com/nicepkg/openclaw.git}"

echo "=== Модуль 4: OpenClaw ==="
echo ""

# --- Проверка: OpenClaw уже установлен? ---
if [ -f "${REPO_DIR}/docker-compose.yml" ]; then
    echo "  ℹ️  OpenClaw уже установлен в ${REPO_DIR}"
    if docker ps --filter name=repo-openclaw-gateway-1 --format '{{.Status}}' 2>/dev/null | grep -q "Up"; then
        echo "  ℹ️  Gateway работает"
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/healthz --max-time 5 2>/dev/null || echo "000")
        echo "  ℹ️  Healthcheck: HTTP ${HTTP_CODE}"
    else
        echo "  ⚠️  Gateway не запущен"
    fi
    echo ""
    echo "=== Модуль 4 завершён (OpenClaw уже был установлен) ==="
    exit 0
fi

# --- [1/8] Структура каталогов ---
echo "[1/8] Создание структуры каталогов..."
sudo mkdir -p "${OPENCLAW_DIR}"/{config,config-backup,logs,secrets,workspace}
sudo chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${OPENCLAW_DIR}"
echo "  ✅ Каталоги созданы"

# --- [2/8] Клонирование репозитория ---
echo "[2/8] Клонирование OpenClaw..."
if [ ! -d "${REPO_DIR}" ]; then
    git clone "${OPENCLAW_REPO}" "${REPO_DIR}"
    echo "  ✅ Репозиторий склонирован"
else
    echo "  ℹ️  Репозиторий уже существует"
fi

# --- [3/8] Запуск docker-setup.sh ---
echo "[3/8] Запуск docker-setup.sh (интерактивный onboarding)..."
echo ""
echo "  ⚠️  Сейчас запустится интерактивный скрипт."
echo "  Он задаст вопросы и создаст .env файл."
echo ""
read -p "  Нажми Enter для продолжения (или Ctrl+C для отмены)..."
cd "${REPO_DIR}" && bash docker-setup.sh
echo ""
echo "  ✅ docker-setup.sh завершён"

# --- [4/8] Проверка .env ---
echo "[4/8] Проверка .env..."
if [ -f "${REPO_DIR}/.env" ]; then
    echo "  ✅ .env создан"

    # Проверить что порты привязаны к localhost
    if grep -q "OPENCLAW_GATEWAY_PORT=127.0.0.1:" "${REPO_DIR}/.env"; then
        echo "  ✅ Gateway привязан к localhost"
    else
        echo "  ⚠️  Gateway может быть доступен извне!"
        echo "  Рекомендуется: OPENCLAW_GATEWAY_PORT=127.0.0.1:18789"
        read -p "  Исправить на localhost? [y/N]: " FIX_PORT
        if [[ "${FIX_PORT}" =~ ^[yY] ]]; then
            sed -i 's/^OPENCLAW_GATEWAY_PORT=.*/OPENCLAW_GATEWAY_PORT=127.0.0.1:18789/' "${REPO_DIR}/.env"
            sed -i 's/^OPENCLAW_BRIDGE_PORT=.*/OPENCLAW_BRIDGE_PORT=127.0.0.1:18790/' "${REPO_DIR}/.env"
            echo "  ✅ Порты привязаны к localhost"
        fi
    fi
else
    echo "  ❌ .env не создан — docker-setup.sh не завершился корректно"
    exit 1
fi

# --- [5/8] Проверка healthcheck ---
echo "[5/8] Проверка healthcheck..."
echo "  ⏳ Ожидание запуска (15 сек)..."
sleep 15

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/healthz --max-time 10 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" = "200" ]; then
    echo "  ✅ Healthcheck: HTTP 200 — Gateway работает"
else
    echo "  ⚠️  Healthcheck: HTTP ${HTTP_CODE}"
    echo "  Контейнер может ещё запускаться. Проверь позже:"
    echo "    curl http://127.0.0.1:18789/healthz"
fi

# --- [6/8] Emergency-скрипты ---
echo "[6/8] Создание emergency-скриптов..."

cat > "${OPENCLAW_DIR}/emergency-stop.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo "⛔ Останавливаю OpenClaw Gateway..."
docker stop repo-openclaw-gateway-1
echo ""
echo "📋 Статус контейнера после остановки:"
docker ps -a --filter name=repo-openclaw-gateway-1 --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "🕐 Остановлен: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
SCRIPT
chmod +x "${OPENCLAW_DIR}/emergency-stop.sh"

cat > "${OPENCLAW_DIR}/emergency-start.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo "🚀 Запускаю OpenClaw Gateway..."
cd /srv/openclaw/repo && docker compose up -d
echo ""
echo "⏳ Ожидание 10 секунд для инициализации..."
sleep 10
echo ""
echo "📋 Статус контейнера:"
docker ps --filter name=repo-openclaw-gateway-1 --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "🏥 Проверка healthz:"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/healthz --max-time 5 || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Healthz: HTTP $HTTP_CODE — Gateway работает"
else
    echo "❌ Healthz: HTTP $HTTP_CODE — проблема!"
fi
echo ""
echo "🕐 Запущен: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
SCRIPT
chmod +x "${OPENCLAW_DIR}/emergency-start.sh"

echo "  ✅ emergency-stop.sh и emergency-start.sh созданы"

# --- [7/8] Bash-алиасы ---
echo "[7/8] Настройка bash-алиасов..."

ALIASES_FILE="${DEPLOY_HOME}/.bash_aliases"

# Удалить старые алиасы OpenClaw если есть
if [ -f "${ALIASES_FILE}" ]; then
    sed -i '/# === OpenClaw/,/^$/d' "${ALIASES_FILE}"
    sed -i '/^alias claw-/d' "${ALIASES_FILE}"
fi

cat >> "${ALIASES_FILE}" << 'ALIASES'
# === OpenClaw Emergency Controls ===
alias claw-stop='docker stop repo-openclaw-gateway-1 && echo "✓ CONTAINER STOPPED at $(date)"'
alias claw-start='docker start repo-openclaw-gateway-1 && echo "✓ CONTAINER STARTED at $(date)"'
alias claw-status='docker ps --filter name=repo-openclaw-gateway-1 --format "{{.Names}}: {{.Status}}"'
alias claw-restart='docker restart repo-openclaw-gateway-1 && echo "✓ CONTAINER RESTARTED at $(date)"'
alias claw-logs='docker logs --tail 50 repo-openclaw-gateway-1'
alias claw-health='curl -s -o /dev/null -w "HTTP %{http_code}" http://127.0.0.1:18789/healthz && echo ""'
ALIASES

echo "  ✅ Алиасы добавлены: claw-stop, claw-start, claw-status, claw-restart, claw-logs, claw-health"

# --- [8/8] Бэкап конфигов (cron) ---
echo "[8/8] Настройка бэкапа конфигов..."

BACKUP_DIR="${OPENCLAW_DIR}/config-backup"
mkdir -p "${BACKUP_DIR}"

# Инициализация Git-репо для бэкапов (если нет)
if [ ! -d "${BACKUP_DIR}/.git" ]; then
    cd "${BACKUP_DIR}"
    git init -q
    git config user.email "backup@localhost"
    git config user.name "OpenClaw Backup"
    echo "  ✅ Git-репо для бэкапов инициализирован"
fi

# Скрипт бэкапа
cat > "${OPENCLAW_DIR}/backup-config.sh" << 'BACKUP'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/srv/openclaw/config-backup"
CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/home/deploy/.openclaw}"

# Копируем актуальные конфиги (если существуют)
[ -f "$CONFIG_DIR/openclaw.json" ] && cp "$CONFIG_DIR/openclaw.json" "$BACKUP_DIR/openclaw.json"
[ -f "/srv/openclaw/repo/.env" ] && cp "/srv/openclaw/repo/.env" "$BACKUP_DIR/.env"

cd "$BACKUP_DIR"
git add -A

if git diff --cached --quiet; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') — нет изменений"
else
    git commit -m "auto-backup $(date +%Y-%m-%d_%H:%M)"
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') — бэкап закоммичен"
fi
BACKUP
chmod +x "${OPENCLAW_DIR}/backup-config.sh"

# Cron (каждый день в 07:00 UTC)
CRON_LINE="0 7 * * * /srv/openclaw/backup-config.sh >> /srv/openclaw/logs/backup.log 2>&1"
(crontab -l 2>/dev/null | grep -v "backup-config.sh"; echo "${CRON_LINE}") | crontab -
echo "  ✅ Бэкап настроен (ежедневно 07:00 UTC)"

# --- Итоги ---
echo ""
echo "=== Модуль 4 завершён ==="
echo ""
echo "📋 Что создано:"
echo "   /srv/openclaw/repo/          — OpenClaw (docker-compose)"
echo "   /srv/openclaw/emergency-*.sh — аварийные скрипты"
echo "   /srv/openclaw/backup-config.sh — бэкап конфигов"
echo "   ~/.bash_aliases              — алиасы claw-*"
echo ""
echo "⚡ Быстрые команды:"
echo "   claw-status   — статус контейнера"
echo "   claw-health   — HTTP healthcheck"
echo "   claw-logs     — последние 50 строк логов"
echo "   claw-stop     — экстренная остановка"
echo "   claw-start    — запуск"
echo "   claw-restart  — перезапуск"
echo ""
echo "   Перезайди в SSH чтобы алиасы заработали."
