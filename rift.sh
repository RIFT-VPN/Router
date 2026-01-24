#!/bin/sh

# === RIFT PANEL INSTALLER & UPDATER (V24 - Full Fix Pack) ===
# Paste this file on OpenWrt and run: sh rift.sh

SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"
PANEL_VERSION="2.4"   # <-- VERSION BUMP

echo "=== УСТАНОВКА RIFT PANEL v${PANEL_VERSION} ==="

# 1. Зависимости
echo "[1/7] Установка пакетов..."
opkg update >/dev/null 2>&1
opkg install curl ca-bundle coreutils-base64 lua >/dev/null 2>&1

# 2. Создание структуры
echo "[2/7] Настройка системы..."
mkdir -p /www/podkop_panel/cgi-bin
mkdir -p /etc/podkop_data
touch /etc/config/podkop_subs
if [ ! -s /etc/config/podkop_subs ]; then
    echo "config podkop_subs 'config'" > /etc/config/podkop_subs
fi
echo "${PANEL_VERSION}" > /etc/podkop_data/version

# 3. Настройка uhttpd
echo "[3/7] Настройка веб-сервера (порт 2017)..."
uci -q delete uhttpd.podkop_panel
uci set uhttpd.podkop_panel=uhttpd
uci add_list uhttpd.podkop_panel.listen_http='0.0.0.0:2017'
uci set uhttpd.podkop_panel.home='/www/podkop_panel'
uci set uhttpd.podkop_panel.rfc1918_filter='0'
uci set uhttpd.podkop_panel.max_requests='10'
uci set uhttpd.podkop_panel.cgi_prefix='/cgi-bin'
uci commit uhttpd

# 4. УБИРАЕМ ДОСТУП ПО ДОМЕНУ rift (работаем только по IP)
echo "[4/7] Удаление домена rift (если был ранее)..."
# удалить dhcp domain 'rift' и rebind_domain
for s in $(uci show dhcp 2>/dev/null | sed -n "s/^\(dhcp\.@domain\[[0-9]\+\]\)=domain.*/\1/p"); do
  [ "$(uci -q get ${s}.name)" = "rift" ] && uci delete "$s"
done
uci -q del_list dhcp.@dnsmasq[0].rebind_domain='rift'
uci commit dhcp >/dev/null 2>&1

# 5. Backend (RPC)
echo "[5/7] Запись Backend скрипта..."
cat << 'EOF' > /www/podkop_panel/cgi-bin/rpc
#!/usr/bin/lua

function trim(s) return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1")) end

-- безопасное экранирование для shell
function shq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function to_json(val)
  local t=type(val)
  if t=="table" then
    local is_array=(#val>0)
    local parts={}
    if is_array then
      for _,v in ipairs(val) do table.insert(parts,to_json(v)) end
      return"["..table.concat(parts,",").."]"
    else
      for k,v in pairs(val) do
        table.insert(parts,'"'..k..'":'..to_json(v))
      end
      return"{"..table.concat(parts,",").."}"
    end
  elseif t=="string" then
    val=val:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','')
    return'"'..val..'"'
  elseif t=="number" or t=="boolean" then
    return tostring(val)
  else
    return"null"
  end
end

function serialize(val)
  local t=type(val)
  if t=="table" then
    local parts={}
    for k,v in pairs(val) do
      local key=(type(k)=="number") and""or('["'..k..'"]=') 
      table.insert(parts,key..serialize(v))
    end
    return"{"..table.concat(parts,",").."}"
  elseif t=="string" then
    return string.format("%q",val)
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

-- нормальное сравнение версий (2.10 > 2.4)
local function parse_ver(v)
  local t={}
  for num in tostring(v or ""):gmatch("(%d+)") do t[#t+1]=tonumber(num) end
  while #t < 3 do t[#t+1]=0 end
  return t
end
local function cmp_ver(a,b)
  local A=parse_ver(a)
  local B=parse_ver(b)
  for i=1,3 do
    if A[i] > B[i] then return 1 end
    if A[i] < B[i] then return -1 end
  end
  return 0
end

-- parse query string
local qs=os.getenv("QUERY_STRING")or""
local params={}
for k,v in string.gmatch(qs,"([^&=]+)=([^&=]*)") do
  params[k]=v:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end)
end
local method=params.method

print("Content-type: application/json; charset=utf-8\n")

if method=="get_panel_info" then
  local f=io.open("/etc/podkop_data/version","r")
  local v=f and f:read("*a") or "0.0"
  if f then f:close() end
  print(to_json({version=trim(v)}))
  os.exit(0)
end

if method=="check_for_update" then
  local remote_script=exec_read("curl -fsSL --connect-timeout 6 --max-time 12 " .. shq("https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh") .. " 2>/dev/null")
  local remote_version=remote_script:match('PANEL_VERSION="([%d%.]+)"')
  local f=io.open("/etc/podkop_data/version","r")
  local local_version=f and trim(f:read("*a")) or "0.0"
  if f then f:close() end

  if remote_version and local_version then
    if cmp_ver(remote_version, local_version) == 1 then
      print(to_json({status="update_available",local_v=local_version,remote_v=remote_version}))
    else
      print(to_json({status="up_to_date",local_v=local_version,remote_v=remote_version}))
    end
  else
    print(to_json({status="error", msg="Не удалось получить версию с GitHub"}))
  end
  os.exit(0)
end

if method=="perform_update" then
  exec_silent("sh -c " .. shq("curl -fsSL --connect-timeout 10 --max-time 30 " ..
    "https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh | sh"))
  print('{"status":"ok"}')
  os.exit(0)
end

if method=="get_nodes" then
  local s,db=pcall(dofile,"/etc/podkop_data/nodes.lua")
  if not s or type(db)~="table" then db={nodes={}} end
  local cp=uci_get("podkop","main","proxy_string")
  local r=exec_silent("pgrep -f podkop")
  local rn=(r==0)or(r==true)
  local dp=(cp or ""):gsub("%%20"," ")
  print(to_json({
    nodes=db.nodes or{},
    expire=db.expire or"Нет данных",
    updated=db.updated or"Никогда",
    active_url=dp,
    running=rn
  }))
  os.exit(0)
end

-- универсальный парсер ссылок (plain-text или base64)
local function parse_nodes(text)
  local nodes={}
  text = text or ""
  for line in text:gmatch("[^\r\n]+") do
    if line:match("^vless://") or line:match("^trojan://") or line:match("^ss://") then
      local ne=line:match("#(.+)$")
      local n="Server"
      if ne then n=ne:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end) end

      local proto=(line:match("^(%w+)://") or "LINK"):upper()
      local host=line:match("@(.-):") or line:match("://([^/:#%?]+)") or "unknown"
      local ti=proto
      if line:match("security=reality") then ti="Reality" end

      table.insert(nodes,{name=n,host=host,type=ti,full_url=line})
    end
  end
  return nodes
end

if method=="update_subs" then
  local url=params.url
  if not url or url=="" then url=trim(uci_get("podkop_subs","config","url")) end
  if not url or url=="" then
    print('{"status":"error","msg":"URL не найден!"}')
    os.exit(0)
  end

  -- сохраняем URL
  exec_silent("uci -q delete podkop_subs.config.url")
  uci_set("podkop_subs","config","url",url)
  exec_silent("uci commit podkop_subs")

  -- headers (case preserved для base64)
  local hdr_raw = exec_read("curl -sS -L --connect-timeout 10 --max-time 20 -A 'Mozilla/5.0' -D - -o /dev/null " .. shq(url) .. " 2>&1")
  hdr_raw = hdr_raw or ""
  local hdr_low = hdr_raw:lower()

  local ei="Неизвестно"
  local ui = hdr_low:match("subscription%-userinfo:%s*([^\r\n]+)")
  if ui then
    local et=ui:match("expire=(%d+)")
    if et then
      ei=os.date("%Y-%m-%d",tonumber(et))
      local total=ui:match("total=(%d+)")
      local dl=ui:match("download=(%d+)")
      if total and dl then
        local lgb=math.floor((tonumber(total)-tonumber(dl))/1073741824*100)/100
        ei=ei.." (Ост: "..lgb.." GB)"
      end
    end
  end

  if ei=="Неизвестно" then
    -- берём base64 строго из НЕ-lowercase заголовков
    local t64 = hdr_raw:match("profile%-title:%s*base64:([%w%+/=]+)")
    if t64 then
      local dec=exec_read("echo " .. shq(t64) .. " | base64 -d 2>/dev/null")
      dec=(dec or ""):gsub("RIFT",""):gsub("\n"," "):gsub("^%s+","")
      if dec~="" then ei=dec end
    end
  end

  -- body (может быть plain-text или base64)
  local raw=exec_read("curl -sS -L --connect-timeout 10 --max-time 20 -A 'Mozilla/5.0' " .. shq(url) .. " 2>&1")
  raw=raw or ""

  if raw:match("^curl:") then
    print(to_json({status="error", msg=("curl: "..raw:gsub("\n"," "):sub(1,220))}))
    os.exit(0)
  end

  -- 1) plain-text
  local nodes=parse_nodes(raw)

  -- 2) base64 fallback
  if #nodes==0 then
    local trimmed = raw:gsub("%s+","")
    if trimmed:match("^[%w%+/=]+$") then
      local decoded=exec_read("printf %s " .. shq(trimmed) .. " | base64 -d 2>/dev/null")
      nodes=parse_nodes(decoded)
    end
  end

  if #nodes==0 then
    print(to_json({
      status="error",
      msg="Серверы не найдены. Ответ не base64 и не содержит vless/trojan/ss ссылок.",
      sample=raw:sub(1,160)
    }))
    os.exit(0)
  end

  local db={expire=ei,updated=os.date("%Y-%m-%d %H:%M:%S"),nodes=nodes}
  local f=io.open("/etc/podkop_data/nodes.lua","w")
  if f then
    f:write("return "..serialize(db))
    f:close()
    print(to_json({status="ok",count=#nodes,expire=ei}))
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
      for w in line:gmatch("%S+") do table.insert(p,w) end
      if #p>=4 then table.insert(c,{ip=p[3],name=p[4],mac=p[2]}) end
    end
    f:close()
  end
  local vl={}
  local rl=exec_read("uci -q get podkop.main.fully_routed_ips")
  for w in (rl or ""):gmatch("%S+") do table.insert(vl,w) end
  local dl={}
  local rd=exec_read("uci -q get podkop.main.user_domains")
  for w in (rd or ""):gmatch("%S+") do table.insert(dl,w) end
  print(to_json({clients=c,vpn_ips=vl,domains=dl}))
  os.exit(0)
end

if method=="manage_vpn" then
  local ip=params.ip
  local a=params.action
  if ip and a and ip:match("^%d+%.%d+%.%d+%.%d+$") then
    if a=="add" then
      exec_silent("uci add_list podkop.main.fully_routed_ips="..shq(ip))
    elseif a=="del" then
      exec_silent("uci del_list podkop.main.fully_routed_ips="..shq(ip))
    end
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
EOF

# 6. Frontend (HTML)
echo "[6/7] Запись Frontend интерфейса..."
cat << 'EOF' > /www/podkop_panel/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>RIFT Panel</title>
  <style>
    :root{--bg-color:#F4F7FE;--card-bg:#fff;--text-primary:#1A202C;--text-secondary:#718096;--grad-start:#0068FF;--grad-end:#85D9FE}
    @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
    body{font-family:'Inter',-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background-color:var(--bg-color);margin:0;padding:20px;color:var(--text-primary)}
    .container{max-width:500px;margin:0 auto}
    .header{text-align:center;margin-bottom:30px}
    .logo-svg{width:80px;height:80px}
    h1{font-size:24px;font-weight:700;color:var(--text-primary);margin:10px 0 0}
    .card{background:var(--card-bg);border-radius:24px;padding:24px;margin-bottom:20px;box-shadow:0 8px 32px 0 rgba(0,0,0,.05)}
    h3{margin:0 0 20px;font-weight:600;font-size:18px;color:var(--text-primary)}
    .gradient-bg{background-image:linear-gradient(90deg,var(--grad-start) 0,var(--grad-end) 100%)}
    .active-conn-card{color:#fff;text-align:center}
    .active-conn-card h3{color:rgba(255,255,255,.8);font-size:14px;font-weight:500}
    .server-name-big{font-size:24px;font-weight:700;margin-bottom:8px;display:block}
    .server-meta{color:rgba(255,255,255,.8);font-size:14px}
    .btn-update{background:rgba(255,255,255,.2);color:#fff;width:100%;padding:12px;border:1px solid rgba(255,255,255,.3);border-radius:12px;font-weight:600;font-size:14px;cursor:pointer;margin-top:20px}
    .list-row{display:flex;align-items:center;justify-content:space-between;padding:16px 0;border-bottom:1px solid #E9EFFE}
    .list-row:last-child{border-bottom:none;padding-bottom:0}
    .list-row:first-child{padding-top:0}
    .item-name{font-weight:600;font-size:15px}
    .item-sub{display:block;font-size:13px;color:var(--text-secondary)}
    .item-ping{font-size:14px;margin-right:16px;font-weight:600;color:var(--text-primary)}
    .btn-action,.active-badge{background:#EEF2FF;border:1px solid #EEF2FF;color:#4A55E0;padding:8px 16px;border-radius:20px;font-size:13px;font-weight:600;cursor:pointer;text-align:center;display:inline-block}
    .active-badge{color:#fff;cursor:default}
    .input-group{display:flex;gap:10px;margin-top:20px}
    input[type=text]{background:#F7FAFC;border:1px solid #E2E8F0;color:var(--text-primary);padding:12px;border-radius:12px;width:100%;box-sizing:border-box;font-size:14px}
    .btn-apply{color:#fff;border:none;padding:0 20px;border-radius:12px;cursor:pointer;font-size:14px;font-weight:600}
    .preloader-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.7);backdrop-filter:blur(5px);z-index:9999;display:none;flex-direction:column;justify-content:center;align-items:center}
    .spinner{width:50px;height:50px;border:4px solid rgba(255,255,255,.1);border-top:4px solid #fff;border-radius:50%;animation:spin 1s linear infinite;margin-bottom:20px}
    @keyframes spin{0%{transform:rotate(0)}100%{transform:rotate(360deg)}}
  </style>
</head>
<body>
  <div id="preloader" class="preloader-overlay"><div class="spinner"></div></div>
  <div id="toast" style="display:none;position:fixed;left:12px;right:12px;bottom:12px;padding:12px 14px;border-radius:14px;background:#111;color:#fff;z-index:10000;font-size:14px;box-shadow:0 12px 40px rgba(0,0,0,.25)"></div>

  <div class="container">
    <header class="header">
      <svg class="logo-svg" viewBox="0 0 936 936" fill="none" xmlns="http://www.w3.org/2000/svg">
        <rect width="935.497" height="935.497" rx="150" fill="url(#p-grad)"/>
        <path d="M427.959 305.04C451.912 301.277 476.444 304.502 498.611 314.329C533.931 329.986 560.121 360.975 569.673 398.41L612.004 564.321L612.441 566.32C616.717 585.791 603.61 604.812 583.894 607.752L581.979 608.038C572.841 609.401 563.578 606.533 556.808 600.246L554.184 597.81C550.247 594.154 545.073 592.122 539.7 592.122C531.029 592.122 523.225 597.384 519.971 605.421L515.385 616.753C511.664 625.942 504.619 633.392 495.652 637.62L490.775 639.919C481.876 644.115 471.987 645.761 462.209 644.675L449.883 643.304C440.682 642.283 432.315 637.495 426.771 630.081L414.181 613.244C405.972 602.265 389.26 603.093 382.175 614.828L380.271 617.383C371.677 628.923 356.781 633.853 342.999 629.718L341.829 629.368C328.541 625.381 319.248 613.399 318.693 599.537L323.205 517.195C323.903 504.455 323.651 491.682 322.451 478.98L318.51 437.248C317.099 422.315 318.476 407.251 322.569 392.821C335.459 347.378 373.6 313.579 420.264 306.248L427.959 305.04ZM372.907 405.849C359.344 405.849 348.349 421.201 348.349 440.138C348.349 459.075 359.344 474.427 372.907 474.427C386.47 474.427 397.466 459.075 397.466 440.138C397.466 421.201 386.47 405.849 372.907 405.849ZM444.266 405.848C430.703 405.848 419.708 421.2 419.708 440.137C419.708 459.074 430.703 474.426 444.266 474.426C457.829 474.426 468.824 459.074 468.824 440.137C468.824 421.2 457.829 405.848 444.266 405.848Z" fill="white"/>
        <defs>
          <linearGradient id="p-grad" x1="821.778" y1="29.7283" x2="12.3598" y2="1048.38" gradientUnits="userSpaceOnUse">
            <stop offset=".3" stop-color="#0068FF"/><stop offset="1" stop-color="#85D9FE"/>
          </linearGradient>
        </defs>
      </svg>
      <h1>RIFT</h1>
    </header>

    <div class="card active-conn-card gradient-bg">
      <h3>АКТИВНОЕ ПОДКЛЮЧЕНИЕ</h3>
      <span class="server-name-big" id="active_name">...</span>
      <span class="server-meta" id="sub_meta">...</span>
      <button class="btn-update" onclick="updateSubs()">Обновить подписку</button>
    </div>

    <div class="card">
      <h3>Серверы</h3>
      <div id="nodes_list"></div>
      <div class="input-group">
        <input type="text" id="sub_url" placeholder="Ссылка на подписку">
        <button class="btn-apply gradient-bg" onclick="saveUrl()">Применить</button>
      </div>
    </div>

    <div class="card">
      <h3>Полный VPN для устройства</h3>
      <div class="input-group">
        <input type="text" id="manual_ip" placeholder="IP адрес (192.168.1.X)">
        <button class="btn-apply gradient-bg" onclick="addManualIp()">+</button>
      </div>
      <div id="vpn_list" style="margin-top:15px"></div>
    </div>

    <div class="card">
      <h3>Точечные домены (VPN)</h3>
      <div class="input-group">
        <input type="text" id="new_domain" placeholder="domain.com">
        <button class="btn-apply gradient-bg" onclick="addDomain()">+</button>
      </div>
      <div id="domains_list" style="margin-top:15px"></div>
    </div>

    <div class="card" style="text-align:center;font-size:14px;color:var(--text-secondary)" id="footer"></div>
  </div>

<script>
  function normalizeUrl(url){ return (url||"").replace(/&sid=[a-zA-Z0-9]+/g,''); }

  let globalNodes=[], activeUrl="", vpnIps=[], domains=[];
  const toastEl = () => document.getElementById('toast');

  function showToast(msg, ms=4500){
    const el = toastEl();
    el.textContent = msg;
    el.style.display = 'block';
    clearTimeout(window.__toastTimer);
    window.__toastTimer = setTimeout(()=>{ el.style.display='none'; }, ms);
  }

  function showLoader(){ document.getElementById('preloader').style.display='flex'; }
  function hideLoader(){ document.getElementById('preloader').style.display='none'; }

  async function api(method, params={}){
    params.method = method;
    const qs = Object.keys(params).map(k => k + '=' + encodeURIComponent(params[k])).join('&');

    let resp, text, data;
    try{
      resp = await fetch('/cgi-bin/rpc?' + qs, { cache:'no-store' });
    }catch(e){
      throw new Error("RPC недоступен (fetch). Проверь uhttpd/CGI.");
    }

    text = await resp.text();
    try{
      data = JSON.parse(text);
    }catch(e){
      throw new Error("RPC вернул не-JSON: " + text.slice(0,180));
    }

    if (data && data.status === "error"){
      throw new Error(data.msg || "Ошибка без msg");
    }
    return data;
  }

  window.onload = async function(){
    try{
      const r = await api('get_sub_url');
      if(r.url) document.getElementById('sub_url').value = r.url;
    }catch(e){ showToast("URL: " + e.message); }

    try{
      const r = await api('get_panel_info');
      if(r.version){
        document.getElementById('footer').innerHTML =
          `Версия: ${r.version} <button class="btn-action" style="margin-left:10px;padding:6px 12px;font-size:12px" onclick="checkForUpdates()">Обновить</button>`;
      }
    }catch(e){ showToast("Panel info: " + e.message); }

    await loadData();
    await loadNetwork();
  };

  async function loadData(){
    try{
      const d = await api('get_nodes');
      globalNodes = d.nodes || [];
      activeUrl = d.active_url || "";

      const et = d.expire ? ("Истекает: " + d.expire) : "Нет данных о подписке";
      document.getElementById('sub_meta').innerText = et;

      let an = "Нет подключения";
      if(activeUrl){
        const normActiveUrl = normalizeUrl(activeUrl.trim());
        const n = globalNodes.find(x => normalizeUrl((x.full_url||"").trim()) === normActiveUrl);
        if(n) an = n.name;
        else{
          const m = activeUrl.match(/#(.*)$/);
          if(m) an = decodeURIComponent(m[1]);
        }
      }
      document.getElementById('active_name').innerText = an;
      renderNodes();
    }catch(e){
      showToast("loadData: " + e.message, 6500);
    }
  }

  function renderNodes(){
    const div = document.getElementById("nodes_list");
    if(globalNodes.length === 0){
      div.innerHTML = '<div style="padding:16px 0;text-align:center">Список пуст</div>';
      return;
    }
    let h="";
    const normActiveUrl = normalizeUrl((activeUrl||"").trim());
    globalNodes.forEach((n,i)=>{
      const isNodeActive = normalizeUrl((n.full_url||"").trim()) === normActiveUrl;
      const btn = isNodeActive
        ? '<span class="active-badge gradient-bg">Активен</span>'
        : `<button class="btn-action" onclick="connect(${i})">Подключить</button>`;
      h += `<div class="list-row">
              <div><span class="item-name">${n.name||"Server"}</span></div>
              <div><span class="item-ping" id="ping_${i}">-</span> ${btn}</div>
            </div>`;
    });
    div.innerHTML = h;
  }

  async function updateSubs(){
    showLoader();
    try{
      const r = await api('update_subs', {});
      showToast(`Подписка обновлена. Серверов: ${r.count || "?"}`);
      await loadData();
    }catch(e){
      showToast("updateSubs: " + e.message, 7000);
    }finally{
      hideLoader();
    }
  }

  async function saveUrl(){
    const u = document.getElementById('sub_url').value;
    if(!u) return;
    showLoader();
    try{
      const r = await api('update_subs', { url:u });
      showToast(`Ссылка сохранена. Серверов: ${r.count || "?"}`);
      await loadData();
    }catch(e){
      showToast("Подписка: " + e.message, 8000);
    }finally{
      hideLoader();
    }
  }

  async function connect(i){
    if(!confirm(`Подключиться к ${globalNodes[i].name}?`)) return;
    showLoader();
    try{
      await api('apply', { node_url: globalNodes[i].full_url });
      await new Promise(r=>setTimeout(r, 2500));
      await loadData();
    }catch(e){
      showToast("connect: " + e.message, 7000);
    }finally{
      hideLoader();
    }
  }

  async function loadNetwork(){
    try{
      const d = await api('get_network');
      const c = d.clients || [];
      vpnIps = Array.isArray(d.vpn_ips) ? d.vpn_ips : [];
      domains = Array.isArray(d.domains) ? d.domains : [];

      let vh="";
      vpnIps.forEach(ip=>{
        const f = c.find(x=>x.ip===ip);
        if(!f) vh += bvr("Static IP", ip, true);
      });
      c.forEach(x=>{
        const iv = vpnIps.includes(x.ip);
        vh += bvr(x.name, x.ip, iv);
      });
      if(vh==="") vh="<div class='list-row' style='justify-content:center'>Нет устройств</div>";
      document.getElementById("vpn_list").innerHTML = vh;

      let domh="";
      if(domains.length>0){
        domains.forEach(dom=>{
          domh += `<div class="list-row">
                    <div><span class="item-name">${dom}</span></div>
                    <button class="btn-action" onclick="manageDomain('${dom}','del')">Удалить</button>
                  </div>`;
        });
      }else{
        domh="<div class='list-row' style='justify-content:center'>Список пуст</div>";
      }
      document.getElementById('domains_list').innerHTML = domh;

    }catch(e){
      showToast("loadNetwork: " + e.message, 6500);
    }
  }

  function bvr(n,ip,iv){
    const btn = iv
      ? `<button class="active-badge gradient-bg" onclick="toggleVpn('${ip}','del')">Включено</button>`
      : `<button class="btn-action" onclick="toggleVpn('${ip}','add')">Включить</button>`;
    return `<div class="list-row"><div><span class="item-name">${n||"Device"}</span><span class="item-sub">${ip}</span></div>${btn}</div>`;
  }

  async function toggleVpn(ip,a){
    showLoader();
    try{
      await api('manage_vpn', { ip:ip, action:a });
      await new Promise(r=>setTimeout(r, 3000));
      await loadNetwork();
    }catch(e){
      showToast("VPN list: " + e.message, 7000);
    }finally{
      hideLoader();
    }
  }

  function addManualIp(){
    const ip = document.getElementById('manual_ip').value;
    if(ip) toggleVpn(ip,'add');
    document.getElementById('manual_ip').value="";
  }

  async function manageDomain(d,a){
    showLoader();
    try{
      await api('manage_domain', { domain:d, action:a });
      await new Promise(r=>setTimeout(r, 3000));
      await loadNetwork();
    }catch(e){
      showToast("Domains: " + e.message, 7000);
    }finally{
      hideLoader();
    }
  }

  function addDomain(){
    const d=document.getElementById('new_domain').value;
    if(d) manageDomain(d,'add');
    document.getElementById('new_domain').value="";
  }

  async function checkForUpdates(){
    showLoader();
    try{
      const r = await api('check_for_update');
      if(r.status==="update_available"){
        if(confirm(`Доступна новая версия ${r.remote_v} (у вас ${r.local_v}). Обновить?`)){
          await api('perform_update');
          await new Promise(r=>setTimeout(r, 5000));
          location.reload();
        }
      }else if(r.status==="up_to_date"){
        showToast(`У вас последняя версия (${r.local_v}).`);
      }else{
        showToast("Ошибка проверки обновлений.");
      }
    }catch(e){
      showToast("Updates: " + e.message, 7000);
    }finally{
      hideLoader();
    }
  }
</script>
</body>
</html>
EOF

# 7. Автообновление + cron (исправлено без process substitution)
echo "[7/7] Настройка автообновления..."
cat << 'EOF' > /etc/podkop_data/autoupdate.sh
#!/bin/sh
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"
VERSION_FILE="/etc/podkop_data/version"

[ -f "$VERSION_FILE" ] || exit 0

LOCAL_VERSION="$(cat "$VERSION_FILE" 2>/dev/null)"
REMOTE_VERSION="$(curl -fsSL --connect-timeout 8 --max-time 20 "$REMOTE_SCRIPT_URL" 2>/dev/null | sed -n 's/^PANEL_VERSION="\([^"]*\)".*/\1/p' | head -n1)"

if [ -n "$REMOTE_VERSION" ] && [ -n "$LOCAL_VERSION" ] && [ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]; then
  curl -fsSL --connect-timeout 10 --max-time 30 "$REMOTE_SCRIPT_URL" | sh >/dev/null 2>&1
fi
EOF
chmod +x /etc/podkop_data/autoupdate.sh

CRON_JOB="0 4 * * * /etc/podkop_data/autoupdate.sh"
(crontab -l 2>/dev/null | grep -Fv "/etc/podkop_data/autoupdate.sh" ; echo "$CRON_JOB") | crontab -

# Финал
chmod +x /www/podkop_panel/cgi-bin/rpc
sed -i 's/\r$//' /www/podkop_panel/cgi-bin/rpc

/etc/init.d/uhttpd enable >/dev/null 2>&1
/etc/init.d/uhttpd restart >/dev/null 2>&1
/etc/init.d/dnsmasq restart >/dev/null 2>&1

ROUTER_IP="$(uci -q get network.lan.ipaddr)"
[ -z "$ROUTER_IP" ] && ROUTER_IP="192.168.1.1"

echo "================================================="
echo "ГОТОВО! Панель v${PANEL_VERSION} установлена."
echo "Доступ: http://${ROUTER_IP}:2017"
echo "================================================="
