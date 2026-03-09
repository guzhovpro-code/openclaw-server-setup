#!/usr/bin/env bash
# ============================================================
# Integration: n8n
# - docker-compose.yml for n8n (with Traefik labels if available)
# - Persistent volume for data
# - n8n.sh helper script
# - API key creation
# ============================================================
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/srv/openclaw}"
WORKSPACE_DIR="${OPENCLAW_DIR}/workspace"
WORKSPACE_SCRIPTS="${WORKSPACE_DIR}/scripts"
SECRETS_DIR="/home/${DEPLOY_USER}/.openclaw/secrets"
N8N_DIR="${OPENCLAW_DIR}/n8n"
N8N_DATA_DIR="${N8N_DIR}/data"
N8N_CONTAINER="openclaw-n8n"

echo ""
echo "=== Интеграция: n8n ==="
echo ""

# --- Cleanup trap ---
cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo "  ОШИБКА: Установка n8n прервана (код ${exit_code})"
        echo "  Скрипт идемпотентен — можно запустить повторно."
    fi
}
trap cleanup EXIT

# --- Check Docker ---
if ! docker info &>/dev/null 2>&1; then
    echo "  ОШИБКА: Docker не запущен"
    exit 1
fi

# --- Check if already installed ---
ALREADY_INSTALLED=false
if docker ps -a --filter name="${N8N_CONTAINER}" --format '{{.Names}}' 2>/dev/null | grep -q "${N8N_CONTAINER}"; then
    N8N_STATUS=$(docker ps --filter name="${N8N_CONTAINER}" --format '{{.Status}}' 2>/dev/null || echo "stopped")
    echo "  n8n уже установлен: ${N8N_STATUS}"
    read -p "  Переустановить/обновить? [y/N]: " REINSTALL
    if [[ ! "${REINSTALL}" =~ ^[yY] ]]; then
        echo "  Пропущено."
        exit 0
    fi
    ALREADY_INSTALLED=true
fi

# --- Dependencies ---
if ! command -v htpasswd &>/dev/null; then
    echo "  Установка apache2-utils (для htpasswd)..."
    sudo apt-get install -y -qq apache2-utils
fi

# --- Create directories ---
sudo mkdir -p "${N8N_DIR}" "${N8N_DATA_DIR}" "${WORKSPACE_SCRIPTS}" "${SECRETS_DIR}"
sudo chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${N8N_DIR}" "${WORKSPACE_DIR}"

# ============================================================
# [1/5] Collect configuration
# ============================================================
echo "[1/5] Настройка параметров..."
echo ""

# Check if Traefik is running
TRAEFIK_AVAILABLE=false
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "traefik"; then
    TRAEFIK_AVAILABLE=true
    echo "  Traefik обнаружен — будет настроен HTTPS"
fi

# Domain name
N8N_DOMAIN=""
N8N_DOMAIN_FILE="${SECRETS_DIR}/n8n-domain"
if [ "${TRAEFIK_AVAILABLE}" = true ]; then
    if [ -f "${N8N_DOMAIN_FILE}" ] && [ "${ALREADY_INSTALLED}" = true ]; then
        N8N_DOMAIN="$(cat "${N8N_DOMAIN_FILE}")"
        echo "  Домен: ${N8N_DOMAIN}"
        read -p "  Обновить? [y/N]: " UPDATE_DOMAIN
        if [[ "${UPDATE_DOMAIN}" =~ ^[yY] ]]; then
            read -p "  Домен для n8n (например n8n.example.com): " N8N_DOMAIN
        fi
    else
        echo "  Для HTTPS через Traefik нужен домен."
        echo "  DNS A-запись должна указывать на IP этого сервера."
        echo ""
        read -p "  Домен для n8n (например n8n.example.com): " N8N_DOMAIN
    fi

    if [ -n "${N8N_DOMAIN}" ]; then
        printf '%s' "${N8N_DOMAIN}" | sudo tee "${N8N_DOMAIN_FILE}" > /dev/null
        sudo chmod 600 "${N8N_DOMAIN_FILE}"
        sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${N8N_DOMAIN_FILE}"
    fi
fi

# Basic auth password
N8N_PASS_FILE="${SECRETS_DIR}/n8n-basic-auth-password"
N8N_AUTH_USER="admin"

if [ -f "${N8N_PASS_FILE}" ] && [ "${ALREADY_INSTALLED}" = true ]; then
    N8N_PASS="$(sudo cat "${N8N_PASS_FILE}")"
    echo "  Basic auth пароль уже сохранён."
    read -p "  Обновить? [y/N]: " UPDATE_PASS
    if [[ "${UPDATE_PASS}" =~ ^[yY] ]]; then
        read -sp "  Пароль для Basic Auth (пользователь: admin): " N8N_PASS
        echo ""
    fi
else
    echo ""
    echo "  n8n будет защищён Basic Auth."
    read -sp "  Пароль для Basic Auth (пользователь: admin): " N8N_PASS
    echo ""

    if [ -z "${N8N_PASS}" ]; then
        echo "  ОШИБКА: Пароль обязателен"
        exit 1
    fi
fi

printf '%s' "${N8N_PASS}" | sudo tee "${N8N_PASS_FILE}" > /dev/null
sudo chmod 600 "${N8N_PASS_FILE}"
sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${N8N_PASS_FILE}"

# Generate htpasswd for Traefik
HTPASSWD=$(htpasswd -nb "${N8N_AUTH_USER}" "${N8N_PASS}" 2>/dev/null | sed 's/\$/\$\$/g')

# ============================================================
# [2/5] Create docker-compose.yml
# ============================================================
echo ""
echo "[2/5] Создание docker-compose.yml..."

# Stop existing container if updating
if [ "${ALREADY_INSTALLED}" = true ]; then
    docker compose -f "${N8N_DIR}/docker-compose.yml" down 2>/dev/null || true
fi

if [ "${TRAEFIK_AVAILABLE}" = true ] && [ -n "${N8N_DOMAIN}" ]; then
    # --- With Traefik (HTTPS) ---
    cat > "${N8N_DIR}/docker-compose.yml" << COMPOSE
version: "3.8"

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: ${N8N_CONTAINER}
    restart: unless-stopped
    environment:
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${N8N_DOMAIN}/
      - GENERIC_TIMEZONE=Europe/Moscow
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_PASS}
    volumes:
      - ${N8N_DATA_DIR}:/home/node/.n8n
    networks:
      - traefik-public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.http.routers.n8n.middlewares=n8n-auth"
      - "traefik.http.middlewares.n8n-auth.basicauth.users=${HTPASSWD}"

networks:
  traefik-public:
    external: true
COMPOSE
    echo "  docker-compose.yml создан (с Traefik, HTTPS)"

else
    # --- Without Traefik (localhost only) ---
    cat > "${N8N_DIR}/docker-compose.yml" << COMPOSE
version: "3.8"

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: ${N8N_CONTAINER}
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - N8N_HOST=localhost
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - NODE_ENV=production
      - GENERIC_TIMEZONE=Europe/Moscow
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_PASS}
    volumes:
      - ${N8N_DATA_DIR}:/home/node/.n8n
COMPOSE
    echo "  docker-compose.yml создан (localhost:5678, без Traefik)"
fi

# ============================================================
# [3/5] Start n8n
# ============================================================
echo ""
echo "[3/5] Запуск n8n..."

cd "${N8N_DIR}" && docker compose up -d

echo "  Ожидание запуска (15 сек)..."
sleep 15

# Check if running
if docker ps --filter name="${N8N_CONTAINER}" --format '{{.Status}}' 2>/dev/null | grep -q "Up"; then
    echo "  n8n запущен"
else
    echo "  ПРЕДУПРЕЖДЕНИЕ: n8n не запустился. Проверь логи:"
    echo "  docker logs ${N8N_CONTAINER} --tail 20"
fi

# ============================================================
# [4/5] Create API key
# ============================================================
echo ""
echo "[4/5] Создание API-ключа..."

N8N_API_KEY_FILE="${SECRETS_DIR}/n8n-api-key"

# Try to create API key via n8n CLI
API_KEY=$(docker exec "${N8N_CONTAINER}" n8n user-management:create-api-key 2>/dev/null || echo "")

if [ -n "${API_KEY}" ] && [ "${API_KEY}" != "null" ]; then
    printf '%s' "${API_KEY}" | sudo tee "${N8N_API_KEY_FILE}" > /dev/null
    sudo chmod 600 "${N8N_API_KEY_FILE}"
    sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${N8N_API_KEY_FILE}"
    echo "  API-ключ создан и сохранён"
else
    echo "  API-ключ не удалось создать автоматически."
    echo "  Создай вручную в интерфейсе n8n: Settings -> API -> Create API Key"
    echo "  Затем сохрани: echo 'KEY' > ${N8N_API_KEY_FILE}"
fi

# ============================================================
# [5/5] Create n8n.sh helper script
# ============================================================
echo ""
echo "[5/5] Создание n8n.sh скрипта..."

cat > "${WORKSPACE_SCRIPTS}/n8n.sh" << 'N8NSH'
#!/usr/bin/env bash
# ============================================================
# n8n.sh — helper for n8n operations
# Usage:
#   n8n.sh status              Check n8n status
#   n8n.sh start               Start n8n
#   n8n.sh stop                Stop n8n
#   n8n.sh restart             Restart n8n
#   n8n.sh logs [N]            Show last N log lines (default 50)
#   n8n.sh update              Pull latest image and restart
#   n8n.sh workflows           List workflows via API
#   n8n.sh execute <id>        Execute workflow by ID
#   n8n.sh api <endpoint>      Call n8n API endpoint
# ============================================================
set -euo pipefail

N8N_DIR="/srv/openclaw/n8n"
N8N_CONTAINER="openclaw-n8n"
SECRETS_DIR="${HOME}/.openclaw/secrets"
API_KEY="$(cat "${SECRETS_DIR}/n8n-api-key" 2>/dev/null || echo "")"
N8N_DOMAIN="$(cat "${SECRETS_DIR}/n8n-domain" 2>/dev/null || echo "localhost:5678")"

# Determine base URL
if [ "${N8N_DOMAIN}" = "localhost:5678" ] || [ -z "${N8N_DOMAIN}" ]; then
    N8N_BASE="http://localhost:5678"
else
    N8N_BASE="https://${N8N_DOMAIN}"
fi

n8n_api() {
    local endpoint="$1"
    local method="${2:-GET}"
    local data="${3:-}"

    if [ -z "${API_KEY}" ]; then
        echo "ОШИБКА: API-ключ не найден (${SECRETS_DIR}/n8n-api-key)"
        echo "Создай в интерфейсе: Settings -> API -> Create API Key"
        return 1
    fi

    local args=(-s -X "${method}"
        -H "X-N8N-API-KEY: ${API_KEY}"
        -H "Content-Type: application/json"
        --max-time 30)

    if [ -n "${data}" ]; then
        args+=(-d "${data}")
    fi

    curl "${args[@]}" "${N8N_BASE}/api/v1${endpoint}"
}

case "${1:-help}" in
    status)
        echo "=== n8n Status ==="
        if docker ps --filter name="${N8N_CONTAINER}" --format '{{.Status}}' 2>/dev/null | grep -q "Up"; then
            echo "  Контейнер: работает"
            docker ps --filter name="${N8N_CONTAINER}" --format "  Статус: {{.Status}}\n  Порты: {{.Ports}}"
        else
            echo "  Контейнер: ОСТАНОВЛЕН"
        fi

        # Health check
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${N8N_BASE}/healthz" --max-time 5 2>/dev/null || echo "000")
        echo "  Health: HTTP ${HTTP_CODE}"
        echo "  URL: ${N8N_BASE}"
        ;;

    start)
        echo "Запуск n8n..."
        cd "${N8N_DIR}" && docker compose up -d
        echo "Готово"
        ;;

    stop)
        echo "Остановка n8n..."
        cd "${N8N_DIR}" && docker compose down
        echo "Готово"
        ;;

    restart)
        echo "Перезапуск n8n..."
        cd "${N8N_DIR}" && docker compose restart
        echo "Готово"
        ;;

    logs)
        LINES="${2:-50}"
        docker logs --tail "${LINES}" "${N8N_CONTAINER}"
        ;;

    update)
        echo "Обновление n8n..."
        cd "${N8N_DIR}" && docker compose pull && docker compose up -d
        echo "Готово"
        ;;

    workflows)
        echo "=== Workflows ==="
        RESULT=$(n8n_api "/workflows" 2>/dev/null)
        echo "${RESULT}" | jq -r '.data[]? | "  [\(.id)] \(.name) — \(.active // false)"' 2>/dev/null || \
            echo "  Не удалось получить список (проверь API-ключ)"
        ;;

    execute)
        WF_ID="${2:?Укажи ID workflow}"
        echo "Запуск workflow ${WF_ID}..."
        n8n_api "/workflows/${WF_ID}/execute" POST
        ;;

    api)
        ENDPOINT="${2:?Укажи endpoint (например /workflows)}"
        METHOD="${3:-GET}"
        DATA="${4:-}"
        n8n_api "${ENDPOINT}" "${METHOD}" "${DATA}"
        ;;

    help|*)
        echo "n8n.sh — помощник для n8n"
        echo ""
        echo "Команды:"
        echo "  status              Статус n8n"
        echo "  start               Запуск"
        echo "  stop                Остановка"
        echo "  restart             Перезапуск"
        echo "  logs [N]            Логи (последние N строк)"
        echo "  update              Обновить образ"
        echo "  workflows           Список workflow"
        echo "  execute <id>        Запустить workflow"
        echo "  api <endpoint>      Вызов API"
        ;;
esac
N8NSH
chmod +x "${WORKSPACE_SCRIPTS}/n8n.sh"
echo "  n8n.sh создан"

# ============================================================
# Report
# ============================================================
echo ""
echo "=== n8n: установлен ==="
echo ""

if [ "${TRAEFIK_AVAILABLE}" = true ] && [ -n "${N8N_DOMAIN}" ]; then
    echo "  URL: https://${N8N_DOMAIN}"
else
    echo "  URL: http://localhost:5678"
    echo "  (доступен только с сервера; для внешнего доступа настрой Traefik или SSH-туннель)"
fi

echo "  Логин: ${N8N_AUTH_USER}"
echo "  Пароль: (сохранён в ${N8N_PASS_FILE})"
echo ""
echo "  Файлы:"
echo "    ${N8N_DIR}/docker-compose.yml"
echo "    ${WORKSPACE_SCRIPTS}/n8n.sh"
echo "    ${N8N_DATA_DIR}/ — persistent data"
echo ""
echo "  Секреты:"
echo "    ${N8N_PASS_FILE}"
[ -f "${N8N_API_KEY_FILE}" ] && echo "    ${N8N_API_KEY_FILE}"
echo ""
echo "  Проверить:"
echo "    ${WORKSPACE_SCRIPTS}/n8n.sh status"
echo "    ${WORKSPACE_SCRIPTS}/n8n.sh workflows"
echo ""
