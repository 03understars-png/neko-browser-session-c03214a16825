param([Parameter(Mandatory)] [string] $Work)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$log = Join-Path $Work 'agent.log'
function Log([string] $text) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $text) }
function State([string] $text) { Set-Content -Path (Join-Path $Work 'agent-state') -Value $text; Log "state: $text" }
State 'checking'
$context = 65536
$ramGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$gpuMb = 0
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) { $gpuMb = [int](& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | Select-Object -First 1) }
if ($gpuMb -ge 12000 -or ($ramGb -ge 24 -and $cores -ge 16)) { $model = 'gemma4:12b-it-qat' }
elseif ($ramGb -ge 9) { $model = 'gemma4:e4b-it-qat' }
else { State "skipped this machine has $ramGb GB; the desktop needs most of it"; exit 0 }
Log "machine: $ramGb GB, $cores cores, GPU $gpuMb MB: $model"

State 'installing Ollama'
$home_ = Join-Path $env:LOCALAPPDATA 'ollama-cb'
$ollama = Join-Path $home_ 'ollama.exe'
if (-not (Test-Path $ollama)) {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $zip = Join-Path $env:TEMP "ollama-$arch.zip"
    try {
        Invoke-WebRequest "https://github.com/ollama/ollama/releases/latest/download/ollama-windows-$arch.zip" -OutFile $zip -UseBasicParsing
        New-Item -ItemType Directory -Force $home_ | Out-Null
        Expand-Archive $zip -DestinationPath $home_ -Force
        Remove-Item $zip -Force
    } catch { State "failed Ollama did not download: $($_.Exception.Message)"; exit 1 }
}
if (-not (Test-Path $ollama)) { State 'failed Ollama is not runnable'; exit 1 }
Log "ollama: $(& $ollama --version 2>&1 | Select-Object -Last 1)"
$up = { try { Invoke-RestMethod http://127.0.0.1:11434/api/version -TimeoutSec 3 | Out-Null; $true } catch { $false } }
if (-not (& $up)) {
    foreach ($pair in @(@('OLLAMA_HOST', '127.0.0.1:11434'), @('OLLAMA_CONTEXT_LENGTH', "$context"), @('OLLAMA_FLASH_ATTENTION', '1'),
                        @('OLLAMA_KV_CACHE_TYPE', 'q8_0'), @('OLLAMA_KEEP_ALIVE', '-1'), @('OLLAMA_NUM_PARALLEL', '2'),
                        @('OLLAMA_MAX_LOADED_MODELS', '1'))) {
        [Environment]::SetEnvironmentVariable($pair[0], $pair[1], 'Process')
        [Environment]::SetEnvironmentVariable($pair[0], $pair[1], 'User')   # an Ollama started again later reads them too
    }
    $serve = Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $Work 'ollama.log') -RedirectStandardError (Join-Path $Work 'ollama-err.log')
    try { $serve.PriorityClass = 'BelowNormal' } catch { Log "ollama priority: $($_.Exception.Message)" }
    for ($i = 0; $i -lt 60 -and -not (& $up); $i++) { Start-Sleep 1 }
}
if (-not (& $up)) { State 'failed Ollama did not start'; exit 1 }

State "downloading $model"
for ($i = 0; $i -lt 3; $i++) {
    & $ollama pull $model 2>&1 | Out-File -Append -Encoding utf8 (Join-Path $Work 'ollama-pull.log')
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep 10
}
& $ollama show $model *> $null
if ($LASTEXITCODE -ne 0) { State "failed $model did not download"; exit 1 }
$threads = if ($cores -gt 2) { "`nPARAMETER num_thread $($cores - 1)" } else { '' }
Set-Content -Path (Join-Path $Work 'Modelfile') -Value "FROM $model`nPARAMETER num_ctx $context$threads"
& $ollama create cb-gemma4 -f (Join-Path $Work 'Modelfile') 2>&1 | Out-File -Append -Encoding utf8 (Join-Path $Work 'ollama-pull.log')
if ($LASTEXITCODE -ne 0) { State 'failed the model could not be set up'; exit 1 }
try {
    Invoke-RestMethod http://127.0.0.1:11434/api/generate -Method Post -TimeoutSec 600 -ContentType 'application/json' `
        -Body (@{ model = 'cb-gemma4'; prompt = ''; keep_alive = -1 } | ConvertTo-Json) | Out-Null
} catch { Log 'the model did not load yet; it loads at the first task' }

State 'installing Hermes Agent'
$findHermes = {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + $env:Path
    $found = Get-Command hermes -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $found) {
        $found = Get-ChildItem $env:LOCALAPPDATA, $env:USERPROFILE -Recurse -Depth 5 -Include 'hermes.exe', 'hermes.cmd' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    $found
}
$hermes = & $findHermes
if (-not $hermes) {
    try {
        $installer = Join-Path $env:TEMP 'hermes-install.ps1'
        Invoke-WebRequest https://hermes-agent.nousresearch.com/install.ps1 -OutFile $installer -UseBasicParsing
        $p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$installer`"", '-NonInteractive' `
            -RedirectStandardOutput (Join-Path $Work 'hermes-install.log') -RedirectStandardError (Join-Path $Work 'hermes-install-err.log')
        if (-not $p.WaitForExit(30 * 60 * 1000)) {
            Log 'hermes install: still running after 30 minutes; ended'
            & taskkill /f /t /pid $p.Id 2>&1 | Out-Null
        }
    } catch { Log "hermes install: $($_.Exception.Message)" }
    $hermes = & $findHermes
}
if (-not $hermes) { State 'failed Hermes did not install (hermes-install.log)'; exit 1 }
Log "hermes: $(& $hermes --version 2>&1 | Select-Object -First 1)"
& $hermes config set model.provider custom 2>&1 | Out-File -Append -Encoding utf8 $log
& $hermes config set model.base_url http://127.0.0.1:11434/v1 2>&1 | Out-File -Append -Encoding utf8 $log
& $hermes config set model.default cb-gemma4 2>&1 | Out-File -Append -Encoding utf8 $log
& $hermes config set model.context_length $context 2>&1 | Out-File -Append -Encoding utf8 $log
& $hermes config set approvals.mode off 2>&1 | Out-File -Append -Encoding utf8 $log
& $hermes config set auxiliary.title_generation.enabled false 2>&1 | Out-File -Append -Encoding utf8 $log
foreach ($tool in 'computer_use', 'browser', 'web', 'terminal', 'file') {
    & $hermes tools enable $tool --platform cli 2>&1 | Out-File -Append -Encoding utf8 $log
}
foreach ($tool in 'image_gen', 'tts', 'connections', 'cronjob', 'delegation', 'session_search', 'clarify', 'code_execution') {
    & $hermes tools disable $tool --platform cli 2>&1 | Out-File -Append -Encoding utf8 $log
}
& $hermes computer-use doctor 2>&1 | Out-File -Append -Encoding utf8 $log
$shell = New-Object -ComObject WScript.Shell
$powershell = (Get-Command powershell.exe).Source
foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
    $link = $shell.CreateShortcut((Join-Path $dir 'AI Agent.lnk'))
    $link.TargetPath = $powershell
    $link.Arguments = "-NoExit -NoProfile -Command `"& '$hermes'`""
    $link.WorkingDirectory = $env:USERPROFILE
    $link.IconLocation = "$powershell,0"
    $link.Save()
}
Set-Content -Path (Join-Path $Work 'agent-hermes') -Value $hermes
State "ready $model"
