#!/usr/bin/env bash
# ============================================================
# Integration: MongoDB
# - Installs MongoDB 8.0 from official repo
# - Enables authentication
# - Creates users: admin (root), openclaw (readWriteAnyDatabase)
# - Binds to localhost + Docker bridge (172.17.0.1)
# - UFW rules for Docker networks
# - mongodb.sh helper script
# - Creates operational_logs database with indexes
# ============================================================
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/srv/openclaw}"
WORKSPACE_DIR="${OPENCLAW_DIR}/workspace"
WORKSPACE_SCRIPTS="${WORKSPACE_DIR}/scripts"
SECRETS_DIR="/home/${DEPLOY_USER}/.openclaw/secrets"
DOCKER_BRIDGE_IP="172.17.0.1"

echo ""
echo "=== Интеграция: MongoDB ==="
echo ""

# --- Cleanup trap ---
cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo "  ОШИБКА: Установка MongoDB прервана (код ${exit_code})"
        echo "  Скрипт идемпотентен — можно запустить повторно."
    fi
}
trap cleanup EXIT

# --- Check if already installed ---
ALREADY_INSTALLED=false
if command -v mongosh &>/dev/null || command -v mongod &>/dev/null; then
    MONGO_VER=$(mongod --version 2>/dev/null | head -1 || echo "unknown")
    echo "  MongoDB уже установлен: ${MONGO_VER}"

    if systemctl is-active --quiet mongod 2>/dev/null; then
        echo "  Сервис mongod: работает"
    else
        echo "  Сервис mongod: не запущен"
    fi

    read -p "  Переустановить/обновить? [y/N]: " REINSTALL
    if [[ ! "${REINSTALL}" =~ ^[yY] ]]; then
        echo "  Пропущено."
        exit 0
    fi
    ALREADY_INSTALLED=true
fi

# --- Create directories ---
sudo mkdir -p "${WORKSPACE_SCRIPTS}" "${SECRETS_DIR}"
sudo chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${WORKSPACE_DIR}"

# ============================================================
# [1/7] Collect passwords
# ============================================================
echo "[1/7] Настройка паролей..."
echo ""

ADMIN_PASS_FILE="${SECRETS_DIR}/mongodb-admin-password"
OPENCLAW_PASS_FILE="${SECRETS_DIR}/mongodb-openclaw-password"

# Admin password
if [ -f "${ADMIN_PASS_FILE}" ] && [ "${ALREADY_INSTALLED}" = true ]; then
    echo "  Пароль admin уже сохранён."
    read -p "  Обновить? [y/N]: " UPDATE_ADMIN
    if [[ "${UPDATE_ADMIN}" =~ ^[yY] ]]; then
        read -sp "  Новый пароль для admin (root): " ADMIN_PASS
        echo ""
        printf '%s' "${ADMIN_PASS}" | sudo tee "${ADMIN_PASS_FILE}" > /dev/null
        sudo chmod 600 "${ADMIN_PASS_FILE}"
        sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${ADMIN_PASS_FILE}"
    else
        ADMIN_PASS="$(sudo cat "${ADMIN_PASS_FILE}")"
    fi
else
    echo "  MongoDB будет настроена с аутентификацией."
    echo "  Нужны два пароля: admin (root) и openclaw (приложение)."
    echo ""
    read -sp "  Пароль для admin (root, минимум 12 символов): " ADMIN_PASS
    echo ""

    if [ ${#ADMIN_PASS} -lt 12 ]; then
        echo "  ПРЕДУПРЕЖДЕНИЕ: Пароль короче 12 символов — рекомендуется длиннее."
        read -p "  Продолжить? [y/N]: " CONTINUE
        if [[ ! "${CONTINUE}" =~ ^[yY] ]]; then
            exit 1
        fi
    fi

    printf '%s' "${ADMIN_PASS}" | sudo tee "${ADMIN_PASS_FILE}" > /dev/null
    sudo chmod 600 "${ADMIN_PASS_FILE}"
    sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${ADMIN_PASS_FILE}"
    echo "  Пароль admin сохранён"
fi

# OpenClaw password
if [ -f "${OPENCLAW_PASS_FILE}" ] && [ "${ALREADY_INSTALLED}" = true ]; then
    echo "  Пароль openclaw уже сохранён."
    read -p "  Обновить? [y/N]: " UPDATE_OC
    if [[ "${UPDATE_OC}" =~ ^[yY] ]]; then
        read -sp "  Новый пароль для openclaw: " OPENCLAW_PASS
        echo ""
        printf '%s' "${OPENCLAW_PASS}" | sudo tee "${OPENCLAW_PASS_FILE}" > /dev/null
        sudo chmod 600 "${OPENCLAW_PASS_FILE}"
        sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${OPENCLAW_PASS_FILE}"
    else
        OPENCLAW_PASS="$(sudo cat "${OPENCLAW_PASS_FILE}")"
    fi
else
    read -sp "  Пароль для openclaw (приложение): " OPENCLAW_PASS
    echo ""

    printf '%s' "${OPENCLAW_PASS}" | sudo tee "${OPENCLAW_PASS_FILE}" > /dev/null
    sudo chmod 600 "${OPENCLAW_PASS_FILE}"
    sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "${OPENCLAW_PASS_FILE}"
    echo "  Пароль openclaw сохранён"
fi

# ============================================================
# [2/7] Install MongoDB 8.0
# ============================================================
echo ""
echo "[2/7] Установка MongoDB 8.0..."

# Check if already installed and matching version
if mongod --version 2>/dev/null | grep -q "v8\."; then
    echo "  MongoDB 8.x уже установлен — пропускаю установку пакетов"
else
    # Import MongoDB public GPG key
    echo "  Импорт GPG-ключа MongoDB..."
    curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
        sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg 2>/dev/null || true

    # Detect Ubuntu version for repo
    UBUNTU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-jammy}")

    # Add repository
    echo "  Добавление репозитория (${UBUNTU_CODENAME})..."
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu ${UBUNTU_CODENAME}/mongodb-org/8.0 multiverse" | \
        sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list > /dev/null

    # Install
    echo "  Установка пакетов..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq mongodb-org

    echo "  MongoDB 8.0 установлен"
fi

# ============================================================
# [3/7] Configure MongoDB
# ============================================================
echo ""
echo "[3/7] Настройка MongoDB..."

MONGOD_CONF="/etc/mongod.conf"

# Backup original config
if [ -f "${MONGOD_CONF}" ] && [ ! -f "${MONGOD_CONF}.original" ]; then
    sudo cp "${MONGOD_CONF}" "${MONGOD_CONF}.original"
fi

# Write config: bind to localhost + Docker bridge, enable auth
sudo tee "${MONGOD_CONF}" > /dev/null << MONGOCONF
# MongoDB 8.0 configuration for OpenClaw
# Generated by openclaw-server-setup/integrations/mongodb.sh

storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 127.0.0.1,${DOCKER_BRIDGE_IP}

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

security:
  authorization: enabled
MONGOCONF

echo "  Конфиг обновлён: bindIp=127.0.0.1,${DOCKER_BRIDGE_IP}, authorization=enabled"

# ============================================================
# [4/7] Start MongoDB and create users
# ============================================================
echo ""
echo "[4/7] Запуск и создание пользователей..."

# Start without auth first to create users (if users don't exist yet)
sudo systemctl enable mongod
sudo systemctl restart mongod

# Wait for MongoDB to be ready
echo "  Ожидание запуска MongoDB..."
for i in $(seq 1 15); do
    if mongosh --quiet --eval "db.runCommand({ping: 1})" &>/dev/null 2>&1; then
        echo "  MongoDB готов"
        break
    fi
    if [ "${i}" -eq 15 ]; then
        echo "  ОШИБКА: MongoDB не запустился за 15 секунд"
        sudo journalctl -u mongod --no-pager -n 10
        exit 1
    fi
    sleep 1
done

# Check if admin user already exists
ADMIN_EXISTS=$(mongosh --quiet --eval "
    try {
        db.getSiblingDB('admin').getUser('admin') ? 'yes' : 'no'
    } catch(e) {
        'no'
    }
" 2>/dev/null || echo "no")

if [ "${ADMIN_EXISTS}" = "yes" ]; then
    echo "  Пользователь admin уже существует"

    # Update password if needed
    mongosh --quiet --eval "
        db.getSiblingDB('admin').changeUserPassword('admin', '${ADMIN_PASS}')
    " -u admin -p "${ADMIN_PASS}" --authenticationDatabase admin 2>/dev/null || \
    echo "  (пароль не обновлён — возможно, используется старый)"
else
    # Create admin user (without auth first)
    echo "  Создание пользователя admin..."

    # Temporarily disable auth to create first user
    sudo sed -i 's/authorization: enabled/authorization: disabled/' "${MONGOD_CONF}"
    sudo systemctl restart mongod
    sleep 3

    mongosh --quiet --eval "
        db.getSiblingDB('admin').createUser({
            user: 'admin',
            pwd: '${ADMIN_PASS}',
            roles: [{role: 'root', db: 'admin'}]
        })
    " 2>/dev/null
    echo "  admin создан (роль: root)"

    # Create openclaw user
    echo "  Создание пользователя openclaw..."
    mongosh --quiet --eval "
        db.getSiblingDB('admin').createUser({
            user: 'openclaw',
            pwd: '${OPENCLAW_PASS}',
            roles: [{role: 'readWriteAnyDatabase', db: 'admin'}]
        })
    " 2>/dev/null
    echo "  openclaw создан (роль: readWriteAnyDatabase)"

    # Re-enable auth
    sudo sed -i 's/authorization: disabled/authorization: enabled/' "${MONGOD_CONF}"
    sudo systemctl restart mongod
    sleep 3
fi

# ============================================================
# [5/7] UFW rules for Docker networks
# ============================================================
echo ""
echo "[5/7] Настройка UFW для Docker..."

if command -v ufw &>/dev/null; then
    # Allow MongoDB from Docker bridge network
    sudo ufw allow from 172.17.0.0/16 to any port 27017 comment "MongoDB from Docker bridge" 2>/dev/null || true

    # Allow MongoDB from Docker Compose default network
    sudo ufw allow from 172.18.0.0/16 to any port 27017 comment "MongoDB from Docker compose" 2>/dev/null || true

    # Deny MongoDB from external
    sudo ufw deny 27017 comment "Block external MongoDB" 2>/dev/null || true

    echo "  UFW: Docker networks разрешены, внешний доступ заблокирован"
else
    echo "  UFW не установлен — пропущено"
fi

# ============================================================
# [6/7] Create operational_logs database with indexes
# ============================================================
echo ""
echo "[6/7] Создание базы operational_logs..."

mongosh --quiet -u "openclaw" -p "${OPENCLAW_PASS}" --authenticationDatabase admin --eval "
    // Switch to operational_logs database
    const db = db.getSiblingDB('operational_logs');

    // Create collections if they don't exist
    const collections = db.getCollectionNames();

    if (!collections.includes('events')) {
        db.createCollection('events');
        print('  Collection events created');
    }

    if (!collections.includes('tasks')) {
        db.createCollection('tasks');
        print('  Collection tasks created');
    }

    if (!collections.includes('health_checks')) {
        db.createCollection('health_checks');
        print('  Collection health_checks created');
    }

    // Create indexes
    db.events.createIndex({timestamp: -1}, {background: true});
    db.events.createIndex({type: 1, timestamp: -1}, {background: true});
    db.events.createIndex({source: 1}, {background: true});

    db.tasks.createIndex({created_at: -1}, {background: true});
    db.tasks.createIndex({status: 1}, {background: true});
    db.tasks.createIndex({assignee: 1, status: 1}, {background: true});

    db.health_checks.createIndex({timestamp: -1}, {background: true});
    db.health_checks.createIndex({timestamp: 1}, {expireAfterSeconds: 2592000}); // TTL 30 days

    print('  Indexes created');
" 2>/dev/null || echo "  ПРЕДУПРЕЖДЕНИЕ: Не удалось создать БД (проверь пароль)"

echo "  База operational_logs готова"

# ============================================================
# [7/7] Create mongodb.sh helper script
# ============================================================
echo ""
echo "[7/7] Создание mongodb.sh скрипта..."

cat > "${WORKSPACE_SCRIPTS}/mongodb.sh" << 'MONGOSH'
#!/usr/bin/env bash
# ============================================================
# mongodb.sh — helper for MongoDB operations
# Usage:
#   mongodb.sh status                    Check MongoDB status
#   mongodb.sh shell [db]                Open mongosh
#   mongodb.sh log <type> <message>      Add event to operational_logs
#   mongodb.sh query <db> <collection> <filter_json>
#   mongodb.sh stats                     Show DB stats
#   mongodb.sh backup [output_dir]       Dump databases
#   mongodb.sh users                     List users
# ============================================================
set -euo pipefail

SECRETS_DIR="${HOME}/.openclaw/secrets"
ADMIN_PASS="$(cat "${SECRETS_DIR}/mongodb-admin-password" 2>/dev/null || echo "")"
OPENCLAW_PASS="$(cat "${SECRETS_DIR}/mongodb-openclaw-password" 2>/dev/null || echo "")"

mongo_cmd() {
    local user="${1:-openclaw}"
    local pass="${2:-${OPENCLAW_PASS}}"
    shift 2 || true
    mongosh --quiet -u "${user}" -p "${pass}" --authenticationDatabase admin "$@"
}

case "${1:-help}" in
    status)
        echo "=== MongoDB Status ==="
        if systemctl is-active --quiet mongod; then
            echo "  Сервис: работает"
        else
            echo "  Сервис: ОСТАНОВЛЕН"
        fi
        mongod --version 2>/dev/null | head -1 | sed 's/^/  Версия: /'
        mongo_cmd openclaw "${OPENCLAW_PASS}" --eval "
            const st = db.serverStatus();
            print('  Uptime: ' + Math.round(st.uptime/3600) + ' часов');
            print('  Connections: ' + st.connections.current);
        " 2>/dev/null || echo "  Не удалось подключиться"
        ;;

    shell)
        DB="${2:-admin}"
        echo "Подключение к ${DB}..."
        mongosh -u openclaw -p "${OPENCLAW_PASS}" --authenticationDatabase admin "${DB}"
        ;;

    log)
        TYPE="${2:?Укажи тип события (info/warn/error/task)}"
        MESSAGE="${3:?Укажи сообщение}"
        SOURCE="${4:-script}"
        mongo_cmd openclaw "${OPENCLAW_PASS}" --eval "
            db.getSiblingDB('operational_logs').events.insertOne({
                type: '${TYPE}',
                message: '${MESSAGE}',
                source: '${SOURCE}',
                timestamp: new Date()
            });
            print('Event logged');
        " 2>/dev/null
        ;;

    query)
        DB="${2:?Укажи БД}"
        COLLECTION="${3:?Укажи коллекцию}"
        FILTER="${4:-{}}"
        mongo_cmd openclaw "${OPENCLAW_PASS}" --eval "
            const results = db.getSiblingDB('${DB}').getCollection('${COLLECTION}').find(${FILTER}).limit(20).toArray();
            printjson(results);
        " 2>/dev/null
        ;;

    stats)
        echo "=== Database Stats ==="
        mongo_cmd openclaw "${OPENCLAW_PASS}" --eval "
            const dbs = db.adminCommand({listDatabases: 1});
            dbs.databases.forEach(d => {
                print('  ' + d.name + ': ' + Math.round(d.sizeOnDisk/1024) + ' KB');
            });
            print('  Total: ' + Math.round(dbs.totalSize/1024/1024) + ' MB');
        " 2>/dev/null
        ;;

    backup)
        OUTPUT="${2:-/srv/openclaw/logs/mongodb-backup-$(date +%Y%m%d)}"
        echo "Бэкап в ${OUTPUT}..."
        mongodump -u admin -p "${ADMIN_PASS}" --authenticationDatabase admin --out "${OUTPUT}" 2>/dev/null
        echo "Готово: ${OUTPUT}"
        ;;

    users)
        echo "=== MongoDB Users ==="
        mongo_cmd admin "${ADMIN_PASS}" --eval "
            db.getSiblingDB('admin').getUsers().users.forEach(u => {
                print('  ' + u.user + ' — ' + u.roles.map(r => r.role + '@' + r.db).join(', '));
            });
        " 2>/dev/null
        ;;

    help|*)
        echo "mongodb.sh — помощник для MongoDB"
        echo ""
        echo "Команды:"
        echo "  status                         Статус MongoDB"
        echo "  shell [db]                     Открыть mongosh"
        echo "  log <type> <message> [source]  Логировать событие"
        echo "  query <db> <collection> [filter] Запросить данные"
        echo "  stats                          Статистика БД"
        echo "  backup [dir]                   Бэкап БД"
        echo "  users                          Список пользователей"
        ;;
esac
MONGOSH
chmod +x "${WORKSPACE_SCRIPTS}/mongodb.sh"
echo "  mongodb.sh создан"

# ============================================================
# Report
# ============================================================
echo ""
echo "=== MongoDB: установлен ==="
echo ""
echo "  Версия: $(mongod --version 2>/dev/null | head -1 || echo "N/A")"
echo "  Статус: $(systemctl is-active mongod 2>/dev/null || echo "unknown")"
echo "  Порт: 27017 (localhost + Docker bridge ${DOCKER_BRIDGE_IP})"
echo "  Авторизация: включена"
echo ""
echo "  Пользователи:"
echo "    admin    — root (полный доступ)"
echo "    openclaw — readWriteAnyDatabase (приложение)"
echo ""
echo "  Файлы:"
echo "    ${WORKSPACE_SCRIPTS}/mongodb.sh"
echo "    ${SECRETS_DIR}/mongodb-admin-password"
echo "    ${SECRETS_DIR}/mongodb-openclaw-password"
echo ""
echo "  Строка подключения (из Docker):"
echo "    mongodb://openclaw:<password>@${DOCKER_BRIDGE_IP}:27017/operational_logs?authSource=admin"
echo ""
echo "  Проверить:"
echo "    ${WORKSPACE_SCRIPTS}/mongodb.sh status"
echo "    ${WORKSPACE_SCRIPTS}/mongodb.sh stats"
echo ""
