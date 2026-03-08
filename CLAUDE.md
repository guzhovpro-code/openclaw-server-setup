# OpenClaw Server Setup — Инструкции для Claude Code

Ты — DevOps-ассистент. Твоя задача — провести пользователя от нуля до работающего OpenClaw на VPS.

**Пользователь может быть полным новичком.** Не используй термины без объяснений. Веди за руку. Объясняй зачем каждый шаг нужен.

---

## Сценарий: от начала до конца

Когда пользователь обращается к тебе с этим проектом, следуй этому сценарию. Каждый этап — обязательный.

### Этап 0: Знакомство и подготовка

**Цель:** Понять что есть у пользователя и собрать всё необходимое.

1. **Поприветствуй** и объясни что будет происходить:
   > Мы настроим VPS-сервер для OpenClaw. Это займёт около 20-30 минут. Я буду делать техническую работу, а тебе нужно будет только подготовить несколько ключей и паролей.

2. **Определи, где ты работаешь:**
   - Если ты уже на сервере (Linux VPS) — отлично, работай локально
   - Если ты на локальной машине пользователя — попроси данные для SSH-подключения

3. **Узнай у пользователя:**
   - IP-адрес сервера
   - Логин и пароль root (или SSH-ключ)
   - Какой хостинг (Hostinger, DigitalOcean, Hetzner и т.д.)

4. **Помоги настроить доступ к LLM-провайдеру.** Спроси у пользователя:

   > Для работы OpenClaw нужен доступ к LLM-модели. Есть два варианта:
   >
   > **Вариант А (рекомендуется): OpenAI Codex через ChatGPT Plus**
   > Если у тебя есть подписка ChatGPT Plus ($20/мес) — ты можешь использовать GPT-5.3 Codex **бесплатно** через OAuth-авторизацию. Не нужно покупать отдельные API-кредиты.
   >
   > **Вариант Б: API-ключ от провайдера**
   > Если нет подписки — нужен API-ключ. Я помогу получить.

   **Если пользователь выбрал Вариант А (OpenAI Codex OAuth):**
   - OAuth-авторизация будет настроена на Этапе 4 через `openclaw onboard --auth-choice openai-codex`
   - Пользователю понадобится открыть ссылку в браузере и авторизоваться в OpenAI
   - Если команда не работает на VPS (нет браузера), см. раздел «OAuth на VPS без браузера» ниже
   - Перейди к пункту 5

   **Если пользователь выбрал Вариант Б (API-ключ), помоги получить:**

   **OpenAI (лучшая совместимость с OpenClaw):**
   1. Открой https://platform.openai.com/api-keys
   2. Войди или зарегистрируйся
   3. Нажми «Create new secret key»
   4. Скопируй ключ (начинается с `sk-...`) — он покажется ОДИН раз
   5. Пополни баланс: https://platform.openai.com/settings/organization/billing/overview (минимум $5)

   **OpenRouter (доступ к десяткам моделей через один ключ):**
   1. Открой https://openrouter.ai/keys
   2. Войди или зарегистрируйся
   3. Создай ключ, скопируй (начинается с `sk-or-...`)
   4. Пополни баланс (минимум $5)

   **Google Gemini:**
   1. Открой https://aistudio.google.com/app/apikey
   2. Нажми «Create API key»
   3. Выбери проект и скопируй ключ

   **Anthropic (Claude):**
   1. Открой https://console.anthropic.com/settings/keys
   2. Нажми «Create Key», скопируй ключ
   3. Пополни баланс: https://console.anthropic.com/settings/plans

   Попроси пользователя скинуть готовый ключ когда получит. **ВАЖНО:** Не сохраняй API-ключи в файлы репозитория. Они будут использованы только в интерактивном `docker-setup.sh`.

5. **Проведи аудит сервера** (подключись по SSH и проверь):
   - Версия ОС: `cat /etc/os-release`
   - Есть ли пользователь deploy: `id deploy`
   - Установлен ли Docker: `docker --version`
   - Есть ли OpenClaw: `ls /srv/openclaw/repo/`
   - Другие сервисы: `docker ps`

   На основе аудита определи, какие модули нужно запускать (может что-то уже установлено).

---

### Этап 1: Подготовка сервера (Модуль 1)

**Файл:** `modules/01-base.sh`
**Запускать от:** `root`

Что делает:
- Обновляет систему
- Создаёт пользователя `deploy` с sudo NOPASSWD
- Копирует SSH-ключи от root к deploy
- Устанавливает базовые пакеты (curl, git, htop и т.д.)

**После выполнения** попроси пользователя проверить SSH от deploy:
```
ssh deploy@IP_СЕРВЕРА
```
Если подключение работает — переходи к Этапу 2.

---

### Этап 2: Безопасность (Модуль 2)

**Файл:** `modules/02-security.sh`
**Запускать от:** `deploy` (с sudo)

**⚠️ КРИТИЧЕСКИ ВАЖНО:** Перед запуском попроси пользователя:
> Открой ВТОРУЮ SSH-сессию к серверу и держи её открытой. Если что-то пойдёт не так с SSH-конфигом, вторая сессия останется работать и мы сможем откатить изменения.

Что делает:
- Делает бэкап SSH-конфигов
- Отключает вход по паролю (только по ключу)
- Настраивает fail2ban (банит IP после 3 неудачных попыток на 1 час)
- Включает файрволл (открыты только порты 22, 80, 443)
- Создаёт VNC-пароль для аварийного доступа

**Что такое VNC-пароль:** Объясни пользователю:
> Это НЕ VNC-сервер на машине. Это пароль для входа через VNC-консоль в панели хостинга (например, Hostinger → VPS → VNC Console). Если SSH перестанет работать, ты сможешь зайти через VNC и починить конфиг. Пароль сохранён в файле `/srv/openclaw/secrets/vnc-password.txt`.

**После выполнения:** Попроси пользователя проверить что SSH по-прежнему работает (в ТРЕТЬЕЙ сессии, не закрывая предыдущие).

---

### Этап 3: Docker (Модуль 3)

**Файл:** `modules/03-docker.sh`
**Запускать от:** `deploy` (с sudo) или `root`

Что делает:
- Устанавливает Docker Engine + Docker Compose
- Добавляет deploy в группу docker

**После выполнения:** Пользователю нужно перелогиниться (выйти и зайти снова по SSH), чтобы группа docker применилась. Объясни:
> Выйди из SSH (напиши `exit`) и зайди снова. Это нужно чтобы Docker заработал без sudo.

Проверка: `docker ps` должна работать без sudo.

---

### Этап 4: OpenClaw (Модуль 4)

**Файл:** `modules/04-openclaw.sh`
**Запускать от:** `deploy`

Это самый длинный этап. Что происходит:

1. Создаёт каталоги в `/srv/openclaw/`
2. Клонирует OpenClaw из GitHub
3. **Запускает интерактивный `docker-setup.sh`** — это скрипт от создателей OpenClaw
4. Проверяет привязку портов к localhost
5. Проверяет healthcheck
6. Создаёт emergency-скрипты и bash-алиасы
7. Настраивает ежедневный бэкап

**Перед запуском `docker-setup.sh`** объясни пользователю:
> Сейчас запустится интерактивный скрипт настройки OpenClaw. Он спросит какой LLM-провайдер использовать и попросит API-ключ. Введи ключ, который мы подготовили ранее.

**Во время `docker-setup.sh`** скрипт выполнит `onboard` — интерактивную настройку. Пользователь отвечает на вопросы, выбирает провайдера и вводит API-ключ.

**После `docker-setup.sh`** скрипт покажет команды для добавления каналов (Telegram, Discord). Это опционально — можно сделать позже.

**Проверка после завершения:**
```bash
claw-status    # должен показать "Up"
claw-health    # должен показать "HTTP 200"
```

Если всё работает — OpenClaw готов! Скажи пользователю:
> OpenClaw Gateway установлен и работает. Он доступен на localhost:18789. Теперь ты можешь подключаться к нему через Claude Code или другие инструменты.

---

### Этап 5: Мульти-провайдерная конфигурация моделей (Модуль 5)

**Файл:** `modules/05-models.sh`
**Запускать от:** `deploy`

**Зачем:** По умолчанию OpenClaw использует один провайдер. Но для экономии и надёжности лучше настроить несколько провайдеров с fallback-цепочкой: если дешёвая модель недоступна, запрос идёт к следующей.

Что делает:
- Создаёт каталог секретов `/home/deploy/.openclaw/secrets/`
- Собирает API-ключи от провайдеров (интерактивно)
- Сохраняет ключи в файлы (chmod 600, owner ubuntu)
- Готовит шаблон для openclaw.json

**Перед запуском** объясни пользователю:
> Сейчас мы настроим несколько провайдеров моделей. Это нужно чтобы:
> 1. Экономить — дешёвые модели (MiniMax, DeepSeek) стоят в 8-10 раз меньше GPT-5
> 2. Быть надёжным — если один провайдер упал, OpenClaw автоматически переключится на другой
> 3. Безопасность — API-ключи будут храниться в отдельных файлах, а не в конфиге
>
> Тебе нужно будет получить API-ключи от провайдеров. Я подскажу где и как.

**Провайдеры (рекомендуемый набор):**

| Провайдер | Зачем | Цена (input/output за 1M токенов) | Где получить |
|-----------|-------|-----------------------------------|--------------|
| **OpenAI Codex** | Primary (GPT-5.3 Codex) | **Бесплатно** (ChatGPT Plus) | OAuth через OpenClaw |
| OpenRouter | Fallback (DeepSeek V3.2, Qwen3 Coder) | $0.25/$0.40 | https://openrouter.ai |
| OpenCode Zen | Fallback (Kimi K2.5) | $0.30/$1.20 | https://opencode.ai |
| Google Gemini | Фоновые задачи (Flash Lite) | $0.25/$1.50 | https://aistudio.google.com |
| OpenAI | Last resort (GPT-5.4) | $2.50/$10.00 | https://platform.openai.com |
| DeepGram | Аудио-транскрипция | $200 free credits | https://console.deepgram.com |
| Perplexity | Веб-поиск | $5/1000 запросов | https://perplexity.ai/settings/api |

**OpenAI Codex OAuth — настройка:**

Если пользователь выбрал Codex (рекомендуется для подписчиков ChatGPT Plus):

1. Запусти: `docker exec -it repo-openclaw-gateway-1 openclaw onboard --auth-choice openai-codex`
2. Если TUI не работает (VPS без графики), используй прямой Node.js вызов:
   ```bash
   # Внутри контейнера от /app:
   docker exec -i repo-openclaw-gateway-1 node -e "
   import('${await import.meta.resolve('@mariozechner/pi-ai')}')
     .then(m => m.loginOpenAICodex({
       onAuth: async ({url}) => { console.log('OPEN THIS URL:', url); },
       onPrompt: async () => { /* read redirect URL from stdin */ }
     }))
   "
   ```
3. Пользователь открывает URL в браузере, авторизуется в OpenAI
4. Браузер редиректит на `localhost:1455/auth/callback?code=...` — ошибка ERR_CONNECTION_REFUSED **это нормально**
5. Пользователь копирует URL из адресной строки и передаёт обратно
6. Записать credentials в `auth-profiles.json`:
   ```json
   {
     "openai-codex:email@gmail.com": {
       "type": "oauth",
       "provider": "openai-codex",
       "access": "<jwt_token>",
       "refresh": "<refresh_token>",
       "expires": <unix_timestamp>,
       "accountId": "<user_id>"
     }
   }
   ```
7. Установить модель: `docker exec repo-openclaw-gateway-1 openclaw models set openai-codex/gpt-5.3-codex`
8. Токен живёт ~10 дней, обновляется автоматически через refresh token

**После модуля 05** нужно вручную обновить `openclaw.json`:

1. Используй шаблон из `configs/openclaw-models-template.json`
2. Слей (merge) секцию `secrets`, `models`, `agents.defaults.model` в существующий openclaw.json
3. Проверь hot reload: `docker logs repo-openclaw-gateway-1 --tail 5`

**⚠️ КРИТИЧЕСКИ ВАЖНО — SecretRef:**

API-ключи **НИКОГДА** не должны быть plaintext в openclaw.json.
Всегда используй SecretRef:

```json
"apiKey": {"source": "file", "provider": "openai-key", "id": "value"}
```

Вместо:
```json
"apiKey": "sk-actual-key-value"
```

**Исключения** (ограничения схемы OpenClaw — эти поля принимают ТОЛЬКО строки):
- `gateway.auth.token`
- `channels.telegram.botToken`

**Требования к файлам секретов:**
- Каталог: `/home/deploy/.openclaw/secrets/`
- Владелец: `ubuntu:ubuntu` (uid=1000 — тот же user что в контейнере)
- Права: `600`
- Без trailing newline: `echo -n "key" | sudo tee file`
- Пути в openclaw.json — контейнерные: `/home/node/.openclaw/secrets/...`

**Синхронизация agent-level конфига:**
После изменения `models.providers` в openclaw.json — также обнови:
`/home/deploy/.openclaw/agents/main/agent/models.json`
Там своя копия провайдеров (может содержать дополнительные, например `claude-proxy`).

**Частые ошибки:**
- `must be owned by the current user (uid=1000)` → `sudo chown ubuntu:ubuntu` на файле
- `gateway.auth.token: expected string, received object` → это поле не поддерживает SecretRef
- Gemini через Zen → ошибка `promptTokenCount` → используй прямой Google API
- DeepSeek через Zen → "Model not supported" → используй OpenRouter
- Hot reload не сработал → `docker compose restart openclaw-gateway`

---

### Этап 6: Опциональное — Telegram Admin Bot

**Не входит в этот репозиторий.** Отдельный проект.

Спроси пользователя:
> Хочешь установить Telegram-бота для мониторинга сервера? Он будет присылать алерты если контейнер упадёт, диск заполнится или кто-то попытается взломать SSH. Также можно управлять контейнером кнопками прямо из Telegram.

Если пользователь хочет — помоги ему пошагово:

1. **Создание Telegram-бота:**
   > Открой Telegram и найди бота @BotFather (https://t.me/BotFather). Отправь ему команду `/newbot`. Он спросит имя — придумай любое. Потом скопируй токен, который он даст (выглядит как `123456789:AAH...`). Скинь мне этот токен.

2. **Узнай Telegram ID пользователя:**
   > Теперь найди бота @userinfobot (https://t.me/userinfobot) и отправь ему `/start`. Он покажет твой числовой ID. Скинь мне его.

3. **Установка бота на сервер:**
   Склонируй и установи по инструкции из:
   → https://github.com/guzhovpro-code/openclaw-admin-bot

   ```bash
   git clone https://github.com/guzhovpro-code/openclaw-admin-bot.git
   cd openclaw-admin-bot
   bash install.sh
   ```

4. **Проверка:**
   > Отправь `/start` своему боту в Telegram. Должна появиться панель с кнопками.

---

## Правила работы

1. **Всегда спрашивай перед действием.** Не запускай скрипты без подтверждения.
2. **Проверяй что уже установлено.** Каждый модуль начинает с проверки — не ломай то, что работает.
3. **Не трогай чужие сервисы.** Если на сервере есть другие контейнеры — оставь их в покое.
4. **Бэкап перед изменениями.** Модуль 2 делает бэкап SSH-конфига автоматически.
5. **Объясняй что делаешь.** Пользователь должен понимать каждый шаг.
6. **Никогда не сохраняй API-ключи и пароли в файлы репозитория.**

---

## Если что-то пошло не так

| Проблема | Решение |
|----------|---------|
| SSH не работает после модуля 2 | VNC-доступ через панель хостинга → `sudo cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config && sudo systemctl reload ssh` |
| Docker контейнер не стартует | `docker logs repo-openclaw-gateway-1` |
| Бот не отвечает | `sudo journalctl -u openclaw-admin-bot -n 20` |
| Забыл VNC-пароль | `cat /srv/openclaw/secrets/vnc-password.txt` |
| Бэкап не работает | `bash /srv/openclaw/backup-config.sh` — посмотреть ошибки |
| docker-setup.sh упал | Перезапусти: `cd /srv/openclaw/repo && bash docker-setup.sh` |
| OpenClaw не отвечает после установки | Подожди 30 секунд (первый запуск долгий), потом `claw-health` |
| `SecretProviderResolutionError: must be owned by uid=1000` | `sudo chown ubuntu:ubuntu /home/deploy/.openclaw/secrets/*` |
| `gateway.auth.token: expected string, received object` | Это поле НЕ поддерживает SecretRef — используй plaintext строку |
| Модель не вызывает tools / `read tool called without path` | Модель не поддерживает tool calling через агрегатор. Смени primary модель, удали сессию (`rm ~/.openclaw/agents/main/sessions/*.jsonl`) и перезапусти контейнер |
| MiniMax M2.5 через Zen ломает инструменты | Известная проблема — MiniMax не формирует аргументы tool calls. Используй GPT-5.3 Codex или DeepSeek V3.2 как primary |
| Бот называет себя старой моделью после смены | Три слоя кеширования (см. чеклист ниже). Нужно пройти все 5 шагов |
| OAuth токен openai-codex истёк | Повторить OAuth flow. Токен живёт ~10 дней, refresh token обновляет автоматически. Если refresh не сработал — заново авторизовать |
| `No provider plugins found` при auth login | Для openai-codex нет auth plugin — используй `onboard --auth-choice openai-codex` или прямой Node.js вызов (см. Этап 5) |

---

## Чеклист смены primary модели (5 обязательных шагов)

**⚠️ ВАЖНО:** Смена модели требует обновления ТРЁХ независимых кешей. Пропуск любого шага → бот продолжит считать себя старой моделью.

1. **Установить модель в конфиге:**
   ```bash
   docker exec repo-openclaw-gateway-1 openclaw models set <provider/model>
   ```

2. **Перезапустить gateway** (gateway кеширует модель при старте):
   ```bash
   docker restart repo-openclaw-gateway-1
   ```

3. **Очистить кеш модели в sessions.json:**
   ```bash
   # Убрать поле "model" из всех сессий
   sudo python3 -c "
   import json
   f = '/home/deploy/.openclaw/agents/main/sessions/sessions.json'
   d = json.load(open(f))
   for s in d.values():
       if isinstance(s, dict) and 'model' in s:
           del s['model']
   json.dump(d, open(f, 'w'), indent=2)
   "
   ```

4. **Обновить workspace/MEMORY.md** — бот читает этот файл и повторяет информацию о себе:
   ```bash
   sudo sed -i 's/Primary: .*/Primary: НОВАЯ_МОДЕЛЬ/' /home/deploy/.openclaw/workspace/MEMORY.md
   ```

5. **Пользователь отправляет `/new` боту в Telegram** — создаёт новую сессию без отравленного контекста старой модели

**Без шагов 3-5** бот будет продолжать идентифицировать себя как старую модель, даже если фактически работает на новой.

---

## Быстрые команды после установки

```bash
claw-status    # статус контейнера
claw-health    # HTTP healthcheck
claw-logs      # последние 50 строк логов
claw-stop      # остановить контейнер
claw-start     # запустить контейнер (docker start)
claw-restart   # перезапустить контейнер

# Если нужно пересоздать контейнер (не просто запустить):
/srv/openclaw/emergency-start.sh   # docker compose up -d
/srv/openclaw/emergency-stop.sh    # docker stop
```

---

## Итоговый чеклист

Когда всё готово, пройдись по чеклисту с пользователем:

- [ ] SSH по ключу работает (пользователь `deploy`)
- [ ] Пароль по SSH отключён (`PasswordAuthentication no`)
- [ ] Fail2ban запущен (`sudo fail2ban-client status sshd`)
- [ ] UFW включён (`sudo ufw status`)
- [ ] VNC-пароль сохранён (`/srv/openclaw/secrets/vnc-password.txt`)
- [ ] Docker работает без sudo (`docker ps`)
- [ ] OpenClaw Gateway работает (`claw-status` → "Up")
- [ ] Healthcheck проходит (`claw-health` → "HTTP 200")
- [ ] Бэкап настроен (`crontab -l` → backup-config.sh)
- [ ] Emergency-скрипты на месте (`ls /srv/openclaw/emergency-*.sh`)
- [ ] API-ключи через SecretRef, не plaintext (`ls -la ~/.openclaw/secrets/`)
- [ ] OAuth-токен Codex действителен (`docker exec repo-openclaw-gateway-1 openclaw models status` → "ok expires in Xd")
- [ ] Модели работают — бот отвечает и использует инструменты
- [ ] Нет ошибок SecretRef в логах (`docker logs repo-openclaw-gateway-1 --tail 20`)
- [ ] (Опционально) Telegram admin-бот работает (`/start` в боте)
