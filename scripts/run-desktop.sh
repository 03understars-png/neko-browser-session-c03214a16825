#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORK_DIR="${RUNNER_TEMP:-/tmp}/compute-base-desktop"
readonly STATE_DIR="$WORK_DIR/state"
readonly LIVE_DIR="$WORK_DIR/live-sync"
readonly KIT="$WORK_DIR/kit"
readonly VIEWER_DIR="$KIT/viewer"
readonly SCRIPTS="$GITHUB_WORKSPACE/scripts"
readonly PROFILE_TOOL="$SCRIPTS/desktop/desktop-sync.sh"
readonly OWNER_USER="owner"
if [[ ${CB_LIMITLESS:-} == 1 ]]; then
  CB_IDLE_SECONDS=999999999 CB_SAFETY_SECONDS=999999999
  printf 'Limitless: no idle stop and no time limit of ours; only Stop ends it.
'
fi
readonly IDLE_SECONDS=${CB_IDLE_SECONDS:-3600}
readonly SAMPLE_SECONDS=15
readonly BURNER=${BURNER:-}
if [[ -n ${CB_SAFETY_SECONDS:-} ]]; then readonly SAFETY_SECONDS=$CB_SAFETY_SECONDS; elif [[ $BURNER == 1 ]]; then readonly SAFETY_SECONDS=13500; else readonly SAFETY_SECONDS=19800; fi  # 5h30m, as on Linux
readonly EXIT_REASON_FILE="$WORK_DIR/exit-reason"
readonly PROFILE_SAVED_FILE="$WORK_DIR/profile-saved"
readonly PROFILE_RESTORED_FILE="$WORK_DIR/profile-restored"
read -r req_w req_h req_scale <<<"${SCREEN:-1920 1080 1}"
even() { local v=${1%.*}; (( v < $2 )) && v=$2; (( v > $3 )) && v=$3; echo $(( v / 2 * 2 )); }
SCREEN_WIDTH=$(even "$req_w" 1024 2560)
SCREEN_HEIGHT=$(even "$req_h" 600 1600)
VIDEO_WIDTH=$(even "$(awk -v a="$SCREEN_WIDTH" -v s="$req_scale" 'BEGIN{printf "%d", a*s}')" 1024 3840)
VIDEO_HEIGHT=$(even "$(awk -v a="$SCREEN_HEIGHT" -v s="$req_scale" 'BEGIN{printf "%d", a*s}')" 600 2400)
readonly SCREEN_WIDTH SCREEN_HEIGHT VIDEO_WIDTH VIDEO_HEIGHT
export VIDEO_WIDTH VIDEO_HEIGHT
readonly SUNSHINE="/Applications/Sunshine.app/Contents/MacOS/Sunshine"
readonly TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"

export DESKTOP_EXTRA_EXCLUDES="CachedData:CachedExtensionVSIXs:CachedProfilesData:ByHost:Chrome:syncthing:compute-base:gh:sunshine:authorized_keys"
export DESKTOP_PATHS="Library/Application Support/BraveSoftware/Brave-Browser:Library/Application Support/Code/User:Library/Application Support/Google:Library/Application Support/LM Studio:Library/Saved Application State:.local/share/cb-handoff:.zshrc:.zprofile:.zshenv:.bash_profile:.bashrc:.gitconfig:.npmrc:.ssh:.config:.hermes/memories:.hermes/skills:.hermes/SOUL.md"
export BRAVE_SUBDIR="Library/Application Support/BraveSoftware/Brave-Browser"
DESKTOP_UID=$(id -u); DESKTOP_GID=$(id -g)
export DESKTOP_UID DESKTOP_GID

pids=()
started_at=$(date +%s)
lim() { perl -e 'alarm shift; exec @ARGV' "$@"; }
q() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/ }; s=${s//$'\r'/}; s=${s//$'\t'/ }; printf '"%s"' "$s"; }
publish() {
  [[ -n ${STATUS_UPLOAD_URL:-} && -n ${STATUS_KEY:-} ]] || return 0
  local dir
  dir=$(mktemp -d)
  printf '%s' "$1" >"$dir/status.json"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in "$dir/status.json" -out "$dir/compute-base-status.enc" -pass env:STATUS_KEY &&
    openssl dgst -sha256 -hmac "$STATUS_KEY" -binary "$dir/compute-base-status.enc" | openssl base64 -A >"$dir/compute-base-status.hmac" &&
    (cd "$dir" && zip -q -X status.zip compute-base-status.enc compute-base-status.hmac) &&
    curl --fail --silent --max-time 20 --retry 2 --request PUT --header 'Content-Type: application/zip' \
      --data-binary @"$dir/status.zip" "$STATUS_UPLOAD_URL" >/dev/null 2>&1
  rm -rf "$dir"
}
step() {
  printf '[%3ss] %s\n' "$(( $(date +%s) - started_at ))" "$*"
  (publish "{\"status\":\"starting\",\"step\":$(q "$*"),\"step_at\":$(date +%s)}" &)
}

cleanup() {
  set +e
  for pid in "${pids[@]}"; do kill "$pid" >/dev/null 2>&1; done
  bash "$SCRIPTS/desktop/live-sync.sh" stop "$LIVE_DIR" >/dev/null 2>&1
  if [[ -n ${CB_PERSIST_DIR:-} && -d $CB_PERSIST_DIR ]]; then
    tail -n 200 "$HOME/cb-boot.log" >"$CB_PERSIST_DIR/last-run.log" 2>/dev/null
    for log in "$WORK_DIR"/sunshine.log "$WORK_DIR"/cloudflared.log; do
      [[ -s $log ]] && { printf '== %s\n' "${log##*/}"; tail -n 30 "$log"; } >>"$CB_PERSIST_DIR/last-run.log" 2>/dev/null
    done
  fi
}
trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  local log
  for log in "$WORK_DIR"/*.log "$WORK_DIR"/gate/*.log "$WORK_DIR"/nginx/logs/error.log; do
    [[ -s $log ]] || continue
    printf '== %s\n' "${log#"$WORK_DIR"/}" >&2
    tail -n 25 "$log" >&2 || true
  done
  lim 40 bash -c "$(declare -f q publish); publish \"\$1\"" _ \
    "{\"status\":\"stopped\",\"reason\":\"failed\",\"error\":$(q "$*")}" || true
  exit 1
}

[[ -n "${DESKTOP_PASSWORD:-}" ]] || fail "desktop password secret is missing"
if [[ $BURNER == 1 ]]; then
  [[ -z "${PROFILE_DOWNLOAD_URL:-}${PROFILE_UPLOAD_URL:-}${FILES_DOWNLOAD_URL:-}${FILES_UPLOAD_URL:-}${SYNC_REQUEST_URL:-}${DEVICE_URL:-}" ]] ||
    fail "a burner must not be given storage links"
else
  [[ -n "${PROFILE_DOWNLOAD_URL:-}" ]] || fail "profile download ticket is missing"
  [[ -n "${PROFILE_UPLOAD_URL:-}" ]] || fail "profile upload ticket is missing"
fi
[[ -n "${STOP_REQUEST_URL:-}" ]] || fail "stop request ticket is missing"
[[ ${KIT_DOWNLOAD_URL:-} == https://* ]] || fail "the Mac kit link is missing"
(( ${#DESKTOP_PASSWORD} >= 16 )) || fail "desktop password must contain at least 16 characters"
[[ -f "$PROFILE_TOOL" && -f "$SCRIPTS/pair-viewer.py" ]] || fail "desktop runtime files are missing"

mkdir -p "$WORK_DIR" "$STATE_DIR" "$KIT"
rm -f "$EXIT_REASON_FILE" "$PROFILE_SAVED_FILE" "$PROFILE_RESTORED_FILE"

readonly USER_TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
RESPONSIBLE=(/usr/local/opt/runner/provisioner/provisioner /usr/libexec/sshd-keygen-wrapper
  /usr/libexec/sshd-session /usr/sbin/sshd)
tcc_pid=$PPID
while [[ $tcc_pid -gt 1 ]]; do
  exe=$(ps -o comm= -p "$tcc_pid" 2>/dev/null | sed 's/^ *//' || true)
  [[ $exe == /* || -z $exe ]] || exe=$(command -v "${exe##*/}" 2>/dev/null || true)
  if [[ $exe == /* ]]; then RESPONSIBLE+=("$exe"); fi
  tcc_pid=$(ps -o ppid= -p "$tcc_pid" 2>/dev/null | tr -d ' ' || echo 1)
  [[ -n $tcc_pid ]] || break
done
readonly RESPONSIBLE
printf 'Permissions for: %s\n' "${RESPONSIBLE[*]}"
restart_tcc() {
  sudo killall -9 tccd >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/com.apple.tccd" >/dev/null 2>&1 || true
  sleep 1
}
grant() {
  local service=$1 client=$2 type=${3:-1} app=${4:-} req="NULL" sql
  if [[ -n $app ]] && codesign -d -r- "$app" 2>/dev/null | sed -n 's/^designated => //p' | csreq -r- -b "$WORK_DIR/csreq.bin" 2>/dev/null; then
    req="X'$(xxd -p "$WORK_DIR/csreq.bin" | tr -d '\n')'"
  fi
  sql="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified) VALUES ('$service', '$client', $type, 2, REASON, 1, $req, 0, 'UNUSED', 0, CAST(strftime('%s','now') AS INTEGER));"
  sudo sqlite3 -cmd '.timeout 20000' "$TCC_DB" "${sql/REASON/4}"
  if [[ -f $USER_TCC_DB ]]; then sqlite3 -cmd '.timeout 20000' "$USER_TCC_DB" "${sql/REASON/3}" || sudo sqlite3 -cmd '.timeout 20000' "$USER_TCC_DB" "${sql/REASON/3}" || true; fi
}

step "Installing the Mac desktop"
sudo defaults write /Library/Preferences/com.apple.timezone.auto Active -bool false 2>/dev/null || true
if [[ -e /var/db/timezone/zoneinfo/Asia/Kolkata ]]; then
  sudo ln -sf /var/db/timezone/zoneinfo/Asia/Kolkata /etc/localtime 2>/dev/null || true
else
  sudo ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime 2>/dev/null || true
fi
killall ControlCenter >/dev/null 2>&1 || true
defaults write com.apple.CrashReporter DialogType none 2>/dev/null || true
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1
( bash "$SCRIPTS/desktop/transfer.sh" get "$KIT_DOWNLOAD_URL" "$WORK_DIR/kit.tar.gz" 300 &&
    tar -xz -C "$KIT" <"$WORK_DIR/kit.tar.gz" && rm -f "$WORK_DIR/kit.tar.gz" ) \
  >"$WORK_DIR/kit.log" 2>&1 &
kit_pid=$!
brew_retry() {
  local log=$1 try
  shift
  for try in 1 2 3; do
    brew install --quiet "$@" >>"$log" 2>&1 && return 0
    printf '== try %s failed\n' "$try" >>"$log"
    sleep $((try * 5))
  done
  return 1
}
( brew_retry "$WORK_DIR/brew.log" coreutils gnu-tar rsync flock findutils nginx switchaudio-osx &&
  touch "$WORK_DIR/tools-ready" &&
  brew_retry "$WORK_DIR/brew-apps.log" --cask brave-browser &&
  brew_retry "$WORK_DIR/brew-apps.log" --cask blackhole-2ch ) &
apps_pid=$!
defaults write -g AppleInterfaceStyle -string Dark
user_tcc="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
for client in /usr/bin/osascript /bin/bash "$(command -v bash)" "${RESPONSIBLE[@]}"; do
  for db in "$user_tcc" "$TCC_DB"; do
    sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified) VALUES ('kTCCServiceAppleEvents', '$client', 1, 2, $([[ $db == "$user_tcc" ]] && echo 3 || echo 4), 1, 0, 'com.apple.systemevents', 0, CAST(strftime('%s','now') AS INTEGER));" 2>/dev/null || true
  done
done
restart_tcc
apple_events=1
if [[ ${CB_KEEP_SESSION:-} == 1 ]]; then apple_events=0; touch "$WORK_DIR/no-apple-events"; fi
{ ((apple_events)) && lim 20 osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' >/dev/null 2>&1; } ||
  lim 120 xcrun swift "$SCRIPTS/dark-mode.swift" >/dev/null 2>&1 ||
  printf 'Dark mode could not be switched on.\n' >&2
defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
killall Dock SystemUIServer ControlCenter Finder WindowManager >/dev/null 2>&1 || true
sudo pmset -a displaysleep 0 sleep 0 disksleep 0 >/dev/null
nohup caffeinate -dimsu </dev/null >/dev/null 2>&1 &
pids+=($!)
defaults -currentHost write com.apple.screensaver idleTime 0

wait "$kit_pid" || fail "the Mac kit could not be downloaded"
[[ -x $KIT/bin/vdisplay && -x $VIEWER_DIR/web-server && -d $KIT/Sunshine.app ]] || fail "the Mac kit is incomplete"
if head -c 2 "$KIT/bin/SwitchAudioSource" 2>/dev/null | grep -q '#!'; then rm -f "$KIT/bin/SwitchAudioSource"; fi
PATH="$KIT/bin:$PATH"
step "Creating the Retina screen"
physical=$(displayplacer list 2>/dev/null | sed -n 's/^Persistent screen id: //p' | head -n 1 || true)
echo "$physical" >"$WORK_DIR/screen-physical"
echo "$req_scale" >"$WORK_DIR/screen-scale"
echo "$SCREEN_WIDTH $SCREEN_HEIGHT" >"$WORK_DIR/screen-size"
if [[ -z $physical ]]; then
  step "Creating this Mac's only screen"
  lim 20 sudo mdutil -a -i off >/dev/null 2>&1 || true
  lim 10 caffeinate -u -t 3 >/dev/null 2>&1 || true
  nohup vdisplay --no-hidpi -w "$SCREEN_WIDTH" -h "$SCREEN_HEIGHT" -r 60 -n "Compute Base" </dev/null >"$WORK_DIR/vdisplay.log" 2>&1 &
  echo $! >"$WORK_DIR/vdisplay.pid"
  virtual=""
  for _ in {1..30}; do
    virtual=$(lim 10 displayplacer list | sed -n 's/^Persistent screen id: //p' | head -n 1 || true)
    [[ -n $virtual ]] && break
    sleep 1
  done
  [[ -n $virtual ]] || fail "this Mac has no screen, and one could not be made ($(tail -n 2 "$WORK_DIR/vdisplay.log" 2>/dev/null | tr '\n' ' '))"
  lim 10 python3 "$SCRIPTS/arrange-screen.py" --id "$virtual" >"$WORK_DIR/sunshine-output" 2>/dev/null || rm -f "$WORK_DIR/sunshine-output"
  echo "$SCREEN_WIDTH $SCREEN_HEIGHT" >"$WORK_DIR/own-size"
  touch "$WORK_DIR/screen-fallback"
  printf 'Matches your window: %sx%s, 60 FPS (H.264)\n' "$SCREEN_WIDTH" "$SCREEN_HEIGHT" >"$WORK_DIR/display"
  step "Screens: $(lim 10 python3 "$SCRIPTS/arrange-screen.py" --status 2>&1 | tail -n 1)"
elif [[ ${CB_OWN_SCREEN:-} == 1 ]] || ! lim 8 python3 "$SCRIPTS/arrange-screen.py" --check 2>/dev/null; then
  step "Preparing this Mac's screen"
  if [[ ${CB_OWN_SCREEN:-} == 1 ]]; then
    lim 20 sudo mdutil -a -i off >/dev/null 2>&1 || true
    sudo killall mds_stores mdworker_shared 2>/dev/null || true
  fi
  printf 'The Mac'"'"'s own screen, 60 FPS (H.264)\n' >"$WORK_DIR/display"
  touch "$WORK_DIR/screen-fallback"
  lim 10 caffeinate -u -t 3 >/dev/null 2>&1 || true
  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked -bool false 2>/dev/null || true
  sudo defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool true 2>/dev/null || true
  [[ ${CB_KEEP_SESSION:-} == 1 ]] || sudo killall loginwindow 2>/dev/null || true
  opened=0
  for _ in {1..40}; do
    sleep 2
    if lim 10 python3 "$SCRIPTS/arrange-screen.py" --active 2>/dev/null &&
       ! lim 10 python3 "$SCRIPTS/mac-unlock.py" --locked 2>/dev/null; then opened=1; break; fi
  done
  if ((opened)); then
    [[ ${CB_KEEP_SESSION:-} == 1 ]] || touch "$WORK_DIR/session-reopened"
    lim 10 caffeinate -u -t 3 >/dev/null 2>&1 || true
    step "Opened a fresh Mac desktop"
    lim 15 displayplacer list >"$WORK_DIR/modes.log" 2>&1 || true
    grep -E 'Resolution:|mode [0-9]+:.*scaling:on|current mode' "$WORK_DIR/modes.log" | head -n 40 | sed 's/^/== screen modes: /' >&2 || true
    nohup vdisplay --no-hidpi -w "$SCREEN_WIDTH" -h "$SCREEN_HEIGHT" -r 60 -n "Compute Base" </dev/null >"$WORK_DIR/vdisplay.log" 2>&1 &
    echo $! >"$WORK_DIR/vdisplay.pid"
    virtual=""
    for _ in {1..30}; do
      virtual=$(lim 10 displayplacer list | sed -n 's/^Persistent screen id: //p' | grep -vx "$physical" | head -n 1 || true)
      [[ -n $virtual ]] && break
      sleep 1
    done
    if [[ -n $virtual ]] &&
       lim 45 python3 "$SCRIPTS/arrange-screen.py" "$virtual" "$physical" "$SCREEN_WIDTH" "$SCREEN_HEIGHT" 2>"$WORK_DIR/arrange.log" &&
       lim 8 python3 "$SCRIPTS/arrange-screen.py" --active 2>/dev/null; then
      echo "$SCREEN_WIDTH $SCREEN_HEIGHT" >"$WORK_DIR/own-size"
      printf 'Matches your window: %sx%s, 60 FPS (H.264)\n' "$SCREEN_WIDTH" "$SCREEN_HEIGHT" >"$WORK_DIR/display"
      step "Screen ${SCREEN_WIDTH}x${SCREEN_HEIGHT} at 1x ($(tail -n 1 "$WORK_DIR/arrange.log" | cut -c1-120))"
    else
      step "A screen of the window's size was refused ($(tail -n 1 "$WORK_DIR/arrange.log" 2>/dev/null | cut -c1-120)); streaming the Mac's own"
      kill "$(cat "$WORK_DIR/vdisplay.pid")" 2>/dev/null || true
      rm -f "$WORK_DIR/vdisplay.pid"
      for _ in {1..20}; do
        lim 10 displayplacer list | sed -n 's/^Persistent screen id: //p' | grep -vqx "$physical" || break
        sleep 0.5
      done
    fi
  else
    step "The Mac's desktop did not come up (screens: $(lim 10 python3 "$SCRIPTS/arrange-screen.py" --status 2>&1 | tail -n 1))"
  fi
  step "Screens: $(lim 10 python3 "$SCRIPTS/arrange-screen.py" --status 2>&1 | tail -n 1)"
  if ! lim 10 python3 "$SCRIPTS/arrange-screen.py" --active 2>/dev/null; then
    nohup vdisplay -w "$SCREEN_WIDTH" -h "$SCREEN_HEIGHT" -r 60 -n "Compute Base" </dev/null >"$WORK_DIR/vdisplay.log" 2>&1 &
    echo $! >"$WORK_DIR/vdisplay.pid"
    virtual=""
    for _ in {1..30}; do
      virtual=$(displayplacer list | sed -n 's/^Persistent screen id: //p' | grep -vx "$physical" | head -n 1 || true)
      [[ -n $virtual ]] && break
      sleep 1
    done
    if [[ -n $virtual ]]; then
      lim 10 python3 "$SCRIPTS/arrange-screen.py" --id "$virtual" >"$WORK_DIR/sunshine-output" 2>/dev/null || rm -f "$WORK_DIR/sunshine-output"
      printf 'Matches your window: %sx%s, Retina, 60 FPS (H.264)\n' "$SCREEN_WIDTH" "$SCREEN_HEIGHT" >"$WORK_DIR/display"
    fi
    step "Screens now: $(lim 10 python3 "$SCRIPTS/arrange-screen.py" --status 2>&1 | tail -n 1)"
  fi
else
  printf 'Matches your window: %sx%s, Retina, 60 FPS (H.264)\n' "$SCREEN_WIDTH" "$SCREEN_HEIGHT" >"$WORK_DIR/display"
  step "Screen ${SCREEN_WIDTH}x${SCREEN_HEIGHT} at 2x, stream ${VIDEO_WIDTH}x${VIDEO_HEIGHT} at 60 fps"
  nohup vdisplay -w "$SCREEN_WIDTH" -h "$SCREEN_HEIGHT" -r 60 -n "Compute Base" </dev/null >"$WORK_DIR/vdisplay.log" 2>&1 &
  echo $! >"$WORK_DIR/vdisplay.pid"
  virtual=""
  for _ in {1..30}; do
    virtual=$(displayplacer list | sed -n 's/^Persistent screen id: //p' | grep -vx "$physical" | head -n 1 || true)
    [[ -n $virtual ]] && break
    sleep 1
  done
  [[ -n $virtual ]] || fail "the Retina screen did not appear"
  if ! displayplacer "id:$virtual+$physical res:${SCREEN_WIDTH}x${SCREEN_HEIGHT} hz:60 scaling:on origin:(0,0) degree:0"; then
    printf 'displayplacer was refused; arranging the screens through CoreGraphics.\n' >&2
    arranged=0
    lim 45 python3 "$SCRIPTS/arrange-screen.py" "$virtual" "$physical" "$SCREEN_WIDTH" "$SCREEN_HEIGHT" 2>"$WORK_DIR/arrange.log" && arranged=1
    cat "$WORK_DIR/arrange.log" >&2
    if ((!arranged)); then
      printf 'The Retina screen could not be arranged; streaming the Mac'"'"'s own screen.\n' >&2
      kill "$(cat "$WORK_DIR/vdisplay.pid")" 2>/dev/null || true
      for _ in {1..20}; do
        displayplacer list | sed -n 's/^Persistent screen id: //p' | grep -vqx "$physical" || break
        sleep 0.5
      done
      printf 'The Mac'"'"'s own screen, 60 FPS (H.264)\n' >"$WORK_DIR/display"
      touch "$WORK_DIR/screen-fallback"
    fi
  fi
fi
wallpaper=$(find "/System/Library/Desktop Pictures" -maxdepth 1 -type f \( -name '*.heic' -o -name '*.jpg' -o -name '*.png' \) 2>/dev/null |
  grep -i -E 'tahoe|dark|sequoia|sonoma' | head -n 1)
[[ -n $wallpaper ]] || wallpaper=$(find "/System/Library/Desktop Pictures" -type f \( -name '*.heic' -o -name '*.jpg' \) 2>/dev/null | head -n 1)
printf '%s\n' "$wallpaper" >"$WORK_DIR/wallpaper"
set_wallpaper() {
  [[ -n $wallpaper ]] || return 0
  ((apple_events)) && lim 20 osascript -e "tell application \"System Events\" to set picture of every desktop to \"$wallpaper\"" >/dev/null 2>&1 && return 0
  [[ -x $WORK_DIR/wallpaper-set ]] || lim 180 xcrun swiftc -O -o "$WORK_DIR/wallpaper-set" "$SCRIPTS/wallpaper.swift" >/dev/null 2>&1 || true
  [[ -x $WORK_DIR/wallpaper-set ]] && lim 20 "$WORK_DIR/wallpaper-set" "$wallpaper" && return 0
  printf 'The wallpaper could not be set.\n' >&2
}
set_wallpaper

step "Starting the stream"
cp -R "$KIT/Sunshine.app" /Applications/
sunshine_id=$(defaults read /Applications/Sunshine.app/Contents/Info CFBundleIdentifier 2>/dev/null || true)
for service in kTCCServiceScreenCapture kTCCServiceMicrophone kTCCServiceAudioCapture kTCCServiceAccessibility kTCCServicePostEvent; do
  grant "$service" "$SUNSHINE"
  [[ -z $sunshine_id ]] || grant "$service" "$sunshine_id" 0 /Applications/Sunshine.app
done
for client in "${RESPONSIBLE[@]}" /bin/bash "$(command -v bash)" /usr/bin/osascript; do
  for service in kTCCServiceScreenCapture kTCCServiceMicrophone kTCCServiceAudioCapture kTCCServiceAccessibility kTCCServicePostEvent; do
    grant "$service" "$client"
  done
done
restart_tcc

if ((apple_events)); then
( quiet_until=$(($(date +%s) + 600))
  while true; do
    if (($(date +%s) < quiet_until)); then
      lim 10 osascript -e 'if application "System Settings" is running then tell application "System Settings" to quit' \
        >>"$WORK_DIR/clicker.log" 2>&1 || true
    fi
    lim 10 osascript <<'OSA' >>"$WORK_DIR/clicker.log" 2>&1 || true
tell application "System Events"
  repeat with n in {"UserNotificationCenter", "CoreServicesUIAgent", "Sunshine", "universalaccessd", "SecurityAgent"}
    if exists process n then
      repeat with w in (every window of process n)
        try
          if exists (button "Allow" of w) then click button "Allow" of w
        end try
        -- "Do you want to change your default web browser to Brave Browser?"
        try
          repeat with b in (every button of w)
            if name of b starts with "Use “Brave" then click b
          end repeat
        end try
      end repeat
    end if
  end repeat
  -- An app's first notifications ("Brave Browser" Notifications, "Sunshine"
  -- Notifications) wait top right for an answer that never comes: answered.
  if exists process "NotificationCenter" then
    tell process "NotificationCenter"
      repeat with w in (every window)
        try
          repeat with e in (entire contents of w)
            try
              repeat with a in (every action of e)
                if description of a is in {"Allow", "Close"} then
                  perform a
                  exit repeat
                end if
              end repeat
            end try
          end repeat
        end try
      end repeat
    end tell
  end if
  -- The same question for the runner's own agent ("hosted-compute-...") came
  -- from a process not named above: any window asking about local networks.
  repeat with p in (every process whose background only is false or name contains "Agent" or name contains "hosted")
    repeat with w in (every window of p)
      try
        set asked to ((value of every static text of w) as text)
        -- And the streamer's own screen question ("requesting to bypass the system private window picker").
        if (exists (button "Allow" of w)) and (asked contains "local network" or asked contains "private window picker") then click button "Allow" of w
      end try
    end repeat
  end repeat
end tell
OSA
    sleep 3
  done ) &
fi
if true; then
  if lim 240 xcrun swiftc -O -o "$WORK_DIR/clicker" "$SCRIPTS/clicker.swift" >>"$WORK_DIR/clicker.log" 2>&1; then
    for service in kTCCServiceAccessibility kTCCServicePostEvent; do grant "$service" "$WORK_DIR/clicker"; done
    restart_tcc
    python3 - "$HOME/Library/LaunchAgents/base.compute.clicker.plist" "$WORK_DIR/clicker" "$WORK_DIR/clicker.log" <<'PY'
import plistlib, sys, time
agent, program, log = sys.argv[1:]
with open(agent, "wb") as handle:
    plistlib.dump({"Label": "base.compute.clicker", "ProgramArguments": [program, "--quiet-until", str(int(time.time()) + 600)],
                   "RunAtLoad": True,
                   "KeepAlive": True, "StandardOutPath": log, "StandardErrorPath": log}, handle)
PY
    launchctl bootout "gui/$(id -u)/base.compute.clicker" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/base.compute.clicker.plist" ||
      printf 'The question clicker could not be started.
' >&2
  else
    printf 'The question clicker could not be built.
' >&2
  fi
fi
sunshine_password=$(openssl rand -hex 16)
mkdir -p "$HOME/.config/sunshine"
cat >"$HOME/.config/sunshine/apps.json" <<EOF
{"env": {}, "apps": [{"name": "Desktop", "image-path": "desktop.png"}]}
EOF
export CB_WORK_DIR="$WORK_DIR"
encoder=videotoolbox software_encoder=""
if [[ ${CB_OWN_SCREEN:-} == 1 ]]; then
  encoder=software
  software_encoder=$'sw_preset = ultrafast\nsw_tune = zerolatency\nmin_threads = 6'
fi
cat >"$HOME/.config/sunshine/sunshine.conf" <<EOF
min_log_level = info
audio_sink = BlackHole 2ch
encoder = $encoder
origin_web_ui_allowed = lan
${software_encoder}
EOF
if [[ -s $WORK_DIR/sunshine-output ]]; then
  printf 'output_name = %s\n' "$(cat "$WORK_DIR/sunshine-output")" >>"$HOME/.config/sunshine/sunshine.conf"
fi
lim 60 "$SUNSHINE" --creds "$OWNER_USER" "$sunshine_password" >/dev/null 2>&1 || fail "Sunshine could not be set up"

start_viewer() {
  (cd "$VIEWER_DIR" && nohup ./web-server </dev/null >>"$WORK_DIR/viewer.log" 2>&1 & echo $! >"$WORK_DIR/viewer.pid")
  for _ in {1..30}; do curl --silent --max-time 3 --output /dev/null http://127.0.0.1:8080/ && return 0; sleep 1; done
  fail "the browser viewer did not start"
}
mkdir -p "$VIEWER_DIR/server"
printf '%s\n' 'try { var cbScale = new XMLHttpRequest(); cbScale.open("POST", "/__cb/scale?s=" + (window.devicePixelRatio || 1), false); cbScale.send() } catch (e) {}' \
  >"$VIEWER_DIR/static/cb-scale.js"
cp "$SCRIPTS/desktop/viewer-return.js" "$VIEWER_DIR/static/cb-return.js"
for page in "$VIEWER_DIR"/static/*.html; do
  grep -q 'cb-scale.js' "$page" || perl -0pi -e 's#(<head[^>]*>)#$1<script src="/cb-scale.js"></script><script src="/cb-return.js"></script>#i' "$page"
done
export GATE_SCALE_FILE="$WORK_DIR/screen-scale"
start_viewer

for _ in {1..300}; do
  [[ -f $WORK_DIR/tools-ready ]] && break
  kill -0 "$apps_pid" 2>/dev/null || break
  sleep 1
done
[[ -f $WORK_DIR/tools-ready ]] || fail "the Mac tools could not be installed"
PATH="$(brew --prefix coreutils)/libexec/gnubin:$(brew --prefix gnu-tar)/libexec/gnubin:$(brew --prefix findutils)/libexec/gnubin:$(brew --prefix)/bin:$PATH"
export PATH
for tool in /bin/bash "$(brew --prefix)/bin/bash" "$(command -v rsync)" "$(command -v tar)" "$(command -v find)"; do
  grant kTCCServiceSystemPolicyAllFiles "$tool"
done

step "Restoring your desktop and files"
for folder in Desktop Documents Downloads Pictures Music Videos; do
  mkdir -p "$HOME/$folder"
  find "$HOME/$folder" -mindepth 1 -delete 2>/dev/null || true
done
NATIVE_KEPT=0
if [[ $BURNER != 1 && -n ${CB_PERSIST_DIR:-} && -f "$CB_PERSIST_DIR/kept-here" ]]; then NATIVE_KEPT=1; fi
if [[ $BURNER == 1 ]]; then
  printf 'Burner: a fresh Mac; nothing is restored or saved.\n'
elif (( NATIVE_KEPT )); then
  printf 'Your desktop is kept on this Devbox; nothing is fetched.\n'
else
  bash "$PROFILE_TOOL" restore "$HOME" "$STATE_DIR"
  if [[ -s "$STATE_DIR/restored" ]]; then touch "$PROFILE_RESTORED_FILE"; fi
fi

wait "$apps_pid" || fail "Brave or the sound device could not be installed ($(grep -v '^== ' "$WORK_DIR/brew-apps.log" 2>/dev/null | grep -i -E 'error|fail' | tail -n 1 | cut -c1-160))"
if [[ $BURNER != 1 && -n ${CB_PERSIST_DIR:-} ]]; then
  export CB_PERSIST_DIR
  bash "$SCRIPTS/desktop/devbox-keep.sh" baseline || true
  if (( NATIVE_KEPT )); then
    bash "$SCRIPTS/desktop/devbox-keep.sh" restore && touch "$PROFILE_RESTORED_FILE"
  fi
fi
step "Setting up sound"
sudo killall coreaudiod >/dev/null 2>&1 || true
for _ in {1..20}; do SwitchAudioSource -a -t output | grep -qx "BlackHole 2ch" && break; sleep 1; done
SwitchAudioSource -t output -s "BlackHole 2ch" >/dev/null || fail "the sound device is missing"
SwitchAudioSource -t system -s "BlackHole 2ch" >/dev/null 2>&1 || true
restart_tcc
if [[ ${CB_KEEP_SESSION:-} == 1 ]]; then
  agent="$HOME/Library/LaunchAgents/base.compute.sunshine.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  python3 - "$agent" "$SUNSHINE" "$HOME/.config/sunshine/sunshine.conf" "$WORK_DIR/sunshine.log" <<'PY'
import os, plistlib, sys
agent, program, conf, log = sys.argv[1:]
env = {k: os.environ[k] for k in ("PATH", "HOME", "USER", "LANG", "CB_WORK_DIR", "SCREEN_SCALE") if k in os.environ}
with open(agent, "wb") as handle:
    plistlib.dump({"Label": "base.compute.sunshine", "ProgramArguments": [program, conf], "RunAtLoad": True,
                   "EnvironmentVariables": env, "StandardOutPath": log, "StandardErrorPath": log}, handle)
PY
  launchctl bootout "gui/$(id -u)/base.compute.sunshine" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$agent" || fail "Sunshine could not be started"
  sunshine_pid=""
  for _ in {1..20}; do sunshine_pid=$(pgrep -f "$SUNSHINE $HOME/.config/sunshine/sunshine.conf" | head -n 1); [[ -n $sunshine_pid ]] && break; sleep 0.5; done
  [[ -n $sunshine_pid ]] && pids+=("$sunshine_pid")
else
  nohup "$SUNSHINE" "$HOME/.config/sunshine/sunshine.conf" </dev/null >"$WORK_DIR/sunshine.log" 2>&1 &
  pids+=($!)
fi

awk "/compute-base.json <<'J'/{f=1;next} /^J\$/{f=0} f" "$SCRIPTS/desktop/10-compute-base.sh" >"$WORK_DIR/brave-policies.json"
awk "/compute-base.json <<'RJ'/{f=1;next} /^RJ\$/{f=0} f" "$SCRIPTS/desktop/10-compute-base.sh" >"$WORK_DIR/brave-recommended.json"
python3 - "$WORK_DIR/brave-recommended.json" "$WORK_DIR/brave-recommended.plist" <<'PY'
import json, plistlib, sys
plistlib.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "wb"))
PY
defaults import com.brave.Browser "$WORK_DIR/brave-recommended.plist" || true
if [[ -z ${BURNER:-} && ${BOOKMARKS_URL:-} == https://* ]]; then
  curl --fail --silent --show-error --location --retry 3 --max-time 60 "$BOOKMARKS_URL" \
    -o "$WORK_DIR/brave-bookmarks.json" || rm -f "$WORK_DIR/brave-bookmarks.json"
  grep -q '"ManagedBookmarks"' "$WORK_DIR/brave-bookmarks.json" 2>/dev/null ||
    rm -f "$WORK_DIR/brave-bookmarks.json"
fi
if [[ ${CB_OWN_SCREEN:-} == 1 ]]; then
  python3 - "$WORK_DIR/brave-policies.json" <<'PY'
import json, sys
path = sys.argv[1]
policies = json.load(open(path))
policies["DnsOverHttpsMode"] = "automatic"
json.dump(policies, open(path, "w"))
PY
fi
set_brave_policies() {
  python3 - "$WORK_DIR/com.brave.Browser.plist" "$WORK_DIR/brave-policies.json" "$WORK_DIR/brave-extensions.json" <<'PY'
import json, os, plistlib, sys
policies = {}
for path in sys.argv[2:]:
    if os.path.exists(path):
        policies.update(json.load(open(path)))
plistlib.dump(policies, open(sys.argv[1], "wb"))
PY
  sudo mkdir -p "/Library/Managed Preferences"
  sudo cp "$WORK_DIR/com.brave.Browser.plist" "/Library/Managed Preferences/com.brave.Browser.plist"
}
set_extensions() {
  bash "$SCRIPTS/desktop/brave-extensions.sh" "$1" "$HOME/$BRAVE_SUBDIR" "$WORK_DIR/brave-extensions.json" &&
    set_brave_policies
}
set_brave_policies

step "Pairing the viewer with the stream"
sunshine_up=0
for _ in {1..60}; do
  curl --silent --insecure --max-time 3 --output /dev/null https://127.0.0.1:47990/ && { sunshine_up=1; break; }
  sleep 1
done
((sunshine_up)) || fail "Sunshine did not start"
viewer_password=$(openssl rand -hex 16)
ids=$(cd "$VIEWER_DIR" && VIEWER_PASSWORD="$viewer_password" SUNSHINE_PASSWORD="$sunshine_password" \
  lim 150 python3 "$SCRIPTS/pair-viewer.py" pair) || fail "the viewer could not be paired with the stream"
host_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["host_id"])' "$ids")
app_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["app_id"])' "$ids")
kill "$(cat "$WORK_DIR/viewer.pid")"; sleep 2
viewer_bitrate="" viewer_size=""
if [[ ${CB_OWN_SCREEN:-} == 1 ]]; then
  viewer_bitrate=8000
  viewer_size=$(cat "$WORK_DIR/own-size" 2>/dev/null || system_profiler SPDisplaysDataType 2>/dev/null | awk '/Resolution:/ {print $2, $4; exit}')
  [[ $viewer_size =~ ^[0-9]+\ [0-9]+$ ]] || viewer_size="1920 1080"
fi
(cd "$VIEWER_DIR" && VIEWER_BITRATE="$viewer_bitrate" VIEWER_SIZE="$viewer_size" python3 "$SCRIPTS/pair-viewer.py" configure) || fail "the viewer could not be set up"
start_viewer
pids+=("$(cat "$WORK_DIR/viewer.pid")")

step "Opening a secure connection"
nginx_dir="$WORK_DIR/nginx"
mkdir -p "$nginx_dir/logs" "$nginx_dir/tmp"
(umask 077 && printf '%s:{PLAIN}%s\n' "$OWNER_USER" "$DESKTOP_PASSWORD" >"$nginx_dir/htpasswd")
if [[ -n ${DESKTOP_VIEW_LOGIN:-} ]]; then
  DESKTOP_VIEW_PASSWORD=$(openssl rand -hex 16)
  DESKTOP_VIEW_USER=watch
  export DESKTOP_VIEW_LOGIN DESKTOP_VIEW_PASSWORD DESKTOP_VIEW_USER
  (umask 077 && printf 'watch:{PLAIN}%s\n' "$DESKTOP_VIEW_PASSWORD" >>"$nginx_dir/htpasswd")
  nohup python3 "$SCRIPTS/desktop/watch-relay.py" 8091 8080 </dev/null >"$WORK_DIR/watch-relay.log" 2>&1 &
  pids+=($!)
fi
cat >"$nginx_dir/nginx.conf" <<EOF
worker_processes 1;
pid $nginx_dir/nginx.pid;
error_log $nginx_dir/logs/error.log;
events { worker_connections 256; }
http {
  access_log off;
  client_body_temp_path $nginx_dir/tmp; proxy_temp_path $nginx_dir/tmp;
  fastcgi_temp_path $nginx_dir/tmp; uwsgi_temp_path $nginx_dir/tmp; scgi_temp_path $nginx_dir/tmp;
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
  map \$remote_user \$viewer { watch 127.0.0.1:8091; default 127.0.0.1:8080; }
  server {
    listen 127.0.0.1:8090;
    auth_basic "Compute Base";
    auth_basic_user_file $nginx_dir/htpasswd;
    location / {
      proxy_pass http://\$viewer;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_set_header Authorization "";
      proxy_buffering off;
      proxy_read_timeout 1d;
      proxy_send_timeout 1d;
    }
  }
}
EOF
nginx -p "$nginx_dir" -c "$nginx_dir/nginx.conf" -g 'daemon off;' </dev/null >"$WORK_DIR/nginx.log" 2>&1 &
pids+=($!)
sleep 1

sudo xattr -dr com.apple.quarantine "/Applications/Brave Browser.app" 2>/dev/null || true
grant_app() {
  local service=$1 bundle=$2 sql
  sql="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags, last_modified) VALUES ('$service', '$bundle', 0, 2, 4, 1, 'UNUSED', 0, CAST(strftime('%s','now') AS INTEGER));"
  sudo sqlite3 "$TCC_DB" "$sql" 2>/dev/null || true
  [[ -f $USER_TCC_DB ]] && { sqlite3 "$USER_TCC_DB" "$sql" 2>/dev/null || sudo sqlite3 "$USER_TCC_DB" "$sql" 2>/dev/null || true; }
  return 0
}
for bundle in com.brave.Browser com.apple.finder com.apple.Terminal; do
  for service in kTCCServiceSystemPolicyDownloadsFolder kTCCServiceSystemPolicyDesktopFolder \
    kTCCServiceSystemPolicyDocumentsFolder kTCCServiceSystemPolicyAllFiles kTCCServiceSystemPolicyRemovableVolumes; do
    grant_app "$service" "$bundle"
  done
done
for client in "${RESPONSIBLE[@]}" /bin/bash "$(command -v bash)" /bin/zsh /bin/sh; do
  for service in kTCCServiceSystemPolicyDownloadsFolder kTCCServiceSystemPolicyDesktopFolder \
    kTCCServiceSystemPolicyDocumentsFolder kTCCServiceSystemPolicyAllFiles kTCCServiceSystemPolicyRemovableVolumes; do
    grant "$service" "$client"
  done
done
restart_tcc
sudo spctl --global-disable >/dev/null 2>&1 || sudo spctl --master-disable >/dev/null 2>&1 || true
defaults write com.apple.LaunchServices LSQuarantine -bool false
admin_pw=${DESKTOP_LOGIN:-$DESKTOP_PASSWORD}
if ! sudo dscl . -passwd "/Users/$(id -un)" "$admin_pw" >/dev/null 2>&1; then
  printf '%s' "$admin_pw" | sudo "$(command -v python3)" "$SCRIPTS/set-password.py" "$(id -un)" >/dev/null 2>&1 || true
  sleep 2
fi
dscl . -authonly "$(id -un)" "$admin_pw" >/dev/null 2>&1 || printf 'The admin password could not be set.\n' >&2
unset admin_pw
cat >"$WORK_DIR/pin-hook.sh" <<EOF
#!/bin/bash
IFS= read -r pin
[[ \$pin =~ ^[0-9]{4}\$ ]] || exit 1
sudo dscl . -passwd "/Users/$(id -un)" "\$pin" >/dev/null 2>&1 ||
  printf '%s' "\$pin" | sudo "$(command -v python3)" "$SCRIPTS/set-password.py" "$(id -un)" >/dev/null 2>&1
if dscl . -authonly "$(id -un)" "\$pin" >/dev/null 2>&1; then
  echo "\$(date '+%H:%M:%S') password set to the new PIN" >>"$WORK_DIR/pin-hook.log"
else
  echo "\$(date '+%H:%M:%S') the password could not be set" >>"$WORK_DIR/pin-hook.log"
fi
EOF
chmod 700 "$WORK_DIR/pin-hook.sh"
export GATE_PIN_HOOK="$WORK_DIR/pin-hook.sh"
step "Starting the tunnel"
source "$SCRIPTS/desktop/gate.sh"
export GATE_STREAMER=streamer
gate_start 127.0.0.1:8090 "$OWNER_USER" "$DESKTOP_PASSWORD" 8070 "$WORK_DIR" ||
  fail "the desktop's gate did not start"
pids+=("$GATE_VERIFIER_PID" "$GATE_CADDY_PID")
local_status=$(curl --silent --max-time 5 --output /dev/null --write-out '%{http_code}' http://127.0.0.1:8090/ || true)
[[ "$local_status" == "401" ]] || fail "the password gate is not running ($local_status)"
source "$SCRIPTS/desktop/tunnel.sh"
CLOUDFLARED=cloudflared TUNNEL_ORIGIN=http://127.0.0.1:8070 TUNNEL_LOG="$WORK_DIR/cloudflared.log"
start_tunnel || fail "no secure link could be opened (Cloudflare's quick tunnel and the app's relay both failed: $(grep -av '^$' "$TUNNEL_LOG" | tail -n 2 | tr '\n' ' ' | cut -c1-200))"
cloudflared_pid=$tunnel_pid
pids+=("$cloudflared_pid")
step "The secure link answers"
signed_status=""
for _ in {1..20}; do
  signed_status=$(curl --silent --max-time 15 --output /dev/null --write-out '%{http_code}' --user "$OWNER_USER:$DESKTOP_PASSWORD" "http://127.0.0.1:8090/stream.html" || true)
  [[ "$signed_status" == "200" ]] && break
  sleep 3
done
[[ "$signed_status" == "200" ]] || fail "the viewer did not answer through the tunnel ($signed_status)"

close_brave() {
  pkill -TERM -x "Brave Browser" >/dev/null 2>&1 || return 0
  for _ in {1..20}; do pgrep -x "Brave Browser" >/dev/null || return 0; sleep 1; done
  pkill -KILL -x "Brave Browser" >/dev/null 2>&1 || true
}

snapshot_profile() {
  local reason="${1:-auto}"
  if [[ $BURNER == 1 ]]; then touch "$PROFILE_SAVED_FILE"; return 0; fi
  printf 'Saving your desktop and files (%s)...\n' "$reason"
  lim 300 bash "$SCRIPTS/desktop/handoff-mac.sh" capture >>"$WORK_DIR/handoff.log" 2>&1 || true
  if [[ -n ${CB_PERSIST_DIR:-} && -f "$CB_PERSIST_DIR/baseline" ]] && { [[ $reason != auto ]] || (( $(date +%s) - ${last_keep:-0} >= 600 )); }; then
    bash "$SCRIPTS/desktop/devbox-keep.sh" save 2>&1 | tail -n 3 || true
    last_keep=$(date +%s)
  fi
  if bash "$PROFILE_TOOL" save "$HOME" "$STATE_DIR" "" "$reason"; then
    touch "$PROFILE_SAVED_FILE"
  elif [[ "$reason" == final ]]; then
    fail "the desktop could not be saved"
  else
    printf 'Save failed (%s); it will be tried again.\n' "$reason" >&2
  fi
}

sound_report() {
  grep -i -E 'error|warn|fatal|fail|denied|capture|session|stream' "$WORK_DIR/viewer.log" 2>/dev/null |
    grep -v -i -E 'pin|password|token|secret' | tail -n 30 | sed 's/^/== stream viewer: /' || true
  grep -i -E 'error|fatal|fail|denied|capture|session|display|client' "$WORK_DIR/sunshine.log" 2>/dev/null |
    grep -v -i -E 'gamepad|pin|password|secret' | tail -n 40 | sed 's/^/== stream sunshine: /' || true
  lim 30 log show --last 15m --style compact --predicate 'subsystem == "com.apple.TCC"' 2>/dev/null |
    grep -i -E 'screencapture|sunshine|listenevent|postevent' | tail -n 15 | sed 's/^/== stream tcc: /' || true
  printf '== sound: output %s\n' "$(SwitchAudioSource -c -t output 2>/dev/null || echo unknown)"
  grep -i -E 'audio|microphone|opus|sink' "$WORK_DIR/sunshine.log" 2>/dev/null | tail -n 20 | sed 's/^/== sound: /' || true
  lim 30 log show --last 15m --style compact --predicate 'subsystem == "com.apple.TCC"' 2>/dev/null |
    grep -i -E 'microphone|audiocapture|sunshine' | tail -n 15 | sed 's/^/== sound tcc: /' || true
  tail -n 5 "$WORK_DIR/clicker.log" 2>/dev/null | sed 's/^/== sound clicker: /' || true
  lim 15 osascript -e 'tell application "System Events" to get name of every process whose visible is true or name contains "Notification" or name contains "Agent"' 2>&1 |
    sed 's/^/== sound processes: /' || true
  if command -v rec >/dev/null; then
    lim 20 rec -q -t coreaudio "BlackHole 2ch" -n trim 0 2 stat 2>&1 | grep -E 'RMS +amplitude|Maximum amplitude' | sed 's/^/== sound blackhole: /' || true
  fi
  for db in "$TCC_DB" "$USER_TCC_DB"; do
    sudo sqlite3 "$db" "SELECT service, client, auth_value FROM access WHERE service IN ('kTCCServiceMicrophone','kTCCServiceAudioCapture');" 2>&1 |
      sed "s|^|== sound grant ${db##*/Library/}: |" || true
  done
}

finish_session() {
  local reason="$1"
  sound_report
  tail -n 3 "$WORK_DIR/brave-sync.log" 2>/dev/null | sed 's/^/== brave sync: /' || true
  grep -i -E 'fatal|check failed|crash|segv|abort' "$WORK_DIR/brave.log" 2>/dev/null | tail -n 8 | cut -c1-240 | sed 's/^/== brave log: /' || true
  pgrep -x "Brave Browser" >/dev/null && echo "== brave: still running at stop" || echo "== brave: NOT running at stop"
  printf '%s\n' "$reason" >"$EXIT_REASON_FILE"
  bash "$SCRIPTS/desktop/live-sync.sh" stop "$LIVE_DIR" || true
  printf 'Closing Brave cleanly...\n'
  close_brave
  snapshot_profile final
  exit 0
}

handle_signal() {
  trap - INT TERM
  finish_session signal
}
trap handle_signal INT TERM

if [[ $BURNER != 1 ]]; then
  mkdir -p "$LIVE_DIR"
  bash "$SCRIPTS/desktop/live-sync.sh" start "$HOME" "$LIVE_DIR" ||
    printf 'Live sync could not start; files still save as usual.\n' >&2
fi

printf 'Browser is ready at %s/stream.html?hostId=%s&appId=%s\n' "$public_url" "$host_id" "$app_id"
set_extensions all || printf 'The extension list could not be set.\n' >&2
sudo killall cfprefsd >/dev/null 2>&1 || true
NO_DEVICE_BINDING=DeviceBoundSessions,EnableBoundSessionCredentials,EnableChromeRefreshTokenBinding
BRAVE_FLAGS=(--restore-last-session --no-first-run --force-dark-mode
  --use-mock-keychain --hide-crash-restore-bubble --disable-features="$NO_DEVICE_BINDING"
  --remote-debugging-port=9333 --remote-debugging-address=127.0.0.1)
security delete-generic-password -s "Brave Safe Storage" >/dev/null 2>&1 || true
find "$HOME/$BRAVE_SUBDIR" -maxdepth 2 -name "Secure Preferences" -type f -delete 2>/dev/null || true
launcher="$HOME/Applications/Brave.app"
mkdir -p "$HOME/Applications"
flags_q=$(printf '%q ' "${BRAVE_FLAGS[@]}")
make_launcher() {
  if osacompile -o "$launcher" -e "do shell script \"open -a '/Applications/Brave Browser.app' --args $flags_q\"" 2>"$WORK_DIR/launcher.log"; then
    cp "/Applications/Brave Browser.app/Contents/Resources/app.icns" "$launcher/Contents/Resources/applet.icns" 2>/dev/null
    return 0
  fi
  rm -rf "$launcher" && mkdir -p "$launcher/Contents/MacOS" "$launcher/Contents/Resources" || return 1
  printf '#!/bin/bash\nexec open -a "/Applications/Brave Browser.app" --args %s\n' "$flags_q" >"$launcher/Contents/MacOS/Brave"
  chmod 755 "$launcher/Contents/MacOS/Brave"
  cp "/Applications/Brave Browser.app/Contents/Resources/app.icns" "$launcher/Contents/Resources/app.icns" 2>/dev/null
  python3 - "$launcher/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as handle:
    plistlib.dump({"CFBundleName": "Brave", "CFBundleExecutable": "Brave", "CFBundleIdentifier": "base.compute.brave-launcher",
                   "CFBundleIconFile": "app.icns", "CFBundlePackageType": "APPL", "LSUIElement": False}, handle)
PY
}
make_launcher &&
  touch "$launcher" &&
  python3 - "$launcher" <<'PY' && killall Dock >/dev/null 2>&1 || true
import plistlib, subprocess, sys
launcher = sys.argv[1]
raw = subprocess.run(["defaults", "export", "com.apple.dock", "-"], capture_output=True).stdout
dock = plistlib.loads(raw) if raw else {}
apps = [a for a in dock.get("persistent-apps", [])
        if "Brave" not in str(a.get("tile-data", {}).get("file-data", {}).get("_CFURLString", ""))]
apps.append({"tile-data": {"file-data": {"_CFURLString": f"file://{launcher}/", "_CFURLStringType": 15},
                           "file-label": "Brave"}, "tile-type": "file-tile"})
dock["persistent-apps"] = apps
subprocess.run(["defaults", "import", "com.apple.dock", "-"], input=plistlib.dumps(dock), check=True)
PY
if [[ -f $WORK_DIR/session-reopened ]]; then
  sudo dscacheutil -flushcache >/dev/null 2>&1 || true
  sudo killall -HUP mDNSResponder >/dev/null 2>&1 || true
  for _ in {1..30}; do
    curl --silent --max-time 5 --output /dev/null "https://www.google.com/generate_204" && break
    sleep 2
  done
fi
open_brave() {
  if [[ -f $WORK_DIR/session-reopened ]]; then
    nohup sudo launchctl asuser "$(id -u)" sudo -u "$(id -un)" \
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" "${BRAVE_FLAGS[@]}" \
      </dev/null >>"$WORK_DIR/brave.log" 2>&1 &
  else
    nohup "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" "${BRAVE_FLAGS[@]}" \
      </dev/null >>"$WORK_DIR/brave.log" 2>&1 &
  fi
}
reset_brave_sync_state() {
  mv "$HOME/$BRAVE_SUBDIR/Default/Sync Data" "$WORK_DIR/brave-sync-data.old" 2>/dev/null || true
  python3 - "$HOME/$BRAVE_SUBDIR/Default/Preferences" <<'PY' 2>/dev/null
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    prefs = json.load(handle)
for key in ("brave_sync_v2", "sync"):
    prefs.pop(key, None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(prefs, handle)
PY
}
if [[ ${CB_KEEP_SESSION:-} == 1 ]]; then
  reset_brave_sync_state && printf 'Brave Sync state reset before opening.\n' >&2
fi
if [[ -s $WORK_DIR/brave-bookmarks.json ]]; then
  python3 "$SCRIPTS/desktop/bookmarks-bar.py" "$HOME/$BRAVE_SUBDIR/Default" "$WORK_DIR/brave-bookmarks.json" >&2 || true
fi
python3 - "$HOME/$BRAVE_SUBDIR" <<'PY' || printf 'Brave: welcome page not marked seen.\n' >&2
import json, os, sys
root = sys.argv[1]
profiles = [os.path.join(root, d) for d in os.listdir(root) if os.path.isfile(os.path.join(root, d, "Preferences"))] if os.path.isdir(root) else []
for profile in profiles or [os.path.join(root, "Default")]:
    path = os.path.join(profile, "Preferences")
    try:
        with open(path, encoding="utf-8") as handle:
            prefs = json.load(handle)
    except FileNotFoundError:
        prefs = {}
    except (OSError, ValueError):
        continue  # unreadable: left as it is, never replaced
    prefs.setdefault("brave", {})["has_seen_brave_welcome_page"] = True
    prefs.setdefault("browser", {})["has_seen_welcome_page"] = True
    os.makedirs(profile, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(prefs, handle)
PY
: >"$WORK_DIR/brave.log"
open_brave
pids+=($!)
awk "/<<'QT'/{f=1;next} /^QT\$/{f=0} f" "$SCRIPTS/desktop/10-compute-base.sh" >"$WORK_DIR/quiet-tabs.py"
awk "/compute-base-extensions.list <<'X'/{f=1;next} /^X\$/{f=0} f" "$SCRIPTS/desktop/10-compute-base.sh" >"$WORK_DIR/extensions.list"
nohup python3 "$WORK_DIR/quiet-tabs.py" 9333 900 "$WORK_DIR/extensions.list" </dev/null >"$WORK_DIR/quiet-tabs.log" 2>&1 &
brave_opened=$(date +%s) brave_restarts=0
source "$SCRIPTS/desktop/brave-sync.sh" && brave_sync_stage "$HOME" "$SCRIPTS/desktop"
if [[ -f $HOME/.config/compute-base/brave-sync.py ]]; then
  ( python3 "$HOME/.config/compute-base/brave-sync.py" 9333 "$HOME/.config/compute-base/brave-sync-code"       >"$WORK_DIR/brave-sync.log" 2>&1 & )
fi
(
  trap - ERR; set +e
  if [[ ${CB_HANDOFF_TEST:-} == seed ]]; then
    CB_WORK_DIR="$WORK_DIR" bash "$SCRIPTS/desktop/handoff-mac.sh" seeded
    gate_diag "$(printf 'A seeded\n'; cat "$HOME/.local/share/cb-handoff/seed.txt")"
  else
    bash "$SCRIPTS/desktop/handoff-mac.sh" apply "$WORK_DIR"
    if [[ ${CB_HANDOFF_TEST:-} == check ]]; then
      gate_diag "$(printf 'B restored\n'; bash "$SCRIPTS/desktop/handoff-mac.sh" verify; printf 'steps: '; tr '\n' ' ' <"$WORK_DIR/handoff-done")"
    fi
  fi
) </dev/null >>"$WORK_DIR/handoff.log" 2>&1 &
( trap - ERR; set +e; sleep 60; bash "$SCRIPTS/desktop/apps-mac.sh" "$WORK_DIR" || true ) </dev/null >/dev/null 2>&1 &
(
  trap - ERR; set +e; sleep 90
  bash "$SCRIPTS/desktop/ai-agent.sh" "$WORK_DIR"
  cua_app=$(find "$HOME/.hermes/tools" -maxdepth 2 -name CuaDriver.app -type d 2>/dev/null | head -n 1)
  if [[ -n $cua_app ]]; then
    for service in kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceListenEvent kTCCServiceScreenCapture; do
      grant "$service" "$cua_app/Contents/MacOS/cua-driver"
      grant "$service" com.trycua.driver 0 "$cua_app"
    done
    restart_tcc
  fi
  if grep -q '^ready' "$WORK_DIR/agent-state" 2>/dev/null; then
    agent="$HOME/Applications/AI Agent.app"
    mkdir -p "$agent/Contents/MacOS"
    printf '#!/bin/bash\nprintf "#!/bin/bash\\nexport PATH=\\"\\$HOME/.local/bin:\\$PATH\\"\\nexec hermes\\n" >/tmp/cb-hermes.command\nchmod +x /tmp/cb-hermes.command\nexec open -a Terminal /tmp/cb-hermes.command\n' \
      >"$agent/Contents/MacOS/AI Agent"
    chmod 755 "$agent/Contents/MacOS/AI Agent"
    python3 - "$agent" <<'PY' && killall Dock >/dev/null 2>&1
import plistlib, subprocess, sys
agent = sys.argv[1]
with open(f"{agent}/Contents/Info.plist", "wb") as handle:
    plistlib.dump({"CFBundleName": "AI Agent", "CFBundleExecutable": "AI Agent", "CFBundleIdentifier": "base.compute.ai-agent",
                   "CFBundlePackageType": "APPL"}, handle)
raw = subprocess.run(["defaults", "export", "com.apple.dock", "-"], capture_output=True).stdout
dock = plistlib.loads(raw) if raw else {}
apps = [a for a in dock.get("persistent-apps", []) if "AI Agent" not in str(a.get("tile-data", {}).get("file-data", {}))]
apps.append({"tile-data": {"file-data": {"_CFURLString": f"file://{agent}/", "_CFURLStringType": 15},
                           "file-label": "AI Agent"}, "tile-type": "file-tile"})
dock["persistent-apps"] = apps
subprocess.run(["defaults", "import", "com.apple.dock", "-"], input=plistlib.dumps(dock), check=True)
PY
  fi
) </dev/null >>"$WORK_DIR/agent.log" 2>&1 &
printf 'Brave is open (%s appearance).\n' "$(defaults read -g AppleInterfaceStyle 2>/dev/null | tr 'A-Z' 'a-z' || echo light)"

LINK_SUFFIX="/stream.html?hostId=$host_id&appId=$app_id"
printf 'Browser will remain available until stopped or idle for one continuous hour.\n'
if [[ ${SOUND_CHECK:-} == 1 ]]; then
  ( end=$(( $(date +%s) + 600 )); while (( $(date +%s) < end )); do afplay /System/Library/Sounds/Glass.aiff; done ) &
  ( brew install --quiet sox >/dev/null 2>&1 || true ) &
fi

zero_since=0
last_state=""
last_auto_sync=$(date +%s)
dirty_since=0

while true; do
  if ! tunnel_watch; then
    printf 'No secure link could be opened again; saving and stopping.\n' >&2
    finish_session broken
  fi
  now=$(date +%s)
  if (( now - brave_opened >= 60 && now - brave_opened < 360 && brave_restarts < 3 )) &&
     ! pgrep -x "Brave Browser" >/dev/null; then
    brave_restarts=$((brave_restarts + 1)) brave_opened=$now
    printf 'Brave was not running; opening it again (%s).\n' "$brave_restarts" >&2
    rm -f "$HOME/$BRAVE_SUBDIR"/Singleton* 2>/dev/null || true
    if ((brave_restarts == 1)); then
      reset_brave_sync_state && printf 'Brave Sync state reset after a crash on opening.\n' >&2
    fi
    open_brave
    if ((brave_restarts == 1)) && [[ -f $HOME/.config/compute-base/brave-sync.py ]]; then
      ( sleep 20; python3 "$HOME/.config/compute-base/brave-sync.py" 9333 "$HOME/.config/compute-base/brave-sync-code" \
          >>"$WORK_DIR/brave-sync.log" 2>&1 ) &
    fi
  fi

  stop_status=$(curl --silent --max-time 10 --output /dev/null --write-out '%{http_code}' "$STOP_REQUEST_URL" || true)
  if [[ "$stop_status" == "200" ]]; then
    printf 'A graceful stop was requested.\n'
    finish_session requested
  fi

  if [[ -n "${SYNC_REQUEST_URL:-}" ]]; then
    sync_status=$(curl --silent --max-time 10 --output /dev/null --write-out '%{http_code}' "$SYNC_REQUEST_URL" || true)
    if [[ "$sync_status" == "200" ]]; then
      printf 'A manual sync was requested via control signal.\n'
      snapshot_profile manual
      curl --silent --max-time 10 --output /dev/null --request DELETE "$SYNC_REQUEST_URL" 2>/dev/null || true
      last_auto_sync=$now
      dirty_since=0
    fi
  fi

  if [[ $BURNER != 1 ]] && bash "$PROFILE_TOOL" dirty "$HOME" "$STATE_DIR"; then
    if (( dirty_since == 0 )); then
      dirty_since=$now
    elif (( now - last_auto_sync >= 300 )); then
      printf 'Unsynced changes detected; running background auto-sync.\n'
      snapshot_profile auto
      last_auto_sync=$now
      dirty_since=0
    fi
  else
    dirty_since=0
  fi

  if (( now - started_at >= SAFETY_SECONDS )); then
    printf 'Safety cutoff reached; saving and stopping before the runner limit.\n'
    finish_session safety
  fi

  if [[ ${SOUND_CHECK:-} == 1 ]] && (( now % 60 < SAMPLE_SECONDS )); then
    printf '== idle: streamers=%s viewer-conns=%s tunnel-conns=%s\n' \
      "$(pgrep -f "$VIEWER_DIR/streamer|\\./streamer" | wc -l | tr -d ' ')" \
      "$(lsof -nP -iTCP:8080 -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ')" \
      "$(lsof -nP -iTCP:8090 -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ')"
  fi
  xattr -r -d com.apple.quarantine "$HOME/Downloads" 2>/dev/null || true
  for app in /Applications/*.app; do
    if xattr -p com.apple.quarantine "$app" >/dev/null 2>&1; then sudo xattr -r -d com.apple.quarantine "$app" 2>/dev/null || true; fi
  done
  if [[ -s $WORK_DIR/gate/live ]]; then viewer_on() { (( $(tr -cd '0-9' <"$WORK_DIR/gate/live")0 > 0 )); }
  else viewer_on() { pgrep -f "$VIEWER_DIR/streamer|\\./streamer" >/dev/null 2>&1; }; fi
  if viewer_on; then
    zero_since=0
    if [[ "$last_state" != connected ]]; then
      printf 'A desktop viewer is connected; idle timer reset.\n'
      last_state=connected
    fi
  else
    if (( zero_since == 0 )); then
      zero_since=$now
      printf 'No desktop viewer is connected; one-hour idle timer started.\n'
    fi
    last_state=idle
    if (( now - zero_since >= IDLE_SECONDS )); then
      printf 'One continuous hour with no connected viewer; shutting down.\n'
      finish_session idle
    fi
  fi

  if [[ ${SOUND_CHECK:-} == 1 || ${CB_DIAG:-} == 1 ]] && (( now % 60 < SAMPLE_SECONDS )); then
    gate_diag "$(grep -h -i -E 'error|warn|fail|refus|timeout|denied|session|starting moonlight|stream uses|launch|resume|status code|client|encoder|capture|display'       "$WORK_DIR/viewer.log" "$WORK_DIR/sunshine.log" "$WORK_DIR/gate/caddy.log" "$WORK_DIR/gate/verifier.log" "$nginx_dir/logs/error.log" 2>/dev/null | grep -v -E 'Rtt|Failed to send packet (Key|Mouse)|MAC address' | grep -v -i 'udp socket' | cut -c1-240 | tail -n 50; echo "== screen"; cat "$WORK_DIR/display" "$WORK_DIR/own-size" "$WORK_DIR/screen-size" "$WORK_DIR/screen-scale" 2>/dev/null; ls "$WORK_DIR" | grep -E "screen-fallback|sunshine-output|vdisplay" ; grep -h -E "screen modes|hidpi|Retina|Screens?[ :]|Matches|refused|Preparing|Opened|did not come up" "$WORK_DIR/modes.log" "${RUNNER_TEMP:-/tmp}/compute-base-desktop.log" 2>/dev/null | tail -n 12; lim 15 displayplacer list 2>/dev/null | grep -E "Resolution:|scaling:on|current mode" | head -n 8; echo "== pin hook"; cat "$WORK_DIR/pin-hook.log" 2>/dev/null; echo "== agent"; cat "$WORK_DIR/agent-state" 2>/dev/null; grep -v "^\s*$" "$WORK_DIR/agent.log" 2>/dev/null | tail -n 6 | cut -c1-200; echo "== bookmarks bar"; python3 -c 'import json,sqlite3,sys; d=sys.argv[1]; b=json.load(open(d+"/Bookmarks")); print([n["name"] for n in b["roots"]["bookmark_bar"]["children"]][:12], len(b["roots"]["other"]["children"]), "under Other;", sqlite3.connect(d+"/Favicons").execute("select count(*) from icon_mapping").fetchone()[0], "icons")' "$HOME/$BRAVE_SUBDIR/Default" 2>&1 | tail -n 1; echo "== local network asks"; lim 40 log show --last 15m --info --predicate 'process == "nehelper" AND eventMessage CONTAINS "prompting for"' 2>/dev/null | grep -o "prompting for .*" | sort | uniq -c; echo "== cpu"; top -l 2 -n 12 -o cpu -stats pid,command,cpu,mem 2>/dev/null | tail -n 14; sysctl -n vm.loadavg hw.ncpu 2>/dev/null)"
  fi
  brave_sync_report "$WORK_DIR/brave-sync.log" "pgrep -x 'Brave Browser'" || true
  sleep "$SAMPLE_SECONDS"
done
