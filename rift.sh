#!/bin/sh

echo "=== НАЧАЛО УСТАНОВКИ PODKOP PANEL ==="

# 1. Установка зависимостей
echo "[1/6] Установка пакетов..."
opkg update
opkg install curl ca-bundle coreutils-base64 lua

# 2. Создание папок и конфигов
echo "[2/6] Настройка системы..."
mkdir -p /www/podkop_panel/cgi-bin
mkdir -p /etc/podkop_data
touch /etc/config/podkop_subs
# Инициализируем конфиг подписки, если пустой
if [ ! -s /etc/config/podkop_subs ]; then
    echo "config podkop_subs 'config'" > /etc/config/podkop_subs
fi

# 3. Настройка uhttpd (Веб-сервер)
echo "[3/6] Настройка веб-сервера (порт 2017)..."
uci delete uhttpd.podkop_panel 2>/dev/null
uci set uhttpd.podkop_panel=uhttpd
uci add_list uhttpd.podkop_panel.listen_http='0.0.0.0:2017'
uci set uhttpd.podkop_panel.home='/www/podkop_panel'
uci set uhttpd.podkop_panel.rfc1918_filter='0'
uci set uhttpd.podkop_panel.max_requests='10'
uci set uhttpd.podkop_panel.cgi_prefix='/cgi-bin'
uci commit uhttpd

# 4. Настройка DNS (rift -> 192.168.1.1)
echo "[4/6] Настройка домена http://rift:2017 ..."
while uci -q delete dhcp.@domain[-1]; do :; done 2>/dev/null
uci add dhcp domain
uci set dhcp.@domain[-1].name='rift'
uci set dhcp.@domain[-1].ip='192.168.1.1'
# Разрешаем Rebind
uci del_list dhcp.@dnsmasq[0].rebind_domain='rift' 2>/dev/null
uci add_list dhcp.@dnsmasq[0].rebind_domain='rift'
uci commit dhcp

# 5. Создание файлов (Backend + Frontend)
echo "[5/6] Запись файлов программы..."

# --- BACKEND (RPC) ---
cat << 'EOF' > /www/podkop_panel/cgi-bin/rpc
#!/usr/bin/lua

function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

function to_json(val)
    local t = type(val)
    if t == "table" then
        local is_array = (#val > 0)
        local parts = {}
        if is_array then
            for _, v in ipairs(val) do table.insert(parts, to_json(v)) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                table.insert(parts, '"' .. k .. '":' .. to_json(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    elseif t == "string" then
        val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '')
        return '"' .. val .. '"'
    elseif t == "number" or t == "boolean" then return tostring(val)
    else return "null" end
end

function serialize(val)
    local t = type(val)
    if t == "table" then
        local parts = {}
        for k, v in pairs(val) do
            local key = (type(k)=="number") and "" or ('["'..k..'"]=')
            table.insert(parts, key .. serialize(v))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif t == "string" then return string.format("%q", val)
    else return tostring(val) end
end

function exec_read(cmd)
    local h = io.popen(cmd)
    local r = h:read("*a")
    h:close()
    return r and trim(r) or ""
end

function exec_silent(cmd) return os.execute(cmd .. " >/dev/null 2>&1") end

function uci_get(config, section, option)
    return exec_read("uci -q get " .. config .. "." .. section .. "." .. option)
end

function uci_set(config, section, option, value)
    local safe = value:gsub("'", "'\\''")
    exec_silent("uci set " .. config .. "." .. section .. "." .. option .. "='" .. safe .. "'")
end

local qs = os.getenv("QUERY_STRING") or ""
local params = {}
for k, v in string.gmatch(qs, "([^&=]+)=([^&=]*)") do
    params[k] = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end
local method = params.method

print("Content-type: application/json; charset=utf-8\n")

if method == "get_nodes" then
    local status, db = pcall(dofile, "/etc/podkop_data/nodes.lua")
    if not status or type(db) ~= "table" then db = {nodes={}} end
    local current_proxy = uci_get("podkop", "main", "proxy_string")
    local ret = exec_silent("pgrep -f podkop")
    local running = (ret == 0) or (ret == true)
    local decoded_proxy = current_proxy:gsub("%%20", " ")
    print(to_json({nodes = db.nodes or {}, expire = db.expire or "Нет данных", updated = db.updated or "Никогда", active_url = decoded_proxy, running = running}))
    os.exit(0)
end

if method == "update_subs" then
    local url = params.url
    if not url or url == "" then url = trim(uci_get("podkop_subs", "config", "url")) end
    if not url or url == "" then print('{"status":"error", "msg":"URL не найден! Вставьте ссылку."}') os.exit(0) end

    exec_silent("uci -q delete podkop_subs.config.url")
    uci_set("podkop_subs", "config", "url", url)
    exec_silent("uci commit podkop_subs")

    local headers = exec_read("curl -s -L -A 'Mozilla/5.0' -D - -o /dev/null '" .. url .. "'")
    local expire_info = "Неизвестно"
    local userinfo = headers:match("subscription%-userinfo: ([^\r\n]+)")
    if userinfo then
        local expire_ts = userinfo:match("expire=(%d+)")
        if expire_ts then
            expire_info = os.date("%Y-%m-%d", tonumber(expire_ts))
            local total = userinfo:match("total=(%d+)")
            local download = userinfo:match("download=(%d+)")
            if total and download then
                local left_gb = math.floor((tonumber(total) - tonumber(download)) / 1073741824 * 100) / 100
                expire_info = expire_info .. " (Ост: " .. left_gb .. " GB)"
            end
        end
    end
    if expire_info == "Неизвестно" then
        local title_b64 = headers:match("profile%-title: base64:([%w%+/=]+)")
        if title_b64 then
            local decoded = exec_read("echo '" .. title_b64 .. "' | base64 -d")
            decoded = decoded:gsub("RIFT", ""):gsub("\n", " "):gsub("^%s+", "")
            expire_info = decoded
        end
    end

    local body = exec_read("curl -s -L -A 'Mozilla/5.0' '" .. url .. "' | base64 -d")
    local nodes = {}
    for line in body:gmatch("[^\r\n]+") do
        if line:match("^vless://") then
            local name_enc = line:match("#(.+)$")
            local name = "Server"
            if name_enc then name = name_enc:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end) end
            local host = line:match("@(.-):") or "unknown"
            local type_info = line:match("security=reality") and "Reality" or "VLESS"
            table.insert(nodes, { name = name, host = host, type = type_info, full_url = line })
        end
    end
    
    if #nodes == 0 then print('{"status":"error", "msg":"Серверы не найдены"}') os.exit(0) end

    local db = { expire = expire_info, updated = os.date("%Y-%m-%d %H:%M:%S"), nodes = nodes }
    local f = io.open("/etc/podkop_data/nodes.lua", "w")
    if f then f:write("return " .. serialize(db)) f:close() print(to_json({ status = "ok", count = #nodes }))
    else print('{"status":"error", "msg":"Ошибка записи"}') end
    os.exit(0)
end

if method == "apply" then
    if params.node_url then
        local clean_url = params.node_url:gsub(" ", "%%20")
        uci_set("podkop", "main", "proxy_string", clean_url)
        exec_silent("uci commit podkop")
        exec_silent("/etc/init.d/podkop restart")
        print('{"status":"ok"}')
    else print('{"status":"error"}') end
    os.exit(0)
end

if method == "ping" then
    local host = params.host
    if host and host:match("^[a-zA-Z0-9%.%-]+$") then
        local res = exec_silent("ping -c 1 -W 1 " .. host)
        local ms = "timeout"
        local status = "fail"
        local ret_bool = (res == 0) or (res == true) 
        if ret_bool then
            local out = exec_read("ping -c 1 -W 1 " .. host .. " | grep 'seq=0'")
            local val = out:match("time=([%d%.]+)")
            if val then ms = math.floor(tonumber(val)) .. " ms" end
            status = "ok"
        end
        print(to_json({status = status, time = ms}))
    else print('{"status":"error"}') end
    os.exit(0)
end

if method == "get_network" then
    local clients = {}
    local f = io.open("/tmp/dhcp.leases", "r")
    if f then
        for line in f:lines() do
            local parts = {}
            for w in line:gmatch("%S+") do table.insert(parts, w) end
            if #parts >= 4 then table.insert(clients, {ip=parts[3], name=parts[4], mac=parts[2]}) end
        end
        f:close()
    end
    local vpn_list = {}
    local raw_list = exec_read("uci -q get podkop.main.fully_routed_ips")
    for w in raw_list:gmatch("%S+") do table.insert(vpn_list, w) end
    print(to_json({clients = clients, vpn_ips = vpn_list}))
    os.exit(0)
end

if method == "manage_vpn" then
    local ip = params.ip
    local action = params.action 
    if ip and action and ip:match("^%d+%.%d+%.%d+%.%d+$") then
        if action == "add" then exec_silent("uci add_list podkop.main.fully_routed_ips='" .. ip .. "'")
        elseif action == "del" then exec_silent("uci del_list podkop.main.fully_routed_ips='" .. ip .. "'") end
        exec_silent("uci commit podkop")
        exec_silent("/etc/init.d/podkop restart")
        print('{"status":"ok"}')
    else print('{"status":"error"}') end
    os.exit(0)
end

if method == "get_sub_url" then
    local u = uci_get("podkop_subs", "config", "url")
    print(to_json({url = u}))
    os.exit(0)
end
print('{"error":"unknown method"}')
EOF

# --- FRONTEND (HTML) ---
cat << 'EOF' > /www/podkop_panel/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Podkop VPN</title>
    <style>
        :root {
            --bg-color: #0f0f0f; --card-color: #1c1c1e; --text-color: #ffffff;
            --text-sec: #8e8e93; --accent: #bfff00; --accent-dim: #4d6600; --danger: #ff453a;
        }
        body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", Roboto, Arial, sans-serif; background: var(--bg-color); margin: 0; padding: 15px; color: var(--text-color); -webkit-tap-highlight-color: transparent; }
        .container { max-width: 600px; margin: 0 auto; }
        .card { background: var(--card-color); border-radius: 16px; padding: 20px; margin-bottom: 15px; }
        h2, h3 { margin: 0 0 15px 0; font-weight: 700; font-size: 18px; }
        .active-conn { text-align: center; }
        .server-name-big { font-size: 20px; font-weight: 700; margin-bottom: 5px; display: block; }
        .server-meta { color: var(--text-sec); font-size: 13px; margin-bottom: 20px; display: block; }
        .btn-update { background: var(--accent); color: #000; width: 100%; padding: 14px; border: none; border-radius: 12px; font-weight: 700; font-size: 16px; cursor: pointer; text-transform: uppercase; }
        .btn-update:active { opacity: 0.8; }
        .header-row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
        .btn-ping { background: rgba(255,255,255,0.1); color: var(--text-color); border: none; padding: 6px 12px; border-radius: 20px; font-size: 12px; cursor: pointer; }
        table { width: 100%; border-collapse: collapse; }
        td { padding: 12px 0; border-bottom: 1px solid rgba(255,255,255,0.05); vertical-align: middle; }
        tr:last-child td { border-bottom: none; }
        .srv-name { font-weight: 600; font-size: 14px; }
        .srv-ping { font-size: 12px; color: var(--text-sec); margin-right: 10px; font-family: monospace;}
        .btn-connect { background: rgba(255,255,255,0.1); color: #fff; border: none; padding: 6px 14px; border-radius: 20px; font-size: 13px; cursor: pointer; }
        .active-badge { color: var(--accent); font-weight: bold; font-size: 13px; }
        .url-spoiler { margin-top: 15px; padding-top: 10px; border-top: 1px solid rgba(255,255,255,0.05); }
        .url-toggle { color: var(--text-sec); font-size: 12px; text-decoration: underline; cursor: pointer; display: block; text-align: center; }
        .url-input-group { display: none; margin-top: 10px; gap: 8px; }
        input[type="text"] { background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.1); color: #fff; padding: 10px; border-radius: 8px; width: 100%; box-sizing: border-box; }
        .btn-save-url { background: rgba(255,255,255,0.2); color: #fff; border: none; padding: 10px; border-radius: 8px; cursor: pointer; }
        .vpn-row { display: flex; justify-content: space-between; align-items: center; padding: 10px 0; border-bottom: 1px solid rgba(255,255,255,0.05); }
        .dev-info { font-size: 14px; font-weight: 600; }
        .dev-sub { display: block; font-size: 12px; color: var(--text-sec); }
        .vpn-switch { background: rgba(255,255,255,0.1); padding: 6px 12px; border-radius: 20px; font-size: 11px; font-weight: 700; cursor: pointer; text-transform: uppercase; }
        .vpn-switch.on { background: var(--accent-dim); color: var(--accent); border: 1px solid var(--accent); }
        .vpn-switch.off { color: var(--text-sec); }
        .p-good { color: var(--accent); } .p-avg { color: #ffd60a; } .p-bad { color: var(--danger); }
        .preloader-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.85); backdrop-filter: blur(5px); z-index: 9999; display: none; flex-direction: column; justify-content: center; align-items: center; transition: opacity 0.3s; }
        .spinner { width: 50px; height: 50px; border: 4px solid rgba(255, 255, 255, 0.1); border-top: 4px solid var(--accent); border-radius: 50%; animation: spin 1s linear infinite; margin-bottom: 20px; }
        .loading-text { color: var(--accent); font-weight: 600; font-size: 16px; letter-spacing: 1px; text-transform: uppercase; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>
<div id="preloader" class="preloader-overlay"><div class="spinner"></div><div class="loading-text" id="loader_text">ЗАГРУЗКА...</div></div>
<div class="container">
    <div class="card active-conn">
        <span class="server-name-big" id="active_name">Загрузка...</span>
        <span class="server-meta" id="sub_meta">...</span>
        <button class="btn-update" onclick="updateSubs()">Обновить подписку</button>
    </div>
    <div class="card">
        <div class="header-row"><h3>Серверы</h3><button class="btn-ping" onclick="pingAll()">⚡ Ping</button></div>
        <table id="nodes_table"><tbody><tr><td colspan="3" style="text-align:center; color:#666">Загрузка...</td></tr></tbody></table>
        <div class="url-spoiler">
            <span class="url-toggle" onclick="toggleUrlInput()">Изменить ссылку подписки</span>
            <div class="url-input-group" id="url_group"><input type="text" id="sub_url" placeholder="vless://..." /><button class="btn-save-url" onclick="saveUrl()">OK</button></div>
        </div>
    </div>
    <div class="card">
        <h3>Полный VPN для устройства</h3>
        <div style="display:flex; gap:8px; margin-bottom: 15px;"><input type="text" id="manual_ip" placeholder="IP (192.168.1.X)" /><button class="btn-save-url" onclick="addManualIp()">+</button></div>
        <div id="vpn_list"><div style="text-align:center; color:#666; font-size:13px;">Загрузка...</div></div>
    </div>
</div>
<script>
    let globalNodes = [], activeUrl = "", vpnIps = [];
    function showLoader(t="ВЫПОЛНЯЕТСЯ..."){document.getElementById('loader_text').innerText=t;document.getElementById('preloader').style.display='flex'}
    function hideLoader(){document.getElementById('preloader').style.display='none'}
    async function api(m,p={}){p.method=m;let qs=Object.keys(p).map(k=>k+'='+encodeURIComponent(p[k])).join('&');let r=await fetch('/cgi-bin/rpc?'+qs);return await r.json()}
    window.onload=async function(){api('get_sub_url').then(r=>{if(r.url)document.getElementById('sub_url').value=r.url});loadData();loadNetwork()};
    async function loadData(){try{let d=await api('get_nodes');globalNodes=d.nodes||[];activeUrl=d.active_url||"";let et=d.expire?"Истекает: "+d.expire:"Нет данных о подписке";document.getElementById('sub_meta').innerText=et;let an="Нет подключения";if(activeUrl){let n=globalNodes.find(x=>x.full_url.trim()===activeUrl.trim());if(n)an=n.name;else{let m=activeUrl.match(/#(.*)$/);if(m)an=decodeURIComponent(m[1])}}document.getElementById('active_name').innerText=an;renderNodes()}catch(e){}}
    function renderNodes(){let tb=document.querySelector("#nodes_table tbody");if(globalNodes.length===0){tb.innerHTML='<tr><td colspan="3" style="text-align:center; padding:10px;">Список пуст</td></tr>';return}let h="";globalNodes.forEach((n,i)=>{let ia=(n.full_url.trim()===activeUrl.trim());let btn=ia?'<span class="active-badge">● Active</span>':`<button class="btn-connect" onclick="connect(${i})">Подключить</button>`;h+=`<tr><td><span class="srv-name">${n.name}</span></td><td style="text-align:right; width:60px;"><span id="ping_${i}" class="srv-ping">-</span></td><td style="text-align:right; width:90px;">${btn}</td></tr>`});tb.innerHTML=h}
    async function updateSubs(){showLoader("ОБНОВЛЕНИЕ...");try{let r=await api('update_subs',{});if(r.status==='ok')await loadData();else alert("Ошибка: "+(r.msg||"Неизвестная"))}catch(e){alert("Сбой сети")}finally{hideLoader()}}
    function toggleUrlInput(){let e=document.getElementById('url_group');e.style.display=(e.style.display==='flex')?'none':'flex'}
    async function saveUrl(){let u=document.getElementById('sub_url').value;if(!u)return;showLoader("СОХРАНЕНИЕ...");try{await api('update_subs',{url:u});await loadData();toggleUrlInput()}catch(e){alert("Ошибка")}finally{hideLoader()}}
    async function connect(i){if(!confirm(`Подключиться к ${globalNodes[i].name}?`))return;showLoader("ПОДКЛЮЧЕНИЕ...");try{await api('apply',{node_url:globalNodes[i].full_url});await new Promise(r=>setTimeout(r,2500));await loadData()}catch(e){alert("Ошибка")}finally{hideLoader()}}
    async function pingAll(){for(let i=0;i<globalNodes.length;i++){let e=document.getElementById(`ping_${i}`);e.innerText="...";api('ping',{host:globalNodes[i].host}).then(r=>{let ms=parseInt(r.time);let c=(r.status!=='ok')?'p-bad':(ms<150?'p-good':'p-avg');e.innerHTML=`<span class="${c}">${r.time}</span>`});await new Promise(r=>setTimeout(r,100))}}
    async function loadNetwork(){try{let d=await api('get_network');let c=d.clients||[];let v=d.vpn_ips;if(!Array.isArray(v))v=[];let h="";v.forEach(ip=>{let f=c.find(x=>x.ip===ip);if(!f)h+=bvr("Static IP",ip,true)});c.forEach(x=>{let iv=v.includes(x.ip);h+=bvr(x.name,x.ip,iv)});if(h==="")h="<div style='text-align:center;color:#666'>Нет устройств</div>";document.getElementById("vpn_list").innerHTML=h}catch(e){}}
    function bvr(n,ip,iv){let c=iv?"vpn-switch on":"vpn-switch off";let t=iv?"ВКЛЮЧЕНО":"ВЫКЛЮЧЕНО";let a=iv?"del":"add";return `<div class="vpn-row"><div><span class="dev-info">${n}</span><span class="dev-sub">${ip}</span></div><div class="${c}" onclick="toggleVpn('${ip}','${a}')">${t}</div></div>`}
    async function toggleVpn(ip,a){showLoader(a==='add'?"ВКЛЮЧЕНИЕ VPN...":"ОТКЛЮЧЕНИЕ VPN...");try{await api('manage_vpn',{ip:ip,action:a});await new Promise(r=>setTimeout(r,2000));await loadNetwork()}catch(e){alert("Ошибка")}finally{hideLoader()}}
    function addManualIp(){let ip=document.getElementById('manual_ip').value;if(ip)toggleVpn(ip,'add');document.getElementById('manual_ip').value=""}
</script>
</body>
</html>
EOF

# 6. Финал
echo "[6/6] Завершение..."
chmod +x /www/podkop_panel/cgi-bin/rpc
sed -i 's/\r$//' /www/podkop_panel/cgi-bin/rpc
/etc/init.d/uhttpd enable
/etc/init.d/uhttpd restart
/etc/init.d/dnsmasq restart

echo "================================================="
echo "ГОТОВО! Панель доступна: http://rift:2017"
echo "================================================="
