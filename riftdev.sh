#!/bin/sh
# === RIFT PANEL INSTALLER & UPDATER (V3.0 — Remnawave + HWID + UI/UX) ===
# Run: wget -O - https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh | sh

PANEL_VERSION="3.1"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/riftdev.sh"

echo "=== УСТАНОВКА RIFT PANEL v${PANEL_VERSION} ==="

# 1) deps
echo "[1/8] Установка пакетов..."
opkg update >/dev/null 2>&1
opkg install ca-bundle coreutils-base64 lua uclient-fetch >/dev/null 2>&1 || true

# 2) structure
echo "[2/8] Настройка системы..."
mkdir -p /www/podkop_panel/cgi-bin
mkdir -p /etc/podkop_data
touch /etc/config/podkop_subs
if [ ! -s /etc/config/podkop_subs ]; then
  echo "config podkop_subs 'config'" > /etc/config/podkop_subs
fi
echo "${PANEL_VERSION}" > /etc/podkop_data/version

# 3) Generate HWID
echo "[3/8] Генерация HWID..."
if [ ! -f /etc/podkop_data/hwid ]; then
  MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo "00:00:00:00:00:00")
  HWID="RIFT-$(echo -n "$MAC" | md5sum | cut -c1-27)"
  echo "$HWID" > /etc/podkop_data/hwid
fi

# 4) uhttpd
echo "[4/8] Настройка веб-сервера (порт 2017)..."
uci -q delete uhttpd.podkop_panel
uci set uhttpd.podkop_panel=uhttpd
uci add_list uhttpd.podkop_panel.listen_http='0.0.0.0:2017'
uci set uhttpd.podkop_panel.home='/www/podkop_panel'
uci set uhttpd.podkop_panel.rfc1918_filter='0'
uci set uhttpd.podkop_panel.max_requests='10'
uci set uhttpd.podkop_panel.cgi_prefix='/cgi-bin'
uci commit uhttpd >/dev/null 2>&1

# 5) remove rift domain
echo "[5/8] Удаление домена rift (если был ранее)..."
for s in $(uci show dhcp 2>/dev/null | sed -n "s/^\(dhcp\.@domain\[[0-9]\+\]\)=domain.*/\1/p"); do
  [ "$(uci -q get ${s}.name)" = "rift" ] && uci delete "$s"
done
uci -q del_list dhcp.@dnsmasq[0].rebind_domain='rift'
uci commit dhcp >/dev/null 2>&1

# 6) Backend (RPC)
echo "[6/8] Запись Backend скрипта..."
cat <<'BACKEND_EOF' > /www/podkop_panel/cgi-bin/rpc
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
      local key=(type(k)=="number") and "" or ('["'..k..'"]=' )
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

local function fetch_to_file(url, out, err, headers)
  exec_silent("rm -f "..out.." "..err)
  local cmd
  if HAS_UCLIENT then
    cmd = "uclient-fetch -q -O "..out
    if headers then
      for _,h in ipairs(headers) do
        cmd = cmd.." --header="..shq(h)
      end
    end
    cmd = cmd.." "..shq(url).." 2>"..err
  else
    cmd = "wget -q -T 25 -O "..out
    if headers then
      for _,h in ipairs(headers) do
        cmd = cmd.." --header="..shq(h)
      end
    end
    cmd = cmd.." "..shq(url).." 2>"..err
  end
  local rc = os.execute(cmd)
  return (rc==0) or (rc==true)
end

-- HWID helpers
local function get_hwid()
  local f=io.open("/etc/podkop_data/hwid","r")
  if f then local h=trim(f:read("*a")) f:close() return h end
  return "RIFT-unknown"
end

local function get_remnawave_headers()
  local hwid = get_hwid()
  local osver = exec_read("grep 'DISTRIB_RELEASE' /etc/openwrt_release 2>/dev/null | cut -d\"'\" -f2")
  if osver == "" then osver = exec_read("uname -r") end
  local model = exec_read("cat /tmp/sysinfo/model 2>/dev/null")
  if model == "" then model = "OpenWrt Router" end
  return {
    "x-hwid: "..hwid,
    "x-device-os: OpenWrt",
    "x-ver-os: "..(osver ~= "" and osver or "unknown"),
    "x-device-model: "..model,
    "User-Agent: RIFT-Panel/"..trim(exec_read("cat /etc/podkop_data/version 2>/dev/null") or "3.0")
  }
end

-- parse query string
local qs=os.getenv("QUERY_STRING") or ""
local params={}
for k,v in string.gmatch(qs,"([^&=]+)=([^&=]*)") do
  params[k]=v:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end)
end
local method=params.method

print("Content-type: application/json; charset=utf-8\n")

local REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"

-- link parsing (line-by-line to preserve names with spaces)
local PROTOCOLS={"vless://","trojan://","ss://","vmess://","hysteria2://","tuic://"}
local function extract_links(text)
  local out={}
  if not text then return out end
  for line in (text.."\n"):gmatch("([^\n]+)") do
    line=trim(line)
    if line~="" then
      for _,proto in ipairs(PROTOCOLS) do
        if line:sub(1,#proto)==proto then
          out[#out+1]=line
          break
        end
      end
    end
  end
  return out
end

-- safe URL-decode: only decode %XX where XX are valid hex pairs
local function url_decode_safe(s)
  if not s then return "" end
  return s:gsub("%%(%x%x)",function(h) return string.char(tonumber(h,16)) end)
end

local FILTER_KEYWORDS={"Обход БС","обход бс"}
local function should_filter(name)
  for _,kw in ipairs(FILTER_KEYWORDS) do
    if name:find(kw,1,true) then return true end
  end
  return false
end

local function link_to_node(line)
  local proto=(line:match("^(%w+)://") or "LINK"):upper()
  local ne=line:match("#(.+)$")
  local name="Server"
  if ne then name=url_decode_safe(ne) end
  local host=line:match("@(.-):" ) or line:match("://([^/:#%?]+)") or "unknown"
  local ti=proto
  if line:match("security=reality") then ti="Reality" end
  return {name=name, host=host, type=ti, full_url=line}
end

local function parse_nodes_any(text)
  local nodes={}
  local seen={}
  local links=extract_links(text or "")
  for _,u in ipairs(links) do
    local n=link_to_node(u)
    if not should_filter(n.name) and not seen[n.host] then
      seen[n.host]=true
      nodes[#nodes+1]=n
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

-- RPC methods

if method=="get_panel_info" then
  local f=io.open("/etc/podkop_data/version","r")
  local v=f and f:read("*a") or "0.0"
  if f then f:close() end
  print(to_json({version=trim(v)}))
  os.exit(0)
end

if method=="get_hwid" then
  local hwid = get_hwid()
  local osver = exec_read("grep 'DISTRIB_RELEASE' /etc/openwrt_release 2>/dev/null | cut -d\"'\" -f2")
  local model = exec_read("cat /tmp/sysinfo/model 2>/dev/null")
  if model == "" then model = "OpenWrt Router" end
  print(to_json({hwid=hwid, device_os="OpenWrt", os_version=osver, device_model=model}))
  os.exit(0)
end

if method=="get_traffic" then
  local nft_out = exec_read("nft list table inet PodkopTable 2>/dev/null | grep 'counter packets' | head -4")
  local total_packets, total_bytes = 0, 0
  for p, b in nft_out:gmatch("counter packets (%d+) bytes (%d+)") do
    total_packets = total_packets + tonumber(p)
    total_bytes = total_bytes + tonumber(b)
  end
  local uptime = exec_read("cat /proc/uptime 2>/dev/null | awk '{print $1}'")
  print(to_json({packets=total_packets, bytes=total_bytes, uptime=tonumber(uptime) or 0}))
  os.exit(0)
end

if method=="get_system" then
  local meminfo = exec_read("cat /proc/meminfo 2>/dev/null")
  local mem_total = tonumber(meminfo:match("MemTotal:%s*(%d+)")) or 0
  local mem_free = tonumber(meminfo:match("MemFree:%s*(%d+)")) or 0
  local mem_avail = tonumber(meminfo:match("MemAvailable:%s*(%d+)")) or mem_free
  local uptime = tonumber(exec_read("cat /proc/uptime | awk '{print $1}'")) or 0
  local model = exec_read("cat /tmp/sysinfo/model 2>/dev/null")
  print(to_json({mem_total=mem_total, mem_available=mem_avail, uptime=uptime, model=model}))
  os.exit(0)
end

if method=="check_for_update" then
  local tmp="/tmp/rift_remote.sh"
  local err="/tmp/rift_remote.err"
  local ok = fetch_to_file(REMOTE_SCRIPT_URL, tmp, err)
  if not ok then
    print(to_json({status="error", msg="Не удалось скачать обновление"}))
    os.exit(0)
  end
  local remote_script = exec_read("cat "..tmp.." 2>/dev/null")
  local remote_version = remote_script:match('PANEL_VERSION="([%d%.]+)"')
  local f=io.open("/etc/podkop_data/version","r")
  local local_version=f and trim(f:read("*a")) or "0.0"
  if f then f:close() end
  if remote_version and local_version then
    if cmp_ver(remote_version, local_version)==1 then
      print(to_json({status="update_available",local_v=local_version,remote_v=remote_version}))
    else
      print(to_json({status="up_to_date",local_v=local_version,remote_v=remote_version}))
    end
  else
    print(to_json({status="error", msg="Не удалось распарсить версию"}))
  end
  os.exit(0)
end

if method=="perform_update" then
  local tmp="/tmp/rift_update.sh"
  local err="/tmp/rift_update.err"
  local ok = fetch_to_file(REMOTE_SCRIPT_URL, tmp, err)
  if not ok then
    print(to_json({status="error", msg="Не удалось скачать скрипт обновления"}))
    os.exit(0)
  end
  exec_silent("sh "..tmp)
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
  local hdrs = get_remnawave_headers()
  local ok = fetch_to_file(url, body, err, hdrs)
  local raw = exec_read("cat "..body.." 2>/dev/null")
  local e   = exec_read("cat "..err.." 2>/dev/null")

  if (not ok) or raw=="" then
    local sample = (e ~= "" and e:gsub("\n"," "):sub(1,220)) or "empty body"
    print(to_json({status="error", msg="Ошибка загрузки подписки", sample=sample}))
    os.exit(0)
  end

  local nodes = parse_nodes_any(raw)
  local decoded = ""
  if #nodes == 0 then
    decoded = try_decode_base64(raw)
    if decoded ~= "" then
      nodes = parse_nodes_any(decoded)
    end
  end

  if #nodes == 0 then
    local s1 = raw:gsub("\n"," "):sub(1,180)
    local s2 = (decoded ~= "" and decoded:gsub("\n"," "):sub(1,180)) or ""
    local extra = (s2 ~= "" and (" | decoded: "..s2)) or ""
    print(to_json({status="error", msg="Серверы не найдены", sample=("raw: "..s1..extra)}))
    os.exit(0)
  end

  local db={expire="Нет данных", updated=os.date("%Y-%m-%d %H:%M:%S"), nodes=nodes}
  local f=io.open("/etc/podkop_data/nodes.lua","w")
  if f then
    f:write("return "..serialize(db))
    f:close()
    print(to_json({status="ok", count=#nodes, expire=db.expire}))
  else
    print('{"status":"error","msg":"Ошибка записи nodes.lua"}')
  end
  os.exit(0)
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
    local res=exec_silent("ping -c 1 -W 1 "..host)
    local ms="timeout"
    local s="fail"
    local rb=(res==0)or(res==true)
    if rb then
      local out=exec_read("ping -c 1 -W 1 "..host.." | grep 'seq=0'")
      local val=out:match("time=([%d%.]+)")
      if val then ms=math.floor(tonumber(val)).." ms" end
      s="ok"
    end
    print(to_json({status=s,time=ms}))
  else
    print('{"status":"error","msg":"Некорректный host"}')
  end
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
  local rl=exec_read("uci -q get podkop.main.fully_routed_ips")
  for w in (rl or ""):gmatch("%S+") do vl[#vl+1]=w end
  local dl={}
  local rd=exec_read("uci -q get podkop.main.user_domains")
  for w in (rd or ""):gmatch("%S+") do dl[#dl+1]=w end
  print(to_json({clients=c,vpn_ips=vl,domains=dl}))
  os.exit(0)
end

if method=="manage_vpn" then
  local ip=params.ip
  local a=params.action
  if ip and a and ip:match("^%d+%.%d+%.%d+%.%d+$") then
    if a=="add" then exec_silent("uci add_list podkop.main.fully_routed_ips="..shq(ip))
    elseif a=="del" then exec_silent("uci del_list podkop.main.fully_routed_ips="..shq(ip)) end
    exec_silent("uci commit podkop")
    exec_silent("/etc/init.d/podkop restart")
    print('{"status":"ok"}')
  else
    print('{"status":"error","msg":"Некорректный ip/action"}')
  end
  os.exit(0)
end

if method=="manage_domain" then
  local d=params.domain
  local a=params.action
  if d and a and d:match("^[a-zA-Z0-9%.%-]+$") then
    if a=="add" then
      exec_silent("uci set podkop.main.user_domain_list_type='dynamic'")
      exec_silent("uci add_list podkop.main.user_domains="..shq(d))
    elseif a=="del" then
      exec_silent("uci del_list podkop.main.user_domains="..shq(d))
    end
    exec_silent("uci commit podkop")
    exec_silent("/etc/init.d/podkop restart")
    print('{"status":"ok"}')
  else
    print('{"status":"error","msg":"Некорректный domain/action"}')
  end
  os.exit(0)
end

if method=="get_sub_url" then
  local u=uci_get("podkop_subs","config","url")
  print(to_json({url=u}))
  os.exit(0)
end

print('{"status":"error","msg":"unknown method"}')
BACKEND_EOF

# Mark as next step
echo "[6/8] Backend готов. Записываю Frontend..."
cat <<'FRONTEND_EOF' > /www/podkop_panel/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>RIFT Panel</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
  <style>
:root{--bg:#0a0e1a;--card:rgba(255,255,255,.06);--card-border:rgba(255,255,255,.08);--text:#e8ecf4;--text-dim:rgba(255,255,255,.5);--grad-start:#0068FF;--grad-end:#85D9FE;--green:#34d399;--yellow:#fbbf24;--red:#f87171;--glass:rgba(255,255,255,.04)}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Inter',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;padding:16px 16px 80px}
.container{max-width:480px;margin:0 auto}
.header{text-align:center;padding:20px 0 16px}
.header h1{font-size:28px;font-weight:800;background:linear-gradient(135deg,var(--grad-start),var(--grad-end));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:1px}
.header .ver{font-size:11px;color:var(--text-dim);margin-top:2px}
.card{background:var(--card);border:1px solid var(--card-border);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);border-radius:20px;padding:20px;margin-bottom:14px;animation:fadeUp .5s ease both}
.card:nth-child(2){animation-delay:.05s}.card:nth-child(3){animation-delay:.1s}.card:nth-child(4){animation-delay:.15s}.card:nth-child(5){animation-delay:.2s}.card:nth-child(6){animation-delay:.25s}
@keyframes fadeUp{from{opacity:0;transform:translateY(16px)}to{opacity:1;transform:translateY(0)}}
h3{font-size:13px;font-weight:700;color:var(--text-dim);letter-spacing:.8px;text-transform:uppercase;margin-bottom:14px}
.hero{background:linear-gradient(135deg,var(--grad-start),var(--grad-end));border:none;color:#fff;text-align:center;padding:24px 20px;position:relative;overflow:hidden}
.hero::after{content:'';position:absolute;top:-50%;left:-50%;width:200%;height:200%;background:radial-gradient(circle,rgba(255,255,255,.08) 0%,transparent 70%);animation:shimmer 6s ease-in-out infinite}
@keyframes shimmer{0%,100%{transform:translate(0,0)}50%{transform:translate(25%,25%)}}
.hero .status-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;animation:pulse 2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.hero .active-name{font-size:20px;font-weight:800;display:block;margin:10px 0 4px;word-break:break-word}
.hero .meta{font-size:12px;opacity:.8}
.stats-row{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;margin-bottom:14px}
.stat-box{background:var(--card);border:1px solid var(--card-border);backdrop-filter:blur(20px);border-radius:16px;padding:14px 12px;text-align:center;animation:fadeUp .5s ease both}
.stat-box .icon{font-size:20px;margin-bottom:6px}
.stat-box .val{font-size:16px;font-weight:700;background:linear-gradient(135deg,var(--grad-start),var(--grad-end));-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.stat-box .lbl{font-size:10px;color:var(--text-dim);margin-top:3px;text-transform:uppercase;letter-spacing:.5px}
.list-row{display:flex;align-items:center;justify-content:space-between;padding:12px 0;border-bottom:1px solid rgba(255,255,255,.06)}
.list-row:last-child{border-bottom:none}
.item-name{font-weight:600;font-size:13px}.item-sub{font-size:11px;color:var(--text-dim);display:block;margin-top:2px}
.btn{border:none;border-radius:12px;padding:8px 16px;font-size:12px;font-weight:700;cursor:pointer;transition:all .2s;position:relative;overflow:hidden}
.btn-primary{background:linear-gradient(135deg,var(--grad-start),var(--grad-end));color:#fff}
.btn-outline{background:rgba(0,104,255,.12);color:var(--grad-start);border:1px solid rgba(0,104,255,.2)}
.btn-active{background:linear-gradient(135deg,var(--green),#059669);color:#fff;cursor:default}
.btn-danger{background:rgba(248,113,113,.12);color:var(--red);border:1px solid rgba(248,113,113,.2)}
.btn:active{transform:scale(.95)}
.btn-wide{width:100%;padding:14px;border-radius:14px;font-size:14px;margin-top:12px}
.input-row{display:flex;gap:8px;margin-top:12px}
input[type=text]{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);color:var(--text);padding:12px 14px;border-radius:12px;width:100%;font-size:13px;font-family:inherit;outline:none;transition:border .2s}
input[type=text]:focus{border-color:var(--grad-start)}
input[type=text]::placeholder{color:var(--text-dim)}
.ping-badge{font-size:11px;font-weight:700;padding:4px 10px;border-radius:8px;min-width:52px;text-align:center}
.ping-good{background:rgba(52,211,153,.15);color:var(--green)}.ping-mid{background:rgba(251,191,36,.15);color:var(--yellow)}.ping-bad{background:rgba(248,113,113,.15);color:var(--red)}.ping-wait{background:rgba(255,255,255,.06);color:var(--text-dim)}
.hwid-card{display:flex;align-items:center;gap:14px}
.hwid-icon{width:44px;height:44px;border-radius:12px;background:linear-gradient(135deg,var(--grad-start),var(--grad-end));display:flex;align-items:center;justify-content:center;font-size:20px;flex-shrink:0}
.hwid-info .hwid-val{font-size:12px;font-weight:600;font-family:'Courier New',monospace;color:var(--grad-end);word-break:break-all}
.hwid-info .hwid-meta{font-size:11px;color:var(--text-dim);margin-top:3px}
.toast{position:fixed;left:12px;right:12px;bottom:20px;padding:14px 16px;border-radius:14px;background:rgba(20,20,30,.95);border:1px solid rgba(255,255,255,.1);backdrop-filter:blur(20px);color:#fff;z-index:10000;font-size:13px;transform:translateY(100px);opacity:0;transition:all .35s cubic-bezier(.4,0,.2,1);max-width:480px;margin:0 auto}
.toast.show{transform:translateY(0);opacity:1}
.loader{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.7);backdrop-filter:blur(6px);z-index:9999;display:none;justify-content:center;align-items:center}
.loader.show{display:flex}
.spinner{width:40px;height:40px;border:3px solid rgba(255,255,255,.1);border-top:3px solid var(--grad-end);border-radius:50%;animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.skeleton{background:linear-gradient(90deg,rgba(255,255,255,.04) 25%,rgba(255,255,255,.08) 50%,rgba(255,255,255,.04) 75%);background-size:200% 100%;animation:skel 1.5s ease-in-out infinite;border-radius:8px;height:16px;margin:4px 0}
@keyframes skel{0%{background-position:200% 0}100%{background-position:-200% 0}}
.footer{text-align:center;font-size:11px;color:var(--text-dim);padding:8px 0}
.footer button{background:rgba(0,104,255,.1);border:1px solid rgba(0,104,255,.2);color:var(--grad-start);padding:6px 14px;border-radius:10px;font-size:11px;font-weight:700;cursor:pointer;margin-left:8px;font-family:inherit}
.refresh-timer{font-size:11px;color:var(--text-dim);text-align:center;margin-top:8px}
@media(max-width:360px){.stats-row{grid-template-columns:1fr 1fr}.stat-box:nth-child(3){grid-column:span 2}}
  </style>
</head>
<body>
  <div id="loader" class="loader"><div class="spinner"></div></div>
  <div id="toast" class="toast"></div>
  <div class="container">
    <header class="header"><h1>⚡ RIFT</h1><div class="ver" id="ver_label">v...</div></header>

    <div class="card hero" id="hero_card">
      <h3><span class="status-dot" id="status_dot" style="background:var(--red)"></span>ПОДКЛЮЧЕНИЕ</h3>
      <span class="active-name" id="active_name"><div class="skeleton" style="width:60%;margin:0 auto;height:22px"></div></span>
      <span class="meta" id="sub_meta">Загрузка...</span>
      <button class="btn btn-wide" style="background:rgba(255,255,255,.15);color:#fff;border:1px solid rgba(255,255,255,.2)" onclick="updateSubs()">🔄 Обновить подписку</button>
      <div class="refresh-timer" id="refresh_timer"></div>
    </div>

    <div class="stats-row">
      <div class="stat-box"><div class="icon">📊</div><div class="val" id="st_traffic">—</div><div class="lbl">Трафик</div></div>
      <div class="stat-box"><div class="icon">⏱</div><div class="val" id="st_uptime">—</div><div class="lbl">Аптайм</div></div>
      <div class="stat-box"><div class="icon">💾</div><div class="val" id="st_mem">—</div><div class="lbl">RAM</div></div>
    </div>

    <div class="card">
      <h3>🖥 Устройство</h3>
      <div class="hwid-card">
        <div class="hwid-icon">🔑</div>
        <div class="hwid-info">
          <div class="hwid-val" id="hwid_val">...</div>
          <div class="hwid-meta" id="hwid_meta">OpenWrt</div>
        </div>
      </div>
    </div>

    <div class="card">
      <h3>🌐 Серверы</h3>
      <div id="nodes_list"><div class="skeleton"></div><div class="skeleton" style="width:80%"></div><div class="skeleton" style="width:60%"></div></div>
      <div class="input-row">
        <input type="text" id="sub_url" placeholder="Ссылка на подписку">
        <button class="btn btn-primary" onclick="saveUrl()">💾</button>
      </div>
    </div>

    <div class="card">
      <h3>📡 VPN для устройства</h3>
      <div class="input-row">
        <input type="text" id="manual_ip" placeholder="IP (192.168.1.X)">
        <button class="btn btn-primary" onclick="addManualIp()">+</button>
      </div>
      <div id="vpn_list" style="margin-top:10px"></div>
    </div>

    <div class="card">
      <h3>🎯 Домены (VPN)</h3>
      <div class="input-row">
        <input type="text" id="new_domain" placeholder="domain.com">
        <button class="btn btn-primary" onclick="addDomain()">+</button>
      </div>
      <div id="domains_list" style="margin-top:10px"></div>
    </div>

    <div class="footer" id="footer"></div>
  </div>

<script>
function normalizeUrl(u){return(u||"").replace(/&sid=[a-zA-Z0-9]+/g,'');}
let globalNodes=[],activeUrl="",vpnIps=[],domains=[];
let refreshInterval=600,refreshCountdown=refreshInterval;

function showToast(msg,ms=5000){const el=document.getElementById('toast');el.textContent=msg;el.classList.add('show');clearTimeout(window.__t);window.__t=setTimeout(()=>el.classList.remove('show'),ms);}
function showLoader(){document.getElementById('loader').classList.add('show');}
function hideLoader(){document.getElementById('loader').classList.remove('show');}

async function api(method,params={}){
  params.method=method;
  const qs=Object.keys(params).map(k=>k+'='+encodeURIComponent(params[k])).join('&');
  const resp=await fetch('/cgi-bin/rpc?'+qs,{cache:'no-store'});
  const text=await resp.text();
  let data;
  try{data=JSON.parse(text);}catch(e){throw new Error("RPC: "+text.slice(0,120));}
  if(data&&data.status==="error"){throw new Error(data.msg||"Ошибка");}
  return data;
}

function fmtBytes(b){if(b<1024)return b+' B';if(b<1048576)return(b/1024).toFixed(1)+' KB';if(b<1073741824)return(b/1048576).toFixed(1)+' MB';return(b/1073741824).toFixed(2)+' GB';}
function fmtUptime(s){s=Math.floor(s);const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);if(d>0)return d+'д '+h+'ч';if(h>0)return h+'ч '+m+'м';return m+'м';}

window.onload=async function(){
  try{const r=await api('get_sub_url');if(r.url)document.getElementById('sub_url').value=r.url;}catch(e){}
  try{
    const r=await api('get_panel_info');
    if(r.version){
      document.getElementById('ver_label').textContent='v'+r.version;
      document.getElementById('footer').innerHTML='Версия: '+r.version+' <button onclick="checkForUpdates()">🔄 Проверить</button>';
    }
  }catch(e){}
  await loadData();
  await loadNetwork();
  await loadHWID();
  await loadStats();
  setInterval(loadStats,15000);
  setInterval(()=>{refreshCountdown--;if(refreshCountdown<=0){refreshCountdown=refreshInterval;silentRefresh();}updateTimer();},1000);
  updateTimer();
};

function updateTimer(){
  const m=Math.floor(refreshCountdown/60),s=refreshCountdown%60;
  document.getElementById('refresh_timer').textContent='Обновление через '+m+':'+String(s).padStart(2,'0');
}

async function silentRefresh(){
  try{await api('update_subs',{});await loadData();}catch(e){}
}

async function loadStats(){
  try{
    const t=await api('get_traffic');
    document.getElementById('st_traffic').textContent=fmtBytes(t.bytes||0);
    document.getElementById('st_uptime').textContent=fmtUptime(t.uptime||0);
  }catch(e){}
  try{
    const s=await api('get_system');
    const pct=s.mem_total>0?Math.round((1-s.mem_available/s.mem_total)*100):0;
    document.getElementById('st_mem').textContent=pct+'%';
  }catch(e){}
}

async function loadHWID(){
  try{
    const r=await api('get_hwid');
    document.getElementById('hwid_val').textContent=r.hwid||'—';
    document.getElementById('hwid_meta').textContent=(r.device_model||'OpenWrt')+' • '+(r.os_version||'');
  }catch(e){}
}

async function loadData(){
  try{
    const d=await api('get_nodes');
    globalNodes=Array.isArray(d.nodes)?d.nodes:[];
    activeUrl=d.active_url||"";
    document.getElementById('sub_meta').innerText=d.updated?("Обновлено: "+d.updated):"Нет данных";
    let an="Нет подключения";
    const dot=document.getElementById('status_dot');
    if(activeUrl&&globalNodes.length){
      const norm=normalizeUrl(activeUrl.trim());
      const n=globalNodes.find(x=>normalizeUrl((x.full_url||"").trim())===norm);
      if(n)an=n.name;else{const m=activeUrl.match(/#(.*)$/);if(m)an=decodeURIComponent(m[1]);}
      dot.style.background='var(--green)';
    }else{dot.style.background='var(--red)';}
    document.getElementById('active_name').innerText=an;
    renderNodes();
  }catch(e){showToast("Ошибка: "+e.message);}
}

function renderNodes(){
  const div=document.getElementById("nodes_list");
  if(!globalNodes.length){div.innerHTML='<div style="padding:14px 0;text-align:center;color:var(--text-dim)">Список пуст</div>';return;}
  const normActive=normalizeUrl((activeUrl||"").trim());
  let h="";
  globalNodes.forEach((n,i)=>{
    const isA=normalizeUrl((n.full_url||"").trim())===normActive;
    const btn=isA?'<span class="btn btn-active">✓ Активен</span>'
      :'<button class="btn btn-outline" onclick="connect('+i+')">▶</button>';
    const pingId='ping_'+i;
    h+='<div class="list-row"><div style="flex:1;min-width:0"><span class="item-name" style="display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+
      (n.name||"Server")+'</span><span class="item-sub">'+(n.type||'')+' • '+(n.host||'')+'</span></div>'+
      '<div style="display:flex;gap:6px;align-items:center;flex-shrink:0"><span class="ping-badge ping-wait" id="'+pingId+'" onclick="doPing(\''+n.host+'\',\''+pingId+'\')">ping</span>'+btn+'</div></div>';
  });
  div.innerHTML=h;
}

async function doPing(host,elId){
  const el=document.getElementById(elId);
  if(!el)return;el.textContent='...';el.className='ping-badge ping-wait';
  try{
    const r=await api('ping',{host:host});
    if(r.status==='ok'){
      const ms=parseInt(r.time);
      el.textContent=r.time;
      el.className='ping-badge '+(ms<100?'ping-good':ms<300?'ping-mid':'ping-bad');
    }else{el.textContent='✗';el.className='ping-badge ping-bad';}
  }catch(e){el.textContent='✗';el.className='ping-badge ping-bad';}
}

async function updateSubs(){
  showLoader();
  try{const r=await api('update_subs',{});showToast('✅ Обновлено. Серверов: '+(r.count||"?"));refreshCountdown=refreshInterval;await loadData();}
  catch(e){showToast("❌ "+e.message,8000);}
  finally{hideLoader();}
}

async function saveUrl(){
  const u=document.getElementById('sub_url').value;if(!u)return;
  showLoader();
  try{const r=await api('update_subs',{url:u});showToast('✅ Сохранено. Серверов: '+(r.count||"?"));refreshCountdown=refreshInterval;await loadData();}
  catch(e){showToast("❌ "+e.message,8000);}
  finally{hideLoader();}
}

async function connect(i){
  if(!confirm('Подключиться к '+globalNodes[i].name+'?'))return;
  showLoader();
  try{await api('apply',{node_url:globalNodes[i].full_url});await new Promise(r=>setTimeout(r,2500));await loadData();}
  catch(e){showToast("❌ "+e.message,8000);}
  finally{hideLoader();}
}

async function loadNetwork(){
  try{
    const d=await api('get_network');
    const c=d.clients||[];vpnIps=Array.isArray(d.vpn_ips)?d.vpn_ips:[];domains=Array.isArray(d.domains)?d.domains:[];
    let vh="";
    c.forEach(x=>{
      const iv=vpnIps.includes(x.ip);
      const btn=iv?'<button class="btn btn-active" onclick="toggleVpn(\''+x.ip+'\',\'del\')">✓ Вкл</button>'
        :'<button class="btn btn-outline" onclick="toggleVpn(\''+x.ip+'\',\'add\')">Включить</button>';
      vh+='<div class="list-row"><div><span class="item-name">'+x.name+'</span><span class="item-sub">'+x.ip+'</span></div>'+btn+'</div>';
    });
    if(!vh)vh='<div style="padding:12px 0;text-align:center;color:var(--text-dim)">Нет устройств</div>';
    document.getElementById("vpn_list").innerHTML=vh;
    let dh="";
    if(domains.length){domains.forEach(dom=>{dh+='<div class="list-row"><div><span class="item-name">'+dom+'</span></div><button class="btn btn-danger" onclick="manageDomain(\''+dom+'\',\'del\')">✕</button></div>';});}
    else{dh='<div style="padding:12px 0;text-align:center;color:var(--text-dim)">Список пуст</div>';}
    document.getElementById('domains_list').innerHTML=dh;
  }catch(e){showToast("❌ "+e.message);}
}

async function toggleVpn(ip,a){showLoader();try{await api('manage_vpn',{ip:ip,action:a});await new Promise(r=>setTimeout(r,2000));await loadNetwork();}catch(e){showToast("❌ "+e.message);}finally{hideLoader();}}
function addManualIp(){const ip=document.getElementById('manual_ip').value;if(ip)toggleVpn(ip,'add');document.getElementById('manual_ip').value="";}
async function manageDomain(d,a){showLoader();try{await api('manage_domain',{domain:d,action:a});await new Promise(r=>setTimeout(r,2000));await loadNetwork();}catch(e){showToast("❌ "+e.message);}finally{hideLoader();}}
function addDomain(){const d=document.getElementById('new_domain').value;if(d)manageDomain(d,'add');document.getElementById('new_domain').value="";}

async function checkForUpdates(){
  showLoader();
  try{
    const r=await api('check_for_update');
    if(r.status==="update_available"){
      if(confirm('Доступна v'+r.remote_v+' (у вас v'+r.local_v+'). Обновить?')){
        await api('perform_update');await new Promise(r=>setTimeout(r,4000));location.reload();
      }
    }else if(r.status==="up_to_date"){showToast('✅ У вас последняя версия (v'+r.local_v+')');}
    else{showToast('❌ Ошибка проверки');}
  }catch(e){showToast("❌ "+e.message);}
  finally{hideLoader();}
}
</script>
</body>
</html>
FRONTEND_EOF

# 7) sub_refresh + autoupdate + cron
echo "[7/8] Настройка автообновления подписки и панели..."

# Sub refresh script (every 10 min)
cat <<'SUBREF_EOF' > /etc/podkop_data/sub_refresh.sh
#!/bin/sh
# Silent subscription refresh with HWID headers
URL=$(uci -q get podkop_subs.config.url)
[ -z "$URL" ] && exit 0

HWID=$(cat /etc/podkop_data/hwid 2>/dev/null || echo "RIFT-unknown")
OSVER=$(grep 'DISTRIB_RELEASE' /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)
MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "OpenWrt Router")
VER=$(cat /etc/podkop_data/version 2>/dev/null || echo "3.0")
BODY="/tmp/podkop_sub_auto.body"

if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -q -O "$BODY" \
    --header="x-hwid: $HWID" \
    --header="x-device-os: OpenWrt" \
    --header="x-ver-os: $OSVER" \
    --header="x-device-model: $MODEL" \
    --header="User-Agent: RIFT-Panel/$VER" \
    "$URL" 2>/dev/null
else
  wget -q -T 20 -O "$BODY" \
    --header="x-hwid: $HWID" \
    --header="x-device-os: OpenWrt" \
    --header="x-ver-os: $OSVER" \
    --header="x-device-model: $MODEL" \
    --header="User-Agent: RIFT-Panel/$VER" \
    "$URL" 2>/dev/null
fi

[ ! -s "$BODY" ] && rm -f "$BODY" && exit 0

# Try to call the panel RPC to parse nodes (reuses existing logic)
# Alternatively parse inline with lua
lua -e '
function trim(s) return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1")) end
function shq(s) s=tostring(s or "") return "\x27"..s:gsub("\x27", "\x27\\\x27\x27").."\x27" end
function exec_read(cmd) local h=io.popen(cmd) local r=h:read("*a") h:close() return r and trim(r) or "" end
function serialize(val)
  local t=type(val)
  if t=="table" then
    local parts={}
    for k,v in pairs(val) do
      local key=(type(k)=="number") and "" or ("[\""..k.."\"]=" )
      parts[#parts+1]=key..serialize(v)
    end
    return "{"..table.concat(parts,",").."}"
  elseif t=="string" then return string.format("%q",val)
  else return tostring(val) end
end
local function b64fix(s) s=(s or ""):gsub("%s+",""):gsub("-","+"):gsub("_","/") while(#s%4)~=0 do s=s.."=" end return s end
local PROTOS={"vless://","trojan://","ss://","vmess://","hysteria2://","tuic://"}
local function extract(text)
  local out={}
  if not text then return out end
  for line in (text.."\n"):gmatch("([^\n]+)") do
    line=trim(line)
    if line~="" then
      for _,pr in ipairs(PROTOS) do
        if line:sub(1,#pr)==pr then out[#out+1]=line break end
      end
    end
  end
  return out
end
local function tonode(l)
  local p=(l:match("^(%w+)://") or "LINK"):upper()
  local ne=l:match("#(.+)$")
  local nm="Server"
  if ne then nm=ne:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end) end
  local ho=l:match("@(.-):" ) or l:match("://([^/:#%%?]+)") or "unknown"
  local ti=p if l:match("security=reality") then ti="Reality" end
  return {name=nm,host=ho,type=ti,full_url=l}
end
local function should_skip(name) return name:find("\208\158\208\177\209\133\208\190\208\180 \208\145\208\161",1,true) end
local f=io.open("/tmp/podkop_sub_auto.body","r")
if not f then os.exit(0) end
local raw=f:read("*a") f:close()
local nodes={}
local seen={}
local function add_links(text)
  local lnks=extract(text)
  for _,u in ipairs(lnks) do
    local n=tonode(u)
    if not should_skip(n.name) and not seen[n.host] then
      seen[n.host]=true
      nodes[#nodes+1]=n
    end
  end
end
add_links(raw)
if #nodes==0 then
  local t=raw:gsub("%s+","")
  if #t>=16 and t:match("^[%w%+/%=_%-%s]+$") then
    local dec=exec_read("printf %s "..shq(b64fix(t)).." | base64 -d 2>/dev/null")
    if dec~="" then add_links(dec) end
  end
end
if #nodes>0 then
  local db={expire="Нет данных",updated=os.date("%Y-%m-%d %H:%M:%S"),nodes=nodes}
  local out=io.open("/etc/podkop_data/nodes.lua","w")
  if out then out:write("return "..serialize(db)) out:close() end
end
' 2>/dev/null

rm -f "$BODY"
SUBREF_EOF
chmod +x /etc/podkop_data/sub_refresh.sh

# Panel autoupdate script (daily)
cat <<'AUTOUPD_EOF' > /etc/podkop_data/autoupdate.sh
#!/bin/sh
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"
VERSION_FILE="/etc/podkop_data/version"
TMP="/tmp/rift_remote.sh"
[ -f "$VERSION_FILE" ] || exit 0
LOCAL_VERSION="$(cat "$VERSION_FILE" 2>/dev/null)"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -q -O "$TMP" "$REMOTE_SCRIPT_URL" >/dev/null 2>&1 || exit 0
else
  wget -q -O "$TMP" "$REMOTE_SCRIPT_URL" >/dev/null 2>&1 || exit 0
fi
REMOTE_VERSION="$(sed -n 's/^PANEL_VERSION="\([^"]*\)".*/\1/p' "$TMP" | head -n1)"
if [ -n "$REMOTE_VERSION" ] && [ -n "$LOCAL_VERSION" ] && [ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]; then
  sh "$TMP" >/dev/null 2>&1
fi
rm -f "$TMP"
AUTOUPD_EOF
chmod +x /etc/podkop_data/autoupdate.sh

# 8) cron setup
echo "[8/8] Настройка cron задач..."
# Remove old jobs
(crontab -l 2>/dev/null | grep -Fv "/etc/podkop_data/autoupdate.sh" | grep -Fv "/etc/podkop_data/sub_refresh.sh") > /tmp/cron_clean 2>/dev/null
echo "0 4 * * * /etc/podkop_data/autoupdate.sh" >> /tmp/cron_clean
echo "*/10 * * * * /etc/podkop_data/sub_refresh.sh" >> /tmp/cron_clean
crontab /tmp/cron_clean
rm -f /tmp/cron_clean

# finish
chmod +x /www/podkop_panel/cgi-bin/rpc
sed -i 's/\r$//' /www/podkop_panel/cgi-bin/rpc

/etc/init.d/uhttpd enable >/dev/null 2>&1
/etc/init.d/uhttpd restart >/dev/null 2>&1
/etc/init.d/dnsmasq restart >/dev/null 2>&1

ROUTER_IP="$(uci -q get network.lan.ipaddr)"
[ -z "$ROUTER_IP" ] && ROUTER_IP="192.168.1.1"

echo "================================================="
echo "✅ ГОТОВО! RIFT Panel v${PANEL_VERSION} установлена."
echo "🔑 HWID: $(cat /etc/podkop_data/hwid 2>/dev/null)"
echo "🌐 Доступ: http://${ROUTER_IP}:2017"
echo "🔄 Подписка обновляется каждые 10 минут"
echo "================================================="
