#!/usr/bin/env bash
brave_sync_stage() {
  local home=$1 files=$2 owner=${3:-} dir
  [[ -f $files/brave-sync.py ]] || return 0
  dir="$home/.config/compute-base"
  local as=()
  if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w $dir ]]; then as=(sudo -n); ${as[@]+"${as[@]}"} mkdir -p "$dir" || return 0; fi
  ${as[@]+"${as[@]}"} cp "$files/brave-sync.py" "$dir/brave-sync.py" || return 0
  if [[ -n ${BRAVE_SYNC_CODE:-} ]]; then
    (umask 077; printf '%s\n' "$BRAVE_SYNC_CODE" | ${as[@]+"${as[@]}"} tee "$dir/brave-sync-code" >/dev/null) || return 0
    ${as[@]+"${as[@]}"} chmod 600 "$dir/brave-sync-code"
  fi
  if [[ -n $owner ]]; then
    chown -R "$owner" "$dir" 2>/dev/null || sudo -n chown -R "$owner" "$dir" 2>/dev/null || true
  fi
}

brave_bookmarks_stage() {
  local home=$1 owner=${2:-} dir file as=()
  dir="$home/.config/compute-base" file="$home/.config/compute-base/bookmarks-policy.json"
  rm -f "$file" 2>/dev/null || sudo -n rm -f "$file" 2>/dev/null || true
  [[ -z ${BURNER:-} && ${BOOKMARKS_URL:-} == https://* ]] || return 0
  if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w $dir ]]; then as=(sudo -n); ${as[@]+"${as[@]}"} mkdir -p "$dir" || return 0; fi
  curl --fail --silent --show-error --location --retry 3 --max-time 60 "$BOOKMARKS_URL" |
    ${as[@]+"${as[@]}"} tee "$file.tmp" >/dev/null 2>&1 || { ${as[@]+"${as[@]}"} rm -f "$file.tmp"; return 0; }
  if ! head -c 64 "$file.tmp" 2>/dev/null | grep -q -E '"(bar|ManagedBookmarks)"'; then
    ${as[@]+"${as[@]}"} rm -f "$file.tmp"; return 0
  fi
  ${as[@]+"${as[@]}"} mv -f "$file.tmp" "$file" || return 0
  ${as[@]+"${as[@]}"} cp "$(dirname "${BASH_SOURCE[0]}")/bookmarks-bar.py" "$dir/bookmarks-bar.py" 2>/dev/null || true
  if [[ -n $owner ]]; then
    chown -R "$owner" "$dir" 2>/dev/null || sudo -n chown -R "$owner" "$dir" 2>/dev/null || true
  fi
  echo "$file"
}

brave_sync_report() {
  local log=$1 check=$2 line running=false py
  [[ -z ${BRAVE_SYNC_REPORTED:-} && -n ${GATE_REPORT_URL:-} ]] || return 0
  [[ -n $( (sudo -n find "$log" -mmin +1 2>/dev/null || find "$log" -mmin +1 2>/dev/null) | head -n 1) ]] || return 0
  line=$( (sudo -n cat "$log" 2>/dev/null || cat "$log" 2>/dev/null) | grep '^{' | tail -n 1) || true
  [[ -n $line ]] || return 0
  BRAVE_SYNC_REPORTED=1
  bash -c "$check" >/dev/null 2>&1 && running=true
  py=$(case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) command -v python || command -v python3 ;; *) command -v python3 || command -v python ;; esac) || return 0
  "$py" -c 'import json, sys; print(json.dumps({"event": "brave-sync", "note": sys.argv[1][:2000], "running": sys.argv[2] == "true"}))' \
    "$line" "$running" | curl --silent --max-time 20 --request PUT --header 'Content-Type: application/json' \
    --data-binary @- "$GATE_REPORT_URL" >/dev/null 2>&1 || true
}
