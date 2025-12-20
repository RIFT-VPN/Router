#!/bin/sh

# === PODKOP PANEL INSTALLER & UPDATER (V21) ===
# URL этого скрипта (для автообновления)
SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"
# ВЕРСИЯ ПАНЕЛИ
PANEL_VERSION="1.0"

echo "=== УСТАНОВКА PODKOP PANEL v${PANEL_VERSION} ==="

# 1. Зависимости
echo "[1/7] Установка пакетов..."
opkg update >/dev/null
opkg install curl ca-bundle coreutils-base64 lua >/dev/null

# 2. Создание структуры
echo "[2/7] Настройка системы..."
mkdir -p /www/podkop_panel/cgi-bin
mkdir -p /etc/podkop_data
touch /etc/config/podkop_subs
if [ ! -s /etc/config/podkop_subs ]; then
    echo "config podkop_subs 'config'" > /etc/config/podkop_subs
fi
# Сохраняем текущую версию
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

# 4. Настройка DNS
echo "[4/7] Настройка домена http://rift:2017 ..."
( uci -q delete dhcp.rift && uci commit dhcp ) 2>/dev/null
uci add dhcp domain >/dev/null
uci set dhcp.@domain[-1].name='rift'
uci set dhcp.@domain[-1].ip='192.168.1.1'
uci -q del_list dhcp.@dnsmasq[0].rebind_domain='rift'
uci add_list dhcp.@dnsmasq[0].rebind_domain='rift'
uci commit dhcp

# 5. Создание Backend (RPC)
echo "[5/7] Запись Backend скрипта..."
cat << 'EOF' > /www/podkop_panel/cgi-bin/rpc
#!/usr/bin/lua
-- V21 Backend with Update functionality
function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
function to_json(val) local t=type(val) if t=="table" then local is_array=(#val>0) local parts={} if is_array then for _,v in ipairs(val) do table.insert(parts,to_json(v)) end return"["..table.concat(parts,",").."]" else for k,v in pairs(val) do table.insert(parts,'"'..k..'":'..to_json(v)) end return"{"..table.concat(parts,",").."}" end elseif t=="string" then val=val:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','') return'"'..val..'"' elseif t=="number" or t=="boolean" then return tostring(val) else return"null" end end
function serialize(val) local t=type(val) if t=="table" then local parts={} for k,v in pairs(val) do local key=(type(k)=="number") and""or('["'..k..'"]=') table.insert(parts,key..serialize(v)) end return"{"..table.concat(parts,",").."}" elseif t=="string" then return string.format("%q",val) else return tostring(val) end end
function exec_read(cmd) local h=io.popen(cmd) local r=h:read("*a") h:close() return r and trim(r)or"" end
function exec_silent(cmd) return os.execute(cmd..">/dev/null 2>&1") end
function uci_get(c,s,o) return exec_read("uci -q get "..c.."."..s.."."..o) end
function uci_set(c,s,o,v) local safe=v:gsub("'","'\\''") exec_silent("uci set "..c.."."..s.."."..o.."='"..safe.."'") end
local qs=os.getenv("QUERY_STRING")or"" local params={} for k,v in string.gmatch(qs,"([^&=]+)=([^&=]*)") do params[k]=v:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end) end local method=params.method
print("Content-type: application/json; charset=utf-8\n")
if method=="get_panel_info" then local f=io.open("/etc/podkop_data/version","r") local v=f and f:read("*a")or"0.0" if f then f:close() end print(to_json({version=trim(v)})) os.exit(0) end
if method=="check_for_update" then local remote_script=exec_read("wget -O - https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh 2>/dev/null") local remote_version=remote_script:match('PANEL_VERSION="([%d%.]+)"') local f=io.open("/etc/podkop_data/version","r") local local_version=f and trim(f:read("*a"))or"0.0" if f then f:close() end if remote_version and local_version then if remote_version>local_version then print(to_json({status="update_available",local_v=local_version,remote_v=remote_version})) else print(to_json({status="up_to_date",local_v=local_version,remote_v=remote_version})) end else print('{"status":"error"}') end os.exit(0) end
if method=="perform_update" then exec_silent("sh <(wget -O - https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh)") print('{"status":"ok"}') os.exit(0) end
if method=="get_nodes" then local s,db=pcall(dofile,"/etc/podkop_data/nodes.lua") if not s or type(db)~="table" then db={nodes={}} end local cp=uci_get("podkop","main","proxy_string") local r=exec_silent("pgrep -f podkop") local rn=(r==0)or(r==true) local dp=cp:gsub("%%20"," ") print(to_json({nodes=db.nodes or{},expire=db.expire or"Нет данных",updated=db.updated or"Никогда",active_url=dp,running=rn})) os.exit(0) end
if method=="update_subs" then local url=params.url if not url or url=="" then url=trim(uci_get("podkop_subs","config","url")) end if not url or url=="" then print('{"status":"error","msg":"URL не найден!"}') os.exit(0) end exec_silent("uci -q delete podkop_subs.config.url") uci_set("podkop_subs","config","url",url) exec_silent("uci commit podkop_subs") local h=exec_read("curl -s -L -A 'Mozilla/5.0' -D - -o /dev/null '"..url.."'") local ei="Неизвестно" local ui=h:match("subscription%-userinfo: ([^\r\n]+)") if ui then local et=ui:match("expire=(%d+)") if et then ei=os.date("%Y-%m-%d",tonumber(et)) local total=ui:match("total=(%d+)") local dl=ui:match("download=(%d+)") if total and dl then local lgb=math.floor((tonumber(total)-tonumber(dl))/1073741824*100)/100 ei=ei.." (Ост: "..lgb.." GB)" end end end if ei=="Неизвестно" then local t64=h:match("profile%-title: base64:([%w%+/=]+)") if t64 then local dec=exec_read("echo '"..t64.."' | base64 -d") dec=dec:gsub("RIFT",""):gsub("\n"," "):gsub("^%s+","") ei=dec end end local body=exec_read("curl -s -L -A 'Mozilla/5.0' '"..url.."' | base64 -d") local nodes={} for line in body:gmatch("[^\r\n]+") do if line:match("^vless://") then local ne=line:match("#(.+)$") local n="Server" if ne then n=ne:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end) end local host=line:match("@(.-):")or"unknown" local ti=line:match("security=reality")and"Reality"or"VLESS" table.insert(nodes,{name=n,host=host,type=ti,full_url=line}) end end if#nodes==0 then print('{"status":"error","msg":"Серверы не найдены"}') os.exit(0) end local db={expire=ei,updated=os.date("%Y-%m-%d %H:%M:%S"),nodes=nodes} local f=io.open("/etc/podkop_data/nodes.lua","w") if f then f:write("return "..serialize(db)) f:close() print(to_json({status="ok",count=#nodes})) else print('{"status":"error","msg":"Ошибка записи"}') end os.exit(0) end
if method=="apply" then if params.node_url then local cu=params.node_url:gsub(" ","%%20") uci_set("podkop","main","proxy_string",cu) exec_silent("uci commit podkop") exec_silent("/etc/init.d/podkop restart") print('{"status":"ok"}') else print('{"status":"error"}') end os.exit(0) end
if method=="ping" then local host=params.host if host and host:match("^[a-zA-Z0-9%.%-]+$") then local res=exec_silent("ping -c 1 -W 1 "..host) local ms="timeout" local s="fail" local rb=(res==0)or(res==true) if rb then local out=exec_read("ping -c 1 -W 1 "..host.." | grep 'seq=0'") local val=out:match("time=([%d%.]+)") if val then ms=math.floor(tonumber(val)).." ms" end s="ok" end print(to_json({status=s,time=ms})) else print('{"status":"error"}') end os.exit(0) end
if method=="get_network" then local c={} local f=io.open("/tmp/dhcp.leases","r") if f then for line in f:lines() do local p={} for w in line:gmatch("%S+") do table.insert(p,w) end if#p>=4 then table.insert(c,{ip=p[3],name=p[4],mac=p[2]}) end end f:close() end local vl={} local rl=exec_read("uci -q get podkop.main.fully_routed_ips") for w in rl:gmatch("%S+") do table.insert(vl,w) end local dl={} local rd=exec_read("uci -q get podkop.main.user_domains") for w in rd:gmatch("%S+") do table.insert(dl,w) end print(to_json({clients=c,vpn_ips=vl,domains=dl})) os.exit(0) end
if method=="manage_vpn" then local ip=params.ip local a=params.action if ip and a and ip:match("^%d+%.%d+%.%d+%.%d+$") then if a=="add" then exec_silent("uci add_list podkop.main.fully_routed_ips='"..ip.."'") elseif a=="del" then exec_silent("uci del_list podkop.main.fully_routed_ips='"..ip.."'") end exec_silent("uci commit podkop") exec_silent("/etc/init.d/podkop restart") print('{"status":"ok"}') else print('{"status":"error"}') end os.exit(0) end
if method=="manage_domain" then local d=params.domain local a=params.action if d and a and d:match("^[a-zA-Z0-9%.%-]+$") then if a=="add" then exec_silent("uci set podkop.main.user_domain_list_type='dynamic'") exec_silent("uci add_list podkop.main.user_domains='"..d.."'") elseif a=="del" then exec_silent("uci del_list podkop.main.user_domains='"..d.."'") end exec_silent("uci commit podkop") exec_silent("/etc/init.d/podkop restart") print('{"status":"ok"}') else print('{"status":"error"}') end os.exit(0) end
if method=="get_sub_url" then local u=uci_get("podkop_subs","config","url") print(to_json({url=u})) os.exit(0) end
print('{"error":"unknown method"}')
EOF

# --- FRONTEND (HTML) ---
echo "[6/7] Запись Frontend интерфейса..."
cat << 'EOF' > /www/podkop_panel/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Podkop VPN</title>
    <style>
        :root{--bg-color:#0f0f0f;--card-color:#1c1c1e;--text-color:#fff;--text-sec:#8e8e93;--accent:#bfff00;--accent-dim:#4d6600;--danger:#ff453a}body{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",Roboto,Arial,sans-serif;background:var(--bg-color);margin:0;padding:15px;color:var(--text-color);-webkit-tap-highlight-color:transparent}.container{max-width:600px;margin:0 auto}.card{background:var(--card-color);border-radius:16px;padding:20px;margin-bottom:15px}h3{margin:0 0 15px 0;font-weight:700;font-size:18px}.active-conn{text-align:center}.server-name-big{font-size:20px;font-weight:700;margin-bottom:5px;display:block}.server-meta{color:var(--text-sec);font-size:13px;margin-bottom:20px;display:block}.btn-update{background:var(--accent);color:#000;width:100%;padding:14px;border:none;border-radius:12px;font-weight:700;font-size:16px;cursor:pointer;text-transform:uppercase}.btn-update:active{opacity:.8}.header-row{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px}.btn-ping{background:rgba(255,255,255,.1);color:var(--text-color);border:none;padding:6px 12px;border-radius:20px;font-size:12px;cursor:pointer}table{width:100%;border-collapse:collapse}td{padding:12px 0;border-bottom:1px solid rgba(255,255,255,.05);vertical-align:middle}tr:last-child td{border-bottom:none}.srv-name{font-weight:600;font-size:14px}.srv-ping{font-size:12px;color:var(--text-sec);margin-right:10px;font-family:monospace}.btn-connect{background:rgba(255,255,255,.1);color:#fff;border:none;padding:6px 14px;border-radius:20px;font-size:13px;cursor:pointer}.active-badge{color:var(--accent);font-weight:700;font-size:13px}.url-spoiler{margin-top:15px;padding-top:10px;border-top:1px solid rgba(255,255,255,.05)}.url-toggle{color:var(--text-sec);font-size:12px;text-decoration:underline;cursor:pointer;display:block;text-align:center}.url-input-group{display:none;margin-top:10px;gap:8px}input[type=text]{background:rgba(0,0,0,.3);border:1px solid rgba(255,255,255,.1);color:#fff;padding:10px;border-radius:8px;width:100%;box-sizing:border-box}.btn-save-url{background:rgba(255,255,255,.2);color:#fff;border:none;padding:10px;border-radius:8px;cursor:pointer}.vpn-row{display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid rgba(255,255,255,.05)}.dev-info{font-size:14px;font-weight:600}.dev-sub{display:block;font-size:12px;color:var(--text-sec)}.vpn-switch{background:rgba(255,255,255,.1);padding:6px 12px;border-radius:20px;font-size:11px;font-weight:700;cursor:pointer;text-transform:uppercase}.vpn-switch.on{background:var(--accent-dim);color:var(--accent);border:1px solid var(--accent)}.vpn-switch.off{color:var(--text-sec)}.p-good{color:var(--accent)}.p-avg{color:#ffd60a}.p-bad{color:var(--danger)}.chip-container{display:flex;flex-wrap:wrap;gap:8px}.chip{background:rgba(255,255,255,.1);padding:6px 12px;border-radius:16px;font-size:13px;display:flex;align-items:center;gap:8px}.chip span{color:var(--danger);font-weight:700;cursor:pointer;font-size:16px;line-height:1}.chip:hover span{color:#ff6b61}.preloader-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.85);backdrop-filter:blur(5px);z-index:9999;display:none;flex-direction:column;justify-content:center;align-items:center;transition:opacity .3s}.spinner{width:50px;height:50px;border:4px solid rgba(255,255,255,.1);border-top:4px solid var(--accent);border-radius:50%;animation:spin 1s linear infinite;margin-bottom:20px}.loading-text{color:var(--accent);font-weight:600;font-size:16px;letter-spacing:1px;text-transform:uppercase}.footer{text-align:center;color:var(--text-sec);font-size:12px;margin-top:20px}.footer button{background:0 0;border:none;color:var(--text-sec);text-decoration:underline;cursor:pointer;font-size:12px}@keyframes spin{0%{transform:rotate(0)}100%{transform:rotate(360deg)}}
    </style>
</head>
<body>
<div id="preloader" class="preloader-overlay"><div class="spinner"></div><div class="loading-text" id="loader_text">ЗАГРУЗКА...</div></div>
<div class="container">
    <div class="card active-conn"><span class="server-name-big" id="active_name">Загрузка...</span> <span class="server-meta" id="sub_meta">...</span><button class="btn-update" onclick="updateSubs()">Обновить подписку</button></div>
    <div class="card">
        <div class="header-row"><h3>Серверы</h3><button class="btn-ping" onclick="pingAll()">⚡ Ping</button></div>
        <table id="nodes_table"><tbody><tr><td colspan="3" style="text-align:center;color:#666">Загрузка...</td></tr></tbody></table>
        <div class="url-spoiler"><span class="url-toggle" onclick="toggleUrlInput()">Изменить ссылку подписки</span><div class="url-input-group" id="url_group"><input type="text" id="sub_url" placeholder="vless://..."><button class="btn-save-url" onclick="saveUrl()">OK</button></div></div>
    </div>
    <div class="card">
        <h3>Точечные домены (VPN)</h3>
        <div style="display:flex;gap:8px;margin-bottom:15px"><input type="text" id="new_domain" placeholder="domain.com"><button class="btn-save-url" onclick="addDomain()">+</button></div>
        <div id="domains_list" class="chip-container"><div style="text-align:center;color:#666;width:100%">Загрузка...</div></div>
    </div>
    <div class="card">
        <h3>Полный VPN для устройства</h3>
        <div style="display:flex;gap:8px;margin-bottom:15px"><input type="text" id="manual_ip" placeholder="IP (192.168.1.X)"><button class="btn-save-url" onclick="addManualIp()">+</button></div>
        <div id="vpn_list"><div style="text-align:center;color:#666;font-size:13px">Загрузка...</div></div>
    </div>
    <div class="footer" id="footer">Версия: ... <button onclick="checkForUpdates()">[ Проверить обновления ]</button></div>
</div>
<script>
let globalNodes=[],activeUrl="",vpnIps=[];function showLoader(t="ВЫПОЛНЯЕТСЯ..."){document.getElementById('loader_text').innerText=t;document.getElementById('preloader').style.display='flex'}
function hideLoader(){document.getElementById('preloader').style.display='none'}
async function api(m,p={}){p.method=m;let qs=Object.keys(p).map(k=>k+'='+encodeURIComponent(p[k])).join('&');let r=await fetch('/cgi-bin/rpc?'+qs);return await r.json()}
window.onload=async function(){api('get_sub_url').then(r=>{if(r.url)document.getElementById('sub_url').value=r.url});api('get_panel_info').then(r=>{if(r.version)document.getElementById('footer').innerHTML=`Версия: ${r.version} <button onclick="checkForUpdates()">[ Проверить обновления ]</button>`});loadData();loadNetwork()};async function loadData(){try{let d=await api('get_nodes');globalNodes=d.nodes||[];activeUrl=d.active_url||"";let et=d.expire?"Истекает: "+d.expire:"Нет данных о подписке";document.getElementById('sub_meta').innerText=et;let an="Нет подключения";if(activeUrl){let n=globalNodes.find(x=>x.full_url.trim()===activeUrl.trim());if(n)an=n.name;else{let m=activeUrl.match(/#(.*)$/);if(m)an=decodeURIComponent(m[1])}}document.getElementById('active_name').innerText=an;renderNodes()}catch(e){}}
function renderNodes(){let tb=document.querySelector("#nodes_table tbody");if(globalNodes.length===0){tb.innerHTML='<tr><td colspan="3" style="text-align:center;padding:10px;">Список пуст</td></tr>';return}let h="";globalNodes.forEach((n,i)=>{let ia=n.full_url.trim()===activeUrl.trim();let btn=ia?'<span class="active-badge">● Active</span>':`<button class="btn-connect" onclick="connect(${i})">Подключить</button>`;h+=`<tr><td><span class="srv-name">${n.name}</span></td><td style="text-align:right;width:60px;"><span id="ping_${i}" class="srv-ping">-</span></td><td style="text-align:right;width:90px;">${btn}</td></tr>`});tb.innerHTML=h}
async function updateSubs(){showLoader("ОБНОВЛЕНИЕ...");try{let r=await api('update_subs',{});if(r.status==='ok')await loadData();else alert("Ошибка: "+(r.msg||"Неизвестная"))}catch(e){alert("Сбой сети")}finally{hideLoader()}}
function toggleUrlInput(){let e=document.getElementById('url_group');e.style.display=e.style.display==='flex'?'none':'flex'}
async function saveUrl(){let u=document.getElementById('sub_url').value;if(!u)return;showLoader("СОХРАНЕНИЕ...");try{await api('update_subs',{url:u});await loadData();toggleUrlInput()}catch(e){alert("Ошибка")}finally{hideLoader()}}
async function connect(i){if(!confirm(`Подключиться к ${globalNodes[i].name}?`))return;showLoader("ПОДКЛЮЧЕНИЕ...");try{await api('apply',{node_url:globalNodes[i].full_url});await new Promise(r=>setTimeout(r,2500));await loadData()}catch(e){alert("Ошибка")}finally{hideLoader()}}
async function pingAll(){for(let i=0;i<globalNodes.length;i++){let e=document.getElementById(`ping_${i}`);e.innerText="...";api('ping',{host:globalNodes[i].host}).then(r=>{let ms=parseInt(r.time);let c=r.status!=='ok'?'p-bad':ms<150?'p-good':'p-avg';e.innerHTML=`<span class="${c}">${r.time}</span>`});await new Promise(r=>setTimeout(r,100))}}
async function loadNetwork(){try{let d=await api('get_network');let c=d.clients||[];let v=d.vpn_ips;if(!Array.isArray(v))v=[];let dh="";v.forEach(ip=>{let f=c.find(x=>x.ip===ip);if(!f)dh+=bvr("Static IP",ip,!0)});c.forEach(x=>{let iv=v.includes(x.ip);dh+=bvr(x.name,x.ip,iv)});if(dh==="")dh="<div style='text-align:center;color:#666'>Нет устройств</div>";document.getElementById("vpn_list").innerHTML=dh;let doms=d.domains;if(!Array.isArray(doms))doms=[];let domh="";if(doms.length>0)doms.forEach(dom=>{domh+=`<div class="chip">${dom} <span onclick="manageDomain('${dom}','del')">×</span></div>`});else domh="<small style='color:#999'>Список пуст</small>";document.getElementById('domains_list').innerHTML=domh}catch(e){}}
function bvr(n,ip,iv){let c=iv?"vpn-switch on":"vpn-switch off";let t=iv?"ВКЛЮЧЕНО":"ВЫКЛЮЧЕНО";let a=iv?"del":"add";return `<div class="vpn-row"><div><span class="dev-info">${n}</span><span class="dev-sub">${ip}</span></div><div class="${c}" onclick="toggleVpn('${ip}','${a}')">${t}</div></div>`}
async function toggleVpn(ip,a){showLoader(a==='add'?"ВКЛЮЧЕНИЕ VPN...":"ОТКЛЮЧЕНИЕ VPN...");try{await api('manage_vpn',{ip:ip,action:a});await new Promise(r=>setTimeout(r,3e3));await loadNetwork()}catch(e){alert("Ошибка")}finally{hideLoader()}}
function addManualIp(){let ip=document.getElementById('manual_ip').value;if(ip)toggleVpn(ip,'add');document.getElementById('manual_ip').value=""}
async function manageDomain(d,a){showLoader("ПРИМЕНЕНИЕ...");try{await api('manage_domain',{domain:d,action:a});await new Promise(r=>setTimeout(r,3e3));await loadNetwork()}catch(e){alert("Ошибка")}finally{hideLoader()}}
function addDomain(){let d=document.getElementById('new_domain').value;if(d)manageDomain(d,'add');document.getElementById('new_domain').value=""}
async function checkForUpdates(){showLoader("ПРОВЕРКА...");try{let r=await api('check_for_update');if(r.status==="update_available"){if(confirm(`Доступна новая версия ${r.remote_v} (у вас ${r.local_v}). Обновить?`)){showLoader("ОБНОВЛЕНИЕ...");await api('perform_update');await new Promise(r=>setTimeout(r,5e3));location.reload()}}else if(r.status==="up_to_date"){alert(`У вас последняя версия (${r.local_v}).`)}else{alert("Ошибка проверки.")}}catch(e){alert("Сбой сети.")}finally{hideLoader()}}
</script>
</body>
</html>
EOF

# 7. Создание скрипта автообновления и Cron задачи
echo "[7/7] Настройка автообновления..."
# Создаем сам скрипт
cat << EOF > /etc/podkop_data/autoupdate.sh
#!/bin/sh
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"
VERSION_FILE="/etc/podkop_data/version"
if [ -f "\$VERSION_FILE" ]; then
    LOCAL_VERSION=\$(cat \$VERSION_FILE)
    REMOTE_VERSION=\$(wget -q -O - "\$REMOTE_SCRIPT_URL" | grep 'PANEL_VERSION=' | cut -d'"' -f2)
    if [ -n "\$REMOTE_VERSION" ] && [ "\$REMOTE_VERSION" != "\$LOCAL_VERSION" ]; then
        # Обновляемся
        sh <(wget -O - "\$REMOTE_SCRIPT_URL") > /dev/null 2>&1
    fi
fi
EOF
chmod +x /etc/podkop_data/autoupdate.sh

# Добавляем задачу в Cron (если ее еще нет)
CRON_JOB="0 4 * * * /etc/podkop_data/autoupdate.sh"
(crontab -l 2>/dev/null | grep -Fv "/etc/podkop_data/autoupdate.sh" ; echo "\$CRON_JOB") | crontab -

# Финальный запуск
chmod +x /www/podkop_panel/cgi-bin/rpc
sed -i 's/\r$//' /www/podkop_panel/cgi-bin/rpc
/etc/init.d/uhttpd enable
/etc/init.d/uhttpd restart
/etc/init.d/dnsmasq restart

echo "================================================="
echo "ГОТОВО! Панель v${PANEL_VERSION} установлена."
echo "Доступ: http://rift:2017"
echo "Автообновление настроено на 4 часа утра."
echo "================================================="
