#!/bin/ash
set -eu

APP="riftpanel"
APPDIR="/usr/lib/${APP}"
WWW="/www/${APP}"
CGI="/www/cgi-bin/riftpanel-api"
UCI_CFG="/etc/config/${APP}"
VERSION="0.1.0"

log(){ echo "[$APP] $*"; }
die(){ echo "[$APP] ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "Run as root"; }
is_openwrt(){ [ -f /etc/openwrt_release ] || [ -f /etc/os-release ] || die "Not OpenWrt"; }

opkg_install() {
  pkg="$1"
  if opkg status "$pkg" >/dev/null 2>&1; then return 0; fi
  log "Installing: $pkg"
  opkg update >/dev/null 2>&1 || true
  opkg install "$pkg" >/dev/null
}

write_uci() {
  log "Writing $UCI_CFG"
  cat >"$UCI_CFG" <<EOF
config riftpanel 'main'
  option subscription_url ''
  option selected_name ''          # human name of node (decoded #fragment)
  option last_nodes_hash ''        # internal
  option update_feed_url ''        # URL to JSON feed for panel updates
  option channel 'stable'
EOF
}

write_lib() {
  log "Writing lib scripts to $APPDIR"
  mkdir -p "$APPDIR"

  # VERSION
  echo "$VERSION" > "${APPDIR}/VERSION"

  # common.sh
  cat >"${APPDIR}/common.sh" <<'EOF'
#!/bin/ash
set -eu

APP="riftpanel"
STATE_DIR="/tmp/riftpanel"
mkdir -p "$STATE_DIR"

log(){ logger -t "$APP" "$*"; }
say(){ echo "[$APP] $*"; }

urldecode() {
  # + -> space, %XX -> byte
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

trim() {
  # trim spaces
  echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

uci_get(){ uci -q get "$1" 2>/dev/null || true; }
uci_set(){ uci -q set "$1=$2"; }
uci_commit(){ uci -q commit "$1"; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    # fallback: busybox might not have sha256sum -> try openssl
    if command -v openssl >/dev/null 2>&1; then
      openssl dgst -sha256 "$1" | awk '{print $2}'
    else
      echo ""
    fi
  fi
}
EOF
  chmod 0755 "${APPDIR}/common.sh"

  # subscription.sh
  cat >"${APPDIR}/subscription.sh" <<'EOF'
#!/bin/ash
set -eu
. /usr/lib/riftpanel/common.sh

# Downloads subscription_url and outputs decoded vless lines to stdout.
# Also stores meta in $STATE_DIR/sub.title
fetch_subscription_lines() {
  local url raw dec headers title_b64 title
  url="$(uci_get riftpanel.main.subscription_url)"
  [ -n "$url" ] || return 0

  raw="$STATE_DIR/sub.raw"
  dec="$STATE_DIR/sub.dec"
  headers="$STATE_DIR/sub.headers"
  : >"$STATE_DIR/sub.title" || true

  # headers first (profile-title may exist)
  if curl -fsS -L -m 20 -D "$headers" -o "$raw" "$url" 2>/dev/null; then
    title_b64="$(sed -n 's/^[Pp]rofile-title: base64://p' "$headers" | tr -d '\r' | head -n1 || true)"
    if [ -n "$title_b64" ]; then
      title="$(echo "$title_b64" | base64 -d 2>/dev/null || true)"
      [ -n "$title" ] && echo "$title" >"$STATE_DIR/sub.title" || true
    fi

    # try base64 decode; if fails, keep raw
    if base64 -d <"$raw" >"$dec" 2>/dev/null; then
      :
    else
      cp "$raw" "$dec"
    fi

    # output only vless://
    grep -E '^vless://' "$dec" 2>/dev/null || true
  fi
}

# Parses vless lines and prints tab-separated fields:
# idx \t name_decoded \t host \t port \t raw \t pbk \t sni \t sid \t fp \t flow \t security
parse_subscription() {
  local i line name_enc name host port q pbk sni sid fp flow sec
  i=0
  fetch_subscription_lines | while IFS= read -r line; do
    i=$((i+1))
    line="$(echo "$line" | tr -d '\r')"

    # name after '#'
    name_enc=""
    echo "$line" | grep -q '#' && name_enc="${line#*#}"
    name="$(urldecode "$name_enc")"
    [ -n "$name" ] || name="Server $i"

    host="$(echo "$line" | sed -n 's#^vless://[^@]*@\([^:]*\):\([0-9][0-9]*\).*#\1#p')"
    port="$(echo "$line" | sed -n 's#^vless://[^@]*@[^:]*:\([0-9][0-9]*\).*#\1#p')"

    q="$(echo "$line" | sed -n 's/^[^?]*?\(.*\)$/\1/p' | sed 's/#.*//')"
    pbk="$(echo "$q" | tr '&' '\n' | sed -n 's/^pbk=//p' | head -n1)"
    sni="$(echo "$q" | tr '&' '\n' | sed -n 's/^sni=//p' | head -n1)"
    sid="$(echo "$q" | tr '&' '\n' | sed -n 's/^sid=//p' | head -n1)"
    fp="$(echo "$q" | tr '&' '\n' | sed -n 's/^fp=//p' | head -n1)"
    flow="$(echo "$q" | tr '&' '\n' | sed -n 's/^flow=//p' | head -n1)"
    sec="$(echo "$q" | tr '&' '\n' | sed -n 's/^security=//p' | head -n1)"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$i" "$name" "$host" "$port" "$line" "$pbk" "$sni" "$sid" "$fp" "$flow" "$sec"
  done
}

nodes_hash() {
  # stable-ish hash to detect changes
  local tmp h
  tmp="$STATE_DIR/sub.nodes"
  fetch_subscription_lines >"$tmp" || true
  h="$(sha256_file "$tmp")"
  echo "$h"
}

subscription_title() {
  [ -f "$STATE_DIR/sub.title" ] && cat "$STATE_DIR/sub.title" || true
}
EOF
  chmod 0755 "${APPDIR}/subscription.sh"

  # podkop_sync.sh
  cat >"${APPDIR}/podkop_sync.sh" <<'EOF'
#!/bin/ash
set -eu
. /usr/lib/riftpanel/common.sh
. /usr/lib/riftpanel/subscription.sh

ensure_podkop_section() {
  # assumes section name "main" exists, but be defensive
  uci -q show podkop.main >/dev/null 2>&1 || true
}

podkop_restart() {
  /etc/init.d/podkop restart >/dev/null 2>&1 || true
}

set_selected_server_by_name() {
  # arg: decoded name
  local name="$1" line found
  [ -n "$name" ] || return 1

  found=""
  parse_subscription | while IFS="$(printf '\t')" read -r idx n host port raw pbk sni sid fp flow sec; do
    [ "$n" = "$name" ] || continue
    echo "$raw"
    break
  done >"$STATE_DIR/sel.raw" || true

  [ -s "$STATE_DIR/sel.raw" ] || return 2
  line="$(cat "$STATE_DIR/sel.raw")"

  ensure_podkop_section
  uci_set "podkop.main.proxy_string" "'$line'"
  uci_commit podkop

  uci_set "riftpanel.main.selected_name" "'$name'"
  uci_commit riftpanel

  podkop_restart
  return 0
}

sync_active_server_if_changed() {
  # If selected_name set: find matching node by name and ensure podkop.main.proxy_string equals it.
  local sel current want
  sel="$(uci_get riftpanel.main.selected_name)"
  sel="$(echo "$sel" | sed "s/^'//; s/'$//")"
  [ -n "$sel" ] || return 0

  current="$(uci_get podkop.main.proxy_string)"
  current="$(echo "$current" | sed "s/^'//; s/'$//")"

  parse_subscription | while IFS="$(printf '\t')" read -r idx n host port raw pbk sni sid fp flow sec; do
    [ "$n" = "$sel" ] || continue
    echo "$raw"
    break
  done >"$STATE_DIR/want.raw" || true

  [ -s "$STATE_DIR/want.raw" ] || return 0
  want="$(cat "$STATE_DIR/want.raw")"

  if [ "$want" != "$current" ]; then
    log "Selected server '$sel' changed in subscription -> updating podkop.main.proxy_string"
    uci_set "podkop.main.proxy_string" "'$want'"
    uci_commit podkop
    podkop_restart
  fi
}

set_user_domains() {
  # arg: newline-separated domains
  local text="$1" d
  ensure_podkop_section

  # Clear existing list
  uci -q delete podkop.main.user_domains || true

  echo "$text" | tr '\r' '\n' | tr ' ' '\n' | while IFS= read -r d; do
    d="$(trim "$d")"
    [ -n "$d" ] || continue
    # basic sanitize: allow letters digits dot dash
    echo "$d" | grep -qE '^[A-Za-z0-9.-]+$' || continue
    uci -q add_list podkop.main.user_domains="$d"
  done

  uci_commit podkop
  podkop_restart
}

set_fully_routed_ip() {
  # arg: ipv4 or empty to clear
  local ip="$1"
  ensure_podkop_section

  uci -q delete podkop.main.fully_routed_ips || true
  if [ -n "$ip" ]; then
    uci -q add_list podkop.main.fully_routed_ips="$ip"
  fi

  uci_commit podkop
  podkop_restart
}
EOF
  chmod 0755 "${APPDIR}/podkop_sync.sh"

  # updater.sh (checks update_feed_url hourly, installs without touching /etc/config/riftpanel)
  cat >"${APPDIR}/updater.sh" <<'EOF'
#!/bin/ash
set -eu
. /usr/lib/riftpanel/common.sh

have(){ command -v "$1" >/dev/null 2>&1; }

get_local_version() {
  cat /usr/lib/riftpanel/VERSION 2>/dev/null || echo "0.0.0"
}

# Feed format (example):
# {
#   "version": "0.1.1",
#   "tarball": "https://example.com/riftpanel-0.1.1.tar.gz",
#   "sha256": "...."
# }
check_and_update() {
  local feed url tmp feed_json ver tar sha local_ver
  feed="$(uci_get riftpanel.main.update_feed_url)"
  feed="$(echo "$feed" | sed "s/^'//; s/'$//")"
  [ -n "$feed" ] || return 0

  tmp="/tmp/riftpanel_update"
  mkdir -p "$tmp"
  feed_json="$tmp/feed.json"

  curl -fsS -L -m 20 "$feed" -o "$feed_json" 2>/dev/null || return 0

  if have jsonfilter; then
    ver="$(jsonfilter -i "$feed_json" -e '@.version' 2>/dev/null || true)"
    tar="$(jsonfilter -i "$feed_json" -e '@.tarball' 2>/dev/null || true)"
    sha="$(jsonfilter -i "$feed_json" -e '@.sha256' 2>/dev/null || true)"
  else
    # minimal fallback (not perfect)
    ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$feed_json" | head -n1 || true)"
    tar="$(sed -n 's/.*"tarball"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$feed_json" | head -n1 || true)"
    sha="$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$feed_json" | head -n1 || true)"
  fi

  [ -n "$ver" ] && [ -n "$tar" ] || return 0
  local_ver="$(get_local_version)"

  [ "$ver" = "$local_ver" ] && return 0

  log "Update available: $local_ver -> $ver"
  pkg="$tmp/pkg.tgz"
  curl -fsS -L -m 60 "$tar" -o "$pkg" 2>/dev/null || { log "Download failed"; return 0; }

  if [ -n "$sha" ]; then
    calc="$(sha256_file "$pkg")"
    [ -n "$calc" ] && [ "$calc" = "$sha" ] || { log "SHA256 mismatch"; return 0; }
  fi

  unpack="$tmp/unpack"
  rm -rf "$unpack"; mkdir -p "$unpack"
  tar -xzf "$pkg" -C "$unpack" 2>/dev/null || { log "Unpack failed"; return 0; }

  # Expected layout inside tar:
  #   www/riftpanel/*
  #   www/cgi-bin/riftpanel-api
  #   usr/lib/riftpanel/*
  #   etc/init.d/... (optional)
  # We do NOT touch /etc/config/riftpanel

  if [ -d "$unpack/www/riftpanel" ]; then
    mkdir -p /www/riftpanel
    cp -a "$unpack/www/riftpanel/." /www/riftpanel/
  fi
  if [ -f "$unpack/www/cgi-bin/riftpanel-api" ]; then
    mkdir -p /www/cgi-bin
    cp -a "$unpack/www/cgi-bin/riftpanel-api" /www/cgi-bin/riftpanel-api
    chmod 0755 /www/cgi-bin/riftpanel-api
  fi
  if [ -d "$unpack/usr/lib/riftpanel" ]; then
    mkdir -p /usr/lib/riftpanel
    # keep existing config and replace code
    cp -a "$unpack/usr/lib/riftpanel/." /usr/lib/riftpanel/
  fi
  if [ -d "$unpack/etc/init.d" ]; then
    cp -a "$unpack/etc/init.d/." /etc/init.d/ 2>/dev/null || true
  fi

  echo "$ver" > /usr/lib/riftpanel/VERSION
  log "Updated to $ver"
}

EOF
  chmod 0755 "${APPDIR}/updater.sh"

  # hourly.sh: subscription refresh + config sync + panel updates
  cat >"${APPDIR}/hourly.sh" <<'EOF'
#!/bin/ash
set -eu
. /usr/lib/riftpanel/common.sh
. /usr/lib/riftpanel/subscription.sh
. /usr/lib/riftpanel/podkop_sync.sh

hourly() {
  # 1) detect subscription change
  h="$(nodes_hash || true)"
  prev="$(uci_get riftpanel.main.last_nodes_hash)"
  prev="$(echo "$prev" | sed "s/^'//; s/'$//")"

  if [ -n "$h" ] && [ "$h" != "$prev" ]; then
    log "Subscription nodes changed"
    uci_set "riftpanel.main.last_nodes_hash" "'$h'"
    uci_commit riftpanel

    # 2) if selected server is set, update podkop.main.proxy_string if changed
    sync_active_server_if_changed || true
  fi

  # 3) check panel updates
  /usr/lib/riftpanel/updater.sh || true
}

hourly
EOF
  chmod 0755 "${APPDIR}/hourly.sh"
}

write_cgi() {
  log "Writing CGI API: $CGI"
  mkdir -p /www/cgi-bin
  cat >"$CGI" <<'EOF'
#!/bin/ash
set -eu

. /usr/lib/riftpanel/common.sh
. /usr/lib/riftpanel/subscription.sh
. /usr/lib/riftpanel/podkop_sync.sh

# JSON builder
. /usr/share/libubox/jshn.sh

hdr_json(){
  printf "Content-Type: application/json\r\nCache-Control: no-store\r\nPragma: no-cache\r\n\r\n"
}

read_body(){
  local len="${CONTENT_LENGTH:-0}"
  [ "$len" -gt 0 ] 2>/dev/null || { echo ""; return 0; }
  dd bs=1 count="$len" 2>/dev/null || true
}

qparam() {
  # naive query parser for small GET params
  # usage: qparam key
  echo "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1
}

clients_list() {
  # outputs: ip\tmac\tname\tsrc
  local lan_dev
  lan_dev="$(uci -q get network.lan.device 2>/dev/null || uci -q get network.lan.ifname 2>/dev/null || echo br-lan)"

  {
    # dhcp leases: ts mac ip name ...
    awk '{print $3 "\t" $2 "\t" $4 "\tDHCP"}' /tmp/dhcp.leases 2>/dev/null || true
    # neigh: ip lladdr mac
    ip -4 neigh show dev "$lan_dev" 2>/dev/null | awk '/lladdr/{print $1 "\t" $3 "\tUnknown\tNEIGH"}' || true
  } | awk '!seen[$1]++'
}

api_status() {
  hdr_json
  json_init

  # panel config
  sub_url="$(uci_get riftpanel.main.subscription_url)"
  sel_name="$(uci_get riftpanel.main.selected_name)"
  upd_feed="$(uci_get riftpanel.main.update_feed_url)"
  channel="$(uci_get riftpanel.main.channel)"
  ver="$(cat /usr/lib/riftpanel/VERSION 2>/dev/null || echo 0.0.0)"

  json_add_object panel
    json_add_string version "$(echo "$ver")"
    json_add_string channel "$(echo "$channel" | sed "s/^'//; s/'$//")"
    json_add_string subscription_url "$(echo "$sub_url" | sed "s/^'//; s/'$//")"
    json_add_string selected_name "$(echo "$sel_name" | sed "s/^'//; s/'$//")"
    json_add_string update_feed_url "$(echo "$upd_feed" | sed "s/^'//; s/'$//")"
    title="$(subscription_title || true)"
    json_add_string subscription_title "$title"
  json_close_object

  # podkop config
  proxy="$(uci_get podkop.main.proxy_string)"
  domains="$(uci -q get podkop.main.user_domains 2>/dev/null || true)"
  fullip="$(uci -q get podkop.main.fully_routed_ips 2>/dev/null || true)"

  json_add_object podkop
    json_add_string proxy_string "$(echo "$proxy" | sed "s/^'//; s/'$//")"
    json_add_string fully_routed_ip "$(echo "$fullip" | head -n1)"
  json_close_object

  # subscription servers
  json_add_array servers
  parse_subscription | while IFS="$(printf '\t')" read -r idx name host port raw pbk sni sid fp flow sec; do
    json_add_object ""
      json_add_int idx "$idx"
      json_add_string name "$name"
      json_add_string host "$host"
      json_add_string port "$port"
      json_add_string pbk "$pbk"
      json_add_string sni "$sni"
      json_add_string sid "$sid"
      json_add_string fp "$fp"
      json_add_string flow "$flow"
      json_add_string security "$sec"
      json_add_string raw "$raw"
    json_close_object
  done
  json_close_array

  # user domains list (read as "uci get" -> first only, so we expose full via uci show)
  json_add_array user_domains
    # try "uci show" to capture list items
    uci -q show podkop.main.user_domains 2>/dev/null | sed -n "s/.*=//p" | tr -d "'" | while IFS= read -r d; do
      [ -n "$d" ] || continue
      json_add_string "" "$d"
    done
  json_close_array

  # clients
  json_add_array clients
  clients_list | while IFS="$(printf '\t')" read -r ip mac name src; do
    json_add_object ""
      json_add_string ip "$ip"
      json_add_string mac "$mac"
      json_add_string name "$name"
      json_add_string src "$src"
    json_close_object
  done
  json_close_array

  json_dump
}

api_set_subscription() {
  body="$(read_body)"
  # Expect JSON: {"subscription_url":"..."}
  . /usr/share/libubox/jshn.sh
  json_init
  json_load "$body" 2>/dev/null || true
  json_get_var url subscription_url || url=""
  url="$(echo "$url" | tr -d '\r')"

  hdr_json
  json_init
  if [ -n "$url" ]; then
    uci -q set riftpanel.main.subscription_url="$url"
    uci -q commit riftpanel
    json_add_string ok "true"
  else
    json_add_string ok "false"
    json_add_string error "empty subscription_url"
  fi
  json_dump
}

api_select_server() {
  body="$(read_body)"
  json_init
  json_load "$body" 2>/dev/null || true
  json_get_var name selected_name || name=""
  name="$(echo "$name" | tr -d '\r')"

  hdr_json
  json_init
  if [ -n "$name" ]; then
    if set_selected_server_by_name "$name" 2>/dev/null; then
      json_add_string ok "true"
    else
      json_add_string ok "false"
      json_add_string error "server not found in subscription"
    fi
  else
    json_add_string ok "false"
    json_add_string error "empty selected_name"
  fi
  json_dump
}

api_set_domains() {
  body="$(read_body)"
  json_init
  json_load "$body" 2>/dev/null || true
  json_get_var domains domains || domains=""

  hdr_json
  json_init
  set_user_domains "$domains" || true
  json_add_string ok "true"
  json_dump
}

api_set_fully_routed() {
  body="$(read_body)"
  json_init
  json_load "$body" 2>/dev/null || true
  json_get_var ip ip || ip=""
  ip="$(echo "$ip" | tr -d '\r')"

  hdr_json
  json_init
  set_fully_routed_ip "$ip" || true
  json_add_string ok "true"
  json_dump
}

api_set_update_feed() {
  body="$(read_body)"
  json_init
  json_load "$body" 2>/dev/null || true
  json_get_var url update_feed_url || url=""
  url="$(echo "$url" | tr -d '\r')"

  hdr_json
  json_init
  uci -q set riftpanel.main.update_feed_url="$url"
  uci -q commit riftpanel
  json_add_string ok "true"
  json_dump
}

api_refresh() {
  # Force refresh hash + sync selected server if changed
  hdr_json
  json_init
  h="$(/usr/lib/riftpanel/subscription.sh nodes_hash 2>/dev/null || true)"
  if [ -n "$h" ]; then
    uci -q set riftpanel.main.last_nodes_hash="$h"
    uci -q commit riftpanel
  fi
  /usr/lib/riftpanel/podkop_sync.sh sync_active_server_if_changed 2>/dev/null || true
  json_add_string ok "true"
  json_dump
}

action="$(qparam action)"
case "$action" in
  status) api_status ;;
  set_subscription) api_set_subscription ;;
  select_server) api_select_server ;;
  set_domains) api_set_domains ;;
  set_fully_routed) api_set_fully_routed ;;
  set_update_feed) api_set_update_feed ;;
  refresh) api_refresh ;;
  *) hdr_json; echo '{"ok":false,"error":"unknown action"}' ;;
esac
EOF
  chmod 0755 "$CGI"
}

write_web() {
  log "Writing web UI to $WWW"
  mkdir -p "$WWW"

  cat >"${WWW}/index.html" <<'EOF'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>RiftPanel — управление podkop</title>
  <style>
    body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial; margin:16px; max-width:1100px}
    .row{display:flex; gap:12px; flex-wrap:wrap}
    .card{border:1px solid #ddd; border-radius:12px; padding:12px; margin:12px 0}
    input, textarea, select, button{font:inherit}
    input, textarea, select{padding:8px; border-radius:10px; border:1px solid #ccc; width:100%}
    textarea{min-height:110px}
    button{padding:10px 12px; border-radius:10px; border:1px solid #ccc; background:#f7f7f7; cursor:pointer}
    button.primary{background:#111; color:#fff; border-color:#111}
    small{color:#666}
    table{width:100%; border-collapse:collapse}
    td,th{border-bottom:1px solid #eee; padding:8px; vertical-align:top}
    th{text-align:left}
    .muted{color:#666}
    .ok{color:#0a7}
    .bad{color:#c33}
    .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace; font-size:12px; word-break:break-all}
  </style>
</head>
<body>
  <h1>RiftPanel</h1>
  <div class="muted">Панель управления <b>podkop</b> через подписку (URL) и правила маршрутизации.</div>

  <div class="card">
    <div class="row">
      <div style="flex:2; min-width:320px">
        <label>Subscription URL</label>
        <input id="subUrl" placeholder="https://..." />
        <small id="subTitle" class="muted"></small>
      </div>
      <div style="flex:1; min-width:260px">
        <label>Обновления панели (update_feed_url)</label>
        <input id="updFeed" placeholder="https://.../feed.json" />
        <small class="muted">Если пусто — автообновление выключено</small>
      </div>
    </div>
    <div class="row" style="margin-top:10px">
      <button class="primary" onclick="saveSubscription()">Сохранить подписку</button>
      <button onclick="saveUpdateFeed()">Сохранить update feed</button>
      <button onclick="forceRefresh()">Обновить ноды сейчас</button>
      <span id="topStatus" class="muted"></span>
    </div>
  </div>

  <div class="card">
    <h2>Сервера в подписке</h2>
    <div class="muted">Выбери сервер — панель обновит <span class="mono">podkop.main.proxy_string</span> и перезапустит podkop.</div>
    <div id="servers"></div>
  </div>

  <div class="card">
    <h2>Домены для маршрутизации</h2>
    <div class="muted">Введи домены (по одному в строке). Панель запишет их в <span class="mono">podkop.main.user_domains</span>.</div>
    <textarea id="domains" placeholder="example.com&#10;2ip.ru"></textarea>
    <div class="row" style="margin-top:10px">
      <button class="primary" onclick="applyDomains()">Apply domains</button>
      <span id="domainsStatus" class="muted"></span>
    </div>
  </div>

  <div class="card">
    <h2>Полный VPN для устройства</h2>
    <div class="muted">Выбери клиента из LAN — панель запишет IP в <span class="mono">podkop.main.fully_routed_ips</span>.</div>
    <div class="row">
      <div style="flex:2; min-width:320px">
        <label>Устройство (IP • MAC • Name)</label>
        <select id="clientSelect"></select>
      </div>
      <div style="flex:1; min-width:200px">
        <label>&nbsp;</label>
        <button class="primary" onclick="applyClient()">Применить</button>
        <button onclick="clearClient()">Очистить</button>
      </div>
    </div>
    <div id="clientStatus" class="muted" style="margin-top:10px"></div>
  </div>

  <div class="card">
    <h2>Текущее состояние</h2>
    <div class="row">
      <div style="flex:1; min-width:300px">
        <div><b>Версия панели:</b> <span id="ver"></span></div>
        <div><b>Выбранный сервер:</b> <span id="selName"></span></div>
        <div><b>Fully routed IP:</b> <span id="fullIp"></span></div>
      </div>
      <div style="flex:2; min-width:320px">
        <div class="muted">podkop.main.proxy_string</div>
        <div id="proxyString" class="mono"></div>
      </div>
    </div>
  </div>

<script src="app.js"></script>
</body>
</html>
EOF

  cat >"${WWW}/app.js" <<'EOF'
async function api(action, payload) {
  const url = `/cgi-bin/riftpanel-api?action=${encodeURIComponent(action)}`;
  const opts = payload ? {
    method: "POST",
    headers: {"Content-Type":"application/json"},
    body: JSON.stringify(payload)
  } : { method: "GET" };
  const r = await fetch(url, opts);
  return await r.json();
}

function esc(s){ return (s ?? "").toString().replace(/[&<>"]/g, c=>({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;" }[c])); }

let lastStatus = null;

function renderServers(servers, selectedName) {
  const wrap = document.getElementById("servers");
  if (!servers || servers.length === 0) {
    wrap.innerHTML = `<div class="bad">Нет нод (проверь Subscription URL)</div>`;
    return;
  }
  const rows = servers.map(s => {
    const active = (s.name === selectedName) ? `<span class="ok">● выбран</span>` : "";
    return `
      <tr>
        <td>
          <div><b>${esc(s.name)}</b> ${active}</div>
          <div class="muted">${esc(s.host)}:${esc(s.port)} • ${esc(s.security || "")} • ${esc(s.flow || "")}</div>
        </td>
        <td style="width:220px">
          <button class="primary" onclick="selectServer('${esc(s.name).replace(/'/g,"&#39;")}')">Выбрать</button>
        </td>
      </tr>
      <tr><td colspan="2" class="mono">${esc(s.raw)}</td></tr>
    `;
  }).join("");

  wrap.innerHTML = `<table><thead><tr><th>Сервер</th><th></th></tr></thead><tbody>${rows}</tbody></table>`;
}

function renderClients(clients, currentFullIp){
  const sel = document.getElementById("clientSelect");
  const opts = [`<option value="">— не выбран —</option>`]
    .concat((clients||[]).map(c => {
      const label = `${c.ip} • ${c.mac} • ${c.name} (${c.src})`;
      const selected = (c.ip === currentFullIp) ? "selected" : "";
      return `<option value="${esc(c.ip)}" ${selected}>${esc(label)}</option>`;
    }));
  sel.innerHTML = opts.join("");
}

async function reload() {
  const st = await api("status");
  lastStatus = st;

  document.getElementById("ver").textContent = st.panel?.version || "";
  document.getElementById("subUrl").value = st.panel?.subscription_url || "";
  document.getElementById("updFeed").value = st.panel?.update_feed_url || "";
  document.getElementById("subTitle").textContent = st.panel?.subscription_title ? `Подписка: ${st.panel.subscription_title}` : "";
  document.getElementById("selName").textContent = st.panel?.selected_name || "—";
  document.getElementById("fullIp").textContent = st.podkop?.fully_routed_ip || "—";
  document.getElementById("proxyString").textContent = st.podkop?.proxy_string || "";

  // domains
  const domains = st.user_domains || [];
  document.getElementById("domains").value = domains.join("\n");

  renderServers(st.servers, st.panel?.selected_name || "");
  renderClients(st.clients, st.podkop?.fully_routed_ip || "");

  document.getElementById("topStatus").textContent = "";
}

async function saveSubscription(){
  const url = document.getElementById("subUrl").value.trim();
  document.getElementById("topStatus").textContent = "Сохраняю...";
  const r = await api("set_subscription", {subscription_url: url});
  document.getElementById("topStatus").textContent = r.ok === "true" ? "OK" : ("Ошибка: " + (r.error||""));
  await reload();
}

async function saveUpdateFeed(){
  const url = document.getElementById("updFeed").value.trim();
  document.getElementById("topStatus").textContent = "Сохраняю feed...";
  const r = await api("set_update_feed", {update_feed_url: url});
  document.getElementById("topStatus").textContent = r.ok === "true" ? "OK" : ("Ошибка: " + (r.error||""));
  await reload();
}

async function forceRefresh(){
  document.getElementById("topStatus").textContent = "Обновляю...";
  const r = await api("refresh");
  document.getElementById("topStatus").textContent = r.ok ? "OK" : "FAIL";
  await reload();
}

async function selectServer(name){
  document.getElementById("topStatus").textContent = "Применяю сервер...";
  const r = await api("select_server", {selected_name: name});
  document.getElementById("topStatus").textContent = r.ok === "true" ? "OK" : ("Ошибка: " + (r.error||""));
  await reload();
}

async function applyDomains(){
  const text = document.getElementById("domains").value;
  document.getElementById("domainsStatus").textContent = "Применяю...";
  const r = await api("set_domains", {domains: text});
  document.getElementById("domainsStatus").textContent = r.ok === "true" ? "OK" : "FAIL";
  await reload();
}

async function applyClient(){
  const ip = document.getElementById("clientSelect").value;
  document.getElementById("clientStatus").textContent = "Применяю...";
  const r = await api("set_fully_routed", {ip});
  document.getElementById("clientStatus").textContent = r.ok === "true" ? `OK: ${ip || "очищено"}` : "FAIL";
  await reload();
}

async function clearClient(){
  document.getElementById("clientSelect").value = "";
  await applyClient();
}

reload();
EOF
}

setup_cron() {
  log "Setting hourly cron job"
  mkdir -p /etc/crontabs
  touch /etc/crontabs/root

  # remove previous riftpanel lines
  sed -i '/riftpanel\/hourly\.sh/d' /etc/crontabs/root || true
  echo "0 * * * * /usr/lib/riftpanel/hourly.sh >/dev/null 2>&1" >> /etc/crontabs/root

  /etc/init.d/cron restart >/dev/null 2>&1 || true
}

final_note() {
  log "Installed."
  echo
  echo "Open UI:  http://<router-ip>/riftpanel/"
  echo "API:      http://<router-ip>/cgi-bin/riftpanel-api?action=status"
  echo
  echo "Hourly job: /usr/lib/riftpanel/hourly.sh (subscription sync + panel updates)"
  echo "Logs:       logread -e riftpanel | tail -n 100"
}

main() {
  need_root
  is_openwrt

  # deps for CGI + JSON
  have curl || opkg_install curl
  [ -f /etc/ssl/certs/ca-certificates.crt ] || opkg_install ca-bundle
  have jsonfilter || opkg_install jsonfilter
  # jshn.sh is in libubox; usually present. If missing:
  [ -f /usr/share/libubox/jshn.sh ] || opkg_install libubox

  write_uci
  write_lib
  write_cgi
  write_web
  setup_cron

  final_note
}

main "$@"
