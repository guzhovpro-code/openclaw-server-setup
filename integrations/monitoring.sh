#!/usr/bin/env bash
# ============================================================
# Integration: Monitoring
# - healthcheck.sh — checks Docker containers, Telegram alerts
# - config-backup.sh — sanitizes secrets, pushes to private GitHub repo
# - cc-tasks-cleanup.sh — daily cleanup of old task files
# - Cron jobs: */5 healthcheck, */2h backup, daily 4:00 cleanup
# ============================================================
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/srv/openclaw}"
SCRIPTS_DIR="${OPENCLAW_DIR}/scripts"
SECRETS_DIR="/home/${DEPLOY_USER}/.openclaw/secrets"
LOGS_DIR="${OPENCLAW_DIR}/logs"
CONTAINER_NAME="repo-openclaw-gateway-1"

echo ""
echo "=== Интеграция: Мониторинг ==="
echo ""

# --- Cleanup trap ---
cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo "  ОШИБКА: Установка мониторинга прервана (код ${exit_code})"
        echo "  Скрипт идемпотентен — можно запустить повторно."
    fi
}
trap cleanup EXIT

# --- Check if already installed ---
ALREADY_INSTALLED=false
if [ -f "${SCRIPTS_DIR}/healthcheck.sh" ] && [ -f "${SCRIPTS_DIR}/config-backup.sh" ]; then
    echo "  Мониторинг уже установлен."
    read -p "  Переустановить/обновить? [y/N]: " REINSTALL
    if [[ ! "${REINSTALL}" =~ ^[yY] ]]; then
        echo "  Пропущено."
        exit 0
    fi
    ALREADY_INSTALLED=true
fi

# --- Create directories ---
sudo mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}" "${SECRETS_DIR}"
sudo chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${SCRIPTS_DIR}" "${LOGS_DIR}"

# ============================================================
# [1/5] Collect credentials
# ============================================================
echo "[1/5] Настройка учётных данных..."
echo ""

# Telegram bot token (admin bot)
TELEGRAM_TOKEN_FILE="${SECRETS_DIR}/telegram-admin-bot-token"
if [ -f "${TELEGRAM_TOKEN_FILE}" ] && [ "${ALREADY_INSTALLED}" = true ]; then
    echo "  Telegram-токен уже сохранён."
    read -p "  Обновить? [y/N]: " UPDATE_TOKEN
    if [[ "${UPDATE_TOKEN}" =~ ^[yY] ]]; then
        read -sp "  Telegram Bot Token (для алертов): " TG_TOKEN
        echo ""
        if [ -n "${TG_TOKEN}" ]; then
            printf '%s' "${TG_TOKEN}" | sudo tee "${TELEGRAM_TOKEN_FILE}" > /dev/null
            sudo chmod 600 "${TELEGRAM_TOKEN_FILE}"
            sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${TELEGRAM_TOKEN_FILE}"
            echo "  Токен обновлён"
        fi
    fi
else
    echo "  Для алертов нужен Telegram-бот."
    echo "  Создай бота через @BotFather и скопируй токен."
    echo ""
    read -sp "  Telegram Bot Token: " TG_TOKEN
    echo ""
    if [ -z "${TG_TOKEN}" ]; then
        echo "  ОШИБКА: Telegram Bot Token обязателен для мониторинга"
        exit 1
    fi
    printf '%s' "${TG_TOKEN}" | sudo tee "${TELEGRAM_TOKEN_FILE}" > /dev/null
    sudo chmod 600 "${TELEGRAM_TOKEN_FILE}"
    sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${TELEGRAM_TOKEN_FILE}"
    echo "  Токен сохранён"
fi

# Telegram chat ID
CHAT_ID_FILE="${SECRETS_DIR}/telegram-admin-chat-id"
if [ -f "${CHAT_ID_FILE}" ] && [ "${ALREADY_INSTALLED}" = true ]; then
    echo "  Telegram Chat ID уже сохранён."
    read -p "  Обновить? [y/N]: " UPDATE_CHAT
    if [[ "${UPDATE_CHAT}" =~ ^[yY] ]]; then
        read -p "  Telegram Chat ID: " TG_CHAT_ID
        if [ -n "${TG_CHAT_ID}" ]; then
            printf '%s' "${TG_CHAT_ID}" | sudo tee "${CHAT_ID_FILE}" > /dev/null
            sudo chmod 600 "${CHAT_ID_FILE}"
            sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${CHAT_ID_FILE}"
        fi
    fi
else
    echo ""
    echo "  Отправь боту /start, затем узнай свой Chat ID:"
    echo "  https://api.telegram.org/bot<TOKEN>/getUpdates"
    echo ""
    read -p "  Telegram Chat ID: " TG_CHAT_ID
    if [ -z "${TG_CHAT_ID}" ]; then
        echo "  ОШИБКА: Telegram Chat ID обязателен"
        exit 1
    fi
    printf '%s' "${TG_CHAT_ID}" | sudo tee "${CHAT_ID_FILE}" > /dev/null
    sudo chmod 600 "${CHAT_ID_FILE}"
    sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${CHAT_ID_FILE}"
    echo "  Chat ID сохранён"
fi

# GitHub repo for backups
BACKUP_REPO_FILE="${SECRETS_DIR}/backup-github-repo"
if [ -f "${BACKUP_REPO_FILE}" ] && [ "${ALREADY_INSTALLED}" = true ]; then
    echo "  GitHub backup repo уже настроен."
    read -p "  Обновить? [y/N]: " UPDATE_REPO
    if [[ "${UPDATE_REPO}" =~ ^[yY] ]]; then
        read -p "  GitHub repo URL (SSH, например git@github.com:user/repo.git): " GH_REPO
        if [ -n "${GH_REPO}" ]; then
            printf '%s' "${GH_REPO}" | sudo tee "${BACKUP_REPO_FILE}" > /dev/null
            sudo chmod 600 "${BACKUP_REPO_FILE}"
            sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${BACKUP_REPO_FILE}"
        fi
    fi
else
    echo ""
    echo "  Для бэкапов нужен приватный GitHub-репозиторий."
    echo "  Рекомендуется SSH URL (gh CLI должен быть авторизован)."
    echo ""
    read -p "  GitHub repo URL (SSH, например git@github.com:user/repo.git): " GH_REPO
    if [ -z "${GH_REPO}" ]; then
        echo "  Бэкап на GitHub пропущен (можно настроить позже)"
        GH_REPO=""
    else
        printf '%s' "${GH_REPO}" | sudo tee "${BACKUP_REPO_FILE}" > /dev/null
        sudo chmod 600 "${BACKUP_REPO_FILE}"
        sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${BACKUP_REPO_FILE}"
        echo "  GitHub repo сохранён"
    fi
fi

# ============================================================
# [2/5] Create healthcheck.sh
# ============================================================
echo ""
echo "[2/5] Создание healthcheck.sh..."

cat > "${SCRIPTS_DIR}/healthcheck.sh" << 'HEALTHCHECK'
#!/usr/bin/env bash
# ============================================================
# healthcheck.sh — checks Docker containers, sends Telegram alerts
# Run via cron every 5 minutes
# ============================================================
set -uo pipefail

SECRETS_DIR="${HOME}/.openclaw/secrets"
LOGS_DIR="/srv/openclaw/logs"
CONTAINER_NAME="repo-openclaw-gateway-1"
HEALTHCHECK_URL="http://127.0.0.1:18789/healthz"
HOSTNAME_SHORT="$(hostname -s)"
STATE_FILE="/tmp/.openclaw-healthcheck-state"

# Read secrets
TG_TOKEN="$(cat "${SECRETS_DIR}/telegram-admin-bot-token" 2>/dev/null || echo "")"
TG_CHAT_ID="$(cat "${SECRETS_DIR}/telegram-admin-chat-id" 2>/dev/null || echo "")"

log() {
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') $1" >> "${LOGS_DIR}/healthcheck.log"
}

send_alert() {
    local message="$1"
    if [ -n "${TG_TOKEN}" ] && [ -n "${TG_CHAT_ID}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d text="${message}" \
            -d parse_mode="HTML" \
            --max-time 10 > /dev/null 2>&1 || true
    fi
}

ERRORS=()
PREV_STATE="ok"
[ -f "${STATE_FILE}" ] && PREV_STATE="$(cat "${STATE_FILE}")"

# Check 1: Docker daemon
if ! docker info &>/dev/null 2>&1; then
    ERRORS+=("Docker daemon не отвечает")
fi

# Check 2: OpenClaw container
CONTAINER_STATUS=$(docker ps --filter name="${CONTAINER_NAME}" --format '{{.Status}}' 2>/dev/null || echo "")
if [ -z "${CONTAINER_STATUS}" ]; then
    ERRORS+=("Контейнер ${CONTAINER_NAME} не найден")
elif ! echo "${CONTAINER_STATUS}" | grep -q "Up"; then
    ERRORS+=("Контейнер ${CONTAINER_NAME} остановлен: ${CONTAINER_STATUS}")
fi

# Check 3: HTTP healthcheck
if [ ${#ERRORS[@]} -eq 0 ]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${HEALTHCHECK_URL}" --max-time 10 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" != "200" ]; then
        ERRORS+=("Healthcheck HTTP ${HTTP_CODE} (ожидался 200)")
    fi
fi

# Check 4: Disk space (alert if >90%)
DISK_USAGE=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
if [ "${DISK_USAGE}" -gt 90 ]; then
    ERRORS+=("Диск заполнен на ${DISK_USAGE}%")
fi

# Check 5: RAM (alert if available <100MB)
AVAIL_MB=$(free -m | awk '/^Mem:/ {print $7}')
if [ "${AVAIL_MB}" -lt 100 ]; then
    ERRORS+=("Мало RAM: ${AVAIL_MB} MB свободно")
fi

# Decide and report
if [ ${#ERRORS[@]} -gt 0 ]; then
    ERROR_TEXT=""
    for err in "${ERRORS[@]}"; do
        ERROR_TEXT="${ERROR_TEXT}\n- ${err}"
        log "FAIL: ${err}"
    done

    # Only alert on state transition (ok -> fail) or every 30 min
    MINUTE=$(date +%M)
    if [ "${PREV_STATE}" = "ok" ] || [ "$((MINUTE % 30))" -eq 0 ]; then
        send_alert "<b>[${HOSTNAME_SHORT}] OpenClaw ALERT</b>${ERROR_TEXT}"
    fi

    echo "fail" > "${STATE_FILE}"
else
    log "OK: container=${CONTAINER_STATUS}, disk=${DISK_USAGE}%, ram=${AVAIL_MB}MB"

    # Send recovery notification if previous state was fail
    if [ "${PREV_STATE}" = "fail" ]; then
        send_alert "<b>[${HOSTNAME_SHORT}] OpenClaw OK</b>\nВсе проверки пройдены. Сервис восстановлен."
    fi

    echo "ok" > "${STATE_FILE}"
fi
HEALTHCHECK
chmod +x "${SCRIPTS_DIR}/healthcheck.sh"
echo "  healthcheck.sh создан"

# ============================================================
# [3/5] Create config-backup.sh
# ============================================================
echo ""
echo "[3/5] Создание config-backup.sh..."

cat > "${SCRIPTS_DIR}/config-backup.sh" << 'BACKUP'
#!/usr/bin/env bash
# ============================================================
# config-backup.sh — sanitize secrets, commit, push to GitHub
# Run via cron every 2 hours
# ============================================================
set -uo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SECRETS_DIR="${HOME}/.openclaw/secrets"
CONFIG_DIR="${HOME}/.openclaw"
BACKUP_DIR="/srv/openclaw/config-backup"
LOGS_DIR="/srv/openclaw/logs"
BACKUP_REPO_FILE="${SECRETS_DIR}/backup-github-repo"

log() {
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') $1" >> "${LOGS_DIR}/backup.log"
}

# Read GitHub repo URL if available
GH_REPO=""
[ -f "${BACKUP_REPO_FILE}" ] && GH_REPO="$(cat "${BACKUP_REPO_FILE}")"

# Ensure backup directory exists
mkdir -p "${BACKUP_DIR}"

# Initialize git repo if needed
if [ ! -d "${BACKUP_DIR}/.git" ]; then
    cd "${BACKUP_DIR}"
    git init -q
    git config user.email "backup@openclaw"
    git config user.name "OpenClaw Backup"
    if [ -n "${GH_REPO}" ]; then
        git remote add origin "${GH_REPO}" 2>/dev/null || git remote set-url origin "${GH_REPO}"
    fi
fi

# Copy config files (sanitize secrets)
if [ -f "${CONFIG_DIR}/openclaw.json" ]; then
    # Copy and strip any inline secret values (should not exist with SecretRef, but just in case)
    sudo cp "${CONFIG_DIR}/openclaw.json" "${BACKUP_DIR}/openclaw.json"
    sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${BACKUP_DIR}/openclaw.json"
fi

# Copy .env but redact secret values
if [ -f "/srv/openclaw/repo/.env" ]; then
    sed -E 's/(TOKEN|SECRET|PASSWORD|KEY)=.+/\1=***REDACTED***/gi' \
        /srv/openclaw/repo/.env > "${BACKUP_DIR}/.env.sanitized"
fi

# Copy docker-compose.yml
[ -f "/srv/openclaw/repo/docker-compose.yml" ] && \
    cp "/srv/openclaw/repo/docker-compose.yml" "${BACKUP_DIR}/docker-compose.yml"

# List installed integrations
ls -1 /srv/openclaw/scripts/*.sh 2>/dev/null > "${BACKUP_DIR}/installed-scripts.txt" || true

# Save crontab
crontab -l > "${BACKUP_DIR}/crontab.txt" 2>/dev/null || true

# Ensure .gitignore excludes actual secrets
cat > "${BACKUP_DIR}/.gitignore" << 'GI'
*.key
*.token
*.secret
*.pem
GI

cd "${BACKUP_DIR}"
sudo chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${BACKUP_DIR}"
git add -A

if git diff --cached --quiet; then
    log "No changes"
else
    git commit -q -m "auto-backup $(date '+%Y-%m-%d %H:%M')"
    log "Committed"

    # Push if remote configured
    if [ -n "${GH_REPO}" ] && git remote get-url origin &>/dev/null; then
        if git push -q origin main 2>/dev/null || git push -q origin master 2>/dev/null; then
            log "Pushed to GitHub"
        else
            # First push — set upstream
            BRANCH=$(git branch --show-current)
            git push -q -u origin "${BRANCH}" 2>/dev/null || log "Push failed"
        fi
    fi
fi
BACKUP
chmod +x "${SCRIPTS_DIR}/config-backup.sh"
echo "  config-backup.sh создан"

# ============================================================
# [4/5] Create cc-tasks-cleanup.sh
# ============================================================
echo ""
echo "[4/5] Создание cc-tasks-cleanup.sh..."

cat > "${SCRIPTS_DIR}/cc-tasks-cleanup.sh" << 'CLEANUP'
#!/usr/bin/env bash
# ============================================================
# cc-tasks-cleanup.sh — daily cleanup of old CC task files
# Removes completed task files older than 7 days
# Run via cron daily at 4:00
# ============================================================
set -uo pipefail

TASKS_DIR="/srv/openclaw/workspace/cc-tasks"
HANDOFFS_DIR="/srv/openclaw/workspace/handoffs"
LOGS_DIR="/srv/openclaw/logs"
RETENTION_DAYS=7

log() {
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') $1" >> "${LOGS_DIR}/cleanup.log"
}

CLEANED=0

# Clean old task files
if [ -d "${TASKS_DIR}" ]; then
    COUNT=$(find "${TASKS_DIR}" -name "*.done" -mtime +${RETENTION_DAYS} 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt 0 ]; then
        find "${TASKS_DIR}" -name "*.done" -mtime +${RETENTION_DAYS} -delete 2>/dev/null
        CLEANED=$((CLEANED + COUNT))
    fi
fi

# Clean old handoff files
if [ -d "${HANDOFFS_DIR}" ]; then
    COUNT=$(find "${HANDOFFS_DIR}" -name "*.done" -mtime +${RETENTION_DAYS} 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt 0 ]; then
        find "${HANDOFFS_DIR}" -name "*.done" -mtime +${RETENTION_DAYS} -delete 2>/dev/null
        CLEANED=$((CLEANED + COUNT))
    fi
fi

# Clean old log files (older than 30 days)
if [ -d "${LOGS_DIR}" ]; then
    COUNT=$(find "${LOGS_DIR}" -name "*.log" -mtime +30 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt 0 ]; then
        find "${LOGS_DIR}" -name "*.log" -mtime +30 -delete 2>/dev/null
        CLEANED=$((CLEANED + COUNT))
    fi
fi

# Truncate large log files (>50MB)
if [ -d "${LOGS_DIR}" ]; then
    find "${LOGS_DIR}" -name "*.log" -size +50M 2>/dev/null | while read -r f; do
        tail -n 1000 "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
        log "Truncated large log: ${f}"
        CLEANED=$((CLEANED + 1))
    done
fi

log "Cleanup done: ${CLEANED} files removed/truncated"
CLEANUP
chmod +x "${SCRIPTS_DIR}/cc-tasks-cleanup.sh"
echo "  cc-tasks-cleanup.sh создан"

# ============================================================
# [5/5] Configure cron jobs
# ============================================================
echo ""
echo "[5/5] Настройка cron-задач..."

# Helper: add cron entry if not already present
add_cron() {
    local schedule="$1"
    local command="$2"
    local comment="$3"
    local marker="${comment}"

    # Remove existing entry for this script (by marker in comment)
    local existing
    existing=$(crontab -l 2>/dev/null || true)
    local filtered
    filtered=$(echo "${existing}" | grep -v "${marker}" || true)

    # Add new entry
    local new_entry="# ${comment}"$'\n'"${schedule} ${command}"
    echo "${filtered}"$'\n'"${new_entry}" | crontab -
}

add_cron "*/5 * * * *" \
    "${SCRIPTS_DIR}/healthcheck.sh >> ${LOGS_DIR}/healthcheck.log 2>&1" \
    "openclaw-healthcheck"

add_cron "0 */2 * * *" \
    "${SCRIPTS_DIR}/config-backup.sh >> ${LOGS_DIR}/backup.log 2>&1" \
    "openclaw-config-backup"

add_cron "0 4 * * *" \
    "${SCRIPTS_DIR}/cc-tasks-cleanup.sh >> ${LOGS_DIR}/cleanup.log 2>&1" \
    "openclaw-tasks-cleanup"

echo "  Cron-задачи установлены:"
echo "    */5 мин  — healthcheck"
echo "    */2 часа — config-backup"
echo "    4:00     — cc-tasks-cleanup"

# ============================================================
# Verify and report
# ============================================================
echo ""
echo "=== Мониторинг: установлен ==="
echo ""
echo "  Файлы:"
echo "    ${SCRIPTS_DIR}/healthcheck.sh"
echo "    ${SCRIPTS_DIR}/config-backup.sh"
echo "    ${SCRIPTS_DIR}/cc-tasks-cleanup.sh"
echo ""
echo "  Секреты:"
echo "    ${SECRETS_DIR}/telegram-admin-bot-token"
echo "    ${SECRETS_DIR}/telegram-admin-chat-id"
[ -f "${BACKUP_REPO_FILE}" ] && echo "    ${SECRETS_DIR}/backup-github-repo"
echo ""
echo "  Логи: ${LOGS_DIR}/"
echo ""
echo "  Проверить вручную:"
echo "    ${SCRIPTS_DIR}/healthcheck.sh"
echo "    crontab -l | grep openclaw"
echo ""
