#!/usr/bin/env bash
# ============================================================
# Integration: Notion
# - notion.sh helper script in workspace/scripts/
# - Notion integration token stored securely
# - MCP server entry in openclaw.json
# - Creates 3 Notion databases (Sync Hub, Tasks, Resources)
# - Adds briefing note for bot
# ============================================================
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/srv/openclaw}"
WORKSPACE_DIR="${OPENCLAW_DIR}/workspace"
WORKSPACE_SCRIPTS="${WORKSPACE_DIR}/scripts"
SECRETS_DIR="/home/${DEPLOY_USER}/.openclaw/secrets"
CONFIG_DIR="/home/${DEPLOY_USER}/.openclaw"
NOTES_DIR="${WORKSPACE_DIR}/notes"

echo ""
echo "=== Интеграция: Notion ==="
echo ""

# --- Cleanup trap ---
cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo "  ОШИБКА: Установка Notion прервана (код ${exit_code})"
        echo "  Скрипт идемпотентен — можно запустить повторно."
    fi
}
trap cleanup EXIT

# --- Check if already installed ---
ALREADY_INSTALLED=false
if [ -f "${WORKSPACE_SCRIPTS}/notion.sh" ]; then
    echo "  Notion интеграция уже установлена."
    read -p "  Переустановить/обновить? [y/N]: " REINSTALL
    if [[ ! "${REINSTALL}" =~ ^[yY] ]]; then
        echo "  Пропущено."
        exit 0
    fi
    ALREADY_INSTALLED=true
fi

# --- Dependencies ---
if ! command -v jq &>/dev/null; then
    echo "  Установка jq..."
    sudo apt-get install -y -qq jq
fi

if ! command -v curl &>/dev/null; then
    echo "  Установка curl..."
    sudo apt-get install -y -qq curl
fi

# --- Create directories ---
sudo mkdir -p "${WORKSPACE_SCRIPTS}" "${SECRETS_DIR}" "${NOTES_DIR}"
sudo chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${WORKSPACE_DIR}" "${SECRETS_DIR}"

# ============================================================
# [1/5] Collect Notion token
# ============================================================
echo "[1/5] Настройка Notion API..."
echo ""

NOTION_TOKEN_FILE="${SECRETS_DIR}/notion-mcp-token"
NOTION_TOKEN=""

if [ -f "${NOTION_TOKEN_FILE}" ] && [ "${ALREADY_INSTALLED}" = true ]; then
    echo "  Notion токен уже сохранён."
    read -p "  Обновить? [y/N]: " UPDATE_TOKEN
    if [[ "${UPDATE_TOKEN}" =~ ^[yY] ]]; then
        echo "  Создай интеграцию на https://www.notion.so/my-integrations"
        echo "  Тип: Internal integration"
        echo "  Capabilities: Read content, Update content, Insert content"
        echo ""
        read -sp "  Notion Integration Token (начинается с ntn_ или secret_): " NOTION_TOKEN
        echo ""
    else
        NOTION_TOKEN="$(sudo cat "${NOTION_TOKEN_FILE}" 2>/dev/null || echo "")"
    fi
else
    echo "  Для подключения нужна Notion Integration."
    echo ""
    echo "  Шаги:"
    echo "  1. Перейди на https://www.notion.so/my-integrations"
    echo "  2. Нажми 'New integration'"
    echo "  3. Назови: OpenClaw Bot"
    echo "  4. Тип: Internal"
    echo "  5. Capabilities: Read, Update, Insert content"
    echo "  6. Скопируй Internal Integration Secret"
    echo ""
    read -sp "  Notion Integration Token: " NOTION_TOKEN
    echo ""
fi

if [ -z "${NOTION_TOKEN}" ]; then
    echo "  ОШИБКА: Notion токен обязателен"
    exit 1
fi

printf '%s' "${NOTION_TOKEN}" | sudo tee "${NOTION_TOKEN_FILE}" > /dev/null
sudo chmod 600 "${NOTION_TOKEN_FILE}"
sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${NOTION_TOKEN_FILE}"
echo "  Токен сохранён"

# ============================================================
# [2/5] Create Notion databases via API
# ============================================================
echo ""
echo "[2/5] Создание баз данных в Notion..."
echo ""
echo "  Для создания БД нужен ID родительской страницы."
echo "  Открой страницу в Notion, скопируй ID из URL:"
echo "  https://www.notion.so/workspace/PAGE_TITLE-<32-char-ID>"
echo "  Не забудь подключить интеграцию к этой странице (... -> Connections -> OpenClaw Bot)"
echo ""
read -p "  Parent Page ID (32 символа, или Enter для пропуска): " PARENT_PAGE_ID

DB_IDS_FILE="${SECRETS_DIR}/notion-database-ids"

if [ -n "${PARENT_PAGE_ID}" ]; then
    # Remove hyphens if user pasted UUID format
    PARENT_PAGE_ID="${PARENT_PAGE_ID//-/}"

    # Format as UUID
    if [ ${#PARENT_PAGE_ID} -eq 32 ]; then
        PARENT_UUID="${PARENT_PAGE_ID:0:8}-${PARENT_PAGE_ID:8:4}-${PARENT_PAGE_ID:12:4}-${PARENT_PAGE_ID:16:4}-${PARENT_PAGE_ID:20:12}"
    else
        PARENT_UUID="${PARENT_PAGE_ID}"
    fi

    echo "  Создаю базы данных..."

    # Helper: create Notion database
    create_db() {
        local title="$1"
        local properties="$2"
        local icon="$3"

        local response
        response=$(curl -s -X POST "https://api.notion.com/v1/databases" \
            -H "Authorization: Bearer ${NOTION_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "Notion-Version: 2022-06-28" \
            -d "{
                \"parent\": {\"type\": \"page_id\", \"page_id\": \"${PARENT_UUID}\"},
                \"icon\": {\"type\": \"emoji\", \"emoji\": \"${icon}\"},
                \"title\": [{\"type\": \"text\", \"text\": {\"content\": \"${title}\"}}],
                \"properties\": ${properties}
            }" 2>/dev/null)

        local db_id
        db_id=$(echo "${response}" | jq -r '.id // empty' 2>/dev/null || echo "")

        if [ -n "${db_id}" ]; then
            echo "    + ${title}: ${db_id}"
            echo "${db_id}"
        else
            local error
            error=$(echo "${response}" | jq -r '.message // .code // "unknown error"' 2>/dev/null || echo "API error")
            echo "    x ${title}: ОШИБКА — ${error}" >&2
            echo ""
        fi
    }

    # Sync Hub database
    SYNC_HUB_ID=$(create_db "Sync Hub" '{
        "Name": {"title": {}},
        "Status": {"select": {"options": [
            {"name": "Active", "color": "green"},
            {"name": "Done", "color": "gray"},
            {"name": "Pending", "color": "yellow"}
        ]}},
        "Source": {"select": {"options": [
            {"name": "CC", "color": "blue"},
            {"name": "Bot", "color": "purple"},
            {"name": "Manual", "color": "default"}
        ]}},
        "Updated": {"date": {}},
        "Notes": {"rich_text": {}}
    }' "🔄")

    # Tasks database
    TASKS_ID=$(create_db "Tasks" '{
        "Task": {"title": {}},
        "Status": {"select": {"options": [
            {"name": "Todo", "color": "red"},
            {"name": "In Progress", "color": "yellow"},
            {"name": "Done", "color": "green"},
            {"name": "Blocked", "color": "gray"}
        ]}},
        "Priority": {"select": {"options": [
            {"name": "P0", "color": "red"},
            {"name": "P1", "color": "orange"},
            {"name": "P2", "color": "yellow"},
            {"name": "P3", "color": "default"}
        ]}},
        "Assignee": {"select": {"options": [
            {"name": "Bot", "color": "purple"},
            {"name": "CC", "color": "blue"},
            {"name": "Human", "color": "green"}
        ]}},
        "Due": {"date": {}},
        "Notes": {"rich_text": {}}
    }' "📋")

    # Resources database
    RESOURCES_ID=$(create_db "Resources" '{
        "Name": {"title": {}},
        "Type": {"select": {"options": [
            {"name": "Config", "color": "blue"},
            {"name": "Script", "color": "green"},
            {"name": "Doc", "color": "yellow"},
            {"name": "Link", "color": "purple"}
        ]}},
        "Path": {"rich_text": {}},
        "Description": {"rich_text": {}},
        "Updated": {"date": {}}
    }' "📦")

    # Save database IDs
    cat > "${DB_IDS_FILE}" << DBIDS
NOTION_SYNC_HUB_ID=${SYNC_HUB_ID}
NOTION_TASKS_ID=${TASKS_ID}
NOTION_RESOURCES_ID=${RESOURCES_ID}
DBIDS
    sudo chmod 600 "${DB_IDS_FILE}"
    sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${DB_IDS_FILE}"

else
    echo "  Пропущено. Можно создать базы позже через notion.sh"
    echo "  или указать ID существующих баз вручную."

    if [ ! -f "${DB_IDS_FILE}" ]; then
        cat > "${DB_IDS_FILE}" << DBIDS
NOTION_SYNC_HUB_ID=
NOTION_TASKS_ID=
NOTION_RESOURCES_ID=
DBIDS
        sudo chmod 600 "${DB_IDS_FILE}"
        sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${DB_IDS_FILE}"
    fi
fi

# ============================================================
# [3/5] Create notion.sh helper script
# ============================================================
echo ""
echo "[3/5] Создание notion.sh скрипта..."

cat > "${WORKSPACE_SCRIPTS}/notion.sh" << 'NOTIONSH'
#!/usr/bin/env bash
# ============================================================
# notion.sh — CRUD operations on Notion API
# Usage:
#   notion.sh query <database_id> [filter_json]
#   notion.sh create <database_id> <properties_json>
#   notion.sh update <page_id> <properties_json>
#   notion.sh get <page_id>
#   notion.sh search <query>
#   notion.sh sync-hub add <name> <status> [notes]
#   notion.sh task add <name> <status> <priority> [assignee]
#   notion.sh databases — list saved database IDs
# ============================================================
set -euo pipefail

SECRETS_DIR="${HOME}/.openclaw/secrets"
NOTION_TOKEN="$(cat "${SECRETS_DIR}/notion-mcp-token" 2>/dev/null || echo "")"
DB_IDS_FILE="${SECRETS_DIR}/notion-database-ids"
NOTION_API="https://api.notion.com/v1"
NOTION_VERSION="2022-06-28"

if [ -z "${NOTION_TOKEN}" ]; then
    echo "ОШИБКА: Notion токен не найден (${SECRETS_DIR}/notion-mcp-token)"
    exit 1
fi

# Load database IDs
if [ -f "${DB_IDS_FILE}" ]; then
    source "${DB_IDS_FILE}"
fi

notion_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local args=(-s -X "${method}"
        -H "Authorization: Bearer ${NOTION_TOKEN}"
        -H "Content-Type: application/json"
        -H "Notion-Version: ${NOTION_VERSION}"
        --max-time 30)

    if [ -n "${data}" ]; then
        args+=(-d "${data}")
    fi

    curl "${args[@]}" "${NOTION_API}${endpoint}"
}

case "${1:-help}" in
    query)
        DB_ID="${2:?Укажи database_id}"
        FILTER="${3:-{}}"
        notion_api POST "/databases/${DB_ID}/query" "${FILTER}"
        ;;

    create)
        DB_ID="${2:?Укажи database_id}"
        PROPS="${3:?Укажи properties JSON}"
        notion_api POST "/pages" "{\"parent\":{\"database_id\":\"${DB_ID}\"},\"properties\":${PROPS}}"
        ;;

    update)
        PAGE_ID="${2:?Укажи page_id}"
        PROPS="${3:?Укажи properties JSON}"
        notion_api PATCH "/pages/${PAGE_ID}" "{\"properties\":${PROPS}}"
        ;;

    get)
        PAGE_ID="${2:?Укажи page_id}"
        notion_api GET "/pages/${PAGE_ID}"
        ;;

    search)
        QUERY="${2:?Укажи поисковый запрос}"
        notion_api POST "/search" "{\"query\":\"${QUERY}\"}"
        ;;

    sync-hub)
        ACTION="${2:-}"
        if [ "${ACTION}" = "add" ]; then
            NAME="${3:?Укажи имя записи}"
            STATUS="${4:-Active}"
            NOTES="${5:-}"
            DB_ID="${NOTION_SYNC_HUB_ID:?NOTION_SYNC_HUB_ID не установлен}"
            notion_api POST "/pages" "{
                \"parent\":{\"database_id\":\"${DB_ID}\"},
                \"properties\":{
                    \"Name\":{\"title\":[{\"text\":{\"content\":\"${NAME}\"}}]},
                    \"Status\":{\"select\":{\"name\":\"${STATUS}\"}},
                    \"Source\":{\"select\":{\"name\":\"CC\"}},
                    \"Updated\":{\"date\":{\"start\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}},
                    \"Notes\":{\"rich_text\":[{\"text\":{\"content\":\"${NOTES}\"}}]}
                }
            }"
        else
            echo "Использование: notion.sh sync-hub add <name> [status] [notes]"
        fi
        ;;

    task)
        ACTION="${2:-}"
        if [ "${ACTION}" = "add" ]; then
            NAME="${3:?Укажи название задачи}"
            STATUS="${4:-Todo}"
            PRIORITY="${5:-P2}"
            ASSIGNEE="${6:-Bot}"
            DB_ID="${NOTION_TASKS_ID:?NOTION_TASKS_ID не установлен}"
            notion_api POST "/pages" "{
                \"parent\":{\"database_id\":\"${DB_ID}\"},
                \"properties\":{
                    \"Task\":{\"title\":[{\"text\":{\"content\":\"${NAME}\"}}]},
                    \"Status\":{\"select\":{\"name\":\"${STATUS}\"}},
                    \"Priority\":{\"select\":{\"name\":\"${PRIORITY}\"}},
                    \"Assignee\":{\"select\":{\"name\":\"${ASSIGNEE}\"}}
                }
            }"
        else
            echo "Использование: notion.sh task add <name> [status] [priority] [assignee]"
        fi
        ;;

    databases)
        echo "Сохранённые ID баз данных:"
        if [ -f "${DB_IDS_FILE}" ]; then
            cat "${DB_IDS_FILE}"
        else
            echo "  Файл ${DB_IDS_FILE} не найден"
        fi
        ;;

    help|*)
        echo "notion.sh — CRUD для Notion API"
        echo ""
        echo "Команды:"
        echo "  query <db_id> [filter]     Запросить записи из БД"
        echo "  create <db_id> <props>     Создать страницу"
        echo "  update <page_id> <props>   Обновить страницу"
        echo "  get <page_id>              Получить страницу"
        echo "  search <query>             Поиск по Notion"
        echo "  sync-hub add <name> ...    Добавить в Sync Hub"
        echo "  task add <name> ...        Добавить задачу"
        echo "  databases                  Показать ID БД"
        ;;
esac
NOTIONSH
chmod +x "${WORKSPACE_SCRIPTS}/notion.sh"
echo "  notion.sh создан"

# ============================================================
# [4/5] Configure MCP server entry
# ============================================================
echo ""
echo "[4/5] Настройка MCP-сервера в openclaw.json..."

CONFIG_FILE="${CONFIG_DIR}/openclaw.json"

if [ -f "${CONFIG_FILE}" ]; then
    # Check if Notion MCP entry already exists
    if sudo cat "${CONFIG_FILE}" | jq -e '.mcpServers.notion // .mcp_servers.notion' &>/dev/null 2>&1; then
        echo "  Notion MCP уже настроен в openclaw.json"
    else
        echo "  MCP-запись для Notion подготовлена."
        echo "  Добавь в openclaw.json (секция mcpServers):"
        echo ""
        echo '  "notion": {'
        echo '    "command": "npx",'
        echo '    "args": ["-y", "@notionhq/notion-mcp-server"],'
        echo '    "env": {'
        echo "      \"OPENAPI_MCP_HEADERS\": \"{\\\"Authorization\\\": \\\"Bearer \$(cat ${SECRETS_DIR}/notion-mcp-token)\\\", \\\"Notion-Version\\\": \\\"2022-06-28\\\"}\""
        echo '    }'
        echo '  }'
        echo ""
        echo "  (ACPX MCP поддержка заблокирована багом codex-acp — используй notion.sh)"
    fi
else
    echo "  openclaw.json не найден — пропущено."
    echo "  MCP-запись можно добавить после установки OpenClaw."
fi

# ============================================================
# [5/5] Create briefing note for bot
# ============================================================
echo ""
echo "[5/5] Создание брифинга для бота..."

cat > "${NOTES_DIR}/notion-setup-briefing.md" << 'BRIEFING'
# Notion Integration — Брифинг

## Подключение
- Токен: `~/.openclaw/secrets/notion-mcp-token`
- ID баз: `~/.openclaw/secrets/notion-database-ids`
- Скрипт: `workspace/scripts/notion.sh`

## Базы данных

### Sync Hub
- Общая доска для синхронизации между CC и ботом
- Поля: Name, Status (Active/Done/Pending), Source (CC/Bot/Manual), Updated, Notes

### Tasks
- Задачи с приоритетами и назначением
- Поля: Task, Status (Todo/In Progress/Done/Blocked), Priority (P0-P3), Assignee (Bot/CC/Human), Due, Notes

### Resources
- Справочник конфигов, скриптов, ссылок
- Поля: Name, Type (Config/Script/Doc/Link), Path, Description, Updated

## Использование

```bash
# Добавить запись в Sync Hub
./workspace/scripts/notion.sh sync-hub add "Название" "Active" "Примечания"

# Добавить задачу
./workspace/scripts/notion.sh task add "Сделать X" "Todo" "P1" "Bot"

# Поиск
./workspace/scripts/notion.sh search "ключевое слово"

# Показать ID баз
./workspace/scripts/notion.sh databases
```

## Заметки
- MCP-сервер подготовлен, но заблокирован багом codex-acp
- Для прямого API-доступа используй notion.sh
- Не забывай подключать интеграцию к новым страницам в Notion
BRIEFING
echo "  Брифинг создан: ${NOTES_DIR}/notion-setup-briefing.md"

# ============================================================
# Report
# ============================================================
echo ""
echo "=== Notion: установлен ==="
echo ""
echo "  Файлы:"
echo "    ${WORKSPACE_SCRIPTS}/notion.sh"
echo "    ${NOTES_DIR}/notion-setup-briefing.md"
echo ""
echo "  Секреты:"
echo "    ${SECRETS_DIR}/notion-mcp-token"
echo "    ${SECRETS_DIR}/notion-database-ids"
echo ""
echo "  Проверить:"
echo "    ${WORKSPACE_SCRIPTS}/notion.sh databases"
echo "    ${WORKSPACE_SCRIPTS}/notion.sh search \"test\""
echo ""
