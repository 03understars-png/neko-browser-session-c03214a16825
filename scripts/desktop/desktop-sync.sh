#!/usr/bin/env bash
set -Eeuo pipefail

readonly PERSONAL=(Desktop Documents Downloads Pictures Music Videos)
readonly HOME_EXCLUDES=(.cache .XDG ssl .local/share/Trash .local/share/baloo .local/share/compute-base
  .stfolder .stignore .stversions
  .vscode/extensions .config/Code/CachedData .config/Code/CachedExtensionVSIXs .config/Code/Cache
  .config/Code/logs .android .gradle .npm .pub-cache .lmstudio/models .lmstudio/.internal
  .ollama .local/ollama .hermes/hermes-agent .hermes/installs .hermes/tools .hermes/cache .hermes/logs)
readonly KEPT_NAME="Kept from before sync"
readonly SYSTEM_JUNK=(.DS_Store '._*' .directory desktop.ini Thumbs.db '*.lnk')
readonly KEPT_SETTINGS=.local/share/compute-base/kept
readonly KEPT_SETTINGS_COUNT=3
NAME_EXCLUDES=(
  'Cache' 'Code Cache' 'GPUCache' 'DawnCache' 'DawnGraphiteCache' 'DawnWebGPUCache'
  'GrShaderCache' 'GraphiteDawnCache' 'ShaderCache' 'component_crx_cache'
  'extensions_crx_cache' 'Crashpad' 'Crash Reports' 'Safe Browsing' 'BrowserMetrics'
  'CacheStorage' 'ScriptCache' 'optimization_guide_model_store'
  'OnDeviceHeadSuggestModel' 'GPUPersistentCache' 'Local Traces' 'BrowserMetrics-spare.pma'
  'SingletonLock' 'SingletonCookie' 'SingletonSocket'
)
if [[ -n ${DESKTOP_EXTRA_EXCLUDES:-} ]]; then
  IFS=: read -r -a _extra_excludes <<<"$DESKTOP_EXTRA_EXCLUDES"
  NAME_EXCLUDES+=("${_extra_excludes[@]}")
fi
readonly NAME_EXCLUDES
readonly DESKTOP_UID=${DESKTOP_UID:-1000}
readonly DESKTOP_GID=${DESKTOP_GID:-$DESKTOP_UID}
readonly BRAVE_SUBDIR=${BRAVE_SUBDIR:-.config/BraveSoftware/Brave-Browser}
DESKTOP_ONLY=()
if [[ -n ${DESKTOP_PATHS:-} ]]; then IFS=: read -r -a DESKTOP_ONLY <<<"$DESKTOP_PATHS"; fi
readonly DESKTOP_ONLY
readonly TRANSFER_SECONDS=7200
RETRY_ALL=()
if curl --help all 2>/dev/null | grep -- '--retry-all-errors' >/dev/null; then RETRY_ALL=(--retry-all-errors); fi
readonly STALL=(--speed-limit 10240 --speed-time 60 "${RETRY_ALL[@]}")

log() { printf '%s\n' "$*"; }

desktop_filters() {
  local name path part prefix parts
  if ((${#DESKTOP_ONLY[@]})); then
    for name in "${NAME_EXCLUDES[@]}"; do printf '%s\0' --exclude "$name"; done
    for path in "${DESKTOP_ONLY[@]}"; do
      prefix=""
      IFS=/ read -r -a parts <<<"$path"
      for part in "${parts[@]}"; do
        prefix="$prefix/$part"
        printf '%s\0' --include "$prefix/"
      done
      printf '%s\0' --include "$prefix"
      printf '%s\0' --include "$prefix/***"
    done
    printf '%s\0' --exclude '*'
    return
  fi
  for name in "${HOME_EXCLUDES[@]}" "${PERSONAL[@]}"; do printf '%s\0' --exclude "/$name"; done
  for name in "${NAME_EXCLUDES[@]}"; do printf '%s\0' --exclude "$name"; done
}

remote_epoch() {
  local url=$1 modified
  [[ $url == https://* ]] || { echo 0; return; }
  modified=$(curl --fail --silent --head --max-time 30 "$url" 2>/dev/null |
    awk -F': ' 'tolower($1) == "last-modified" {print $2}' | tr -d '\r' || true)
  if [[ -n $modified ]]; then date -d "$modified" +%s 2>/dev/null || echo 0; else echo 0; fi
}

marker_epoch() { stat -c %Y "$1" 2>/dev/null || echo 0; }

known_epoch() {
  local stored
  stored=$(cat "$2/$1.remote" 2>/dev/null || echo 0)
  [[ $stored =~ ^[0-9]+$ ]] && echo "$stored" || echo 0
}

TRANSFER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/transfer.sh"

fetch() {
  local url=$1 out=$2
  if [[ -f $TRANSFER ]]; then
    bash "$TRANSFER" get "$url" "$out" "$TRANSFER_SECONDS" || return
  else
    curl --fail --location --silent --show-error --retry 3 --retry-delay 5 "${STALL[@]}" \
      --max-time "$TRANSFER_SECONDS" "$url" --output "$out" || return
  fi
  tar -tzf "$out" >"$out.list" || { rm -f "$out.list"; log "The saved archive is damaged." >&2; return 1; }
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "$out.list"; then
    rm -f "$out.list"
    log "The saved archive contains an unsafe path; ignoring it." >&2
    return 1
  fi
  rm -f "$out.list"
}

upload() {
  local took size limit
  size=$(wc -c <"$1" | tr -d ' ')
  limit=$((120 + size / 2097152))
  ((limit < TRANSFER_SECONDS)) || limit=$TRANSFER_SECONDS
  if [[ -f $TRANSFER ]]; then
    bash "$TRANSFER" put "$1" "$2" "$limit"
    return
  fi
  took=$(curl --fail --silent --show-error --retry 2 --retry-delay 5 "${STALL[@]}" --max-time "$limit" \
    --request PUT --header 'Content-Type: application/gzip' --upload-file "$1" --output /dev/null \
    --write-out '%{time_total} %{speed_upload}' "$2") || return
  awk -v t="${took% *}" -v b="${took#* }" 'BEGIN { printf "Uploaded in %.0f s (%.1f MB/s).\n", t, b / 1048576 }'
}

changed() {
  local kind=$1 home=$2 state=$3 marker="$3/$1.synced" name prune=() dirs=()
  [[ -f $marker && ! -e $state/$kind.pending ]] || return 0
  if [[ $kind == desktop ]]; then
    if ((${#DESKTOP_ONLY[@]})); then
      for name in "${NAME_EXCLUDES[@]}"; do prune+=(-name "$name" -o); done
      unset 'prune[${#prune[@]}-1]'
      for name in "${DESKTOP_ONLY[@]}"; do [[ -e $home/$name ]] && dirs+=("$home/$name"); done
      ((${#dirs[@]})) || return 1
      [[ -n $(find "${dirs[@]}" \( "${prune[@]}" \) -prune -o -newer "$marker" -print -quit 2>/dev/null) ]]
      return
    fi
    for name in "${HOME_EXCLUDES[@]}" "${PERSONAL[@]}"; do prune+=(-path "$home/$name" -o); done
    for name in "${NAME_EXCLUDES[@]}"; do prune+=(-name "$name" -o); done
    unset 'prune[${#prune[@]}-1]'
    [[ -n $(find "$home" \( "${prune[@]}" \) -prune -o -newer "$marker" -print -quit 2>/dev/null) ]]
  else
    for name in "${PERSONAL[@]}"; do [[ -d $home/$name ]] && dirs+=("$home/$name"); done
    ((${#dirs[@]})) || return 1
    [[ -n $(find "${dirs[@]}" -name "$KEPT_NAME *" -prune -o -newer "$marker" -print -quit 2>/dev/null) ]]
  fi
}

apply() {
  local kind=$1 src=$2 home=$3 keep=$4 name args=(-a --no-specials --no-devices --delete --chmod=u+rwX)
  if [[ -n $keep ]]; then args+=(--backup "--backup-dir=$keep"); fi
  if [[ $kind == desktop ]]; then
    local filters=() protect=() path
    mapfile -d '' filters < <(desktop_filters)
    if ((${#DESKTOP_ONLY[@]} > 1)); then
      for path in "${DESKTOP_ONLY[@]}"; do
        [[ $path == "$BRAVE_SUBDIR" ]] && continue
        protect+=(--filter "P /$path" --filter "P /$path/***")
      done
    fi
    rsync "${args[@]}" "${protect[@]}" "${filters[@]}" "$src"/ "$home"/
  else
    local junk_excludes=()
    for name in "${SYSTEM_JUNK[@]}"; do junk_excludes+=(--exclude "$name"); done
    for name in "${PERSONAL[@]}"; do
      [[ -d $src/$name ]] || continue
      mkdir -p "$home/$name"
      chmod u+rwx "$home/$name"
      if [[ -n $keep ]]; then
        rsync -a --no-specials --no-devices --delete --chmod=u+rwX --exclude "$KEPT_NAME *" "${junk_excludes[@]}"           --backup "--backup-dir=$keep/$name" "$src/$name"/ "$home/$name"/
      else
        rsync -a --no-specials --no-devices --delete --chmod=u+rwX --exclude "$KEPT_NAME *" "${junk_excludes[@]}" "$src/$name"/ "$home/$name"/
      fi
    done
  fi
}

restore_part() {
  local kind=$1 url=$2 home=$3 state=$4 remote local_epoch keep=""
  local archive="$state/$kind.download.tar.gz" unpacked="$state/$kind.unpacked"
  [[ $url == https://* ]] || return 0
  remote=$(remote_epoch "$url")
  if ((remote == 0)); then
    touch "$state/$kind.pending"
    return 1
  fi
  local_epoch=$(known_epoch "$kind" "$state")
  if ((remote <= local_epoch)); then
    log "Your $kind copy on this machine is already the latest."
    return 0
  fi
  log "Restoring your saved $kind..."
  rm -rf "$unpacked" && mkdir -p "$unpacked"
  if ! fetch "$url" "$archive"; then
    rm -rf "$archive" "$unpacked"
    log "Could not download your saved $kind; keeping this machine's copy." >&2
    return 0
  fi
  tar -xzf "$archive" -C "$unpacked" --no-same-owner
  rm -f "$archive"
  if [[ -f $state/$kind.synced ]] && changed "$kind" "$home" "$state"; then
    keep="$state/kept/$kind"
  elif [[ ! -f $state/$kind.synced ]] && [[ $kind == files ]] && [[ -n $(find "$home"/{Desktop,Documents,Downloads,Pictures,Music,Videos} -type f -print -quit 2>/dev/null) ]]; then
    keep="$state/kept/$kind"
  fi
  apply "$kind" "$unpacked" "$home" "$keep"
  rm -rf "$unpacked" "$state/$kind.pending"
  touch "$state/$kind.synced"
  echo "$remote" >"$state/$kind.remote"
  log "Restored your saved $kind."
  echo "$kind" >>"$state/restored"
}

restore_legacy() {
  local home=$1 state=$2 remote archive="$2/legacy.download.tar.gz" unpacked="$2/legacy.unpacked"
  [[ ${LEGACY_DOWNLOAD_URL:-} == https://* ]] || return 0
  remote=$(remote_epoch "$LEGACY_DOWNLOAD_URL")
  ((remote > 0)) || return 0
  if ((remote <= $(known_epoch desktop "$state"))) && [[ -d $home/$BRAVE_SUBDIR ]]; then
    return 0
  fi
  log "Restoring your saved Brave profile..."
  rm -rf "$unpacked" && mkdir -p "$unpacked"
  fetch "$LEGACY_DOWNLOAD_URL" "$archive" || { rm -rf "$archive" "$unpacked"; return 0; }
  tar -xzf "$archive" -C "$unpacked" --no-same-owner
  rm -f "$archive"
  mkdir -p "$home/$BRAVE_SUBDIR"
  rsync -a --no-specials --no-devices --delete "$unpacked"/ "$home/$BRAVE_SUBDIR"/
  rm -rf "$unpacked"
  touch "$state/desktop.pending"
  echo brave >>"$state/restored"
  log "Restored your saved Brave profile."
}

restore() {
  local home=$1 state=$2
  mkdir -p "$home" "$state"
  rm -f "$state/restored"
  if ! restore_part desktop "${PROFILE_DOWNLOAD_URL:-}" "$home" "$state"; then
    restore_legacy "$home" "$state"
  fi
  restore_part files "${FILES_DOWNLOAD_URL:-}" "$home" "$state" || true
  rm -f "$home/$BRAVE_SUBDIR"/Singleton{Lock,Cookie,Socket}
  local prefs
  for prefs in "$home/$BRAVE_SUBDIR"/*/Preferences; do
    [[ -f $prefs ]] || continue
    sed -E 's/"exit_type":"(Crashed|SessionCrashed)"/"exit_type":"Normal"/g; s/"exited_cleanly":false/"exited_cleanly":true/g' "$prefs" >"$prefs.cb-tmp" &&
    cat "$prefs.cb-tmp" >"$prefs" || true
    rm -f "$prefs.cb-tmp"
  done
  if [[ -d $state/kept ]]; then
    local stamp kept_dir old
    stamp=$(date +'%Y-%m-%d %H.%M')
    if [[ -d $state/kept/files ]] && [[ -n $(ls -A "$state/kept/files") ]]; then
      kept_dir="$home/Desktop/$KEPT_NAME $stamp"
      mkdir -p "$kept_dir"
      cp -a "$state/kept/files"/. "$kept_dir"/
      log "Local files that were replaced were kept in: ${kept_dir#"$home"/}"
    fi
    if [[ -d $state/kept/desktop ]] && [[ -n $(ls -A "$state/kept/desktop") ]]; then
      kept_dir="$home/$KEPT_SETTINGS/$stamp.$(date +%S)"
      mkdir -p "$kept_dir"
      cp -a "$state/kept/desktop"/. "$kept_dir"/
      while read -r old; do rm -rf "$home/$KEPT_SETTINGS/$old"; done         < <(ls -1 "$home/$KEPT_SETTINGS" | sort -r | tail -n +$((KEPT_SETTINGS_COUNT + 1)))
      log "Local settings that were replaced were kept in: $KEPT_SETTINGS"
    fi
    rm -rf "$state/kept"
  fi
  if [[ $(id -u) != "$DESKTOP_UID" ]]; then chown -R "$DESKTOP_UID:$DESKTOP_GID" "$home"; fi
}

newer_signins() {
  local state=$1 url=${PROFILE_DOWNLOAD_URL:-} newer="$1/newer-signins" archive="$1/newer.tar.gz"
  [[ $url == https://* ]] || return 0
  local remote known
  remote=$(remote_epoch "$url")
  known=$(known_epoch desktop "$state")
  ((remote > known)) || return 0
  rm -rf "$newer" && mkdir -p "$newer"
  if fetch "$url" "$archive" 2>/dev/null &&
     tar -xzf "$archive" -C "$newer" --no-same-owner --wildcards \
       '*/Cookies' '*/Login Data' '*/Login Data For Account' 2>/dev/null; then
    printf '%s\n' "$newer"
  else
    find "$newer" -type f | grep -q . && printf '%s\n' "$newer"
  fi
  rm -f "$archive"
}

merge_signins() {
  local into=$1 newer=$2 py
  [[ -n $newer && -d $newer ]] || return 0
  py=$(case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) command -v python || command -v python3 ;; *) command -v python3 || command -v python ;; esac) || return 0
  "$py" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-signins.py" "$into" "$newer" || true
}

snapshot_desktop() {
  local home=$1 state=$2 container=$3 archive=$4 staging="$2/desktop.staging" paused=0 status=0 filters=()
  mapfile -d '' filters < <(desktop_filters)
  mkdir -p "$staging"
  if [[ -n $container ]] && docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
    docker pause "$container" >/dev/null && paused=1
  fi
  local newer
  newer=$(newer_signins "$state")
  if [[ -z $container && ${#DESKTOP_ONLY[@]} -gt 0 && $(uname -s) == MSYS* ]]; then
    local paths=() name
    for name in "${DESKTOP_ONLY[@]}"; do [[ -e $home/$name ]] && paths+=("$name"); done
    ((${#paths[@]})) || { tar -czf "$archive" -T /dev/null; return; }
    set +e
    tar --ignore-failed-read --warning=no-file-changed --warning=no-file-removed --warning=no-failed-read \
      "${NAME_EXCLUDES[@]/#/--exclude=}" -C "$home" -cf "$archive.tar" "${paths[@]}"
    local packed=$?
    set -e
    ((packed <= 1)) || return "$packed"
    if [[ -n $newer ]]; then
      local merged="$state/merged-signins" file
      rm -rf "$merged" && mkdir -p "$merged"
      while IFS= read -r -d '' file; do
        file=${file#"$newer"/}
        [[ -f $home/$file ]] && mkdir -p "$merged/$(dirname "$file")" && cp "$home/$file" "$merged/$file"
      done < <(find "$newer" -type f -print0)
      merge_signins "$merged" "$newer"
      (cd "$merged" && find . -type f -print0 | tar --null -rf "$archive.tar" -T -) || true
      rm -rf "$merged" "$newer"
    fi
    gzip -1 -c "$archive.tar" >"$archive" && rm -f "$archive.tar"
    return
  fi
  rsync -a --no-specials --no-devices --delete --delete-excluded "${filters[@]}" "$home"/ "$staging"/ || status=$?
  if ((paused)); then docker unpause "$container" >/dev/null; fi
  ((status == 0 || status == 24)) || return "$status"
  if [[ -n $newer ]]; then
    merge_signins "$staging" "$newer"
    rm -rf "$newer"
  fi
  tar -czf "$archive" -C "$staging" .
}

snapshot_files() {
  local home=$1 archive=$2 status
  set +e
  tar --warning=no-file-changed --warning=no-file-removed --mode=u+rwX --exclude="$KEPT_NAME *" --exclude=".syncthing.*" --exclude=".stfolder" "${SYSTEM_JUNK[@]/#/--exclude=}" -C "$home" -cf - "${PERSONAL[@]}" | gzip -1 >"$archive"
  status=("${PIPESTATUS[@]}")
  set -e
  ((status[0] <= 1 && status[1] == 0))
}

save_part() {
  local kind=$1 home=$2 state=$3 container=$4 url=$5 shared=$6 archive="$3/$1.upload.tar.gz"
  [[ $url == https://* ]] || return 0
  touch "$state/$kind.synced.next"
  if [[ $kind == desktop ]]; then
    snapshot_desktop "$home" "$state" "$container" "$archive"
  else
    snapshot_files "$home" "$archive"
  fi
  log "Uploading your $kind ($(du -h "$archive" | cut -f1))..."
  if ! upload "$archive" "$url"; then
    rm -f "$archive" "$state/$kind.synced.next"
    log "Could not save your $kind; it will be tried again." >&2
    return 1
  fi
  rm -f "$archive" "$state/$kind.pending"
  mv "$state/$kind.synced.next" "$state/$kind.synced"
  if [[ $url == "$shared" ]]; then remote_epoch "$url" >"$state/$kind.remote"; fi
  log "Saved your $kind at $(date -u +'%Y-%m-%dT%H:%M:%SZ')."
}

save() {
  local home=$1 state=$2 container=$3 reason=${4:-auto} failed=0
  mkdir -p "$state"
  [[ -d $home ]] || { log "No desktop home to save yet."; return 0; }
  exec 9>"$state/sync.lock"
  if [[ $reason == final ]] && ! flock -w 5 9; then
    local holder
    holder=$(cat "$state/sync.lock.pid" 2>/dev/null || true)
    if [[ $holder =~ ^[0-9]+$ ]] && [[ $holder != "$$" ]]; then
      log "Ending the save still running (process $holder) for the final save."
      pkill -TERM -P "$holder" 2>/dev/null || true
      kill -TERM "$holder" 2>/dev/null || true
    fi
    flock -w 30 9 || { log "Another save still holds the lock; saving anyway." >&2; }
  elif [[ $reason != final ]]; then
    flock 9
  fi
  printf '%s\n' "$$" >"$state/sync.lock.pid"
  local name
  for name in "${PERSONAL[@]}"; do
    if [[ ! -d $home/$name ]]; then
      mkdir -p "$home/$name" && chown "$DESKTOP_UID:$DESKTOP_GID" "$home/$name"
    fi
  done
  if [[ $reason != auto ]] || changed desktop "$home" "$state"; then
    save_part desktop "$home" "$state" "$container" "${PROFILE_UPLOAD_URL:-}" "${PROFILE_DOWNLOAD_URL:-}" || failed=1
  fi
  if [[ $reason != auto ]] || changed files "$home" "$state"; then
    save_part files "$home" "$state" "$container" "${FILES_UPLOAD_URL:-}" "${FILES_DOWNLOAD_URL:-}" || failed=1
  fi
  return "$failed"
}

dirty() {
  local home=$1 state=$2
  { [[ ${PROFILE_UPLOAD_URL:-} == https://* ]] && changed desktop "$home" "$state"; } ||
    { [[ ${FILES_UPLOAD_URL:-} == https://* ]] && changed files "$home" "$state"; }
}

close() {
  local container=$1
  docker exec -u abc "$container" pkill -TERM -x brave >/dev/null 2>&1 || return 0
  for _ in $(seq 1 20); do
    docker exec "$container" pgrep -x brave >/dev/null 2>&1 || return 0
    sleep 1
  done
}

command=${1:-}
shift || true
case "$command" in
  restore) restore "$@" ;;
  save) save "$@" ;;
  dirty) dirty "$@" ;;
  close) close "$@" ;;
  *) echo "usage: desktop-sync.sh restore|save|dirty|close ..." >&2; exit 64 ;;
esac
