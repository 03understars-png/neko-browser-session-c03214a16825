#!/usr/bin/env bash
set -Eeuo pipefail
RETRY_ALL=()
if curl --help all 2>/dev/null | grep -- '--retry-all-errors' >/dev/null; then RETRY_ALL=(--retry-all-errors); fi

readonly VERSION=v2.1.5
readonly HUB_ID=5MCJ5LD-YRTPPCJ-AIZPF4Q-3W7SZCY-ZC4ZIF5-GBFWDHL-HNLN5ML-CUT6YQ4
readonly HUB_ADDRESS=tcp://140.245.3.194:22000
readonly GUI=127.0.0.1:18384
readonly PERSONAL=(Desktop Documents Downloads Pictures Music Videos)

log() { printf '[live-sync] %s\n' "$*"; }

WINDOWS=""
case $(uname -s) in MINGW* | MSYS* | CYGWIN*) WINDOWS=1 ;; esac
EXE=syncthing
[[ -z $WINDOWS ]] || EXE=syncthing.exe
native() { if [[ -n $WINDOWS ]]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

binary() {
  local dir=$1 os arch name
  case $(uname -s) in Linux) os=linux ;; Darwin) os=macos ;; MINGW* | MSYS* | CYGWIN*) os=windows ;; *) return 1 ;; esac
  case $(uname -m) in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) return 1 ;; esac
  [[ $os == macos ]] && arch=universal
  [[ -x $dir/$EXE ]] && return 0
  name=syncthing-$os-$arch-$VERSION
  if [[ $os == linux ]]; then
    curl --fail --location --silent --show-error --retry 5 "${RETRY_ALL[@]}" --retry-delay 3 \
      "https://github.com/syncthing/syncthing/releases/download/$VERSION/$name.tar.gz" |
      tar -xzf - -C "$dir" --strip-components=1 "$name/syncthing"
  else
    curl --fail --location --silent --show-error --retry 5 "${RETRY_ALL[@]}" --retry-delay 3 \
      "https://github.com/syncthing/syncthing/releases/download/$VERSION/$name.zip" -o "$dir/st.zip"
    unzip -q -j -o "$dir/st.zip" "$name/$EXE" -d "$dir" && rm -f "$dir/st.zip"
  fi
  chmod 0755 "$dir/$EXE"
}

rest() {
  local method=$1 path=$2
  shift 2
  curl --fail --silent --show-error --max-time 20 --request "$method" \
    --header "X-API-Key: $(cat "$STATE/key")" --header 'Content-Type: application/json' \
    "http://$GUI/rest$path" "$@"
}

as_owner() {
  if [[ -n ${OWNER_UID:-} && $(id -u) == 0 ]]; then
    setpriv --reuid="$OWNER_UID" --regid="$OWNER_GID" --clear-groups env HOME="$STATE" "$@"
  else
    "$@"
  fi
}

start() {
  local home=$1 name device
  STATE=$2/syncthing
  OWNER_UID=${3:-}
  OWNER_GID=${4:-}
  [[ -n ${DEVICE_URL:-} ]] || { log "no device link (a burner, or sync is off); skipped"; return 0; }
  mkdir -p "$STATE"
  binary "$STATE" || { log "this machine has no Syncthing build; skipped"; return 0; }
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$STATE/key"
  chmod 0600 "$STATE/key"
  for name in "${PERSONAL[@]}" .stfolder; do mkdir -p "$home/$name"; done
  {
    printf '%s\n' "Kept from before sync *" '.DS_Store' '._*' '.directory' '*.part' '*.crdownload' '(?i)desktop.ini' '(?i)Thumbs.db' '(?i)*.lnk'
    for name in "${PERSONAL[@]}"; do printf '!/%s\n' "$name"; done
    printf '%s\n' '*'
  } >"$home/.stignore"
  if [[ -n $OWNER_UID ]]; then
    name=$(dirname "$home")
    while [[ $name != / ]]; do chmod o+x "$name"; name=$(dirname "$name"); done
    chown -R "$OWNER_UID:$OWNER_GID" "$STATE"
    chown "$OWNER_UID:$OWNER_GID" "$home/.stignore"
    for name in "${PERSONAL[@]}" .stfolder; do chown "$OWNER_UID:$OWNER_GID" "$home/$name"; done
  fi
  as_owner "$STATE/$EXE" generate --home="$(native "$STATE/config")" --no-port-probing >/dev/null
  as_owner sed -i.bak -E 's#<(localAnnounceEnabled|globalAnnounceEnabled|relaysEnabled|natEnabled)>true</#<\1>false</#' \
    "$STATE/config/config.xml" && rm -f "$STATE/config/config.xml.bak"
  STGUIAPIKEY=$(cat "$STATE/key") as_owner "$STATE/$EXE" serve --home="$(native "$STATE/config")" --no-browser \
    --no-upgrade --no-restart --no-port-probing --gui-address="$GUI" >"$STATE/log" 2>&1 &
  echo $! >"$STATE/pid"
  for _ in {1..60}; do rest GET /system/ping >/dev/null 2>&1 && break; sleep 1; done
  rest GET /system/ping >/dev/null || { log "Syncthing did not start"; tail -n 20 "$STATE/log" >&2; return 1; }
  rest PATCH /config/options --data '{"globalAnnounceEnabled":false,"localAnnounceEnabled":false,
    "relaysEnabled":false,"natEnabled":false,"urAccepted":-1,"crashReportingEnabled":false,
    "autoUpgradeIntervalH":0}' >/dev/null
  rest DELETE /config/folders/default >/dev/null 2>&1 || true
  rest PUT "/config/devices/$HUB_ID" --data "{\"deviceID\":\"$HUB_ID\",\"name\":\"hub\",
    \"addresses\":[\"$HUB_ADDRESS\"]}" >/dev/null
  rest PUT /config/folders/files --data "{\"id\":\"files\",\"label\":\"Files\",\"path\":\"$(native "$home")\",
    \"type\":\"sendreceive\",\"ignorePerms\":true,\"fsWatcherEnabled\":true,\"fsWatcherDelayS\":1,\"rescanIntervalS\":600,
    \"devices\":[{\"deviceID\":\"$HUB_ID\"}]}" >/dev/null
  local state=""
  for _ in {1..60}; do
    state=$(rest GET "/db/status?folder=files" | sed -n 's/.*"state": *"\([a-z-]*\)".*/\1/p')
    [[ $state == idle || $state == error ]] && break
    sleep 2
  done
  if [[ $state != idle ]]; then
    log "the folder did not start ($state): $(rest GET "/db/status?folder=files" |
      sed -n 's/.*"error": *"\([^"]*\)".*/\1/p' | head -c 200)"
    return 1
  fi
  device=$(rest GET /system/status | sed -n 's/.*"myID": *"\([A-Z0-9-]*\)".*/\1/p')
  [[ -n $device ]] || { log "no device ID"; return 1; }
  curl --fail --silent --show-error --max-time 20 --retry 5 "${RETRY_ALL[@]}" --request PUT \
    --data "$device" "$DEVICE_URL" >/dev/null
  log "on; this desktop is ${device:0:7}"
}

stop() {
  STATE=$1/syncthing
  [[ -f $STATE/pid ]] || return 0
  local completion
  for _ in {1..30}; do
    completion=$(rest GET "/db/completion?device=$HUB_ID&folder=files" 2>/dev/null |
      sed -n 's/.*"completion": *\([0-9.]*\).*/\1/p')
    [[ $completion == 100 ]] && break
    sleep 2
  done
  kill "$(cat "$STATE/pid")" 2>/dev/null || true
  if [[ -n $WINDOWS ]]; then
    taskkill //F //IM syncthing.exe >/dev/null 2>&1 || true
  else
    pkill -f -- "--home=$STATE/config" 2>/dev/null || true
  fi
  rm -f "$STATE/pid" "$STATE/key"
  [[ -z ${DEVICE_URL:-} ]] || curl --silent --max-time 15 --request DELETE "$DEVICE_URL" >/dev/null || true
  log "off (hub had ${completion:-?}% of this desktop's changes)"
}

case ${1:-} in
  start) shift; start "$@" ;;
  stop) shift; stop "$@" ;;
  *) echo "usage: live-sync.sh start <home> <state-dir> [uid gid] | stop <state-dir>" >&2; exit 2 ;;
esac
