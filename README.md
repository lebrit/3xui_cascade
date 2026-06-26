# 3xui_cascade

Универсальный установщик 3x-ui для двух сценариев:

- **EU сервер**: установка 3x-ui, выпуск сертификата на домен, создание inbound `VLESS + xHTTP + Reality`, создание outbound Cloudflare WARP и routing через WARP для ChatGPT/Gemini/AI/Google.
- **RU сервер**: установка 3x-ui, выпуск сертификата на домен, создание inbound `VLESS + xHTTP + Reality`, настройка каскада `RU -> EU`, интерактивное меню управления EU-резервами, прямой маршрут для российских IP и доменов.

Логин панели по умолчанию:

```text
admin
```

Пароль не хранится в репозитории. Скрипт спросит пароль при запуске скрытым вводом.

## Установка одной командой

### Интерактивный выбор EU/RU

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lebrit/3xui_cascade/main/install_3xui_cascade.sh)
```

### Сразу установка EU сервера

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lebrit/3xui_cascade/main/install_3xui_cascade.sh) --eu
```

### Сразу установка RU сервера

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lebrit/3xui_cascade/main/install_3xui_cascade.sh) --ru
```

## Установка с заранее заданным паролем

```bash
PANEL_PASS='your-password' bash <(curl -fsSL https://raw.githubusercontent.com/lebrit/3xui_cascade/main/install_3xui_cascade.sh) --eu
```

или для RU:

```bash
PANEL_PASS='your-password' bash <(curl -fsSL https://raw.githubusercontent.com/lebrit/3xui_cascade/main/install_3xui_cascade.sh) --ru
```

## Что спросит скрипт

1. Роль сервера: EU или RU, если не передан флаг `--eu` или `--ru`.
2. Пароль панели 3x-ui, если не передана переменная `PANEL_PASS`.
3. Домен сервера.
4. Для RU сервера: VLESS share link от EU inbound для создания каскада `RU -> EU`.

## Настройки по умолчанию

```text
PANEL_USER=admin
PANEL_PORT=2053
PANEL_PATH=admin
INBOUND_PORT=443
INBOUND_PATH=/vless-path
CLIENT_EMAIL=admin
```

Можно переопределить переменными окружения:

```bash
PANEL_USER=admin PANEL_PORT=2053 PANEL_PATH=admin INBOUND_PORT=443 bash <(curl -fsSL https://raw.githubusercontent.com/lebrit/3xui_cascade/main/install_3xui_cascade.sh) --ru
```

## RU меню управления каскадом

После установки RU сервера доступно меню:

```bash
ru-eu-menu
```

Или команды напрямую:

```bash
ru-eu-manager list
ru-eu-manager add
ru-eu-manager set main
ru-eu-manager del main
ru-eu-manager balancer on
ru-eu-manager balancer off
ru-eu-manager rebuild
ru-eu-manager routing
ru-eu-manager status
ru-eu-manager logs
```

## Логика маршрутизации RU сервера

```text
Российские IP                  -> direct
Российские домены              -> direct
DNS Google/Cloudflare          -> direct
ChatGPT QUIC UDP/443           -> blocked
ChatGPT/OpenAI/Gemini/AI       -> активная EU нода или balancer
Google IP ranges               -> активная EU нода или balancer
BitTorrent                     -> blocked
Private IP                     -> blocked
Остальное                      -> direct
```

Российские IP/домены добавлены выше правил на EU, потому что в Xray routing первое совпавшее правило выигрывает.

## Добавление резервного EU сервера

На RU сервере:

```bash
ru-eu-menu
```

Выбрать:

```text
1) Добавить EU сервер
```

После этого вставить VLESS share link с нового EU inbound.

Для включения автоматического резерва:

```bash
ru-eu-manager balancer on
```

Для возврата к одному активному EU серверу:

```bash
ru-eu-manager balancer off
```

## Файлы с данными после установки

EU сервер:

```text
/root/eu_client_info.txt
```

RU сервер:

```text
/root/ru_client_info.txt
```

## Требования

- Ubuntu 22.04/24.04.
- Root доступ.
- Домен должен указывать A-записью на IP сервера.
- Порт `80/tcp` должен быть свободен для выпуска сертификата Let's Encrypt.
- Порт `443/tcp` должен быть свободен для inbound.

## Важно

Репозиторий публичный, поэтому не храните здесь пароли, приватные ключи и персональные конфиги. Пароль панели вводится при запуске и не записывается в GitHub.
