# OpenClaw Server Setup

Автоматическая настройка VPS-сервера для [OpenClaw](https://github.com/nicepkg/openclaw) с помощью Claude Code.

## Что это?

Набор скриптов, которые настроят ваш сервер:
- Создадут безопасного пользователя
- Защитят SSH от взломщиков
- Установят Docker
- Развернут OpenClaw Gateway
- Настроят бэкапы

**Вам не нужно разбираться в Linux** — Claude Code проведёт вас через каждый шаг.

## Что нужно перед началом

1. **VPS-сервер** на Ubuntu 22.04 или новее (Hostinger, DigitalOcean, Hetzner и т.д.)
2. **Claude Code** — [установите](https://docs.anthropic.com/en/docs/claude-code/overview), если ещё нет
3. **API-ключ от LLM-провайдера** — OpenClaw использует LLM для работы. Claude Code подскажет как получить ключ, но можно подготовить заранее:

   | Провайдер | Где получить ключ | Примечание |
   |-----------|-------------------|------------|
   | **OpenAI** (рекомендуется) | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | Лучшая совместимость с OpenClaw |
   | Anthropic | [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) | |
   | Google Gemini | [aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey) | |

   Claude Code проведёт через получение ключа пошагово, если не знаете как

## Как начать

### Вариант 1: Claude Code на сервере (рекомендуется)

Подключитесь к серверу по SSH и запустите:

```bash
# Установите Claude Code на сервере (если ещё нет)
npm install -g @anthropic-ai/claude-code

# Скачайте скрипты настройки
git clone https://github.com/guzhovpro-code/openclaw-server-setup.git
cd openclaw-server-setup

# Запустите Claude Code — он прочитает инструкции и начнёт настройку
claude
```

Claude Code прочитает файл `CLAUDE.md` и поведёт вас по шагам.

### Вариант 2: Отправьте ссылку Claude Code

Если Claude Code работает у вас локально — просто скажите ему:

> "Настрой мой VPS для OpenClaw по инструкциям из https://github.com/guzhovpro-code/openclaw-server-setup. IP сервера: ХХХ.ХХХ.ХХХ.ХХХ, пароль root: ..."

Claude Code подключится к серверу по SSH и выполнит всё сам.

## Что будет настроено

### Шаг 1: Подготовка сервера
- Обновление системы
- Создание пользователя `deploy` (для безопасности — не работаем от root)
- Настройка SSH-ключей

### Шаг 2: Безопасность
- SSH только по ключу (пароли отключены — защита от brute-force)
- Fail2ban — автоматически банит IP, которые пытаются подобрать пароль
- Файрволл — открыты только нужные порты (22, 80, 443)
- VNC-пароль — для аварийного доступа через панель хостинга

### Шаг 3: Docker
- Docker Engine + Docker Compose для запуска контейнеров

### Шаг 4: OpenClaw
- Установка OpenClaw Gateway на localhost (безопасно, не виден извне)
- Скрипты экстренной остановки и запуска
- Удобные команды: `claw-status`, `claw-health`, `claw-stop`, `claw-start`
- Ежедневный бэкап конфигов

## После установки

### Быстрые команды

```bash
claw-status    # посмотреть состояние контейнера
claw-health    # проверить что OpenClaw отвечает
claw-logs      # последние 50 строк логов
claw-stop      # остановить
claw-start     # запустить
claw-restart   # перезапустить
```

### Telegram-бот для мониторинга (опционально)

Хотите управлять сервером из Telegram и получать алерты при сбоях?

→ [openclaw-admin-bot](https://github.com/guzhovpro-code/openclaw-admin-bot)

Бот даёт:
- Кнопки управления контейнером прямо в Telegram
- Автоматические уведомления если контейнер упал, диск заполнен или кто-то атакует SSH
- Отчёт о состоянии сервера по команде

## Если что-то пошло не так

| Проблема | Что делать |
|----------|-----------|
| Не могу подключиться по SSH | Зайдите через VNC-консоль в панели хостинга |
| Забыл VNC-пароль | `cat /srv/openclaw/secrets/vnc-password.txt` |
| OpenClaw не отвечает | `claw-logs` — посмотрите ошибки |
| Нужно откатить SSH | `sudo cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config && sudo systemctl reload ssh` |

## Структура файлов

```
openclaw-server-setup/
├── CLAUDE.md                    # Инструкции для Claude Code
├── README.md                    # Этот файл
├── modules/
│   ├── 01-base.sh               # Подготовка сервера
│   ├── 02-security.sh           # Безопасность
│   ├── 03-docker.sh             # Docker
│   └── 04-openclaw.sh           # OpenClaw
└── configs/
    └── fail2ban-jail.local      # Настройки защиты от brute-force
```

## Лицензия

MIT
