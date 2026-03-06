#!/usr/bin/env bash
# ============================================================
# Модуль 2: Хардинг безопасности
# SSH, fail2ban, UFW, VNC-пароль
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/../configs"

echo "=== Модуль 2: Хардинг безопасности ==="
echo ""
echo "⚠️  ВАЖНО: Убедись что у тебя открыта ВТОРАЯ SSH-сессия как страховка!"
echo ""

# --- Бэкап SSH-конфига ---
echo "[1/6] Бэкап SSH-конфига..."
BACKUP_SUFFIX=$(date +%Y%m%d%H%M)
sudo cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.${BACKUP_SUFFIX}"
if [ -d /etc/ssh/sshd_config.d ]; then
    sudo cp -r /etc/ssh/sshd_config.d "/etc/ssh/sshd_config.d.backup.${BACKUP_SUFFIX}"
fi
echo "  ✅ Бэкап создан: sshd_config.backup.${BACKUP_SUFFIX}"

# --- Отключение конфликтующих override-файлов ---
echo "[2/6] Отключение override-файлов в sshd_config.d..."
if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] || continue
        sudo mv "$f" "${f}.disabled"
        echo "  Отключён: $(basename $f)"
    done
fi
echo "  ✅ Override-файлы отключены"

# --- Хардинг SSH ---
echo "[3/6] Настройка SSH..."
DEPLOY_USER="${DEPLOY_USER:-deploy}"

# Убедиться что ключевые параметры установлены
sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config

# AllowUsers и PermitRootLogin
if grep -q "^AllowUsers" /etc/ssh/sshd_config; then
    sudo sed -i "s/^AllowUsers.*/AllowUsers ${DEPLOY_USER} root/" /etc/ssh/sshd_config
else
    echo "AllowUsers ${DEPLOY_USER} root" | sudo tee -a /etc/ssh/sshd_config > /dev/null
fi

if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
    sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
else
    echo "PermitRootLogin prohibit-password" | sudo tee -a /etc/ssh/sshd_config > /dev/null
fi

# Проверка конфига
sudo sshd -t && echo "  ✅ SSH-конфиг валиден" || { echo "  ❌ ОШИБКА в конфиге! Откатываю..."; sudo cp "/etc/ssh/sshd_config.backup.${BACKUP_SUFFIX}" /etc/ssh/sshd_config; exit 1; }
sudo systemctl reload ssh
echo "  ✅ SSH перезагружен"

# --- Fail2ban ---
echo "[4/6] Настройка fail2ban..."
sudo cp "${CONFIGS_DIR}/fail2ban-jail.local" /etc/fail2ban/jail.local 2>/dev/null || \
sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
mode = aggressive
maxretry = 3
findtime = 600
bantime = 3600
EOF

sudo systemctl restart fail2ban
echo "  ✅ Fail2ban настроен (maxretry=3, bantime=1 час)"

# --- UFW ---
echo "[5/6] Настройка UFW..."
sudo ufw default deny incoming 2>/dev/null
sudo ufw default allow outgoing 2>/dev/null
sudo ufw allow 22/tcp 2>/dev/null
sudo ufw allow 80/tcp 2>/dev/null
sudo ufw allow 443/tcp 2>/dev/null
echo "y" | sudo ufw enable 2>/dev/null
echo "  ✅ UFW включён (22, 80, 443)"

# --- Пароль для VNC ---
echo "[6/6] Установка пароля для ${DEPLOY_USER} (для VNC-аварийного доступа)..."
VNC_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
echo "${DEPLOY_USER}:${VNC_PASS}" | sudo chpasswd
echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  СОХРАНИ ПАРОЛЬ ДЛЯ VNC:             ║"
echo "  ║  Пользователь: ${DEPLOY_USER}"
echo "  ║  Пароль: ${VNC_PASS}"
echo "  ║  (только для VNC, SSH по паролю OFF)  ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# --- Итог ---
echo "=== Итог модуля 2 ==="
echo ""
sudo sshd -T 2>/dev/null | grep -i "permitrootlogin\|allowusers\|passwordauthentication\|pubkeyauthentication"
echo ""
sudo fail2ban-client status sshd 2>/dev/null | grep -E "Currently|Total" || true
echo ""
sudo ufw status | head -10
echo ""
echo "=== Модуль 2 завершён ==="
