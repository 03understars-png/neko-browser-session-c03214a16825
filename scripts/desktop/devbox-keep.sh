#!/usr/bin/env bash
set -u
KEEP=${CB_PERSIST_DIR:?}
HOME_COPY="$KEEP/home"
SYSTEM_COPY="$KEEP/system"
BASELINE="$KEEP/baseline"
log() { printf '%s\n' "$*"; }
lim() { perl -e 'alarm shift; exec @ARGV' "$@"; }

HOME_EXCLUDES=(
  --no-specials --no-devices
  --exclude=/compute-base --exclude=/cb-boot.sh --exclude=/cb-boot.log --exclude=/cb-* --exclude=/Library/LaunchAgents/cb.*
  --exclude=/Library/Application\ Support/com.apple.TCC --exclude=/Library/Keychains
  --exclude=/.Trash --exclude=/.cache --exclude=/Library/Caches --exclude=/Library/Logs
  --exclude=/Library/Application\ Support/CrashReporter --exclude=/Library/Application\ Support/Code/CachedData
  --exclude=/Library/Application\ Support/Code/logs --exclude=/Library/Saved\ Application\ State
  --exclude=/.config/sunshine --exclude=/.local/share/compute-base --exclude=/.local/share/cb-handoff-run
  --exclude=/Library/LaunchAgents/base.compute.* --exclude=/.ssh/authorized_keys --exclude=/.zsh_sessions
  --exclude=/.npm/_cacache --exclude=/.gradle/caches --exclude=/.android/cache
  --exclude=/Library/Group\ Containers/group.com.apple.* --exclude=/Library/Containers/com.apple.*
  --exclude=/Library/Mail --exclude=/Library/Messages --exclude=/Library/Safari --exclude=/Library/Suggestions
  --exclude=/Library/Biome --exclude=/Library/IdentityServices --exclude=/Library/Metadata --exclude=/Library/Trial
)
SYSTEM_ROOTS=(/Applications /opt)
SYSTEM_EXCLUDES=(--exclude=/opt/homebrew --exclude=/opt/runner --exclude=/Applications/Xcode*.app)

case ${1:-} in
  baseline)
    mkdir -p "$KEEP" 2>/dev/null || sudo install -d -o "$(id -un)" "$KEEP"
    touch "$BASELINE"
    ;;
  restore)
    [[ -f $KEEP/kept-here && -d $HOME_COPY ]] || exit 1
    log "Putting your kept desktop back..."
    rsync -aX --exclude=/.DS_Store "${HOME_EXCLUDES[@]}" "$HOME_COPY"/ "$HOME"/ || log "Some of your kept files could not be put back."
    for root in "${SYSTEM_ROOTS[@]}"; do
      [[ -d $SYSTEM_COPY$root ]] || continue
      sudo rsync -aX --no-times --exclude=/homebrew --exclude=/runner "$SYSTEM_COPY$root"/ "$root"/ || log "Some of what you installed in $root could not be put back."
    done
    lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    for app in "$SYSTEM_COPY"/Applications/*.app; do
      [[ -d $app && -x $lsregister ]] && "$lsregister" -f "/Applications/${app##*/}" >/dev/null 2>&1
    done
    killall Dock >/dev/null 2>&1 || true
    killall cfprefsd >/dev/null 2>&1 || true
    ;;
  save)
    mkdir -p "$KEEP" 2>/dev/null || sudo install -d -o "$(id -un)" "$KEEP"
    mkdir -p "$HOME_COPY" "$SYSTEM_COPY"
    status=0
    lim 1500 rsync -aX --ignore-errors --delete-after "${HOME_EXCLUDES[@]}" "$HOME"/ "$HOME_COPY"/ 2>&1 | tail -n 3 | sed 's/^/devbox-keep: /'
    status=${PIPESTATUS[0]}
    ((status == 0 || status == 23 || status == 24)) || { log "Could not keep your home folder on the Devbox ($status)."; exit 1; }
    if [[ -f $BASELINE ]]; then
      list=$(mktemp)
      for root in "${SYSTEM_ROOTS[@]}"; do
        [[ -d $root ]] || continue
        sudo find "$root" -xdev \( -path /opt/homebrew -o -path /opt/runner -o -path "/Applications/Xcode*" \) -prune -o \
          -newer "$BASELINE" -print 2>/dev/null
      done | sed 's#^/##' >"$list"
      sudo rm -rf "$KEEP/system.new" && mkdir -p "$KEEP/system.new"
      copied=0
      if [[ -s $list ]]; then
        lim 1500 sudo rsync -aX --relative --link-dest="$SYSTEM_COPY" --files-from="$list" "${SYSTEM_EXCLUDES[@]}" / "$KEEP/system.new"/ 2>&1 |
          tail -n 3 | sed 's/^/devbox-keep: /'
        copied=${PIPESTATUS[0]}
      fi
      if ((copied == 0 || copied == 23 || copied == 24)); then
        sudo rm -rf "$SYSTEM_COPY" && mv "$KEEP/system.new" "$SYSTEM_COPY"
      else
        log "What you installed could not be copied this time ($copied); the last copy is kept."
        sudo rm -rf "$KEEP/system.new"
      fi
      rm -f "$list"
    fi
    sync
    touch "$KEEP/kept-here"
    log "Your desktop is kept on the Devbox ($(du -sh "$HOME_COPY" 2>/dev/null | cut -f1) home, $(du -sh "$SYSTEM_COPY" 2>/dev/null | cut -f1) installed)."
    ;;
  *)
    echo "usage: devbox-keep.sh restore|save|baseline" >&2
    exit 2
    ;;
esac
