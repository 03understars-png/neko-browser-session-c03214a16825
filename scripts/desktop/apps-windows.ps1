param([Parameter(Mandatory)] [string] $Work, [Parameter(Mandatory)] [string] $ProfileDir)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$done = Join-Path $Work 'apps-done'
Set-Content $done '' -Encoding ascii
Start-Transcript -Append (Join-Path $Work 'apps.log') | Out-Null
(Get-Process -Id $PID).PriorityClass = 'Idle'
function Ok($name, $version) { Add-Content $done "$name $version" -Encoding ascii; "ready: $name $version" }
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Fetch($url, $out) { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out -MaximumRedirection 10 }
'apps start'

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ';C:\ProgramData\chocolatey\bin'
}

choco upgrade -y --no-progress --limit-output python nodejs git | Out-Null
Refresh-Path
Ok python ((& python --version 2>&1) -replace 'Python ', '')
Ok node (& node --version)
Ok git ((& git --version) -replace 'git version ', '')

$vsc = Join-Path $env:TEMP 'vscode.exe'
Fetch 'https://update.code.visualstudio.com/latest/win32-x64/stable' $vsc
Start-Process $vsc -Wait -ArgumentList '/VERYSILENT', '/NORESTART', '/MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,addtopath'
$code = 'C:\Program Files\Microsoft VS Code\bin\code.cmd'
& icacls 'C:\Program Files\Microsoft VS Code' /grant '*S-1-5-32-545:(OI)(CI)M' /T /C /Q *> $null
if (Test-Path $code) {
    $user = Join-Path $env:APPDATA 'Code\User'
    New-Item -ItemType Directory -Force $user | Out-Null
    Copy-Item (Join-Path $ProfileDir 'settings.json') (Join-Path $user 'settings.json') -Force
    Copy-Item (Join-Path $ProfileDir 'keybindings.json') (Join-Path $user 'keybindings.json') -Force
    $failed = @()
    foreach ($ext in Get-Content (Join-Path $ProfileDir 'extensions.txt')) {
        if (-not $ext) { continue }
        & $code --install-extension $ext --force *> $null
        if ($LASTEXITCODE -ne 0) { $failed += $ext }
    }
    $note = if ($failed) { " (not available here: $($failed -join ' '))" } else { '' }
    Ok vscode ((& $code --version | Select-Object -First 1) + $note)
}

$lms = Join-Path $env:TEMP 'lmstudio.exe'
Fetch 'https://lmstudio.ai/download/latest/win32/x64' $lms
Start-Process $lms -Wait -ArgumentList '/S'
$lmsExe = Get-ChildItem "$env:LOCALAPPDATA\Programs", 'C:\Program Files' -Recurse -Filter 'LM Studio.exe' -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($lmsExe) { Ok lmstudio $lmsExe.VersionInfo.ProductVersion }

if (Get-Command docker -ErrorAction SilentlyContinue) {
    Ok docker ((& docker --version) + ' (Docker Engine, Windows containers)')
} else {
    choco install -y --no-progress --limit-output docker-cli docker-engine | Out-Null
    Refresh-Path
    if (Get-Command docker -ErrorAction SilentlyContinue) { Ok docker ((& docker --version) + ' (Docker Engine, Windows containers)') }
}

choco upgrade -y --no-progress --limit-output androidstudio | Out-Null
$studio = 'C:\Program Files\Android\Android Studio'
if (Test-Path "$studio\bin\studio64.exe") {
    Ok android-studio (Get-Item "$studio\bin\studio64.exe").VersionInfo.ProductVersion
    $sdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    $env:JAVA_HOME = "$studio\jbr"
    $env:ANDROID_HOME = $sdkRoot
    [Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdkRoot, 'User')
    $page = (Invoke-WebRequest -UseBasicParsing 'https://developer.android.com/studio').Content
    $tools = [regex]::Match($page, 'https://dl\.google\.com/android/repository/commandlinetools-win-[0-9]+_latest\.zip').Value
    if ($tools) {
        $zip = Join-Path $env:TEMP 'cmdline-tools.zip'
        Fetch $tools $zip
        Remove-Item -Recurse -Force "$env:TEMP\cmdline-tools", "$sdkRoot\cmdline-tools\latest" -ErrorAction SilentlyContinue
        Expand-Archive $zip $env:TEMP -Force
        New-Item -ItemType Directory -Force "$sdkRoot\cmdline-tools" | Out-Null
        Move-Item "$env:TEMP\cmdline-tools" "$sdkRoot\cmdline-tools\latest"
        $sdk = "$sdkRoot\cmdline-tools\latest\bin\sdkmanager.bat"
        $yes = Join-Path $env:TEMP 'sdk-yes.txt'
        Set-Content $yes (("y`r`n") * 60) -Encoding ascii -NoNewline
        function Sdk([string] $arguments) {
            Start-Process -Wait -NoNewWindow $sdk $arguments -RedirectStandardInput $yes `
                -RedirectStandardOutput (Join-Path $env:TEMP 'sdk-out.txt') -RedirectStandardError (Join-Path $env:TEMP 'sdk-err.txt')
        }
        Sdk '--licenses'
        $image = (& $sdk --list 2>$null | Select-String -AllMatches 'system-images;android-(\d+);google_apis;x86_64' |
            ForEach-Object { $_.Matches } | Sort-Object { [int]$_.Groups[1].Value } | Select-Object -Last 1).Value
        if ($image) {
            $api = $image.Split(';')[1]
            Sdk "`"platform-tools`" `"emulator`" `"platforms;$api`" `"$image`""
            $drive = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free } | Sort-Object Free -Descending | Select-Object -First 1
            $avdHome = "$($drive.Root)android-avd"
            New-Item -ItemType Directory -Force $avdHome | Out-Null
            $env:ANDROID_AVD_HOME = $avdHome
            [Environment]::SetEnvironmentVariable('ANDROID_AVD_HOME', $avdHome, 'User')
            'no' | & "$sdkRoot\cmdline-tools\latest\bin\avdmanager.bat" create avd --force -n Pixel -k $image -d pixel_8 *> $null
            if (Test-Path "$avdHome\Pixel.ini") {
                Ok android-emulator "$api on $avdHome"
                $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:PUBLIC\Desktop\Android Emulator (Pixel).lnk")
                $lnk.TargetPath = "$sdkRoot\emulator\emulator.exe"
                $lnk.Arguments = '-avd Pixel -no-metrics -gpu swiftshader_indirect'
                $lnk.Save()
            }
        }
    }
}
Remove-Item -Recurse -Force C:\flutter -ErrorAction SilentlyContinue
& git clone -q --depth 1 -b stable https://github.com/flutter/flutter.git C:\flutter *> $null
if (Test-Path C:\flutter\bin\flutter.bat) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike '*C:\flutter\bin*') { [Environment]::SetEnvironmentVariable('Path', "$userPath;C:\flutter\bin", 'User') }
    $env:Path += ';C:\flutter\bin'
    & flutter --disable-analytics *> $null
    if ($env:ANDROID_HOME -and (Test-Path $env:ANDROID_HOME)) { & flutter config --android-sdk $env:ANDROID_HOME *> $null }
    Ok flutter ((& flutter --version --machine 2>$null | ConvertFrom-Json).frameworkVersion)
}
'apps done'
Stop-Transcript | Out-Null
