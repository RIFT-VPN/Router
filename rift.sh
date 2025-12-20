#!/bin/ash
set -eu

APP="riftpanel"
APPDIR="/usr/lib/${APP}"
WWWDIR="/www/${APP}"
CGI="/www/cgi-bin/${APP}"
UCI_CFG="/etc/config/${APP}"

# Версию увеличивай при релизах — по ней работает авто-апдейт
RIFT_VERSION="0.2.0"

# ВАЖНО: это твоя "истина" для авто-апдейта (raw rift.sh)
REMOTE_URL_DEFAULT="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"

log() { echo "[$APP] $*"; }
die() { echo "[$APP] ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Run as root"; }
is_openwrt() { [ -f /etc/openwrt_release ] || [ -f /etc/config/system ] || die "Not OpenWrt"; }

opkg_install() {
  pkg="$1"
  opkg status "$pkg" >/dev/null 2>&1 && return 0
  log "Installing: $pkg"
  opkg update >/dev/null 2>&1 || true
  opkg install "$pkg" >/dev/null
}

uci_get() { uci -q get "$1" 2>/dev/null || true; }
uci_set() { uci -q set "$1=$2"; }
uci_commit() { uci -q commit "$1"; }

# ---------------------------
# Helpers (urlencode/urldecode)
# ---------------------------
urldecode() {
  # + -> space, %XX -> byte
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

urlencode() {
  # Percent-encode UTF-8 bytes except unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
  # Works in BusyBox ash using od/hexdump.
  local s="$1" out="" c hex
  # Read bytes
  printf '%s' "$s" | od -An -tx1 | tr -d '\n' | tr ' ' '\n' | while IFS= read -r hex; do
    [ -n "$hex" ] || continue
    # Convert hex->char for checks using printf
    c="$(printf "\\x$hex")"
    case "$c" in
      [a-zA-Z0-9.~_-]) printf "%s" "$c" ;;
      *) printf "%%%s" "$(echo "$hex" | tr 'a-f' 'A-F')" ;;
    esac
  done
}

trim() { echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

sha256_file() {
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have openssl; then
    openssl dgst -sha256 "$1" | awk '{print $2}'
  else
    echo ""
  fi
}

# ---------------------------
# Write UCI config (preserve user data on updates)
# ---------------------------
ensure_uci_config() {
  if [ -f "$UCI_CFG" ]; then
    # ensure main section exists
    uci -q show "${APP}.main" >/dev/null 2>&1 || true
    return 0
  fi

  log "Creating $UCI_CFG"
  cat >"$UCI_CFG" <<EOF
config ${APP} main
  option subscription_url ''
  option selected_name ''
  option user_domains ''
  option fully_routed_ip ''
  option last_nodes_hash ''
  option remote_url '${REMOTE_URL_DEFAULT}'
  option installed_version '${RIFT_VERSION}'
EOF
  uci_commit "$APP" || true
}

# ---------------------------
# Ensure uhttpd CGI enabled
# ---------------------------
ensure_uhttpd() {
  # uhttpd is standard on OpenWrt; ensure CGI is on
  if ! have uhttpd; then
    opkg_install uhttpd
  fi

  # Best-effort: ensure cgi_prefix exists
  # OpenWrt usually has: option cgi_prefix '/cgi-bin'
  if ! uci -q get uhttpd.main.cgi_prefix >/dev/null 2>&1; then
    uci -q set uhttpd.main.cgi_prefix='/cgi-bin' || true
    uci -q commit uhttpd || true
  fi

  /etc/init.d/uhttpd enable >/dev/null 2>&1 || true
  /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}

# ---------------------------
# Backend: subscription & podkop sync
# ---------------------------
write_backend() {
  mkdir -p "$APPDIR"

  cat >"${APPDIR}/VERSION" <<EOF
${RIFT_VERSION}
EOF

  cat >"${APPDIR}/common.sh" <<'EOF'
#!/bin/ash
set -eu

APP="riftpanel"
STATE_DIR="/tmp/riftpanel"
mkdir -p "$STATE_DIR"

log(){ logger -t "$APP" "$*"; }
say(){ echo "[$APP] $*"; }

trim(){ echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

uci_get(){ uci -q get "$1" 2>/dev/null || true; }
uci_set(){ uci -q set "$1=$2"; }
uci_commit(){ uci -q commit "$1"; }

urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $2}'
  else
    echo ""
  fi
}

urlencode() {
  local s="$1"
  printf '%s' "$s" | od -An -tx1 | tr -d '\n' | tr ' ' '\n' | while IFS= read -r hex; do
    [ -n "$hex" ] || continue
    c="$(printf "\\x$hex")"
    case "$c" in
      [a-zA-Z0-9.~_-]) printf "%s" "$c" ;;
      *) printf "%%%s" "$(echo "$hex" | tr 'a-f' 'A-F')" ;;
    esac
  done
}
EOF
  chmod 0755 "${APPDIR}/common.sh"

  cat >"${APPDIR}/subscription.sh" <<'EOF'
#!/bin/ash
set -eu
. /usr/lib/riftpanel/common.sh

# Downloads subscription_url, decodes, outputs vless:// lines.
fetch_subscription_lines() {
  local url raw dec headers title_b64 title
  url="$(uci_get riftpanel.main.subscription_url)"
  url="$(echo "$url" | sed "s/^'//; s/'$//")"
  [ -n "$url" ] || return 0

  raw="$STATE_DIR/sub.raw"
  dec="$STATE_DIR/sub.dec"
  headers="$STATE_DIR/sub.headers"
  : >"$STATE_DIR/sub.title" || true

  if curl -fsS -L -m 25 -D "$headers" -o "$raw" "$url" 2>/dev/null; then
    title_b64="$(sed -n 's/^[Pp]rofile-title:[[:space:]]*base64://p' "$headers" | tr -d '\r' | head -n1 || true)"
    if [ -n "$title_b64" ]; then
      title="$(echo "$title_b64" | base64 -d 2>/dev/null || true)"
      [ -n "$title" ] && echo "$title" >"$STATE_DIR/sub.title" || true
    fi

    # Try base64 decode; if fails, keep as-is.
    if base64 -d <"$raw" >"$dec" 2>/dev/null; then :; else cp "$raw" "$dec"; fi

    grep -E '^vless://' "$dec" 2>/dev/null | tr -d '\r' || true
  fi
}

subscription_title() { [ -f "$STATE_DIR/sub.title" ] && cat "$STATE_DIR/sub.title" || true; }

nodes_hash() {
  local tmp h
  tmp="$STATE_DIR/sub.nodes"
  fetch_subscription_lines >"$tmp" || true
  h="$(sha256_file "$tmp")"
  echo "$h"
}

# Parse VLESS lines -> tab-separated:
# idx  name_decoded  host  port  raw
parse_subscription() {
  local i line name_enc name host port
  i=0
  fetch_subscription_lines | while IFS= read -r line; do
    i=$((i+1))
    name_enc=""
    echo "$line" | grep -q '#' && name_enc="${line#*#}"
    name="$(urldecode "$name_enc")"
    [ -n "$name" ] || name="Server $i"

    host="$(echo "$line" | sed -n 's#^vless://[^@]*@\([^:]*\):\([0-9][0-9]*\).*#\1#p')"
    port="$(echo "$line" | sed -n 's#^vless://[^@]*@[^:]*:\([0-9][0-9]*\).*#\1#p')"

    printf "%s\t%s\t%s\t%s\t%s\n" "$i" "$name" "$host" "$port" "$line"
  done
}
EOF
  chmod 0755 "${APPDIR}/subscription.sh"

  cat >"${APPDIR}/podkop_sync.sh" <<'EOF'
#!/bin/ash
set -eu
. /usr/lib/riftpanel/common.sh
. /usr/lib/riftpanel/subscription.sh

podkop_restart() { /etc/init.d/podkop restart >/dev/null 2>&1 || true; }

set_selected_server_by_name() {
  # arg: decoded name
  local name="$1" raw=""
  [ -n "$name" ] || return 1

  # Find node raw line by name
  parse_subscription | while IFS="$(printf '\t')" read -r idx n host port line; do
    [ "$n" = "$name" ] || continue
    echo "$line"
    break
  done >"$STATE_DIR/sel.raw" || true

  [ -s "$STATE_DIR/sel.raw" ] || return 2
  raw="$(cat "$STATE_DIR/sel.raw")"

  # Store selected_name (decoded) in riftpanel
  uci_set "riftpanel.main.selected_name" "'$name'"
  uci_commit riftpanel

  # For podkop store URL-encoded full URI (safer for unicode/spaces)
  enc="$(urlencode "$raw")"
  uci -q set "podkop.main.proxy_string=vless://${enc#vless%3A%2F%2F}" 2>/dev/null || uci -q set "podkop.main.proxy_string='$enc'" 2>/dev/null || true

  # Alternative fallback: store as quoted raw
  if ! uci -q get podkop.main.proxy_string >/dev/null 2>&1; then
    uci -q set "podkop.main.proxy_string" "'$raw'" || true
  fi

  uci_commit podkop
  podkop_restart
  return 0
}

sync_active_server_if_changed() {
  local sel cur want
  sel="$(uci_get riftpanel.main.selected_name)"
  sel="$(echo "$sel" | sed "s/^'//; s/'$//")"
  [ -n "$sel" ] || return 0

  cur="$(uci_get podkop.main.proxy_string)"
  cur="$(echo "$cur" | sed "s/^'//; s/'$//")"

  parse_subscription | while IFS="$(printf '\t')" read -r idx n host port line; do
    [ "$n" = "$sel" ] || continue
    echo "$line"
    break
  done >"$STATE_DIR/want.raw" || true

  [ -s "$STATE_DIR/want.raw" ] || return 0
  want="$(cat "$STATE_DIR/want.raw")"

  # Compare best-effort: decode current if it looks urlencoded vless://...
  # If mismatch -> update
  enc_want="$(urlencode "$want")"
  if echo "$cur" | grep -qE '^vless://'; then
    # cur might be already encoded or raw; compare both variants
    if [ "$cur" != "$want" ] && [ "$cur" != "$enc_want" ] && [ "$cur" != "vless://${enc_want#vless%3A%2F%2F}" ]; then
      log "Selected server changed in subscription -> updating podkop proxy_string"
      uci -q set "podkop.main.proxy_string=vless://${enc_want#vless%3A%2F%2F}" || uci -q set "podkop.main.proxy_string='$enc_want'" || uci -q set "podkop.main.proxy_string='$want'" || true
      uci_commit podkop
      podkop_restart
    fi
  fi
}

set_user_domains() {
  # arg: newline-separated domains
  local text="$1" d
  # Save into riftpanel as-is
  uci_set "riftpanel.main.user_domains" "'$text'"
  uci_commit riftpanel

  # Apply to podkop (list)
  uci -q delete podkop.main.user_domains >/dev/null 2>&1 || true
  echo "$text" | tr '\r' '\n' | while IFS= read -r d; do
    d="$(trim "$d")"
    [ -n "$d" ] || continue
    echo "$d" | grep -qE '^[A-Za-z0-9.-]+$' || continue
    uci -q add_list "podkop.main.user_domains=$d" || true
  done
  uci_commit podkop
  podkop_restart
}

set_fully_routed_ip() {
  # arg: ipv4 or empty to clear
  local ip="$1"
  uci_set "riftpanel.main.fully_routed_ip" "'$ip'"
  uci_commit riftpanel

  uci -q delete podkop.main.fully_routed_ips >/dev/null 2>&1 || true
  if [ -n "$ip" ]; then
    uci -q add_list "podkop.main.fully_routed_ips=$ip" || true
  fi
  uci_commit podkop
  podkop_restart
}
EOF
  chmod 0755 "${APPDIR}/podkop_sync.sh"

  cat >"${APPDIR}/hourly.sh" <<'EOF'
#!/bin/ash
set -eu
. /usr/lib/riftpanel/common.sh
. /usr/lib/riftpanel/subscription.sh
. /usr/lib/riftpanel/podkop_sync.sh

hourly() {
  # 1) Subscription hash
  local h prev
  h="$(nodes_hash || true)"
  prev="$(uci_get riftpanel.main.last_nodes_hash)"
  prev="$(echo "$prev" | sed "s/^'//; s/'$//")"

  if [ -n "$h" ] && [ "$h" != "$prev" ]; then
    log "Subscription nodes changed"
    uci_set "riftpanel.main.last_nodes_hash" "'$h'"
    uci_commit riftpanel
    sync_active_server_if_changed || true
  fi

  # 2) Panel self-update (if enabled)
  /usr/bin/riftpanel self-update >/dev/null 2>&1 || true
}
hourly "$@"
EOF
  chmod 0755 "${APPDIR}/hourly.sh"
}

# ---------------------------
# CGI API
# ---------------------------
write_cgi() {
  mkdir -p /www/cgi-bin
  cat >"$CGI" <<'EOF'
#!/bin/ash
set -eu
. /usr/lib/riftpanel/common.sh
. /usr/lib/riftpanel/subscription.sh
. /usr/lib/riftpanel/podkop_sync.sh
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
  # GET parser for small params
  echo "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1
}

# parse x-www-form-urlencoded body
bparam() {
  # usage: echo "$body" | bparam key
  tr '&' '\n' | sed -n "s/^$1=//p" | head -n1
}

clients_list() {
  # ip \t mac \t name
  # /tmp/dhcp.leases: <exp> <mac> <ip> <name> <id>
  [ -f /tmp/dhcp.leases ] || return 0
  awk '{print $3 "\t" $2 "\t" $4}' /tmp/dhcp.leases 2>/dev/null || true
}

action="${1:-}"
if [ -z "$action" ]; then
  action="$(qparam action || true)"
fi

body=""
if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
  body="$(read_body || true)"
fi

hdr_json
json_init

case "$action" in
  status|"")
    json_add_string version "$(cat /usr/lib/riftpanel/VERSION 2>/dev/null || echo 0)"
    json_add_string subscription_url "$(uci_get riftpanel.main.subscription_url | sed "s/^'//; s/'$//")"
    json_add_string selected_name "$(uci_get riftpanel.main.selected_name | sed "s/^'//; s/'$//")"
    json_add_string user_domains "$(uci_get riftpanel.main.user_domains | sed "s/^'//; s/'$//")"
    json_add_string fully_routed_ip "$(uci_get riftpanel.main.fully_routed_ip | sed "s/^'//; s/'$//")"
    json_add_string sub_title "$(subscription_title || true)"

    json_add_array nodes
    parse_subscription | while IFS="$(printf '\t')" read -r idx name host port raw; do
      json_add_object ""
      json_add_int idx "$idx"
      json_add_string name "$name"
      json_add_string host "$host"
      json_add_string port "$port"
      json_close_object
    done
    json_close_array

    json_add_array clients
    clients_list | while IFS="$(printf '\t')" read -r ip mac name; do
      json_add_object ""
      json_add_string ip "$ip"
      json_add_string mac "$mac"
      json_add_string name "$name"
      json_close_object
    done
    json_close_array
    ;;

  set_subscription)
    url="$(echo "$body" | bparam url | head -n1 || true)"
    url="$(urldecode "$url")"
    uci_set "riftpanel.main.subscription_url" "'$url'"
    uci_commit riftpanel
    json_add_string ok "1"
    ;;

  refresh)
    # just force hash update & return nodes
    h="$(nodes_hash || true)"
    uci_set "riftpanel.main.last_nodes_hash" "'$h'"
    uci_commit riftpanel
    json_add_string ok "1"
    ;;

  select_node)
    name="$(echo "$body" | bparam name | head -n1 || true)"
    name="$(urldecode "$name")"
    if set_selected_server_by_name "$name"; then
      json_add_string ok "1"
    else
      json_add_string ok "0"
    fi
    ;;

  set_domains)
    d="$(echo "$body" | bparam domains | head -n1 || true)"
    d="$(urldecode "$d")"
    set_user_domains "$d" || true
    json_add_string ok "1"
    ;;

  set_device)
    ip="$(echo "$body" | bparam ip | head -n1 || true)"
    ip="$(urldecode "$ip")"
    # allow empty to clear
    echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || ip=""
    set_fully_routed_ip "$ip" || true
    json_add_string ok "1"
    ;;

  *)
    json_add_string ok "0"
    json_add_string error "unknown action"
    ;;
esac

json_dump
EOF
  chmod 0755 "$CGI"
}

# ---------------------------
# Web UI
# ---------------------------
write_web() {
  mkdir -p "$WWWDIR"

  cat >"${WWWDIR}/index.html" <<'EOF'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>RiftPanel</title>
  <link rel="stylesheet" href="./style.css"/>
</head>
<body>
  <div class="wrap">
    <header>
      <div class="title">
        <h1>RiftPanel</h1>
        <div class="muted">Панель управления подпиской и podkop</div>
      </div>
      <div class="badge" id="ver">v?</div>
    </header>

    <section class="card">
      <h2>Подписка</h2>
      <div class="row">
        <input id="subUrl" placeholder="https://... (subscription link)"/>
        <button id="saveSub">Сохранить</button>
        <button id="refresh">Обновить список</button>
      </div>
      <div class="muted" id="subTitle"></div>
    </section>

    <section class="card">
      <h2>Сервера в подписке</h2>
      <div class="muted">Выбери сервер — он будет прописан в podkop и будет авто-обновляться при смене конфигурации в подписке.</div>
      <div id="nodes" class="list"></div>
    </section>

    <section class="card">
      <h2>Домены для маршрутизации</h2>
      <div class="muted">Каждая строка — домен. Будет применено в podkop.main.user_domains</div>
      <textarea id="domains" rows="6" placeholder="example.com&#10;api.example.com"></textarea>
      <div class="row">
        <button id="saveDomains">Сохранить и применить</button>
      </div>
    </section>

    <section class="card">
      <h2>Устройство, которое полностью через VPN</h2>
      <div class="muted">Выбери устройство из DHCP leases (LAN). Будет применено в podkop.main.fully_routed_ips</div>
      <div class="row">
        <select id="device"></select>
        <button id="applyDevice">Применить</button>
        <button id="clearDevice" class="secondary">Сбросить</button>
      </div>
    </section>

    <footer class="muted">
      API: <code>/cgi-bin/riftpanel?action=status</code>
    </footer>
  </div>

  <script src="./app.js"></script>
</body>
</html>
EOF

  cat >"${WWWDIR}/style.css" <<'EOF'
:root{--bg:#0b0f14;--card:#101826;--text:#e8eef6;--muted:#9bb0c3;--accent:#6ee7ff;--b:#1b2a40}
*{box-sizing:border-box;font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Cantarell,Noto Sans,sans-serif}
body{margin:0;background:var(--bg);color:var(--text)}
.wrap{max-width:980px;margin:0 auto;padding:20px}
header{display:flex;align-items:center;justify-content:space-between;margin-bottom:14px}
h1{margin:0;font-size:22px}
.muted{color:var(--muted);font-size:13px;margin-top:6px}
.card{background:var(--card);border:1px solid var(--b);border-radius:14px;padding:14px 14px;margin:12px 0}
h2{margin:0 0 10px 0;font-size:16px}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
input,textarea,select{width:100%;max-width:100%;background:#0c1420;border:1px solid var(--b);color:var(--text);border-radius:10px;padding:10px}
textarea{resize:vertical}
button{background:var(--accent);color:#001018;border:0;border-radius:10px;padding:10px 12px;font-weight:700;cursor:pointer}
button.secondary{background:#2a3d57;color:var(--text)}
.badge{border:1px solid var(--b);padding:6px 10px;border-radius:999px;color:var(--muted)}
.list{display:flex;flex-direction:column;gap:8px;margin-top:10px}
.node{display:flex;justify-content:space-between;gap:12px;border:1px solid var(--b);border-radius:12px;padding:10px;background:#0c1420}
.node .info{min-width:0}
.node .name{font-weight:700}
.node .meta{color:var(--muted);font-size:12px;margin-top:4px;word-break:break-word}
.node button{white-space:nowrap}
footer{margin-top:18px}
code{color:#d7f9ff}
EOF

  cat >"${WWWDIR}/app.js" <<'EOF'
async function api(action, data){
  const url = `/cgi-bin/riftpanel?action=${encodeURIComponent(action)}`;
  const body = data ? new URLSearchParams(data) : null;
  const res = await fetch(url, {method: data ? 'POST' : 'GET', body});
  return await res.json();
}

function el(id){ return document.getElementById(id); }

function renderNodes(nodes, selected){
  const box = el('nodes');
  box.innerHTML = '';
  if(!nodes || nodes.length===0){
    box.innerHTML = '<div class="muted">Нет серверов. Проверь подписку и нажми “Обновить список”.</div>';
    return;
  }
  nodes.forEach(n=>{
    const row = document.createElement('div');
    row.className = 'node';
    const info = document.createElement('div');
    info.className='info';
    info.innerHTML = `
      <div class="name">${escapeHtml(n.name)} ${n.name===selected ? ' <span style="color:var(--accent)">(выбран)</span>' : ''}</div>
      <div class="meta">${escapeHtml(n.host)}:${escapeHtml(String(n.port||''))}</div>
    `;
    const btn = document.createElement('button');
    btn.textContent = n.name===selected ? 'Выбран' : 'Выбрать';
    btn.disabled = n.name===selected;
    btn.onclick = async ()=>{
      await api('select_node', {name: n.name});
      await load();
    };
    row.appendChild(info);
    row.appendChild(btn);
    box.appendChild(row);
  });
}

function renderClients(clients, selectedIp){
  const sel = el('device');
  sel.innerHTML = '';
  const opt0 = document.createElement('option');
  opt0.value = '';
  opt0.textContent = '— не выбрано —';
  sel.appendChild(opt0);

  (clients||[]).forEach(c=>{
    const o = document.createElement('option');
    o.value = c.ip;
    o.textContent = `${c.name || 'device'} — ${c.ip} — ${c.mac}`;
    if(c.ip === selectedIp) o.selected = true;
    sel.appendChild(o);
  });
}

function escapeHtml(s){
  return String(s).replace(/[&<>"']/g, m=>({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;" }[m]));
}

async function load(){
  const st = await api('status');
  el('ver').textContent = `v${st.version || '?'}`;
  el('subUrl').value = st.subscription_url || '';
  el('domains').value = st.user_domains || '';
  el('subTitle').textContent = st.sub_title ? `Подписка: ${st.sub_title}` : '';
  renderNodes(st.nodes || [], st.selected_name || '');
  renderClients(st.clients || [], st.fully_routed_ip || '');
}

el('saveSub').onclick = async ()=>{
  const url = el('subUrl').value.trim();
  await api('set_subscription', {url});
  await load();
};

el('refresh').onclick = async ()=>{
  await api('refresh', {x:'1'});
  await load();
};

el('saveDomains').onclick = async ()=>{
  await api('set_domains', {domains: el('domains').value});
  await load();
};

el('applyDevice').onclick = async ()=>{
  await api('set_device', {ip: el('device').value});
  await load();
};

el('clearDevice').onclick = async ()=>{
  await api('set_device', {ip: ''});
  await load();
};

load();
EOF
}

# ---------------------------
# Wrapper tool: /usr/bin/riftpanel
# ---------------------------
write_wrapper() {
  cat >/usr/bin/riftpanel <<'EOF'
#!/bin/ash
set -eu

APP="riftpanel"

uci_get(){ uci -q get "$1" 2>/dev/null || true; }

get_local_ver() { cat /usr/lib/riftpanel/VERSION 2>/dev/null || echo "0.0.0"; }

# Read RIFT_VERSION from remote rift.sh without executing it (best-effort)
get_remote_ver() {
  local url tmp
  url="$(uci_get riftpanel.main.remote_url)"
  url="$(echo "$url" | sed "s/^'//; s/'$//")"
  [ -n "$url" ] || url="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"

  tmp="/tmp/riftpanel_remote_head.$$"
  curl -fsS -L -m 20 "$url" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; echo ""; return 0; }
  # Look for line: RIFT_VERSION="x.y.z"
  v="$(sed -n 's/^RIFT_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n1 || true)"
  rm -f "$tmp"
  echo "$v"
}

self_update() {
  local localv remotev url tmp
  localv="$(get_local_ver)"
  remotev="$(get_remote_ver)"

  [ -n "$remotev" ] || exit 0
  [ "$remotev" = "$localv" ] && exit 0

  url="$(uci_get riftpanel.main.remote_url)"
  url="$(echo "$url" | sed "s/^'//; s/'$//")"
  [ -n "$url" ] || url="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"

  tmp="/tmp/riftpanel_update.$$"
  curl -fsS -L -m 60 "$url" -o "$tmp" 2>/dev/null || exit 0
  chmod +x "$tmp" || true

  # Update mode rewrites only code & web, keeps /etc/config/riftpanel
  sh "$tmp" update >/dev/null 2>&1 || true
  rm -f "$tmp"
}

case "${1:-}" in
  hourly) /usr/lib/riftpanel/hourly.sh ;;
  self-update) self_update ;;
  *) echo "Usage: riftpanel {hourly|self-update}" ;;
esac
EOF
  chmod 0755 /usr/bin/riftpanel
}

# ---------------------------
# Cron hourly
# ---------------------------
ensure_cron() {
  # OpenWrt uses /etc/crontabs/root
  [ -d /etc/crontabs ] || mkdir -p /etc/crontabs
  touch /etc/crontabs/root

  # run at minute 7 each hour to avoid spike on 00
  grep -q 'riftpanel hourly' /etc/crontabs/root 2>/dev/null || {
    echo '7 * * * * /usr/bin/riftpanel hourly >/dev/null 2>&1' >>/etc/crontabs/root
  }

  /etc/init.d/cron enable >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1 || true
}

# ---------------------------
# Install/Update (code only; preserve /etc/config/riftpanel)
# ---------------------------
install_deps() {
  opkg_install curl
  opkg_install ca-bundle || true
  opkg_install coreutils-base64 || true
  opkg_install libubox
}

write_all_code() {
  ensure_uhttpd
  write_backend
  write_cgi
  write_web
  write_wrapper
  ensure_cron

  # store installed version in UCI
  uci -q set riftpanel.main.installed_version="'${RIFT_VERSION}'" >/dev/null 2>&1 || true
  uci -q commit riftpanel >/dev/null 2>&1 || true
}

cmd_install() {
  need_root
  is_openwrt
  install_deps
  ensure_uci_config
  write_all_code

  log "Installed. Open: http://<router-ip>/${APP}/"
  log "API: /cgi-bin/${APP}?action=status"
}

cmd_update() {
  need_root
  is_openwrt
  install_deps
  ensure_uci_config
  # IMPORTANT: do not overwrite /etc/config/riftpanel (user data)
  write_all_code

  log "Updated code to v${RIFT_VERSION} (user config preserved)"
}

cmd_uninstall() {
  need_root
  rm -rf "$APPDIR" "$WWWDIR" "$CGI" /usr/bin/riftpanel 2>/dev/null || true
  # user data intentionally not removed:
  log "Uninstalled code. User config kept: ${UCI_CFG}"
}

case "${1:-install}" in
  install) cmd_install ;;
  update) cmd_update ;;
  uninstall) cmd_uninstall ;;
  *) echo "Usage: $0 {install|update|uninstall}" ;;
esac
