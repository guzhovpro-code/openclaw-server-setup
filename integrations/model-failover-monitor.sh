#!/bin/bash
# Model Failover Monitor — отслеживает переключения моделей и уведомляет в ЦУ
# Запуск: cron */5 * * * * (вместе с healthcheck)

STATE_FILE="/tmp/openclaw-model-state.json"
GROUP_ID="-1003757508521"
TOPIC_ID="6"
BOT_TOKEN=$(cat /home/deploy/.openclaw/secrets/telegram-bot-token 2>/dev/null || sudo cat /home/deploy/.openclaw/secrets/telegram-bot-token 2>/dev/null)

if [ -z "$BOT_TOKEN" ]; then
    exit 0
fi

# Get recent model usage from logs (last 10 minutes)
MODELS_USED=$(docker logs repo-openclaw-gateway-1 --since 10m 2>&1 | \
    grep -oP 'provider=\K[^\s]+(?=\s+model=)' | \
    sort -u)

# Alternative: parse "embedded run start" lines
AGENT_MODELS=$(docker logs repo-openclaw-gateway-1 --since 10m 2>&1 | \
    grep "embedded run start" | \
    grep -oP 'provider=\K\S+\s+model=\S+' | \
    sed 's/ model=/\//' | \
    sort -u)

if [ -z "$AGENT_MODELS" ]; then
    exit 0
fi

# Load previous state
PREV_STATE=""
if [ -f "$STATE_FILE" ]; then
    PREV_STATE=$(cat "$STATE_FILE")
fi

CURRENT_STATE=$(echo "$AGENT_MODELS" | sort)

# Compare
if [ "$CURRENT_STATE" != "$PREV_STATE" ] && [ -n "$PREV_STATE" ]; then
    # Models changed! Check for fallbacks
    NEW_MODELS=$(comm -13 <(echo "$PREV_STATE") <(echo "$CURRENT_STATE"))
    GONE_MODELS=$(comm -23 <(echo "$PREV_STATE") <(echo "$CURRENT_STATE"))
    
    if [ -n "$NEW_MODELS" ] || [ -n "$GONE_MODELS" ]; then
        MSG="⚡ *Переключение модели*%0A"
        if [ -n "$GONE_MODELS" ]; then
            MSG="${MSG}Ушли: $(echo $GONE_MODELS | tr '\n' ', ')%0A"
        fi
        if [ -n "$NEW_MODELS" ]; then
            MSG="${MSG}Новые: $(echo $NEW_MODELS | tr '\n' ', ')%0A"
        fi
        MSG="${MSG}Текущие: $(echo $CURRENT_STATE | tr '\n' ', ')"
        
        curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${GROUP_ID}" \
            -d "message_thread_id=${TOPIC_ID}" \
            -d "text=${MSG}" \
            -d "parse_mode=Markdown" > /dev/null 2>&1
    fi
fi

# Save current state
echo "$CURRENT_STATE" > "$STATE_FILE"
