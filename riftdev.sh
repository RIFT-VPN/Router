#!/bin/sh
# === RIFT PANEL INSTALLER & UPDATER (V3.3) ===
# Install: sh <(wget -O - https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/riftdev.sh)

PANEL_VERSION="3.3"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/riftdev.sh"

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
      echo "[1/6] Остановка веб-сервера..."
      uci -q delete uhttpd.podkop_panel
      uci commit uhttpd >/dev/null 2>&1
      /etc/init.d/uhttpd restart >/dev/null 2>&1
      echo "[2/6] Удаление cron задач..."
      (crontab -l 2>/dev/null | grep -Fv "autoupdate_sub" | grep -Fv "autoupdate_panel" | grep -Fv "/etc/podkop_data/") | crontab -
      echo "[3/6] Удаление файлов панели..."
      rm -rf /www/podkop_panel
      echo "[4/6] Удаление данных..."
      rm -rf /etc/podkop_data
      echo "[5/6] Удаление конфигурации..."
      rm -f /etc/config/podkop_subs
      echo "[6/6] Очистка temp..."
      rm -f /tmp/podkop_sub*.body /tmp/podkop_sub*.err /tmp/rift_*.sh /tmp/rift_*.err
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

# 1) deps
echo "[1/9] Установка пакетов..."
opkg update >/dev/null 2>&1
opkg install ca-bundle coreutils-base64 lua uclient-fetch >/dev/null 2>&1 || true

# 2) structure
echo "[2/9] Настройка системы..."
mkdir -p /www/podkop_panel/cgi-bin
mkdir -p /etc/podkop_data
touch /etc/config/podkop_subs
if [ ! -s /etc/config/podkop_subs ]; then
  echo "config podkop_subs 'config'" > /etc/config/podkop_subs
fi
echo "${PANEL_VERSION}" > /etc/podkop_data/version

# Generate HWID if not exists
if [ ! -f /etc/podkop_data/hwid ]; then
  MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo "00:00:00:00:00:00")
  HWID=$(echo "$MAC" | md5sum | cut -c1-32)
  echo "$HWID" > /etc/podkop_data/hwid
fi

# 3) uhttpd
echo "[3/9] Настройка веб-сервера (порт 2017)..."
uci -q delete uhttpd.podkop_panel
uci set uhttpd.podkop_panel=uhttpd
uci add_list uhttpd.podkop_panel.listen_http='0.0.0.0:2017'
uci set uhttpd.podkop_panel.home='/www/podkop_panel'
uci set uhttpd.podkop_panel.rfc1918_filter='0'
uci set uhttpd.podkop_panel.max_requests='10'
uci set uhttpd.podkop_panel.cgi_prefix='/cgi-bin'
uci commit uhttpd >/dev/null 2>&1

# 4) remove rift domain
echo "[4/9] Очистка DNS..."
for s in $(uci show dhcp 2>/dev/null | sed -n "s/^\(dhcp\.@domain\[[0-9]\+\]\)=domain.*/\1/p"); do
  [ "$(uci -q get ${s}.name)" = "rift" ] && uci delete "$s"
done
uci -q del_list dhcp.@dnsmasq[0].rebind_domain='rift'
uci commit dhcp >/dev/null 2>&1

# 5) Patch podkop for XHTTP support
echo "[5/9] Патч podkop для XHTTP..."
FACADE="/usr/lib/podkop/sing_box_config_facade.sh"
MANAGER="/usr/lib/podkop/sing_box_config_manager.sh"

if [ -f "$FACADE" ] && ! grep -q "xhttp" "$FACADE" 2>/dev/null; then
  sed -i '/^\s*\*)/i\
    xhttp | splithttp)\
        log "Mapping XHTTP transport to HTTP for sing-box" "info"\
        local xhttp_path xhttp_host\
        xhttp_path=$(url_get_query_param "$url" "path")\
        xhttp_host=$(url_get_query_param "$url" "host")\
        config=$(\
            sing_box_cm_set_http_transport_for_outbound "$config" "$outbound_tag" "$xhttp_path" "$xhttp_host"\
        )\
        ;;' "$FACADE"
  echo "  -> sing_box_config_facade.sh patched"
fi

if [ -f "$MANAGER" ] && ! grep -q "set_http_transport_for_outbound" "$MANAGER" 2>/dev/null; then
  cat >> "$MANAGER" << 'PATCH'

sing_box_cm_set_http_transport_for_outbound() {
    local config="$1" tag="$2" path="$3" host="$4"
    echo "$config" | jq \
        --arg tag "$tag" \
        --arg path "$path" \
        --arg host "$host" \
        '.outbounds |= map(
            if .tag == $tag then
                . + { transport: (
                    { type: "http" }
                    + (if $path != "" then {path: $path} else {} end)
                    + (if $host != "" then {host: [$host]} else {} end)
                ) }
            else . end
        )'
}
PATCH
  echo "  -> sing_box_config_manager.sh patched"
fi

# 6) Backend (RPC)
echo "[6/9] Запись Backend..."
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

local function get_hwid()
  local f = io.open("/etc/podkop_data/hwid","r")
  if f then local h=trim(f:read("*a")); f:close(); return h end
  return "unknown"
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
  local osver = get_os_version()
  local headers = {
    "x-hwid: " .. hwid,
    "x-device-os: OpenWRT",
    "x-ver-os: " .. osver,
    "x-device-model: " .. model
  }
  local ok = fetch_to_file(url, out, err, headers)
  if not ok then ok = fetch_to_file(url, out, err) end
  return ok
end

local function smart_fetch_with_headers(url, out, hdr_file)
  local hwid = get_hwid()
  local model = get_device_model()
  local osver = get_os_version()
  local headers = {
    "x-hwid: " .. hwid,
    "x-device-os: OpenWRT",
    "x-ver-os: " .. osver,
    "x-device-model: " .. model
  }
  local ok = fetch_with_headers(url, out, hdr_file, headers)
  if not ok then ok = fetch_with_headers(url, out, hdr_file) end
  return ok
end

-- Extract subscription info from saved headers
local function extract_sub_info(hdr_file)
  local info = {expire="", title="", interval=""}
  local raw = exec_read("cat "..hdr_file.." 2>/dev/null")
  -- profile-title (base64 encoded)
  local pt = raw:match("profile%-title:%s*base64:([%w%+/=]+)")
  if pt then
    local decoded = exec_read("printf %s "..shq(pt).." | base64 -d 2>/dev/null")
    info.title = decoded or ""
    -- extract expire like "29D,22H" or time info
    local expire_match = decoded:match("(%d+[DdДд][%s,]*%d*[HhЧч]*)")
    if expire_match then info.expire = expire_match end
  end
  -- subscription-userinfo header
  local sui = raw:match("subscription%-userinfo:%s*(.-)%s*$")
  if sui then
    local exp_ts = sui:match("expire=(%d+)")
    if exp_ts then
      info.expire_ts = tonumber(exp_ts)
      local diff = tonumber(exp_ts) - os.time()
      if diff > 0 then
        local days = math.floor(diff/86400)
        local hours = math.floor((diff%86400)/3600)
        info.expire = days.."д "..hours.."ч"
      else
        info.expire = "Истекла"
      end
    end
    local dl = sui:match("download=(%d+)")
    local total = sui:match("total=(%d+)")
    if dl and total then
      info.traffic_used = math.floor(tonumber(dl)/1073741824*100)/100
      info.traffic_total = math.floor(tonumber(total)/1073741824*100)/100
    end
  end
  local pi = raw:match("profile%-update%-interval:%s*(%d+)")
  if pi then info.interval = pi end
  return info
end

local qs=os.getenv("QUERY_STRING") or ""
local params={}
for k,v in string.gmatch(qs,"([^&=]+)=([^&=]*)") do
  params[k]=v:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end)
end
local method=params.method

print("Content-type: application/json; charset=utf-8\n")

local REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/riftdev.sh"

local function url_decode(s)
  if not s then return "" end
  return s:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end)
end

local function url_get_param(url, param)
  local val = url:match("[?&]" .. param .. "=([^&#]*)")
  if val then return url_decode(val) end
  return ""
end

-- FIX: parse links line-by-line, not by whitespace pattern
local function parse_links_from_text(text)
  local out={}
  if not text then return out end
  for line in text:gmatch("[^\n\r]+") do
    line = trim(line)
    -- match protocol at START of line
    if line:match("^[a-z]+://") then
      out[#out+1] = line
    end
  end
  return out
end

local function link_to_node(line)
  local proto=(line:match("^(%w+)://") or "LINK"):upper()

  -- Extract name: everything after the FIRST # (greedy to end)
  local ne=line:match("#(.+)$")
  local name="Server"
  if ne then name=url_decode(ne) end

  local host=line:match("@(.-):") or line:match("://([^/:#%?]+)") or "unknown"

  local transport = url_get_param(line, "type")
  if transport == "" then transport = "tcp" end
  transport = transport:lower()

  local security = url_get_param(line, "security")
  local ti = proto
  if security == "reality" then ti = "Reality" end

  local transport_label = transport:upper()
  local unsupported = false
  if transport == "grpc" then transport_label = "gRPC"
  elseif transport == "xhttp" or transport == "splithttp" then
    transport_label = "XHTTP"
    unsupported = true -- sing-box does not support xhttp
  elseif transport == "ws" then transport_label = "WS"
  end

  local service_name = url_get_param(line, "serviceName")
  local path = url_get_param(line, "path")
  local mode = url_get_param(line, "mode")
  local flow = url_get_param(line, "flow")

  return {
    name=name,
    host=host,
    type=ti,
    transport=transport,
    transport_label=transport_label,
    security=security,
    service_name=service_name,
    path=path,
    mode=mode,
    flow=flow,
    unsupported=unsupported,
    full_url=line
  }
end

-- Filter and dedup
local function should_skip(name)
  if not name then return false end
  local lower = name:lower()
  -- Filter phone-only and unsupported transport entries
  if lower:find("обход бс") or lower:find("обход%s+бс") then return true end
  if name:match("📱") then return true end
  return false
end

local function is_xhttp(transport)
  local t = (transport or ""):lower()
  return t == "xhttp" or t == "splithttp"
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
    if not seen[key] and not should_skip(node.name) and not is_xhttp(node.transport) then
      seen[key] = true
      nodes[#nodes+1] = node
    end
  end
  return nodes
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
  local dec = exec_read("printf %s " .. shq(t) .. " | base64 -d 2>/dev/null")
  return dec or ""
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
  exec_silent("sh "..tmp)
  os.remove(tmp); os.remove(err)
  print('{"status":"ok"}')
  os.exit(0)
end

if method=="get_nodes" then
  local s,db=pcall(dofile,"/etc/podkop_data/nodes.lua")
  if not s or type(db)~="table" then db={nodes={}} end
  if type(db.nodes)~="table" then db.nodes={} end
  local cp=uci_get("podkop","main","proxy_string")
  local r=exec_silent("pgrep -f podkop")
  local rn=(r==0)or(r==true)
  local dp=(cp or ""):gsub("%%20"," ")
  print(to_json({
    nodes=db.nodes,
    expire=db.expire or "Нет данных",
    sub_title=db.sub_title or "",
    sub_expire=db.sub_expire or "",
    sub_traffic=db.sub_traffic or "",
    updated=db.updated or "Никогда",
    active_url=dp,
    running=rn
  }))
  os.exit(0)
end

if method=="update_subs" then
  local url=params.url
  if not url or url=="" then url=trim(uci_get("podkop_subs","config","url")) end
  if not url or url=="" then
    print('{"status":"error","msg":"URL не найден!"}')
    os.exit(0)
  end
  exec_silent("uci -q delete podkop_subs.config.url")
  uci_set("podkop_subs","config","url",url)
  exec_silent("uci commit podkop_subs")

  local body="/tmp/podkop_sub.body"
  local err="/tmp/podkop_sub.err"
  local ok = smart_fetch(url, body, err)
  local raw = exec_read("cat "..body.." 2>/dev/null")

  if (not ok) or raw=="" then
    print(to_json({status="error", msg="Ошибка загрузки подписки"}))
    os.remove(body); os.remove(err); os.exit(0)
  end

  -- Try to capture headers separately (optional, may fail on BusyBox)
  local hdr_file="/tmp/podkop_sub.hdr"
  local sub_info = {expire="", title="", interval=""}
  exec_silent("wget -q -S -T 10 -O /dev/null "..shq(url).." 2>"..hdr_file)
  local hdr_raw = exec_read("cat "..hdr_file.." 2>/dev/null")
  if hdr_raw ~= "" then
    sub_info = extract_sub_info(hdr_file)
  end
  os.remove(hdr_file)

  -- try raw first, then base64
  local nodes = parse_nodes(raw)
  if #nodes == 0 then
    local decoded = try_decode_base64(raw)
    if decoded ~= "" then nodes = parse_nodes(decoded) end
  end

  if #nodes == 0 then
    print(to_json({status="error", msg="Серверы не найдены"}))
    os.remove(body); os.remove(hdr_file); os.exit(0)
  end

  -- Build traffic string
  local traffic_str = ""
  if sub_info.traffic_used then
    traffic_str = sub_info.traffic_used.." / "..sub_info.traffic_total.." GB"
  end

  local db={
    expire=sub_info.expire ~= "" and sub_info.expire or "Нет данных",
    sub_title=sub_info.title or "",
    sub_expire=sub_info.expire or "",
    sub_traffic=traffic_str,
    updated=os.date("%Y-%m-%d %H:%M:%S"),
    nodes=nodes
  }
  local f=io.open("/etc/podkop_data/nodes.lua","w")
  if f then
    f:write("return "..serialize(db))
    f:close()
    print(to_json({status="ok", count=#nodes, expire=db.expire, sub_title=db.sub_title, sub_traffic=traffic_str}))
  else
    print('{"status":"error","msg":"Ошибка записи"}')
  end
  os.remove(body); os.remove(err); os.exit(0)
end

if method=="apply" then
  if params.node_url then
    local cu=params.node_url:gsub(" ","%%20")
    uci_set("podkop","main","proxy_string",cu)
    exec_silent("uci commit podkop")
    exec_silent("/etc/init.d/podkop restart")
    print('{"status":"ok"}')
  else
    print('{"status":"error","msg":"node_url пуст"}')
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

if method=="get_network" then
  local c={}
  local f=io.open("/tmp/dhcp.leases","r")
  if f then
    for line in f:lines() do
      local p={}
      for w in line:gmatch("%S+") do p[#p+1]=w end
      if #p>=4 then c[#c+1]={ip=p[3],name=p[4],mac=p[2]} end
    end
    f:close()
  end
  local vl={}
  for w in (exec_read("uci -q get podkop.main.fully_routed_ips") or ""):gmatch("%S+") do vl[#vl+1]=w end
  local dl={}
  for w in (exec_read("uci -q get podkop.main.user_domains") or ""):gmatch("%S+") do dl[#dl+1]=w end
  print(to_json({clients=c,vpn_ips=vl,domains=dl}))
  os.exit(0)
end

if method=="manage_vpn" then
  local ip=params.ip; local a=params.action
  if ip and a and ip:match("^%d+%.%d+%.%d+%.%d+$") then
    if a=="add" then exec_silent("uci add_list podkop.main.fully_routed_ips="..shq(ip))
    elseif a=="del" then exec_silent("uci del_list podkop.main.fully_routed_ips="..shq(ip)) end
    exec_silent("uci commit podkop"); exec_silent("/etc/init.d/podkop restart")
    print('{"status":"ok"}')
  else print('{"status":"error","msg":"bad ip"}') end
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

if method=="get_sub_url" then
  print(to_json({url=uci_get("podkop_subs","config","url")}))
  os.exit(0)
end

if method=="get_logs" then
  local lines = params.lines or "50"
  local log_output = exec_read("logread -e podkop 2>/dev/null | tail -n " .. lines)
  if log_output == "" then
    log_output = exec_read("logread 2>/dev/null | grep -i 'podkop\\|sing-box' | tail -n " .. lines)
  end
  print(to_json({logs=log_output}))
  os.exit(0)
end

if method=="get_hwid_info" then
  print(to_json({hwid=get_hwid(), device_model=get_device_model(), os_version=get_os_version(), os_type="OpenWRT"}))
  os.exit(0)
end

print('{"status":"error","msg":"unknown method"}')
EOF

# 7) Frontend
echo "[7/9] Запись Frontend..."
cat <<'EOF' > /www/podkop_panel/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>RIFT Panel</title>
  <style>
    :root{--bg:#0F1923;--card:#1A2735;--text:#E8EDF2;--text-sec:#7B8D9E;--accent:#00D4FF;--grad1:#00D4FF;--grad2:#0066FF;--green:#00E676;--red:#FF5252;--orange:#FFB74D;--border:rgba(0,212,255,.12);--shadow:0 4px 24px rgba(0,0,0,.4)}
    @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:'Inter',-apple-system,BlinkMacSystemFont,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
    .container{max-width:520px;margin:0 auto;padding:16px}
    .header{text-align:center;padding:20px 0 12px}
    .header h1{font-size:28px;font-weight:800;background:linear-gradient(135deg,var(--grad1),var(--grad2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:1px}
    .header .version{font-size:11px;color:var(--text-sec);margin-top:4px}
    .card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:20px;margin-bottom:14px;box-shadow:var(--shadow)}
    h3{margin:0 0 14px;font-weight:700;font-size:14px;color:var(--text-sec);text-transform:uppercase;letter-spacing:.8px}
    .active-card{background:linear-gradient(135deg,#0066FF 0%,#00D4FF 100%);border:none;text-align:center;color:#fff;position:relative;overflow:hidden}
    .active-card::before{content:'';position:absolute;top:-50%;left:-50%;width:200%;height:200%;background:radial-gradient(circle,rgba(255,255,255,.06) 0%,transparent 70%);animation:pulse 4s ease-in-out infinite;pointer-events:none}
    @keyframes pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.05)}}
    .active-card h3{color:rgba(255,255,255,.7)}
    .server-big{font-size:18px;font-weight:800;margin:8px 0 4px;display:block;word-break:break-word}
    .server-meta{color:rgba(255,255,255,.75);font-size:12px}
    .status-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;vertical-align:middle}
    .status-dot.on{background:var(--green);box-shadow:0 0 8px var(--green)}
    .status-dot.off{background:var(--red);box-shadow:0 0 8px var(--red)}
    .btn{border:none;border-radius:12px;font-weight:700;font-size:13px;cursor:pointer;transition:all .15s;outline:none}
    .btn-primary{background:linear-gradient(135deg,var(--grad1),var(--grad2));color:#fff;padding:10px 18px}
    .btn-primary:active{transform:scale(.97)}
    .btn-outline{background:rgba(0,212,255,.08);border:1px solid rgba(0,212,255,.25);color:var(--accent);padding:8px 14px;font-size:12px}
    .btn-outline:active{background:rgba(0,212,255,.15)}
    .btn-danger{background:rgba(255,82,82,.1);border:1px solid rgba(255,82,82,.25);color:var(--red);padding:6px 12px;font-size:11px}
    .btn-active{background:linear-gradient(135deg,var(--green),#00C853);color:#fff;padding:8px 14px;font-size:12px;border:none}
    .btn-full{width:100%;padding:12px;margin-top:12px;font-size:14px}
    .list-row{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:12px 0;border-bottom:1px solid var(--border)}
    .list-row:last-child{border-bottom:none;padding-bottom:0}
    .node-info{flex:1;min-width:0}
    .item-name{font-weight:600;font-size:13px;color:var(--text);display:block;word-break:break-word}
    .item-sub{display:block;font-size:11px;color:var(--text-sec);margin-top:2px}
    .transport-badge{display:inline-block;font-size:9px;font-weight:800;padding:2px 6px;border-radius:6px;margin-left:6px;vertical-align:middle}
    .badge-tcp{background:rgba(0,212,255,.12);color:var(--accent)}
    .badge-grpc{background:rgba(255,183,77,.12);color:var(--orange)}
    .badge-xhttp{background:rgba(255,82,82,.12);color:var(--red);text-decoration:line-through}
    .badge-ws{background:rgba(156,39,176,.12);color:#CE93D8}
    .ping-text{font-size:10px;color:var(--text-sec);margin-top:1px;display:block}
    .ping-ok{color:var(--green)}
    .ping-bad{color:var(--red)}
    .sub-info{font-size:11px;color:rgba(255,255,255,.6);margin-top:4px;display:block}
    .input-group{display:flex;gap:8px;margin-top:12px}
    input[type=text]{background:rgba(255,255,255,.05);border:1px solid var(--border);color:var(--text);padding:10px 12px;border-radius:10px;width:100%;font-size:12px;font-family:inherit;outline:none}
    input[type=text]:focus{border-color:var(--accent)}
    input[type=text]::placeholder{color:var(--text-sec)}
    .preloader-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.7);backdrop-filter:blur(8px);z-index:9999;display:none;justify-content:center;align-items:center}
    .spinner{width:44px;height:44px;border:3px solid rgba(0,212,255,.15);border-top:3px solid var(--accent);border-radius:50%;animation:spin .8s linear infinite}
    @keyframes spin{0%{transform:rotate(0)}100%{transform:rotate(360deg)}}
    .toast{display:none;position:fixed;left:12px;right:12px;bottom:12px;padding:12px 16px;border-radius:12px;background:var(--card);border:1px solid var(--border);color:var(--text);z-index:10000;font-size:12px;box-shadow:0 8px 32px rgba(0,0,0,.5)}
    .logs-modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.8);backdrop-filter:blur(8px);z-index:9998;overflow-y:auto}
    .logs-content{max-width:560px;margin:40px auto;padding:20px;background:var(--card);border-radius:16px;border:1px solid var(--border)}
    .logs-text{font-family:'Courier New',monospace;font-size:11px;line-height:1.6;color:var(--green);background:rgba(0,0,0,.3);padding:12px;border-radius:8px;max-height:60vh;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
    .logs-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}
    .hwid-block{font-size:11px;color:var(--text-sec);padding:8px 12px;background:rgba(0,0,0,.2);border-radius:8px;margin-top:8px;word-break:break-all}
    .hwid-block b{color:var(--accent)}
    .empty-state{text-align:center;padding:20px 0;color:var(--text-sec);font-size:13px}
    .node-actions{flex-shrink:0}
  </style>
</head>
<body>
  <div id="preloader" class="preloader-overlay"><div class="spinner"></div></div>
  <div id="toast" class="toast"></div>
  <div id="logsModal" class="logs-modal" onclick="if(event.target===this)closeLogs()">
    <div class="logs-content">
      <div class="logs-header">
        <h3 style="margin:0">📋 Логи Podkop</h3>
        <button class="btn btn-outline" onclick="closeLogs()">Закрыть</button>
      </div>
      <div>
        <button class="btn btn-outline" onclick="loadLogs()" style="margin-bottom:10px">🔄 Обновить</button>
        <button class="btn btn-outline" onclick="loadLogs(200)" style="margin-bottom:10px;margin-left:6px">Больше</button>
      </div>
      <div id="logs_text" class="logs-text">Загрузка...</div>
    </div>
  </div>
  <div class="container">
    <header class="header">
      <h1>⚡ RIFT</h1>
      <div class="version" id="ver_line">...</div>
    </header>
    <div class="card active-card">
      <h3>АКТИВНОЕ ПОДКЛЮЧЕНИЕ</h3>
      <span id="status_indicator"></span>
      <span class="server-big" id="active_name">...</span>
      <span class="server-meta" id="sub_meta">...</span>
      <button class="btn btn-full" style="background:rgba(255,255,255,.18);color:#fff;border:1px solid rgba(255,255,255,.2)" onclick="updateSubs()">🔄 Обновить подписку</button>
    </div>
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center">
        <h3>🌐 Серверы</h3>
        <button class="btn btn-outline" onclick="pingAll()" style="font-size:11px;padding:4px 10px" id="pingBtn">📶 Пинг</button>
      </div>
      <div id="nodes_list"></div>
      <div class="input-group">
        <input type="text" id="sub_url" placeholder="Ссылка на подписку...">
        <button class="btn btn-primary" onclick="saveUrl()">💾</button>
      </div>
    </div>
    <div class="card">
      <h3>🔒 VPN для устройства</h3>
      <div class="input-group">
        <input type="text" id="manual_ip" placeholder="IP (192.168.1.X)">
        <button class="btn btn-primary" onclick="addManualIp()">+</button>
      </div>
      <div id="vpn_list" style="margin-top:10px"></div>
    </div>
    <div class="card">
      <h3>🎯 Домены через VPN</h3>
      <div class="input-group">
        <input type="text" id="new_domain" placeholder="domain.com">
        <button class="btn btn-primary" onclick="addDomain()">+</button>
      </div>
      <div id="domains_list" style="margin-top:10px"></div>
    </div>
    <div class="card">
      <h3>ℹ️ Устройство</h3>
      <div id="hwid_info" class="hwid-block">Загрузка...</div>
    </div>
    <div class="card" style="text-align:center">
      <button class="btn btn-outline" onclick="openLogs()" style="margin:4px">📋 Логи</button>
      <button class="btn btn-outline" onclick="checkForUpdates()" style="margin:4px">⬆️ Обновить панель</button>
    </div>
  </div>
<script>
  function esc(s){let d=document.createElement('div');d.textContent=s;return d.innerHTML;}
  function normalizeUrl(url){return(url||"").replace(/#.*$/,'');}
  let globalNodes=[],activeUrl="",vpnIps=[],domains=[],pingData={};
  function showToast(msg,ms=6000){const el=document.getElementById('toast');el.textContent=msg;el.style.display='block';clearTimeout(window.__t);window.__t=setTimeout(()=>{el.style.display='none';},ms);}
  function showLoader(){document.getElementById('preloader').style.display='flex';}
  function hideLoader(){document.getElementById('preloader').style.display='none';}
  async function api(method,params={}){
    params.method=method;
    const qs=Object.keys(params).map(k=>k+'='+encodeURIComponent(params[k])).join('&');
    const resp=await fetch('/cgi-bin/rpc?'+qs,{cache:'no-store'});
    const text=await resp.text();
    let data;
    try{data=JSON.parse(text);}catch(e){throw new Error("RPC: "+text.slice(0,160));}
    if(data&&data.status==="error") throw new Error(data.msg||"Ошибка");
    return data;
  }
  window.onload=async function(){
    try{const r=await api('get_sub_url');if(r.url)document.getElementById('sub_url').value=r.url;}catch(e){}
    try{const r=await api('get_panel_info');if(r.version)document.getElementById('ver_line').textContent='v'+r.version+' • '+(r.device_model||'');}catch(e){}
    try{const r=await api('get_hwid_info');document.getElementById('hwid_info').innerHTML='<b>HWID:</b> '+(r.hwid||'?')+'<br><b>OS:</b> '+(r.os_type||'')+' '+(r.os_version||'')+'<br><b>Модель:</b> '+(r.device_model||'?');}catch(e){}
    await loadData();await loadNetwork();
  };
  async function loadData(){
    try{
      const d=await api('get_nodes');
      globalNodes=Array.isArray(d.nodes)?d.nodes:[];
      activeUrl=d.active_url||"";
      let metaParts=[];if(d.updated)metaParts.push('Обновлено: '+d.updated);if(d.sub_expire)metaParts.push('⏳ '+d.sub_expire);if(d.sub_traffic)metaParts.push('📊 '+d.sub_traffic);document.getElementById('sub_meta').innerText=metaParts.join(' • ')||'Нет данных';
      const running=d.running;
      document.getElementById('status_indicator').innerHTML='<span class="status-dot '+(running?'on':'off')+'"></span>';
      let an="Нет подключения";
      if(activeUrl&&globalNodes.length){
        const norm=normalizeUrl(activeUrl.trim());
        const n=globalNodes.find(x=>normalizeUrl((x.full_url||"").trim())===norm);
        if(n)an=n.name;
        else{const m=activeUrl.match(/#(.+)$/);if(m)an=decodeURIComponent(m[1]);}
      }
      document.getElementById('active_name').innerText=an;
      renderNodes();
    }catch(e){showToast("loadData: "+e.message);}
  }
  function getBadge(t){switch((t||'').toLowerCase()){case 'grpc':return 'badge-grpc';case 'xhttp':case 'splithttp':return 'badge-xhttp';case 'ws':return 'badge-ws';default:return 'badge-tcp';}}
  function renderNodes(){
    const div=document.getElementById("nodes_list");
    if(!globalNodes.length){div.innerHTML='<div class="empty-state">Список пуст — добавьте подписку</div>';return;}
    let h="";const normA=normalizeUrl((activeUrl||"").trim());
    globalNodes.forEach((n,i)=>{
      const isA=normalizeUrl((n.full_url||"").trim())===normA;
      const tl=n.transport_label||(n.transport||'tcp').toUpperCase();
      const isXhttp=n.unsupported||((n.transport||'').toLowerCase()==='xhttp');
      const badge=`<span class="transport-badge ${getBadge(n.transport)}">${esc(tl)}${isXhttp?' ⚠️':''}</span>`;
      let btn;
      if(isA) btn='<button class="btn btn-active">✓ Активен</button>';
      else if(isXhttp) btn='<button class="btn btn-danger" title="sing-box не поддерживает XHTTP" disabled>⚠️</button>';
      else btn=`<button class="btn btn-outline" onclick="connect(${i})">Подключить</button>`;
      const p=pingData[n.host];
      const pingHtml=p?`<span class="ping-text ${p==='timeout'?'ping-bad':'ping-ok'}">${p}</span>`:'';
      h+=`<div class="list-row"><div class="node-info"><span class="item-name">${esc(n.name||"Server")}${badge}</span><span class="item-sub">${esc(n.host||"")}${pingHtml}</span></div><div class="node-actions">${btn}</div></div>`;
    });
    div.innerHTML=h;
  }
  async function updateSubs(){showLoader();try{const r=await api('update_subs',{});showToast(`✅ Обновлено: ${r.count||"?"} серверов`);await loadData();}catch(e){showToast("❌ "+e.message,10000);}finally{hideLoader();}}
  async function saveUrl(){const u=document.getElementById('sub_url').value;if(!u)return;showLoader();try{const r=await api('update_subs',{url:u});showToast(`✅ Сохранено: ${r.count||"?"} серверов`);await loadData();}catch(e){showToast("❌ "+e.message,10000);}finally{hideLoader();}}
  async function connect(i){
    const n=globalNodes[i];
    if(n.unsupported||((n.transport||'').toLowerCase()==='xhttp')){showToast('⚠️ XHTTP не поддерживается sing-box. Используйте gRPC или TCP.',8000);return;}
    if(!confirm(`Подключиться к ${n.name}?`))return;
    showLoader();try{await api('apply',{node_url:n.full_url});await new Promise(r=>setTimeout(r,2500));await loadData();}catch(e){showToast("❌ "+e.message,10000);}finally{hideLoader();}}
  async function pingAll(){
    const btn=document.getElementById('pingBtn');btn.textContent='⏳...';btn.disabled=true;
    try{const r=await api('ping_all');if(r.pings){pingData=r.pings;renderNodes();showToast('📶 Пинг обновлён');}}catch(e){showToast('Ping: '+e.message);}
    finally{btn.textContent='📶 Пинг';btn.disabled=false;}
  }
  async function loadNetwork(){
    try{
      const d=await api('get_network');const c=d.clients||[];vpnIps=Array.isArray(d.vpn_ips)?d.vpn_ips:[];domains=Array.isArray(d.domains)?d.domains:[];
      let vh="";c.forEach(x=>{const iv=vpnIps.includes(x.ip);vh+=`<div class="list-row"><div class="node-info"><span class="item-name">${esc(x.name)}</span><span class="item-sub">${esc(x.ip)}</span></div><div class="node-actions">${iv?`<button class="btn btn-active" onclick="toggleVpn('${x.ip}','del')">✓ VPN</button>`:`<button class="btn btn-outline" onclick="toggleVpn('${x.ip}','add')">Включить</button>`}</div></div>`;});
      document.getElementById("vpn_list").innerHTML=vh||'<div class="empty-state">Нет устройств</div>';
      let dh="";domains.forEach(dom=>{dh+=`<div class="list-row"><div class="node-info"><span class="item-name">${esc(dom)}</span></div><div class="node-actions"><button class="btn btn-danger" onclick="manageDomain('${dom}','del')">✕</button></div></div>`;});
      document.getElementById('domains_list').innerHTML=dh||'<div class="empty-state">Список пуст</div>';
    }catch(e){showToast("Network: "+e.message);}
  }
  async function toggleVpn(ip,a){showLoader();try{await api('manage_vpn',{ip,action:a});await new Promise(r=>setTimeout(r,2000));await loadNetwork();}catch(e){showToast("VPN: "+e.message);}finally{hideLoader();}}
  function addManualIp(){const ip=document.getElementById('manual_ip').value;if(ip)toggleVpn(ip,'add');document.getElementById('manual_ip').value="";}
  async function manageDomain(d,a){showLoader();try{await api('manage_domain',{domain:d,action:a});await new Promise(r=>setTimeout(r,2000));await loadNetwork();}catch(e){showToast("Domain: "+e.message);}finally{hideLoader();}}
  function addDomain(){const d=document.getElementById('new_domain').value;if(d)manageDomain(d,'add');document.getElementById('new_domain').value="";}
  function openLogs(){document.getElementById('logsModal').style.display='block';loadLogs();}
  function closeLogs(){document.getElementById('logsModal').style.display='none';}
  async function loadLogs(lines){try{const r=await api('get_logs',{lines:lines||50});const el=document.getElementById('logs_text');el.textContent=r.logs||"Логи пусты";el.scrollTop=el.scrollHeight;}catch(e){document.getElementById('logs_text').textContent="Ошибка: "+e.message;}}
  async function checkForUpdates(){showLoader();try{const r=await api('check_for_update');if(r.status==='update_available'){if(confirm(`Доступна v${r.remote_v} (у вас ${r.local_v}). Обновить?`)){await api('perform_update');await new Promise(r=>setTimeout(r,4000));location.reload();}}else showToast(`✅ Последняя версия (${r.local_v}).`);}catch(e){showToast('Updates: '+e.message);}finally{hideLoader();}}
</script>
</body>
</html>
EOF

# 8) Auto-update subscription (every 5 min)
echo "[8/9] Настройка автообновления..."
cat <<'AEOF' > /etc/podkop_data/autoupdate_sub.sh
#!/bin/sh
URL="$(uci -q get podkop_subs.config.url)"
[ -z "$URL" ] && exit 0
HWID="$(cat /etc/podkop_data/hwid 2>/dev/null)"
MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo 'OpenWrt')"
OSVER="$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d"'" -f2)"
BODY="/tmp/podkop_sub_auto.body"
ERR="/tmp/podkop_sub_auto.err"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -q -O "$BODY" --header="User-Agent: v2rayNG/1.8.19" --header="x-hwid: $HWID" --header="x-device-os: OpenWRT" --header="x-ver-os: $OSVER" --header="x-device-model: $MODEL" "$URL" 2>"$ERR" || { rm -f "$BODY" "$ERR"; exit 0; }
else
  wget -q -T 25 -U "v2rayNG/1.8.19" --header="x-hwid: $HWID" --header="x-device-os: OpenWRT" --header="x-ver-os: $OSVER" --header="x-device-model: $MODEL" -O "$BODY" "$URL" 2>"$ERR" || { rm -f "$BODY" "$ERR"; exit 0; }
fi
RAW="$(cat "$BODY" 2>/dev/null)"; [ -z "$RAW" ] && { rm -f "$BODY" "$ERR"; exit 0; }
DECODED=""
if ! echo "$RAW" | grep -q "://"; then
  SAFE="$(echo "$RAW" | tr -d '\n\r\t ' | sed 's/-/+/g;s/_/\//g')"
  PAD=$(( (4 - ${#SAFE} % 4) % 4 )); while [ "$PAD" -gt 0 ]; do SAFE="${SAFE}="; PAD=$((PAD-1)); done
  DECODED="$(printf '%s' "$SAFE" | base64 -d 2>/dev/null)"
fi
TEXT="${DECODED:-$RAW}"
echo "$TEXT" | grep -q "://" || { rm -f "$BODY" "$ERR"; exit 0; }
COUNT=$(echo "$TEXT" | grep -c "://")
lua -e "
local text=[=[$TEXT]=]
local nodes,seen={},{}
for line in text:gmatch('[^\n\r]+') do
  line=line:match('^%s*(.-)%s*$')
  local proto=line:match('^(%w+)://')
  if proto then
    local key=line:match('^([^#]+)') or line
    if not seen[key] then
      seen[key]=true
      local ne=line:match('#(.+)$')
      local name='Server'
      if ne then name=ne:gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end) end
      -- skip phone-only and xhttp entries
      local _transport = line:match('[?&]type=([^&#]*)') or 'tcp'
      if not name:lower():find('обход бс') and not name:find('📱') and _transport ~= 'xhttp' and _transport ~= 'splithttp' then
        local host=line:match('@(.-)[:?]') or line:match('://([^/:#?]+)') or 'unknown'
        local transport=line:match('[?&]type=([^&#]*)') or 'tcp'
        local security=line:match('[?&]security=([^&#]*)') or ''
        local tl=transport:upper()
        if transport=='grpc' then tl='gRPC' elseif transport=='xhttp' then tl='XHTTP' end
        local ti=proto:upper(); if security=='reality' then ti='Reality' end
        nodes[#nodes+1]={name=name,host=host,type=ti,transport=transport,transport_label=tl,security=security,
          service_name=line:match('[?&]serviceName=([^&#]*)') or '',path=line:match('[?&]path=([^&#]*)') or '',
          mode=line:match('[?&]mode=([^&#]*)') or '',flow=line:match('[?&]flow=([^&#]*)') or '',full_url=line}
      end
    end
  end
end
local function ser(v)
  local t=type(v)
  if t=='table' then local p={};for k,vv in pairs(v) do p[#p+1]=(type(k)=='number' and '' or ('[\"'..k..'\"]='  ))..ser(vv) end;return '{'..table.concat(p,',')..'}'
  elseif t=='string' then return string.format('%q',v)
  else return tostring(v) end
end
local db={expire='Нет данных',updated=os.date('%Y-%m-%d %H:%M:%S'),nodes=nodes}
local f=io.open('/etc/podkop_data/nodes.lua','w')
if f then f:write('return '..ser(db)); f:close() end
" 2>/dev/null
rm -f "$BODY" "$ERR"
logger -t "rift-panel" "Subscription updated: $COUNT nodes"
AEOF
chmod +x /etc/podkop_data/autoupdate_sub.sh

# Panel auto-update (daily)
cat <<'PEOF' > /etc/podkop_data/autoupdate_panel.sh
#!/bin/sh
TMP="/tmp/rift_remote.sh"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -q -O "$TMP" "https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/riftdev.sh" 2>/dev/null || { rm -f "$TMP"; exit 0; }
else
  wget -q -O "$TMP" "https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/riftdev.sh" 2>/dev/null || { rm -f "$TMP"; exit 0; }
fi
LOCAL_V="$(cat /etc/podkop_data/version 2>/dev/null)"
REMOTE_V="$(sed -n 's/^PANEL_VERSION="\([^"]*\)".*/\1/p' "$TMP" | head -1)"
[ -n "$REMOTE_V" ] && [ -n "$LOCAL_V" ] && [ "$REMOTE_V" != "$LOCAL_V" ] && sh "$TMP" >/dev/null 2>&1
rm -f "$TMP"
PEOF
chmod +x /etc/podkop_data/autoupdate_panel.sh

# 9) cron
echo "[9/9] Настройка cron..."
(crontab -l 2>/dev/null | grep -Fv "autoupdate_sub" | grep -Fv "autoupdate_panel" | grep -Fv "/etc/podkop_data/") | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * * /etc/podkop_data/autoupdate_sub.sh"; echo "13 4 * * * /etc/podkop_data/autoupdate_panel.sh") | crontab -

# finish
chmod +x /www/podkop_panel/cgi-bin/rpc
sed -i 's/\r$//' /www/podkop_panel/cgi-bin/rpc
/etc/init.d/uhttpd enable >/dev/null 2>&1
/etc/init.d/uhttpd restart >/dev/null 2>&1
/etc/init.d/dnsmasq restart >/dev/null 2>&1

ROUTER_IP="$(uci -q get network.lan.ipaddr)"
[ -z "$ROUTER_IP" ] && ROUTER_IP="192.168.1.1"
echo "================================================="
echo "ГОТОВО! RIFT Panel v${PANEL_VERSION}"
echo "Доступ: http://${ROUTER_IP}:2017"
echo "HWID: $(cat /etc/podkop_data/hwid 2>/dev/null)"
echo "Авто-обновление подписки: каждые 5 минут"
echo "================================================="
