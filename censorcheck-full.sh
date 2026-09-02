#!/usr/bin/env bash
# censorcheck-full.sh
#
# Temporary VPS self-test for Xray/VLESS (RAW, XHTTP, gRPC), Hysteria2/QUIC,
# and optional RIPE Atlas reachability checks from Russian ASNs.
#
# This script is an independent wrapper. It does NOT embed censorcheck's source.
# If RUN_ORIGINAL=1, it downloads the upstream censorcheck script and runs it
# with its RIPE radar disabled; this script provides its own optional Atlas radar.
#
# License: MIT
# Third-party projects remain under their own licenses:
#   Xray-core: https://github.com/XTLS/Xray-core
#   Hysteria2: https://github.com/apernet/hysteria
#   censorcheck: https://github.com/Nokola-Tesla/censorcheck
#
# Recommended one-liner after publishing to GitHub:
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/censorcheck-full.sh | sudo bash
#
# With RIPE Atlas API key (needed for the external Russian-ASN radar):
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/censorcheck-full.sh | \
#     sudo env RIPE_API_KEY='YOUR_KEY' bash
#
# Optional environment variables:
#   RIPE_API_KEY=...          RIPE Atlas API key. If absent, external radar is skipped.
#   REALITY_SNI=www.microsoft.com
#   PUBLIC_IP=1.2.3.4         Override autodetection.
#   RAW_PORT=443
#   XHTTP_PORT=8443
#   GRPC_PORT=9443
#   HY2_PORT=443              UDP port; may equal RAW_PORT because UDP/TCP differ.
#   RUN_ORIGINAL=1            Run upstream censorcheck outbound checks (default 1).
#   SELFTEST=1                Run local functional protocol tests (default 1).
#   HOLD_SECONDS=0            Keep temporary endpoints alive N seconds after tests.
#   ATLAS_PROBES_PER_ASN=2    Requested probes per Russian ASN.
#   ATLAS_TIMEOUT=120         Seconds to wait for RIPE Atlas results.
#
# Important limitations:
#   * Local self-tests prove that temporary protocol endpoints work, NOT that TSPU
#     allows them from a particular Russian ISP.
#   * RIPE Atlas sslcert checks validate TCP/443 + TLS/REALITY-like reachability
#     from selected Russian ASNs. RIPE Atlas is not an Xray/Hysteria client, so it
#     cannot prove end-to-end XHTTP/gRPC/HY2 protocol success.
#   * For the strongest result, use the printed share links from an actual client
#     inside the Russian ISP you care about (e.g. drkvl speedtest).

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.3.0"

RAW_PORT="${RAW_PORT:-443}"
XHTTP_PORT="${XHTTP_PORT:-8443}"
GRPC_PORT="${GRPC_PORT:-9443}"
HY2_PORT="${HY2_PORT:-443}"
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

C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_CYAN='\033[36m'
C_DIM='\033[2m'
C_BOLD='\033[1m'

log()  { printf '%b%s%b\n' "$C_CYAN" "$*" "$C_RESET"; }
ok()   { printf '%b[OK]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%b[ERROR]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
section() {
  printf '\n%b%s%b\n' "$C_BOLD" "======================================================================" "$C_RESET"
  printf '%b%s%b\n' "$C_BOLD" "$*" "$C_RESET"
  printf '%b%s%b\n' "$C_BOLD" "======================================================================" "$C_RESET"
}

usage() {
  cat <<USAGE
censorcheck-full.sh v${VERSION}

Usage:
  sudo bash censorcheck-full.sh [options]

Options:
  --ripe-key KEY       RIPE Atlas API key
  --ip IPv4            Override public IPv4 autodetection
  --sni HOST           REALITY camouflage SNI/target (default: ${REALITY_SNI})
  --no-original        Do not run upstream censorcheck
  --no-selftest        Do not run local RAW/XHTTP/gRPC/HY2 functional tests
  --hold SECONDS       Keep temporary endpoints alive after checks
  --help               Show this help

Ports can be overridden with environment variables RAW_PORT, XHTTP_PORT,
GRPC_PORT and HY2_PORT.
USAGE
}

while (($#)); do
  case "$1" in
    --ripe-key)
      [[ $# -ge 2 ]] || die "--ripe-key requires a value"
      RIPE_API_KEY="$2"; shift 2 ;;
    --ip)
      [[ $# -ge 2 ]] || die "--ip requires a value"
      PUBLIC_IP="$2"; shift 2 ;;
    --sni)
      [[ $# -ge 2 ]] || die "--sni requires a value"
      REALITY_SNI="$2"; shift 2 ;;
    --no-original)
      RUN_ORIGINAL=0; shift ;;
    --no-selftest)
      SELFTEST=0; shift ;;
    --hold)
      [[ $# -ge 2 ]] || die "--hold requires seconds"
      HOLD_SECONDS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
done

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_port() { is_uint "$1" && ((1 <= 10#$1 && 10#$1 <= 65535)); }
valid_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip" || return 1
  [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for x in "$a" "$b" "$c" "$d"; do
    [[ "$x" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$x >= 0 && 10#$x <= 255)) || return 1
  done
}
valid_hostname() {
  local h="$1"
  [[ ${#h} -le 253 ]] || return 1
  [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$h" == *.* ]] || return 1
}

for p in "$RAW_PORT" "$XHTTP_PORT" "$GRPC_PORT" "$HY2_PORT"; do
  valid_port "$p" || die "Invalid port: $p"
done
is_uint "$HOLD_SECONDS" || die "HOLD_SECONDS must be an integer"
is_uint "$ATLAS_PROBES_PER_ASN" || die "ATLAS_PROBES_PER_ASN must be an integer"
is_uint "$ATLAS_TIMEOUT" || die "ATLAS_TIMEOUT must be an integer"
((ATLAS_PROBES_PER_ASN >= 1 && ATLAS_PROBES_PER_ASN <= 10)) || die "ATLAS_PROBES_PER_ASN must be 1..10"
((ATLAS_TIMEOUT >= 30 && ATLAS_TIMEOUT <= 600)) || die "ATLAS_TIMEOUT must be 30..600"
valid_hostname "$REALITY_SNI" || die "Invalid REALITY_SNI hostname: $REALITY_SNI"
[[ "$RAW_PORT" != "$XHTTP_PORT" && "$RAW_PORT" != "$GRPC_PORT" && "$XHTTP_PORT" != "$GRPC_PORT" ]] || \
  die "RAW_PORT, XHTTP_PORT and GRPC_PORT must be three distinct TCP ports"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  die "Run as root: sudo bash censorcheck-full.sh (TCP/UDP 443 require root)."
fi

install_deps() {
  local need=()
  local cmd
  for cmd in curl unzip python3 openssl ss awk sed grep timeout; do
    command -v "$cmd" >/dev/null 2>&1 || need+=("$cmd")
  done
  ((${#need[@]} == 0)) && return 0

  log "Installing missing dependencies: ${need[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      curl unzip python3 openssl iproute2 gawk sed grep coreutils ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl unzip python3 openssl iproute gawk sed grep coreutils ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip python3 openssl iproute gawk sed grep coreutils ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash curl unzip python3 openssl iproute2 gawk sed grep coreutils ca-certificates
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl unzip python openssl iproute2 gawk sed grep coreutils ca-certificates
  else
    die "Unsupported package manager. Install curl unzip python3 openssl iproute2 awk sed grep coreutils manually."
  fi
}

cleanup() {
  [[ "$CLEANED" == 1 ]] && return 0
  CLEANED=1
  set +e
  for pid in "${CHILD_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  [[ -n "$HY2_SERVER_PID" ]] && kill "$HY2_SERVER_PID" 2>/dev/null
  [[ -n "$XRAY_SERVER_PID" ]] && kill "$XRAY_SERVER_PID" 2>/dev/null
  sleep 0.2
  for pid in "${CHILD_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
  done
  [[ -n "$HY2_SERVER_PID" ]] && kill -9 "$HY2_SERVER_PID" 2>/dev/null
  [[ -n "$XRAY_SERVER_PID" ]] && kill -9 "$XRAY_SERVER_PID" 2>/dev/null
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP"
  set -e
}
trap cleanup EXIT INT TERM HUP

install_deps
TMP="$(mktemp -d /tmp/censorcheck-full.XXXXXX)"
chmod 700 "$TMP"

section "censorcheck-full v${VERSION} — temporary protocol lab"
printf 'Temporary directory: %s\n' "$TMP"
printf 'REALITY target/SNI: %s\n' "$REALITY_SNI"
printf 'Ports: RAW/TCP=%s  XHTTP/TCP=%s  gRPC/TCP=%s  HY2/UDP=%s\n' \
  "$RAW_PORT" "$XHTTP_PORT" "$GRPC_PORT" "$HY2_PORT"

if [[ -z "$PUBLIC_IP" ]]; then
  log "Detecting public IPv4..."
  PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if ! valid_ipv4 "$PUBLIC_IP"; then
    PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
  fi
fi
valid_ipv4 "$PUBLIC_IP" || die "Could not detect a valid public IPv4. Set PUBLIC_IP=1.2.3.4."
ok "Public IPv4: $PUBLIC_IP"

port_busy_tcp() {
  local port="$1"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}
port_busy_udp() {
  local port="$1"
  ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$" || \
  ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

busy=()
port_busy_tcp "$RAW_PORT" && busy+=("TCP/$RAW_PORT")
[[ "$XHTTP_PORT" == "$RAW_PORT" ]] || { port_busy_tcp "$XHTTP_PORT" && busy+=("TCP/$XHTTP_PORT"); }
[[ "$GRPC_PORT" == "$RAW_PORT" || "$GRPC_PORT" == "$XHTTP_PORT" ]] || { port_busy_tcp "$GRPC_PORT" && busy+=("TCP/$GRPC_PORT"); }
port_busy_udp "$HY2_PORT" && busy+=("UDP/$HY2_PORT")
if ((${#busy[@]})); then
  printf '%bBusy test ports:%b %s\n' "$C_RED" "$C_RESET" "${busy[*]}" >&2
  ss -lntup 2>/dev/null | grep -E ":(${RAW_PORT}|${XHTTP_PORT}|${GRPC_PORT}|${HY2_PORT})([^0-9]|$)" >&2 || true
  die "Refusing to stop or overwrite existing services. Choose free ports or use a clean VPS."
fi
ok "Required test ports are free"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    XRAY_ASSET="Xray-linux-64.zip"
    HY2_ASSET="hysteria-linux-amd64"
    ;;
  aarch64|arm64)
    XRAY_ASSET="Xray-linux-arm64-v8a.zip"
    HY2_ASSET="hysteria-linux-arm64"
    ;;
  *)
    die "Unsupported architecture: $ARCH (currently amd64 and arm64 are supported)."
    ;;
esac

section "Downloading temporary Xray-core and Hysteria2"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}"

curl -fL --retry 3 --connect-timeout 10 "$XRAY_URL" -o "$TMP/xray.zip"
unzip -q "$TMP/xray.zip" -d "$TMP/xray"
XRAY="$TMP/xray/xray"
[[ -x "$XRAY" ]] || chmod +x "$XRAY"
[[ -x "$XRAY" ]] || die "Xray binary not found after extraction"
ok "$($XRAY version | head -n1)"

HY2_URL="https://download.hysteria.network/app/latest/${HY2_ASSET}"
curl -fL --retry 3 --connect-timeout 10 "$HY2_URL" -o "$TMP/hysteria"
HYSTERIA="$TMP/hysteria"
chmod +x "$HYSTERIA"
ok "$($HYSTERIA version 2>&1 | head -n1)"

section "Generating one-time credentials"
UUID="$($XRAY uuid | tr -d '\r' | tail -n1)"
KEYOUT="$($XRAY x25519)"
PRIVATE_KEY="$(printf '%s\n' "$KEYOUT" | awk -F': ' 'tolower($1) ~ /^private ?key$/ {print $2; exit}')"
PUBLIC_KEY="$(printf '%s\n' "$KEYOUT" | awk -F': ' '
  /^Password \(PublicKey\)$/ {print $2; exit}
  tolower($1) ~ /^public ?key$/ {print $2; exit}
  tolower($1) == "password" {print $2; exit}
')"
SID="$(openssl rand -hex 8)"
XHTTP_TOKEN="$(openssl rand -hex 12)"
XHTTP_PATH="/assets/${XHTTP_TOKEN}"
GRPC_SERVICE="svc$(openssl rand -hex 8)"
HY2_PASSWORD="$(openssl rand -hex 18)"
[[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$SID" ]] || die "Failed to parse Xray generated credentials"
ok "One-time Xray/HY2 credentials generated"

XRAY_SERVER_CONFIG="$TMP/xray-server.json"
cat > "$XRAY_SERVER_CONFIG" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "vless-raw-reality",
      "listen": "0.0.0.0",
      "port": ${RAW_PORT},
      "protocol": "vless",
      "settings": {
        "users": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SID}"]
        }
      }
    },
    {
      "tag": "vless-xhttp-reality",
      "listen": "0.0.0.0",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "users": [{"id": "${UUID}"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        },
        "realitySettings": {
          "show": false,
          "target": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SID}"]
        }
      }
    },
    {
      "tag": "vless-grpc-reality",
      "listen": "0.0.0.0",
      "port": ${GRPC_PORT},
      "protocol": "vless",
      "settings": {
        "users": [{"id": "${UUID}"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "grpcSettings": {
          "serviceName": "${GRPC_SERVICE}",
          "multiMode": false
        },
        "realitySettings": {
          "show": false,
          "target": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SID}"]
        }
      }
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"}
  ]
}
JSON

if ! "$XRAY" run -test -c "$XRAY_SERVER_CONFIG" >"$TMP/xray-config-test.log" 2>&1; then
  cat "$TMP/xray-config-test.log" >&2
  die "Xray server config validation failed"
fi
ok "Xray config validation passed"

"$XRAY" run -c "$XRAY_SERVER_CONFIG" >"$TMP/xray-server.log" 2>&1 &
XRAY_SERVER_PID=$!

for _ in {1..50}; do
  kill -0 "$XRAY_SERVER_PID" 2>/dev/null || { cat "$TMP/xray-server.log" >&2; die "Xray exited during startup"; }
  if port_busy_tcp "$RAW_PORT" && port_busy_tcp "$XHTTP_PORT" && port_busy_tcp "$GRPC_PORT"; then
    break
  fi
  sleep 0.1
done
port_busy_tcp "$RAW_PORT" || { cat "$TMP/xray-server.log" >&2; die "RAW port did not open"; }
port_busy_tcp "$XHTTP_PORT" || { cat "$TMP/xray-server.log" >&2; die "XHTTP port did not open"; }
port_busy_tcp "$GRPC_PORT" || { cat "$TMP/xray-server.log" >&2; die "gRPC port did not open"; }
ok "Xray temporary endpoints are listening"

# Hysteria2 self-signed certificate, intentionally temporary.
if ! openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
    -keyout "$TMP/hy2.key" -out "$TMP/hy2.crt" \
    -subj "/CN=tspu-check.invalid" \
    -addext "subjectAltName=DNS:tspu-check.invalid,IP:${PUBLIC_IP}" \
    >/dev/null 2>&1; then
  # Compatibility fallback for older OpenSSL builds without -addext.
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
    -keyout "$TMP/hy2.key" -out "$TMP/hy2.crt" \
    -subj "/CN=tspu-check.invalid" >/dev/null 2>&1
fi
chmod 600 "$TMP/hy2.key"

HY2_SERVER_CONFIG="$TMP/hy2-server.yaml"
cat > "$HY2_SERVER_CONFIG" <<YAML
listen: 0.0.0.0:${HY2_PORT}
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

"$HYSTERIA" server -c "$HY2_SERVER_CONFIG" >"$TMP/hy2-server.log" 2>&1 &
HY2_SERVER_PID=$!
for _ in {1..50}; do
  kill -0 "$HY2_SERVER_PID" 2>/dev/null || { cat "$TMP/hy2-server.log" >&2; die "Hysteria2 exited during startup"; }
  if port_busy_udp "$HY2_PORT"; then break; fi
  sleep 0.1
done
port_busy_udp "$HY2_PORT" || { cat "$TMP/hy2-server.log" >&2; die "HY2 UDP port did not open"; }
ok "Hysteria2 temporary endpoint is listening on UDP/${HY2_PORT}"

urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

RAW_URI="vless://${UUID}@${PUBLIC_IP}:${RAW_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}&type=tcp&flow=xtls-rprx-vision#TSPU-RAW"
XHTTP_URI="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}&type=xhttp&path=$(urlencode "$XHTTP_PATH")&mode=auto#TSPU-XHTTP"
GRPC_URI="vless://${UUID}@${PUBLIC_IP}:${GRPC_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}&type=grpc&serviceName=${GRPC_SERVICE}#TSPU-gRPC"
HY2_URI="hysteria2://${HY2_PASSWORD}@${PUBLIC_IP}:${HY2_PORT}/?insecure=1&sni=tspu-check.invalid#TSPU-HY2"

section "Temporary test profiles"
printf '%bRAW/Reality%b\n%s\n\n' "$C_BOLD" "$C_RESET" "$RAW_URI"
printf '%bXHTTP/Reality%b\n%s\n\n' "$C_BOLD" "$C_RESET" "$XHTTP_URI"
printf '%bgRPC/Reality%b\n%s\n\n' "$C_BOLD" "$C_RESET" "$GRPC_URI"
printf '%bHysteria2/QUIC%b\n%s\n' "$C_BOLD" "$C_RESET" "$HY2_URI"
printf '\n%bThese credentials are temporary and will stop working when this script exits.%b\n' "$C_DIM" "$C_RESET"

selftest_xray() {
  local name="$1" port="$2" network="$3" socks_port="$4" flow="$5"
  local cfg="$TMP/client-${name}.json" logf="$TMP/client-${name}.log"
  local user_extra="" transport_extra=""
  [[ -n "$flow" ]] && user_extra=", \"flow\": \"${flow}\""
  case "$network" in
    xhttp) transport_extra=", \"xhttpSettings\": {\"path\": \"${XHTTP_PATH}\", \"mode\": \"auto\"}" ;;
    grpc)  transport_extra=", \"grpcSettings\": {\"serviceName\": \"${GRPC_SERVICE}\", \"multiMode\": false}" ;;
    raw)   transport_extra="" ;;
    *)     warn "$name: unsupported self-test network $network"; return 1 ;;
  esac

  cat > "$cfg" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"listen": "127.0.0.1", "port": ${socks_port}, "protocol": "socks", "settings": {"udp": true}}
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "127.0.0.1",
          "port": ${port},
          "users": [{"id": "${UUID}", "encryption": "none"${user_extra}}]
        }]
      },
      "streamSettings": {
        "network": "${network}",
        "security": "reality",
        "realitySettings": {
          "serverName": "${REALITY_SNI}",
          "fingerprint": "chrome",
          "password": "${PUBLIC_KEY}",
          "shortId": "${SID}"
        }${transport_extra}
      }
    }
  ]
}
JSON

  if ! "$XRAY" run -test -c "$cfg" >"$TMP/client-${name}-config-test.log" 2>&1; then
    warn "$name: client config validation failed"
    sed 's/^/  /' "$TMP/client-${name}-config-test.log" >&2 || true
    return 1
  fi

  "$XRAY" run -c "$cfg" >"$logf" 2>&1 &
  local pid=$!
  CHILD_PIDS+=("$pid")
  for _ in {1..30}; do
    kill -0 "$pid" 2>/dev/null || break
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${socks_port}$" && break
    sleep 0.1
  done
  if timeout 15 curl -fsS --socks5-hostname "127.0.0.1:${socks_port}" \
      --max-time 12 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    ok "$name local end-to-end functional test"
    kill "$pid" 2>/dev/null || true
    return 0
  fi
  warn "$name local end-to-end test FAILED (see $logf while script is running)"
  tail -n 15 "$logf" 2>/dev/null | sed 's/^/  /' >&2 || true
  kill "$pid" 2>/dev/null || true
  return 1
}

SELF_RAW="SKIP"; SELF_XHTTP="SKIP"; SELF_GRPC="SKIP"; SELF_HY2="SKIP"
if [[ "$SELFTEST" == 1 ]]; then
  section "Local functional protocol self-tests"
  if selftest_xray "RAW/Reality" "$RAW_PORT" "raw" 11080 "xtls-rprx-vision"; then SELF_RAW="PASS"; else SELF_RAW="FAIL"; fi

  if selftest_xray "XHTTP/Reality" "$XHTTP_PORT" "xhttp" 11081 ""; then SELF_XHTTP="PASS"; else SELF_XHTTP="FAIL"; fi

  if selftest_xray "gRPC/Reality" "$GRPC_PORT" "grpc" 11082 ""; then SELF_GRPC="PASS"; else SELF_GRPC="FAIL"; fi

  HY2_CLIENT_CONFIG="$TMP/hy2-client.yaml"
  cat > "$HY2_CLIENT_CONFIG" <<YAML
server: 127.0.0.1:${HY2_PORT}
auth: ${HY2_PASSWORD}
tls:
  sni: tspu-check.invalid
  insecure: true
socks5:
  listen: 127.0.0.1:11083
YAML
  "$HYSTERIA" client -c "$HY2_CLIENT_CONFIG" >"$TMP/hy2-client.log" 2>&1 &
  HY2_CLIENT_PID=$!
  CHILD_PIDS+=("$HY2_CLIENT_PID")
  for _ in {1..50}; do
    kill -0 "$HY2_CLIENT_PID" 2>/dev/null || break
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)11083$' && break
    sleep 0.1
  done
  if timeout 15 curl -fsS --socks5-hostname 127.0.0.1:11083 --max-time 12 \
      https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    ok "Hysteria2 local end-to-end functional test"
    SELF_HY2="PASS"
  else
    warn "Hysteria2 local end-to-end test FAILED"
    tail -n 15 "$TMP/hy2-client.log" 2>/dev/null | sed 's/^/  /' >&2 || true
    SELF_HY2="FAIL"
  fi
  kill "$HY2_CLIENT_PID" 2>/dev/null || true
else
  warn "Local protocol self-tests disabled"
fi

run_atlas_radar() {
  [[ -n "$RIPE_API_KEY" ]] || return 2

  section "RIPE Atlas Russian-ASN radar — TCP/${RAW_PORT} + TLS/REALITY fallback"
  printf '%bThis is an external path test. It is not a full VLESS/XHTTP/gRPC/HY2 client test.%b\n' "$C_DIM" "$C_RESET"

  PUBLIC_IP="$PUBLIC_IP" RAW_PORT="$RAW_PORT" REALITY_SNI="$REALITY_SNI" \
  RIPE_API_KEY="$RIPE_API_KEY" ATLAS_PROBES_PER_ASN="$ATLAS_PROBES_PER_ASN" \
  ATLAS_TIMEOUT="$ATLAS_TIMEOUT" python3 - <<'PY'
import json, os, sys, time, urllib.request, urllib.error

API = "https://atlas.ripe.net/api/v2"
KEY = os.environ["RIPE_API_KEY"]
IP = os.environ["PUBLIC_IP"]
PORT = int(os.environ["RAW_PORT"])
SNI = os.environ["REALITY_SNI"]
PER_ASN = int(os.environ["ATLAS_PROBES_PER_ASN"])
TIMEOUT = int(os.environ["ATLAS_TIMEOUT"])

providers = {
    12389: "Rostelecom",
    8402: "Beeline",
    25513: "MGTS",
    8359: "MTS",
    3216: "Beeline/SPb",
    20485: "TTK",
    25490: "RTK-South",
    43727: "MegaFon",
    12714: "MegaFon",
    34757: "Siberian Networks",
    29124: "Iskratelecom",
    12768: "Dom.ru",
}

def request(url, method="GET", data=None):
    headers = {"Accept": "application/json", "User-Agent": "censorcheck-full/0.3"}
    if data is not None:
        headers["Content-Type"] = "application/json"
        headers["Authorization"] = f"Key {KEY}"
        data = json.dumps(data).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())

payload = {
    "definitions": [{
        "target": IP,
        "description": "censorcheck-full Reality/TLS reachability",
        "type": "sslcert",
        "port": PORT,
        "hostname": SNI,
        "af": 4,
    }],
    "probes": [
        {"requested": PER_ASN, "type": "asn", "value": asn,
         "tags": {"include": ["system-ipv4-works"]}}
        for asn in providers
    ],
    "is_oneoff": True,
}

try:
    created = request(f"{API}/measurements/", method="POST", data=payload)
except urllib.error.HTTPError as e:
    body = e.read().decode(errors="replace")
    print(f"ATLAS_API_ERROR HTTP {e.code}: {body[:500]}")
    sys.exit(3)
except Exception as e:
    print(f"ATLAS_API_ERROR: {e}")
    sys.exit(3)

ids = created.get("measurements") or []
if not ids:
    print("ATLAS_API_ERROR: measurement id missing")
    print(json.dumps(created)[:1000])
    sys.exit(3)
msm = ids[0]
print(f"Measurement ID: {msm}")
print(f"https://atlas.ripe.net/measurements/{msm}/")

results = []
deadline = time.time() + TIMEOUT
last_count = -1
last_change = time.time()
expected = len(providers) * PER_ASN
while time.time() < deadline:
    try:
        results = request(f"{API}/measurements/{msm}/results/")
    except Exception:
        results = []
    if len(results) != last_count:
        print(f"Results received: {len(results)}/{expected}")
        last_count = len(results)
        last_change = time.time()
    if len(results) >= expected:
        break
    # Stop after a quiet period once a useful sample has arrived; some ASNs may
    # have fewer connected probes than requested.
    if len(results) >= max(4, len(providers) // 2) and time.time() - last_change >= 15:
        break
    time.sleep(5)

if not results:
    print("ATLAS_NO_RESULTS")
    sys.exit(4)

probe_asn_cache = {}
def probe_asn(prb_id):
    if prb_id in probe_asn_cache:
        return probe_asn_cache[prb_id]
    try:
        p = request(f"{API}/probes/{prb_id}/")
        asn = p.get("asn_v4")
    except Exception:
        asn = None
    probe_asn_cache[prb_id] = asn
    return asn

stats = {asn: {"pass": 0, "tcp": 0, "fail": 0, "total": 0} for asn in providers}
unknown = 0
for r in results:
    asn = probe_asn(r.get("prb_id"))
    if asn not in stats:
        unknown += 1
        continue
    s = stats[asn]
    s["total"] += 1
    if r.get("cert") and not r.get("alert") and not r.get("error"):
        s["pass"] += 1
    elif r.get("ttc") is not None:
        s["tcp"] += 1
    else:
        s["fail"] += 1

print("\nPer-ASN result:")
all_pass = all_total = all_tcp = all_fail = 0
for asn, name in providers.items():
    s = stats[asn]
    all_pass += s["pass"]; all_total += s["total"]; all_tcp += s["tcp"]; all_fail += s["fail"]
    if s["total"] == 0:
        status = "NO_PROBE_RESULT"
    elif s["pass"] == s["total"]:
        status = "PASS"
    elif s["pass"] > 0:
        status = "PARTIAL"
    elif s["tcp"] > 0:
        status = "TCP_ONLY_TLS_FAIL"
    else:
        status = "FAIL"
    print(f"  AS{asn:<6} {name:<20} {status:<18} TLS={s['pass']}/{s['total']} TCP-only={s['tcp']} fail={s['fail']}")

print("\nAtlas summary:")
print(f"  TLS passes : {all_pass}/{all_total}")
print(f"  TCP only   : {all_tcp}")
print(f"  hard fails : {all_fail}")
if unknown:
    print(f"  unclassified probe results: {unknown}")

if all_total == 0:
    print("ATLAS_VERDICT=INCONCLUSIVE")
    sys.exit(5)
ratio = all_pass / all_total
if ratio >= 0.90 and all_fail <= max(1, all_total // 10):
    print("ATLAS_VERDICT=PASS")
elif ratio >= 0.50:
    print("ATLAS_VERDICT=PARTIAL")
else:
    print("ATLAS_VERDICT=FAIL")
PY
}

ATLAS_VERDICT="NOT_TESTED"
if [[ -n "$RIPE_API_KEY" ]]; then
  set +e
  ATLAS_OUTPUT="$(run_atlas_radar 2>&1)"
  ATLAS_RC=$?
  set -e
  printf '%s\n' "$ATLAS_OUTPUT"
  if [[ "$ATLAS_OUTPUT" =~ ATLAS_VERDICT=([A-Z_]+) ]]; then
    ATLAS_VERDICT="${BASH_REMATCH[1]}"
  elif ((ATLAS_RC != 0)); then
    ATLAS_VERDICT="ERROR"
  fi
else
  section "RIPE Atlas Russian-ASN radar"
  warn "Skipped: RIPE_API_KEY is not set."
  printf 'Create an Atlas API key, then run for example:\n'
  printf '  sudo env RIPE_API_KEY=%q bash censorcheck-full.sh\n' 'YOUR_KEY'
fi

if [[ "$RUN_ORIGINAL" == 1 ]]; then
  section "Upstream censorcheck — outbound censorship checks from this VPS"
  printf '%bNote: this part checks what THIS VPS can reach. It is not the Russian-client-to-VPS TSPU test.%b\n' "$C_DIM" "$C_RESET"
  if curl -fsSL --max-time 20 "$ORIGINAL_CENSORCHECK_URL" -o "$TMP/upstream-censorcheck.sh"; then
    # Disable upstream RIPE radar because its current public source contains a
    # placeholder API key. Our Atlas radar above uses RIPE_API_KEY explicitly.
    sed -E 's/^RIPE_API_KEY="Insert the key".*/RIPE_API_KEY=""/' \
      "$TMP/upstream-censorcheck.sh" > "$TMP/upstream-censorcheck-noradar.sh"
    chmod +x "$TMP/upstream-censorcheck-noradar.sh"
    set +e
    bash "$TMP/upstream-censorcheck-noradar.sh"
    ORIGINAL_RC=$?
    set -e
    if ((ORIGINAL_RC == 0)); then
      ok "Upstream censorcheck finished"
    else
      warn "Upstream censorcheck exited with code $ORIGINAL_RC"
    fi
  else
    warn "Could not download upstream censorcheck; continuing"
  fi
fi

section "Summary"
printf 'Server:                %s\n' "$PUBLIC_IP"
printf 'RAW/Reality local:     %s\n' "$SELF_RAW"
printf 'XHTTP/Reality local:   %s\n' "$SELF_XHTTP"
printf 'gRPC/Reality local:    %s\n' "$SELF_GRPC"
printf 'Hysteria2 local:       %s\n' "$SELF_HY2"
printf 'RIPE Atlas TCP/TLS:    %s\n' "$ATLAS_VERDICT"
printf '\n'

if [[ "$SELF_RAW" == PASS && "$SELF_XHTTP" == PASS && "$SELF_GRPC" == PASS && "$SELF_HY2" == PASS ]]; then
  ok "All four temporary protocol endpoints are functionally valid on the VPS"
elif [[ "$SELFTEST" == 1 ]]; then
  warn "At least one local protocol self-test failed; do not interpret external failures as TSPU until local config is fixed"
fi

case "$ATLAS_VERDICT" in
  PASS)
    ok "TCP/${RAW_PORT} + TLS/REALITY fallback was reachable from most returned Russian RIPE Atlas probes"
    ;;
  PARTIAL)
    warn "Russian RIPE Atlas reachability is partial; investigate ISP/region-specific filtering"
    ;;
  FAIL)
    warn "Russian RIPE Atlas probes mostly failed to complete TLS; this is a strong reason to reject/investigate the VPS"
    ;;
  NOT_TESTED)
    warn "TSPU external path was NOT tested because no RIPE_API_KEY was supplied"
    ;;
  ERROR|INCONCLUSIVE)
    warn "RIPE Atlas result is inconclusive/error; do not call the VPS blocked based on this run"
    ;;
esac

printf '\n%bFor exact transport testing from a real Russian ISP, import these temporary links while this script is still running:%b\n' "$C_BOLD" "$C_RESET"
printf 'RAW:   %s\n' "$RAW_URI"
printf 'XHTTP: %s\n' "$XHTTP_URI"
printf 'gRPC:  %s\n' "$GRPC_URI"
printf 'HY2:   %s\n' "$HY2_URI"

if ((HOLD_SECONDS > 0)); then
  section "Holding temporary endpoints for ${HOLD_SECONDS}s"
  printf 'Run your external client/drkvl tests now. Ctrl+C will clean up immediately.\n'
  end=$((SECONDS + HOLD_SECONDS))
  while ((SECONDS < end)); do
    remain=$((end - SECONDS))
    printf '\rRemaining: %4ds ' "$remain"
    sleep 1
  done
  printf '\n'
fi

section "Cleanup"
printf 'Stopping temporary Xray/Hysteria processes and deleting one-time credentials...\n'
cleanup
ok "Cleaned. No persistent Xray/Hysteria service was installed."
trap - EXIT INT TERM HUP
exit 0
