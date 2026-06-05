#!/bin/sh
# === RIFT PANEL INSTALLER & UPDATER (v4.7) ===
# Install: sh <(wget -O - https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh)
#
# v4.7 changes (vs v4.6):
#   - SVG-флаги для ~50 стран (вместо 4)
#   - Разделители ㅤ (U+3164) рендерятся как тонкая линия без кнопок
#   - MAC-based «полный VPN»: storage MAC + watcher daemon обновляет IP при переподключении

PANEL_VERSION="4.7"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"
EXT_SINGBOX_INSTALL_URL="https://raw.githubusercontent.com/EikeiDev/OpenWRT-sing-box-extended/refs/heads/main/install.sh"

# === MENU: detect existing installation ===
if [ -f /etc/podkop_data/version ]; then
  INSTALLED_VER="$(cat /etc/podkop_data/version 2>/dev/null)"
  echo "================================================="
  echo " RIFT Panel v${INSTALLED_VER} обнаружена"
  echo "================================================="
  echo " 1) Обновить панель до v${PANEL_VERSION}"
  echo " 2) Полностью удалить панель"
  echo " 3) Выход"
  echo "================================================="
  printf "Выберите действие [1/2/3]: "
  read -r CHOICE
  case "$CHOICE" in
    2)
      echo "=== УДАЛЕНИЕ RIFT PANEL ==="
      echo "[1/7] Остановка веб-сервера..."
      uci -q delete uhttpd.podkop_panel
      uci commit uhttpd >/dev/null 2>&1
      echo "[2/8] Удаление cron задач..."
      (crontab -l 2>/dev/null | grep -Fv "autoupdate_sub" | grep -Fv "autoupdate_panel" | grep -Fv "/etc/podkop_data/") | crontab -
      echo "[3/8] Остановка MAC-VPN watcher (v4.7+)..."
      [ -x /etc/init.d/rift-mac-vpn-watcher ] && {
        /etc/init.d/rift-mac-vpn-watcher stop >/dev/null 2>&1
        /etc/init.d/rift-mac-vpn-watcher disable >/dev/null 2>&1
      }
      rm -f /etc/init.d/rift-mac-vpn-watcher /usr/local/sbin/rift-mac-vpn-watcher
      echo "[4/8] Удаление файлов панели..."
      rm -rf /www/podkop_panel
      echo "[5/8] Восстановление главной страницы..."
      if [ -f /etc/podkop_data/openwrt_index_backup.html ]; then
        cp /etc/podkop_data/openwrt_index_backup.html /www/index.html
      fi
      echo "[6/8] Удаление данных..."
      rm -rf /etc/podkop_data
      echo "[7/8] Удаление конфигурации..."
      rm -f /etc/config/podkop_subs
      uci -q delete dhcp.rift_panel_domain
      uci commit dhcp >/dev/null 2>&1
      echo "[8/8] Очистка temp..."
      rm -f /tmp/podkop_sub*.body /tmp/podkop_sub*.err /tmp/rift_*.sh /tmp/rift_*.err
      /etc/init.d/uhttpd restart >/dev/null 2>&1
      /etc/init.d/dnsmasq restart >/dev/null 2>&1
      echo "================================================="
      echo "RIFT Panel полностью удалена."
      echo "Podkop остался нетронутым."
      echo "================================================="
      exit 0
      ;;
    3)
      echo "Выход."
      exit 0
      ;;
    *)
      echo "Обновление до v${PANEL_VERSION}..."
      ;;
  esac
fi

echo "=== УСТАНОВКА RIFT PANEL v${PANEL_VERSION} ==="

get_singbox_version() {
  /usr/bin/sing-box version 2>/dev/null | head -n 1
}

singbox_supports_xhttp() {
  [ -x /usr/bin/sing-box ] || return 1
  cat > /tmp/rift_xhttp_check.json <<'JSON'
{
  "log": { "disabled": true },
  "inbounds": [],
  "outbounds": [
    {
      "type": "vless",
      "tag": "test-out",
      "server": "example.com",
      "server_port": 443,
      "uuid": "11111111-1111-1111-1111-111111111111",
      "tls": {
        "enabled": true,
        "server_name": "example.com",
        "insecure": true,
        "alpn": ["h2", "http/1.1"]
      },
      "transport": {
        "type": "xhttp",
        "path": "/",
        "mode": "auto",
        "host": "example.com",
        "x_padding_bytes": "100-1000"
      }
    }
  ]
}
JSON
  /usr/bin/sing-box check -c /tmp/rift_xhttp_check.json >/tmp/rift_xhttp_check.log 2>&1
  local rc=$?
  rm -f /tmp/rift_xhttp_check.json /tmp/rift_xhttp_check.log
  return $rc
}

# Map device arch -> shtorm-7/sing-box-extended asset suffix
_singbox_arch_suffix() {
  local a; a=$(uname -m)
  if [ -f /etc/openwrt_release ]; then
    local da; da=$(. /etc/openwrt_release; echo "$DISTRIB_ARCH")
    case "$da" in
      *mips64el*|*mips64le*) a=mips64el ;;
      *mipsel*|*mipsle*) a=mipsel ;;
    esac
  fi
  case "$a" in
    aarch64) echo arm64 ;;
    armv7*) echo armv7 ;;
    armv6*) echo armv6 ;;
    x86_64) echo amd64 ;;
    i386|i686) echo 386 ;;
    mips) echo mips-softfloat ;;
    mipsel|mipsle) echo mipsle-softfloat ;;
    mips64) echo mips64 ;;
    mips64el|mips64le) echo mips64le ;;
    riscv64) echo riscv64 ;;
    s390x) echo s390x ;;
    *) echo "" ;;
  esac
}

# Неинтерактивная установка sing-box-extended (заменяет штатный /usr/bin/sing-box).
# Скачивает последний стабильный релиз, ПРОВЕРЯЕТ что бинарь запускается на устройстве,
# делает бэкап старого, только потом подменяет. На любой ошибке штатный бинарь не трогается.
install_extended_singbox() {
  local api="https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=30"
  local suffix; suffix=$(_singbox_arch_suffix)
  [ -n "$suffix" ] || { echo "  -> неизвестная архитектура $(uname -m)"; return 1; }

  local FETCH DL
  if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL --connect-timeout 20"; DL="curl -fsSL --connect-timeout 20 -o"
  elif command -v uclient-fetch >/dev/null 2>&1; then
    FETCH="uclient-fetch -q -O -"; DL="uclient-fetch -q -O"
  else
    FETCH="wget -qO-"; DL="wget -qO"
  fi

  local tag
  tag=$($FETCH "$api" 2>/dev/null | tr ',' '\n' | grep '"tag_name"' \
        | awk -F '"' '{print $4}' | grep -viE 'rc|beta|alpha' | head -n1)
  [ -n "$tag" ] || { echo "  -> не удалось получить версию extended (нет сети/GitHub API)"; return 1; }

  local url
  url=$($FETCH "https://api.github.com/repos/shtorm-7/sing-box-extended/releases/tags/$tag" 2>/dev/null \
        | tr ',' '\n' | grep browser_download_url | grep "linux-$suffix.tar.gz" \
        | head -n1 | awk -F '"' '{print $4}')
  [ -n "$url" ] || { echo "  -> нет сборки под $suffix в релизе $tag"; return 1; }

  local wd=/tmp/rift_sbx; rm -rf "$wd"; mkdir -p "$wd" || return 1
  $DL "$wd/sb.tar.gz" "$url" 2>/dev/null || { echo "  -> ошибка скачивания extended"; rm -rf "$wd"; return 1; }
  [ -s "$wd/sb.tar.gz" ] || { echo "  -> пустой архив extended"; rm -rf "$wd"; return 1; }
  tar -xzf "$wd/sb.tar.gz" -C "$wd" 2>/dev/null || { echo "  -> ошибка распаковки extended"; rm -rf "$wd"; return 1; }

  local bin; bin=$(find "$wd" -type f -name sing-box | head -n1)
  [ -n "$bin" ] || { echo "  -> бинарь не найден в архиве"; rm -rf "$wd"; return 1; }
  chmod +x "$bin"
  # Проверяем что скачанный бинарь реально запускается на этом устройстве ДО подмены живого
  "$bin" version >/dev/null 2>&1 || { echo "  -> скачанный бинарь не запускается на устройстве"; rm -rf "$wd"; return 1; }

  # Бэкап штатного бинаря один раз (для ручного отката)
  mkdir -p /etc/podkop_data
  if [ -x /usr/bin/sing-box ] && [ ! -f /etc/podkop_data/sing-box.stock.bak ]; then
    cp /usr/bin/sing-box /etc/podkop_data/sing-box.stock.bak 2>/dev/null || true
  fi

  /etc/init.d/podkop stop >/dev/null 2>&1 || true
  sleep 1
  mv -f "$bin" /usr/bin/sing-box || { echo "  -> не удалось заменить бинарь"; rm -rf "$wd"; /etc/init.d/podkop start >/dev/null 2>&1; return 1; }
  chmod +x /usr/bin/sing-box
  rm -rf "$wd"
  /etc/init.d/podkop start >/dev/null 2>&1 || true
  return 0
}

ensure_xhttp_singbox() {
  if singbox_supports_xhttp; then
    echo "  -> sing-box уже поддерживает XHTTP: $(get_singbox_version)"
    return 0
  fi
  echo "  -> обнаружен обычный sing-box, ставлю sing-box-extended для XHTTP..."
  install_extended_singbox || return 1
  sleep 2
  singbox_supports_xhttp
}

# === Подробный лог установки (для диагностики) ===
mkdir -p /etc/podkop_data 2>/dev/null
INSTALL_LOG=/etc/podkop_data/install.log
logi(){ echo "$*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$INSTALL_LOG" 2>/dev/null; }
{
  echo "================================================================"
  echo " RIFT Panel install/upgrade v${PANEL_VERSION}  @ $(date '+%Y-%m-%d %H:%M:%S')"
  echo " OpenWrt: $(grep -E 'DISTRIB_(RELEASE|ARCH)' /etc/openwrt_release 2>/dev/null | tr '\n' ' ')"
  echo " uname:   $(uname -m) / $(uname -r)"
  echo " model:   $(cat /tmp/sysinfo/model 2>/dev/null)"
  echo " sing-box(before): $(/usr/bin/sing-box version 2>/dev/null | head -1)"
  if [ -s /etc/podkop_data/hwid ]; then echo " режим: ОБНОВЛЕНИЕ (hwid сохраняется)"; else echo " режим: ЧИСТАЯ УСТАНОВКА"; fi
  echo "================================================================"
} >> "$INSTALL_LOG" 2>/dev/null

# 1) deps
logi "[1/10] Установка пакетов (opkg)..."
opkg update >>"$INSTALL_LOG" 2>&1
opkg install ca-bundle coreutils-base64 lua uclient-fetch curl >>"$INSTALL_LOG" 2>&1 || true
logi "  -> lua=$(command -v lua || echo НЕТ) uclient-fetch=$(command -v uclient-fetch || echo НЕТ) curl=$(command -v curl || echo НЕТ)"

# 2) structure
logi "[2/10] Настройка системы..."
mkdir -p /www/podkop_panel/cgi-bin
mkdir -p /etc/podkop_data
touch /etc/config/podkop_subs
if [ ! -s /etc/config/podkop_subs ]; then
  echo "config podkop_subs 'config'" > /etc/config/podkop_subs
fi
echo "${PANEL_VERSION}" > /etc/podkop_data/version

# Generate HWID from multiple hardware sources (tamper-resistant)
generate_hwid() {
  local _mac _board _model _cpuinfo _mtd_factory _dmi _salt _raw
  _mac=$(cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo "00:00:00:00:00:00")
  _board=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "generic")
  _model=$(cat /tmp/sysinfo/model 2>/dev/null || echo "router")
  _cpuinfo=$(grep -E "^(Serial|Hardware|machine|system type)" /proc/cpuinfo 2>/dev/null | head -4)
  # Factory calibration data from MTD — contains burned-in MAC, unique per device, survives MAC spoofing
  _mtd_factory=""
  if [ -e /dev/mtd2ro ]; then
    _mtd_factory=$(dd if=/dev/mtd2ro bs=1 count=64 skip=4 2>/dev/null | md5sum 2>/dev/null | cut -c1-32)
  elif [ -e /dev/mtd0ro ]; then
    _mtd_factory=$(dd if=/dev/mtd0ro bs=1 count=64 skip=4 2>/dev/null | md5sum 2>/dev/null | cut -c1-32)
  fi
  # DMI serial for x86 routers
  _dmi=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "")
  _salt="RiFT-hW1d-s4Lt-v2"
  _raw="${_salt}|${_mac}|${_board}|${_model}|${_cpuinfo}|${_mtd_factory}|${_dmi}"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$_raw" | sha256sum | cut -c1-16
  else
    printf '%s' "$_raw" | md5sum | cut -c1-16
  fi
}
# Сохраняем существующий HWID при апгрейде: device в Remnawave = (hwid,user),
# смена hwid = новое устройство → превышение лимита у клиента. Генерим только на чистой установке.
if [ -s /etc/podkop_data/hwid ]; then
  HWID=$(cat /etc/podkop_data/hwid)
  logi "  -> HWID сохранён при апгрейде: ${HWID} (устройство в Remnawave не меняется)"
else
  HWID=$(generate_hwid)
  echo "$HWID" > /etc/podkop_data/hwid
  logi "  -> HWID сгенерирован (чистая установка): ${HWID}"
fi

# 3) uhttpd
logi "[3/10] Настройка веб-сервера (порт 2017)..."
uci -q delete uhttpd.podkop_panel
uci set uhttpd.podkop_panel=uhttpd
uci add_list uhttpd.podkop_panel.listen_http='0.0.0.0:2017'
uci set uhttpd.podkop_panel.home='/www/podkop_panel'
uci set uhttpd.podkop_panel.rfc1918_filter='0'
uci set uhttpd.podkop_panel.max_requests='10'
uci set uhttpd.podkop_panel.cgi_prefix='/cgi-bin'
uci commit uhttpd >/dev/null 2>&1

# 4) remove rift domain
logi "[4/10] Очистка DNS..."
for s in $(uci show dhcp 2>/dev/null | sed -n "s/^\(dhcp\.@domain\[[0-9]\+\]\)=domain.*/\1/p"); do
  [ "$(uci -q get ${s}.name)" = "rift" ] && uci delete "$s"
done
uci -q delete dhcp.rift_panel_domain
uci -q del_list dhcp.@dnsmasq[0].rebind_domain='rift'
uci commit dhcp >/dev/null 2>&1

# 5) sing-box-extended (нужен для XHTTP; HY2/TCP/gRPC тоже работают на нём).
# v4.7: всегда ставим extended, заменяя штатный sing-box. JSON-пайплайн гоняет
# все транспорты через outbound_json, поэтому facade-патч (XHTTP→HTTP) больше не нужен.
logi "[5/10] sing-box-extended (для XHTTP/HY2)..."
if singbox_supports_xhttp; then
  logi "  -> уже extended: $(get_singbox_version) — пропускаю установку"
else
  logi "  -> штатный sing-box ($(get_singbox_version)) — ставлю extended..."
  if install_extended_singbox >>"$INSTALL_LOG" 2>&1; then
    if singbox_supports_xhttp; then
      logi "  -> OK, extended установлен: $(get_singbox_version)"
    else
      logi "  -> ВНИМАНИЕ: бинарь заменён, но XHTTP-проверка не прошла ($(get_singbox_version))"
    fi
  else
    logi "  -> ОШИБКА установки extended (см. $INSTALL_LOG). XHTTP-узлы работать не будут до повторной попытки."
  fi
fi

# 6) Backend (RPC)
logi "[6/10] Запись Backend (RPC панели)..."
cat <<'EOF' > /www/podkop_panel/cgi-bin/rpc
#!/usr/bin/lua

function trim(s) return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1")) end
function shq(s) s=tostring(s or "") return "'"..s:gsub("'", "'\\''").."'" end

local function is_array(tbl)
  if type(tbl) ~= "table" then return false end
  local n, max = 0, 0
  for k,_ in pairs(tbl) do
    if type(k) ~= "number" then return false end
    if k <= 0 or (k % 1) ~= 0 then return false end
    if k > max then max = k end
    n = n + 1
  end
  if n == 0 then return true end
  return max == n
end

function to_json(val)
  local t=type(val)
  if t=="table" then
    local parts={}
    if is_array(val) then
      for i=1,#val do parts[#parts+1]=to_json(val[i]) end
      return "["..table.concat(parts,",").."]"
    else
      for k,v in pairs(val) do parts[#parts+1]='"'..k..'":'..to_json(v) end
      return "{"..table.concat(parts,",").."}"
    end
  elseif t=="string" then
    val=val:gsub("\\","\\\\"):gsub('"','\\"'):gsub("\n","\\n"):gsub("\r","")
    return '"'..val..'"'
  elseif t=="number" or t=="boolean" then
    return tostring(val)
  else
    return "null"
  end
end

function serialize(val)
  local t=type(val)
  if t=="table" then
    local parts={}
    for k,v in pairs(val) do
      local key=(type(k)=="number") and "" or ('["'..k..'"]=')
      parts[#parts+1]=key..serialize(v)
    end
    return "{"..table.concat(parts,",").."}"
  elseif t=="string" then
    return string.format("%q", val)
  else
    return tostring(val)
  end
end

function exec_read(cmd)
  local h=io.popen(cmd)
  local r=h:read("*a")
  h:close()
  return r and trim(r) or ""
end
function exec_silent(cmd) return os.execute(cmd..">/dev/null 2>&1") end

-- Подробный лог работы панели (в RAM /tmp, без износа флеша). Виден через RPC get_logs.
RIFT_PANEL_LOG = "/tmp/rift_panel.log"
function dlog(msg)
  local f = io.open(RIFT_PANEL_LOG, "a")
  if f then
    f:write(os.date("!%Y-%m-%dT%H:%M:%SZ").."  "..tostring(msg).."\n")
    f:close()
  end
end

function uci_get(c,s,o) return exec_read("uci -q get "..c.."."..s.."."..o) end
function uci_set(c,s,o,v)
  local safe=tostring(v or ""):gsub("'","'\\''")
  exec_silent("uci set "..c.."."..s.."."..o.."='"..safe.."'")
end

local function parse_ver(v)
  local t={}
  for n in tostring(v or ""):gmatch("(%d+)") do t[#t+1]=tonumber(n) end
  while #t<3 do t[#t+1]=0 end
  return t
end
local function cmp_ver(a,b)
  local A=parse_ver(a); local B=parse_ver(b)
  for i=1,3 do
    if A[i]>B[i] then return 1 end
    if A[i]<B[i] then return -1 end
  end
  return 0
end

local function cmd_exists(bin)
  local r = exec_silent("command -v "..bin)
  return (r==0) or (r==true)
end

local HAS_UCLIENT = cmd_exists("uclient-fetch")

local function generate_hwid()
  local mac = exec_read("cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo '00:00:00:00:00:00'")
  local board = exec_read("cat /tmp/sysinfo/board_name 2>/dev/null || echo 'generic'")
  local model = exec_read("cat /tmp/sysinfo/model 2>/dev/null || echo 'router'")
  local cpuinfo = exec_read("grep -E '^(Serial|Hardware|machine|system type)' /proc/cpuinfo 2>/dev/null | head -4")
  local mtd = ""
  local r2 = exec_silent("test -e /dev/mtd2ro")
  local r0 = exec_silent("test -e /dev/mtd0ro")
  if (r2==0) or (r2==true) then
    mtd = exec_read("dd if=/dev/mtd2ro bs=1 count=64 skip=4 2>/dev/null | md5sum 2>/dev/null | cut -c1-32")
  elseif (r0==0) or (r0==true) then
    mtd = exec_read("dd if=/dev/mtd0ro bs=1 count=64 skip=4 2>/dev/null | md5sum 2>/dev/null | cut -c1-32")
  end
  local dmi = exec_read("cat /sys/class/dmi/id/product_serial 2>/dev/null || echo ''")
  local salt = "RiFT-hW1d-s4Lt-v2"
  local raw = salt.."|"..mac.."|"..board.."|"..model.."|"..cpuinfo.."|"..mtd.."|"..dmi
  local hwid
  if cmd_exists("sha256sum") then
    hwid = exec_read("printf %s "..shq(raw).." | sha256sum | cut -c1-16")
  else
    hwid = exec_read("printf %s "..shq(raw).." | md5sum | cut -c1-16")
  end
  return hwid ~= "" and hwid or "unknown"
end

local _cached_hwid = nil
local function get_hwid()
  if _cached_hwid then return _cached_hwid end
  -- Сначала читаем сохранённый hwid: апгрейд не должен менять привязку устройства
  -- (device в Remnawave = hwid+user, новый hwid = превышение лимита у клиента).
  local rf = io.open("/etc/podkop_data/hwid","r")
  if rf then
    local v = rf:read("*l"); rf:close()
    if v and v ~= "" then _cached_hwid = v; return v end
  end
  _cached_hwid = generate_hwid()
  -- update file for cron script consistency
  local f = io.open("/etc/podkop_data/hwid","w")
  if f then f:write(_cached_hwid); f:close() end
  return _cached_hwid
end

local function get_device_model()
  local f = io.open("/tmp/sysinfo/model","r")
  if f then local m=trim(f:read("*a")); f:close(); return m end
  return "OpenWrt Router"
end

local function get_os_version()
  local v = exec_read("cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d\"'\" -f2")
  if v == "" then v = exec_read("uname -r") end
  return v
end

local function fetch_to_file(url, out, err, extra_headers)
  exec_silent("rm -f "..out.." "..err)
  local ua = "v2rayNG/1.8.19"
  local hdr = ""
  if extra_headers then
    for _,h in ipairs(extra_headers) do
      hdr = hdr .. " --header=" .. shq(h)
    end
  end
  local cmd
  if HAS_UCLIENT then
    cmd = "uclient-fetch -q -O "..out.." --header="..shq("User-Agent: "..ua)..hdr.." "..shq(url).." 2>"..err
  else
    cmd = "wget -q -T 25 -U "..shq(ua)..hdr.." -O "..out.." "..shq(url).." 2>"..err
  end
  local rc = os.execute(cmd)
  return (rc==0) or (rc==true)
end

-- Fetch and capture response headers (for subscription info)
local function fetch_with_headers(url, out, hdr_file, extra_headers)
  exec_silent("rm -f "..out.." "..hdr_file)
  local ua = "v2rayNG/1.8.19"
  local hdr = ""
  if extra_headers then
    for _,h in ipairs(extra_headers) do hdr = hdr .. " --header=" .. shq(h) end
  end
  -- wget -S writes headers to stderr
  local cmd = "wget -q -S -T 25 -U "..shq(ua)..hdr.." -O "..out.." "..shq(url).." 2>"..hdr_file
  local rc = os.execute(cmd)
  return (rc==0) or (rc==true)
end

local function smart_fetch(url, out, err)
  local hwid = get_hwid()
  local model = get_device_model()
  local headers = {
    "x-hwid: " .. hwid,
    "x-device-model: " .. model
  }
  local ok = fetch_to_file(url, out, err, headers)
  return ok
end

local function smart_fetch_with_headers(url, out, hdr_file)
  local hwid = get_hwid()
  local model = get_device_model()
  local headers = {
    "x-hwid: " .. hwid,
    "x-device-model: " .. model
  }
  local ok = fetch_with_headers(url, out, hdr_file, headers)
  return ok
end

-- Подписка для роутера в JSON: UA с префиксом "Happ" -> Remnawave отдаёт XRAY_JSON
-- (единственный формат со всеми транспортами, включая HY2 и XHTTP). HWID-заголовки —
-- полный набор, иначе Remnawave вернёт заглушки HWIDNotSupported вместо узлов.
local function fetch_subscription_json(url, out, err)
  exec_silent("rm -f "..out.." "..err)
  local ua = "Happ/4.7-RIFT"
  local hwid = get_hwid()
  local model = get_device_model()
  local osver = get_os_version()
  local hdr =
      " --header="..shq("x-hwid: "..hwid)..
      " --header="..shq("x-device-os: OpenWRT")..
      " --header="..shq("x-ver-os: "..osver)..
      " --header="..shq("x-device-model: "..model)
  local cmd
  if HAS_UCLIENT then
    cmd = "uclient-fetch -q -O "..out.." --header="..shq("User-Agent: "..ua)..hdr.." "..shq(url).." 2>"..err
  else
    cmd = "wget -q -T 25 -U "..shq(ua)..hdr.." -O "..out.." "..shq(url).." 2>"..err
  end
  dlog("fetch_sub ua="..ua.." hwid="..hwid.." os="..osver.." model="..model.." url="..url)
  local rc = os.execute(cmd)
  local okrc = (rc==0) or (rc==true)
  dlog("fetch_sub rc="..tostring(rc).." ok="..tostring(okrc))
  return okrc
end

local function get_singbox_version()
  return exec_read("/usr/bin/sing-box version 2>/dev/null | head -n 1")
end

local function singbox_supports_xhttp()
  local cfg = [[{
  "log": { "disabled": true },
  "inbounds": [],
  "outbounds": [
    {
      "type": "vless",
      "tag": "test-out",
      "server": "example.com",
      "server_port": 443,
      "uuid": "11111111-1111-1111-1111-111111111111",
      "tls": {
        "enabled": true,
        "server_name": "example.com",
        "insecure": true,
        "alpn": ["h2", "http/1.1"]
      },
      "transport": {
        "type": "xhttp",
        "path": "/",
        "mode": "auto",
        "host": "example.com",
        "x_padding_bytes": "100-1000"
      }
    }
  ]
}]]
  local tmp = "/tmp/rift_xhttp_check.json"
  local f = io.open(tmp, "w")
  if not f then return false, "Не удалось создать временный конфиг" end
  f:write(cfg)
  f:close()
  local rc = os.execute("/usr/bin/sing-box check -c "..tmp.." >/tmp/rift_xhttp_check.log 2>&1")
  os.remove(tmp)
  local logs = exec_read("tail -n 20 /tmp/rift_xhttp_check.log 2>/dev/null")
  os.remove("/tmp/rift_xhttp_check.log")
  return (rc==0) or (rc==true), logs
end

local function install_extended_singbox()
  local tmp = "/tmp/rift_singbox_upgrade.sh"
  local err = "/tmp/rift_singbox_upgrade.err"
  local logf = "/tmp/rift_singbox_upgrade.log"
  local ok = fetch_to_file(EXT_SINGBOX_INSTALL_URL, tmp, err)
  if not ok then
    return false, "Не удалось скачать установщик sing-box-extended"
  end
  exec_silent("chmod +x "..tmp)
  local rc = os.execute("sh "..tmp.." >"..logf.." 2>&1")
  local logs = exec_read("tail -n 40 "..logf.." 2>/dev/null")
  os.remove(tmp)
  os.remove(err)
  os.remove(logf)
  return (rc==0) or (rc==true), logs
end

local function ensure_singbox_xhttp()
  local before = get_singbox_version()
  local ok, details = singbox_supports_xhttp()
  if ok then
    return true, {
      changed = false,
      before = before,
      after = before,
      msg = "Current sing-box already supports XHTTP"
    }
  end

  local upgraded, install_logs = install_extended_singbox()
  if not upgraded then
    return false, {
      changed = false,
      before = before,
      after = get_singbox_version(),
      msg = "Failed to install sing-box-extended",
      logs = install_logs ~= "" and install_logs or details
    }
  end

  local after = get_singbox_version()
  local supported_after, check_logs = singbox_supports_xhttp()
  if supported_after then
    return true, {
      changed = true,
      before = before,
      after = after,
      msg = "Installed sing-box-extended with XHTTP support",
      logs = install_logs
    }
  end

  return false, {
    changed = true,
    before = before,
    after = after,
    msg = "sing-box was upgraded, but XHTTP validation still fails",
    logs = check_logs ~= "" and check_logs or install_logs
  }
end

-- Extract subscription info from saved headers
local function extract_sub_info(hdr_file)
  local info = {expire="", title="", interval="", traffic_used="", traffic_total="", traffic_label=""}
  local raw = exec_read("cat "..hdr_file.." 2>/dev/null")
  raw = raw:gsub("\r", "")  -- strip CR from curl output
  local headers = {}
  for line in raw:gmatch("[^\n]+") do
    local k, v = line:match("^([%w%-]+):%s*(.*)$")
    if k and v then headers[k:lower()] = trim(v) end
  end
  -- profile-title (base64 encoded)
  local pt = (headers["profile-title"] or ""):match("^base64:([A-Za-z0-9%+/=]+)")
  if pt then
    local decoded = exec_read("printf %s "..shq(pt).." | base64 -d 2>/dev/null")
    info.title = decoded or ""
    -- extract expire like "29D,22H" or time info
    local expire_match = decoded:match("(%d+[DdДд][%s,]*%d*[HhЧч]*)")
    if expire_match then info.expire = expire_match end
  end
  -- subscription-userinfo header
  local sui = headers["subscription-userinfo"] or ""
  if sui then
    local exp_ts = sui:match("expire=(%d+)")
    if exp_ts and tonumber(exp_ts) and tonumber(exp_ts) > 0 then
      info.expire_ts = tonumber(exp_ts)
      local diff = tonumber(exp_ts) - os.time()
      if diff > 0 then
        local days = math.floor(diff/86400)
        local hours = math.floor((diff%86400)/3600)
        info.expire = days.."д "..hours.."ч"
      else
        info.expire = "Expired"
      end
    elseif exp_ts == "0" then
      info.expire = "No expiry"
    end
    local ul = tonumber(sui:match("upload=(%d+)") or "0") or 0
    local dl = sui:match("download=(%d+)")
    local total = sui:match("total=(%d+)")
    if dl then
      local used_gb = math.floor(((tonumber(dl) or 0) + ul)/1073741824*100)/100
      info.traffic_used = tostring(used_gb)
      if total then
        local total_num = tonumber(total) or 0
        if total_num > 0 then
          local total_gb = math.floor(total_num/1073741824*100)/100
          info.traffic_total = tostring(total_gb)
          info.traffic_label = info.traffic_used.." / "..info.traffic_total.." GB"
        else
          info.traffic_total = "unlimited"
          info.traffic_label = info.traffic_used.." / unlimited"
        end
      else
        info.traffic_label = info.traffic_used.." GB"
      end
    end
  end
  local pi = headers["profile-update-interval"]
  if pi then info.interval = pi end
  local web = headers["profile-web-page-url"]
  if web then info.web_page_url = web end
  return info
end

local qs=os.getenv("QUERY_STRING") or ""
local params={}
for k,v in string.gmatch(qs,"([^&=]+)=([^&=]*)") do
  params[k]=v:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end)
end
local method=params.method

print("Content-type: application/json; charset=utf-8\n")

local REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"
local EXT_SINGBOX_INSTALL_URL="https://raw.githubusercontent.com/EikeiDev/OpenWRT-sing-box-extended/refs/heads/main/install.sh"
local DNS_PROTECT_TYPE="doh"
local DNS_PROTECT_SERVER="8.8.8.8"
local DNS_PROTECT_BOOTSTRAP="9.9.9.9"
local DNS_FALLBACK_TYPE="udp"
local DNS_FALLBACK_SERVER="8.8.8.8"
local DNS_FALLBACK_BOOTSTRAP="77.88.8.1"

local function url_decode(s)
  if not s then return "" end
  local out = s:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end)
  return out
end

local function url_get_param(url, param)
  local val = url:match("[?&]" .. param .. "=([^&#]*)")
  if val then return url_decode(val) end
  return ""
end

local function normalize_proxy_stream(text)
  local out = tostring(text or "")
  out = out:gsub("\r", "\n")
  out = out:gsub("vmess://", "__RIFT_VMESS__")
  out = out:gsub("vless://", "__RIFT_VLESS__")
  out = out:gsub("trojan://", "__RIFT_TROJAN__")
  out = out:gsub("hysteria2://", "__RIFT_HYSTERIA2__")
  out = out:gsub("hy2://", "__RIFT_HY2__")
  out = out:gsub("tuic://", "__RIFT_TUIC__")
  out = out:gsub("ss://", "\nss://")
  out = out:gsub("__RIFT_VMESS__", "\nvmess://")
  out = out:gsub("__RIFT_VLESS__", "\nvless://")
  out = out:gsub("__RIFT_TROJAN__", "\ntrojan://")
  out = out:gsub("__RIFT_HYSTERIA2__", "\nhysteria2://")
  out = out:gsub("__RIFT_HY2__", "\nhy2://")
  out = out:gsub("__RIFT_TUIC__", "\ntuic://")
  out = out:gsub("^\n+", "")
  return out
end

local function parse_links_from_text(text)
  local out={}
  text = normalize_proxy_stream(text)
  if not text or text == "" then return out end
  for line in text:gmatch("[^\n\r]+") do
    line = trim(line)
    if line:match("^[a-z]+://") then
      out[#out+1] = line
    end
  end
  return out
end

local function put_if(tbl, key, value)
  if value ~= nil and value ~= "" then
    tbl[key] = value
  end
end

-- Decorative separator detector: узел является "вертикальным разделителем"
-- если его NAME состоит только из: U+3164 (ㅤ Hangul Filler),
-- U+2800 (⠀ Braille blank), U+00A0 (NBSP), обычных пробелов, табов.
-- Такие записи в подписке Remnawave используются как визуальные разделители
-- кластеров. Их хост = фейковый (например c3:443 или "Кластер 3:443").
-- Они НЕ должны быть кликабельными — рендерим как тонкую линию.
local function is_decorative_separator(name)
  if not name or name == "" then return false end
  -- Каждый ㅤ (U+3164) в UTF-8 = 3 байта E3 85 A4
  -- Каждый ⠀ (U+2800) = 3 байта E2 A0 80
  -- NBSP (U+00A0) = 2 байта C2 A0
  -- Strip известных whitespace-нашествий и проверяем что остался пустой стринг
  local stripped = name
    :gsub("\227\133\164", "")   -- U+3164 (Lua 5.1: только \ddd, не \xHH)
    :gsub("\226\160\128", "")   -- U+2800 Braille blank
    :gsub("\194\160", "")        -- NBSP
    :gsub("%s", "")              -- ASCII whitespace (space, tab, etc)
  return stripped == ""
end

local function link_to_node(line)
  local proto=(line:match("^(%w+)://") or "LINK"):upper()

  -- Extract name: everything after the FIRST # (greedy to end)
  local ne=line:match("#(.+)$")
  local name="Server"
  if ne then name=url_decode(ne) end

  -- Early-out: если name — декоративный разделитель, возвращаем узел-маркер
  -- который UI рендерит как <hr>. Без хоста, без транспорта, без кнопки.
  if is_decorative_separator(name) then
    return {
      name = name,
      is_separator = true,
      full_url = line
    }
  end

  local host=line:match("@(.-):") or line:match("://([^/:#%?]+)") or "unknown"

  local transport = url_get_param(line, "type")
  if transport == "" then transport = "tcp" end
  transport = transport:lower()

  local security = url_get_param(line, "security")
  local ti = proto
  if security == "reality" then ti = "Reality" end

  local transport_label = transport:upper()
  if transport == "grpc" then transport_label = "gRPC"
  elseif transport == "xhttp" or transport == "splithttp" then
    transport_label = "XHTTP"
  elseif transport == "ws" then transport_label = "WS"
  end

  local service_name = url_get_param(line, "serviceName")
  local path = url_get_param(line, "path")
  if path == "" then path = url_get_param(line, "bx") end
  if path == "" then path = url_get_param(line, "spx") end
  local mode = url_get_param(line, "mode")
  local flow = url_get_param(line, "flow")
  local extra = url_get_param(line, "extra")

  local node = {
    name = name,
    host = host,
    type = ti,
    transport = transport,
    full_url = line
  }
  put_if(node, "transport_label", transport_label ~= transport:upper() and transport_label or "")
  put_if(node, "security", security)
  put_if(node, "service_name", service_name)
  put_if(node, "path", path)
  put_if(node, "mode", mode)
  put_if(node, "flow", flow)
  put_if(node, "extra", extra)
  return node
end

local SKIP_NAME_PLAIN = string.char(0xD0,0xBE,0xD0,0xB1,0xD1,0x85,0xD0,0xBE,0xD0,0xB4,0x20,0xD0,0xB1,0xD1,0x81)
local PHONE_ICON = string.char(0xF0,0x9F,0x93,0xB1)

-- Filter and dedup
local function should_skip(name)
  if not name then return false end
  local lower = tostring(name):lower():gsub("%s+", " ")
  -- Filter phone-only entries
  if lower:find(SKIP_NAME_PLAIN, 1, true) then return true end
  if tostring(name):find(PHONE_ICON, 1, true) then return true end
  return false
end

local function get_url_key(url)
  -- strip fragment for dedup
  return (url:match("^([^#]+)") or url)
end

local function parse_nodes(text)
  local nodes={}
  local seen={}
  local links=parse_links_from_text(text or "")
  for _,u in ipairs(links) do
    local node = link_to_node(u)
    local key = get_url_key(u)
    if not seen[key] and not should_skip(node.name) then
      seen[key] = true
      nodes[#nodes+1] = node
    end
  end
  return nodes
end

-- =====================================================================
-- JSON-пайплайн v4.7: XRAY_JSON (формат Happ) -> sing-box outbound.
-- Парсер и конвертер протестированы оффлайн на реальной подписке +
-- живой трафик через sing-box-extended (TCP/gRPC/XHTTP/HY2). См. README.
-- =====================================================================

-- Мини JSON-декодер (без внешних зависимостей). Поддержка object/array/string/
-- number/bool/null, \uXXXX (вкл. суррогатные пары) и сырых UTF-8 байт в строках.
local function json_decode(s)
  if not s or s == "" then return nil, "empty" end
  local pos, len = 1, #s
  local decode_value
  local function err(m) error("json:"..m.."@"..pos) end
  local function skip_ws()
    while pos <= len do
      local c = s:byte(pos)
      if c==32 or c==9 or c==10 or c==13 then pos=pos+1 else break end
    end
  end
  local function decode_string()
    pos = pos + 1
    local buf = {}
    while pos <= len do
      local c = s:byte(pos)
      if c == 34 then pos = pos + 1; return table.concat(buf)
      elseif c == 92 then
        local n = s:byte(pos+1)
        if n == 117 then
          local cp = tonumber(s:sub(pos+2,pos+5),16) or 0
          pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos,pos+1)=="\\u" then
            local lo = tonumber(s:sub(pos+2,pos+5),16) or 0
            if lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp-0xD800)*0x400 + (lo-0xDC00); pos = pos + 6
            end
          end
          if cp < 0x80 then buf[#buf+1]=string.char(cp)
          elseif cp < 0x800 then buf[#buf+1]=string.char(0xC0+math.floor(cp/0x40),0x80+(cp%0x40))
          elseif cp < 0x10000 then buf[#buf+1]=string.char(0xE0+math.floor(cp/0x1000),0x80+(math.floor(cp/0x40)%0x40),0x80+(cp%0x40))
          else buf[#buf+1]=string.char(0xF0+math.floor(cp/0x40000),0x80+(math.floor(cp/0x1000)%0x40),0x80+(math.floor(cp/0x40)%0x40),0x80+(cp%0x40)) end
        else
          local map = {[34]='"',[92]='\\',[47]='/',[98]='\b',[102]='\f',[110]='\n',[114]='\r',[116]='\t'}
          buf[#buf+1] = map[n] or string.char(n or 63); pos = pos + 2
        end
      else buf[#buf+1] = string.char(c); pos = pos + 1 end
    end
    err("unterminated")
  end
  local function decode_number()
    local start = pos
    while pos <= len do
      local c = s:byte(pos)
      if (c>=48 and c<=57) or c==45 or c==43 or c==46 or c==101 or c==69 then pos=pos+1 else break end
    end
    return tonumber(s:sub(start, pos-1))
  end
  local function decode_object()
    pos = pos + 1; local obj = {}; skip_ws()
    if s:byte(pos) == 125 then pos=pos+1; return obj end
    while true do
      skip_ws()
      if s:byte(pos) ~= 34 then err("key") end
      local key = decode_string(); skip_ws()
      if s:byte(pos) ~= 58 then err("colon") end
      pos = pos + 1; obj[key] = decode_value(); skip_ws()
      local c = s:byte(pos)
      if c == 44 then pos=pos+1 elseif c == 125 then pos=pos+1; return obj else err("obj") end
    end
  end
  local function decode_array()
    pos = pos + 1; local arr = {}; skip_ws()
    if s:byte(pos) == 93 then pos=pos+1; return arr end
    while true do
      arr[#arr+1] = decode_value(); skip_ws()
      local c = s:byte(pos)
      if c == 44 then pos=pos+1 elseif c == 93 then pos=pos+1; return arr else err("arr") end
    end
  end
  decode_value = function()
    skip_ws()
    local c = s:byte(pos)
    if c == 123 then return decode_object()
    elseif c == 91 then return decode_array()
    elseif c == 34 then return decode_string()
    elseif c == 116 then pos=pos+4; return true
    elseif c == 102 then pos=pos+5; return false
    elseif c == 110 then pos=pos+4; return nil
    else return decode_number() end
  end
  local ok, result = pcall(decode_value)
  if not ok then return nil, result end
  return result
end

-- xray vless outbound -> базовая часть sing-box vless outbound
local function ob_vless_common(o)
  local v = o.settings.vnext[1]
  local u = v.users[1]
  local ss = o.streamSettings
  local rs = ss.realitySettings or {}
  local fp = rs.fingerprint
  if not fp or fp == "" then fp = "qq" end
  local ob = {
    type = "vless",
    server = v.address,
    server_port = v.port,
    uuid = u.id,
    tls = {
      enabled = true,
      server_name = rs.serverName or "",
      utls = { enabled = true, fingerprint = fp },
      reality = { enabled = true, public_key = rs.publicKey or "", short_id = rs.shortId or "" },
    },
  }
  return ob, ss, u
end

-- xray outbound -> sing-box outbound (таблица). nil если протокол не поддержан.
local function convert_outbound(o)
  local p = o.protocol
  local ss = o.streamSettings or {}
  local net = ss.network
  if p == "vless" and net == "tcp" then
    local ob, _, u = ob_vless_common(o)
    local flow = u.flow or ""
    if flow ~= "" then ob.flow = flow end
    return ob
  elseif p == "vless" and net == "grpc" then
    local ob = ob_vless_common(o)
    local g = ss.grpcSettings or {}
    ob.transport = { type="grpc", service_name = g.serviceName or "" }
    return ob
  elseif p == "vless" and net == "xhttp" then
    local ob = ob_vless_common(o)
    local x = ss.xhttpSettings or {}
    local pad = x.xPaddingBytes
    if not pad or pad == "" then pad = "100-1000" end
    ob.transport = {
      type = "xhttp",
      path = (x.path and x.path ~= "" and x.path) or "/",
      mode = (x.mode and x.mode ~= "" and x.mode) or "auto",
      x_padding_bytes = tostring(pad),
    }
    if x.host and x.host ~= "" then ob.transport.host = x.host end
    -- ОБЯЗАТЕЛЬНО: xhttp over reality в sing-box-extended требует явный ALPN h2,
    -- иначе туннель встаёт, но данные не идут (проверено на живом трафике).
    ob.tls.alpn = { "h2" }
    return ob
  elseif p == "hysteria" then
    local s = o.settings or {}
    local hs = ss.hysteriaSettings or {}
    local ts = ss.tlsSettings or {}
    return {
      type = "hysteria2",
      server = s.address,
      server_port = s.port,
      password = hs.auth or "",
      tls = { enabled = true, server_name = ts.serverName or "", alpn = ts.alpn or {"h3"} },
    }
  end
  return nil
end

local function transport_of(sb)
  if sb.type == "hysteria2" then return "hysteria2", "HY2" end
  local tt = sb.transport and sb.transport.type
  if tt == "grpc" then return "grpc", "gRPC" end
  if tt == "xhttp" then return "xhttp", "XHTTP" end
  return "tcp", "TCP"
end

-- XRAY_JSON массив (от Happ) -> список узлов панели с готовым sing-box outbound.
-- Разделители (Hangul Filler / Braille / фейк-хосты) помечаются is_separator.
local function build_nodes_from_xray(arr)
  local nodes, seen = {}, {}
  local stats = { tcp=0, grpc=0, xhttp=0, hysteria2=0, sep=0, skip=0 }
  if type(arr) ~= "table" then return nodes, stats end
  for _,item in ipairs(arr) do
    local name = item.remarks or ""
    if is_decorative_separator(name) then
      stats.sep = stats.sep + 1
      nodes[#nodes+1] = { name = name, is_separator = true }
    elseif should_skip(name) then
      stats.skip = stats.skip + 1
    else
      local proxy
      for _,ob in ipairs(item.outbounds or {}) do
        if ob.protocol == "vless" or ob.protocol == "hysteria" then proxy = ob; break end
      end
      if proxy then
        local sb = convert_outbound(proxy)
        -- пропускаем мусорные/фейковые узлы без reality-ключа (это тоже разделители)
        local bad = sb and sb.tls and sb.tls.reality and sb.tls.reality.enabled
                    and (not sb.tls.reality.public_key or sb.tls.reality.public_key == "")
        if sb and not bad then
          sb.tag = "proxy"
          local tr, trl = transport_of(sb)
          local key = (sb.server or "")..":"..tostring(sb.server_port or "")..":"..tr
          if not seen[key] then
            seen[key] = true
            stats[tr] = (stats[tr] or 0) + 1
            nodes[#nodes+1] = {
              name = name,
              host = sb.server,
              port = sb.server_port,
              type = (sb.type == "hysteria2") and "HY2" or "Reality",
              transport = tr,
              transport_label = trl,
              security = (sb.tls and sb.tls.reality) and "reality" or "tls",
              flow = sb.flow,
              key = key,
              sb = sb,
            }
          end
        end
      end
    end
  end
  return nodes, stats
end

local function json_unescape(s)
  s = tostring(s or "")
  s = s:gsub("\\/", "/")
  s = s:gsub('\\"', '"')
  s = s:gsub("\\\\", "\\")
  return s
end

local function extract_extra_string(extra, key)
  extra = trim(extra or "")
  if extra == "" or extra == "null" then return "" end
  local val = extra:match('"'..key..'"%s*:%s*"(.-)"')
  if not val then return "" end
  return json_unescape(val)
end

local function extract_extra_number(extra, key)
  extra = trim(extra or "")
  if extra == "" or extra == "null" then return "" end
  return extra:match('"'..key..'"%s*:%s*(-?%d+)') or ""
end

local function extract_extra_boolean(extra, key)
  extra = trim(extra or "")
  if extra == "" or extra == "null" then return nil end
  local val = extra:match('"'..key..'"%s*:%s*(true|false)')
  if val == "true" then return true end
  if val == "false" then return false end
  return nil
end

local function split_csv(value)
  local out = {}
  for item in tostring(value or ""):gmatch("[^,]+") do
    item = trim(item)
    if item ~= "" then out[#out+1] = item end
  end
  return out
end

local function parse_vless_link(url)
  local clean = url:gsub("#.*$", "")
  local uuid = clean:match("^vless://([^@]+)@") or ""
  local host = clean:match("@([^:/#%?]+)") or clean:match("://([^/:#%?]+)") or ""
  local port = clean:match("@[^:/#%?]+:(%d+)") or clean:match("://[^/:#%?]+:(%d+)") or "443"
  return {
    uuid = url_decode(uuid),
    host = host,
    port = tonumber(port) or 443
  }
end

local function build_tls_settings_for_vless(url, transport_type)
  local security = url_get_param(url, "security")
  if security ~= "tls" and security ~= "reality" then return nil end

  local tls = { enabled = true }
  local sni = url_get_param(url, "sni")
  if sni ~= "" then tls.server_name = sni end

  local alpn = split_csv(url_get_param(url, "alpn"))
  if #alpn == 0 and transport_type == "xhttp" then
    alpn = { "h2", "http/1.1" }
  end
  if #alpn > 0 then tls.alpn = alpn end

  local fingerprint = url_get_param(url, "fp")
  if fingerprint ~= "" then
    tls.utls = {
      enabled = true,
      fingerprint = fingerprint
    }
  end

  if security == "reality" then
    local public_key = url_get_param(url, "pbk")
    if public_key ~= "" then
      tls.reality = {
        enabled = true,
        public_key = public_key,
        short_id = url_get_param(url, "sid")
      }
    end
  else
    local insecure = url_get_param(url, "allowInsecure")
    if insecure == "" then insecure = url_get_param(url, "insecure") end
    if insecure == "1" or insecure == "true" then tls.insecure = true end
  end

  return tls
end

local function build_xhttp_common_parts(url)
  local parsed = parse_vless_link(url)
  if parsed.uuid == "" or parsed.host == "" then
    return nil, nil, "Failed to parse XHTTP link"
  end

  local extra = url_get_param(url, "extra")
  local extra_path = extract_extra_string(extra, "path")
  local extra_host = extract_extra_string(extra, "host")
  local extra_mode = extract_extra_string(extra, "mode")

  local path = url_get_param(url, "path")
  if path == "" then path = url_get_param(url, "bx") end
  if path == "" then path = url_get_param(url, "spx") end
  if path == "" then path = extra_path end
  if path == "" then path = "/" end

  local host_header = url_get_param(url, "host")
  if host_header == "" then host_header = extra_host end
  if host_header == "" then host_header = url_get_param(url, "sni") end
  if host_header == "" then host_header = parsed.host end

  local mode = url_get_param(url, "mode")
  if mode == "" then mode = extra_mode end
  if mode == "" then mode = "auto" end

  local outbound = {
    type = "vless",
    server = parsed.host,
    server_port = parsed.port,
    uuid = parsed.uuid
  }

  local flow = url_get_param(url, "flow")
  if flow ~= "" then outbound.flow = flow end

  local packet_encoding = url_get_param(url, "packetEncoding")
  if packet_encoding ~= "" then outbound.packet_encoding = packet_encoding end

  return outbound, {
    extra = extra,
    path = path,
    host_header = host_header,
    mode = mode
  }
end

local function build_xhttp_raw_outbound(url)
  local outbound, ctx, err = build_xhttp_common_parts(url)
  if not outbound then return nil, err end

  outbound.tls = build_tls_settings_for_vless(url, "xhttp")

  local transport = {
    type = "xhttp",
    path = ctx.path,
    mode = ctx.mode,
    x_padding_bytes = url_get_param(url, "x_padding_bytes")
  }
  if transport.x_padding_bytes == "" then transport.x_padding_bytes = "100-1000" end
  if ctx.host_header ~= "" then transport.host = ctx.host_header end

  local extra = ctx.extra
  if extra ~= "" and extra ~= "null" then
    local x_padding_bytes = extract_extra_string(extra, "xPaddingBytes")
    if x_padding_bytes == "" then x_padding_bytes = extract_extra_number(extra, "xPaddingBytes") end
    if x_padding_bytes ~= "" then transport.x_padding_bytes = tostring(x_padding_bytes) end

    local no_grpc_header = extract_extra_boolean(extra, "noGRPCHeader")
    if no_grpc_header ~= nil then transport.no_grpc_header = no_grpc_header end

    local no_sse_header = extract_extra_boolean(extra, "noSSEHeader")
    if no_sse_header ~= nil then transport.no_sse_header = no_sse_header end

    local sc_max_each_post_bytes = extract_extra_number(extra, "scMaxEachPostBytes")
    if sc_max_each_post_bytes ~= "" then transport.sc_max_each_post_bytes = tonumber(sc_max_each_post_bytes) end

    local sc_min_posts_interval_ms = extract_extra_number(extra, "scMinPostsIntervalMs")
    if sc_min_posts_interval_ms ~= "" then transport.sc_min_posts_interval_ms = tonumber(sc_min_posts_interval_ms) end

    local sc_stream_up_server_secs = extract_extra_string(extra, "scStreamUpServerSecs")
    if sc_stream_up_server_secs == "" then sc_stream_up_server_secs = extract_extra_number(extra, "scStreamUpServerSecs") end
    if sc_stream_up_server_secs ~= "" then transport.sc_stream_up_server_secs = tostring(sc_stream_up_server_secs) end

    local xmux_blob = extra:match('"xmux"%s*:%s*(%b{})')
    if xmux_blob and xmux_blob ~= "" then
      local xmux = {}
      local function xmux_set_string(src_key, dst_key)
        local val = extract_extra_string(xmux_blob, src_key)
        if val == "" then val = extract_extra_number(xmux_blob, src_key) end
        if val ~= "" then xmux[dst_key] = tostring(val) end
      end
      local function xmux_set_number(src_key, dst_key)
        local val = extract_extra_number(xmux_blob, src_key)
        if val ~= "" then xmux[dst_key] = tonumber(val) end
      end
      xmux_set_string("maxConcurrency", "max_concurrency")
      xmux_set_number("maxConnections", "max_connections")
      xmux_set_number("cMaxReuseTimes", "c_max_reuse_times")
      xmux_set_string("hMaxRequestTimes", "h_max_request_times")
      xmux_set_string("hMaxReusableSecs", "h_max_reusable_secs")
      xmux_set_number("hKeepAlivePeriod", "h_keep_alive_period")
      if next(xmux) then transport.xmux = xmux end
    end
  end

  outbound.transport = transport
  return to_json(outbound), "XHTTP enabled via native JSON outbound"
end

local function build_xhttp_http_compat_outbound(url)
  local parsed = parse_vless_link(url)
  if parsed.uuid == "" or parsed.host == "" then
    return nil, "Failed to parse XHTTP link"
  end

  local extra = url_get_param(url, "extra")
  local extra_path = extract_extra_string(extra, "path")
  local extra_host = extract_extra_string(extra, "host")
  local extra_mode = extract_extra_string(extra, "mode")

  local outbound = {
    type = "vless",
    server = parsed.host,
    server_port = parsed.port,
    uuid = parsed.uuid
  }

  local flow = url_get_param(url, "flow")
  if flow ~= "" then outbound.flow = flow end

  local packet_encoding = url_get_param(url, "packetEncoding")
  if packet_encoding ~= "" then outbound.packet_encoding = packet_encoding end

  outbound.tls = build_tls_settings_for_vless(url, "http")

  local path = url_get_param(url, "path")
  if path == "" then path = url_get_param(url, "bx") end
  if path == "" then path = url_get_param(url, "spx") end
  if path == "" then path = extra_path end
  if path == "" then path = "/" end

  local host_header = url_get_param(url, "host")
  if host_header == "" then host_header = extra_host end
  if host_header == "" then host_header = url_get_param(url, "sni") end
  if host_header == "" then host_header = parsed.host end

  outbound.transport = {
    type = "http",
    path = path
  }
  if host_header ~= "" then
    outbound.transport.host = { host_header }
  end

  local mode = url_get_param(url, "mode")
  if mode == "" then mode = extra_mode end

  local warning = "XHTTP enabled via compatible JSON outbound (transport=http)"
  if (extra ~= "" and extra ~= "null") or (mode ~= "" and mode ~= "auto") then
    warning = warning .. "; advanced XHTTP options are not fully supported by sing-box"
  end

  return to_json(outbound), warning
end

local function build_xhttp_outbounds(url)
  local raw_json, raw_warning = build_xhttp_raw_outbound(url)
  if not raw_json then return nil, nil, raw_warning end
  local compat_json, compat_warning = build_xhttp_http_compat_outbound(url)
  if not compat_json then return nil, nil, compat_warning end
  return raw_json, compat_json, raw_warning
end

local function build_url_connection_key(url)
  url = trim(url or "")
  if url == "" then return "" end
  local parsed = parse_vless_link(url)
  local transport = url_get_param(url, "type")
  if transport == "" then transport = "tcp" end
  transport = transport:lower()
  local extra = url_get_param(url, "extra")
  local host_header = url_get_param(url, "host")
  if host_header == "" then host_header = extract_extra_string(extra, "host") end
  if host_header == "" then host_header = url_get_param(url, "sni") end
  local path = url_get_param(url, "path")
  if path == "" then path = url_get_param(url, "bx") end
  if path == "" then path = url_get_param(url, "spx") end
  if path == "" then path = extract_extra_string(extra, "path") end
  local mode = url_get_param(url, "mode")
  if mode == "" then mode = extract_extra_string(extra, "mode") end
  return table.concat({
    "vless",
    parsed.uuid:lower(),
    parsed.host:lower(),
    tostring(parsed.port or ""),
    transport,
    url_get_param(url, "security"):lower(),
    host_header:lower(),
    path,
    url_get_param(url, "serviceName"),
    mode,
    url_get_param(url, "flow"),
    url_get_param(url, "sni"),
    url_get_param(url, "pbk"),
    url_get_param(url, "sid")
  }, "|")
end

local function json_extract_string(blob, key)
  local val = tostring(blob or ""):match('"'..key..'"%s*:%s*"(.-)"')
  return json_unescape(val or "")
end

local function json_extract_number(blob, key)
  return tostring(blob or ""):match('"'..key..'"%s*:%s*(%d+)') or ""
end

local function build_outbound_connection_key(blob)
  blob = tostring(blob or "")
  if blob == "" then return "" end
  local transport_blob = blob:match('"transport"%s*:%s*(%b{})') or ""
  local tls_blob = blob:match('"tls"%s*:%s*(%b{})') or ""
  local reality_blob = tls_blob:match('"reality"%s*:%s*(%b{})') or ""
  local transport = json_extract_string(transport_blob, "type"):lower()
  if transport == "" then transport = "tcp" end
  if transport == "http" then transport = "xhttp" end
  local host_header = json_extract_string(transport_blob, "host")
  if host_header == "" then
    host_header = transport_blob:match('"host"%s*:%s*%[%s*"(.-)"')
    host_header = json_unescape(host_header or "")
  end
  return table.concat({
    "vless",
    json_extract_string(blob, "uuid"):lower(),
    json_extract_string(blob, "server"):lower(),
    json_extract_number(blob, "server_port"),
    transport,
    reality_blob ~= "" and "reality" or (tls_blob ~= "" and "tls" or ""),
    host_header:lower(),
    json_extract_string(transport_blob, "path"),
    json_extract_string(transport_blob, "service_name"),
    json_extract_string(transport_blob, "mode"),
    json_extract_string(blob, "flow"),
    json_extract_string(tls_blob, "server_name"),
    json_extract_string(reality_blob, "public_key"),
    json_extract_string(reality_blob, "short_id")
  }, "|")
end

local function detect_active_url_from_outbound(outbound_json, nodes)
  local target_key = build_outbound_connection_key(outbound_json)
  if target_key == "" then return "" end
  for _, node in ipairs(nodes or {}) do
    if build_url_connection_key(node.full_url or "") == target_key then
      return node.full_url or ""
    end
  end
  return ""
end

local function restart_podkop_service()
  local rc = os.execute("/etc/init.d/podkop restart >/tmp/rift_apply.log 2>&1")
  return (rc==0) or (rc==true)
end

local function b64_urlsafefix(s)
  s = (s or ""):gsub("%s+","")
  s = s:gsub("-", "+"):gsub("_", "/")
  while (#s % 4) ~= 0 do s = s .. "=" end
  return s
end

local function try_decode_base64(raw)
  if not raw then return "" end
  local t = raw:gsub("%s+","")
  if #t < 16 then return "" end
  if not t:match("^[%w%+/%=_%-%s]+$") then return "" end
  t = b64_urlsafefix(t)
  local in_file = "/tmp/rift_b64_in.txt"
  local out_file = "/tmp/rift_b64_out.txt"
  local f = io.open(in_file, "w")
  if not f then return "" end
  f:write(t)
  f:close()
  os.execute("base64 -d "..in_file.." >"..out_file.." 2>/dev/null")
  local dec = exec_read("cat "..out_file.." 2>/dev/null")
  os.remove(in_file)
  os.remove(out_file)
  return dec or ""
end

local function hash_text(raw)
  raw = tostring(raw or "")
  if raw == "" then return "" end
  local in_file = "/tmp/rift_hash_in.txt"
  local f = io.open(in_file, "w")
  if not f then return "" end
  f:write(raw)
  f:close()
  local sig = exec_read("md5sum "..in_file.." 2>/dev/null | cut -d' ' -f1")
  os.remove(in_file)
  return sig or ""
end

local function get_dns_protection_state()
  local dns_type = trim(uci_get("podkop", "settings", "dns_type"))
  local dns_server = trim(uci_get("podkop", "settings", "dns_server"))
  local bootstrap_dns_server = trim(uci_get("podkop", "settings", "bootstrap_dns_server"))
  local active = dns_type == DNS_PROTECT_TYPE and dns_server == DNS_PROTECT_SERVER and bootstrap_dns_server == DNS_PROTECT_BOOTSTRAP
  local secure = dns_type == "doh" or dns_type == "dot"
  return {
    active = active,
    secure = secure,
    dns_type = dns_type ~= "" and dns_type or "unknown",
    dns_server = dns_server,
    bootstrap_dns_server = bootstrap_dns_server
  }
end

local function save_dns_backup_if_needed()
  local current = get_dns_protection_state()
  if current.active then return end
  uci_set("podkop_subs", "config", "dns_backup_type", current.dns_type)
  uci_set("podkop_subs", "config", "dns_backup_server", current.dns_server)
  uci_set("podkop_subs", "config", "dns_backup_bootstrap", current.bootstrap_dns_server)
  exec_silent("uci commit podkop_subs")
end

local function apply_dns_profile(enable)
  if enable then
    save_dns_backup_if_needed()
    uci_set("podkop", "settings", "dns_type", DNS_PROTECT_TYPE)
    uci_set("podkop", "settings", "dns_server", DNS_PROTECT_SERVER)
    uci_set("podkop", "settings", "bootstrap_dns_server", DNS_PROTECT_BOOTSTRAP)
  else
    local backup_type = trim(uci_get("podkop_subs", "config", "dns_backup_type"))
    local backup_server = trim(uci_get("podkop_subs", "config", "dns_backup_server"))
    local backup_bootstrap = trim(uci_get("podkop_subs", "config", "dns_backup_bootstrap"))
    if backup_type == "" then backup_type = DNS_FALLBACK_TYPE end
    if backup_server == "" then backup_server = DNS_FALLBACK_SERVER end
    if backup_bootstrap == "" then backup_bootstrap = DNS_FALLBACK_BOOTSTRAP end
    uci_set("podkop", "settings", "dns_type", backup_type)
    uci_set("podkop", "settings", "dns_server", backup_server)
    uci_set("podkop", "settings", "bootstrap_dns_server", backup_bootstrap)
  end
  exec_silent("uci commit podkop")
  local restarted = restart_podkop_service()
  return restarted, get_dns_protection_state()
end

-- RPC METHODS --

if method=="get_panel_info" then
  local f=io.open("/etc/podkop_data/version","r")
  local v=f and f:read("*a") or "0.0"
  if f then f:close() end
  print(to_json({version=trim(v), hwid=get_hwid(), device_model=get_device_model()}))
  os.exit(0)
end

if method=="check_for_update" then
  local tmp="/tmp/rift_remote.sh"
  local err="/tmp/rift_remote.err"
  local ok = fetch_to_file(REMOTE_SCRIPT_URL, tmp, err)
  if not ok then
    print(to_json({status="error", msg="Не удалось скачать"}))
    os.remove(tmp); os.remove(err); os.exit(0)
  end
  local rs = exec_read("cat "..tmp)
  local rv = rs:match('PANEL_VERSION="([%d%.]+)"')
  local f=io.open("/etc/podkop_data/version","r")
  local lv=f and trim(f:read("*a")) or "0.0"
  if f then f:close() end
  if rv and cmp_ver(rv,lv)==1 then
    print(to_json({status="update_available",local_v=lv,remote_v=rv}))
  else
    print(to_json({status="up_to_date",local_v=lv,remote_v=rv or lv}))
  end
  os.remove(tmp); os.remove(err); os.exit(0)
end

if method=="perform_update" then
  local tmp="/tmp/rift_update.sh"
  local err="/tmp/rift_update.err"
  fetch_to_file(REMOTE_SCRIPT_URL, tmp, err)
  local raw = exec_read("head -n 5 "..tmp.." 2>/dev/null")
  if raw == "" or not raw:match('PANEL_VERSION="') then
    print('{"status":"error","msg":"Update script download failed"}')
    os.remove(tmp); os.remove(err); os.exit(0)
  end
  exec_silent("sed -i 's/\r$//' "..tmp)
  exec_silent("sh "..tmp)
  os.remove(tmp); os.remove(err)
  print('{"status":"ok"}')
  os.exit(0)
end

if method=="upgrade_singbox" then
  local ok, info = ensure_singbox_xhttp()
  if ok then
    print(to_json({status="ok", before=info.before, after=info.after, changed=info.changed, msg=info.msg, logs=info.logs or ""}))
  else
    print(to_json({status="error", msg=info.msg or "sing-box upgrade failed", before=info.before or "", after=info.after or "", logs=info.logs or ""}))
  end
  os.exit(0)
end

if method=="get_singbox_status" then
  local version = get_singbox_version()
  local ok, details = singbox_supports_xhttp()
  print(to_json({
    version = version,
    xhttp_supported = ok,
    flavor = ok and "extended" or "regular",
    details = details or ""
  }))
  os.exit(0)
end

if method=="get_nodes" then
  local s,db=pcall(dofile,"/etc/podkop_data/nodes.lua")
  if not s or type(db)~="table" then db={nodes={}} end
  if type(db.nodes)~="table" then db.nodes={} end
  local r=exec_silent("pgrep -f podkop")
  local rn=(r==0)or(r==true)
  -- активный узел — по сохранённому ключу (apply пишет /etc/podkop_data/active_key)
  local active_key=exec_read("cat /etc/podkop_data/active_key 2>/dev/null")
  -- в UI sb не нужен (тяжёлый) — отдаём узлы без поля sb
  local view={}
  for i,n in ipairs(db.nodes) do
    if n.is_separator then
      view[i]={is_separator=true, name=n.name}
    else
      view[i]={name=n.name, host=n.host, port=n.port, type=n.type,
               transport=n.transport, transport_label=n.transport_label,
               security=n.security, flow=n.flow, key=n.key}
    end
  end
  print(to_json({
    nodes=view,
    expire=db.expire or "No data",
    sub_title=db.sub_title or "",
    sub_expire=db.sub_expire or "",
    sub_traffic=db.sub_traffic or "",
    updated=db.updated or "Never",
    updated_epoch=db.updated_epoch or 0,
    active_key=active_key,
    running=rn
  }))
  os.exit(0)
end

if method=="update_subs" then
  local url=params.url
  if not url or url=="" then url=trim(uci_get("podkop_subs","config","url")) end
  if not url or url=="" then
    dlog("update_subs: URL not found")
    print('{"status":"error","msg":"URL not found"}')
    os.exit(0)
  end
  exec_silent("uci -q delete podkop_subs.config.url")
  uci_set("podkop_subs","config","url",url)
  exec_silent("uci commit podkop_subs")
  dlog("update_subs: start url="..url)

  -- JSON-пайплайн: тянем XRAY_JSON (Happ-UA) — единственный формат со всеми
  -- транспортами (TCP/gRPC/XHTTP/HY2). Конвертим в sing-box outbound на роутере.
  local body="/tmp/podkop_sub.body"
  local err="/tmp/podkop_sub.err"
  local ok = fetch_subscription_json(url, body, err)
  local raw = exec_read("cat "..body.." 2>/dev/null")
  dlog("update_subs: fetched ok="..tostring(ok).." bytes="..tostring(#raw))

  if (not ok) or raw=="" then
    local ferr = exec_read("tail -n 3 "..err.." 2>/dev/null")
    dlog("update_subs: download failed err="..ferr)
    print(to_json({status="error", msg="Subscription download failed"}))
    os.remove(body); os.remove(err); os.exit(0)
  end

  -- Заголовки подписки (срок/имя/трафик) — отдельным HEAD-запросом тем же UA.
  local hdr_file="/tmp/podkop_sub.hdr"
  local sub_info = {expire="", title="", interval=""}
  os.execute("curl -sI -A 'Happ/4.7-RIFT' "..shq(url).." >"..hdr_file.." 2>/dev/null")
  local hdr_raw = exec_read("cat "..hdr_file.." 2>/dev/null")
  if hdr_raw ~= "" then sub_info = extract_sub_info(hdr_file) end
  os.remove(hdr_file)

  -- Парсим XRAY_JSON и конвертим в узлы с готовым sing-box outbound
  local data, jerr = json_decode(raw)
  if type(data) ~= "table" then
    dlog("update_subs: JSON parse failed: "..tostring(jerr).." head="..raw:sub(1,80))
    print(to_json({status="error", msg="Subscription is not valid JSON (ожидался XRAY_JSON)"}))
    os.remove(body); os.remove(err); os.exit(0)
  end
  local nodes, stats = build_nodes_from_xray(data)
  -- считаем реальные узлы (не разделители)
  local real=0
  for _,n in ipairs(nodes) do if not n.is_separator then real=real+1 end end
  dlog(string.format("update_subs: parsed real=%d sep=%d skip=%d tcp=%d grpc=%d xhttp=%d hy2=%d",
       real, stats.sep or 0, stats.skip or 0, stats.tcp or 0, stats.grpc or 0, stats.xhttp or 0, stats.hysteria2 or 0))

  if real == 0 then
    dlog("update_subs: no real servers (возможно HWID-заглушки или истёкшая подписка)")
    print(to_json({status="error", msg="No servers found"}))
    os.remove(body); os.remove(err); os.exit(0)
  end

  local traffic_str = (sub_info.traffic_label and sub_info.traffic_label ~= "") and sub_info.traffic_label or ""
  local source_hash = hash_text(raw)

  -- Не переписываем nodes.lua если подписка не изменилась (cron каждые 5 мин —
  -- иначе износ флеша). Сравниваем хэш XRAY_JSON-ответа.
  local has_existing, existing = pcall(dofile, "/etc/podkop_data/nodes.lua")
  if has_existing and type(existing)=="table" and existing.source_hash==source_hash then
    dlog("update_subs: подписка не изменилась (hash совпал) — nodes.lua не переписываю")
    print(to_json({status="ok", count=real, expire=existing.expire or "No data",
      sub_title=existing.sub_title or "", sub_traffic=existing.sub_traffic or "",
      updated=existing.updated or "", updated_epoch=existing.updated_epoch or 0, changed=false}))
    os.remove(body); os.remove(err); os.exit(0)
  end

  local db={
    expire=sub_info.expire ~= "" and sub_info.expire or "No data",
    sub_title=sub_info.title or "",
    sub_expire=sub_info.expire or "",
    sub_traffic=traffic_str,
    updated=os.date("!%Y-%m-%dT%H:%M:%SZ"),
    updated_epoch=os.time(),
    nodes=nodes,
    source_hash=source_hash
  }
  local f=io.open("/etc/podkop_data/nodes.lua","w")
  if f then
    f:write("return "..serialize(db))
    f:close()
    dlog("update_subs: nodes.lua written, real="..real)
    print(to_json({status="ok", count=real, expire=db.expire, sub_title=db.sub_title, sub_traffic=traffic_str, updated=db.updated, updated_epoch=db.updated_epoch, changed=true}))
  else
    dlog("update_subs: nodes.lua write FAILED")
    print('{"status":"error","msg":"Write failed"}')
  end
  os.remove(body); os.remove(err); os.exit(0)
end

if method=="apply" then
  -- v4.7 JSON-пайплайн: подключение по индексу узла. Узел уже несёт готовый
  -- sing-box outbound (db.nodes[i].sb). Все транспорты идут через outbound_json
  -- (extended ядро умеет TCP/gRPC/XHTTP/HY2). URL-режим больше не используется.
  local idx = tonumber(params.idx)
  if not idx then
    dlog("apply: idx пуст")
    print('{"status":"error","msg":"idx пуст"}')
    os.exit(0)
  end
  local s,db=pcall(dofile,"/etc/podkop_data/nodes.lua")
  if not s or type(db)~="table" or type(db.nodes)~="table" then
    dlog("apply: nodes.lua недоступен")
    print('{"status":"error","msg":"Список узлов пуст, обновите подписку"}')
    os.exit(0)
  end
  local node = db.nodes[idx+1]   -- JS forEach 0-based -> Lua 1-based
  if not node or node.is_separator or not node.sb then
    dlog("apply: узел idx="..tostring(idx).." не найден/разделитель")
    print('{"status":"error","msg":"Узел не найден"}')
    os.exit(0)
  end
  dlog("apply: idx="..idx.." name="..tostring(node.name).." key="..tostring(node.key).." transport="..tostring(node.transport))

  local outbound = to_json(node.sb)
  exec_silent("uci set podkop.main.proxy_config_type='outbound'")
  exec_silent("uci -q delete podkop.main.proxy_string")
  uci_set("podkop","main","outbound_json",outbound)
  exec_silent("uci commit podkop")
  dlog("apply: outbound_json записан ("..#outbound.." байт), рестарт podkop...")

  if restart_podkop_service() then
    -- запоминаем активный узел для подсветки в UI (стабильный ключ host:port:transport)
    local af=io.open("/etc/podkop_data/active_key","w")
    if af then af:write(node.key or ""); af:close() end
    local up = exec_silent("pgrep -f sing-box")
    dlog("apply: podkop рестартован, sing-box "..(((up==0)or(up==true)) and "RUNNING" or "не виден"))
    print(to_json({status="ok", transport=node.transport, name=node.name}))
  else
    local alog = exec_read("tail -n 8 /tmp/rift_apply.log 2>/dev/null")
    dlog("apply: podkop НЕ перезапустился. log: "..alog)
    print(to_json({status="error", msg="Podkop не смог перезапуститься", log=alog}))
  end
  os.exit(0)
end

if method=="ping" then
  local host=params.host
  if host and host:match("^[a-zA-Z0-9%.%-]+$") then
    local res=exec_silent("ping -c 1 -W 2 "..host)
    local ms="timeout"
    local s="fail"
    if (res==0)or(res==true) then
      local out=exec_read("ping -c 1 -W 2 "..host.." 2>/dev/null")
      local val=out:match("time=([%d%.]+)")
      if val then ms=math.floor(tonumber(val)).." ms" end
      s="ok"
    end
    print(to_json({status=s,time=ms,host=host}))
  else
    print('{"status":"error","msg":"bad host"}')
  end
  os.exit(0)
end

if method=="ping_all" then
  local s,db=pcall(dofile,"/etc/podkop_data/nodes.lua")
  if not s or type(db)~="table" then db={nodes={}} end
  local results={}
  local done_hosts={}
  for _,node in ipairs(db.nodes or {}) do
    local h=node.host
    if h and h~="" and not done_hosts[h] and h:match("^[a-zA-Z0-9%.%-]+$") then
      done_hosts[h]=true
      local res=exec_silent("ping -c 1 -W 2 "..h)
      local ms="timeout"
      if (res==0)or(res==true) then
        local out=exec_read("ping -c 1 -W 2 "..h.." 2>/dev/null")
        local val=out:match("time=([%d%.]+)")
        if val then ms=math.floor(tonumber(val)).." ms" end
      end
      results[h]=ms
    end
  end
  print(to_json({status="ok",pings=results}))
  os.exit(0)
end

-- ===========================================================================
-- v4.7: MAC-based "full VPN"
-- ===========================================================================
-- Раньше: список IP в uci podkop.main.fully_routed_ips. При переподключении
--         DHCP-lease даёт устройству НОВЫЙ IP -> оно выпадало из VPN, юзеру
--         приходилось вручную нажимать «включить» повторно.
-- Сейчас: панель хранит MAC + hostname в /etc/podkop_data/vpn_macs.list.
--         Watcher daemon (rift-mac-vpn-watcher) каждые 30s мапит MAC->IP через
--         ip neigh + dhcp.leases и обновляет podkop.main.fully_routed_ips,
--         если набор IP изменился. UI работает только с MAC.
-- ===========================================================================
local VPN_MACS_FILE = "/etc/podkop_data/vpn_macs.list"

-- Прочитать saved MAC-список. Формат: "MAC\tHOSTNAME" по строке.
local function read_vpn_macs()
  local list = {}
  local f = io.open(VPN_MACS_FILE, "r")
  if not f then return list end
  for line in f:lines() do
    line = trim(line)
    if line ~= "" then
      local mac, name = line:match("^(%S+)%s*(.*)$")
      if mac and mac:match("^[%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:][%x:]$") then
        list[#list+1] = {mac = mac:lower(), name = name or ""}
      end
    end
  end
  f:close()
  return list
end

local function write_vpn_macs(list)
  local f = io.open(VPN_MACS_FILE, "w")
  if not f then return false end
  for _, m in ipairs(list) do
    f:write((m.mac or "") .. "\t" .. (m.name or "") .. "\n")
  end
  f:close()
  return true
end

-- Найти текущий IPv4 для MAC через ip neigh + dhcp.leases.
-- Возвращает "" если устройство сейчас не онлайн.
local function ip_for_mac(mac)
  if not mac or mac == "" then return "" end
  local mac_lo = mac:lower()
  -- Сначала ip neigh (отражает реальное состояние сети)
  local out = exec_read("ip -4 neigh show 2>/dev/null")
  for line in out:gmatch("[^\n]+") do
    local ip, ll = line:match("^(%d+%.%d+%.%d+%.%d+).-lladdr%s+(%S+)")
    if ip and ll and ll:lower() == mac_lo then
      return ip
    end
  end
  -- Fallback: /tmp/dhcp.leases
  local f = io.open("/tmp/dhcp.leases","r")
  if f then
    for line in f:lines() do
      local p = {}
      for w in line:gmatch("%S+") do p[#p+1] = w end
      if p[2] and p[2]:lower() == mac_lo and p[3] then
        f:close()
        return p[3]
      end
    end
    f:close()
  end
  return ""
end

if method=="get_network" then
  -- Активные клиенты (объединяем dhcp.leases и ip neigh, dedup по MAC)
  local clients = {}
  local seen_mac = {}
  -- 1) Источник имён — dhcp.leases (там есть hostname)
  local f = io.open("/tmp/dhcp.leases","r")
  if f then
    for line in f:lines() do
      local p = {}
      for w in line:gmatch("%S+") do p[#p+1] = w end
      if p[2] and p[3] and not seen_mac[p[2]:lower()] then
        seen_mac[p[2]:lower()] = true
        clients[#clients+1] = {mac = p[2]:lower(), ip = p[3], name = p[4] or p[3]}
      end
    end
    f:close()
  end
  -- 2) Дополним из ip neigh (устройства со статической IP / без DHCP)
  local out = exec_read("ip -4 neigh show 2>/dev/null")
  for line in out:gmatch("[^\n]+") do
    local ip, ll = line:match("^(%d+%.%d+%.%d+%.%d+).-lladdr%s+(%S+)")
    if ip and ll and not seen_mac[ll:lower()] then
      -- Только LAN-сеть (исключаем wan-шлюзы)
      if ip:match("^192%.168%.") or ip:match("^10%.") or ip:match("^172%.") then
        seen_mac[ll:lower()] = true
        clients[#clients+1] = {mac = ll:lower(), ip = ip, name = ip}
      end
    end
  end
  -- Saved MAC-список из vpn_macs.list (то что юзер «включил VPN для»)
  local vpn_macs = {}
  for _, m in ipairs(read_vpn_macs()) do
    vpn_macs[#vpn_macs+1] = m.mac
  end
  -- Текущий IP-список из podkop (для отображения какие IP уже фактически роутятся)
  local current_ips = {}
  for w in (exec_read("uci -q get podkop.main.fully_routed_ips") or ""):gmatch("%S+") do
    current_ips[#current_ips+1] = w
  end
  -- Домены
  local domains = {}
  for w in (exec_read("uci -q get podkop.main.user_domains") or ""):gmatch("%S+") do
    domains[#domains+1] = w
  end
  print(to_json({clients=clients, vpn_macs=vpn_macs, vpn_ips_active=current_ips, domains=domains}))
  os.exit(0)
end

if method=="manage_vpn" then
  -- v4.7: оперируем MAC-ом, не IP. Watcher daemon сам переотразит IP.
  local mac = (params.mac or ""):lower()
  local name = params.name or ""
  local a = params.action
  if mac == "" or not a then
    print('{"status":"error","msg":"mac and action required"}')
    os.exit(0)
  end
  -- Валидация MAC (xx:xx:xx:xx:xx:xx)
  if not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
    print('{"status":"error","msg":"bad mac format"}')
    os.exit(0)
  end
  local list = read_vpn_macs()
  if a == "add" then
    local found = false
    for _, m in ipairs(list) do
      if m.mac == mac then m.name = name; found = true; break end
    end
    if not found then list[#list+1] = {mac = mac, name = name} end
  elseif a == "del" then
    local new = {}
    for _, m in ipairs(list) do
      if m.mac ~= mac then new[#new+1] = m end
    end
    list = new
  else
    print('{"status":"error","msg":"bad action"}')
    os.exit(0)
  end
  if not write_vpn_macs(list) then
    print('{"status":"error","msg":"cannot write vpn_macs.list"}')
    os.exit(0)
  end
  -- Тригернуть немедленную пересборку IP-списка
  exec_silent("/usr/local/sbin/rift-mac-vpn-watcher --once 2>/dev/null")
  print('{"status":"ok"}')
  os.exit(0)
end

if method=="manage_domain" then
  local d=params.domain; local a=params.action
  if d and a and d:match("^[a-zA-Z0-9%.%-]+$") then
    if a=="add" then
      exec_silent("uci set podkop.main.user_domain_list_type='dynamic'")
      exec_silent("uci add_list podkop.main.user_domains="..shq(d))
    elseif a=="del" then
      exec_silent("uci del_list podkop.main.user_domains="..shq(d))
    end
    exec_silent("uci commit podkop"); exec_silent("/etc/init.d/podkop restart")
    print('{"status":"ok"}')
  else print('{"status":"error","msg":"bad domain"}') end
  os.exit(0)
end

if method=="get_dns_protection" then
  local state = get_dns_protection_state()
  print(to_json(state))
  os.exit(0)
end

if method=="toggle_dns_protection" then
  local enable = params.enable == "1" or params.enable == "true" or params.enable == "on"
  local ok, state = apply_dns_profile(enable)
  if ok then
    print(to_json({
      status = "ok",
      active = state.active,
      secure = state.secure,
      dns_type = state.dns_type,
      dns_server = state.dns_server,
      bootstrap_dns_server = state.bootstrap_dns_server,
      msg = enable and "DNS protection enabled" or "DNS protection disabled"
    }))
  else
    print(to_json({
      status = "error",
      msg = "Podkop restart failed after DNS change",
      active = state.active,
      dns_type = state.dns_type,
      dns_server = state.dns_server,
      bootstrap_dns_server = state.bootstrap_dns_server
    }))
  end
  os.exit(0)
end

if method=="get_sub_url" then
  print(to_json({url=uci_get("podkop_subs","config","url")}))
  os.exit(0)
end

if method=="get_logs" then
  local lines = tostring(params.lines or "80"):gsub("%D","")
  if lines == "" then lines = "80" end
  local panel = exec_read("tail -n "..lines.." "..RIFT_PANEL_LOG.." 2>/dev/null")
  local sys = exec_read("logread 2>/dev/null | grep -iE 'podkop|sing-box' | tail -n "..lines)
  local out = "===== RIFT panel.log =====\n"..(panel~="" and panel or "(пусто)").."\n\n===== podkop / sing-box (logread) =====\n"..(sys~="" and sys or "(пусто)")
  print(to_json({logs=out}))
  os.exit(0)
end

if method=="get_hwid_info" then
  print(to_json({hwid=get_hwid(), device_model=get_device_model(), os_version=get_os_version(), os_type="OpenWRT"}))
  os.exit(0)
end

print('{"status":"error","msg":"unknown method"}')
EOF

# 7) Frontend
logi "[7/10] Запись Frontend..."
cat <<'EOF' > /www/podkop_panel/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>RIFT Panel</title>
  <link id="favicon" rel="icon" href="">
  <style>
    :root{--bg:#0A0E1A;--card:#111827;--text:#E8EDF2;--text-sec:#7B8D9E;--accent:#85D9FE;--grad1:#0068FF;--grad2:#85D9FE;--green:#00E676;--red:#FF5252;--orange:#FFB74D;--border:rgba(0,104,255,.15);--shadow:0 4px 24px rgba(0,0,0,.5)}
    @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:'Inter',-apple-system,BlinkMacSystemFont,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
    .container{max-width:520px;margin:0 auto;padding:16px}
    .header{text-align:center;padding:20px 0 12px}
    .logo-img{width:64px;height:64px;border-radius:14px;margin-bottom:8px}
    .header h1{font-size:28px;font-weight:800;background:linear-gradient(135deg,var(--grad1),var(--grad2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:1px}
    .header .version{font-size:11px;color:var(--text-sec);margin-top:4px}
    .card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:20px;margin-bottom:14px;box-shadow:var(--shadow)}
    h3{margin:0 0 14px;font-weight:700;font-size:14px;color:var(--text-sec);text-transform:uppercase;letter-spacing:.8px}
    .active-card{background:linear-gradient(135deg,#0068FF 0%,#85D9FE 100%);border:none;text-align:center;color:#fff;position:relative;overflow:hidden}
    .active-card::before{content:'';position:absolute;top:-50%;left:-50%;width:200%;height:200%;background:radial-gradient(circle,rgba(255,255,255,.08) 0%,transparent 70%);animation:pulse 4s ease-in-out infinite;pointer-events:none}
    @keyframes pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.05)}}
    .active-card h3{color:rgba(255,255,255,.7)}
    .server-big{font-size:18px;font-weight:800;margin:8px 0 4px;display:block;word-break:break-word}
    .server-meta{color:rgba(255,255,255,.75);font-size:12px;display:block;margin-top:4px}
    .status-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;vertical-align:middle}
    .status-dot.on{background:var(--green);box-shadow:0 0 8px var(--green)}
    .status-dot.off{background:var(--red);box-shadow:0 0 8px var(--red)}
    .btn{border:none;border-radius:12px;font-weight:700;font-size:13px;cursor:pointer;transition:all .15s;outline:none}
    .btn-primary{background:linear-gradient(135deg,var(--grad1),var(--grad2));color:#fff;padding:10px 18px}
    .btn-primary:active{transform:scale(.97)}
    .btn-outline{background:rgba(0,104,255,.08);border:1px solid rgba(0,104,255,.3);color:var(--accent);padding:8px 14px;font-size:12px}
    .btn-outline:active{background:rgba(0,104,255,.18)}
    .btn-danger{background:rgba(255,82,82,.1);border:1px solid rgba(255,82,82,.25);color:var(--red);padding:6px 12px;font-size:11px}
    .btn-active{background:linear-gradient(135deg,var(--green),#00C853);color:#fff;padding:8px 14px;font-size:12px;border:none}
    .btn-full{width:100%;padding:12px;margin-top:12px;font-size:14px}
    .list-row{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:12px 0;border-bottom:1px solid var(--border)}
    .list-row:last-child{border-bottom:none;padding-bottom:0}
    /* Декоративный разделитель кластеров (узлы с name = только U+3164/U+2800/spaces) */
    .node-separator{height:8px;border-bottom:1px dashed var(--border);margin:6px 0;opacity:.55}
    .node-separator:last-child{display:none}
    .node-info{flex:1;min-width:0}
    .item-name{font-weight:600;font-size:13px;color:var(--text);display:flex;align-items:center;gap:6px;flex-wrap:wrap;word-break:break-word}
    .item-title{display:inline-flex;align-items:center;gap:6px;min-width:0}
    .item-title-text{display:inline-block;min-width:0}
    .item-sub{display:block;font-size:11px;color:var(--text-sec);margin-top:4px;letter-spacing:.04em;text-transform:uppercase}
    .transport-badge{display:inline-block;font-size:9px;font-weight:800;padding:2px 6px;border-radius:6px;margin-left:6px;vertical-align:middle}
    .badge-tcp{background:rgba(0,212,255,.12);color:var(--accent)}
    .badge-grpc{background:rgba(255,183,77,.12);color:var(--orange)}
    .badge-xhttp{background:rgba(0,230,118,.12);color:var(--green)}
    .badge-ws{background:rgba(156,39,176,.12);color:#CE93D8}
    .ping-text{font-size:10px;color:var(--text-sec);margin-top:1px;display:block}
    .list-row.active-row{background:linear-gradient(135deg,rgba(0,104,255,.15),rgba(133,217,254,.08));border:1px solid rgba(0,104,255,.35);border-radius:12px;margin:4px -8px;padding:12px 8px}
    .ping-ok{color:var(--green)}
    .ping-bad{color:var(--red)}
    .sub-info{font-size:11px;color:rgba(255,255,255,.6);margin-top:4px;display:block}
    .input-group{display:flex;gap:8px;margin-top:12px}
    input[type=text]{background:rgba(255,255,255,.05);border:1px solid var(--border);color:var(--text);padding:10px 12px;border-radius:10px;width:100%;font-size:12px;font-family:inherit;outline:none}
    input[type=text]:focus{border-color:var(--accent)}
    input[type=text]::placeholder{color:var(--text-sec)}
    .preloader-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(10,14,26,.85);backdrop-filter:blur(8px);z-index:9999;display:none;flex-direction:column;justify-content:center;align-items:center}
    .ghost-loader{width:55px;height:64px;animation:ghostFloat 2s ease-in-out infinite}
    .ghost-loader img{width:100%;height:100%}
    @keyframes ghostFloat{0%,100%{transform:translateY(0)}50%{transform:translateY(-16px)}}
    .loader-text{color:var(--accent);font-size:12px;margin-top:16px;opacity:.7;letter-spacing:1px}
    .toast{display:none;position:fixed;left:12px;right:12px;bottom:12px;padding:12px 16px;border-radius:12px;background:var(--card);border:1px solid var(--border);color:var(--text);z-index:10000;font-size:12px;box-shadow:0 8px 32px rgba(0,0,0,.5)}
    .logs-modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.8);backdrop-filter:blur(8px);z-index:9998;overflow-y:auto}
    .logs-content{max-width:560px;margin:40px auto;padding:20px;background:var(--card);border-radius:16px;border:1px solid var(--border)}
    .logs-text{font-family:'Courier New',monospace;font-size:11px;line-height:1.6;color:var(--green);background:rgba(0,0,0,.3);padding:12px;border-radius:8px;max-height:60vh;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
    .logs-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}
    .hwid-block{font-size:11px;color:var(--text-sec);padding:8px 12px;background:rgba(0,0,0,.2);border-radius:8px;margin-top:8px;word-break:break-all}
    .hwid-block b{color:var(--accent)}
    .empty-state{text-align:center;padding:20px 0;color:var(--text-sec);font-size:13px}
    .node-actions{flex-shrink:0}
    .flag-icon,.flag-fallback{width:26px;height:26px;display:inline-flex;align-items:center;justify-content:center;border-radius:50%;overflow:hidden;box-shadow:0 0 0 1px rgba(0,0,0,.18) inset;flex:0 0 auto}
    .flag-icon svg{display:block;width:100%;height:100%}
    .flag-fallback{font-size:10px;font-weight:700;background:var(--border)}
    .row-chevron{color:var(--text-muted,#8a8f98);font-size:22px;line-height:1;padding:0 4px;flex:0 0 auto}
    .list-row.clickable{cursor:pointer}
    .list-row.clickable:active{opacity:.7}
    .flag-fallback{font-size:8px;font-weight:800;background:rgba(255,255,255,.06);color:var(--accent);letter-spacing:.04em}
    .active-name-wrap{display:inline-flex;align-items:center;gap:8px;justify-content:center;flex-wrap:wrap}
  </style>
</head>
<body>
  <div id="preloader" class="preloader-overlay"><div class="ghost-loader"><img id="loader_img" src="data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iNTUiIGhlaWdodD0iNjQiIHZpZXdCb3g9IjAgMCA1NSA2NCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZD0iTTIwLjMzOTQgMC4yODI0MTNDMjQuNzY4OSAtMC40MTM0MTQgMjkuMzA1NSAwLjE4MzAzOSAzMy40MDQ4IDIuMDAwMTlDMzkuOTM2NSA0Ljg5NTY3IDQ0Ljc4MDEgMTAuNjI3MiA0Ni41NDY0IDE3LjU1TDU0LjM3NDUgNDguMjMxNkw1NC40NTU2IDQ4LjYwMDhDNTUuMjQ2MiA1Mi4yMDE1IDUyLjgyMjMgNTUuNzE5IDQ5LjE3NjMgNTYuMjYyOUw0OC44MjE4IDU2LjMxNTZDNDcuMTMyIDU2LjU2NzYgNDUuNDE5NCA1Ni4wMzc1IDQ0LjE2NzUgNTQuODc1Mkw0My42ODIyIDU0LjQyNEM0Mi45NTQyIDUzLjc0NzkgNDEuOTk2OSA1My4zNzIzIDQxLjAwMzQgNTMuMzcyM0MzOS4zOTk5IDUzLjM3MjMgMzcuOTU2NyA1NC4zNDU4IDM3LjM1NSA1NS44MzIyTDM2LjUwNjQgNTcuOTI3OUMzNS44MTgzIDU5LjYyNyAzNC41MTU5IDYxLjAwNDYgMzIuODU3OSA2MS43ODYzTDMxLjk1NTYgNjIuMjExMUMzMC4zMDk4IDYyLjk4NyAyOC40ODE2IDYzLjI5MTcgMjYuNjczNCA2My4wOTFMMjQuMzk0MSA2Mi44MzcxQzIyLjY5MjYgNjIuNjQ4MiAyMS4xNDQ3IDYxLjc2MjggMjAuMTE5NyA2MC4zOTE4TDE3Ljc5MTUgNTcuMjc4NUMxNi4yNzM1IDU1LjI0ODMgMTMuMTgyOCA1NS40MDEzIDExLjg3MjYgNTcuNTcxNUwxMS41MjEgNTguMDQ0MUM5LjkzMTY4IDYwLjE3ODIgNy4xNzYxNCA2MS4wOTAxIDQuNjI3NDYgNjAuMzI1NEw0LjQxMTY0IDYwLjI2QzEuOTU0MjQgNTkuNTIyOCAwLjIzNTg4IDU3LjMwNjkgMC4xMzMzMjMgNTQuNzQzNEwwLjk2NzMwNyAzOS41MTY4QzEuMDk2NCAzNy4xNjA5IDEuMDQ5NDkgMzQuNzk4NCAwLjgyNzY1OSAzMi40NDk0TDAuMDk5MTQyOSAyNC43MzE2Qy0wLjE2MTY1IDIxLjk3MDIgMC4wOTMyMTQ0IDE5LjE4NDQgMC44NTAxMiAxNi41MTU4QzMuMjMzOTQgOC4xMTIxNyAxMC4yODcyIDEuODYxNjMgMTguOTE2NSAwLjUwNjA0NkwyMC4zMzk0IDAuMjgyNDEzWk0xMC4xNTk3IDE4LjkyNUM3LjY1MTQ2IDE4LjkyNSA1LjYxNzcgMjEuNzY0NyA1LjYxNzcgMjUuMjY2OEM1LjYxNzg1IDI4Ljc2ODcgNy42NTE1NiAzMS42MDc2IDEwLjE1OTcgMzEuNjA3NkMxMi42Njc2IDMxLjYwNzMgMTQuNzAwNSAyOC43Njg1IDE0LjcwMDcgMjUuMjY2OEMxNC43MDA3IDIxLjc2NDkgMTIuNjY3NyAxOC45MjUzIDEwLjE1OTcgMTguOTI1Wk0yMy4zNTUgMTguOTI1QzIwLjg0NjkgMTguOTI1IDE4LjgxMzIgMjEuNzY0IDE4LjgxMyAyNS4yNjU4QzE4LjgxMyAyOC43Njc5IDIwLjg0NjggMzEuNjA3NiAyMy4zNTUgMzEuNjA3NkMyNS44NjMxIDMxLjYwNzUgMjcuODk2IDI4Ljc2NzggMjcuODk2IDI1LjI2NThDMjcuODk1OCAyMS43NjQxIDI1Ljg2MyAxOC45MjUxIDIzLjM1NSAxOC45MjVaIiBmaWxsPSJ3aGl0ZSIvPgo8L3N2Zz4K" alt=""></div></div>
  <div id="toast" class="toast"></div>
  <div id="logsModal" class="logs-modal" onclick="if(event.target===this)closeLogs()">
    <div class="logs-content">
      <div class="logs-header">
        <h3 style="margin:0">&#1051;&#1086;&#1075;&#1080; Podkop</h3>
        <button class="btn btn-outline" onclick="closeLogs()">&#1047;&#1072;&#1082;&#1088;&#1099;&#1090;&#1100;</button>
      </div>
      <div>
        <button class="btn btn-outline" onclick="loadLogs()" style="margin-bottom:10px">&#1054;&#1073;&#1085;&#1086;&#1074;&#1080;&#1090;&#1100;</button>
        <button class="btn btn-outline" onclick="loadLogs(200)" style="margin-bottom:10px;margin-left:6px">&#1041;&#1086;&#1083;&#1100;&#1096;&#1077;</button>
      </div>
      <div id="logs_text" class="logs-text">&#1047;&#1072;&#1075;&#1088;&#1091;&#1079;&#1082;&#1072;...</div>
    </div>
  </div>
  <div class="container">
    <header class="header" style="padding:12px 0 8px">
      <img class="logo-img" src="data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTczIiBoZWlnaHQ9IjE3MyIgdmlld0JveD0iMCAwIDE3MyAxNzMiIGZpbGw9Im5vbmUiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+CjxyZWN0IHdpZHRoPSIxNzMiIGhlaWdodD0iMTczIiByeD0iMjUiIGZpbGw9InVybCgjcGFpbnQwX2xpbmVhcl82OV8yKSIvPgo8cGF0aCBkPSJNNzkuMTQxNiA1Ni40MTAyQzgzLjU3MTEgNTUuNzE0MyA4OC4xMDc3IDU2LjMxMDggOTIuMjA3IDU4LjEyNzlDOTguNzM4NyA2MS4wMjM0IDEwMy41ODIgNjYuNzU0OSAxMDUuMzQ5IDczLjY3NzdMMTEzLjE3NyAxMDQuMzU5TDExMy4yNTggMTA0LjcyOUMxMTQuMDQ4IDEwOC4zMjkgMTExLjYyNSAxMTEuODQ3IDEwNy45NzkgMTEyLjM5MUwxMDcuNjI0IDExMi40NDNDMTA1LjkzNCAxMTIuNjk1IDEwNC4yMjIgMTEyLjE2NSAxMDIuOTcgMTExLjAwM0wxMDIuNDg0IDExMC41NTJDMTAxLjc1NiAxMDkuODc2IDEwMC43OTkgMTA5LjUgOTkuODA1NyAxMDkuNUM5OC4yMDIxIDEwOS41IDk2Ljc1OSAxMTAuNDc0IDk2LjE1NzIgMTExLjk2TDk1LjMwODYgMTE0LjA1NkM5NC42MjA2IDExNS43NTUgOTMuMzE4MiAxMTcuMTMyIDkxLjY2MDIgMTE3LjkxNEw5MC43NTc4IDExOC4zMzlDODkuMTEyMSAxMTkuMTE1IDg3LjI4MzggMTE5LjQxOSA4NS40NzU2IDExOS4yMTlMODMuMTk2MyAxMTguOTY1QzgxLjQ5NDggMTE4Ljc3NiA3OS45NDcgMTE3Ljg5MSA3OC45MjE5IDExNi41Mkw3Ni41OTM4IDExMy40MDZDNzUuMDc1NyAxMTEuMzc2IDcxLjk4NSAxMTEuNTI5IDcwLjY3NDggMTEzLjY5OUw3MC4zMjMyIDExNC4xNzJDNjguNzMzOSAxMTYuMzA2IDY1Ljk3ODQgMTE3LjIxOCA2My40Mjk3IDExNi40NTNMNjMuMjEzOSAxMTYuMzg4QzYwLjc1NjUgMTE1LjY1MSA1OS4wMzgxIDExMy40MzUgNTguOTM1NSAxMTAuODcxTDU5Ljc2OTUgOTUuNjQ0NUM1OS44OTg2IDkzLjI4ODYgNTkuODUxNyA5MC45MjYyIDU5LjYyOTkgODguNTc3MUw1OC45MDE0IDgwLjg1OTRDNTguNjQwNiA3OC4wOTc5IDU4Ljg5NTQgNzUuMzEyMSA1OS42NTIzIDcyLjY0MzZDNjIuMDM2MiA2NC4yMzk5IDY5LjA4OTQgNTcuOTg5NCA3Ny43MTg4IDU2LjYzMzhMNzkuMTQxNiA1Ni40MTAyWk02OC45NjE5IDc1LjA1MjdDNjYuNDUzNyA3NS4wNTI3IDY0LjQxOTkgNzcuODkyNSA2NC40MTk5IDgxLjM5NDVDNjQuNDIwMSA4NC44OTY0IDY2LjQ1MzggODcuNzM1NCA2OC45NjE5IDg3LjczNTRDNzEuNDY5OSA4Ny43MzUxIDczLjUwMjggODQuODk2MiA3My41MDI5IDgxLjM5NDVDNzMuNTAyOSA3Ny44OTI3IDcxLjQ3IDc1LjA1MyA2OC45NjE5IDc1LjA1MjdaTTgyLjE1NzIgNzUuMDUyN0M3OS42NDkxIDc1LjA1MjcgNzcuNjE1NCA3Ny44OTE3IDc3LjYxNTIgODEuMzkzNkM3Ny42MTUyIDg0Ljg5NTYgNzkuNjQ5IDg3LjczNTQgODIuMTU3MiA4Ny43MzU0Qzg0LjY2NTQgODcuNzM1MiA4Ni42OTgyIDg0Ljg5NTUgODYuNjk4MiA4MS4zOTM2Qzg2LjY5ODEgNzcuODkxOCA4NC42NjUzIDc1LjA1MjkgODIuMTU3MiA3NS4wNTI3WiIgZmlsbD0id2hpdGUiLz4KPGRlZnM+CjxsaW5lYXJHcmFkaWVudCBpZD0icGFpbnQwX2xpbmVhcl82OV8yIiB4MT0iMTUxLjk3IiB5MT0iNS40OTc2MiIgeDI9IjIuMjg1NjgiIHkyPSIxOTMuODc1IiBncmFkaWVudFVuaXRzPSJ1c2VyU3BhY2VPblVzZSI+CjxzdG9wIG9mZnNldD0iMC4zMDA5MzEiIHN0b3AtY29sb3I9IiMwMDY4RkYiLz4KPHN0b3Agb2Zmc2V0PSIxIiBzdG9wLWNvbG9yPSIjODVEOUZFIi8+CjwvbGluZWFyR3JhZGllbnQ+CjwvZGVmcz4KPC9zdmc+Cg==" alt="RIFT">
    </header>
    <div class="card active-card">
      <h3>&#1040;&#1050;&#1058;&#1048;&#1042;&#1053;&#1054;&#1045; &#1055;&#1054;&#1044;&#1050;&#1051;&#1070;&#1063;&#1045;&#1053;&#1048;&#1045;</h3>
      <span class="server-big" id="active_name">...</span>
      <span class="server-meta" id="sub_name"></span>
      <span class="server-meta" id="sub_expire"></span>
      <span class="server-meta" id="sub_traffic"></span>
      <span class="server-meta" id="sub_updated" style="opacity:.6"></span>
      <button class="btn btn-full" style="background:rgba(255,255,255,.18);color:#fff;border:1px solid rgba(255,255,255,.2)" onclick="updateSubs()">&#1054;&#1073;&#1085;&#1086;&#1074;&#1080;&#1090;&#1100; &#1087;&#1086;&#1076;&#1087;&#1080;&#1089;&#1082;&#1091;</button>
    </div>
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center">
        <h3>&#1057;&#1045;&#1056;&#1042;&#1045;&#1056;&#1067;</h3>
        <button class="btn btn-outline" onclick="pingAll()" style="font-size:11px;padding:4px 10px" id="pingBtn">&#1055;&#1080;&#1085;&#1075;</button>
      </div>
      <div id="nodes_list"></div>
      <div class="input-group">
        <input type="text" id="sub_url" placeholder="&#1057;&#1089;&#1099;&#1083;&#1082;&#1072; &#1085;&#1072; &#1087;&#1086;&#1076;&#1087;&#1080;&#1089;&#1082;&#1091;...">
        <button class="btn btn-primary" onclick="saveUrl()">&#1057;&#1086;&#1093;&#1088;&#1072;&#1085;&#1080;&#1090;&#1100;</button>
      </div>
    </div>
    <div class="card">
      <h3>VPN &#1076;&#1083;&#1103; &#1091;&#1089;&#1090;&#1088;&#1086;&#1081;&#1089;&#1090;&#1074;</h3>
      <div class="input-group">
        <input type="text" id="manual_ip" placeholder="IP (192.168.1.X)">
        <button class="btn btn-primary" onclick="addManualIp()">+</button>
      </div>
      <div id="vpn_list" style="margin-top:10px"></div>
    </div>
    <div class="card">
      <h3>&#1044;&#1086;&#1084;&#1077;&#1085;&#1099; &#1095;&#1077;&#1088;&#1077;&#1079; VPN</h3>
      <div class="input-group">
        <input type="text" id="new_domain" placeholder="domain.com">
        <button class="btn btn-primary" onclick="addDomain()">+</button>
      </div>
      <div id="domains_list" style="margin-top:10px"></div>
    </div>
    <div class="card">
      <h3>&#1047;&#1072;&#1097;&#1080;&#1090;&#1072; DNS</h3>
      <div class="list-row" style="border-bottom:none;padding:0">
        <div class="node-info">
          <span class="item-name" id="dns_status_text">&#1055;&#1088;&#1086;&#1074;&#1077;&#1088;&#1082;&#1072;...</span>
          <span class="item-sub" id="dns_status_meta">...</span>
        </div>
        <div class="node-actions">
          <button class="btn btn-outline" id="dns_toggle_btn" onclick="toggleDnsProtection()">&#1042;&#1082;&#1083;&#1102;&#1095;&#1080;&#1090;&#1100;</button>
        </div>
      </div>
    </div>
    <div class="card">
      <h3>&#1059;&#1089;&#1090;&#1088;&#1086;&#1081;&#1089;&#1090;&#1074;&#1086;</h3>
      <div id="hwid_info" class="hwid-block">&#1047;&#1072;&#1075;&#1088;&#1091;&#1079;&#1082;&#1072;...</div>
    </div>
    <div class="card" style="text-align:center">
      <button class="btn btn-outline" onclick="openLogs()" style="margin:4px">&#1051;&#1086;&#1075;&#1080;</button>
      <button class="btn btn-outline" onclick="upgradeSingbox()" style="margin:4px">&#1055;&#1088;&#1086;&#1074;&#1077;&#1088;&#1080;&#1090;&#1100; XHTTP Core</button>
      <button class="btn btn-outline" onclick="checkForUpdates()" style="margin:4px">&#1054;&#1073;&#1085;&#1086;&#1074;&#1080;&#1090;&#1100; &#1087;&#1072;&#1085;&#1077;&#1083;&#1100;</button>
    </div>
  </div>
<script>
  function esc(s){let d=document.createElement('div');d.textContent=s;return d.innerHTML;}
  function normalizeUrl(url){return(url||"").replace(/#.*$/,'');}
  function safeDecode(value){try{return decodeURIComponent(value||'');}catch(e){return String(value||'');}}
  function getParam(url,key){const m=String(url||'').match(new RegExp('[?&]'+key+'=([^&#]*)'));return m?safeDecode(m[1]):'';}
  function buildConnectionKey(url){
    const raw=String(url||'').trim();
    const base=raw.replace(/#.*$/,'');
    const proto=(base.match(/^([a-z0-9+.-]+):\/\//i)||[])[1]||'';
    const user=(base.match(/:\/\/([^@/?#]+)@/)||[])[1]||'';
    const host=(base.match(/@([^:/?#]+)|:\/\/([^:/?#]+)/)||[]);
    const port=(base.match(/@[^:/?#]+:(\d+)|:\/\/[^:/?#]+:(\d+)/)||[]);
    const extra=getParam(base,'extra');
    const extraHost=(String(extra).match(/\"host\"\s*:\s*\"(.*?)\"/)||[])[1]||'';
    const extraPath=(String(extra).match(/\"path\"\s*:\s*\"(.*?)\"/)||[])[1]||'';
    const extraMode=(String(extra).match(/\"mode\"\s*:\s*\"(.*?)\"/)||[])[1]||'';
    const hostHeader=(getParam(base,'host')||safeDecode(extraHost)||getParam(base,'sni')).toLowerCase();
    return [
      proto.toLowerCase(),
      safeDecode(user).toLowerCase(),
      (host[1]||host[2]||'').toLowerCase(),
      port[1]||port[2]||'',
      getParam(base,'type').toLowerCase()||'tcp',
      getParam(base,'security').toLowerCase(),
      hostHeader,
      getParam(base,'path')||getParam(base,'bx')||getParam(base,'spx')||safeDecode(extraPath),
      getParam(base,'serviceName'),
      getParam(base,'mode')||safeDecode(extraMode),
      getParam(base,'flow'),
      getParam(base,'sni'),
      getParam(base,'pbk'),
      getParam(base,'sid')
    ].join('|');
  }
  // SVG-флаги только для нужных стран: Германия, Финляндия, США.
  // Если в имени узла появится другой emoji-флаг — getFlagCode вернёт код страны,
  // и UI отрендерит fallback (двухбуквенный chip через CSS класс .flag-fallback).
  const FLAG_SVG={
    DE:'<svg viewBox="0 0 18 12" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg"><rect width="18" height="12" fill="#FFCE00"/><rect width="18" height="8" fill="#DD0000"/><rect width="18" height="4" fill="#111"/></svg>',
    FI:'<svg viewBox="0 0 18 12" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg"><rect width="18" height="12" fill="#FFFFFF"/><rect x="5" width="3" height="12" fill="#003580"/><rect y="4" width="18" height="3" fill="#003580"/></svg>',
    US:'<svg viewBox="0 0 18 12" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg"><rect width="18" height="12" fill="#B22234"/><rect y="1" width="18" height="1" fill="#FFFFFF"/><rect y="3" width="18" height="1" fill="#FFFFFF"/><rect y="5" width="18" height="1" fill="#FFFFFF"/><rect y="7" width="18" height="1" fill="#FFFFFF"/><rect y="9" width="18" height="1" fill="#FFFFFF"/><rect y="11" width="18" height="1" fill="#FFFFFF"/><rect width="8" height="6.5" fill="#3C3B6E"/></svg>'
  };
  let globalNodes=[],activeKey="",vpnMacs=[],vpnIpsActive=[],domains=[],pingData={},dnsProtectionState=null;
  const RU={
    request_failed:'\u041e\u0448\u0438\u0431\u043a\u0430',
    regular_singbox:'\u041e\u0431\u043d\u0430\u0440\u0443\u0436\u0435\u043d \u043e\u0431\u044b\u0447\u043d\u044b\u0439 sing-box. \u041f\u0440\u0438 \u043f\u0435\u0440\u0432\u043e\u043c XHTTP-\u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0438 \u043f\u0430\u043d\u0435\u043b\u044c \u0430\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u0438 \u043f\u043e\u0441\u0442\u0430\u0432\u0438\u0442 sing-box-extended.',
    subscription:'\u041f\u043e\u0434\u043f\u0438\u0441\u043a\u0430',
    expire:'\u0414\u0435\u0439\u0441\u0442\u0432\u0443\u0435\u0442 \u0434\u043e',
    traffic:'\u0422\u0440\u0430\u0444\u0438\u043a',
    updated:'\u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u043e',
    just_now:'\u0442\u043e\u043b\u044c\u043a\u043e \u0447\u0442\u043e',
    no_expiry:'\u0411\u0435\u0437 \u0441\u0440\u043e\u043a\u0430',
    expired:'\u0418\u0441\u0442\u0451\u043a',
    unlimited:'\u0411\u0435\u0437\u043b\u0438\u043c\u0438\u0442',
    no_active:'\u041d\u0435\u0442 \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u044f',
    no_servers:'\u0421\u043f\u0438\u0441\u043e\u043a \u043f\u0443\u0441\u0442 \u2014 \u0434\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u043f\u043e\u0434\u043f\u0438\u0441\u043a\u0443',
    reconnect:'\u041f\u0435\u0440\u0435\u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u044c',
    connect:'\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u044c',
    ping:'\u041f\u0438\u043d\u0433',
    updated_ok:'\u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u043e',
    saved_ok:'\u0421\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u043e',
    servers_word:'\u0441\u0435\u0440\u0432\u0435\u0440\u043e\u0432',
    update_failed:'\u041e\u0448\u0438\u0431\u043a\u0430 \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f',
    save_failed:'\u041e\u0448\u0438\u0431\u043a\u0430 \u0441\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u0438\u044f',
    connect_to:'\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u044c\u0441\u044f \u043a',
    connect_failed:'\u041e\u0448\u0438\u0431\u043a\u0430 \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u044f',
    ping_updated:'\u041f\u0438\u043d\u0433 \u043e\u0431\u043d\u043e\u0432\u043b\u0451\u043d',
    no_devices:'\u041d\u0435\u0442 \u0443\u0441\u0442\u0440\u043e\u0439\u0441\u0442\u0432',
    vpn_on:'VPN',
    enable:'\u0412\u043a\u043b\u044e\u0447\u0438\u0442\u044c',
    empty_list:'\u0421\u043f\u0438\u0441\u043e\u043a \u043f\u0443\u0441\u0442',
    remove:'\u0423\u0434\u0430\u043b\u0438\u0442\u044c',
    no_logs:'\u041b\u043e\u0433\u0438 \u043f\u0443\u0441\u0442\u044b',
    error:'\u041e\u0448\u0438\u0431\u043a\u0430',
    loading:'\u0417\u0430\u0433\u0440\u0443\u0437\u043a\u0430...',
    server_fallback:'\u0421\u0435\u0440\u0432\u0435\u0440',
    proxy_word:'PROXY',
    bootstrap_label:'Bootstrap DNS',
    network_failed:'\u041e\u0448\u0438\u0431\u043a\u0430 \u0441\u0435\u0442\u0438',
    domain_failed:'\u041e\u0448\u0438\u0431\u043a\u0430 \u0434\u043e\u043c\u0435\u043d\u0430',
    updates_failed:'\u041e\u0448\u0438\u0431\u043a\u0430 \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f',
    data_failed:'\u041e\u0448\u0438\u0431\u043a\u0430 \u0437\u0430\u0433\u0440\u0443\u0437\u043a\u0438',
    model:'\u041c\u043e\u0434\u0435\u043b\u044c',
    dns_unavailable:'DNS \u0441\u0442\u0430\u0442\u0443\u0441 \u043d\u0435\u0434\u043e\u0441\u0442\u0443\u043f\u0435\u043d',
    dns_read_failed:'\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043f\u0440\u043e\u0447\u0438\u0442\u0430\u0442\u044c DNS \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438 Podkop',
    retry:'\u041f\u043e\u0432\u0442\u043e\u0440',
    dns_protected:'\u0417\u0430\u0449\u0438\u0449\u0435\u043d\u043e',
    dns_custom_secure:'\u0421\u0432\u043e\u0439 \u0437\u0430\u0449\u0438\u0449\u0435\u043d\u043d\u044b\u0439 DNS',
    dns_unprotected:'DNS \u043d\u0435 \u0437\u0430\u0449\u0438\u0449\u0435\u043d',
    disable:'\u041e\u0442\u043a\u043b\u044e\u0447\u0438\u0442\u044c',
    activate:'\u0410\u043a\u0442\u0438\u0432\u0438\u0440\u043e\u0432\u0430\u0442\u044c',
    dns_profile_updated:'DNS \u043f\u0440\u043e\u0444\u0438\u043b\u044c \u043e\u0431\u043d\u043e\u0432\u043b\u0451\u043d',
    dns_toggle_failed:'\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043f\u0435\u0440\u0435\u043a\u043b\u044e\u0447\u0438\u0442\u044c DNS',
    dns_enabled:'\u0417\u0430\u0449\u0438\u0442\u0430 DNS \u0432\u043a\u043b\u044e\u0447\u0435\u043d\u0430',
    dns_disabled:'\u0417\u0430\u0449\u0438\u0442\u0430 DNS \u043e\u0442\u043a\u043b\u044e\u0447\u0435\u043d\u0430',
    check_singbox:'\u041f\u0440\u043e\u0432\u0435\u0440\u0438\u0442\u044c sing-box \u0438 \u043f\u0440\u0438 \u043d\u0435\u043e\u0431\u0445\u043e\u0434\u0438\u043c\u043e\u0441\u0442\u0438 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c sing-box extended \u0434\u043b\u044f XHTTP? \u042d\u0442\u043e \u043c\u043e\u0436\u0435\u0442 \u043f\u0435\u0440\u0435\u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u044c podkop.',
    check_completed:'\u041f\u0440\u043e\u0432\u0435\u0440\u043a\u0430 \u0437\u0430\u0432\u0435\u0440\u0448\u0435\u043d\u0430',
    before:'\u0414\u043e',
    after:'\u041f\u043e\u0441\u043b\u0435',
    update_available:'\u0414\u043e\u0441\u0442\u0443\u043f\u043d\u0430 \u043d\u043e\u0432\u0430\u044f \u0432\u0435\u0440\u0441\u0438\u044f ',
    current_version:'\u0443 \u0432\u0430\u0441',
    latest_version:'\u0423 \u0432\u0430\u0441 \u043f\u043e\u0441\u043b\u0435\u0434\u043d\u044f\u044f \u0432\u0435\u0440\u0441\u0438\u044f',
    seconds_ago:'\u0441\u0435\u043a \u043d\u0430\u0437\u0430\u0434',
    minutes_ago:'\u043c\u0438\u043d \u043d\u0430\u0437\u0430\u0434',
    hours_ago:'\u0447 \u043d\u0430\u0437\u0430\u0434',
    days_ago:'\u0434 \u043d\u0430\u0437\u0430\u0434'
  };
  function showToast(msg,ms=6000){const el=document.getElementById('toast');el.textContent=msg;el.style.display='block';clearTimeout(window.__t);window.__t=setTimeout(()=>{el.style.display='none';},ms);}
  function showLoader(){document.getElementById('preloader').style.display='flex';}
  function hideLoader(){document.getElementById('preloader').style.display='none';}
  function renderFlag(code){
    code=String(code||'').toUpperCase();
    if(!code)return '';
    if(FLAG_SVG[code])return `<span class="flag-icon" title="${esc(code)}">${FLAG_SVG[code]}</span>`;
    return `<span class="flag-fallback" title="${esc(code)}">${esc(code)}</span>`;
  }
  function getFlagCode(name){
    const raw=String(name||'');
    const lead=raw.match(/(^|\s)([A-Z]{2})(?=\s|$)/);
    const pair=raw.match(/[\u{1F1E6}-\u{1F1FF}]{2}/u);
    if(pair){
      const code=[...pair[0]].map(ch=>String.fromCharCode(ch.codePointAt(0)-0x1F1E6+65)).join('');
      if(code)return code;
    }
    return lead?lead[2]:'';
  }
  function cleanNodeName(name){
    let s=String(name||RU.server_fallback);
    s=s.replace(/[\u{1F1E6}-\u{1F1FF}]{2}/gu,' ');
    s=s.replace(/(^|\s)[A-Z]{2}(?=\s|$)/g,' ');
    s=s.replace(/[\u3164]/gu,' ');
    s=s.replace(/^[\s\-]+/u,' ');   // \u043E\u0441\u0442\u0430\u0432\u043B\u044F\u0435\u043C \u2514\u2500 (U+2500-257F) \u2014 \u044D\u0442\u043E \u0434\u0435\u0440\u0435\u0432\u043E \u043F\u043E\u0434-\u0443\u0437\u043B\u043E\u0432 \u0432 \u043C\u0430\u043A\u0435\u0442\u0435
    s=s.replace(/\s+/g,' ').trim();
    return s||RU.server_fallback;
  }
  function getNodeProtocol(node){
    return (String(node.transport||'')==='hysteria2')?'HYSTERIA':'VLESS';
  }
  function getNodeSecurity(node){
    const s=String(node.security||'').trim().toUpperCase();
    if(s)return s;
    return (String(node.transport||'')==='hysteria2')?'TLS':'REALITY';
  }
  function getNodeTransport(node){
    const t=String(node.transport||'tcp').toLowerCase();
    if(t==='hysteria2')return 'HYSTERIA';
    if(t==='grpc')return 'GRPC';
    if(t==='xhttp'||t==='splithttp')return 'XHTTP';
    return 'TCP';
  }
  function getNodeMeta(node){
    // Формат как в макете: VLESS / TCP / REALITY / JSON  (HY2: HYSTERIA / HYSTERIA / TLS / JSON)
    return [getNodeProtocol(node),getNodeTransport(node),getNodeSecurity(node),'JSON'].join(' / ');
  }
  function describeNode(node){
    const title=cleanNodeName(node&&node.name||RU.server_fallback);
    const code=getFlagCode(node&&node.name||'');
    return {title,code,flagHtml:renderFlag(code)};
  }
  function renderDnsProtection(state){
    dnsProtectionState=state||null;
    const statusEl=document.getElementById('dns_status_text');
    const metaEl=document.getElementById('dns_status_meta');
    const btn=document.getElementById('dns_toggle_btn');
    if(!statusEl||!metaEl||!btn)return;
    if(!state){
      statusEl.textContent=RU.dns_unavailable;
      metaEl.textContent=RU.dns_read_failed;
      btn.textContent=RU.retry;
      btn.className='btn btn-outline';
      return;
    }
    const type=String(state.dns_type||'').toUpperCase();
    const dns=state.dns_server||'-';
    const bootstrap=state.bootstrap_dns_server||'-';
    if(state.active){
      statusEl.textContent=RU.dns_protected;
      metaEl.textContent=`${type} / ${dns} / ${RU.bootstrap_label} ${bootstrap}`;
      btn.textContent=RU.disable;
      btn.className='btn btn-danger';
    }else if(state.secure){
      statusEl.textContent=RU.dns_custom_secure;
      metaEl.textContent=`${type} / ${dns} / ${RU.bootstrap_label} ${bootstrap}`;
      btn.textContent=RU.activate;
      btn.className='btn btn-outline';
    }else{
      statusEl.textContent=RU.dns_unprotected;
      metaEl.textContent=`${type} / ${dns} / ${RU.bootstrap_label} ${bootstrap}`;
      btn.textContent=RU.activate;
      btn.className='btn btn-primary';
    }
  }
  async function api(method,params={}){
    params.method=method;
    const qs=Object.keys(params).map(k=>k+'='+encodeURIComponent(params[k])).join('&');
    const resp=await fetch('/cgi-bin/rpc?'+qs,{cache:'no-store'});
    const text=await resp.text();
    let data;
    try{data=JSON.parse(text);}catch(e){throw new Error("RPC: "+text.slice(0,160));}
    if(data&&data.status==="error") throw new Error(data.msg||RU.request_failed);
    return data;
  }
  window.onload=async function(){
    try{
      const logo=document.querySelector('.logo-img');
      const loader=document.getElementById('loader_img');
      const favicon=document.getElementById('favicon');
      if(logo&&favicon)favicon.href=logo.src;
      if(logo&&loader&&(!loader.getAttribute('src')||loader.getAttribute('src')===''))loader.src=logo.src;
    }catch(e){}
    try{const r=await api('get_sub_url');if(r.url)document.getElementById('sub_url').value=r.url;}catch(e){}
    try{const r=await api('get_hwid_info');document.getElementById('hwid_info').innerHTML='<b>HWID:</b> '+(r.hwid||'?')+'<br><b>OS:</b> '+(r.os_type||'')+' '+(r.os_version||'')+'<br><b>'+RU.model+':</b> '+(r.device_model||'?');}catch(e){}
    try{const r=await api('get_singbox_status');if(!r.xhttp_supported)showToast(RU.regular_singbox,10000);}catch(e){}
    await loadData();await loadNetwork();await loadDnsProtection();
  };
  function relativeTime(input){
    if(!input)return '';
    let sec=0;
    if(typeof input==='number' && input>0){
      sec=Math.floor(Date.now()/1000-input);
    }else{
      const d=new Date(String(input));
      if(Number.isNaN(d.getTime()))return '';
      sec=Math.floor((Date.now()-d.getTime())/1000);
    }
    if(sec<0)sec=0;
    if(sec<5)return RU.just_now;
    if(sec<60)return sec+' '+RU.seconds_ago;
    if(sec<3600)return Math.floor(sec/60)+' '+RU.minutes_ago;
    if(sec<86400)return Math.floor(sec/3600)+' '+RU.hours_ago;
    return Math.floor(sec/86400)+' '+RU.days_ago;
  }
  function formatSubExpire(value){
    const v=String(value||'').trim();
    if(!v)return '';
    if(v==='No expiry')return RU.no_expiry;
    if(v==='Expired')return RU.expired;
    return v;
  }
  function formatSubTraffic(value){
    const v=String(value||'').trim();
    if(!v)return '';
    return v.replace(/unlimited/gi,RU.unlimited);
  }
  function extractSubId(url){
    if(!url)return '';
    const parts=url.replace(/\/$/,'').split('/').filter(p=>p);
    if(parts.length>=2)return parts[parts.length-2];
    return parts[parts.length-1]||'';
  }
  async function loadData(){
    try{
      const d=await api('get_nodes');
      globalNodes=Array.isArray(d.nodes)?d.nodes:[];
      activeKey=d.active_key||"";
      const subUrl=document.getElementById('sub_url').value||'';
      const subId=extractSubId(subUrl);
      const subTitle=String(d.sub_title||'').trim()||subId;
      document.getElementById('sub_name').innerText=subTitle?(RU.subscription+': '+subTitle):'';
      document.getElementById('sub_expire').innerText=d.sub_expire?(RU.expire+': '+formatSubExpire(d.sub_expire)):'';
      document.getElementById('sub_traffic').innerText=d.sub_traffic?(RU.traffic+': '+formatSubTraffic(d.sub_traffic)):'';
      document.getElementById('sub_updated').innerText=(d.updated_epoch||d.updated)?(RU.updated+' '+relativeTime(Number(d.updated_epoch)||d.updated)):'';
      let activeHtml=RU.no_active;
      if(activeKey&&globalNodes.length){
        const n=globalNodes.find(x=>(x.key||"")===activeKey);
        if(n){
          const desc=describeNode(n);
          activeHtml=`<span class="active-name-wrap">${desc.flagHtml}<span>${esc(desc.title)}</span></span>`;
        }
      }
      document.getElementById('active_name').innerHTML=activeHtml;
      renderNodes();
    }catch(e){showToast(RU.data_failed+': '+e.message);}
  }
  function getBadge(t){switch((t||'').toLowerCase()){case 'grpc':return 'badge-grpc';case 'xhttp':case 'splithttp':return 'badge-xhttp';case 'ws':return 'badge-ws';default:return 'badge-tcp';}}
  function renderNodes(){
    const div=document.getElementById("nodes_list");
    if(!globalNodes.length){div.innerHTML='<div class="empty-state">'+RU.no_servers+'</div>';return;}
    let h="";
    globalNodes.forEach((n,i)=>{
      // Decorative separator (name содержит только Hangul Filler / spaces) —
      // в подписке Remnawave такие узлы — визуальные разделители кластеров.
      // Рендерим тонкую линию-spacer без кнопок, ping, badge.
      if(n.is_separator){
        h+='<div class="node-separator" aria-hidden="true"></div>';
        return;
      }
      const isA=(n.key||"")===activeKey;
      const desc=describeNode(n);
      const p=pingData[n.host];
      const pingHtml=p?`<span class="ping-text ${p==='timeout'?'ping-bad':'ping-ok'}">${RU.ping} ${esc(String(p))}</span>`:'';
      const chev=`<span class="row-chevron" aria-hidden="true">${isA?'✓':'›'}</span>`;
      const rowClass=isA?'list-row active-row clickable':'list-row clickable';
      h+=`<div class="${rowClass}" onclick="connect(${i})"><div class="node-info"><span class="item-name"><span class="item-title">${desc.flagHtml}<span class="item-title-text">${esc(desc.title)}</span></span></span><span class="item-sub">${esc(getNodeMeta(n))}</span>${pingHtml}</div><div class="node-actions">${chev}</div></div>`;
    });
    div.innerHTML=h;
  }
  async function updateSubs(){showLoader();try{const r=await api('update_subs',{});showToast(`${RU.updated_ok}: ${r.count||"?"} ${RU.servers_word}`);await loadData();}catch(e){showToast(RU.update_failed+': '+e.message,10000);}finally{hideLoader();}}
  async function saveUrl(){const u=document.getElementById('sub_url').value;if(!u)return;showLoader();try{const r=await api('update_subs',{url:u});showToast(`${RU.saved_ok}: ${r.count||"?"} ${RU.servers_word}`);await loadData();}catch(e){showToast(RU.save_failed+': '+e.message,10000);}finally{hideLoader();}}
  async function connect(i){
    const n=globalNodes[i];
    const desc=describeNode(n);
    if(!confirm(`${RU.connect_to} ${desc.title}?`))return;
    showLoader();try{const r=await api('apply',{idx:i});if(r.core_msg)showToast(r.core_msg,10000);if(r.warning)showToast(r.warning,10000);await new Promise(r=>setTimeout(r,2500));await loadData();}catch(e){showToast(RU.connect_failed+': '+e.message,10000);}finally{hideLoader();}}
  async function pingAll(){
    const btn=document.getElementById('pingBtn');btn.textContent='...';btn.disabled=true;
    try{const r=await api('ping_all');if(r.pings){pingData=r.pings;renderNodes();showToast(RU.ping_updated);}}catch(e){showToast(RU.ping+': '+e.message);}
    finally{btn.textContent=RU.ping;btn.disabled=false;}
  }
  async function loadNetwork(){
    try{
      const d=await api('get_network');const c=d.clients||[];vpnIps=Array.isArray(d.vpn_ips)?d.vpn_ips:[];domains=Array.isArray(d.domains)?d.domains:[];
      let vh="";c.forEach(x=>{const iv=vpnIps.includes(x.ip);vh+=`<div class="list-row"><div class="node-info"><span class="item-name">${esc(x.name)}</span><span class="item-sub">${esc(x.ip)}</span></div><div class="node-actions">${iv?`<button class="btn btn-active" onclick="toggleVpn('${x.ip}','del')">${RU.vpn_on}</button>`:`<button class="btn btn-outline" onclick="toggleVpn('${x.ip}','add')">${RU.enable}</button>`}</div></div>`;});
      document.getElementById("vpn_list").innerHTML=vh||'<div class="empty-state">'+RU.no_devices+'</div>';
      let dh="";domains.forEach(dom=>{dh+=`<div class="list-row"><div class="node-info"><span class="item-name">${esc(dom)}</span></div><div class="node-actions"><button class="btn btn-danger" onclick="manageDomain('${dom}','del')">${RU.remove}</button></div></div>`;});
      document.getElementById('domains_list').innerHTML=dh||'<div class="empty-state">'+RU.empty_list+'</div>';
    }catch(e){showToast(RU.network_failed+': '+e.message);}
  }
  async function loadDnsProtection(){
    try{
      const r=await api('get_dns_protection');
      renderDnsProtection(r);
    }catch(e){
      renderDnsProtection(null);
      showToast('DNS: '+e.message,8000);
    }
  }
  async function toggleDnsProtection(){
    const enable=!(dnsProtectionState&&dnsProtectionState.active);
    showLoader();
    try{
      const r=await api('toggle_dns_protection',{enable:enable?'1':'0'});
      renderDnsProtection(r);
      showToast(enable?RU.dns_enabled:RU.dns_disabled,8000);
    }catch(e){
      showToast(RU.dns_toggle_failed+': '+e.message,10000);
    }finally{hideLoader();}
  }
  async function toggleVpn(ip,a){showLoader();try{await api('manage_vpn',{ip,action:a});await new Promise(r=>setTimeout(r,2000));await loadNetwork();}catch(e){showToast('VPN: '+e.message);}finally{hideLoader();}}
  function addManualIp(){const ip=document.getElementById('manual_ip').value;if(ip)toggleVpn(ip,'add');document.getElementById('manual_ip').value="";}
  async function manageDomain(d,a){showLoader();try{await api('manage_domain',{domain:d,action:a});await new Promise(r=>setTimeout(r,2000));await loadNetwork();}catch(e){showToast(RU.domain_failed+': '+e.message);}finally{hideLoader();}}
  function addDomain(){const d=document.getElementById('new_domain').value;if(d)manageDomain(d,'add');document.getElementById('new_domain').value="";}
  function openLogs(){document.getElementById('logsModal').style.display='block';loadLogs();}
  function closeLogs(){document.getElementById('logsModal').style.display='none';}
  async function loadLogs(lines){try{const r=await api('get_logs',{lines:lines||50});const el=document.getElementById('logs_text');el.textContent=r.logs||RU.no_logs;el.scrollTop=el.scrollHeight;}catch(e){document.getElementById('logs_text').textContent=RU.error+': '+e.message;}}
  async function upgradeSingbox(){
    if(!confirm(RU.check_singbox))return;
    showLoader();
    try{
      const r=await api('upgrade_singbox');
      const msg=`${r.msg||RU.check_completed}${r.before?`\\n${RU.before}: ${r.before}`:''}${r.after?`\\n${RU.after}: ${r.after}`:''}`;
      showToast(msg,12000);
      if(r.logs){console.log(r.logs);}
      await new Promise(r=>setTimeout(r,3000));
      await loadData();
    }catch(e){
      showToast('XHTTP Core: '+e.message,12000);
    }finally{hideLoader();}
  }
  async function checkForUpdates(){showLoader();try{const r=await api('check_for_update');if(r.status==='update_available'){if(confirm(`${RU.update_available}${r.remote_v} (${RU.current_version} ${r.local_v}).`)){await api('perform_update');await new Promise(r=>setTimeout(r,4000));location.reload();}}else showToast(`${RU.latest_version} (${r.local_v}).`);}catch(e){showToast(RU.updates_failed+': '+e.message);}finally{hideLoader();}}
</script>
</body>
</html>
EOF

# Router domain entry + clean URL wrapper via main uhttpd
logi "[8/10] Настройка домена rift.lan..."
ROUTER_IP="$(uci -q get network.lan.ipaddr)"
[ -z "$ROUTER_IP" ] && ROUTER_IP="192.168.1.1"
uci -q delete dhcp.rift_panel_domain
uci set dhcp.rift_panel_domain=domain
uci set dhcp.rift_panel_domain.name='rift.lan'
uci set dhcp.rift_panel_domain.ip="$ROUTER_IP"
uci commit dhcp >/dev/null 2>&1

if [ -f /www/index.html ] && [ ! -f /etc/podkop_data/openwrt_index_backup.html ]; then
  cp /www/index.html /etc/podkop_data/openwrt_index_backup.html
fi

cat <<'EOF' > /www/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>RIFT Panel</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0a0e1a;
      --card: #10182a;
      --line: rgba(133, 217, 254, 0.16);
      --text: #e8edf2;
      --muted: rgba(232, 237, 242, 0.62);
      --accent-a: #0068ff;
      --accent-b: #85d9fe;
    }

    * { box-sizing: border-box; }
    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background:
        radial-gradient(circle at top, rgba(133, 217, 254, 0.12), transparent 28%),
        var(--bg);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    body.redirecting {
      display: grid;
      place-items: center;
      padding: 20px;
    }

    .shell {
      position: fixed;
      inset: 0;
      display: none;
      background: var(--bg);
    }

    .loader {
      position: absolute;
      inset: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      background:
        radial-gradient(circle at top, rgba(133, 217, 254, 0.08), transparent 28%),
        rgba(10, 14, 26, 0.96);
      z-index: 2;
      transition: opacity .25s ease;
    }

    .loader.hidden {
      opacity: 0;
      pointer-events: none;
    }

    .loader-card {
      width: min(420px, calc(100vw - 32px));
      padding: 24px;
      border-radius: 22px;
      border: 1px solid var(--line);
      background: rgba(16, 24, 42, 0.82);
      box-shadow: 0 18px 48px rgba(0, 0, 0, 0.36);
      color: var(--text);
    }

    .loader-card strong {
      display: block;
      font-size: 18px;
      margin-bottom: 8px;
      letter-spacing: .02em;
    }

    .loader-card p {
      margin: 0;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.6;
    }

    .loader-bar {
      margin-top: 18px;
      height: 4px;
      border-radius: 999px;
      overflow: hidden;
      background: rgba(255, 255, 255, 0.08);
    }

    .loader-bar::before {
      content: "";
      display: block;
      width: 42%;
      height: 100%;
      border-radius: inherit;
      background: linear-gradient(90deg, var(--accent-a), var(--accent-b));
      animation: drift 1.2s ease-in-out infinite;
    }

    iframe {
      width: 100%;
      height: 100%;
      border: 0;
      display: block;
      background: var(--bg);
    }

    .fallback {
      max-width: 420px;
      padding: 24px;
      border-radius: 20px;
      border: 1px solid var(--line);
      background: rgba(16, 24, 42, 0.82);
      color: var(--text);
      box-shadow: 0 18px 48px rgba(0, 0, 0, 0.36);
    }

    .fallback a {
      color: #9fe5ff;
    }

    @keyframes drift {
      0% { transform: translateX(-110%); }
      100% { transform: translateX(280%); }
    }
  </style>
  <script>
    (function () {
      var host = (location.hostname || '').toLowerCase();
      if (host === 'rift.lan' || host === 'rift') {
        document.addEventListener('DOMContentLoaded', function () {
          var shell = document.getElementById('rift-shell');
          var frame = document.getElementById('rift-frame');
          var loader = document.getElementById('rift-loader');
          if (!shell || !frame) return;
          shell.style.display = 'block';
          frame.src = 'http://' + host + ':2017/';
          frame.addEventListener('load', function () {
            if (loader) loader.classList.add('hidden');
          });
        });
      } else {
        location.replace('/cgi-bin/luci/');
      }
    })();
  </script>
</head>
<body>
  <div id="rift-shell" class="shell">
    <div id="rift-loader" class="loader">
      <div class="loader-card">
        <strong>RIFT Panel</strong>
        <p>Открываем панель через чистый адрес <code>http://rift.lan/</code>. Внутри используется порт 2017, но в строке браузера остается только домен.</p>
        <div class="loader-bar"></div>
      </div>
    </div>
    <iframe
      id="rift-frame"
      title="RIFT Panel"
      loading="eager"
      referrerpolicy="no-referrer"
    ></iframe>
  </div>
  <noscript>
    <div class="fallback">
      Для открытия RIFT Panel нужен JavaScript.
      Прямая ссылка: <a href="http://rift.lan:2017/">http://rift.lan:2017/</a>
    </div>
  </noscript>
</body>
</html>
EOF

# 8) Auto-update subscription (every 5 min)
logi "[9/10] Настройка автообновления..."
cat <<'AEOF' > /etc/podkop_data/autoupdate_sub.sh
#!/bin/sh
URL="$(uci -q get podkop_subs.config.url)"
[ -z "$URL" ] && exit 0
TMP="/tmp/rift_autoupdate_rpc.json"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -q -O "$TMP" "http://127.0.0.1:2017/cgi-bin/rpc?method=update_subs" 2>/dev/null || { rm -f "$TMP"; exit 0; }
else
  wget -q -O "$TMP" "http://127.0.0.1:2017/cgi-bin/rpc?method=update_subs" 2>/dev/null || { rm -f "$TMP"; exit 0; }
fi
grep -q '"status":"ok"' "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 0; }
logger -t "rift-panel" "Subscription metadata refreshed via local RPC"
rm -f "$TMP"
AEOF
chmod +x /etc/podkop_data/autoupdate_sub.sh

# 8.5) MAC-based VPN watcher (v4.7) -------------------------------------------
logi "[9.5/10] Установка MAC-VPN watcher..."
touch /etc/podkop_data/vpn_macs.list

cat <<'WEOF' > /usr/local/sbin/rift-mac-vpn-watcher
#!/bin/sh
# rift-mac-vpn-watcher: каждые 30 сек переотражает MAC->IP в podkop.main.fully_routed_ips
# Storage: /etc/podkop_data/vpn_macs.list (формат: "MAC<TAB>HOSTNAME" по строке)
# Mode: --once (одно прохождение) или без аргумента (бесконечный цикл через 30s)

VPN_MACS_FILE="/etc/podkop_data/vpn_macs.list"
MODE="$1"

resolve_one_pass() {
  [ -s "$VPN_MACS_FILE" ] || {
    # Список пуст -> очищаем uci, если там что-то есть
    cur="$(uci -q get podkop.main.fully_routed_ips)"
    [ -n "$cur" ] && {
      uci -q delete podkop.main.fully_routed_ips
      uci commit podkop
      /etc/init.d/podkop reload >/dev/null 2>&1
      logger -t rift-mac-vpn "Cleared fully_routed_ips (list empty)"
    }
    return 0
  }

  # Собрать NEW IPs из MAC-листа
  NEW_IPS=""
  while IFS=$(printf '\t') read -r MAC NAME; do
    [ -z "$MAC" ] && continue
    # Сначала ip neigh (актуальное состояние)
    IP="$(ip -4 neigh show 2>/dev/null | awk -v m="$(echo "$MAC" | tr A-Z a-z)" 'tolower($5)==m && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')"
    # Fallback на dhcp.leases
    if [ -z "$IP" ]; then
      IP="$(awk -v m="$(echo "$MAC" | tr A-Z a-z)" 'tolower($2)==m {print $3; exit}' /tmp/dhcp.leases 2>/dev/null)"
    fi
    [ -n "$IP" ] && NEW_IPS="$NEW_IPS $IP"
  done < "$VPN_MACS_FILE"

  # Нормализовать (trim + sort)
  NEW_SORTED="$(echo "$NEW_IPS" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  CUR_SORTED="$(uci -q get podkop.main.fully_routed_ips | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ $//')"

  if [ "$NEW_SORTED" != "$CUR_SORTED" ]; then
    uci -q delete podkop.main.fully_routed_ips
    for ip in $NEW_SORTED; do
      uci add_list podkop.main.fully_routed_ips="$ip"
    done
    uci commit podkop
    /etc/init.d/podkop reload >/dev/null 2>&1
    logger -t rift-mac-vpn "fully_routed_ips updated: [$NEW_SORTED]"
  fi
}

if [ "$MODE" = "--once" ]; then
  resolve_one_pass
  exit 0
fi

# Daemon mode
while :; do
  resolve_one_pass
  sleep 30
done
WEOF
chmod +x /usr/local/sbin/rift-mac-vpn-watcher

cat <<'IEOF' > /etc/init.d/rift-mac-vpn-watcher
#!/bin/sh /etc/rc.common
# RIFT MAC-VPN watcher: keeps podkop.main.fully_routed_ips in sync with /etc/podkop_data/vpn_macs.list

USE_PROCD=1
START=99
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command /usr/local/sbin/rift-mac-vpn-watcher
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-0}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

reload_service() {
    stop
    start
}
IEOF
chmod +x /etc/init.d/rift-mac-vpn-watcher
/etc/init.d/rift-mac-vpn-watcher enable >/dev/null 2>&1
/etc/init.d/rift-mac-vpn-watcher start >/dev/null 2>&1

# Migrate v4.6→v4.7: если в uci есть старые fully_routed_ips но vpn_macs.list пуст,
# попробуем восстановить MAC из текущего ip neigh для каждого IP и записать.
# Это разовая операция при upgrade — после неё watcher возьмёт управление.
if [ ! -s /etc/podkop_data/vpn_macs.list ]; then
  OLD_IPS="$(uci -q get podkop.main.fully_routed_ips)"
  if [ -n "$OLD_IPS" ]; then
    echo "[9.5/10] Миграция fully_routed_ips IP→MAC..."
    for ip in $OLD_IPS; do
      MAC="$(ip -4 neigh show "$ip" 2>/dev/null | awk '/lladdr/ {print $5; exit}')"
      [ -z "$MAC" ] && MAC="$(awk -v ip="$ip" '$3==ip {print $2; exit}' /tmp/dhcp.leases 2>/dev/null)"
      NAME="$(awk -v ip="$ip" '$3==ip {print $4; exit}' /tmp/dhcp.leases 2>/dev/null)"
      [ -z "$NAME" ] && NAME="$ip"
      [ -n "$MAC" ] && echo "$MAC	$NAME" >> /etc/podkop_data/vpn_macs.list
    done
    # Триггерим watcher чтобы он перепрочитал и подтянул IP-список заново
    /usr/local/sbin/rift-mac-vpn-watcher --once
  fi
fi
# ----------------------------------------------------------------------------

# Panel auto-update (daily)
cat <<'PEOF' > /etc/podkop_data/autoupdate_panel.sh
#!/bin/sh
TMP="/tmp/rift_remote.sh"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -q -O "$TMP" "https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh" 2>/dev/null || { rm -f "$TMP"; exit 0; }
else
  wget -q -O "$TMP" "https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh" 2>/dev/null || { rm -f "$TMP"; exit 0; }
fi
grep -q '^PANEL_VERSION="' "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 0; }
sed -i 's/\r$//' "$TMP"
LOCAL_V="$(cat /etc/podkop_data/version 2>/dev/null)"
REMOTE_V="$(sed -n 's/^PANEL_VERSION="\([^"]*\)".*/\1/p' "$TMP" | head -1)"
[ -n "$REMOTE_V" ] && [ -n "$LOCAL_V" ] && [ "$REMOTE_V" != "$LOCAL_V" ] && sh "$TMP" >/dev/null 2>&1
rm -f "$TMP"
PEOF
chmod +x /etc/podkop_data/autoupdate_panel.sh

# 9) cron
logi "[10/10] Настройка cron..."
(crontab -l 2>/dev/null | grep -Fv "autoupdate_sub" | grep -Fv "autoupdate_panel" | grep -Fv "/etc/podkop_data/") | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * * /etc/podkop_data/autoupdate_sub.sh"; echo "13 4 * * * /etc/podkop_data/autoupdate_panel.sh") | crontab -

# finish
chmod +x /www/podkop_panel/cgi-bin/rpc
sed -i 's/\r$//' /www/podkop_panel/cgi-bin/rpc
/etc/init.d/uhttpd enable >/dev/null 2>&1
/etc/init.d/uhttpd restart >/dev/null 2>&1
/etc/init.d/dnsmasq restart >/dev/null 2>&1

logi "================================================="
logi "ГОТОВО! RIFT Panel v${PANEL_VERSION}"
logi "Доступ: http://${ROUTER_IP}:2017"
logi "Домен: http://rift.lan/"
logi "HWID: $(cat /etc/podkop_data/hwid 2>/dev/null)"
logi "sing-box(after): $(/usr/bin/sing-box version 2>/dev/null | head -1)"
logi "Авто-обновление подписки: каждые 5 минут"
logi "Лог установки: ${INSTALL_LOG}"
logi "Лог работы панели: /tmp/rift_panel.log (или кнопка «Логи» в панели)"
logi "================================================="
