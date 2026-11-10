#!/usr/bin/env bash
set -u
HANDOFF="$HOME/.local/share/cb-handoff"
export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1
lim() { perl -e 'alarm shift; exec @ARGV' "$@"; }
log() { printf '[%s] handoff: %s\n' "$(date +%T)" "$*"; }

put() {
  local target=$1 temp="$1.new"
  cat >"$temp"
  if cmp -s "$temp" "$target" 2>/dev/null; then rm -f "$temp"; else mv -f "$temp" "$target"; fi
}

settings_domains() {
  printf '%s\n' com.apple.dock com.apple.finder com.apple.Terminal com.apple.desktopservices
  defaults domains 2>/dev/null | tr ',' '\n' | sed 's/^ *//' |
    grep -v -E '^(com\.apple\.|org\.apple\.|\.|$)' |
    grep -v -i -E 'runner|github|actions|homebrew|brave|sunshine|moonlight|compute-?base|hostedtoolcache|tart|vdisplay|displayplacer|blackhole|syncthing|nsc|namespace|avrea'
}

capture() {
  mkdir -p "$HANDOFF/defaults"
  if command -v brew >/dev/null 2>&1; then
    lim 90 brew tap 2>/dev/null | sort | put "$HANDOFF/brew-taps.txt"
    lim 120 brew leaves 2>/dev/null | sort | put "$HANDOFF/brew-formulae.txt"
    lim 120 brew list --cask -1 2>/dev/null | sort | put "$HANDOFF/brew-casks.txt"
  fi
  if command -v npm >/dev/null 2>&1; then
    lim 60 npm ls -g --depth=0 --parseable 2>/dev/null | tail -n +2 | sed 's#.*/node_modules/##' | sort | put "$HANDOFF/npm-global.txt"
  fi
  local domain
  while read -r domain; do
    [[ -n $domain ]] || continue
    lim 20 defaults export "$domain" - 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null | put "$HANDOFF/defaults/$domain.plist"
  done < <(settings_domains)
  local asn
  for asn in $(lim 10 lsappinfo visibleProcessList 2>/dev/null | grep -o -E 'ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+'); do
    lim 5 lsappinfo info -only bundleid "$asn" 2>/dev/null | sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p'
  done |
    grep -v -E '^(com\.apple\.(finder|dock|systemuiserver|loginwindow|notificationcenterui|controlcenter|Spotlight|systemevents|universalaccessd)|com\.brave\.|$)' |
    grep -v -i -E 'sunshine|moonlight|compute|clicker|vdisplay' | sort -u | put "$HANDOFF/apps-open.txt"
}

import_settings() {
  local file domain
  [[ -d $HANDOFF/defaults ]] || return 0
  for file in "$HANDOFF"/defaults/*.plist; do
    [[ -f $file ]] || continue
    domain=$(basename "$file" .plist)
    defaults import "$domain" "$file" 2>/dev/null || log "settings of $domain could not be restored"
  done
  killall cfprefsd 2>/dev/null || true
  killall Dock Finder 2>/dev/null || true
}

install_missing() {
  local list=$1 kind=$2 item
  [[ -s $list ]] || return 0
  while read -r item; do
    [[ -n $item ]] || continue
    if [[ $kind == cask ]]; then
      brew list --cask "$item" >/dev/null 2>&1 || { lim 900 brew install --quiet --cask --force "$item" >/dev/null 2>&1 || log "$item (cask) could not be installed"; }
    else
      brew list --formula "$item" >/dev/null 2>&1 || { lim 900 brew install --quiet "$item" >/dev/null 2>&1 || log "$item could not be installed"; }
    fi
  done <"$list"
}

apply() {
  local work=$1 item
  : >"$work/handoff-done"
  [[ -d $HANDOFF ]] || { echo "nothing-to-restore" >>"$work/handoff-done"; return 0; }
  import_settings
  echo "settings" >>"$work/handoff-done"
  sleep 60
  if command -v brew >/dev/null 2>&1; then
    while read -r item; do [[ -n $item ]] && { brew tap | grep -qx "$item" || lim 300 brew tap "$item" >/dev/null 2>&1; }; done <"$HANDOFF/brew-taps.txt" 2>/dev/null
    install_missing "$HANDOFF/brew-formulae.txt" formula
    install_missing "$HANDOFF/brew-casks.txt" cask
  fi
  if [[ -s $HANDOFF/npm-global.txt ]] && command -v npm >/dev/null 2>&1; then
    while read -r item; do
      [[ -n $item && $item != npm && $item != corepack ]] || continue
      npm ls -g --depth=0 --parseable 2>/dev/null | grep -q "/node_modules/$item\$" || lim 300 npm install -g --silent "$item" >/dev/null 2>&1 || log "npm $item could not be installed"
    done <"$HANDOFF/npm-global.txt"
  fi
  echo "installed" >>"$work/handoff-done"
  if [[ -s $HANDOFF/apps-open.txt ]]; then
    while read -r item; do [[ -n $item ]] && open -g -b "$item" >/dev/null 2>&1 || true; done <"$HANDOFF/apps-open.txt"
  fi
  echo "apps-opened" >>"$work/handoff-done"
  echo "done" >>"$work/handoff-done"
}

seed() {
  local id
  id="seed-$(date +%s)-$RANDOM"
  log "seed $id"
  sleep 60
  lim 600 brew install --quiet jq tree >/dev/null 2>&1 || log "jq/tree not installed"
  lim 900 brew install --quiet --cask rectangle >/dev/null 2>&1 || log "rectangle not installed"
  command -v npm >/dev/null 2>&1 && { lim 300 npm install -g --silent cowsay >/dev/null 2>&1 || log "cowsay not installed"; }
  mkdir -p "$HOME/.config/cb-handoff" "$HOME/Library/Application Support/Code/User/snippets" "$HOME/Documents"
  printf '{"seed":"%s","note":"app data that must follow"}\n' "$id" >"$HOME/.config/cb-handoff/state.json"
  printf '{"cb.handoff":{"prefix":"cbh","body":["%s"]}}\n' "$id" >"$HOME/Library/Application Support/Code/User/snippets/cb-handoff.code-snippets"
  printf 'export CB_HANDOFF_SEED=%s\n' "$id" >>"$HOME/.zshrc"
  printf '[user]\n\tname = Handoff Test\n\temail = handoff@example.invalid\n' >"$HOME/.gitconfig"
  printf 'a note in Documents %s\n' "$id" >"$HOME/Documents/handoff-note.txt"
  defaults write com.cbhandoff.test Marker -string "$id"
  defaults write com.apple.dock tilesize -int 41
  killall Dock 2>/dev/null || true
  open -g -a "TextEdit" >/dev/null 2>&1 || true
  log "seeded $id"
  echo "$id"
}

fingerprint() {
  local path
  cd "$HOME" || exit 1
  for path in .zshrc .zprofile .zshenv .bash_profile .bashrc .gitconfig .npmrc .ssh .config "Library/Application Support/Code/User" \
      "Library/Application Support/Google" "Library/Application Support/LM Studio" Documents; do
    [[ -e $path ]] || continue
    find "$path" -type f ! -name '.DS_Store' ! -name '.localized' ! -name authorized_keys ! -path '.config/sunshine/*' ! -path '.config/compute-base/*' ! -path '.config/syncthing/*' ! -path '.config/gh/*' -print0 2>/dev/null |
      sort -z | xargs -0 shasum -a 256 2>/dev/null | sed "s#  #  file #"
  done
  printf 'setting dock tilesize: %s\n' "$(defaults read com.apple.dock tilesize 2>/dev/null)"
  printf 'setting test marker: %s\n' "$(defaults read com.cbhandoff.test Marker 2>/dev/null)"
}

seeded() {
  local id
  id=$(seed | tail -n 1)
  capture
  fingerprint >"$HANDOFF/fingerprint-A.txt"
  {
    echo "seed $id"
    echo "formula jq"; echo "formula tree"; echo "cask rectangle"; echo "npm cowsay"
  } >"$HANDOFF/seed.txt"
  echo "$id"
}

verify() {
  local ok=1 kind item id
  [[ -s $HANDOFF/seed.txt ]] || { echo "FAIL no seed record was carried over"; return 1; }
  id=$(awk '$1 == "seed" {print $2}' "$HANDOFF/seed.txt")
  echo "seed id carried: $id"
  while read -r kind item; do
    case $kind in
      formula) if brew list --formula "$item" >/dev/null 2>&1; then echo "PASS installed formula $item"; else echo "FAIL missing formula $item"; ok=0; fi ;;
      cask) if brew list --cask "$item" >/dev/null 2>&1; then echo "PASS installed cask $item"; else echo "FAIL missing cask $item"; ok=0; fi ;;
      npm) if npm ls -g --depth=0 --parseable 2>/dev/null | grep -q "/node_modules/$item\$"; then echo "PASS installed npm $item"; else echo "FAIL missing npm $item"; ok=0; fi ;;
    esac
  done <"$HANDOFF/seed.txt"
  [[ $(defaults read com.cbhandoff.test Marker 2>/dev/null) == "$id" ]] && echo "PASS app setting (defaults) carried" || { echo "FAIL app setting differs"; ok=0; }
  [[ $(defaults read com.apple.dock tilesize 2>/dev/null) == 41 ]] && echo "PASS Dock setting carried" || { echo "FAIL Dock setting differs: $(defaults read com.apple.dock tilesize 2>/dev/null)"; ok=0; }
  grep -q "$id" "$HOME/.zshrc" 2>/dev/null && echo "PASS .zshrc carried" || { echo "FAIL .zshrc differs"; ok=0; }
  grep -q "$id" "$HOME/.config/cb-handoff/state.json" 2>/dev/null && echo "PASS app data in .config carried" || { echo "FAIL .config data differs"; ok=0; }
  grep -q "$id" "$HOME/Library/Application Support/Code/User/snippets/cb-handoff.code-snippets" 2>/dev/null && echo "PASS app data in Library/Application Support carried" || { echo "FAIL Library data differs"; ok=0; }
  grep -q "$id" "$HOME/Documents/handoff-note.txt" 2>/dev/null && echo "PASS Documents file carried" || { echo "FAIL Documents file differs"; ok=0; }
  fingerprint >"$HANDOFF/../fingerprint-B.txt" 2>/dev/null
  if [[ -f $HANDOFF/fingerprint-A.txt ]]; then
    if diff <(sort "$HANDOFF/fingerprint-A.txt") <(sort "$HANDOFF/../fingerprint-B.txt") >"$HANDOFF/../fingerprint.diff"; then
      echo "PASS every saved file and setting is identical ($(wc -l <"$HANDOFF/fingerprint-A.txt" | tr -d ' ') lines)"
    else
      echo "DIFF between the first machine and this one (< first, > this):"
      head -n 25 "$HANDOFF/../fingerprint.diff" | cut -c1-200
      ok=0
    fi
  fi
  ((ok)) && echo "RESULT PASS" || echo "RESULT FAIL"
}

case "${1:-}" in
  capture) capture ;;
  apply) apply "${2:?work dir}" ;;
  seed) seed ;;
  seeded) seeded ;;
  verify) verify ;;
  fingerprint) fingerprint ;;
  *) echo "usage: handoff-mac.sh capture|apply <work dir>|seed|seeded|verify|fingerprint" >&2; exit 2 ;;
esac
