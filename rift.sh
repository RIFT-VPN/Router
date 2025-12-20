#!/bin/sh

# === RIFT PANEL INSTALLER & UPDATER (V23 - Final Fixes) ===
SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"
PANEL_VERSION="2.3" # Обновляем версию из-за фиксов

echo "=== УСТАНОВКА RIFT PANEL v${PANEL_VERSION} ==="

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

# 5. Создание Backend (RPC) - без изменений
echo "[5/7] Запись Backend скрипта..."
cat << 'EOF' > /www/podkop_panel/cgi-bin/rpc
#!/usr/bin/lua
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

# --- FRONTEND (HTML with new design and fixes) ---
echo "[6/7] Запись Frontend интерфейса..."
cat << 'EOF' > /www/podkop_panel/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>RIFT Panel</title>
    <style>
        :root{--bg-color:#F4F7FE;--card-bg:#fff;--text-primary:#1A202C;--text-secondary:#718096;--grad-start:#0068FF;--grad-end:#85D9FE}@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');body{font-family:'Inter',-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background-color:var(--bg-color);margin:0;padding:20px;color:var(--text-primary)}.container{max-width:500px;margin:0 auto}.header{text-align:center;margin-bottom:30px}.logo-svg{width:80px;height:80px}h1{font-size:24px;font-weight:700;color:var(--text-primary);margin:10px 0 0}.card{background:var(--card-bg);border-radius:24px;padding:24px;margin-bottom:20px;box-shadow:0 8px 32px 0 rgba(0,0,0,.05)}h3{margin:0 0 20px;font-weight:600;font-size:18px;color:var(--text-primary)}.gradient-bg{background-image:linear-gradient(90deg,var(--grad-start) 0,var(--grad-end) 100%)}.active-conn-card{color:#fff;text-align:center}.active-conn-card h3{color:rgba(255,255,255,.8);font-size:14px;font-weight:500}.server-name-big{font-size:24px;font-weight:700;margin-bottom:8px;display:block}.server-meta{color:rgba(255,255,255,.8);font-size:14px}.btn-update{background:rgba(255,255,255,.2);color:#fff;width:100%;padding:12px;border:1px solid rgba(255,255,255,.3);border-radius:12px;font-weight:600;font-size:14px;cursor:pointer;margin-top:20px}.list-row{display:flex;align-items:center;justify-content:space-between;padding:16px 0;border-bottom:1px solid #E9EFFE}.list-row:last-child{border-bottom:none;padding-bottom:0}.list-row:first-child{padding-top:0}.item-name{font-weight:600;font-size:15px}.item-sub{display:block;font-size:13px;color:var(--text-secondary)}.item-ping{font-size:14px;margin-right:16px;font-weight:600;color:var(--text-primary)}.btn-action,.active-badge{background:#EEF2FF;border:1px solid #EEF2FF;color:#4A55E0;padding:8px 16px;border-radius:20px;font-size:13px;font-weight:600;cursor:pointer;text-align:center;display:inline-block}.active-badge{color:#fff;cursor:default}.input-group{display:flex;gap:10px;margin-top:20px}input[type=text]{background:#F7FAFC;border:1px solid #E2E8F0;color:var(--text-primary);padding:12px;border-radius:12px;width:100%;box-sizing:border-box;font-size:14px}.btn-apply{color:#fff;border:none;padding:0 20px;border-radius:12px;cursor:pointer;font-size:14px;font-weight:600}.preloader-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.7);backdrop-filter:blur(5px);z-index:9999;display:none;flex-direction:column;justify-content:center;align-items:center}.spinner{width:50px;height:50px;border:4px solid rgba(255,255,255,.1);border-top:4px solid #fff;border-radius:50%;animation:spin 1s linear infinite;margin-bottom:20px}@keyframes spin{0%{transform:rotate(0)}100%{transform:rotate(360deg)}}
    </style>
</head>
<body>
<div id="preloader" class="preloader-overlay"><div class="spinner"></div></div>
<div class="container">
    <header class="header">
        <svg class="logo-svg" viewBox="0 0 936 936" fill="none" xmlns="http://www.w3.org/2000/svg"><rect width="935.497" height="935.497" rx="150" fill="url(#p-grad)"/><path d="M427.959 305.04C451.912 301.277 476.444 304.502 498.611 314.329C533.931 329.986 560.121 360.975 569.673 398.41L612.004 564.321L612.441 566.32C616.717 585.791 603.61 604.812 583.894 607.752L581.979 608.038C572.841 609.401 563.578 606.533 556.808 600.246L554.184 597.81C550.247 594.154 545.073 592.122 539.7 592.122C531.029 592.122 523.225 597.384 519.971 605.421L515.385 616.753C511.664 625.942 504.619 633.392 495.652 637.62L490.775 639.919C481.876 644.115 471.987 645.761 462.209 644.675L449.883 643.304C440.682 642.283 432.315 637.495 426.771 630.081L414.181 613.244C405.972 602.265 389.26 603.093 382.175 614.828L380.271 617.383C371.677 628.923 356.781 633.853 342.999 629.718L341.829 629.368C328.541 625.381 319.248 613.399 318.693 599.537L323.205 517.195C323.903 504.455 323.651 491.682 322.451 478.98L318.51 437.248C317.099 422.315 318.476 407.251 322.569 392.821C335.459 347.378 373.6 313.579 420.264 306.248L427.959 305.04ZM372.907 405.849C359.344 405.849 348.349 421.201 348.349 440.138C348.349 459.075 359.344 474.427 372.907 474.427C386.47 474.427 397.466 459.075 397.466 440.138C397.466 421.201 386.47 405.849 372.907 405.849ZM444.266 405.848C430.703 405.848 419.708 421.2 419.708 440.137C419.708 459.074 430.703 474.426 444.266 474.426C457.829 474.426 468.824 459.074 468.824 440.137C468.824 421.2 457.829 405.848 444.266 405.848Z" fill="white"/><defs><linearGradient id="p-grad" x1="821.778" y1="29.7283" x2="12.3598" y2="1048.38" gradientUnits="userSpaceOnUse"><stop offset=".3" stop-color="#0068FF"/><stop offset="1" stop-color="#85D9FE"/></linearGradient></defs></svg>
        <h1>RIFT</h1>
    </header>
    <div class="card active-conn-card gradient-bg">
        <h3>АКТИВНОЕ ПОДКЛЮЧЕНИЕ</h3><span class="server-name-big" id="active_name">...</span> <span class="server-meta" id="sub_meta">...</span><button class="btn-update" onclick="updateSubs()">Обновить подписку</button>
    </div>
    <div class="card">
        <h3>Серверы</h3>
        <div id="nodes_list"></div>
        <div class="input-group"><input type="text" id="sub_url" placeholder="Ссылка на подписку"><button class="btn-apply gradient-bg" onclick="saveUrl()">Применить</button></div>
    </div>
    <div class="card">
        <h3>Полный VPN для устройства</h3>
        <div class="input-group"><input type="text" id="manual_ip" placeholder="IP адрес (192.168.1.X)"><button class="btn-apply gradient-bg" onclick="addManualIp()">+</button></div>
        <div id="vpn_list" style="margin-top:15px"></div>
    </div>
    <div class="card">
        <h3>Точечные домены (VPN)</h3>
        <div class="input-group"><input type="text" id="new_domain" placeholder="domain.com"><button class="btn-apply gradient-bg" onclick="addDomain()">+</button></div>
        <div id="domains_list" style="margin-top:15px"></div>
    </div>
    <div class="card" style="text-align:center;font-size:14px;color:var(--text-secondary)" id="footer"></div>
</div>
<script>
    function normalizeUrl(url) {
        return url.replace(/&sid=[a-zA-Z0-9]+/g, '');
    }
    let globalNodes=[],activeUrl="",vpnIps=[],domains=[];function showLoader(){document.getElementById('preloader').style.display='flex'}
    function hideLoader(){document.getElementById('preloader').style.display='none'}
    async function api(m,p={}){p.method=m;let qs=Object.keys(p).map(k=>k+'='+encodeURIComponent(p[k])).join('&');let r=await fetch('/cgi-bin/rpc?'+qs);return await r.json()}
    window.onload=async function(){api('get_sub_url').then(r=>{if(r.url)document.getElementById('sub_url').value=r.url});api('get_panel_info').then(r=>{if(r.version)document.getElementById('footer').innerHTML=`Версия: ${r.version} <button class="btn-action" style="margin-left:10px;padding:6px 12px;font-size:12px" onclick="checkForUpdates()">Обновить</button>`});loadData();loadNetwork()};async function loadData(){try{let d=await api('get_nodes');globalNodes=d.nodes||[];activeUrl=d.active_url||"";let et=d.expire?"Истекает: "+d.expire:"Нет данных о подписке";document.getElementById('sub_meta').innerText=et;let an="Нет подключения";if(activeUrl){let normActiveUrl=normalizeUrl(activeUrl.trim());let n=globalNodes.find(x=>normalizeUrl(x.full_url.trim())===normActiveUrl);if(n)an=n.name;else{let m=activeUrl.match(/#(.*)$/);if(m)an=decodeURIComponent(m[1])}}document.getElementById('active_name').innerText=an;renderNodes()}catch(e){}}
    function renderNodes(){let div=document.getElementById("nodes_list");if(globalNodes.length===0){div.innerHTML='<div style="padding:16px 0;text-align:center">Список пуст</div>';return}let h="";let normActiveUrl=normalizeUrl(activeUrl.trim());globalNodes.forEach((n,i)=>{let isNodeActive=normalizeUrl(n.full_url.trim())===normActiveUrl;let btn=isNodeActive?'<span class="active-badge gradient-bg">Активен</span>':`<button class="btn-action" onclick="connect(${i})">Подключить</button>`;h+=`<div class="list-row"><div><span class="item-name">${n.name}</span></div><div><span class="item-ping" id="ping_${i}">-</span> ${btn}</div></div>`});div.innerHTML=h}
    async function updateSubs(){showLoader();try{let r=await api('update_subs',{});if(r.status==='ok')await loadData();else alert("Ошибка: "+(r.msg||"Неизвестная"))}catch(e){alert("Сбой сети")}finally{hideLoader()}}
    async function saveUrl(){let u=document.getElementById('sub_url').value;if(!u)return;showLoader();try{await api('update_subs',{url:u});await loadData()}catch(e){alert("Ошибка")}finally{hideLoader()}}
    async function connect(i){if(!confirm(`Подключиться к ${globalNodes[i].name}?`))return;showLoader();try{await api('apply',{node_url:globalNodes[i].full_url});await new Promise(r=>setTimeout(r,2500));await loadData()}catch(e){alert("Ошибка")}finally{hideLoader()}}
    async function pingAll(){for(let i=0;i<globalNodes.length;i++){let e=document.getElementById(`ping_${i}`);e.innerText="...";api('ping',{host:globalNodes[i].host}).then(r=>{e.innerText=r.time||"Error"})}}
    async function loadNetwork(){try{let d=await api('get_network');let c=d.clients||[];vpnIps=d.vpn_ips;if(!Array.isArray(vpnIps))vpnIps=[];domains=d.domains;if(!Array.isArray(domains))domains=[];let vh="";vpnIps.forEach(ip=>{let f=c.find(x=>x.ip===ip);if(!f)vh+=bvr("Static IP",ip,!0)});c.forEach(x=>{let iv=vpnIps.includes(x.ip);vh+=bvr(x.name,x.ip,iv)});if(vh==="")vh="<div class='list-row' style='justify-content:center'>Нет устройств</div>";document.getElementById("vpn_list").innerHTML=vh;let domh="";if(domains.length>0)domains.forEach(dom=>{domh+=`<div class="list-row"><div><span class="item-name">${dom}</span></div><button class="btn-action" onclick="manageDomain('${dom}','del')">Удалить</button></div>`});else domh="<div class='list-row' style='justify-content:center'>Список пуст</div>";document.getElementById('domains_list').innerHTML=domh}catch(e){}}
    function bvr(n,ip,iv){let btn=iv?`<button class="active-badge gradient-bg" onclick="toggleVpn('${ip}','del')">Включено</button>`:`<button class="btn-action" onclick="toggleVpn('${ip}','add')">Включить</button>`;return `<div class="list-row"><div><span class="item-name">${n}</span><span class="item-sub">${ip}</span></div>${btn}</div>`}
    async function toggleVpn(ip,a){showLoader();try{await api('manage_vpn',{ip:ip,action:a});await new Promise(r=>setTimeout(r,3e3));await loadNetwork()}catch(e){alert("Ошибка")}finally{hideLoader()}}
    function addManualIp(){let ip=document.getElementById('manual_ip').value;if(ip)toggleVpn(ip,'add');document.getElementById('manual_ip').value=""}
    async function manageDomain(d,a){showLoader();try{await api('manage_domain',{domain:d,action:a});await new Promise(r=>setTimeout(r,3e3));await loadNetwork()}catch(e){alert("Ошибка")}finally{hideLoader()}}
    function addDomain(){let d=document.getElementById('new_domain').value;if(d)manageDomain(d,'add');document.getElementById('new_domain').value=""}
    async function checkForUpdates(){showLoader();try{let r=await api('check_for_update');if(r.status==="update_available"){if(confirm(`Доступна новая версия ${r.remote_v} (у вас ${r.local_v}). Обновить?`)){showLoader();await api('perform_update');await new Promise(r=>setTimeout(r,5e3));location.reload()}}else if(r.status==="up_to_date"){alert(`У вас последняя версия (${r.local_v}).`)}else{alert("Ошибка проверки.")}}catch(e){alert("Сбой сети.")}finally{hideLoader()}}
</script>
</body>
</html>
EOF

# 7. Создание скрипта автообновления и Cron задачи
echo "[7/7] Настройка автообновления..."
cat << EOF > /etc/podkop_data/autoupdate.sh
#!/bin/sh
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/RIFT-VPN/Router/refs/heads/main/rift.sh"
VERSION_FILE="/etc/podkop_data/version"
if [ -f "\$VERSION_FILE" ]; then
    LOCAL_VERSION=\$(cat \$VERSION_FILE)
    REMOTE_VERSION=\$(wget -q -O - "\$REMOTE_SCRIPT_URL" | grep 'PANEL_VERSION=' | cut -d'"' -f2)
    if [ -n "\$REMOTE_VERSION" ] && [ "\$REMOTE_VERSION" != "\$LOCAL_VERSION" ]; then
        sh <(wget -O - "\$REMOTE_SCRIPT_URL") > /dev/null 2>&1
    fi
fi
EOF
chmod +x /etc/podkop_data/autoupdate.sh

# Добавляем задачу в Cron
CRON_JOB="0 4 * * * /etc/podkop_data/autoupdate.sh"
(crontab -l 2>/dev/null | grep -Fv "/etc/podkop_data/autoupdate.sh" ; echo "\$CRON_JOB") | crontab -

# Финал
chmod +x /www/podkop_panel/cgi-bin/rpc
sed -i 's/\r$//' /www/podkop_panel/cgi-bin/rpc
/etc/init.d/uhttpd enable
/etc/init.d/uhttpd restart
/etc/init.d/dnsmasq restart

echo "================================================="
echo "ГОТОВО! Панель v${PANEL_VERSION} установлена."
echo "Доступ: http://rift:2017"
echo "================================================="
