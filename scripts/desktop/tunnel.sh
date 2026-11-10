#!/usr/bin/env bash

tunnel_pid=""
public_url=""
tunnel_failures=0
tunnel_checks=0

tunnel_self() { printf self | openssl dgst -sha256 -hmac "$DESKTOP_PASSWORD" | awk '{print $NF}'; }
tunnel_curl() {
  curl --silent --max-time 15 --doh-url https://1.1.1.1/dns-query --header "X-Cb-Self: $(tunnel_self)" \
    --output /dev/null --write-out '%{http_code}' "$@" || true
}

start_tunnel() {
  start_quick_tunnel && return 0
  kill "$tunnel_pid" 2>/dev/null || true
  printf 'Cloudflare gave no working link; using the app'"'"'s relay.\n' >&2
  start_relay
}

CHISEL_VERSION=1.12.0
chisel_get() {
  [[ -x ${CHISEL:-} ]] && return 0
  local os arch asset sum dir
  case "$(uname -s)" in Darwin) os=darwin ;; MINGW*|MSYS*|CYGWIN*) os=windows ;; *) os=linux ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  case "$os/$arch" in
    darwin/arm64) sum=707a4b932eea214765146504a0df246cefc415b4297af65a80dd67cf69ba85a9 ;;
    darwin/amd64) sum=4aeae36c867f11c8e8c3f2b913a0e063ea3c6d29e1c14a52ed2e6eef8cfc4395 ;;
    linux/arm64) sum=2ec6152cd2c74fe0146d4d79e4e7aa174521368c56e433d55e023a92ea404ec3 ;;
    linux/amd64) sum=f3f180f1d93aa72cce4e6386f98cc06569a0146fbd65eb4423cf83e6434bcfe6 ;;
    windows/*) arch=amd64; sum=600a8ad6f03bc7f6d285fd01ab6a3f8a657204adaafa5666ade9451d18df1ebc ;;
  esac
  dir=$(dirname "$TUNNEL_LOG")
  asset="chisel_${CHISEL_VERSION}_${os}_${arch}$([[ $os == windows ]] && echo .zip || echo .gz)"
  curl -fsSL --retry 3 --max-time 120 -o "$dir/$asset" \
    "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/$asset" || return 1
  local got
  got=$( (sha256sum "$dir/$asset" 2>/dev/null || shasum -a 256 "$dir/$asset") | awk '{print $1}')
  [[ $got == "$sum" ]] || { printf 'chisel download does not match its checksum\n' >&2; return 1; }
  if [[ $os == windows ]]; then
    unzip -oq "$dir/$asset" -d "$dir/chisel-bin" && CHISEL=$(find "$dir/chisel-bin" -name 'chisel*.exe' | head -n 1)
  else
    gunzip -c "$dir/$asset" >"$dir/chisel" && chmod 0755 "$dir/chisel" && CHISEL=$dir/chisel
  fi
  [[ -x ${CHISEL:-} ]]
}

start_relay() {
  [[ -n ${GATE_REPORT_URL:-} ]] || return 1
  chisel_get || return 1
  local info py server auth port host
  info=$(curl -fsS --max-time 20 --retry 2 --request PUT --header 'Content-Type: application/json' \
    --data '{"event":"relay"}' "$GATE_REPORT_URL") || return 1
  py=$(case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) command -v python || command -v python3 ;; *) command -v python3 || command -v python ;; esac)
  read -r server auth port host < <("$py" -c 'import json, sys; d = json.loads(sys.argv[1]); print(d["server"], d["auth"], d["port"], d["host"])' "$info") || return 1
  [[ -n $host ]] || return 1
  "$CHISEL" client --keepalive 25s --max-retry-interval 10s --auth "$auth" "$server" \
    "R:127.0.0.1:$port:${TUNNEL_ORIGIN#http://}" </dev/null >>"$TUNNEL_LOG" 2>&1 &
  tunnel_pid=$!
  public_url="https://$host"
  local _ code good=0
  for _ in {1..30}; do
    code=$(tunnel_curl "$public_url")
    if [[ $code == 401 ]]; then
      good=$((good + 1))
      ((good >= 2)) && { printf 'Relay link: %s\n' "$public_url" >&2; return 0; }
    else
      good=0
    fi
    kill -0 "$tunnel_pid" 2>/dev/null || return 1
    sleep 3
  done
  return 1
}

start_quick_tunnel() {
  local _
  : >"$TUNNEL_LOG"
  "$CLOUDFLARED" tunnel --no-autoupdate --protocol http2 --url "$TUNNEL_ORIGIN" </dev/null >>"$TUNNEL_LOG" 2>&1 &
  tunnel_pid=$!
  public_url=""
  for _ in {1..30}; do
    public_url=$(grep -aEo 'https://[-a-z0-9]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -n 1 || true)
    [[ -n $public_url ]] && break
    kill -0 "$tunnel_pid" 2>/dev/null || return 1
    sleep 2
  done
  [[ -n $public_url ]] || return 1
  local code="" good=0 until=$((SECONDS + 90))
  while (( SECONDS < until )); do
    code=$(tunnel_curl "$public_url")
    if [[ $code == 401 ]]; then
      good=$((good + 1))
      ((good >= 2)) && return 0
    else
      good=0
    fi
    sleep 3
  done
  return 1
}

publish_link() {
  [[ -n ${STATUS_UPLOAD_URL:-} && -n ${STATUS_KEY:-} ]] || return 0
  local dir py
  dir=$(mktemp -d)
  printf '{"status":"ready","gate":true,"url":"%s","username":"%s","password":"%s","relinked_at":"%s"}' "$1" "$OWNER_USER" "$DESKTOP_PASSWORD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$dir/status.json"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in "$dir/status.json" -out "$dir/compute-base-status.enc" -pass env:STATUS_KEY &&
    openssl dgst -sha256 -hmac "$STATUS_KEY" -binary "$dir/compute-base-status.enc" | openssl base64 -A >"$dir/compute-base-status.hmac"
  py=$(case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) command -v python || command -v python3 ;; *) command -v python3 || command -v python ;; esac)
  (cd "$dir" && "$py" -c 'import zipfile; z = zipfile.ZipFile("status.zip", "w"); [z.write(n) for n in ("compute-base-status.enc", "compute-base-status.hmac")]; z.close()')
  curl --fail --silent --show-error --max-time 30 --retry 3 --request PUT --header 'Content-Type: application/zip' \
    --data-binary @"$dir/status.zip" "$STATUS_UPLOAD_URL" >/dev/null
  rm -rf "$dir"
}

tunnel_watch() {
  tunnel_checks=$((tunnel_checks + 1))
  if [[ -n ${RELINK_URL:-} ]] && (( tunnel_checks % 2 == 0 )) &&
    [[ $(curl --silent --max-time 10 --output /dev/null --write-out '%{http_code}' "$RELINK_URL" 2>/dev/null) == 200 ]]; then
    curl --silent --max-time 10 --request DELETE "$RELINK_URL" >/dev/null 2>&1 || true
    printf 'Renew link asked from the app.\n' >&2
    tunnel_failures=3
  elif ! kill -0 "$tunnel_pid" 2>/dev/null; then
    tunnel_failures=3
  elif (( tunnel_checks % 4 == 0 )); then
    case $(tunnel_curl "$public_url") in
      401 | 200 | 404) tunnel_failures=0 ;;
      *) tunnel_failures=$((tunnel_failures + 1)) ;;
    esac
  fi
  (( tunnel_failures >= 3 )) || return 0
  printf 'The secure link stopped answering; opening a new one.\n' >&2
  kill "$tunnel_pid" 2>/dev/null || true
  local attempt
  for attempt in 1 2 3; do
    if start_tunnel; then
      tunnel_failures=0
      printf 'New secure link: %s\n' "$public_url"
      publish_link "$public_url$LINK_SUFFIX" || printf 'The new link could not be reported.\n' >&2
      return 0
    fi
    kill "$tunnel_pid" 2>/dev/null || true
    sleep $((attempt * 10))
  done
  return 1
}
