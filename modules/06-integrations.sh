#!/usr/bin/env bash
# ============================================================
# Module 6: Integration Installer (interactive selector)
# Displays a multi-select menu of optional integrations
# and runs the chosen ones in order.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATIONS_DIR="${SCRIPT_DIR}/../integrations"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/srv/openclaw}"

echo "=== Модуль 6: Интеграции (опционально) ==="
echo ""
echo "  OpenClaw уже работает! Всё ниже — дополнительные модули."
echo "  Каждый модуль независим, можно поставить любой набор."
echo ""

# --- Check Docker is running (common dependency) ---
if ! docker info &>/dev/null 2>&1; then
    echo "  ОШИБКА: Docker не запущен. Сначала выполни модули 03-docker.sh и 04-openclaw.sh"
    exit 1
fi

# ============================================================
# Integration registry: id, script filename, title, description
# ============================================================
declare -a INT_IDS=("monitoring" "notion" "mongodb" "n8n" "cc-bridge")
declare -A INT_TITLES=(
    ["monitoring"]="Мониторинг"
    ["notion"]="Notion"
    ["mongodb"]="MongoDB"
    ["n8n"]="n8n (автоматизация)"
    ["cc-bridge"]="CC Bridge (Claude Code)"
)
declare -A INT_DESCS=(
    ["monitoring"]="Healthcheck каждые 5 мин + авто-бэкап на GitHub + Telegram-алерты"
    ["notion"]="Подключение бота к Notion (Sync Hub, Tasks, Resources)"
    ["mongodb"]="Локальная MongoDB 8.0 с авторизацией для логов и данных"
    ["n8n"]="Платформа автоматизации (Instagram, транскрипция, кастомные воркфлоу)"
    ["cc-bridge"]="Claude Code CLI агент на сервере (задачи из Telegram)"
)
declare -A INT_SCRIPTS=(
    ["monitoring"]="monitoring.sh"
    ["notion"]="notion.sh"
    ["mongodb"]="mongodb.sh"
    ["n8n"]="n8n.sh"
    ["cc-bridge"]="cc-bridge.sh"
)

# ============================================================
# Menu display function — tries whiptail/dialog, falls back to plain text
# Sets SELECTED_IDS array with chosen integration IDs
# ============================================================
declare -a SELECTED_IDS=()

show_menu_whiptail() {
    # Build whiptail checklist arguments
    local -a args=()
    for id in "${INT_IDS[@]}"; do
        args+=("${id}" "${INT_TITLES[$id]} — ${INT_DESCS[$id]}" "OFF")
    done

    local result
    result=$(whiptail --title "OpenClaw: Интеграции" \
        --checklist "\nВыбери интеграции для установки (Пробел = выбрать, Enter = подтвердить):" \
        20 80 ${#INT_IDS[@]} \
        "${args[@]}" \
        3>&1 1>&2 2>&3) || { echo "  Отменено пользователем."; exit 0; }

    # Parse whiptail output: "monitoring" "notion" "mongodb"
    for id in ${result}; do
        id="${id//\"/}"  # remove quotes
        SELECTED_IDS+=("${id}")
    done
}

show_menu_dialog() {
    # Build dialog checklist arguments
    local -a args=()
    for id in "${INT_IDS[@]}"; do
        args+=("${id}" "${INT_TITLES[$id]} — ${INT_DESCS[$id]}" "off")
    done

    local result
    result=$(dialog --title "OpenClaw: Интеграции" \
        --checklist "\nВыбери интеграции для установки:" \
        20 80 ${#INT_IDS[@]} \
        "${args[@]}" \
        3>&1 1>&2 2>&3) || { echo "  Отменено пользователем."; exit 0; }

    for id in ${result}; do
        id="${id//\"/}"
        SELECTED_IDS+=("${id}")
    done
}

show_menu_plain() {
    # Plain text fallback when neither whiptail nor dialog is available
    echo "  Доступные интеграции:"
    echo "  ─────────────────────────────────────────────────────────"
    local i=1
    for id in "${INT_IDS[@]}"; do
        printf "  %d. %-25s %s\n" "${i}" "${INT_TITLES[$id]}" "${INT_DESCS[$id]}"
        ((i++))
    done
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
    echo "  Введи номера через пробел (например: 1 3 5)"
    echo "  Введи 'all' для установки всех"
    echo "  Введи '0' или пустую строку для отмены"
    echo ""
    read -p "  Выбор: " CHOICE

    if [ -z "${CHOICE}" ] || [ "${CHOICE}" = "0" ]; then
        echo "  Отменено пользователем."
        exit 0
    fi

    if [ "${CHOICE}" = "all" ]; then
        SELECTED_IDS=("${INT_IDS[@]}")
        return
    fi

    for num in ${CHOICE}; do
        if [[ "${num}" =~ ^[0-9]+$ ]] && [ "${num}" -ge 1 ] && [ "${num}" -le ${#INT_IDS[@]} ]; then
            SELECTED_IDS+=("${INT_IDS[$((num-1))]}")
        else
            echo "  Неверный номер: ${num} (пропущен)"
        fi
    done
}

# --- Choose UI method ---
if command -v whiptail &>/dev/null; then
    show_menu_whiptail
elif command -v dialog &>/dev/null; then
    show_menu_dialog
else
    show_menu_plain
fi

# --- Validate selection ---
if [ ${#SELECTED_IDS[@]} -eq 0 ]; then
    echo ""
    echo "  Ничего не выбрано. Интеграции можно добавить позже,"
    echo "  запустив этот скрипт повторно."
    echo ""
    echo "=== Модуль 6 завершён (без изменений) ==="
    exit 0
fi

# --- Confirm ---
echo ""
echo "  Будут установлены:"
for id in "${SELECTED_IDS[@]}"; do
    echo "    - ${INT_TITLES[$id]}"
done
echo ""
read -p "  Продолжить? [Y/n]: " CONFIRM
if [[ "${CONFIRM}" =~ ^[nN] ]]; then
    echo "  Отменено."
    exit 0
fi

# ============================================================
# Run selected integrations in order
# ============================================================
echo ""
TOTAL=${#SELECTED_IDS[@]}
CURRENT=0
FAILED=()
SUCCEEDED=()

for id in "${SELECTED_IDS[@]}"; do
    ((CURRENT++))
    SCRIPT_PATH="${INTEGRATIONS_DIR}/${INT_SCRIPTS[$id]}"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  [${CURRENT}/${TOTAL}] Установка: ${INT_TITLES[$id]}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ ! -f "${SCRIPT_PATH}" ]; then
        echo "  ОШИБКА: Файл ${SCRIPT_PATH} не найден!"
        FAILED+=("${INT_TITLES[$id]}")
        continue
    fi

    if bash "${SCRIPT_PATH}"; then
        SUCCEEDED+=("${INT_TITLES[$id]}")
        echo ""
        echo "  --- ${INT_TITLES[$id]}: установлен ---"
    else
        FAILED+=("${INT_TITLES[$id]}")
        echo ""
        echo "  --- ${INT_TITLES[$id]}: ОШИБКА ---"
    fi
    echo ""
done

# ============================================================
# Summary
# ============================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "=== Модуль 6 завершён ==="
echo ""

if [ ${#SUCCEEDED[@]} -gt 0 ]; then
    echo "  Установлены:"
    for name in "${SUCCEEDED[@]}"; do
        echo "    + ${name}"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo "  Ошибки:"
    for name in "${FAILED[@]}"; do
        echo "    x ${name}"
    done
    echo ""
    echo "  Можно запустить повторно — скрипты идемпотентны."
fi

echo ""
echo "  Запусти этот скрипт ещё раз чтобы добавить другие интеграции."
echo ""
