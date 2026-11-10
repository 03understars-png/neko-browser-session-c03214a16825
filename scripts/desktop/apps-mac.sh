#!/usr/bin/env bash
set -u
work=$1
here=$(cd "$(dirname "$0")" && pwd)
exec >>"$work/apps.log" 2>&1
done_file="$work/apps-done"
: >"$done_file"
renice -n 19 $$ >/dev/null 2>&1
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
ok() { printf '%s %s\n' "$1" "${2:-}" >>"$done_file"; log "ready: $1 ${2:-}"; }
block() { awk "/<<'$1'/{f=1;next} /^$1\$/{f=0} f" "$here/10-compute-base.sh"; }
export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1
log "apps start"
brew update --quiet >/dev/null 2>&1

brew install --quiet python node git >/dev/null 2>&1
brew link --overwrite python node git >/dev/null 2>&1
prefix=$(brew --prefix)
ok python "$("$prefix/bin/python3" --version 2>&1 | cut -d' ' -f2)"
ok node "$("$prefix/bin/node" --version 2>/dev/null)"
ok git "$("$prefix/bin/git" --version | cut -d' ' -f3)"

for cask in visual-studio-code android-studio lm-studio android-commandlinetools; do
  brew install --quiet --cask --force "$cask" >/dev/null 2>&1 || log "$cask could not be installed"
done
sudo xattr -dr com.apple.quarantine "/Applications/Visual Studio Code.app" "/Applications/Android Studio.app" \
  "/Applications/Docker.app" "/Applications/LM Studio.app" 2>/dev/null

code="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
if [[ -x $code ]]; then
  user="$HOME/Library/Application Support/Code/User"
  mkdir -p "$user"
  [[ -s "$user/settings.json" ]] || block VSCODE_SETTINGS >"$user/settings.json"
  [[ -s "$user/keybindings.json" ]] || block VSCODE_KEYS >"$user/keybindings.json"
  failed=""
  while read -r ext; do
    [[ -n $ext ]] && { "$code" --install-extension "$ext" --force >/dev/null 2>&1 || failed="$failed $ext"; }
  done < <(block VSCODE_EXTENSIONS)
  ok vscode "$("$code" --version | head -1)${failed:+ (not available here:$failed)}"
fi

brew install --quiet docker docker-compose >/dev/null 2>&1 &&
  ok docker "$("$prefix/bin/docker" --version | cut -d' ' -f3 | tr -d ,) CLI (no engine on GitHub's Macs)"
[[ -d "/Applications/LM Studio.app" ]] &&
  ok lmstudio "$(defaults read "/Applications/LM Studio.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)"

if [[ -d "/Applications/Android Studio.app" ]]; then
  ok android-studio "$(defaults read "/Applications/Android Studio.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)"
  export ANDROID_HOME="$HOME/Library/Android/sdk" ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  sdk=$(command -v sdkmanager || echo "$prefix/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager")
  yes | "$sdk" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1
  "$sdk" --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-36" "build-tools;36.0.0" >/dev/null 2>&1 &&
    ok android-sdk "36 (emulator: not on GitHub's Macs, above)"
  grep -q ANDROID_HOME "$HOME/.zprofile" 2>/dev/null ||
    printf 'export ANDROID_HOME="%s"\nexport PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator"\n' "$ANDROID_HOME" >>"$HOME/.zprofile"
  launchctl setenv ANDROID_HOME "$ANDROID_HOME"
fi
if brew install --quiet --cask flutter >/dev/null 2>&1; then
  flutter=$(command -v flutter || echo "$prefix/bin/flutter")
  "$flutter" --disable-analytics >/dev/null 2>&1
  [[ -d ${ANDROID_HOME:-/nonexistent} ]] && "$flutter" config --android-sdk "$ANDROID_HOME" >/dev/null 2>&1
  ok flutter "$("$flutter" --version --machine 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
fi

sudo xcodebuild -runFirstLaunch >/dev/null 2>&1
brew install --quiet cocoapods >/dev/null 2>&1
iphone=$(xcrun simctl list devices available 2>/dev/null | grep -m1 -oE 'iPhone [0-9]+ Pro \(' | sed 's/ ($//')
[[ -n $iphone ]] && ok ios-simulator "$iphone, $(xcodebuild -version 2>/dev/null | head -1)"
log "apps done"
