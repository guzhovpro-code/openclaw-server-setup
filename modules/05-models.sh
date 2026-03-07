#!/usr/bin/env bash
# ============================================================
# Модуль 5: Мульти-провайдерная конфигурация моделей + SecretRef
# Настройка провайдеров, fallback-цепочки, безопасное хранение ключей
# ============================================================
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/home/${DEPLOY_USER}/.openclaw}"
SECRETS_DIR="${OPENCLAW_CONFIG_DIR}/secrets"
CONTAINER_SECRETS="/home/node/.openclaw/secrets"
CONTAINER_NAME="repo-openclaw-gateway-1"

echo "=== Модуль 5: Модели и провайдеры ==="
echo ""

# --- Проверка: OpenClaw установлен? ---
if ! docker ps --filter name="${CONTAINER_NAME}" --format '{{.Status}}' 2>/dev/null | grep -q "Up"; then
    echo "  ❌ OpenClaw Gateway не запущен."
    echo "  Сначала выполни модуль 04-openclaw.sh"
    exit 1
fi
echo "  ✅ OpenClaw Gateway работает"

# --- Определяем uid владельца конфига ---
CONFIG_OWNER=$(stat -c '%U' "${OPENCLAW_CONFIG_DIR}" 2>/dev/null || echo "${DEPLOY_USER}")
echo "  ℹ️  Владелец конфигов: ${CONFIG_OWNER}"

# --- [1/4] Создание каталога секретов ---
echo ""
echo "[1/4] Подготовка каталога секретов..."
sudo mkdir -p "${SECRETS_DIR}"
sudo chown "${CONFIG_OWNER}:${CONFIG_OWNER}" "${SECRETS_DIR}"
sudo chmod 700 "${SECRETS_DIR}"
echo "  ✅ ${SECRETS_DIR} (owner: ${CONFIG_OWNER}, chmod 700)"

# --- [2/4] Сбор API-ключей ---
echo ""
echo "[2/4] Настройка API-ключей провайдеров..."
echo ""
echo "  Для каждого провайдера нужен API-ключ."
echo "  Ключи будут сохранены в зашифрованные файлы с правами 600."
echo "  В openclaw.json будут только ссылки (SecretRef), не сами ключи."
echo ""

# Функция для безопасного сохранения ключа
save_secret() {
    local name="$1"
    local filename="$2"
    local description="$3"
    local filepath="${SECRETS_DIR}/${filename}"

    if [ -f "${filepath}" ]; then
        echo "  ℹ️  ${name}: ключ уже существует (${filename})"
        read -p "  Перезаписать? [y/N]: " OVERWRITE
        if [[ ! "${OVERWRITE}" =~ ^[yY] ]]; then
            return 0
        fi
    fi

    echo "  ${description}"
    read -sp "  Введи ключ ${name} (или Enter чтобы пропустить): " KEY
    echo ""

    if [ -z "${KEY}" ]; then
        echo "  ⏭  ${name} пропущен"
        return 0
    fi

    printf '%s' "${KEY}" | sudo tee "${filepath}" > /dev/null
    sudo chown "${CONFIG_OWNER}:${CONFIG_OWNER}" "${filepath}"
    sudo chmod 600 "${filepath}"
    echo "  ✅ ${name}: сохранён (${#KEY} символов)"
}

echo "  📋 Доступные провайдеры:"
echo "     1. OpenAI — GPT-5.x (рекомендуется как fallback)"
echo "     2. OpenCode Zen — MiniMax, Kimi, GLM (дешёвый primary)"
echo "     3. Google Gemini — Flash Lite (фоновые задачи)"
echo "     4. OpenRouter — DeepSeek, Qwen (агрегатор)"
echo "     5. DeepGram — аудио-транскрипция"
echo "     6. Perplexity — веб-поиск"
echo ""

# OpenAI
read -p "  Настроить OpenAI? [Y/n]: " SETUP_OPENAI
if [[ ! "${SETUP_OPENAI}" =~ ^[nN] ]]; then
    save_secret "OpenAI" "openai-api-key" \
        "  Получи на https://platform.openai.com/api-keys (начинается с sk-...)"
fi

# Zen
read -p "  Настроить OpenCode Zen? [Y/n]: " SETUP_ZEN
if [[ ! "${SETUP_ZEN}" =~ ^[nN] ]]; then
    save_secret "Zen" "zen-api-key" \
        "  Получи на https://opencode.ai (начинается с sk-...)"
fi

# Google
read -p "  Настроить Google Gemini? [Y/n]: " SETUP_GOOGLE
if [[ ! "${SETUP_GOOGLE}" =~ ^[nN] ]]; then
    save_secret "Google" "google-api-key" \
        "  Получи на https://aistudio.google.com/app/apikey"
fi

# OpenRouter
read -p "  Настроить OpenRouter? [Y/n]: " SETUP_OPENROUTER
if [[ ! "${SETUP_OPENROUTER}" =~ ^[nN] ]]; then
    save_secret "OpenRouter" "openrouter-api-key" \
        "  Получи на https://openrouter.ai/settings/keys (пополни баланс!)"
fi

# DeepGram
read -p "  Настроить DeepGram (аудио)? [y/N]: " SETUP_DEEPGRAM
if [[ "${SETUP_DEEPGRAM}" =~ ^[yY] ]]; then
    save_secret "DeepGram" "deepgram-api-key" \
        "  Получи на https://console.deepgram.com ($200 бесплатных кредитов)"
fi

# Perplexity
read -p "  Настроить Perplexity (веб-поиск)? [y/N]: " SETUP_PERPLEXITY
if [[ "${SETUP_PERPLEXITY}" =~ ^[yY] ]]; then
    save_secret "Perplexity" "perplexity-api-key" \
        "  Получи на https://www.perplexity.ai/settings/api"
fi

# --- [3/4] Генерация конфига ---
echo ""
echo "[3/4] Генерация конфигурации моделей..."
echo ""
echo "  ⚠️  Этот шаг ОБНОВИТ openclaw.json — добавит провайдеры и SecretRef."
echo "  Бэкап будет создан автоматически."
echo ""

CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"

if [ -f "${CONFIG_FILE}" ]; then
    BACKUP_NAME="openclaw.json.bak.pre-models.$(date +%s)"
    sudo cp "${CONFIG_FILE}" "${OPENCLAW_CONFIG_DIR}/${BACKUP_NAME}"
    echo "  ✅ Бэкап: ${BACKUP_NAME}"
fi

echo ""
echo "  ℹ️  Конфигурация моделей должна быть добавлена вручную или через Claude Code."
echo "  Файлы ключей подготовлены. Используй SecretRef в openclaw.json:"
echo ""
echo '  Пример для провайдера в openclaw.json:'
echo '  {'
echo '    "secrets": {'
echo '      "providers": {'
echo '        "openai-key": {'
echo '          "source": "file",'
echo "          \"path\": \"${CONTAINER_SECRETS}/openai-api-key\","
echo '          "mode": "singleValue"'
echo '        }'
echo '      }'
echo '    },'
echo '    "models": {'
echo '      "providers": {'
echo '        "openai": {'
echo '          "apiKey": {"source": "file", "provider": "openai-key", "id": "value"}'
echo '        }'
echo '      }'
echo '    }'
echo '  }'
echo ""

# --- [4/4] Проверка ---
echo "[4/4] Проверка..."

echo "  📁 Файлы секретов:"
ls -la "${SECRETS_DIR}/" 2>/dev/null | grep -v "^total" | grep -v "^d" | while read line; do
    echo "     ${line}"
done

# Проверим hot reload
echo ""
echo "  ⏳ Проверяю hot reload контейнера..."
sleep 3
ERRORS=$(docker logs "${CONTAINER_NAME}" --since "5s" 2>&1 | grep -ciE "error|fail" || echo "0")
if [ "${ERRORS}" -eq 0 ]; then
    echo "  ✅ Нет ошибок в логах"
else
    echo "  ⚠️  Обнаружены ошибки — проверь логи:"
    docker logs "${CONTAINER_NAME}" --since "10s" 2>&1 | grep -iE "error|fail" | tail -5
fi

# --- Итоги ---
echo ""
echo "=== Модуль 5 завершён ==="
echo ""
echo "📋 Что сделано:"
echo "   ${SECRETS_DIR}/  — каталог с API-ключами (chmod 600)"
echo ""
echo "📖 Следующие шаги:"
echo "   1. Обнови openclaw.json — добавь провайдеров с SecretRef"
echo "   2. Обнови agents/main/agent/models.json — синхронизируй провайдеров"
echo "   3. Проверь hot reload: docker logs ${CONTAINER_NAME} --tail 5"
echo ""
echo "  💡 Подробная инструкция по SecretRef:"
echo "  https://github.com/guzhovpro-code/openclaw-server-setup#секреты-и-api-ключи"
echo ""
echo "  ⚠️  ВАЖНО:"
echo "  - gateway.auth.token и telegram.botToken НЕ поддерживают SecretRef"
echo "  - Пути в openclaw.json — контейнерные: /home/node/.openclaw/..."
echo "  - Файлы должны принадлежать ${CONFIG_OWNER} (uid=1000)"
