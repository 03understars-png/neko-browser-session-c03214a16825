#!/usr/bin/env bash
readonly GATE_CADDY_VERSION=2.11.7
GATE_VERIFIER_PORT=${GATE_VERIFIER_PORT:-9077}
GATE_TAP_PORT=${GATE_TAP_PORT:-9079}       # the gate's WebSocket tap (gate.py's default port)
GATE_METRICS_PORT=${GATE_METRICS_PORT:-9078}   # Caddy's read-only count of open streams, for the gate

gate_caddy() {
  local work=$1 os arch file url sum
  case "$(uname -s)" in
    Linux*) os=linux; arch=amd64; file="caddy_${GATE_CADDY_VERSION}_linux_amd64.tar.gz" ;;
    Darwin*) os=mac; arch=arm64; file="caddy_${GATE_CADDY_VERSION}_mac_arm64.tar.gz" ;;
    MINGW*|MSYS*|CYGWIN*) os=windows; arch=amd64; file="caddy_${GATE_CADDY_VERSION}_windows_amd64.zip" ;;
    *) echo "gate: unknown system $(uname -s)" >&2; return 1 ;;
  esac
  [[ $(uname -m) == aarch64 && $os == linux ]] && file="caddy_${GATE_CADDY_VERSION}_linux_arm64.tar.gz"
  url="https://github.com/caddyserver/caddy/releases/download/v${GATE_CADDY_VERSION}"
  mkdir -p "$work/gate"
  curl -fsSL --retry 4 --retry-delay 3 -o "$work/gate/$file" "$url/$file" &&
    curl -fsSL --retry 4 --retry-delay 3 -o "$work/gate/checksums.txt" "$url/caddy_${GATE_CADDY_VERSION}_checksums.txt" ||
    return 1
  sum=$(grep " $file\$" "$work/gate/checksums.txt" | cut -d' ' -f1)
  if command -v sha512sum >/dev/null; then
    [[ $(sha512sum "$work/gate/$file" | cut -d' ' -f1) == "$sum" ]]
  else
    [[ $(shasum -a 512 "$work/gate/$file" | cut -d' ' -f1) == "$sum" ]]
  fi || { echo "gate: Caddy download did not match its checksum" >&2; return 1; }
  if [[ $file == *.zip ]]; then
    unzip -oq "$work/gate/$file" caddy.exe -d "$work/gate"
  else
    tar -xzf "$work/gate/$file" -C "$work/gate" caddy
  fi
}

gate_start() {
  local upstream=$1 user=$2 password=$3 port=$4 work=$5 here python caddy auth
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -n $password ]] || { echo "gate: no secret" >&2; return 1; }
  [[ -n ${DESKTOP_LOGIN:-} ]] || { echo "gate: no desktop password chosen" >&2; return 1; }
  if [[ -n ${GATE_CADDY_BIN:-} && -x ${GATE_CADDY_BIN:-} ]]; then
    mkdir -p "$work/gate" && ln -sf "$GATE_CADDY_BIN" "$work/gate/caddy" || return 1
  else
    gate_caddy "$work" || return 1
  fi
  caddy="$work/gate/caddy"; [[ -x $caddy.exe ]] && caddy="$caddy.exe"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) python=$(command -v python || command -v python3) ;;  # python3 may be the Store stub
    *) python=$(case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) command -v python || command -v python3 ;; *) command -v python3 || command -v python ;; esac) ;;
  esac
  auth=$(printf '%s:%s' "$user" "$password" | base64 | tr -d '\n')
  local up_auth='Authorization {http.request.header.X-Cb-Auth}'
  [[ -z ${GATE_STRIP_AUTH:-} ]] || up_auth='-Authorization'
  cat >"$work/gate/Caddyfile" <<EOF
{
	admin off
	auto_https off
	persist_config off
	metrics
	servers {
		trusted_proxies static 127.0.0.1/32 ::1/128
	}
}
http://127.0.0.1:$GATE_METRICS_PORT {
	metrics
}
http://:$port {
	bind 127.0.0.1
	request_header -X-Cb-Auth
	handle /__cb/* {
		reverse_proxy 127.0.0.1:$GATE_VERIFIER_PORT
	}
	@ws header_regexp Upgrade (?i)websocket
	handle @ws {
		forward_auth 127.0.0.1:$GATE_VERIFIER_PORT {
			uri /__cb/check
			copy_headers X-Cb-Auth
		}
		reverse_proxy 127.0.0.1:$GATE_TAP_PORT {
			header_up $up_auth
		}
	}
	handle {
		forward_auth 127.0.0.1:$GATE_VERIFIER_PORT {
			uri /__cb/check
			copy_headers X-Cb-Auth
		}
		@page header Sec-Fetch-Mode navigate
		header @page >Cache-Control "no-store"
		reverse_proxy $upstream {
			header_up $up_auth
		}
	}
}
EOF
  chmod 600 "$work/gate/Caddyfile"
  local view_auth=""
  if [[ -n ${DESKTOP_VIEW_LOGIN:-} && -n ${DESKTOP_VIEW_PASSWORD:-} ]]; then
    view_auth="Basic $(printf '%s:%s' "${DESKTOP_VIEW_USER:-$user}" "$DESKTOP_VIEW_PASSWORD" | base64 | tr -d '\n')"
  fi
  local live_file="$work/gate/live"
  command -v cygpath >/dev/null 2>&1 && live_file=$(cygpath -w "$live_file")
  rm -f "$work/gate/live"
  GATE_SECRET="$password" GATE_LOGIN="$DESKTOP_LOGIN" GATE_REPORT_URL="${GATE_REPORT_URL:-}" \
    GATE_IP_HEADER="${GATE_IP_HEADER:-}" \
    GATE_VIEW_LOGIN="${view_auth:+${DESKTOP_VIEW_LOGIN:-}}" GATE_AUTH_FULL="Basic $auth" GATE_AUTH_VIEW="$view_auth" \
    GATE_METRICS_URL="http://127.0.0.1:$GATE_METRICS_PORT/metrics" GATE_TAP_PORT="$GATE_TAP_PORT" \
    GATE_UPSTREAM="${upstream#http://}" GATE_LIVE_FILE="$live_file" GATE_SCALE_FILE="${GATE_SCALE_FILE:-}" \
    GATE_PIN_HOOK="${GATE_PIN_HOOK:-}" \
    nohup "$python" "$here/gate.py" "$GATE_VERIFIER_PORT" </dev/null >"$work/gate/verifier.log" 2>&1 &
  GATE_VERIFIER_PID=$!
  nohup "$caddy" run --config "$work/gate/Caddyfile" --adapter caddyfile </dev/null >"$work/gate/caddy.log" 2>&1 &
  GATE_CADDY_PID=$!
  for _ in {1..30}; do
    if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null | grep -q 401; then return 0; fi
    sleep 1
  done
  echo "gate: did not start" >&2
  tail -n 5 "$work/gate/caddy.log" "$work/gate/verifier.log" >&2
  return 1
}

gate_diag() {
  [[ ( ${SOUND_CHECK:-} == 1 || ${CB_DIAG:-} == 1 || -n ${CB_HANDOFF_TEST:-} ) && -n ${GATE_REPORT_URL:-} ]] || return 0
  local py
  py=$(case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) command -v python || command -v python3 ;; *) command -v python3 || command -v python ;; esac) || return 0
  printf '%s' "$1" | "$py" -c 'import json, sys; print(json.dumps({"event": "diag", "note": sys.stdin.read()[-9000:]}))' |
    curl --silent --max-time 20 --request PUT --header 'Content-Type: application/json' \
      --data-binary @- "$GATE_REPORT_URL" >/dev/null 2>&1 || true
}
