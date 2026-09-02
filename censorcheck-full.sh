#!/usr/bin/env bash
# censorcheck-full-443.sh
#
# Temporary VPS protocol/TSPU lab using ONLY port 443:
#   TCP/443: VLESS RAW+REALITY -> XHTTP+REALITY -> gRPC+REALITY (sequential)
#   UDP/443: Hysteria2/QUIC (runs in parallel; TCP and UDP do not conflict)
#
# Optional RIPE Atlas reachability check from selected Russian ASNs is executed
# while RAW+REALITY is listening on TCP/443.
#
# License: MIT
# Third-party projects remain under their own licenses:
#   Xray-core: https://github.com/XTLS/Xray-core
#   Hysteria2: https://github.com/apernet/hysteria
#   censorcheck: https://github.com/Nokola-Tesla/censorcheck
#
# Typical launch after publishing:
#   wget -qO- https://raw.githubusercontent.com/USER/REPO/main/censorcheck-full.sh | sudo bash
#
# With RIPE Atlas key:
#   wget -qO- URL | sudo env RIPE_API_KEY='YOUR_KEY' bash
#
# To leave EACH TCP transport active for 120s for a real client in Russia:
#   wget -qO- URL | sudo env HOLD_SECONDS=120 bash
#
# Environment:
#   RIPE_API_KEY=...          RIPE Atlas API key; Atlas stage skipped if absent
#   REALITY_SNI=www.microsoft.com
#   PUBLIC_IP=1.2.3.4         optional override
#   PORT=443                  test port; default and recommended 443
#   RUN_ORIGINAL=1            run upstream censorcheck while RAW+HY2 are active
#   SELFTEST=1                local end-to-end functional tests
#   HOLD_SECONDS=0            hold EACH TCP stage N sec for external testing
#   ATLAS_PROBES_PER_ASN=2
#   ATLAS_TIMEOUT=120
#
# Important:
#   Local self-tests prove server configs are functional. They do NOT prove that
#   a particular Russian ISP/TSPU passes the protocol. For exact protocol-level
#   TSPU testing, use the printed temporary link from a client inside that ISP
#   while its stage is active (HOLD_SECONDS > 0).

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.4.1-443"
PORT="${PORT:-443}"
HY2_PORT="$PORT"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
PUBLIC_IP="${PUBLIC_IP:-}"
RIPE_API_KEY="${RIPE_API_KEY:-}"
RUN_ORIGINAL="${RUN_ORIGINAL:-1}"
SELFTEST="${SELFTEST:-1}"
HOLD_SECONDS="${HOLD_SECONDS:-0}"
ATLAS_PROBES_PER_ASN="${ATLAS_PROBES_PER_ASN:-2}"
ATLAS_TIMEOUT="${ATLAS_TIMEOUT:-120}"
ORIGINAL_CENSORCHECK_URL="${ORIGINAL_CENSORCHECK_URL:-https://raw.githubusercontent.com/Nokola-Tesla/censorcheck/main/censorcheck.sh}"

TMP=""
XRAY=""
HYSTERIA=""
XRAY_SERVER_PID=""
HY2_SERVER_PID=""
CHILD_PIDS=()
CLEANED=0

C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
C_CYAN='\033[36m'; C_DIM='\033[2m'; C_BOLD='\033[1m'
log()  { printf '%b%s%b\n' "$C_CYAN" "$*" "$C_RESET"; }
ok()   { printf '%b[OK]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%b[ERROR]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
section() {
  printf '\n%b======================================================================%b\n' "$C_BOLD" "$C_RESET"
  printf '%b%s%b\n' "$C_BOLD" "$*" "$C_RESET"
  printf '%b======================================================================%b\n' "$C_BOLD" "$C_RESET"
}

usage() {
  cat <<USAGE
censorcheck-full.sh v${VERSION}

Usage:
  sudo bash censorcheck-full.sh [options]

Options:
  --ripe-key KEY       RIPE Atlas API key
  --ip IPv4            override public IPv4 autodetection
  --sni HOST           REALITY target/SNI (default: ${REALITY_SNI})
  --hold SECONDS       keep EACH RAW/XHTTP/gRPC stage on TCP/${PORT} for N seconds
  --no-original        skip upstream censorcheck
  --no-selftest        skip local functional protocol tests
  --help               show help

Only one network port is used:
  TCP/${PORT}: RAW -> XHTTP -> gRPC sequentially
  UDP/${PORT}: Hysteria2
USAGE
}

while (($#)); do
  case "$1" in
    --ripe-key) [[ $# -ge 2 ]] || die "--ripe-key requires value"; RIPE_API_KEY="$2"; shift 2 ;;
    --ip) [[ $# -ge 2 ]] || die "--ip requires value"; PUBLIC_IP="$2"; shift 2 ;;
    --sni) [[ $# -ge 2 ]] || die "--sni requires value"; REALITY_SNI="$2"; shift 2 ;;
    --hold) [[ $# -ge 2 ]] || die "--hold requires seconds"; HOLD_SECONDS="$2"; shift 2 ;;
    --no-original) RUN_ORIGINAL=0; shift ;;
    --no-selftest) SELFTEST=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_port() { is_uint "$1" && ((1 <= 10#$1 && 10#$1 <= 65535)); }
valid_ipv4() {
  local ip="$1" a b c d x
  IFS=. read -r a b c d <<<"$ip" || return 1
  [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for x in "$a" "$b" "$c" "$d"; do
    [[ "$x" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$x <= 255)) || return 1
  done
}
valid_hostname() {
  local h="$1"
  [[ ${#h} -le 253 ]] || return 1
  [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$h" == *.* ]]
}

valid_port "$PORT" || die "Invalid PORT=$PORT"
is_uint "$HOLD_SECONDS" || die "HOLD_SECONDS must be integer"
is_uint "$ATLAS_PROBES_PER_ASN" || die "ATLAS_PROBES_PER_ASN must be integer"
is_uint "$ATLAS_TIMEOUT" || die "ATLAS_TIMEOUT must be integer"
((ATLAS_PROBES_PER_ASN >= 1 && ATLAS_PROBES_PER_ASN <= 10)) || die "ATLAS_PROBES_PER_ASN must be 1..10"
((ATLAS_TIMEOUT >= 30 && ATLAS_TIMEOUT <= 600)) || die "ATLAS_TIMEOUT must be 30..600"
valid_hostname "$REALITY_SNI" || die "Invalid REALITY_SNI=$REALITY_SNI"
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root: sudo bash censorcheck-full.sh"

install_deps() {
  local need=() cmd
  for cmd in curl unzip python3 openssl ss awk sed grep timeout; do
    command -v "$cmd" >/dev/null 2>&1 || need+=("$cmd")
  done
  ((${#need[@]} == 0)) && return 0
  log "Installing dependencies: ${need[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl unzip python3 openssl iproute2 gawk sed grep coreutils ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl unzip python3 openssl iproute gawk sed grep coreutils ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip python3 openssl iproute gawk sed grep coreutils ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash curl unzip python3 openssl iproute2 gawk sed grep coreutils ca-certificates
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl unzip python openssl iproute2 gawk sed grep coreutils ca-certificates
  else
    die "Unsupported package manager"
  fi
}

port_busy_tcp() { ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${1}$"; }
port_busy_udp() {
  ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${1}$" || \
  ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${1}$"
}

stop_xray() {
  set +e
  if [[ -n "${XRAY_SERVER_PID:-}" ]]; then
    kill "$XRAY_SERVER_PID" 2>/dev/null
    for _ in {1..20}; do kill -0 "$XRAY_SERVER_PID" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$XRAY_SERVER_PID" 2>/dev/null
    wait "$XRAY_SERVER_PID" 2>/dev/null
  fi
  XRAY_SERVER_PID=""
  set -e
}

cleanup() {
  [[ "$CLEANED" == 1 ]] && return 0
  CLEANED=1
  set +e
  stop_xray
  for pid in "${CHILD_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done
  [[ -n "${HY2_SERVER_PID:-}" ]] && kill "$HY2_SERVER_PID" 2>/dev/null
  sleep 0.2
  for pid in "${CHILD_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null; done
  [[ -n "${HY2_SERVER_PID:-}" ]] && kill -9 "$HY2_SERVER_PID" 2>/dev/null
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP"
  set -e
}
trap cleanup EXIT INT TERM HUP

install_deps
TMP="$(mktemp -d /tmp/censorcheck-full.XXXXXX)"
chmod 700 "$TMP"

section "censorcheck-full v${VERSION} — port 443 only"
printf 'Temporary directory: %s\n' "$TMP"
printf 'REALITY target/SNI: %s\n' "$REALITY_SNI"
printf 'TCP/%s: RAW -> XHTTP -> gRPC sequentially\n' "$PORT"
printf 'UDP/%s: Hysteria2/QUIC\n' "$PORT"

if [[ -z "$PUBLIC_IP" ]]; then
  log "Detecting public IPv4..."
  PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  valid_ipv4 "$PUBLIC_IP" || PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
fi
valid_ipv4 "$PUBLIC_IP" || die "Could not detect public IPv4. Use PUBLIC_IP=1.2.3.4"
ok "Public IPv4: $PUBLIC_IP"

if port_busy_tcp "$PORT" || port_busy_udp "$PORT"; then
  printf '%bPort %s is already in use:%b\n' "$C_RED" "$PORT" "$C_RESET" >&2
  ss -lntup 2>/dev/null | grep -E ":${PORT}([^0-9]|$)" >&2 || true
  die "TCP/${PORT} and UDP/${PORT} must both be free for the temporary test"
fi
ok "TCP/${PORT} and UDP/${PORT} are free"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) XRAY_ASSET="Xray-linux-64.zip"; HY2_ASSET="hysteria-linux-amd64" ;;
  aarch64|arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip"; HY2_ASSET="hysteria-linux-arm64" ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

section "Downloading temporary Xray-core and Hysteria2"
curl -fL --retry 3 --connect-timeout 10 "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}" -o "$TMP/xray.zip"
unzip -q "$TMP/xray.zip" -d "$TMP/xray"
XRAY="$TMP/xray/xray"; chmod +x "$XRAY"
[[ -x "$XRAY" ]] || die "Xray binary missing"
ok "$($XRAY version | head -n1)"

curl -fL --retry 3 --connect-timeout 10 "https://download.hysteria.network/app/latest/${HY2_ASSET}" -o "$TMP/hysteria"
HYSTERIA="$TMP/hysteria"; chmod +x "$HYSTERIA"
HY2_VER="$($HYSTERIA version 2>&1 | head -n1 || true)"
ok "Hysteria2 ${HY2_VER:-binary downloaded}"

section "Generating one-time credentials"
UUID="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
KEYOUT="$($XRAY x25519 2>&1 || true)"
readarray -t KEY_PARSED < <(printf '%s\n' "$KEYOUT" | python3 -c '
import re, sys
text=sys.stdin.read()
text=re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text).replace("\r", "")
priv=pub=""
for raw in text.splitlines():
    line=raw.strip()
    if ":" not in line:
        continue
    k,v=line.split(":",1)
    key=re.sub(r"[^a-z]", "", k.lower())
    v=v.strip().split()[0] if v.strip() else ""
    if key in ("privatekey", "private"):
        priv=v
    elif key in ("passwordpublickey", "publickey", "password"):
        pub=v
# Fallback for future cosmetic output changes: X25519 values are 32-byte base64url strings (43 chars, optional =).
vals=re.findall(r"(?<![A-Za-z0-9_-])([A-Za-z0-9_-]{43}=?)(?![A-Za-z0-9_-])", text)
if not priv and vals:
    priv=vals[0]
if not pub and len(vals) > 1:
    pub=vals[1]
print(priv)
print(pub)
')
PRIVATE_KEY="${KEY_PARSED[0]:-}"
PUBLIC_KEY="${KEY_PARSED[1]:-}"
SID="$(openssl rand -hex 8)"
XHTTP_TOKEN="$(openssl rand -hex 12)"
XHTTP_PATH="/assets/${XHTTP_TOKEN}"
GRPC_SERVICE="svc$(openssl rand -hex 8)"
HY2_PASSWORD="$(openssl rand -hex 18)"
if [[ -z "$UUID" || -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || -z "$SID" ]]; then
  printf '%bXray x25519 output was:%b\n%s\n' "$C_YELLOW" "$C_RESET" "$KEYOUT" >&2
  die "Failed to parse Xray generated REALITY credentials"
fi
ok "One-time credentials generated"

# Temporary HY2 certificate.
if ! openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -keyout "$TMP/hy2.key" -out "$TMP/hy2.crt" \
  -subj "/CN=tspu-check.invalid" \
  -addext "subjectAltName=DNS:tspu-check.invalid,IP:${PUBLIC_IP}" >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
    -keyout "$TMP/hy2.key" -out "$TMP/hy2.crt" \
    -subj "/CN=tspu-check.invalid" >/dev/null 2>&1
fi
chmod 600 "$TMP/hy2.key"
cat > "$TMP/hy2-server.yaml" <<YAML
listen: 0.0.0.0:${PORT}
tls:
  cert: ${TMP}/hy2.crt
  key: ${TMP}/hy2.key
  sniGuard: disable
auth:
  type: password
  password: ${HY2_PASSWORD}
masquerade:
  type: string
  string:
    content: ok
    headers:
      content-type: text/plain
    statusCode: 200
YAML

"$HYSTERIA" server -c "$TMP/hy2-server.yaml" >"$TMP/hy2-server.log" 2>&1 &
HY2_SERVER_PID=$!
for _ in {1..50}; do
  kill -0 "$HY2_SERVER_PID" 2>/dev/null || { cat "$TMP/hy2-server.log" >&2; die "Hysteria2 exited on startup"; }
  port_busy_udp "$PORT" && break
  sleep 0.1
done
port_busy_udp "$PORT" || { cat "$TMP/hy2-server.log" >&2; die "Hysteria2 did not open UDP/${PORT}"; }
ok "Hysteria2 listening on UDP/${PORT}"

urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}
RAW_URI="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}&type=tcp&flow=xtls-rprx-vision#TSPU-RAW-443"
XHTTP_URI="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}&type=xhttp&path=$(urlencode "$XHTTP_PATH")&mode=auto#TSPU-XHTTP-443"
GRPC_URI="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}&type=grpc&serviceName=${GRPC_SERVICE}#TSPU-gRPC-443"
HY2_URI="hysteria2://${HY2_PASSWORD}@${PUBLIC_IP}:${PORT}/?insecure=1&sni=tspu-check.invalid#TSPU-HY2-443"

make_xray_server_config() {
  local network="$1" cfg="$2" users transport
  case "$network" in
    raw)
      users='{"id":"'"${UUID}"'","flow":"xtls-rprx-vision"}'
      transport=''
      ;;
    xhttp)
      users='{"id":"'"${UUID}"'"}'
      transport=',"xhttpSettings":{"path":"'"${XHTTP_PATH}"'","mode":"auto"}'
      ;;
    grpc)
      users='{"id":"'"${UUID}"'"}'
      transport=',"grpcSettings":{"serviceName":"'"${GRPC_SERVICE}"'","multiMode":false}'
      ;;
    *) return 1 ;;
  esac
  cat > "$cfg" <<JSON
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "listen":"0.0.0.0",
    "port":${PORT},
    "protocol":"vless",
    "settings":{"clients":[${users}],"decryption":"none"},
    "streamSettings":{
      "network":"${network}",
      "security":"reality",
      "realitySettings":{
        "show":false,
        "target":"${REALITY_SNI}:443",
        "xver":0,
        "serverNames":["${REALITY_SNI}"],
        "privateKey":"${PRIVATE_KEY}",
        "shortIds":["${SID}"]
      }${transport}
    }
  }],
  "outbounds":[{"tag":"direct","protocol":"freedom"}]
}
JSON
}

start_xray_stage() {
  local network="$1" label="$2" cfg="$TMP/xray-server-${network}.json"
  stop_xray
  if port_busy_tcp "$PORT"; then
    ss -lntp 2>/dev/null | grep -E ":${PORT}([^0-9]|$)" >&2 || true
    die "TCP/${PORT} unexpectedly busy before $label"
  fi
  make_xray_server_config "$network" "$cfg"
  if ! "$XRAY" run -test -c "$cfg" >"$TMP/xray-${network}-config-test.log" 2>&1; then
    cat "$TMP/xray-${network}-config-test.log" >&2
    die "$label server config validation failed"
  fi
  "$XRAY" run -c "$cfg" >"$TMP/xray-server-${network}.log" 2>&1 &
  XRAY_SERVER_PID=$!
  for _ in {1..50}; do
    kill -0 "$XRAY_SERVER_PID" 2>/dev/null || { cat "$TMP/xray-server-${network}.log" >&2; die "$label Xray exited during startup"; }
    port_busy_tcp "$PORT" && break
    sleep 0.1
  done
  port_busy_tcp "$PORT" || { cat "$TMP/xray-server-${network}.log" >&2; die "$label did not open TCP/${PORT}"; }
  ok "$label listening on TCP/${PORT}"
}

selftest_xray() {
  local name="$1" network="$2" socks_port="$3" flow="$4"
  local cfg="$TMP/client-${network}.json" logf="$TMP/client-${network}.log"
  local user_extra="" transport_extra=""
  [[ -n "$flow" ]] && user_extra=',"flow":"'"${flow}"'"'
  case "$network" in
    raw) transport_extra='' ;;
    xhttp) transport_extra=',"xhttpSettings":{"path":"'"${XHTTP_PATH}"'","mode":"auto"}' ;;
    grpc) transport_extra=',"grpcSettings":{"serviceName":"'"${GRPC_SERVICE}"'","multiMode":false}' ;;
    *) return 1 ;;
  esac
  cat > "$cfg" <<JSON
{
  "log":{"loglevel":"warning"},
  "inbounds":[{"listen":"127.0.0.1","port":${socks_port},"protocol":"socks","settings":{"udp":true}}],
  "outbounds":[{
    "protocol":"vless",
    "settings":{"vnext":[{"address":"127.0.0.1","port":${PORT},"users":[{"id":"${UUID}","encryption":"none"${user_extra}}]}]},
    "streamSettings":{
      "network":"${network}",
      "security":"reality",
      "realitySettings":{
        "serverName":"${REALITY_SNI}",
        "fingerprint":"chrome",
        "password":"${PUBLIC_KEY}",
        "shortId":"${SID}"
      }${transport_extra}
    }
  }]
}
JSON
  if ! "$XRAY" run -test -c "$cfg" >"$TMP/client-${network}-config-test.log" 2>&1; then
    warn "$name client config validation failed"
    sed 's/^/  /' "$TMP/client-${network}-config-test.log" >&2 || true
    return 1
  fi
  "$XRAY" run -c "$cfg" >"$logf" 2>&1 &
  local pid=$!; CHILD_PIDS+=("$pid")
  for _ in {1..40}; do
    kill -0 "$pid" 2>/dev/null || break
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${socks_port}$" && break
    sleep 0.1
  done
  if timeout 18 curl -fsS --socks5-hostname "127.0.0.1:${socks_port}" --max-time 15 \
      https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    ok "$name local end-to-end functional test"
    kill "$pid" 2>/dev/null || true
    return 0
  fi
  warn "$name local end-to-end test FAILED"
  tail -n 20 "$logf" 2>/dev/null | sed 's/^/  /' >&2 || true
  kill "$pid" 2>/dev/null || true
  return 1
}

selftest_hy2() {
  cat > "$TMP/hy2-client.yaml" <<YAML
server: 127.0.0.1:${PORT}
auth: ${HY2_PASSWORD}
tls:
  sni: tspu-check.invalid
  insecure: true
socks5:
  listen: 127.0.0.1:11083
YAML
  "$HYSTERIA" client -c "$TMP/hy2-client.yaml" >"$TMP/hy2-client.log" 2>&1 &
  local pid=$!; CHILD_PIDS+=("$pid")
  for _ in {1..50}; do
    kill -0 "$pid" 2>/dev/null || break
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)11083$' && break
    sleep 0.1
  done
  if timeout 18 curl -fsS --socks5-hostname 127.0.0.1:11083 --max-time 15 \
      https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    ok "Hysteria2/QUIC UDP/${PORT} local end-to-end functional test"
    kill "$pid" 2>/dev/null || true
    return 0
  fi
  warn "Hysteria2 local end-to-end test FAILED"
  tail -n 20 "$TMP/hy2-client.log" 2>/dev/null | sed 's/^/  /' >&2 || true
  kill "$pid" 2>/dev/null || true
  return 1
}

hold_stage() {
  local label="$1" uri="$2"
  ((HOLD_SECONDS > 0)) || return 0
  section "$label external test window — ${HOLD_SECONDS}s"
  printf '%s\n\n' "$uri"
  printf 'Test this profile NOW from the Russian ISP. TCP/%s is currently %s.\n' "$PORT" "$label"
  local end=$((SECONDS + HOLD_SECONDS)) remain
  while ((SECONDS < end)); do
    remain=$((end - SECONDS)); printf '\rRemaining: %4ds ' "$remain"; sleep 1
  done
  printf '\n'
}

run_atlas_radar() {
  [[ -n "$RIPE_API_KEY" ]] || return 2
  section "RIPE Atlas Russian-ASN radar — TCP/${PORT}"
  printf '%bExternal TCP/TLS path test while RAW+REALITY is active. Not a full VLESS transport test.%b\n' "$C_DIM" "$C_RESET"
  PUBLIC_IP="$PUBLIC_IP" PORT="$PORT" REALITY_SNI="$REALITY_SNI" RIPE_API_KEY="$RIPE_API_KEY" \
  ATLAS_PROBES_PER_ASN="$ATLAS_PROBES_PER_ASN" ATLAS_TIMEOUT="$ATLAS_TIMEOUT" python3 - <<'PY'
import json, os, sys, time, urllib.request, urllib.error
API="https://atlas.ripe.net/api/v2"
KEY=os.environ["RIPE_API_KEY"]; IP=os.environ["PUBLIC_IP"]; PORT=int(os.environ["PORT"])
SNI=os.environ["REALITY_SNI"]; PER=int(os.environ["ATLAS_PROBES_PER_ASN"]); TIMEOUT=int(os.environ["ATLAS_TIMEOUT"])
providers={12389:"Rostelecom",8359:"MTS",8402:"Beeline",25513:"MGTS",3216:"Beeline/SPb",20485:"TTK",25490:"RTK-South",43727:"MegaFon",12714:"MegaFon",12768:"Dom.ru"}
def req(url, method="GET", data=None):
    h={"Accept":"application/json","User-Agent":"censorcheck-full/0.4"}
    if data is not None:
        h["Content-Type"]="application/json"; h["Authorization"]=f"Key {KEY}"; data=json.dumps(data).encode()
    r=urllib.request.Request(url,data=data,headers=h,method=method)
    with urllib.request.urlopen(r,timeout=20) as x: return json.loads(x.read().decode())
payload={"definitions":[{"target":IP,"description":"censorcheck-full TCP443 Reality reachability","type":"sslcert","port":PORT,"hostname":SNI,"af":4}],"probes":[{"requested":PER,"type":"asn","value":a,"tags":{"include":["system-ipv4-works"]}} for a in providers],"is_oneoff":True}
try: created=req(f"{API}/measurements/", "POST", payload)
except urllib.error.HTTPError as e:
    print(f"ATLAS_API_ERROR HTTP {e.code}: {e.read().decode(errors='replace')[:700]}"); sys.exit(3)
except Exception as e: print(f"ATLAS_API_ERROR: {e}"); sys.exit(3)
ids=created.get("measurements") or []
if not ids: print("ATLAS_API_ERROR: no measurement id"); print(json.dumps(created)[:1000]); sys.exit(3)
msm=ids[0]; print(f"Measurement ID: {msm}"); print(f"https://atlas.ripe.net/measurements/{msm}/")
results=[]; deadline=time.time()+TIMEOUT; last=-1; last_change=time.time(); expected=len(providers)*PER
while time.time()<deadline:
    try: results=req(f"{API}/measurements/{msm}/results/")
    except Exception: results=[]
    if len(results)!=last: print(f"Results received: {len(results)}/{expected}"); last=len(results); last_change=time.time()
    if len(results)>=expected: break
    if len(results)>=max(4,len(providers)//2) and time.time()-last_change>=15: break
    time.sleep(5)
if not results: print("ATLAS_NO_RESULTS"); print("ATLAS_VERDICT=INCONCLUSIVE"); sys.exit(4)
cache={}
def asn_for(pid):
    if pid in cache: return cache[pid]
    try: a=req(f"{API}/probes/{pid}/").get("asn_v4")
    except Exception: a=None
    cache[pid]=a; return a
stats={a:{"pass":0,"tcp":0,"fail":0,"total":0} for a in providers}
for r in results:
    a=asn_for(r.get("prb_id"))
    if a not in stats: continue
    s=stats[a]; s["total"]+=1
    if r.get("cert") and not r.get("alert") and not r.get("error"): s["pass"]+=1
    elif r.get("ttc") is not None: s["tcp"]+=1
    else: s["fail"]+=1
print("\nPer-ASN result:")
P=T=TCP=F=0
for a,n in providers.items():
    s=stats[a]; P+=s["pass"]; T+=s["total"]; TCP+=s["tcp"]; F+=s["fail"]
    if s["total"]==0: status="NO_RESULT"
    elif s["pass"]==s["total"]: status="PASS"
    elif s["pass"]>0: status="PARTIAL"
    elif s["tcp"]>0: status="TCP_ONLY_TLS_FAIL"
    else: status="FAIL"
    print(f"  AS{a:<6} {n:<18} {status:<18} TLS={s['pass']}/{s['total']} TCP-only={s['tcp']} fail={s['fail']}")
print(f"\nTLS passes: {P}/{T}; TCP-only: {TCP}; hard fails: {F}")
if T==0: print("ATLAS_VERDICT=INCONCLUSIVE"); sys.exit(5)
r=P/T
if r>=0.90 and F<=max(1,T//10): print("ATLAS_VERDICT=PASS")
elif r>=0.50: print("ATLAS_VERDICT=PARTIAL")
else: print("ATLAS_VERDICT=FAIL")
PY
}

SELF_RAW="SKIP"; SELF_XHTTP="SKIP"; SELF_GRPC="SKIP"; SELF_HY2="SKIP"; ATLAS_VERDICT="NOT_TESTED"

section "HY2 — UDP/${PORT}"
printf 'Profile: %s\n' "$HY2_URI"
if [[ "$SELFTEST" == 1 ]]; then
  if selftest_hy2; then SELF_HY2="PASS"; else SELF_HY2="FAIL"; fi
fi

section "Stage 1/3 — VLESS RAW + REALITY on TCP/${PORT}"
start_xray_stage raw "RAW/Reality"
printf 'Profile: %s\n' "$RAW_URI"
if [[ "$SELFTEST" == 1 ]]; then
  if selftest_xray "RAW/Reality" raw 11080 "xtls-rprx-vision"; then SELF_RAW="PASS"; else SELF_RAW="FAIL"; fi
fi

if [[ -n "$RIPE_API_KEY" ]]; then
  set +e
  ATLAS_OUTPUT="$(run_atlas_radar 2>&1)"; ATLAS_RC=$?
  set -e
  printf '%s\n' "$ATLAS_OUTPUT"
  if [[ "$ATLAS_OUTPUT" =~ ATLAS_VERDICT=([A-Z_]+) ]]; then ATLAS_VERDICT="${BASH_REMATCH[1]}"; elif ((ATLAS_RC != 0)); then ATLAS_VERDICT="ERROR"; fi
else
  warn "RIPE Atlas skipped: RIPE_API_KEY is not set"
fi

if [[ "$RUN_ORIGINAL" == 1 ]]; then
  section "Upstream censorcheck while TCP/443 RAW + UDP/443 HY2 are active"
  if curl -fsSL --max-time 20 "$ORIGINAL_CENSORCHECK_URL" -o "$TMP/upstream-censorcheck.sh"; then
    sed -E 's/^RIPE_API_KEY="Insert the key".*/RIPE_API_KEY=""/' "$TMP/upstream-censorcheck.sh" > "$TMP/upstream-censorcheck-noradar.sh"
    chmod +x "$TMP/upstream-censorcheck-noradar.sh"
    set +e; bash "$TMP/upstream-censorcheck-noradar.sh"; ORIGINAL_RC=$?; set -e
    ((ORIGINAL_RC==0)) && ok "Upstream censorcheck finished" || warn "Upstream censorcheck exited $ORIGINAL_RC"
  else
    warn "Could not download upstream censorcheck"
  fi
fi
hold_stage "RAW/Reality TCP/${PORT}" "$RAW_URI"
stop_xray

section "Stage 2/3 — VLESS XHTTP + REALITY on TCP/${PORT}"
start_xray_stage xhttp "XHTTP/Reality"
printf 'Profile: %s\n' "$XHTTP_URI"
if [[ "$SELFTEST" == 1 ]]; then
  if selftest_xray "XHTTP/Reality" xhttp 11081 ""; then SELF_XHTTP="PASS"; else SELF_XHTTP="FAIL"; fi
fi
hold_stage "XHTTP/Reality TCP/${PORT}" "$XHTTP_URI"
stop_xray

section "Stage 3/3 — VLESS gRPC + REALITY on TCP/${PORT}"
start_xray_stage grpc "gRPC/Reality"
printf 'Profile: %s\n' "$GRPC_URI"
if [[ "$SELFTEST" == 1 ]]; then
  if selftest_xray "gRPC/Reality" grpc 11082 ""; then SELF_GRPC="PASS"; else SELF_GRPC="FAIL"; fi
fi
hold_stage "gRPC/Reality TCP/${PORT}" "$GRPC_URI"
stop_xray

section "Summary"
printf 'Server:                  %s\n' "$PUBLIC_IP"
printf 'Test port:               TCP/%s + UDP/%s only\n' "$PORT" "$PORT"
printf 'RAW/Reality TCP/%s:      %s\n' "$PORT" "$SELF_RAW"
printf 'XHTTP/Reality TCP/%s:    %s\n' "$PORT" "$SELF_XHTTP"
printf 'gRPC/Reality TCP/%s:     %s\n' "$PORT" "$SELF_GRPC"
printf 'Hysteria2 QUIC UDP/%s:   %s\n' "$PORT" "$SELF_HY2"
printf 'RIPE Atlas TCP/TLS/%s:   %s\n' "$PORT" "$ATLAS_VERDICT"

if [[ "$SELFTEST" == 1 && "$SELF_RAW" == PASS && "$SELF_XHTTP" == PASS && "$SELF_GRPC" == PASS && "$SELF_HY2" == PASS ]]; then
  ok "All four protocol implementations work locally using port ${PORT}"
elif [[ "$SELFTEST" == 1 ]]; then
  warn "At least one local protocol self-test failed; fix that before blaming TSPU"
fi
case "$ATLAS_VERDICT" in
  PASS) ok "TCP/${PORT} TLS path reachable from most returned Russian RIPE Atlas probes" ;;
  PARTIAL) warn "Russian RIPE Atlas TCP/TLS reachability is partial" ;;
  FAIL) warn "Russian RIPE Atlas probes mostly failed TCP/TLS to ${PUBLIC_IP}:${PORT}" ;;
  NOT_TESTED) warn "External Russian-ASN radar not run (no RIPE_API_KEY)" ;;
  ERROR|INCONCLUSIVE) warn "RIPE Atlas result is inconclusive/error" ;;
esac

printf '\n%bTemporary profiles used by the stages:%b\n' "$C_BOLD" "$C_RESET"
printf 'RAW:   %s\n' "$RAW_URI"
printf 'XHTTP: %s\n' "$XHTTP_URI"
printf 'gRPC:  %s\n' "$GRPC_URI"
printf 'HY2:   %s\n' "$HY2_URI"
printf '\n%bFor exact TSPU transport verdict, rerun with HOLD_SECONDS=60..180 and test each stage from the Russian ISP.%b\n' "$C_YELLOW" "$C_RESET"

section "Cleanup"
cleanup
ok "Cleaned. Nothing persistent installed."
trap - EXIT INT TERM HUP
exit 0
