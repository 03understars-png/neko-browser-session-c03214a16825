#!/bin/bash

if [ -z "${VIEWONLY_PASSWORD:-}" ] && [ -s /run/s6/container_environment/VIEWONLY_PASSWORD ]; then
  VIEWONLY_PASSWORD=$(cat /run/s6/container_environment/VIEWONLY_PASSWORD)
fi
if [ -n "${VIEWONLY_PASSWORD:-}" ]; then
  for conf in /defaults/default.conf /etc/nginx/conf.d/*.conf /etc/nginx/sites-available/*; do
    [ -f "$conf" ] && sed -i -E '/auth_basic/d' "$conf"
  done
  nginx -s reload >/dev/null 2>&1 || true
fi

selkies_ws=$(find / -path /proc -prune -o -name websockets_mode.py -path '*selkies*' -print 2>/dev/null | head -n 1)
if [ -n "$selkies_ws" ]; then
  python3 - "$selkies_ws" <<'PY' || echo "Selkies: the shared-control change was not applied" >&2
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = "                            if client_role == 'viewer':\n                                data_logger.info(f\"Viewer {remote_address} joins the 'primary' stream.\")"
new = ("                            _cb_owner = (self.display_clients.get('primary') or {}).get('ws')\n"
       "                            _cb_join = (client_role != 'viewer' and display_id == 'primary' and _cb_owner is not None\n"
       "                                        and _cb_owner is not websocket and not _cb_owner.closed)\n"
       "                            if client_role == 'viewer' or _cb_join:\n"
       "                                data_logger.info(f\"{'Controller' if _cb_join else 'Viewer'} {remote_address} joins the 'primary' stream.\")")
if "_cb_join" in source:
    print("Selkies: shared control already on")
elif old in source:
    open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
    print("Selkies: several controllers can share the desktop")
else:
    sys.exit(1)
PY
fi

rm -f /dev/shm/audio.lock

sed -i 's/^countme=1/countme=0/' /etc/yum.repos.d/*.repo 2>/dev/null
if rpm -q plasma-discover >/dev/null 2>&1; then
  dnf remove -y -q --noautoremove plasma-discover plasma-discover-libs >/dev/null 2>&1
fi

echo 'abc ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/compute-base
chmod 0440 /etc/sudoers.d/compute-base
usermod -aG wheel abc 2>/dev/null
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-compute-base.rules <<'R'
polkit.addRule(function (action, subject) {
  if (subject.user == "abc") { return polkit.Result.YES; }
});
R

if ! command -v brave-browser >/dev/null 2>&1; then
  echo "[compute-base] installing Brave"
  curl -fsSL --retry 3 -o /etc/yum.repos.d/brave-browser.repo \
    https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo 2>/dev/null ||
    printf '[brave-browser]\nname=Brave Browser\nbaseurl=https://brave-browser-rpm-release.s3.brave.com/$basearch\nenabled=1\ngpgcheck=1\ngpgkey=https://brave-browser-rpm-release.s3.brave.com/brave-core.asc\n' \
      >/etc/yum.repos.d/brave-browser.repo
  if ! dnf install -y -q --repo brave-browser --setopt=install_weak_deps=False brave-browser; then
    echo "[compute-base] Brave needs more from Fedora; installing with every repository"
    dnf install -y -q --setopt=install_weak_deps=False brave-browser
  fi
fi

mkdir -p /etc/brave/policies/managed /etc/brave/policies/recommended
cat > /etc/brave/policies/managed/compute-base.json <<'J'
{
  "BoundSessionCredentialsEnabled": false,
  "ApplicationBoundEncryptionEnabled": false,
  "DownloadRestrictions": 0,
  "BraveRewardsDisabled": true,
  "BraveWalletDisabled": true,
  "BraveAIChatEnabled": false,
  "BraveNewsDisabled": true,
  "BraveVPNDisabled": true,
  "BraveTalkDisabled": true,
  "BravePlaylistEnabled": false,
  "BraveWaybackMachineEnabled": false,
  "TorDisabled": true,
  "BraveP3AEnabled": false,
  "BraveStatsPingEnabled": false,
  "BraveWebDiscoveryEnabled": false,
  "MetricsReportingEnabled": false,
  "UrlKeyedAnonymizedDataCollectionEnabled": false,
  "SafeBrowsingExtendedReportingEnabled": false,
  "FeedbackSurveysEnabled": false,
  "PromotionsEnabled": false,
  "DefaultBrowserSettingEnabled": true,
  "DefaultSearchProviderEnabled": true,
  "DefaultSearchProviderName": "Google",
  "DefaultSearchProviderKeyword": "google.com",
  "DefaultSearchProviderSearchURL": "https://www.google.com/search?q={searchTerms}",
  "DefaultSearchProviderSuggestURL": "https://www.google.com/complete/search?client=chrome&q={searchTerms}",
  "DefaultSearchProviderIconURL": "https://www.google.com/favicon.ico",
  "DnsOverHttpsMode": "secure",
  "DnsOverHttpsTemplates": "https://dns.adguard-dns.com/dns-query"
}
J
cat > /etc/brave/policies/recommended/compute-base.json <<'RJ'
{
  "RestoreOnStartup": 1,
  "PromptForDownloadLocation": false,
  "SpellCheckServiceEnabled": false,
  "AlternateErrorPagesEnabled": false,
  "BackgroundModeEnabled": false,
  "NetworkPredictionOptions": 2
}
RJ

cat > /etc/brave/compute-base-extensions.list <<'X'
bgnkhhnnamicmpeenaelnjfhikgbkllg AdGuard AdBlocker
gkeojjjcdcopjkbelgbcpckplegclfeg AdGuard Extra
ehllkhjndgnlokhomdlhgbineffifcbj Always active Window - Always Visible
hehggadaopoacecdllhhajmbjkdcmajg ChatGPT
eimadpbcbfnmbkopoojfekhnkhdbieeh Dark Reader
geplbbbmdpmdodfmohpikfacgkfpkhec Email Finder by Skrapp.io
mlloloooolpffjkjaclpfpeednngpjon Enable right click - allow copy & select
bnjjngeaknajbdcgpfkgnonkmififhfo Fake Filler
fnaicdffflnofjppbagibeoednhnbjhg floccus bookmarks sync
hnmpcagpplmpfojmgmnngilcnanddlhb Windscribe
akimgimeeoiognljlfchpbkpfbmeapkh Google Arts & Culture
ghbmnnjooekpmoecnnnilnnbdlolhkhi Google Docs Offline
lpcaedmchfhocbbapmcbpinfpgnhiddi Google Keep
iklnnbgdcppplombffihcijanngoeifm Google Vids Screen Recorder
fihnjjcciajhdojfnbdddfaoknhalnja I don't care about cookies
bcjindcccaagfpapjjmafapmmgkkhgoa JSON Formatter
fheoggkfdfchfphceeifdbepaooicaho McAfee WebAdvisor
gbkeegbaiigmenfmjfclcdgdpimamgkj Office Editing for Docs, Sheets & Slides
iodihamcpbpeioajjeobimgagajmlibd Secure Shell
mbnnmpmcijodolgeejegcijdamonganh Select like a Boss
abocjojdmemdpiffeadpdnicnlhcndcg SocialFocus
mnjggcdmjocbbbhaepdhchncahnbgone SponsorBlock for YouTube
X
cat > /usr/local/bin/compute-base-extensions <<'EXT'
#!/bin/bash
mode=$1 profile=$2 out=$3 list=${4:-/etc/brave/compute-base-extensions.list}
entries=""
while read -r id _; do
  [[ $id =~ ^[a-p]{32}$ ]] || continue
  [[ $mode == all || -d "$profile/Default/Extensions/$id" ]] || continue
  entries="$entries${entries:+,}\"$id\":{\"installation_mode\":\"${EXTENSION_MODE:-normal_installed}\",\"update_url\":\"https://clients2.google.com/service/update2/crx\"}"
done <"$list"
if [[ -z $entries ]]; then rm -f "$out"; exit 0; fi
printf '{"ExtensionSettings":{%s}}\n' "$entries" >"$out.tmp" && mv -f "$out.tmp" "$out"
EXT
chmod 0755 /usr/local/bin/compute-base-extensions
/usr/local/bin/compute-base-extensions boot /config/.config/BraveSoftware/Brave-Browser \
  /etc/brave/policies/managed/compute-base-extensions.json

cat > /usr/local/bin/compute-base-quiet-tabs <<'QT'
import json, re, sys, time, urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9333
SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 900
LIST = sys.argv[3] if len(sys.argv) > 3 else "/etc/brave/compute-base-extensions.list"
ONBOARDING = re.compile(r"^https://(welcome\.adguard\.com/|adguard\.com/[a-z-]*/?(welcome|thankyou)|darkreader\.org/help/"
                        r"|app\.skrapp\.io/signup\?case=extension-installed"
                        r"|chatgpt\.com/auth/login\?next=(%2F|/)work(%2F|/)extension(%2F|/)installed"
                        r"|chatgpt\.com/work/extension/installed)")
try:
    EXTENSIONS = {line.split()[0] for line in open(LIST, encoding="utf-8") if re.match(r"^[a-p]{32}\b", line)}
except OSError:
    EXTENSIONS = set()

def call(path, method="GET"):
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", method=method)
    with urllib.request.urlopen(request, timeout=10) as reply:
        body = reply.read()
    return json.loads(body) if body[:1] in (b"[", b"{") else body

def pages():
    return [t for t in call("/json/list") if t.get("type") == "page"]

def onboarding(url):
    if ONBOARDING.match(url):
        return True
    found = re.match(r"^chrome-extension://([a-p]{32})/", url)
    return bool(found and found.group(1) in EXTENSIONS)

def main():
    deadline = time.time() + SECONDS
    kept = None
    while time.time() < deadline:
        try:
            now = pages()
        except Exception:  # Brave not open yet, or restarting
            time.sleep(3)
            continue
        if kept is None:
            kept = {t["id"] for t in now if not ONBOARDING.match(t.get("url", ""))}
        for tab in now:
            if tab["id"] in kept or not onboarding(tab.get("url", "")):
                continue
            try:
                if len(pages()) <= 1:  # never the last tab: that closes the window
                    call("/json/new?chrome://newtab/", "PUT")
                call(f"/json/close/{tab['id']}")
                print("closed", tab.get("url", "")[:120], flush=True)
            except Exception as error:  # noqa: BLE001
                print("could not close", tab.get("url", "")[:80], error, flush=True)
            kept.add(tab["id"])
        time.sleep(2)

if __name__ == "__main__":
    main()
QT
chmod 0755 /usr/local/bin/compute-base-quiet-tabs

rm -f /etc/brave/policies/managed/compute-base-bookmarks.json
if [ -s /config/.config/compute-base/bookmarks-policy.json ] && [ -f /config/.config/compute-base/bookmarks-bar.py ]; then
  profile=/config/.config/BraveSoftware/Brave-Browser/Default
  "$(command -v python3 || echo /lsiopy/bin/python3)" /config/.config/compute-base/bookmarks-bar.py "$profile" \
    /config/.config/compute-base/bookmarks-policy.json || echo "bookmarks: not put on the bar" >&2
  chown "$(stat -c %u:%g /config)" /config/.config/BraveSoftware /config/.config/BraveSoftware/Brave-Browser \
    "$profile" "$profile/Bookmarks" 2>/dev/null || true
fi

mkdir -p /etc/compute-base/vscode
cat > /etc/compute-base/vscode/settings.json <<'VSCODE_SETTINGS'
{
    "[css]": {
        "editor.defaultFormatter": "vscode.css-language-features"
    },
    "[html]": {
        "editor.defaultFormatter": "vscode.html-language-features"
    },
    "[javascript]": {
        "editor.defaultFormatter": "vscode.typescript-language-features"
    },
    "[javascriptreact]": {
        "editor.defaultFormatter": "vscode.typescript-language-features"
    },
    "[json]": {
        "editor.defaultFormatter": "vscode.json-language-features"
    },
    "[jsonc]": {
        "editor.defaultFormatter": "vscode.json-language-features"
    },
    "[python]": {
        "editor.defaultFormatter": "charliermarsh.ruff"
    },
    "[typescript]": {
        "editor.defaultFormatter": "vscode.typescript-language-features"
    },
    "aws.telemetry": false,
    "background.autoInstall": true,
    "background.editorBackgrounds": [],
    "background.smoothImageRendering": true,
    "background.windowBackgrounds": [
        "https://images.unsplash.com/photo-1669780080364-515ad92d9911?q=80&w=2670&auto=format&fit=crop&ixlib=rb-4.0.3&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D"
    ],
    "chat.agent.maxRequests": 100,
    "chat.editing.confirmEditRequestRemoval": false,
    "chat.editing.confirmEditRequestRetry": false,
    "chat.editor.fontSize": 13,
    "chat.editor.wordWrap": "on",
    "claudeCode.hideOnboarding": true,
    "claudeCode.preferredLocation": "panel",
    "dart.debugExternalPackageLibraries": true,
    "dart.debugSdkLibraries": true,
    "dart.hotReloadProgress": "statusBar",
    "dart.normalizeFileCasing": true,
    "database-client.telemetry.usesOnlineServices": false,
    "debug.console.fontSize": 13,
    "debug.terminal.clearBeforeReusing": true,
    "diffEditor.codeLens": true,
    "diffEditor.ignoreTrimWhitespace": true,
    "diffEditor.maxComputationTime": 0,
    "docker.extension.dockerEngineAvailabilityPrompt": false,
    "docker.lsp.telemetry": "off",
    "editor.acceptSuggestionOnEnter": "smart",
    "editor.bracketPairColorization.enabled": true,
    "editor.cursorBlinking": "expand",
    "editor.cursorSmoothCaretAnimation": "on",
    "editor.cursorWidth": 5,
    "editor.detectIndentation": true,
    "editor.fontFamily": "Cascadia code",
    "editor.fontLigatures": true,
    "editor.fontSize": 13,
    "editor.fontWeight": "400",
    "editor.formatOnPaste": true,
    "editor.formatOnSave": true,
    "editor.formatOnType": true,
    "editor.hover.enabled": "on",
    "editor.inlayHints.padding": true,
    "editor.inlineSuggest.enabled": true,
    "editor.insertSpaces": true,
    "editor.letterSpacing": 0.5,
    "editor.lineHeight": 25,
    "editor.linkedEditing": true,
    "editor.minimap.enabled": false,
    "editor.pasteAs.preferences": [
        "text.updateImports"
    ],
    "editor.quickSuggestions": {
        "strings": "inline"
    },
    "editor.renderWhitespace": "trailing",
    "editor.smoothScrolling": true,
    "editor.snippetSuggestions": "top",
    "editor.suggest.preview": true,
    "editor.suggest.showDeprecated": false,
    "editor.tabCompletion": "on",
    "editor.wordWrap": "on",
    "editor.wrappingStrategy": "advanced",
    "emmet.includeLanguages": {
        "javascript": "javascriptreact"
    },
    "emmet.useInlineCompletions": true,
    "explorer.confirmDelete": false,
    "explorer.confirmDragAndDrop": false,
    "explorer.confirmPasteNative": false,
    "explorer.decorations.badges": false,
    "explorer.fileNesting.enabled": true,
    "explorer.incrementalNaming": "disabled",
    "explorer.openEditors.sortOrder": "alphabetical",
    "extensions.closeExtensionDetailsOnViewChange": true,
    "extensions.ignoreRecommendations": true,
    "files.autoSave": "afterDelay",
    "files.autoSaveWhenNoErrors": true,
    "files.exclude": {
        "/package-lock.json": true
    },
    "files.insertFinalNewline": true,
    "files.trimFinalNewlines": true,
    "files.trimTrailingWhitespace": true,
    "files.watcherExclude": {
        "**/__pycache__/**": true,
        "**/.dart_tool/**": true,
        "**/.gradle/**": true,
        "**/build/**": true,
        "**/node_modules/**": true
    },
    "git.autofetch": true,
    "git.confirmSync": false,
    "git.enableSmartCommit": true,
    "git.mergeEditor": true,
    "git.openRepositoryInParentFolders": "never",
    "git.postCommitCommand": "sync",
    "git.terminalGitEditor": true,
    "github.copilot.enable": {
        "*": true
    },
    "github.copilot.nextEditSuggestions.enabled": true,
    "html.autoClosingTags": true,
    "html.format.indentHandlebars": true,
    "html.format.indentInnerHtml": true,
    "http.systemCertificatesNode": true,
    "js/ts.autoClosingTags.enabled": true,
    "js/ts.format.semicolons": "insert",
    "js/ts.implicitProjectConfig.strict": false,
    "js/ts.implicitProjectConfig.strictFunctionTypes": false,
    "js/ts.implicitProjectConfig.strictNullChecks": false,
    "js/ts.inlayHints.enumMemberValues.enabled": true,
    "js/ts.inlayHints.functionLikeReturnTypes.enabled": true,
    "js/ts.inlayHints.parameterNames.enabled": "all",
    "js/ts.inlayHints.parameterNames.suppressWhenArgumentMatchesName": false,
    "js/ts.inlayHints.propertyDeclarationTypes.enabled": true,
    "js/ts.inlayHints.variableTypes.enabled": true,
    "js/ts.inlayHints.variableTypes.suppressWhenTypeMatchesName": false,
    "js/ts.reportStyleChecksAsWarnings": false,
    "js/ts.suggest.autoImports": true,
    "js/ts.suggest.completeFunctionCalls": true,
    "js/ts.updateImportsOnFileMove.enabled": "always",
    "markdown.preview.fontSize": 13,
    "markdown.updateLinksOnFileMove.enabled": "always",
    "material-icon-theme.activeIconPack": "react",
    "mediaPreview.video.autoPlay": true,
    "mediaPreview.video.loop": true,
    "merge-conflict.autoNavigateNextConflict.enabled": true,
    "notebook.defaultFormatter": "charliermarsh.ruff",
    "notebook.formatOnSave.enabled": true,
    "notebook.output.wordWrap": true,
    "postman.mcp.notifications.postmanMCP": false,
    "postman.telemetry.enabled": false,
    "python.terminal.activateEnvInCurrentTerminal": true,
    "python.terminal.focusAfterLaunch": true,
    "remote.tunnels.access.preventSleep": true,
    "scm.workingSets.enabled": true,
    "screencastMode.fontSize": 25,
    "screencastMode.mouseIndicatorColor": "#FF0",
    "screencastMode.verticalOffset": 3,
    "search.quickAccess.preserveInput": true,
    "search.quickOpen.includeHistory": false,
    "search.smartCase": true,
    "security.workspace.trust.untrustedFiles": "open",
    "settingsSync.ignoredSettings": [
        "-window.zoomLevel",
        "-workbench.welcomePage.walkthroughs.openOnInstall",
        "-python.createEnvironment.trigger",
        "-sonarlint.focusOnNewCode"
    ],
    "sonarlint.automaticAnalysis": false,
    "sonarlint.disableTelemetry": true,
    "telemetry.editStats.enabled": false,
    "telemetry.feedback.enabled": false,
    "telemetry.telemetryLevel": "off",
    "terminal.integrated.confirmOnExit": "hasChildProcesses",
    "terminal.integrated.confirmOnKill": "always",
    "terminal.integrated.copyOnSelection": true,
    "terminal.integrated.cursorBlinking": true,
    "terminal.integrated.cursorStyle": "line",
    "terminal.integrated.cursorWidth": 5,
    "terminal.integrated.defaultProfile.linux": "fish",
    "terminal.integrated.defaultProfile.windows": "PowerShell",
    "terminal.integrated.enableImages": true,
    "terminal.integrated.enableMultiLinePasteWarning": "never",
    "terminal.integrated.fontSize": 13,
    "terminal.integrated.fontWeight": "normal",
    "terminal.integrated.gpuAcceleration": "on",
    "terminal.integrated.hideOnStartup": "whenEmpty",
    "terminal.integrated.letterSpacing": 0.5,
    "terminal.integrated.lineHeight": 1.4,
    "terminal.integrated.shellIntegration.enabled": true,
    "terminal.integrated.smoothScrolling": true,
    "terminal.integrated.tabs.defaultColor": "terminal.ansiMagenta",
    "timeline.pageOnScroll": true,
    "ty.diagnosticMode": "workspace",
    "vscode-office.editorTheme": "Auto",
    "vscode-office.enableTelemetry": false,
    "window.dialogStyle": "custom",
    "window.doubleClickIconToClose": true,
    "window.menuBarVisibility": "compact",
    "window.newWindowDimensions": "fullscreen",
    "window.newWindowProfile": "Default",
    "window.openFoldersInNewWindow": "on",
    "window.restoreFullscreen": true,
    "window.systemColorTheme": "dark",
    "window.titleBarStyle": "custom",
    "window.zoomPerWindow": false,
    "workbench.colorTheme": "Dark Modern",
    "workbench.commandPalette.history": 0,
    "workbench.commandPalette.preserveInput": true,
    "workbench.editor.closeOnFileDelete": true,
    "workbench.editor.empty.hint": "hidden",
    "workbench.editor.enablePreview": false,
    "workbench.editor.enablePreviewFromCodeNavigation": true,
    "workbench.editor.wrapTabs": true,
    "workbench.editorAssociations": {
        "*.png": "imagePreview.previewEditor"
    },
    "workbench.iconTheme": "material-icon-theme",
    "workbench.layoutControl.enabled": false,
    "workbench.list.smoothScrolling": true,
    "workbench.preferredDarkColorTheme": "Dark Modern",
    "workbench.preferredLightColorTheme": "Quiet Light",
    "workbench.quickOpen.preserveInput": true,
    "workbench.reduceMotion": "off",
    "workbench.secondarySideBar.defaultVisibility": "hidden",
    "workbench.sideBar.location": "right",
    "workbench.startupEditor": "none",
    "zenMode.centerLayout": false,
    "zenMode.hideLineNumbers": false
}
VSCODE_SETTINGS
cat > /etc/compute-base/vscode/keybindings.json <<'VSCODE_KEYS'
[
    {
        "command": "-aws.amazonq.inline.invokeChat",
        "key": "ctrl+i",
        "when": "aws.codewhisperer.connected && editorTextFocus"
    },
    {
        "command": "-copyRelativeFilePath",
        "key": "ctrl+k ctrl+shift+c",
        "when": "editorFocus"
    },
    {
        "command": "-geminicodeassist.generateCode",
        "key": "ctrl+enter",
        "when": "authLoggedIn && config.geminicodeassist.enable && editorTextFocus && !inGeminiDiffView && !isInDiffEditor"
    },
    {
        "command": "-geminicodeassist.showinEditor",
        "key": "ctrl+i",
        "when": "authLoggedIn && config.geminicodeassist.enable && editorTextFocus && shouldRegisterInEditorCommand && !inGeminiDiffView && !isInDiffEditor"
    },
    {
        "command": "-github.copilot.generate",
        "key": "ctrl+enter",
        "when": "editorTextFocus && github.copilot.activated && !commentEditorFocused && !inInteractiveInput && !interactiveEditorFocused"
    },
    {
        "command": "-github.copilot.generate",
        "key": "ctrl+enter",
        "when": "editorTextFocus && github.copilot.activated && !inInteractiveInput && !interactiveEditorFocused"
    },
    {
        "command": "-workbench.action.quickchat.toggle",
        "key": "ctrl+shift+alt+l",
        "when": "chatIsEnabled"
    },
    {
        "command": "copyRelativeFilePath",
        "key": "ctrl+shift+r",
        "when": "editorFocus"
    },
    {
        "command": "explorer.newFile",
        "key": "ctrl+n"
    },
    {
        "command": "workbench.action.chat.openInEditor",
        "key": "ctrl+shift+o"
    },
    {
        "command": "workbench.action.clearRecentFiles",
        "key": "ctrl+shift+c"
    },
    {
        "command": "workbench.action.closeOtherEditors",
        "key": "alt+k alt+o"
    },
    {
        "command": "workbench.action.nextEditor",
        "key": "ctrl+tab"
    },
    {
        "command": "workbench.action.previousEditor",
        "key": "ctrl+shift+tab"
    },
    {
        "command": "workbench.action.quickchat.toggle",
        "key": "ctrl+q",
        "when": "chatIsEnabled"
    },
    {
        "command": "workbench.action.terminal.clear",
        "key": "ctrl+t"
    },
    {
        "command": "workbench.action.terminal.kill",
        "key": "ctrl+shift+q"
    },
    {
        "command": "workbench.action.toggleLightDarkThemes",
        "key": "ctrl+shift+t"
    },
    {
        "command": "-continue.focusContinueInputWithoutClear",
        "key": "ctrl+shift+l"
    },
    {
        "command": "-continue.focusContinueInput",
        "key": "ctrl+l"
    },
    {
        "command": "github.copilot.chat.completions.toggle",
        "key": "ctrl+shift+s"
    },
    {
        "key": "ctrl+l",
        "command": "-antigravity.insertSnippet",
        "when": "editorTextFocus"
    },
]
VSCODE_KEYS
cat > /etc/compute-base/vscode/extensions.txt <<'VSCODE_EXTENSIONS'
amazonwebservices.aws-toolkit-vscode
anthropic.claude-code
astral-sh.ty
charliermarsh.ruff
cweijan.dbclient-jdbc
cweijan.vscode-database-client2
cweijan.vscode-office
dart-code.dart-code
dart-code.flutter
docker.docker
google.colab
google.google-antigravity
katsute.code-background
localstack.localstack
ms-azuretools.vscode-containers
ms-azuretools.vscode-docker
ms-python.debugpy
ms-python.python
ms-toolsai.datawrangler
ms-toolsai.jupyter
ms-vscode.hexeditor
ms-vsliveshare.vsliveshare
nonoroazoro.syncing
openai.chatgpt
openai.codex-audio
opentofu.vscode-opentofu
pkief.material-icon-theme
postman.postman-for-vscode
sonarsource.sonarlint-vscode
VSCODE_EXTENSIONS
cat > /usr/local/bin/compute-base-apps <<'APPS'
#!/bin/bash
exec >>/var/log/compute-base-apps.log 2>&1
set -u
DONE=/var/lib/compute-base-apps/done
mkdir -p "${DONE%/*}" /opt
: >"$DONE"
renice -n 19 $$ >/dev/null 2>&1; ionice -c3 -p $$ >/dev/null 2>&1
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
ok() { printf '%s %s\n' "$1" "${2:-}" >>"$DONE"; log "ready: $1 ${2:-}"; }
as_user() { s6-setuidgid abc env HOME=/config USER=abc PATH=/usr/local/bin:/usr/bin:/bin "$@"; }
fetch() { curl -fsSL --retry 4 --retry-delay 5 "$@"; }
arch=$(uname -m)                     # x86_64 or aarch64
narch=$([[ $arch == aarch64 ]] && echo arm64 || echo x64)
log "apps start ($arch)"
light=""; [[ -f /etc/brave/policies/managed/compute-base-no-sandbox.json ]] && light=1

dnf install -y -q python3 python3-pip python-unversioned-command git unzip xz \
  pulseaudio-libs libXcomposite libXcursor libXi libXtst nss mesa-libGL >/dev/null &&
  ok python "$(python3 --version 2>&1 | cut -d' ' -f2)" && ok git "$(git --version | cut -d' ' -f3)"

ver=$(fetch https://nodejs.org/dist/index.json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["version"])') &&
  fetch "https://nodejs.org/dist/$ver/node-$ver-linux-$narch.tar.xz" | tar -xJ -C /usr/local --strip-components=1 \
    --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md &&
  ok node "$ver"

rpm --import https://packages.microsoft.com/keys/microsoft.asc
printf '[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
  >/etc/yum.repos.d/vscode.repo
if dnf install -y -q code >/dev/null; then
  chown -R 1000:1000 /usr/share/code
  install -d -o 1000 -g 1000 /config/.config/Code /config/.config/Code/User
  install -m 0644 -o 1000 -g 1000 /etc/compute-base/vscode/settings.json /config/.config/Code/User/settings.json
  install -m 0644 -o 1000 -g 1000 /etc/compute-base/vscode/keybindings.json /config/.config/Code/User/keybindings.json
  [[ ${COMPUTE_BASE_NO_SANDBOX:-} == 1 || -f /etc/brave/policies/managed/compute-base-no-sandbox.json ]] &&
    sed -i 's#^Exec=/usr/share/code/code #Exec=/usr/share/code/code --no-sandbox #' /usr/share/applications/code*.desktop
  failed=""
  while read -r ext; do
    [[ -n $ext ]] || continue
    as_user code --install-extension "$ext" --force >/dev/null 2>&1 || failed="$failed $ext"
  done </etc/compute-base/vscode/extensions.txt
  ok vscode "$(code --version --user-data-dir /tmp/code-version 2>/dev/null | head -1)${failed:+ (not available here:$failed)}"
fi

if [[ -z $light ]]; then
dver=$(fetch "https://download.docker.com/linux/static/stable/$arch/" | grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' | sort -V | tail -1)
if [[ -n $dver ]] && fetch "https://download.docker.com/linux/static/stable/$arch/$dver" | tar -xz -C /usr/local/bin --strip-components=1 docker/docker; then
  mkdir -p /usr/local/lib/docker/cli-plugins
  fetch -o /usr/local/lib/docker/cli-plugins/docker-compose \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch" &&
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose
  if [[ -S /var/run/docker.sock ]]; then
    gid=$(stat -c %g /var/run/docker.sock)
    getent group "$gid" >/dev/null || groupadd -g "$gid" docker-host
    usermod -aG "$(getent group "$gid" | cut -d: -f1)" abc
    ok docker "${dver%.tgz} with this machine's Docker Engine"
  else
    ok docker "${dver%.tgz} (no Docker Engine here)"
  fi
fi

if fetch -o /tmp/lmstudio.AppImage "https://lmstudio.ai/download/latest/linux/$narch"; then
  chmod +x /tmp/lmstudio.AppImage
  rm -rf /opt/lm-studio && mkdir -p /opt/lm-studio
  (cd /opt/lm-studio && /tmp/lmstudio.AppImage --appimage-extract >/dev/null) && rm -f /tmp/lmstudio.AppImage
  if [[ -x /opt/lm-studio/squashfs-root/AppRun ]]; then
    chmod -R a+rX /opt/lm-studio
    printf '[Desktop Entry]\nType=Application\nName=LM Studio\nExec=/opt/lm-studio/squashfs-root/AppRun --no-sandbox %%U\nIcon=/opt/lm-studio/squashfs-root/lm-studio.png\nCategories=Development;\n' \
      >/usr/share/applications/lm-studio.desktop
    ok lmstudio "$(grep -m1 -oE '"version": *"[^"]+"' /opt/lm-studio/squashfs-root/resources/app/package.json 2>/dev/null | cut -d'"' -f4)"
  fi
fi

if [[ $arch == x86_64 ]]; then
  page=$(fetch https://developer.android.com/studio)
  studio=$(grep -oE 'https://[a-z0-9./_-]+android-studio-[a-z0-9.]+-linux\.tar\.gz' <<<"$page" | head -1)
  tools=$(grep -oE 'https://dl\.google\.com/android/repository/commandlinetools-linux-[0-9]+_latest\.zip' <<<"$page" | head -1)
  if [[ -n $studio ]] && fetch "$studio" | tar -xz -C /opt; then
    grep -q disable.android.first.run /opt/android-studio/bin/idea.properties ||
      echo 'disable.android.first.run=true' >>/opt/android-studio/bin/idea.properties
    export JAVA_HOME=/opt/android-studio/jbr ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_AVD_HOME=/opt/android-avd
    printf 'export ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_AVD_HOME=/opt/android-avd\nexport PATH="$PATH:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:/opt/android-sdk/cmdline-tools/latest/bin"\n' \
      >/etc/profile.d/android.sh
    env_line="env ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_AVD_HOME=/opt/android-avd"
    launcher=/opt/android-studio/bin/studio; [[ -x $launcher ]] || launcher=/opt/android-studio/bin/studio.sh
    printf '[Desktop Entry]\nType=Application\nName=Android Studio\nExec=%s %s\nIcon=/opt/android-studio/bin/studio.png\nCategories=Development;IDE;\n' \
      "$env_line" "$launcher" >/usr/share/applications/android-studio.desktop
    ok android-studio "$(grep -oE 'android-studio-[0-9.]+' <<<"$studio" | head -1 | cut -d- -f3)"
    if [[ -n $tools ]] && fetch -o /tmp/cmdline-tools.zip "$tools"; then
      mkdir -p /opt/android-sdk/cmdline-tools && rm -rf /opt/android-sdk/cmdline-tools/latest
      unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools && mv /tmp/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest
      rm -rf /tmp/cmdline-tools /tmp/cmdline-tools.zip
      sdk=/opt/android-sdk/cmdline-tools/latest/bin/sdkmanager
      yes | "$sdk" --licenses >/dev/null 2>&1
      image=$("$sdk" --list 2>/dev/null | grep -oE 'system-images;android-[0-9]+;google_apis;x86_64' | sort -t- -k2 -n | tail -1)
      api=$(cut -d';' -f2 <<<"$image")
      if [[ -n $image ]] && "$sdk" "platform-tools" "emulator" "platforms;$api" "$image" >/dev/null; then
        mkdir -p /opt/android-avd
        echo no | /opt/android-sdk/cmdline-tools/latest/bin/avdmanager create avd --force -n Pixel -k "$image" -d pixel_8 >/dev/null
        [[ -e /dev/kvm ]] && chmod 0666 /dev/kvm
        printf '[Desktop Entry]\nType=Application\nName=Android Emulator (Pixel)\nExec=%s /opt/android-sdk/emulator/emulator -avd Pixel -gpu swiftshader_indirect\nIcon=/opt/android-studio/bin/studio.png\nCategories=Development;\n' \
          "$env_line" >/usr/share/applications/android-emulator.desktop
        chown -R 1000:1000 /opt/android-sdk /opt/android-avd
        ok android-emulator "$api $( [[ -r /dev/kvm ]] && echo 'with KVM' || echo '(no KVM here: very slow)')"
      fi
    fi
  fi
else
  log "Android Studio: Google has no Linux build for $arch"
fi

else
  log "Kaggle: Docker, LM Studio and Android Studio are skipped here"
fi

dnf install -y -q clang cmake ninja-build gtk3-devel pkgconf-pkg-config which >/dev/null
rm -rf /opt/flutter
if git clone -q --depth 1 -b stable https://github.com/flutter/flutter.git /opt/flutter; then
  chown -R 1000:1000 /opt/flutter
  ln -sf /opt/flutter/bin/flutter /usr/local/bin/flutter
  ln -sf /opt/flutter/bin/dart /usr/local/bin/dart
  as_user flutter --disable-analytics >/dev/null 2>&1
  [[ -d /opt/android-sdk ]] && as_user flutter config --android-sdk /opt/android-sdk >/dev/null 2>&1
  ok flutter "$(as_user flutter --version --machine 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
fi
update-desktop-database /usr/share/applications >/dev/null 2>&1
log "apps done"
APPS
chmod 0755 /usr/local/bin/compute-base-apps

rm -f /config/.config/BraveSoftware/Brave-Browser/Singleton{Lock,Cookie,Socket}
"$(command -v python3 || echo /lsiopy/bin/python3)" - /config/.config/BraveSoftware/Brave-Browser <<'PY' || echo "Brave: welcome page not marked seen" >&2
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
chown -R "$(stat -c %u:%g /config)" /config/.config/BraveSoftware 2>/dev/null || true

C=/config/.config
mkdir -p "$C/autostart"
kw() { kwriteconfig6 --file "$C/$1" --group "$2" --key "$3" "$4"; }
kw kdeglobals KDE AnimationDurationFactor 0
kw kwinrc Plugins blurEnabled false
kw kwinrc Plugins contrastEnabled false
kw kwinrc Plugins slidingpopupsEnabled false
kw kwinrc Plugins kwin4_effect_translucencyEnabled false
kw kwinrc Compositing AnimationSpeed 0
kw baloofilerc "Basic Settings" "Indexing-Enabled" false
kw PlasmaUserFeedback Global FeedbackLevel 0
kw kactivitymanagerd-pluginsrc Plugin-org.kde.ActivityManager.Resources.Scoring what-to-remember 2
kw kwalletrc Wallet Enabled false
kw kwalletrc Wallet "First Use" false
kw kdeglobals KDE LookAndFeelPackage org.kde.breezedark.desktop
kw kdeglobals General ColorScheme BreezeDark
kw gtk-3.0/settings.ini Settings gtk-application-prefer-dark-theme true
kw kdeglobals General BrowserApplication brave-browser.desktop
for t in x-scheme-handler/http x-scheme-handler/https text/html; do
  kw mimeapps.list "Default Applications" "$t" brave-browser.desktop
done
for a in org.kde.discover.notifier org.kde.kdeconnect.daemon baloo_file org.kde.plasma-welcome geoclue-demo-agent; do
  printf "[Desktop Entry]\nHidden=true\n" > "$C/autostart/$a.desktop"
done
chown -R 1000:1000 "$C"

BF="--password-store=basic --force-dark-mode --no-first-run --hide-crash-restore-bubble"
BF="$BF --remote-debugging-port=9333 --remote-debugging-address=127.0.0.1"
if [ "${COMPUTE_BASE_NO_SANDBOX:-}" = 1 ]; then
  BF="$BF --no-sandbox"
  printf '{"CommandLineFlagSecurityWarningsEnabled": false}
' > /etc/brave/policies/managed/compute-base-no-sandbox.json
else
  rm -f /etc/brave/policies/managed/compute-base-no-sandbox.json
fi
A=/config/.local/share/applications
mkdir -p "$A"
if [ -f /usr/share/applications/brave-browser.desktop ]; then
  sed -E "s#^Exec=/usr/bin/brave-browser-stable#Exec=/usr/bin/brave-browser-stable $BF#" /usr/share/applications/brave-browser.desktop > "$A/brave-browser.desktop"
fi
cat > "$C/compute-base-session.sh" <<'SESSION'
#!/bin/bash
for _ in $(seq 1 60); do
  qdbus6 org.kde.plasmashell /PlasmaShell >/dev/null 2>&1 && break
  sleep 1
done
plasma-apply-lookandfeel -a org.kde.breezedark.desktop >/dev/null 2>&1
plasma-apply-colorscheme BreezeDark >/dev/null 2>&1
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
  panels().forEach(function (panel) {
    panel.widgets("org.kde.plasma.icontasks").concat(panel.widgets("org.kde.plasma.taskmanager"))
      .forEach(function (tasks) {
        tasks.currentConfigGroup = ["General"];
        tasks.writeConfig("launchers", ["applications:systemsettings.desktop",
          "preferred://filemanager", "applications:brave-browser.desktop"]);
      });
  });' >/dev/null 2>&1
sync_dir=/config/.config/compute-base
if [ -f "$sync_dir/brave-sync.py" ]; then
  py=$(command -v python3 || echo /lsiopy/bin/python3)
  ( sleep 4; "$py" "$sync_dir/brave-sync.py" 9333 "$sync_dir/brave-sync-code" >"$sync_dir/brave-sync.log" 2>&1 ) &
fi
pgrep -x brave >/dev/null || exec /usr/bin/brave-browser-stable BRAVE_FLAGS
SESSION
sed -i "s#BRAVE_FLAGS#$BF#" "$C/compute-base-session.sh"
chmod 0755 "$C/compute-base-session.sh"
rm -f "$C/autostart/compute-base-brave.desktop" "$C/autostart/compute-base-session.desktop"
chown -R 1000:1000 /config/.local "$C/autostart" "$C/compute-base-session.sh"
