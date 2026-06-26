#!/usr/bin/env bash
set -Eeuo pipefail

# 3x-ui universal installer for EU or RU cascade servers.
# Default panel login: admin. Password is requested at runtime or can be passed as PANEL_PASS env.
# One-command usage after publishing:
#   bash <(curl -fsSL https://raw.githubusercontent.com/lebrit/3xui_cascade/main/install_3xui_cascade.sh)

PANEL_USER="${PANEL_USER:-admin}"
PANEL_PORT="${PANEL_PORT:-2053}"
PANEL_PATH="${PANEL_PATH:-admin}"
INBOUND_PORT="${INBOUND_PORT:-443}"
INBOUND_PATH="${INBOUND_PATH:-/vless-path}"
CLIENT_EMAIL="${CLIENT_EMAIL:-admin}"
DB_PATH="/etc/x-ui/x-ui.db"
COOKIE_FILE="$(mktemp)"

REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-EPXhObP9awA-sTjcWP7U8MdjuAiiBV5v7dgLi4lF5Wg}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-6yea296BrPJFtutSvVTLzHZf-__IppV0HlPnrJ66dnQ}"
REALITY_TARGET="${REALITY_TARGET:-www.sony.com:443}"
REALITY_SNI="${REALITY_SNI:-www.sony.com}"
REALITY_FP="${REALITY_FP:-firefox}"
REALITY_SHORT_IDS_JSON='["cbeb9905262506fb","4966b95be3eda1","685297e2f4c6","2ea6816b80","5d75f912","cdd358","4340","22"]'

trap 'rm -f "$COOKIE_FILE" /tmp/3xui-* 2>/dev/null || true' EXIT

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти от root: sudo -i"
}

normalize_panel_path() {
  PANEL_PATH="${PANEL_PATH#/}"
  PANEL_PATH="${PANEL_PATH%/}"
  [[ -n "$PANEL_PATH" ]] || PANEL_PATH="admin"
}

ask_panel_password() {
  if [[ -n "${PANEL_PASS:-}" ]]; then
    return 0
  fi

  echo
  echo "Логин панели по умолчанию: ${PANEL_USER}"
  echo "Пароль НЕ хранится в GitHub. Введи пароль для панели 3x-ui."
  read -rsp "Пароль панели: " PANEL_PASS
  echo
  [[ -n "$PANEL_PASS" ]] || die "Пароль не может быть пустым"
  export PANEL_PASS
}

ask_domain() {
  local label="$1"
  read -rp "Введите ${label} домен, например irk.lebrit.su: " DOMAIN
  DOMAIN="${DOMAIN// /}"
  [[ "$DOMAIN" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+[A-Za-z]{2,}$ ]] || die "Некорректный домен: $DOMAIN"
}

detect_role() {
  if [[ "${1:-}" == "--eu" || "${1:-}" == "eu" || "${ROLE:-}" == "eu" || "${ROLE:-}" == "EU" ]]; then
    ROLE="eu"
    return
  fi
  if [[ "${1:-}" == "--ru" || "${1:-}" == "ru" || "${ROLE:-}" == "ru" || "${ROLE:-}" == "RU" ]]; then
    ROLE="ru"
    return
  fi

  echo
  echo "Выбери роль сервера:"
  echo "1) EU сервер: ставит 3x-ui, inbound xHTTP+Reality, Cloudflare WARP outbound и routing в WARP"
  echo "2) RU сервер: ставит 3x-ui, inbound xHTTP+Reality, каскад RU -> EU и меню управления резервами"
  echo
  read -rp "Введите 1 или 2: " choice

  case "$choice" in
    1) ROLE="eu" ;;
    2) ROLE="ru" ;;
    *) die "Нужно выбрать 1 или 2" ;;
  esac
}

install_deps() {
  log "Установка зависимостей..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ca-certificates jq sqlite3 python3 uuid-runtime openssl dnsutils lsof zstd tar
}

check_dns_and_ports() {
  local domain="$1"
  local server_ip domain_ip

  server_ip="$(curl -4fsS --max-time 5 https://api4.ipify.org || true)"
  domain_ip="$(dig +short A "$domain" | tail -n1 || true)"

  if [[ -n "$server_ip" && -n "$domain_ip" && "$server_ip" != "$domain_ip" ]]; then
    warn "A-запись $domain сейчас указывает на $domain_ip, а IP сервера $server_ip."
    warn "Let's Encrypt может не выдать сертификат, если DNS ещё не обновился."
  fi

  if lsof -iTCP:80 -sTCP:LISTEN -P -n 2>/dev/null | grep -q LISTEN; then
    die "Порт 80 занят. Освободи 80 порт для Let's Encrypt и запусти снова."
  fi
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    log "Добавляю правила UFW, если firewall включён..."
    ufw allow OpenSSH >/dev/null || true
    ufw allow 80/tcp >/dev/null || true
    ufw allow "${PANEL_PORT}/tcp" >/dev/null || true
    ufw allow "${INBOUND_PORT}/tcp" >/dev/null || true
    ufw allow "${INBOUND_PORT}/udp" >/dev/null || true
  fi
}

install_3xui() {
  local domain="$1"

  log "Установка 3x-ui..."
  export XUI_NONINTERACTIVE=1
  export XUI_USERNAME="$PANEL_USER"
  export XUI_PASSWORD="$PANEL_PASS"
  export XUI_PANEL_PORT="$PANEL_PORT"
  export XUI_WEB_BASE_PATH="$PANEL_PATH"
  export XUI_SSL_MODE="domain"
  export XUI_DOMAIN="$domain"
  export XUI_DB_TYPE="sqlite"
  export XUI_ACME_HTTP_PORT="80"

  bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

  systemctl enable --now x-ui
  sleep 5
  [[ -f "$DB_PATH" ]] || die "Не найдена база 3x-ui: $DB_PATH"
}

panel_login() {
  local base_url="$1"
  local login_payload login_resp login_ok=0

  login_payload="$(jq -nc --arg u "$PANEL_USER" --arg p "$PANEL_PASS" '{username:$u,password:$p}')"

  for _ in $(seq 1 30); do
    login_resp="$(curl -ksS -c "$COOKIE_FILE" \
      -H "Content-Type: application/json" \
      -d "$login_payload" \
      "$base_url/login" || true)"

    if echo "$login_resp" | jq -e '.success == true' >/dev/null 2>&1; then
      login_ok=1
      break
    fi

    sleep 1
  done

  [[ "$login_ok" -eq 1 ]] || {
    echo "$login_resp" || true
    die "Не удалось войти в API панели по $base_url"
  }
}

create_xhttp_reality_inbound() {
  local domain="$1"
  local remark="$2"
  local tag="$3"
  local base_url="https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
  local client_uuid client_subid list_resp existing_ids inbound_json add_resp

  client_uuid="${CLIENT_UUID:-$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)}"
  client_subid="${CLIENT_SUBID:-$(openssl rand -hex 8)}"

  panel_login "$base_url"

  log "Удаляю старый inbound с tag=$tag или port=$INBOUND_PORT, если есть..."
  list_resp="$(curl -ksS -b "$COOKIE_FILE" "$base_url/panel/api/inbounds/list" || true)"
  existing_ids="$(
    echo "$list_resp" | jq -r \
      --arg tag "$tag" \
      --argjson port "$INBOUND_PORT" \
      '(.obj // .data // [])[]? | select(.tag == $tag or .port == $port) | .id' 2>/dev/null || true
  )"

  if [[ -n "$existing_ids" ]]; then
    for id in $existing_ids; do
      curl -ksS -b "$COOKIE_FILE" -X POST "$base_url/panel/api/inbounds/del/$id" >/dev/null || true
    done
  fi

  inbound_json="/tmp/3xui-inbound-${ROLE}.json"

  jq -n \
    --arg domain "$domain" \
    --arg path "$INBOUND_PATH" \
    --arg uuid "$client_uuid" \
    --arg email "$CLIENT_EMAIL" \
    --arg subid "$client_subid" \
    --arg tag "$tag" \
    --arg remark "$remark" \
    --arg privateKey "$REALITY_PRIVATE_KEY" \
    --arg publicKey "$REALITY_PUBLIC_KEY" \
    --arg target "$REALITY_TARGET" \
    --arg sni "$REALITY_SNI" \
    --arg fp "$REALITY_FP" \
    --argjson shortIds "$REALITY_SHORT_IDS_JSON" \
    --argjson port "$INBOUND_PORT" '
  {
    "up": 0,
    "down": 0,
    "total": 0,
    "remark": $remark,
    "enable": true,
    "expiryTime": 0,
    "listen": "",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {
          "id": $uuid,
          "flow": "",
          "email": $email,
          "limitIp": 0,
          "totalGB": 0,
          "expiryTime": 0,
          "enable": true,
          "tgId": 0,
          "subId": $subid,
          "reset": 0
        }
      ],
      "decryption": "none",
      "fallbacks": []
    },
    "streamSettings": {
      "network": "xhttp",
      "xhttpSettings": {
        "path": $path,
        "host": $domain,
        "mode": "packet-up",
        "xPaddingBytes": "100-1000",
        "scMaxEachPostBytes": "1000000",
        "scMaxBufferedPosts": 30
      },
      "security": "reality",
      "realitySettings": {
        "show": false,
        "xver": 0,
        "target": $target,
        "serverNames": [
          $sni
        ],
        "privateKey": $privateKey,
        "minClientVer": "",
        "maxClientVer": "",
        "maxTimediff": 0,
        "shortIds": $shortIds,
        "mldsa65Seed": "",
        "settings": {
          "publicKey": $publicKey,
          "fingerprint": $fp,
          "serverName": "",
          "spiderX": "/",
          "mldsa65Verify": ""
        }
      }
    },
    "tag": $tag,
    "sniffing": {
      "enabled": true,
      "destOverride": [
        "http",
        "tls",
        "quic",
        "fakedns"
      ]
    }
  }' > "$inbound_json"

  log "Создаю inbound..."
  add_resp="$(curl -ksS -b "$COOKIE_FILE" \
    -H "Content-Type: application/json" \
    -d @"$inbound_json" \
    "$base_url/panel/api/inbounds/add" || true)"

  if ! echo "$add_resp" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "$add_resp" || true
    die "Не удалось создать inbound"
  fi

  curl -ksS -b "$COOKIE_FILE" -X POST "$base_url/panel/api/server/restartXrayService" >/dev/null || true

  cat > "/root/${ROLE}_client_info.txt" <<EOF
panel=https://${domain}:${PANEL_PORT}/${PANEL_PATH}
panel_user=${PANEL_USER}
inbound_host=${domain}
inbound_port=${INBOUND_PORT}
inbound_path=${INBOUND_PATH}
client_email=${CLIENT_EMAIL}
client_uuid=${client_uuid}
client_subid=${client_subid}
reality_public_key=${REALITY_PUBLIC_KEY}
reality_sni=${REALITY_SNI}
reality_short_id=cbeb9905262506fb
EOF

  log "Данные клиента сохранены: /root/${ROLE}_client_info.txt"
}

save_xray_template() {
  local config_file="$1"
  python3 - "$DB_PATH" "$config_file" <<'PY'
import sqlite3
import sys
from pathlib import Path

db_path = sys.argv[1]
config_path = sys.argv[2]
config = Path(config_path).read_text()

conn = sqlite3.connect(db_path)
conn.execute(
    """
    INSERT INTO settings(key, value)
    VALUES(?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
    """,
    ("xrayTemplateConfig", config),
)
conn.commit()
conn.close()
PY
}

install_wgcf_cli() {
  if command -v wgcf-cli >/dev/null 2>&1; then
    return 0
  fi

  local arch asset tmp bin
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64) asset="wgcf-cli-linux-64.tar.zstd" ;;
    aarch64|arm64) asset="wgcf-cli-linux-arm64-v8a.tar.zstd" ;;
    armv7l|armv7) asset="wgcf-cli-linux-arm32-v7a.tar.zstd" ;;
    i386|i686) asset="wgcf-cli-linux-32.tar.zstd" ;;
    *) die "Неизвестная архитектура для wgcf-cli: $arch" ;;
  esac

  tmp="$(mktemp -d)"
  curl -fL --retry 3 \
    -o "$tmp/wgcf-cli.tar.zstd" \
    "https://github.com/ArchiveNetwork/wgcf-cli/releases/download/v0.3.6/${asset}"

  tar --use-compress-program=unzstd -xf "$tmp/wgcf-cli.tar.zstd" -C "$tmp"

  bin="$(find "$tmp" -type f -name 'wgcf-cli*' ! -name '*.dgst' | head -n1)"
  [[ -n "$bin" ]] || die "Не смог найти бинарник wgcf-cli после распаковки"

  install -m 755 "$bin" /usr/local/bin/wgcf-cli
}

configure_eu_warp_routing() {
  local warp_dir="/etc/x-ui/warp"
  local rules_file="/tmp/3xui-eu-rules.json"
  local base_file="/tmp/3xui-eu-base.json"
  local new_config="/tmp/3xui-eu-template.json"

  log "Генерация Cloudflare WARP outbound..."
  install_wgcf_cli

  mkdir -p "$warp_dir"
  cd "$warp_dir"

  if [[ ! -s wgcf.json ]]; then
    wgcf-cli -c wgcf.json register || die "Не удалось зарегистрировать WARP аккаунт"
  fi

  rm -f wgcf.xray.json
  wgcf-cli -c wgcf.json generate --xray || die "Не удалось сгенерировать WARP Xray config"
  [[ -s wgcf.xray.json ]] || die "wgcf.xray.json не создан"

  jq '.tag = "warp"' wgcf.xray.json > warp-outbound.json

  cat > "$base_file" <<'JSON'
{
  "api": {"services": ["HandlerService", "LoggerService", "StatsService"], "tag": "api"},
  "inbounds": [{"listen": "127.0.0.1", "port": 62789, "protocol": "tunnel", "settings": {"rewriteAddress": "127.0.0.1"}, "tag": "api"}],
  "log": {"access": "none", "dnsLog": false, "error": "", "loglevel": "warning", "maskAddress": ""},
  "metrics": {"listen": "127.0.0.1:11111", "tag": "metrics_out"},
  "outbounds": [
    {"protocol": "freedom", "settings": {"domainStrategy": "AsIs", "finalRules": [{"action": "allow"}]}, "tag": "direct"},
    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
  ],
  "policy": {"levels": {"0": {"statsUserDownlink": true, "statsUserUplink": true}}, "system": {"statsInboundDownlink": true, "statsInboundUplink": true, "statsOutboundDownlink": false, "statsOutboundUplink": false}},
  "routing": {"domainStrategy": "AsIs", "rules": []},
  "stats": {}
}
JSON

  cat > "$rules_file" <<'JSON'
[
  {"type":"field","inboundTag":["api"],"outboundTag":"api"},
  {"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},
  {"type":"field","ip":["geoip:private"],"outboundTag":"blocked"},
  {"type":"field","ip":["geoip:ru"],"outboundTag":"direct"},
  {"type":"field","domain":["geosite:category-ru","domain:ru","domain:su","domain:рф","domain:xn--p1ai"],"outboundTag":"direct"},
  {"type":"field","ip":["8.8.8.8/32","8.8.4.4/32","1.1.1.1/32","1.0.0.1/32","2001:4860:4860::8888/128","2001:4860:4860::8844/128","2606:4700:4700::1111/128","2606:4700:4700::1001/128"],"outboundTag":"direct"},
  {"type":"field","domain":["domain:dns.google","domain:cloudflare-dns.com","domain:one.one.one.one"],"outboundTag":"direct"},
  {"type":"field","domain":["domain:chatgpt.com","domain:chat.openai.com","domain:desktop.chat.openai.com","domain:ios.chat.openai.com","domain:android.chat.openai.com","domain:mobile.chat.openai.com","domain:ab.chatgpt.com","domain:openai.com","domain:api.openai.com","domain:cdn.openai.com","domain:auth.openai.com","domain:auth0.openai.com","domain:setup.auth.openai.com","domain:oaistatic.com","domain:auth-cdn.oaistatic.com","domain:persistent.oaistatic.com","domain:oaiusercontent.com","domain:files.oaiusercontent.com","domain:uploads.oaiusercontent.com","domain:ws.chatgpt.com","domain:webrtc.chatgpt.com","domain:realtime.chatgpt.com","domain:videos.openai.com"],"port":"443","network":"udp","outboundTag":"blocked"},
  {"type":"field","ip":["64.233.160.0/19","66.102.0.0/20","66.249.80.0/20","72.14.192.0/18","74.125.0.0/16","108.177.0.0/17","142.250.0.0/15","142.251.0.0/16","172.217.0.0/16","172.253.0.0/16","173.194.0.0/16","209.85.128.0/17","216.58.192.0/19","216.239.32.0/19"],"outboundTag":"warp"},
  {"type":"field","domain":["domain:chatgpt.com","domain:chat.openai.com","domain:desktop.chat.openai.com","domain:ios.chat.openai.com","domain:android.chat.openai.com","domain:mobile.chat.openai.com","domain:ab.chatgpt.com","domain:openai.com","domain:api.openai.com","domain:cdn.openai.com","domain:auth.openai.com","domain:auth0.openai.com","domain:setup.auth.openai.com","domain:oaistatic.com","domain:auth-cdn.oaistatic.com","domain:persistent.oaistatic.com","domain:oaiusercontent.com","domain:files.oaiusercontent.com","domain:uploads.oaiusercontent.com","domain:ws.chatgpt.com","domain:webrtc.chatgpt.com","domain:realtime.chatgpt.com","domain:videos.openai.com","domain:challenges.cloudflare.com","domain:statsig.com","domain:statsigapi.net","domain:api.statsig.com","domain:events.statsigapi.net","domain:featuregates.org","domain:featureassets.org","domain:intercom.io","domain:intercomcdn.com","domain:js.intercomcdn.com","domain:ct.sendgrid.net","domain:cdn.openaimerge.com","domain:cdn.workos.com","domain:forwarder.workos.com","domain:setup.workos.com","domain:gemini.google.com","domain:bard.google.com","domain:robinfrontend-pa.googleapis.com","domain:generativelanguage.googleapis.com","domain:aistudio.google.com","domain:ai.google.dev","domain:accounts.google.com","domain:oauth2.googleapis.com","domain:google.com","domain:www.google.com","domain:googleapis.com","domain:www.googleapis.com","domain:gstatic.com","domain:www.gstatic.com","domain:ssl.gstatic.com","domain:connectivitycheck.gstatic.com","domain:googleusercontent.com","domain:lh3.googleusercontent.com","domain:yt3.googleusercontent.com","domain:alkalicore-pa.clients6.google.com","domain:clients6.google.com","domain:signaler-pa.clients6.google.com","domain:waa-pa.clients6.google.com","domain:ogads-pa.clients6.google.com","domain:geller-pa.googleapis.com","domain:searchlabspartnerservice-pa.googleapis.com","domain:federatedcompute-pa.googleapis.com","domain:prod-lt-playstoregatewayadapter-pa.googleapis.com","domain:suggestqueries.google.com","domain:nearbysharing-pa.googleapis.com","domain:mobilemaps-pa-gz.googleapis.com","domain:geomobileservices-pa.googleapis.com","domain:firebaseinstallations.googleapis.com","domain:firebaselogging.googleapis.com","domain:play.googleapis.com","domain:play-fe.googleapis.com","domain:play.google.com","domain:android.apis.google.com","domain:mtalk.google.com","domain:cloudconfig.googleapis.com","domain:youtubei.googleapis.com","domain:app-measurement.com","domain:region1.app-measurement.com","domain:encrypted-tbn0.gstatic.com","domain:encrypted-tbn1.gstatic.com","domain:encrypted-tbn2.gstatic.com","domain:encrypted-tbn3.gstatic.com","rutracker.org"],"outboundTag":"warp"}
]
JSON

  jq --slurpfile rules "$rules_file" --slurpfile warp "$warp_dir/warp-outbound.json" '
    .outbounds = ((.outbounds // [] | map(select(.tag != "warp"))) + [$warp[0]])
    | .routing = ((.routing // {}) | .domainStrategy = "AsIs" | .rules = $rules[0])
  ' "$base_file" > "$new_config"

  save_xray_template "$new_config"
  systemctl restart x-ui
}

install_ru_manager() {
  log "Установка меню RU -> EU: /usr/local/bin/ru-eu-menu"

  cat > /usr/local/bin/ru-eu-manager <<'PYMANAGER'
#!/usr/bin/env python3
import json, os, re, sqlite3, subprocess, sys
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote

STATE_PATH = Path("/etc/x-ui/ru-eu-state.json")
DB_PATH = Path("/etc/x-ui/x-ui.db")

CHATGPT_DOMAINS = ["domain:chatgpt.com","domain:chat.openai.com","domain:desktop.chat.openai.com","domain:ios.chat.openai.com","domain:android.chat.openai.com","domain:mobile.chat.openai.com","domain:ab.chatgpt.com","domain:openai.com","domain:api.openai.com","domain:cdn.openai.com","domain:auth.openai.com","domain:auth0.openai.com","domain:setup.auth.openai.com","domain:oaistatic.com","domain:auth-cdn.oaistatic.com","domain:persistent.oaistatic.com","domain:oaiusercontent.com","domain:files.oaiusercontent.com","domain:uploads.oaiusercontent.com","domain:ws.chatgpt.com","domain:webrtc.chatgpt.com","domain:realtime.chatgpt.com","domain:videos.openai.com"]
AI_DOMAINS = CHATGPT_DOMAINS + ["domain:challenges.cloudflare.com","domain:statsig.com","domain:statsigapi.net","domain:api.statsig.com","domain:events.statsigapi.net","domain:featuregates.org","domain:featureassets.org","domain:intercom.io","domain:intercomcdn.com","domain:js.intercomcdn.com","domain:ct.sendgrid.net","domain:cdn.openaimerge.com","domain:cdn.workos.com","domain:forwarder.workos.com","domain:setup.workos.com","domain:gemini.google.com","domain:bard.google.com","domain:robinfrontend-pa.googleapis.com","domain:generativelanguage.googleapis.com","domain:aistudio.google.com","domain:ai.google.dev","domain:accounts.google.com","domain:oauth2.googleapis.com","domain:google.com","domain:www.google.com","domain:googleapis.com","domain:www.googleapis.com","domain:gstatic.com","domain:www.gstatic.com","domain:ssl.gstatic.com","domain:connectivitycheck.gstatic.com","domain:googleusercontent.com","domain:lh3.googleusercontent.com","domain:yt3.googleusercontent.com","domain:alkalicore-pa.clients6.google.com","domain:clients6.google.com","domain:signaler-pa.clients6.google.com","domain:waa-pa.clients6.google.com","domain:ogads-pa.clients6.google.com","domain:geller-pa.googleapis.com","domain:searchlabspartnerservice-pa.googleapis.com","domain:federatedcompute-pa.googleapis.com","domain:prod-lt-playstoregatewayadapter-pa.googleapis.com","domain:suggestqueries.google.com","domain:nearbysharing-pa.googleapis.com","domain:mobilemaps-pa-gz.googleapis.com","domain:geomobileservices-pa.googleapis.com","domain:firebaseinstallations.googleapis.com","domain:firebaselogging.googleapis.com","domain:play.googleapis.com","domain:play-fe.googleapis.com","domain:play.google.com","domain:android.apis.google.com","domain:mtalk.google.com","domain:cloudconfig.googleapis.com","domain:youtubei.googleapis.com","domain:app-measurement.com","domain:region1.app-measurement.com","domain:encrypted-tbn0.gstatic.com","domain:encrypted-tbn1.gstatic.com","domain:encrypted-tbn2.gstatic.com","domain:encrypted-tbn3.gstatic.com","rutracker.org"]
GOOGLE_IPS = ["64.233.160.0/19","66.102.0.0/20","66.249.80.0/20","72.14.192.0/18","74.125.0.0/16","108.177.0.0/17","142.250.0.0/15","142.251.0.0/16","172.217.0.0/16","172.253.0.0/16","173.194.0.0/16","209.85.128.0/17","216.58.192.0/19","216.239.32.0/19"]
RU_DOMAINS_DIRECT = ["geosite:category-ru","domain:ru","domain:su","domain:рф","domain:xn--p1ai"]

DEFAULT_CONFIG = {
  "api":{"services":["HandlerService","LoggerService","StatsService"],"tag":"api"},
  "inbounds":[{"listen":"127.0.0.1","port":62789,"protocol":"tunnel","settings":{"rewriteAddress":"127.0.0.1"},"tag":"api"}],
  "log":{"access":"none","dnsLog":False,"error":"","loglevel":"warning","maskAddress":""},
  "metrics":{"listen":"127.0.0.1:11111","tag":"metrics_out"},
  "outbounds":[{"protocol":"freedom","settings":{"domainStrategy":"AsIs","finalRules":[{"action":"allow"}]},"tag":"direct"},{"protocol":"blackhole","settings":{},"tag":"blocked"}],
  "policy":{"levels":{"0":{"statsUserDownlink":True,"statsUserUplink":True}},"system":{"statsInboundDownlink":True,"statsInboundUplink":True,"statsOutboundDownlink":False,"statsOutboundUplink":False}},
  "routing":{"domainStrategy":"AsIs","rules":[]},
  "stats":{}
}

def die(msg): print(f"[ERR] {msg}", file=sys.stderr); sys.exit(1)
def log(msg): print(f"[+] {msg}")
def pause(): input("\nНажми Enter для продолжения...")
def clear(): os.system("clear")
def run(cmd): subprocess.run(cmd, check=False)

def load_state():
    if not STATE_PATH.exists(): return {"mode":"active","active":"","nodes":[]}
    try: data=json.loads(STATE_PATH.read_text())
    except Exception: data={"mode":"active","active":"","nodes":[]}
    data.setdefault("mode","active"); data.setdefault("active",""); data.setdefault("nodes",[])
    return data

def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    os.chmod(STATE_PATH, 0o600)

def sanitize_tag(name):
    name=re.sub(r"[^a-z0-9_-]+","-",name.strip().lower()).strip("-_") or "main"
    return name if name.startswith("eu-") else "eu-"+name

def q_first(q,*names,default=""):
    for n in names:
        if n in q and q[n]: return q[n][0]
    return default

def parse_vless_link(link, tag):
    if not link.startswith("vless://"): die("Нужна VLESS ссылка вида vless://uuid@host:443?...")
    u=urlparse(link.strip()); q=parse_qs(u.query)
    uuid=unquote(u.username or ""); address=u.hostname or ""; port=u.port or int(q_first(q,"port",default="443"))
    network=q_first(q,"type","network",default="xhttp"); security=q_first(q,"security",default="reality")
    if not uuid or not address: die("В ссылке не найден UUID или адрес")
    if network!="xhttp": die(f"Нужен xhttp, а в ссылке {network}")
    if security!="reality": die(f"Нужен reality, а в ссылке {security}")
    pbk=q_first(q,"pbk","publicKey",default="")
    if not pbk: die("В ссылке не найден publicKey/pbk Reality")
    outbound={"tag":tag,"protocol":"vless","settings":{"vnext":[{"address":address,"port":int(port),"users":[{"id":uuid,"encryption":"none","flow":""}]}]},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":unquote(q_first(q,"path",default="/vless-path")),"host":q_first(q,"host",default=address),"mode":q_first(q,"mode",default="packet-up")},"realitySettings":{"serverName":q_first(q,"sni","serverName",default="www.sony.com"),"fingerprint":q_first(q,"fp","fingerprint",default="firefox"),"publicKey":pbk,"shortId":q_first(q,"sid","shortId",default=""),"spiderX":unquote(q_first(q,"spx","spiderX",default="/"))}},"mux":{"enabled":False,"concurrency":-1}}
    return {"tag":tag,"remark":unquote(u.fragment or tag),"address":address,"port":int(port),"link":link,"outbound":outbound}

def build_manual_node(tag):
    print("\nРучной ввод параметров EU inbound.\n")
    address=input("EU address/domain: ").strip()
    port=int(input("EU port [443]: ").strip() or "443")
    uuid=input("EU client UUID: ").strip()
    path=input("xHTTP path [/vless-path]: ").strip() or "/vless-path"
    host=input(f"xHTTP host [{address}]: ").strip() or address
    mode=input("xHTTP mode [packet-up]: ").strip() or "packet-up"
    sni=input("Reality SNI/serverName [www.sony.com]: ").strip() or "www.sony.com"
    fp=input("Reality fingerprint [firefox]: ").strip() or "firefox"
    pbk=input("Reality publicKey/pbk: ").strip()
    sid=input("Reality shortId/sid: ").strip()
    spx=input("Reality spiderX [/]: ").strip() or "/"
    if not address or not uuid or not pbk: die("address, uuid и publicKey обязательны")
    outbound={"tag":tag,"protocol":"vless","settings":{"vnext":[{"address":address,"port":port,"users":[{"id":uuid,"encryption":"none","flow":""}]}]},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":path,"host":host,"mode":mode},"realitySettings":{"serverName":sni,"fingerprint":fp,"publicKey":pbk,"shortId":sid,"spiderX":spx}},"mux":{"enabled":False,"concurrency":-1}}
    return {"tag":tag,"remark":tag,"address":address,"port":port,"link":"","outbound":outbound}

def load_template_config():
    if not DB_PATH.exists(): die(f"Не найдена база 3x-ui: {DB_PATH}")
    conn=sqlite3.connect(DB_PATH); row=conn.execute("SELECT value FROM settings WHERE key=?",("xrayTemplateConfig",)).fetchone(); conn.close()
    if not row or not row[0]: return json.loads(json.dumps(DEFAULT_CONFIG))
    try: return json.loads(row[0])
    except Exception: return json.loads(json.dumps(DEFAULT_CONFIG))

def save_template_config(config):
    value=json.dumps(config, ensure_ascii=False, indent=2)
    conn=sqlite3.connect(DB_PATH)
    conn.execute("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",("xrayTemplateConfig",value))
    conn.commit(); conn.close()

def ensure_base_outbounds(config):
    outbounds=config.setdefault("outbounds",[])
    if not any(o.get("tag")=="direct" for o in outbounds):
        outbounds.append({"protocol":"freedom","settings":{"domainStrategy":"AsIs","finalRules":[{"action":"allow"}]},"tag":"direct"})
    if not any(o.get("tag")=="blocked" for o in outbounds):
        outbounds.append({"protocol":"blackhole","settings":{},"tag":"blocked"})

def route_target(state):
    nodes=state.get("nodes",[])
    if not nodes: return {"outboundTag":"direct"}
    if state.get("mode")=="balancer": return {"balancerTag":"eu-auto"}
    active=state.get("active") or nodes[0]["tag"]
    if active not in [n["tag"] for n in nodes]: active=nodes[0]["tag"]; state["active"]=active
    return {"outboundTag":active}

def build_rules(target):
    def wt(rule): rule.update(target); return rule
    return [
      {"type":"field","inboundTag":["api"],"outboundTag":"api"},
      {"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},
      {"type":"field","ip":["geoip:private"],"outboundTag":"blocked"},
      {"type":"field","ip":["8.8.8.8/32","8.8.4.4/32","1.1.1.1/32","1.0.0.1/32","2001:4860:4860::8888/128","2001:4860:4860::8844/128","2606:4700:4700::1111/128","2606:4700:4700::1001/128"],"outboundTag":"direct"},
      {"type":"field","domain":["domain:dns.google","domain:cloudflare-dns.com","domain:one.one.one.one"],"outboundTag":"direct"},
      {"type":"field","ip":["geoip:ru"],"outboundTag":"direct"},
      {"type":"field","domain":RU_DOMAINS_DIRECT,"outboundTag":"direct"},
      {"type":"field","domain":CHATGPT_DOMAINS,"port":"443","network":"udp","outboundTag":"blocked"},
      wt({"type":"field","ip":GOOGLE_IPS}),
      wt({"type":"field","domain":AI_DOMAINS})
    ]

def rebuild(restart=True):
    state=load_state(); nodes=state.get("nodes",[])
    if nodes and not state.get("active"): state["active"]=nodes[0]["tag"]
    if state.get("active") not in [n["tag"] for n in nodes] and nodes: state["active"]=nodes[0]["tag"]
    config=load_template_config(); ensure_base_outbounds(config)
    config["outbounds"]=[o for o in config.get("outbounds",[]) if not str(o.get("tag","")).startswith("eu-")]
    for node in nodes: config["outbounds"].append(node["outbound"])
    config.setdefault("routing",{}); config["routing"]["domainStrategy"]="AsIs"; config["routing"]["rules"]=build_rules(route_target(state))
    if state.get("mode")=="balancer" and nodes:
        fallback=state.get("active") or nodes[0]["tag"]
        config["routing"]["balancers"]=[{"tag":"eu-auto","selector":["eu-"],"fallbackTag":fallback,"strategy":{"type":"roundRobin"}}]
        config["observatory"]={"subjectSelector":["eu-"],"probeURL":"https://www.gstatic.com/generate_204","probeInterval":"30s"}
    else:
        if "balancers" in config.get("routing",{}):
            config["routing"]["balancers"]=[b for b in config["routing"].get("balancers",[]) if b.get("tag")!="eu-auto"]
            if not config["routing"]["balancers"]: config["routing"].pop("balancers",None)
        config.pop("observatory",None)
    save_template_config(config); save_state(state); log("xrayTemplateConfig обновлён")
    if restart: run(["systemctl","restart","x-ui"]); log("x-ui перезапущен")

def cmd_add():
    state=load_state()
    tag=sanitize_tag(input("Название EU ноды [main]: ").strip() or "main")
    print("\nВставь share link из EU inbound. Enter = ручной ввод.\n")
    link=input("VLESS link: ").strip()
    node=parse_vless_link(link,tag) if link else build_manual_node(tag)
    state["nodes"]=[n for n in state.get("nodes",[]) if n.get("tag")!=tag]
    state["nodes"].append(node)
    if not state.get("active"): state["active"]=tag
    save_state(state); log(f"Добавлена EU нода: {tag} -> {node['address']}:{node['port']}"); rebuild(True)

def cmd_list():
    state=load_state(); nodes=state.get("nodes",[])
    print(f"Режим:       {state.get('mode','active')}")
    print(f"Активная EU: {state.get('active') or '-'}\n")
    if not nodes: print("EU нод пока нет"); return
    for n in nodes:
        mark="*" if n.get("tag")==state.get("active") else " "
        print(f"{mark} {n.get('tag')}  {n.get('address')}:{n.get('port')}  {n.get('remark','')}")

def cmd_set(tag):
    tag=sanitize_tag(tag); state=load_state()
    if tag not in [n.get("tag") for n in state.get("nodes",[])]: die(f"EU нода не найдена: {tag}")
    state["active"]=tag; state["mode"]="active"; save_state(state); log(f"Активная EU нода: {tag}"); rebuild(True)

def cmd_del(tag):
    tag=sanitize_tag(tag); state=load_state(); before=len(state.get("nodes",[]))
    state["nodes"]=[n for n in state.get("nodes",[]) if n.get("tag")!=tag]
    if len(state["nodes"])==before: die(f"EU нода не найдена: {tag}")
    if state.get("active")==tag: state["active"]=state["nodes"][0]["tag"] if state["nodes"] else ""
    save_state(state); log(f"Удалена EU нода: {tag}"); rebuild(True)

def cmd_balancer(value):
    if value not in {"on","off"}: die("Используй: ru-eu-manager balancer on|off")
    state=load_state()
    state["mode"]="balancer" if value=="on" else "active"
    save_state(state); log(f"Режим: {state['mode']}"); rebuild(True)

def select_node():
    state=load_state(); nodes=state.get("nodes",[])
    if not nodes: print("EU нод пока нет."); return ""
    for i,n in enumerate(nodes,1):
        mark="*" if n.get("tag")==state.get("active") else " "
        print(f"{i}) {mark} {n.get('tag')}  {n.get('address')}:{n.get('port')}")
    choice=input("\nВыбери номер EU ноды: ").strip()
    if not choice.isdigit(): return ""
    idx=int(choice)-1
    return nodes[idx]["tag"] if 0 <= idx < len(nodes) else ""

def menu():
    while True:
        clear(); state=load_state()
        print("===================================")
        print("      RU -> EU cascade manager      ")
        print("===================================")
        print(f"Режим:       {state.get('mode','active')}")
        print(f"Активная EU: {state.get('active') or '-'}")
        print(f"Всего EU:    {len(state.get('nodes',[]))}\n")
        print("1) Добавить EU сервер")
        print("2) Показать EU серверы")
        print("3) Сделать EU сервер основным")
        print("4) Удалить EU сервер")
        print("5) Включить автоматический резерв / balancer")
        print("6) Выключить автоматический резерв")
        print("7) Пересобрать маршрутизацию и перезапустить x-ui")
        print("8) Показать routing JSON")
        print("9) Статус x-ui")
        print("10) Логи x-ui")
        print("0) Выход\n")
        c=input("Выбери пункт: ").strip()
        try:
            if c=="1": cmd_add(); pause()
            elif c=="2": cmd_list(); pause()
            elif c=="3":
                t=select_node()
                if t: cmd_set(t)
                pause()
            elif c=="4":
                t=select_node()
                if t and input(f"Удалить {t}? yes/no: ").strip().lower()=="yes": cmd_del(t)
                pause()
            elif c=="5": cmd_balancer("on"); pause()
            elif c=="6": cmd_balancer("off"); pause()
            elif c=="7": rebuild(True); pause()
            elif c=="8": print(json.dumps(load_template_config().get("routing",{}), ensure_ascii=False, indent=2)); pause()
            elif c=="9": run(["systemctl","status","x-ui","--no-pager"]); pause()
            elif c=="10": run(["journalctl","-u","x-ui","-n","100","--no-pager"]); pause()
            elif c=="0": break
            else: print("Нет такого пункта."); pause()
        except Exception as e:
            print(f"[ERR] {e}"); pause()

def usage():
    print("""Использование:
  ru-eu-menu
  ru-eu-manager add|list|rebuild|routing|status|logs
  ru-eu-manager set main
  ru-eu-manager del main
  ru-eu-manager balancer on|off
""")

def main():
    if len(sys.argv)<2: menu(); return
    cmd=sys.argv[1]
    if cmd=="menu": menu()
    elif cmd=="add": cmd_add()
    elif cmd=="list": cmd_list()
    elif cmd=="set" and len(sys.argv)>=3: cmd_set(sys.argv[2])
    elif cmd=="del" and len(sys.argv)>=3: cmd_del(sys.argv[2])
    elif cmd=="balancer" and len(sys.argv)>=3: cmd_balancer(sys.argv[2])
    elif cmd=="rebuild": rebuild(True)
    elif cmd=="routing": print(json.dumps(load_template_config().get("routing",{}), ensure_ascii=False, indent=2))
    elif cmd=="status": run(["systemctl","status","x-ui","--no-pager"])
    elif cmd=="logs": run(["journalctl","-u","x-ui","-n","100","--no-pager"])
    else: usage(); sys.exit(1)

if __name__=="__main__": main()
PYMANAGER

  chmod +x /usr/local/bin/ru-eu-manager
  ln -sf /usr/local/bin/ru-eu-manager /usr/local/bin/ru-eu-menu
}

install_eu() {
  ask_domain "EU"
  check_dns_and_ports "$DOMAIN"
  open_firewall
  install_3xui "$DOMAIN"
  configure_eu_warp_routing
  create_xhttp_reality_inbound "$DOMAIN" "EU-VLESS-XHTTP-Reality-WARP" "in-${INBOUND_PORT}-xhttp-reality-eu"
  systemctl restart x-ui

  cat <<EOF

Готово. EU сервер установлен.

Панель:
  https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}

Логин:
  ${PANEL_USER}

Данные клиента:
  /root/eu_client_info.txt

Для RU сервера скопируй VLESS share link этого EU inbound из панели 3x-ui.

EOF
}

install_ru() {
  ask_domain "RU"
  check_dns_and_ports "$DOMAIN"
  open_firewall
  install_3xui "$DOMAIN"
  install_ru_manager
  create_xhttp_reality_inbound "$DOMAIN" "RU-VLESS-XHTTP-Reality-to-EU" "in-${INBOUND_PORT}-xhttp-reality-ru"

  echo
  echo "Теперь добавь основной EU сервер для каскада RU -> EU."
  echo "Вставь VLESS share link из EU inbound. Если его нет — нажми Enter и введи параметры вручную."
  echo
  /usr/local/bin/ru-eu-manager add || warn "EU нода не добавлена. Потом добавишь через: ru-eu-menu"

  systemctl restart x-ui

  cat <<EOF

Готово. RU сервер установлен.

Панель:
  https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}

Логин:
  ${PANEL_USER}

Меню каскада:
  ru-eu-menu

Данные клиента RU:
  /root/ru_client_info.txt

Маршрутизация RU:
  Российские IP/домены -> direct
  ChatGPT/Gemini/AI/Google диапазоны -> активная EU нода или balancer
  BitTorrent/private IP -> blocked

EOF
}

main() {
  need_root
  normalize_panel_path
  detect_role "${1:-}"
  ask_panel_password
  install_deps

  if [[ "$ROLE" == "eu" ]]; then
    install_eu
  else
    install_ru
  fi

  if systemctl is-active --quiet x-ui; then
    log "x-ui работает"
  else
    journalctl -u x-ui -n 120 --no-pager || true
    die "x-ui не запустился"
  fi
}

main "$@"
