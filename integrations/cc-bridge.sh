#!/usr/bin/env bash
# ============================================================
# Integration: CC Bridge (Claude Code on server)
# - Claude Code CLI installation
# - cc-bridge-v3.sh worker script
# - dispatch-to-cc.sh for bot container
# - systemd unit (cc-bridge.service)
# - OAuth token setup
# - ACL for cc-tasks directory
# - Monitoring integration
# ============================================================
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_HOME="/home/${DEPLOY_USER}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/srv/openclaw}"
WORKSPACE_DIR="${OPENCLAW_DIR}/workspace"
SCRIPTS_DIR="${OPENCLAW_DIR}/scripts"
SECRETS_DIR="${DEPLOY_HOME}/.openclaw/secrets"
CC_TASKS_DIR="${WORKSPACE_DIR}/cc-tasks"
HANDOFFS_DIR="${WORKSPACE_DIR}/handoffs"
LOGS_DIR="${OPENCLAW_DIR}/logs"
CC_SERVICE="cc-bridge"

echo ""
echo "=== Интеграция: CC Bridge (Claude Code) ==="
echo ""

# --- Cleanup trap ---
cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo "  ОШИБКА: Установка CC Bridge прервана (код ${exit_code})"
        echo "  Скрипт идемпотентен — можно запустить повторно."
    fi
}
trap cleanup EXIT

# --- Check if already installed ---
ALREADY_INSTALLED=false
if systemctl is-enabled "${CC_SERVICE}" &>/dev/null 2>&1; then
    SERVICE_STATUS=$(systemctl is-active "${CC_SERVICE}" 2>/dev/null || echo "inactive")
    echo "  CC Bridge уже установлен: ${SERVICE_STATUS}"
    read -p "  Переустановить/обновить? [y/N]: " REINSTALL
    if [[ ! "${REINSTALL}" =~ ^[yY] ]]; then
        echo "  Пропущено."
        exit 0
    fi
    ALREADY_INSTALLED=true
fi

# --- Dependencies ---
echo "  Проверка зависимостей..."

# Node.js (required for Claude Code)
if ! command -v node &>/dev/null; then
    echo "  Установка Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null
    sudo apt-get install -y -qq nodejs
fi
NODE_VER=$(node --version 2>/dev/null || echo "none")
echo "  Node.js: ${NODE_VER}"

# npm
if ! command -v npm &>/dev/null; then
    echo "  ОШИБКА: npm не найден"
    exit 1
fi

# ACL support
if ! command -v setfacl &>/dev/null; then
    echo "  Установка acl..."
    sudo apt-get install -y -qq acl
fi

# jq
if ! command -v jq &>/dev/null; then
    sudo apt-get install -y -qq jq
fi

# --- Create directories ---
sudo mkdir -p "${SCRIPTS_DIR}" "${CC_TASKS_DIR}" "${HANDOFFS_DIR}" "${SECRETS_DIR}" "${LOGS_DIR}"
sudo chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${WORKSPACE_DIR}" "${SCRIPTS_DIR}" "${LOGS_DIR}"

# ============================================================
# [1/7] Install Claude Code CLI
# ============================================================
echo ""
echo "[1/7] Установка Claude Code CLI..."

if command -v claude &>/dev/null; then
    CC_VER=$(claude --version 2>/dev/null || echo "unknown")
    echo "  Claude Code уже установлен: ${CC_VER}"
    read -p "  Обновить до последней версии? [y/N]: " UPDATE_CC
    if [[ "${UPDATE_CC}" =~ ^[yY] ]]; then
        sudo npm install -g @anthropic-ai/claude-code@latest
        echo "  Обновлён: $(claude --version 2>/dev/null)"
    fi
else
    echo "  Установка @anthropic-ai/claude-code..."
    sudo npm install -g @anthropic-ai/claude-code
    echo "  Claude Code установлен: $(claude --version 2>/dev/null)"
fi

# ============================================================
# [2/7] OAuth token setup
# ============================================================
echo ""
echo "[2/7] Настройка OAuth-токена..."
echo ""

OAUTH_TOKEN_FILE="${SECRETS_DIR}/claude-oauth-token"

if [ -f "${OAUTH_TOKEN_FILE}" ] && [ "${ALREADY_INSTALLED}" = true ]; then
    echo "  OAuth токен уже сохранён."
    read -p "  Обновить? [y/N]: " UPDATE_TOKEN
    if [[ "${UPDATE_TOKEN}" =~ ^[yY] ]]; then
        echo "  Для получения токена выполни на ЛОКАЛЬНОЙ машине (не на сервере):"
        echo ""
        echo "    claude setup-token"
        echo ""
        echo "  Это откроет браузер для OAuth-авторизации."
        echo "  После авторизации скопируй полученный токен."
        echo ""
        read -sp "  OAuth Token: " OAUTH_TOKEN
        echo ""
        if [ -n "${OAUTH_TOKEN}" ]; then
            printf '%s' "${OAUTH_TOKEN}" | sudo tee "${OAUTH_TOKEN_FILE}" > /dev/null
            sudo chmod 600 "${OAUTH_TOKEN_FILE}"
            sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${OAUTH_TOKEN_FILE}"
            echo "  Токен обновлён"
        fi
    fi
else
    echo "  CC Bridge использует Claude Code CLI для выполнения задач из Telegram."
    echo ""
    echo "  Для авторизации нужен OAuth-токен."
    echo "  Выполни на ЛОКАЛЬНОЙ машине (где есть браузер):"
    echo ""
    echo "    claude setup-token"
    echo ""
    echo "  Это откроет браузер для OAuth-авторизации через Anthropic."
    echo "  После авторизации появится токен — скопируй его."
    echo ""
    echo "  Если у тебя уже есть API-ключ Anthropic, можно использовать его вместо OAuth."
    echo ""
    read -sp "  OAuth Token (или API Key): " OAUTH_TOKEN
    echo ""

    if [ -z "${OAUTH_TOKEN}" ]; then
        echo "  ОШИБКА: Токен обязателен для CC Bridge"
        exit 1
    fi

    printf '%s' "${OAUTH_TOKEN}" | sudo tee "${OAUTH_TOKEN_FILE}" > /dev/null
    sudo chmod 600 "${OAUTH_TOKEN_FILE}"
    sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${OAUTH_TOKEN_FILE}"
    echo "  Токен сохранён"
fi

# ============================================================
# [3/7] Create cc-bridge-v3.sh worker script
# ============================================================
echo ""
echo "[3/7] Создание cc-bridge-v3.sh..."

cat > "${SCRIPTS_DIR}/cc-bridge-v3.sh" << 'BRIDGE'
#!/usr/bin/env bash
# ============================================================
# cc-bridge-v3.sh — Claude Code bridge worker
# Monitors cc-tasks directory for new task files, executes
# them via Claude Code CLI, and writes results back.
#
# Task file format: JSON with fields:
#   id, prompt, context (optional), callback_chat_id
#
# Result file: <task_id>.result.json
# ============================================================
set -uo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SECRETS_DIR="/home/${DEPLOY_USER}/.openclaw/secrets"
CC_TASKS_DIR="/srv/openclaw/workspace/cc-tasks"
HANDOFFS_DIR="/srv/openclaw/workspace/handoffs"
LOGS_DIR="/srv/openclaw/logs"
LOG_FILE="${LOGS_DIR}/cc-bridge.log"
LOCK_FILE="/tmp/.cc-bridge.lock"
POLL_INTERVAL=5
MAX_TASK_DURATION=300  # 5 minutes per task

# Load OAuth token
export ANTHROPIC_API_KEY=""
OAUTH_FILE="${SECRETS_DIR}/claude-oauth-token"
if [ -f "${OAUTH_FILE}" ]; then
    export ANTHROPIC_API_KEY="$(cat "${OAUTH_FILE}")"
fi

log() {
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') [CC-Bridge] $1" | tee -a "${LOG_FILE}"
}

send_telegram() {
    local chat_id="$1"
    local message="$2"
    local tg_token
    tg_token="$(cat "${SECRETS_DIR}/telegram-admin-bot-token" 2>/dev/null || echo "")"

    if [ -n "${tg_token}" ] && [ -n "${chat_id}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${tg_token}/sendMessage" \
            -d chat_id="${chat_id}" \
            -d text="${message}" \
            -d parse_mode="HTML" \
            --max-time 10 > /dev/null 2>&1 || true
    fi
}

process_task() {
    local task_file="$1"
    local task_id
    local prompt
    local callback_chat_id
    local context

    # Parse task file
    task_id=$(jq -r '.id // empty' "${task_file}" 2>/dev/null)
    prompt=$(jq -r '.prompt // empty' "${task_file}" 2>/dev/null)
    callback_chat_id=$(jq -r '.callback_chat_id // empty' "${task_file}" 2>/dev/null)
    context=$(jq -r '.context // empty' "${task_file}" 2>/dev/null)

    if [ -z "${task_id}" ] || [ -z "${prompt}" ]; then
        log "SKIP: Invalid task file ${task_file}"
        mv "${task_file}" "${task_file}.invalid"
        return 1
    fi

    log "START: task=${task_id}"

    # Build Claude Code command
    local cc_args=("--print" "--output-format" "json")

    if [ -n "${context}" ]; then
        # Prepend context to prompt
        prompt="${context}\n\n${prompt}"
    fi

    # Mark task as in-progress
    mv "${task_file}" "${task_file}.processing"

    # Execute via Claude Code CLI with timeout
    local result_file="${CC_TASKS_DIR}/${task_id}.result.json"
    local start_time=$(date +%s)

    if timeout "${MAX_TASK_DURATION}" claude ${cc_args[@]} "${prompt}" > "${result_file}.tmp" 2>&1; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        # Parse Claude output
        local response
        response=$(jq -r '.result // .response // .' "${result_file}.tmp" 2>/dev/null || cat "${result_file}.tmp")

        # Write result
        jq -n \
            --arg id "${task_id}" \
            --arg status "completed" \
            --arg response "${response}" \
            --arg duration "${duration}s" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{id: $id, status: $status, response: $response, duration: $duration, timestamp: $timestamp}' \
            > "${result_file}"

        rm -f "${result_file}.tmp"

        log "DONE: task=${task_id} duration=${duration}s"

        # Notify via Telegram if callback provided
        if [ -n "${callback_chat_id}" ]; then
            local short_response="${response:0:3000}"
            send_telegram "${callback_chat_id}" "<b>CC Task Done</b>\nID: <code>${task_id}</code>\nDuration: ${duration}s\n\n${short_response}"
        fi

        # Mark task as done
        mv "${task_file}.processing" "${task_file}.done"
        return 0
    else
        local exit_code=$?
        log "FAIL: task=${task_id} exit=${exit_code}"

        # Write error result
        jq -n \
            --arg id "${task_id}" \
            --arg status "failed" \
            --arg error "Exit code ${exit_code}" \
            --arg output "$(cat "${result_file}.tmp" 2>/dev/null || echo "no output")" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{id: $id, status: $status, error: $error, output: $output, timestamp: $timestamp}' \
            > "${result_file}"

        rm -f "${result_file}.tmp"

        if [ -n "${callback_chat_id}" ]; then
            send_telegram "${callback_chat_id}" "<b>CC Task FAILED</b>\nID: <code>${task_id}</code>\nError: Exit code ${exit_code}"
        fi

        mv "${task_file}.processing" "${task_file}.failed"
        return 1
    fi
}

# --- Main loop ---
log "Starting CC Bridge v3"

# Ensure directories exist
mkdir -p "${CC_TASKS_DIR}" "${HANDOFFS_DIR}" "${LOGS_DIR}"

# Single instance check
if [ -f "${LOCK_FILE}" ]; then
    OLD_PID=$(cat "${LOCK_FILE}")
    if kill -0 "${OLD_PID}" 2>/dev/null; then
        log "Another instance running (PID ${OLD_PID}), exiting"
        exit 0
    fi
fi
echo $$ > "${LOCK_FILE}"

# Cleanup on exit
trap 'rm -f "${LOCK_FILE}"; log "Stopped"' EXIT

while true; do
    # Process task files (*.task.json)
    for task_file in "${CC_TASKS_DIR}"/*.task.json; do
        [ -f "${task_file}" ] || continue
        process_task "${task_file}" || true
    done

    # Process handoff files from bot (CC_TO_BOT pattern is read, BOT_TO_CC is written by bot)
    for handoff_file in "${HANDOFFS_DIR}"/BOT_TO_CC_*.json; do
        [ -f "${handoff_file}" ] || continue

        # Convert handoff to task format
        TASK_ID="handoff-$(date +%s)-$$"
        jq --arg id "${TASK_ID}" '. + {id: $id}' "${handoff_file}" > "${CC_TASKS_DIR}/${TASK_ID}.task.json" 2>/dev/null
        mv "${handoff_file}" "${handoff_file}.processed"

        log "Handoff converted: ${handoff_file} -> ${TASK_ID}"
    done

    sleep "${POLL_INTERVAL}"
done
BRIDGE
chmod +x "${SCRIPTS_DIR}/cc-bridge-v3.sh"
echo "  cc-bridge-v3.sh создан"

# ============================================================
# [4/7] Create dispatch-to-cc.sh for bot container
# ============================================================
echo ""
echo "[4/7] Создание dispatch-to-cc.sh..."

cat > "${SCRIPTS_DIR}/dispatch-to-cc.sh" << 'DISPATCH'
#!/usr/bin/env bash
# ============================================================
# dispatch-to-cc.sh — Send a task to CC Bridge from bot container
# Usage: dispatch-to-cc.sh <prompt> [chat_id] [context]
# ============================================================
set -euo pipefail

CC_TASKS_DIR="/srv/openclaw/workspace/cc-tasks"
TASK_ID="task-$(date +%s)-${RANDOM}"

PROMPT="${1:?Укажи промпт для Claude Code}"
CHAT_ID="${2:-}"
CONTEXT="${3:-}"

mkdir -p "${CC_TASKS_DIR}"

jq -n \
    --arg id "${TASK_ID}" \
    --arg prompt "${PROMPT}" \
    --arg callback_chat_id "${CHAT_ID}" \
    --arg context "${CONTEXT}" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id: $id, prompt: $prompt, callback_chat_id: $callback_chat_id, context: $context, created: $created}' \
    > "${CC_TASKS_DIR}/${TASK_ID}.task.json"

echo "${TASK_ID}"
DISPATCH
chmod +x "${SCRIPTS_DIR}/dispatch-to-cc.sh"
echo "  dispatch-to-cc.sh создан"

# ============================================================
# [5/7] Create systemd unit
# ============================================================
echo ""
echo "[5/7] Создание systemd-сервиса..."

sudo tee /etc/systemd/system/${CC_SERVICE}.service > /dev/null << SYSTEMD
[Unit]
Description=OpenClaw CC Bridge — Claude Code task worker
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=${DEPLOY_USER}
Group=${DEPLOY_USER}
WorkingDirectory=${OPENCLAW_DIR}
ExecStart=${SCRIPTS_DIR}/cc-bridge-v3.sh
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOGS_DIR}/cc-bridge.log
StandardError=append:${LOGS_DIR}/cc-bridge-error.log

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${WORKSPACE_DIR} ${LOGS_DIR} /tmp
PrivateTmp=true

# Environment
Environment=HOME=/home/${DEPLOY_USER}
Environment=DEPLOY_USER=${DEPLOY_USER}

[Install]
WantedBy=multi-user.target
SYSTEMD

sudo systemctl daemon-reload
sudo systemctl enable "${CC_SERVICE}"
sudo systemctl restart "${CC_SERVICE}"

# Check if started
sleep 3
if systemctl is-active --quiet "${CC_SERVICE}"; then
    echo "  Сервис ${CC_SERVICE} запущен"
else
    echo "  ПРЕДУПРЕЖДЕНИЕ: Сервис не запустился. Проверь:"
    echo "  sudo journalctl -u ${CC_SERVICE} -n 20"
fi

# ============================================================
# [6/7] ACL setup for cc-tasks directory
# ============================================================
echo ""
echo "[6/7] Настройка ACL для cc-tasks..."

# Bot container user (typically runs as root inside container)
# We need deploy user to have full access, and Docker/bot to be able to write
sudo setfacl -R -m u:${DEPLOY_USER}:rwx "${CC_TASKS_DIR}" 2>/dev/null || true
sudo setfacl -R -d -m u:${DEPLOY_USER}:rwx "${CC_TASKS_DIR}" 2>/dev/null || true

# Make tasks directory world-writable for Docker containers
sudo chmod 1777 "${CC_TASKS_DIR}"

# Same for handoffs
sudo setfacl -R -m u:${DEPLOY_USER}:rwx "${HANDOFFS_DIR}" 2>/dev/null || true
sudo setfacl -R -d -m u:${DEPLOY_USER}:rwx "${HANDOFFS_DIR}" 2>/dev/null || true
sudo chmod 1777 "${HANDOFFS_DIR}"

echo "  ACL настроены для ${CC_TASKS_DIR} и ${HANDOFFS_DIR}"

# ============================================================
# [7/7] Add CC Bridge to healthcheck
# ============================================================
echo ""
echo "[7/7] Интеграция с мониторингом..."

HEALTHCHECK_FILE="${SCRIPTS_DIR}/healthcheck.sh"
if [ -f "${HEALTHCHECK_FILE}" ]; then
    # Check if CC Bridge check already present
    if grep -q "cc-bridge" "${HEALTHCHECK_FILE}"; then
        echo "  CC Bridge уже в healthcheck"
    else
        # Add CC Bridge check before the "Decide and report" section
        BRIDGE_CHECK='
# Check 6: CC Bridge service
if ! systemctl is-active --quiet cc-bridge 2>/dev/null; then
    ERRORS+=("CC Bridge сервис не работает")
fi'
        # Append check before the final decision block
        sed -i '/^# Decide and report/i '"$(echo "${BRIDGE_CHECK}" | sed ':a;N;$!ba;s/\n/\\n/g')" "${HEALTHCHECK_FILE}" 2>/dev/null || \
            echo "  Не удалось добавить в healthcheck (добавь вручную)"
        echo "  Добавлен в healthcheck.sh"
    fi
else
    echo "  healthcheck.sh не найден — установи интеграцию Monitoring"
fi

# ============================================================
# Rate limits and limitations notice
# ============================================================
echo ""
echo "  === Важная информация ==="
echo ""
echo "  Ограничения Claude Code CLI:"
echo "  - Rate limit: зависит от плана Anthropic (обычно ~50 req/min)"
echo "  - Одна сессия за раз (параллельные задачи ставятся в очередь)"
echo "  - Максимальная длительность задачи: 5 минут (настраивается)"
echo "  - OAuth токен нужно обновлять периодически"
echo ""
echo "  Для проверки токена:"
echo "    claude --print 'Hello, test'"
echo ""

# ============================================================
# Report
# ============================================================
echo ""
echo "=== CC Bridge: установлен ==="
echo ""
echo "  Сервис: ${CC_SERVICE}"
echo "  Статус: $(systemctl is-active ${CC_SERVICE} 2>/dev/null || echo "unknown")"
echo ""
echo "  Файлы:"
echo "    ${SCRIPTS_DIR}/cc-bridge-v3.sh"
echo "    ${SCRIPTS_DIR}/dispatch-to-cc.sh"
echo "    /etc/systemd/system/${CC_SERVICE}.service"
echo ""
echo "  Директории задач:"
echo "    ${CC_TASKS_DIR}/ — входящие задачи (.task.json)"
echo "    ${HANDOFFS_DIR}/ — handoff файлы бот<->CC"
echo ""
echo "  Секреты:"
echo "    ${SECRETS_DIR}/claude-oauth-token"
echo ""
echo "  Управление:"
echo "    sudo systemctl status ${CC_SERVICE}"
echo "    sudo systemctl restart ${CC_SERVICE}"
echo "    sudo journalctl -u ${CC_SERVICE} -f"
echo ""
echo "  Отправить задачу:"
echo "    ${SCRIPTS_DIR}/dispatch-to-cc.sh 'Проверь состояние сервера' '<chat_id>'"
echo ""
