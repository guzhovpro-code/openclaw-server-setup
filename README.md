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
   - Минимум: 1 ГБ RAM, 20 ГБ диска, 1 vCPU
   - Рекомендуется: 2 ГБ RAM, 40 ГБ диска
2. **Claude Code** — [установите](https://docs.anthropic.com/en/docs/claude-code/overview), если ещё нет
3. **Доступ к LLM-провайдеру** — OpenClaw использует LLM для работы. Есть два варианта:

   **Вариант А: OpenAI Codex через подписку ChatGPT Plus (рекомендуется)**
   - Если у вас есть подписка ChatGPT Plus ($20/мес) — GPT-5.3 Codex доступен **бесплатно** через OAuth
   - Не нужно покупать отдельные API-кредиты
   - Claude Code поможет настроить OAuth-авторизацию

   **Вариант Б: API-ключ от провайдера**

   | Провайдер | Где получить ключ | Примечание |
   |-----------|-------------------|------------|
   | **OpenAI** | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | Лучшая совместимость с OpenClaw |
   | OpenRouter | [openrouter.ai/keys](https://openrouter.ai/keys) | Десятки моделей через один ключ |
   | Google Gemini | [aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey) | |
   | Anthropic | [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) | |

   Claude Code проведёт через получение ключа пошагово, если не знаете как

## Как начать

Откройте Claude Code и отправьте ему сообщение:

> Настрой мой VPS-сервер для OpenClaw по инструкциям из https://github.com/guzhovpro-code/openclaw-server-setup
>
> Данные сервера:
> - IP: _(ваш IP из панели хостинга)_
> - Логин: root
> - Пароль: _(пароль из панели хостинга)_

Claude Code прочитает инструкции из репозитория, подключится к серверу и проведёт через всю настройку. Вам нужно будет только отвечать на вопросы и подготовить API-ключ (Claude Code подскажет как).

> **Где взять IP и пароль?** В панели вашего хостинга. Например, в Hostinger: VPS → Manage → SSH Access. Там будет IP-адрес и root-пароль.

> **Безопасность:** Пароль root используется только для первоначальной настройки. После настройки вход по паролю будет отключён (только по SSH-ключу). Claude Code не хранит и не передаёт ваши пароли.

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

### Шаг 5: Мульти-провайдерная конфигурация (опционально, рекомендуется)

Настройте несколько провайдеров моделей для экономии и надёжности:

| Провайдер | Роль | Цена | Примечание |
|-----------|------|------|------------|
| **OpenAI Codex** | Primary (GPT-5.3 Codex) | **Бесплатно** | Через ChatGPT Plus подписку (OAuth) |
| OpenRouter | Fallback (DeepSeek V3.2) | $0.25/$0.40 | Агрегатор десятков моделей |
| OpenCode Zen | Fallback (Kimi K2.5) | $0.30/$1.20 | Быстрые дешёвые модели |
| Google Gemini | Фоновые задачи | $0.25/$1.50 | Flash Lite для лёгких задач |
| OpenAI | Last resort (GPT-5.4) | $2.50/$10.00 | API ключ, отдельно от Codex |

Claude Code проведёт через настройку пошагово. API-ключи хранятся безопасно (SecretRef), OAuth-токены обновляются автоматически.

### Секреты и API-ключи

API-ключи **никогда** не хранятся в JSON-конфигах. Вместо этого используется система SecretRef:

1. Ключ сохраняется в файл: `/home/deploy/.openclaw/secrets/<имя-ключа>` (chmod 600)
2. В `openclaw.json` указывается ссылка: `{"source": "file", "provider": "<alias>", "id": "value"}`

Подробнее — в `CLAUDE.md` (Этап 5).

### Telegram-бот для мониторинга (опционально)

Хотите управлять сервером из Telegram и получать алерты при сбоях?

→ [openclaw-admin-bot](https://github.com/guzhovpro-code/openclaw-admin-bot)

Бот даёт:
- Кнопки управления контейнером прямо в Telegram
- Автоматические уведомления если контейнер упал, диск заполнен или кто-то атакует SSH
- Отчёт о состоянии сервера по команде

## Интеграции (опционально)

После базовой установки (шаги 1-5) можно подключить дополнительные модули. Каждый модуль **независим** — устанавливайте только то, что нужно. Запустите интерактивный выбор:

```bash
bash modules/06-integrations.sh
```

Или установите нужные модули напрямую: `bash integrations/<модуль>.sh`

| Интеграция | Что даёт | Нужно подготовить |
|------------|----------|-------------------|
| **Мониторинг** | Healthcheck каждые 5 мин, авто-бэкап конфигов на GitHub, Telegram-алерты при сбоях (контейнер упал, диск полный, мало RAM) | Telegram-бот (через @BotFather), Chat ID, приватный GitHub-репо |
| **Notion** | Подключение бота к Notion — базы Sync Hub, Tasks, Resources для совместной работы CC и бота | Notion Integration Token (https://notion.so/my-integrations) |
| **MongoDB** | Локальная MongoDB 8.0 с авторизацией — для operational_logs, хранения данных бота, аналитики | Два пароля (admin и openclaw) |
| **n8n** | Платформа автоматизации workflow — Instagram, транскрипция аудио, кастомные цепочки. Docker-контейнер с Traefik (HTTPS) или localhost | Домен (если нужен HTTPS), пароль для Basic Auth |
| **CC Bridge** | Claude Code CLI агент прямо на сервере — выполняет сложные задачи из Telegram. systemd-сервис, очередь задач, автоматические отчёты | OAuth-токен Claude (через `claude setup-token` на локальной машине) |
| **Диагностика** | Полная проверка системы (30+ тестов): инфра, Docker, прокси, модели, финбезопасность, бэкапы, маршрутизация. Ночной cron | Нет |
| **Failover Monitor** | Отслеживает переключения моделей из логов. Уведомление в Telegram при смене primary модели | Telegram-бот |

**Все модули идемпотентны** — безопасно запускать повторно для обновления или переконфигурации.

## Если что-то пошло не так

| Проблема | Что делать |
|----------|-----------|
| Не могу подключиться по SSH | Зайдите через VNC-консоль в панели хостинга |
| Забыл VNC-пароль | `cat /srv/openclaw/secrets/vnc-password.txt` |
| OpenClaw не отвечает | `claw-logs` — посмотрите ошибки |
| Нужно откатить SSH | `sudo cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config && sudo systemctl reload ssh` |
| Бот называет себя старой моделью | Смена модели = 5 шагов. Подробности в CLAUDE.md (Этап 5) |
| OAuth токен истёк | Повторить OAuth-авторизацию через `openclaw onboard --auth-choice openai-codex` |

## Структура файлов

```
openclaw-server-setup/
├── CLAUDE.md                         # Инструкции для Claude Code
├── README.md                         # Этот файл
├── modules/
│   ├── 01-base.sh                    # Подготовка сервера
│   ├── 02-security.sh                # Безопасность
│   ├── 03-docker.sh                  # Docker
│   ├── 04-openclaw.sh                # OpenClaw Gateway
│   ├── 05-models.sh                  # Провайдеры моделей + SecretRef
│   └── 06-integrations.sh            # Интерактивный выбор интеграций
├── integrations/
│   ├── monitoring.sh                 # Healthcheck + бэкап + Telegram-алерты
│   ├── notion.sh                     # Notion API + базы данных
│   ├── mongodb.sh                    # MongoDB 8.0 + авторизация
│   ├── n8n.sh                        # n8n автоматизация (Docker)
│   ├── cc-bridge.sh                  # Claude Code CLI агент (systemd)
│   ├── diagnostic.sh                 # Полная диагностика системы (30 проверок)
│   └── model-failover-monitor.sh     # Мониторинг переключения моделей
└── configs/
    ├── fail2ban-jail.local           # Настройки защиты от brute-force
    └── openclaw-models-template.json # Шаблон конфигурации моделей
```

## Лицензия

MIT
