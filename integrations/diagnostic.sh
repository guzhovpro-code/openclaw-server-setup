#!/bin/bash
# OpenClaw Full System Diagnostic v1.1
# Комплексная диагностика AI-системы

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}✅ PASS${NC}: $1"; ((PASS++)); }
fail() { echo -e "  ${RED}❌ FAIL${NC}: $1"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠️  WARN${NC}: $1"; ((WARN++)); }
section() { echo -e "\n${BOLD}${BLUE}═══ $1 ═══${NC}"; }

echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   OpenClaw Full System Diagnostic v1.1   ║${NC}"
echo -e "${BOLD}║   $(date '+%Y-%m-%d %H:%M:%S')                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

# ═══ 1. INFRASTRUCTURE ═══
section "1. INFRASTRUCTURE"

DISK_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
if [ "$DISK_PCT" -lt 70 ]; then pass "Disk: ${DISK_PCT}%"
elif [ "$DISK_PCT" -lt 85 ]; then warn "Disk: ${DISK_PCT}%"
else fail "Disk: ${DISK_PCT}% — CRITICAL"; fi

RAM_USED=$(free -m | awk 'NR==2{printf "%.0f", $3/$2*100}')
RAM_INFO=$(free -h | awk 'NR==2{print $3"/"$2}')
if [ "$RAM_USED" -lt 70 ]; then pass "RAM: ${RAM_INFO} (${RAM_USED}%)"
elif [ "$RAM_USED" -lt 85 ]; then warn "RAM: ${RAM_INFO} (${RAM_USED}%)"
else fail "RAM: ${RAM_INFO} (${RAM_USED}%) — HIGH"; fi

LOAD=$(cat /proc/loadavg | awk '{print $1}')
CORES=$(nproc)
LOAD_PCT=$(echo "$LOAD $CORES" | awk '{printf "%.0f", $1/$2*100}')
if [ "$LOAD_PCT" -lt 70 ]; then pass "Load: ${LOAD} (${CORES} cores, ${LOAD_PCT}%)"
elif [ "$LOAD_PCT" -lt 90 ]; then warn "Load: ${LOAD} (${CORES} cores, ${LOAD_PCT}%)"
else fail "Load: ${LOAD} — HIGH for ${CORES} cores"; fi

UPTIME=$(uptime -p)
pass "Uptime: $UPTIME"

# ═══ 2. DOCKER ═══
section "2. DOCKER & CONTAINERS"

if docker info >/dev/null 2>&1; then
    pass "Docker daemon running"
else
    fail "Docker daemon NOT running"
fi

OC_STATUS=$(docker ps --filter "name=repo-openclaw-gateway-1" --format "{{.Status}}" 2>/dev/null)
if [ -n "$OC_STATUS" ]; then
    pass "OpenClaw gateway: $OC_STATUS"
else
    fail "OpenClaw gateway NOT running"
fi

echo -e "  ${BLUE}Containers:${NC}"
docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null | while read line; do echo "    $line"; done

MEM_LIMIT=$(docker inspect repo-openclaw-gateway-1 --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
if [ "$MEM_LIMIT" -gt 0 ]; then
    MEM_MB=$((MEM_LIMIT / 1048576))
    pass "Container mem_limit: ${MEM_MB}MB"
else
    warn "Container has no memory limit"
fi

# ═══ 3. CLAUDE PROXY ═══
section "3. CLAUDE MAX API PROXY"

if pgrep -f "claude-max-api-proxy" >/dev/null 2>&1; then
    PROXY_PID=$(pgrep -f "claude-max-api-proxy" | head -1)
    pass "Claude proxy running (PID: $PROXY_PID)"
else
    fail "Claude proxy NOT running"
fi

if ss -tlnp | grep -q ":3456"; then
    pass "Port 3456 listening"
else
    fail "Port 3456 NOT listening"
fi

PROXY_RESP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:3456/v1/models 2>/dev/null || echo "000")
if [ "$PROXY_RESP" = "200" ]; then
    pass "Proxy responds on localhost (HTTP $PROXY_RESP)"
else
    warn "Proxy localhost response: HTTP $PROXY_RESP"
fi

DOCKER_IP=$(docker inspect repo-openclaw-gateway-1 --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' 2>/dev/null | head -c 20)
if [ -n "$DOCKER_IP" ]; then
    DOCKER_RESP=$(docker exec repo-openclaw-gateway-1 wget -q -O /dev/null --timeout=5 "http://${DOCKER_IP}:3456/v1/models" 2>&1 && echo "OK" || echo "FAIL")
    if [ "$DOCKER_RESP" = "OK" ]; then
        pass "Proxy reachable from container via $DOCKER_IP"
    else
        fail "Proxy NOT reachable from container"
    fi
fi

if (crontab -l 2>/dev/null; sudo crontab -l 2>/dev/null) 2>/dev/null | grep -q "claude-proxy\|claude_proxy"; then
    pass "Claude proxy autostart (cron)"
elif systemctl is-enabled claude-proxy 2>/dev/null | grep -q "enabled"; then
    pass "Claude proxy autostart (systemd)"
else
    warn "Claude proxy has NO autostart configured"
fi

# ═══ 4. MODELS & PROVIDERS ═══
section "4. MODELS & PROVIDERS"

CONFIG=$(sudo cat /home/deploy/.openclaw/openclaw.json 2>/dev/null)
if [ -z "$CONFIG" ]; then
    fail "Cannot read openclaw.json"
else
    pass "openclaw.json readable"
    
    echo "$CONFIG" | python3 -c "
import json, sys
c = json.load(sys.stdin)
models = c.get('models', {})
providers = models.get('providers', c.get('providers', []))
if providers:
    for p in providers:
        pid = p.get('id', '?')
        ms = p.get('models', [])
        mids = [m.get('id','?') if isinstance(m,dict) else str(m) for m in ms]
        print(f'    {pid}: {mids}')
else:
    print('  Providers: model URIs (no separate block)')
agents_obj = c.get('agents', {})
defaults = agents_obj.get('defaults', {})
dm = defaults.get('model', {})
print(f'  Default: {dm.get("primary","?")}, fallbacks: {dm.get("fallbacks",[])}')
print('  Agents:')
for a in agent_list:
    aid = a.get('id', 'default')
    m = a.get('model', {})
    primary = m.get('primary', 'default')
    fb = m.get('fallbacks', [])
    print(f'    {aid}: {primary} → {fb}')
" 2>/dev/null
fi

# ═══ 5. FINANCIAL SAFETY ═══
section "5. FINANCIAL SAFETY"

OPENAI_KEY=$(sudo cat /opt/secrets/openai-api-key 2>/dev/null | tr -d '[:space:]')
if [ -z "$OPENAI_KEY" ]; then
    pass "OpenAI API key file empty (no leak)"
else
    warn "OpenAI API key file has content — verify"
fi

echo "$CONFIG" | python3 -c "
import json, sys
c = json.load(sys.stdin)
mp = c.get('models', {}).get('providers', {})
# providers can be dict (id->config) or list
if isinstance(mp, dict):
    providers = [dict(v, id=k) for k,v in mp.items()]
elif isinstance(mp, list):
    providers = mp
else:
    providers = []
# Also check top-level
tp = c.get('providers', [])
if isinstance(tp, list):
    providers += tp
found_danger = False
for p in providers:
    pid = p.get('id', '?')
    key = p.get('apiKey', '')
    if pid == 'openai' and key and key.strip():
        ms = [m.get('id','?') if isinstance(m, dict) else str(m) for m in p.get('models', [])]
        if any('gpt-5' in m or 'o3' in m or 'o4' in m for m in ms):
            print('DANGER: GPT-5.x in paid openai: ' + str(ms))
            found_danger = True
        else:
            print('OK: paid openai has: ' + str(ms))
if found_danger:
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then pass "No GPT-5.x in paid provider"
else fail "GPT-5.x in PAID provider!"; fi

# Check inside container for leaked keys
CONTAINER_KEY_CHECK=$(docker exec repo-openclaw-gateway-1 bash -c 'grep -rl "sk-proj" /home/node/.openclaw/agents/*/agent/*.json 2>/dev/null | grep -v backups || echo "CLEAN"' 2>/dev/null || echo "SKIP")
if echo "$CONTAINER_KEY_CHECK" | grep -q "CLEAN"; then
    pass "No sk-proj keys in container agent files"
elif echo "$CONTAINER_KEY_CHECK" | grep -q "SKIP"; then
    warn "Could not check container (not running?)"
else
    fail "sk-proj keys found INSIDE container: $CONTAINER_KEY_CHECK"
fi

# Check openai provider not in config
OPENAI_PROVIDER=$(docker exec repo-openclaw-gateway-1 python3 -c "
import json
with open('/home/node/.openclaw/openclaw.json') as f:
    c = json.load(f)
p = c.get('models',{}).get('providers',{})
print('EXISTS' if 'openai' in p else 'NONE')
" 2>/dev/null || echo "SKIP")
if [ "$OPENAI_PROVIDER" = "NONE" ]; then
    pass "No paid openai provider in config"
elif [ "$OPENAI_PROVIDER" = "SKIP" ]; then
    warn "Could not check openai provider"
else
    fail "Paid openai provider still in config!"
fi

# ═══ 6. MONITORING & BACKUPS ═══
section "6. MONITORING & BACKUPS"

ALL_CRON=$(crontab -u deploy -l 2>/dev/null; crontab -u root -l 2>/dev/null)
ROOT_CRON=$(sudo crontab -l 2>/dev/null)

echo "$ALL_CRON" | grep -q "healthcheck" && pass "Healthcheck cron (*/5min)" || fail "Healthcheck cron NOT found"
echo "$ALL_CRON" | grep -q "crab-observer" && pass "Crab observer cron (*/5min)" || warn "Crab observer cron NOT found"
echo "$ALL_CRON" | grep -q "config-backup" && pass "Config backup cron (2h)" || warn "Config backup cron NOT found"
echo "$ALL_CRON" | grep -q "mongodump\|mongo_backup" && pass "MongoDB backup cron (6h)" || (echo "$ROOT_CRON" | grep -q "mongo" && pass "MongoDB backup cron (root)" || warn "MongoDB backup NOT found")

LAST_BACKUP=$(ls -t /srv/openclaw/backups/mongo/ 2>/dev/null | head -1)
if [ -n "$LAST_BACKUP" ]; then
    pass "Last MongoDB backup: $LAST_BACKUP"
else
    warn "No MongoDB backups in /srv/openclaw/backups/mongo/"
fi

# ═══ 7. SESSIONS & LOGS ═══
section "7. SESSIONS & LOGS"

SESSION_DIR="/home/deploy/.openclaw/sessions"
if [ -d "$SESSION_DIR" ]; then
    SESSION_COUNT=$(find "$SESSION_DIR" -name "*.json" 2>/dev/null | wc -l)
    LARGE_SESSIONS=$(find "$SESSION_DIR" -name "*.json" -size +1M 2>/dev/null | wc -l)
    pass "Sessions: $SESSION_COUNT files"
    [ "$LARGE_SESSIONS" -gt 0 ] && warn "Large sessions (>1MB): $LARGE_SESSIONS"
else
    pass "No session directory"
fi

LOG_PATH=$(docker inspect repo-openclaw-gateway-1 --format '{{.LogPath}}' 2>/dev/null || echo "")
if [ -n "$LOG_PATH" ]; then
    LOG_SIZE=$(sudo ls -lh "$LOG_PATH" 2>/dev/null | awk '{print $5}')
    pass "Container log size: $LOG_SIZE"
fi

RECENT_ERRORS=$(docker logs repo-openclaw-gateway-1 --since 1h 2>&1 | grep -ci "\berror\b" | grep -cv "isError=false" || true)
RECENT_ERRORS=${RECENT_ERRORS:-0}
if [ "$RECENT_ERRORS" -lt 5 ]; then pass "Recent errors (1h): $RECENT_ERRORS"
elif [ "$RECENT_ERRORS" -lt 20 ]; then warn "Recent errors (1h): $RECENT_ERRORS"
else fail "Recent errors (1h): $RECENT_ERRORS — investigate!"; fi

# ═══ 8. WORKSPACE FILES ═══
section "8. WORKSPACE FILES"

for f in SOUL.md TOOLS.md AGENTS.md; do
    if [ -f "/home/deploy/.openclaw/workspace/$f" ]; then
        SIZE=$(wc -c < "/home/deploy/.openclaw/workspace/$f")
        pass "workspace/$f ($SIZE bytes)"
    else
        warn "workspace/$f MISSING"
    fi
done

for agent in doctor engineer artist; do
    WS="/home/deploy/.openclaw/workspace-${agent}"
    if [ -d "$WS" ]; then
        FILES=$(ls "$WS"/*.md 2>/dev/null | wc -l)
        HAS_SOUL=$(test -f "$WS/SOUL.md" && echo "yes" || echo "no")
        [ "$HAS_SOUL" = "yes" ] && pass "workspace-${agent}: $FILES files, SOUL.md ✓" || fail "workspace-${agent}: SOUL.md MISSING"
    else
        fail "workspace-${agent} directory MISSING"
    fi
done

# ═══ 9. ROUTING ═══
section "9. ROUTING & TOPICS"

echo "$CONFIG" | python3 -c "
import json, sys
c = json.load(sys.stdin)
groups = c.get('channels',{}).get('telegram',{}).get('groups',{})
expected = {'3': 'doctor', '5': 'auditor', '6': 'main', '540': 'engineer', '659': 'artist'}
for gid, g in groups.items():
    topics = g.get('topics', {})
    for tid, exp_agent in expected.items():
        if tid in topics:
            actual = topics[tid].get('agentId', 'default')
            if actual == exp_agent:
                print(f'  ✅ topic:{tid} → {actual}')
            else:
                print(f'  ❌ topic:{tid} → {actual} (expected {exp_agent})')
        else:
            if exp_agent == 'main':
                print(f'  ✅ topic:{tid} → default (main)')
            else:
                print(f'  ❌ topic:{tid} NOT configured')
hl = c.get('channels',{}).get('telegram',{}).get('historyLimit', 'default')
ghl = c.get('messages',{}).get('groupChat',{}).get('historyLimit', 'default')
print(f'  historyLimit: telegram={hl}, groupChat={ghl}')
" 2>/dev/null

# ═══ SUMMARY ═══
echo -e "\n${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║               SUMMARY                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}WARN: $WARN${NC}"

TOTAL=$((PASS + FAIL + WARN))
if [ "$FAIL" -eq 0 ] && [ "$WARN" -le 2 ]; then
    echo -e "\n  ${GREEN}${BOLD}🟢 SYSTEM READY${NC}"
elif [ "$FAIL" -eq 0 ]; then
    echo -e "\n  ${YELLOW}${BOLD}🟡 SYSTEM OK (with warnings)${NC}"
else
    echo -e "\n  ${RED}${BOLD}🔴 SYSTEM HAS ISSUES${NC}"
fi
echo -e "\n  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
