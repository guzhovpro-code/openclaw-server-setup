# OpenClaw Server Setup

Модульный набор скриптов для настройки VPS-сервера под [OpenClaw](https://github.com/nicepkg/openclaw).

Предназначен для использования с **Claude Code** — AI-ассистент проведёт через настройку пошагово, адаптируясь к состоянию конкретного сервера.

## Быстрый старт

```bash
git clone https://github.com/guzhovpro-code/openclaw-server-setup.git
cd openclaw-server-setup
# Открой Claude Code и он проведёт тебя через настройку
```

## Модули

| # | Модуль | Описание |
|---|--------|----------|
| 1 | **base** | Обновление системы, создание пользователя `deploy`, SSH-ключи, базовые пакеты |
| 2 | **security** | SSH-хардинг, fail2ban, UFW (22, 80, 443), VNC-пароль для аварийного доступа |
| 3 | **docker** | Docker Engine + Compose plugin, группа docker для deploy |
| 4 | **openclaw** | Клонирование OpenClaw, docker-setup.sh, healthcheck, emergency-скрипты, алиасы, бэкап |
| 5 | **monitoring** | Telegram Admin Bot — кнопки управления + автоматические алерты при сбоях |

Модули выполняются по порядку. Можно запускать выборочно — каждый модуль проверяет, что уже установлено.

## Требования

- Ubuntu 22.04+ / Debian 12+ (свежий VPS)
- Root-доступ по SSH
- Публичный SSH-ключ для пользователя `deploy`

## Структура

```
openclaw-server-setup/
├── CLAUDE.md              # Инструкции для Claude Code
├── README.md              # Документация (этот файл)
├── modules/
│   ├── 01-base.sh         # Подготовка VPS
│   ├── 02-security.sh     # SSH-хардинг + fail2ban + UFW
│   ├── 03-docker.sh       # Docker Engine
│   ├── 04-openclaw.sh     # Развёртывание OpenClaw
│   └── 05-monitoring.sh   # Telegram Admin Bot
└── configs/
    ├── fail2ban-jail.local # Конфиг fail2ban
    └── bot.py              # Telegram-бот (универсальный)
```

## Что настраивается

### Безопасность (Модуль 2)
- SSH только по ключу (парольная аутентификация отключена)
- `PermitRootLogin prohibit-password`
- Fail2ban: `maxretry=3`, `bantime=3600`, `mode=aggressive`
- UFW: только порты 22, 80, 443
- VNC-пароль для аварийного доступа через панель хостинга

### OpenClaw (Модуль 4)
- Установка в `/srv/openclaw/`
- Gateway на `127.0.0.1:18789` (только localhost)
- Emergency-скрипты: `emergency-stop.sh`, `emergency-start.sh`
- Bash-алиасы: `claw-stop`, `claw-start`, `claw-status`, `claw-restart`, `claw-logs`, `claw-health`
- Ежедневный бэкап конфигов в локальный Git (07:00 UTC)

### Мониторинг (Модуль 5)
Telegram-бот с кнопками управления и автоматическими алертами:

| Проверка | Интервал | Алерт |
|---|---|---|
| Контейнер OpenClaw | 60 сек | 🔴 при падении, 🟢 при восстановлении |
| Healthcheck `/healthz` | 120 сек | 🔴 если HTTP ≠ 200 |
| Fail2ban баны | 30 сек | 🛡 при бане нового IP |
| Диск | 5 мин | 🔴 если занято ≥ 80% |
| RAM / нагрузка | 5 мин | 🔴 если RAM ≥ 90% или load высокий |

Антиспам: повторный алерт одного типа не чаще чем раз в 30 минут.

## Безопасность

- Бот работает через long polling (не открывает портов)
- Доступ к боту ограничен одним Telegram ID
- Секреты в `.env` (не попадают в git)
- OpenClaw Gateway привязан к localhost
- SSH только по ключу после хардинга

## Ручной запуск модулей

Каждый модуль можно запустить отдельно:

```bash
# От имени root или с sudo
sudo bash modules/01-base.sh
sudo bash modules/02-security.sh
sudo bash modules/03-docker.sh

# От имени deploy (после модулей 1-3)
bash modules/04-openclaw.sh
bash modules/05-monitoring.sh
```

⚠️ **Рекомендуется** использовать через Claude Code — он проверит состояние сервера перед каждым шагом и адаптирует настройки.

## Лицензия

MIT
