param(
    [string]$InstallDir = "$env:LOCALAPPDATA\CockpitClaudeBridge",
    [string]$Distro = '',
    [string]$ProjectDir = '',
    [string]$ClaudeBin = '',
    [string]$CockpitExe = '',
    [string]$NodeExe = '',
    [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-RequiredPath {
    param([string]$Value, [string]$Prompt)
    while ([string]::IsNullOrWhiteSpace($Value) -or -not (Test-Path -LiteralPath $Value)) {
        $Value = Read-Host $Prompt
    }
    return (Resolve-Path -LiteralPath $Value).Path
}

function ConvertTo-ShellSingleQuoted {
    param([string]$Value)
    if ($Value.Contains("'")) {
        throw "Paths containing a single quote are not supported: $Value"
    }
    return "'$Value'"
}

$sourceRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Distro)) {
    $distros = @(& wsl.exe -l -q | ForEach-Object { ($_ -replace [char]0, '').Trim() } | Where-Object { $_ })
    if ($distros.Count -eq 0) { throw 'No WSL distribution was found.' }
    $Distro = $distros[0]
    if ($distros.Count -gt 1) {
        $selected = Read-Host "WSL distro [$Distro]"
        if ($selected) { $Distro = $selected }
    }
}

$wslHome = (& wsl.exe -d $Distro -- bash -lc 'printf %s "$HOME"').Trim()
if ([string]::IsNullOrWhiteSpace($wslHome)) { throw "Unable to resolve HOME in WSL distro $Distro." }

if ([string]::IsNullOrWhiteSpace($ClaudeBin)) {
    $ClaudeBin = (& wsl.exe -d $Distro -- bash -lc 'command -v claude || true').Trim()
    if ([string]::IsNullOrWhiteSpace($ClaudeBin)) {
        $ClaudeBin = Read-Host 'Linux path to the Claude Code binary'
    }
}

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    $ProjectDir = Read-Host "WSL project directory [$wslHome]"
    if ([string]::IsNullOrWhiteSpace($ProjectDir)) { $ProjectDir = $wslHome }
}

if ([string]::IsNullOrWhiteSpace($NodeExe)) {
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($nodeCommand) { $NodeExe = $nodeCommand.Source }
}
$NodeExe = Resolve-RequiredPath -Value $NodeExe -Prompt 'Windows path to node.exe'

if ([string]::IsNullOrWhiteSpace($CockpitExe) -and $env:COCKPIT_CLIPROXY_EXE) {
    $CockpitExe = $env:COCKPIT_CLIPROXY_EXE
}
if ([string]::IsNullOrWhiteSpace($CockpitExe)) {
    $cockpitCommand = Get-Command cockpit-cliproxy.exe -ErrorAction SilentlyContinue
    if ($cockpitCommand) { $CockpitExe = $cockpitCommand.Source }
}
$CockpitExe = Resolve-RequiredPath -Value $CockpitExe -Prompt 'Windows path to cockpit-cliproxy.exe'

$sidecarDir = Join-Path $env:USERPROFILE '.antigravity_cockpit\codex_local_access_sidecar'
$sidecarConfig = Join-Path $sidecarDir 'config.json'
$sidecarManifest = Join-Path $sidecarDir 'manifest.json'
$sidecarQuota = Join-Path $sidecarDir 'quota-reserve.json'
foreach ($required in @($sidecarConfig, $sidecarManifest, $sidecarQuota)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Cockpit sidecar file not found: $required" }
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Get-ChildItem -LiteralPath $sourceRoot -Force | Where-Object { $_.Name -notin @('.git', 'config') } |
    Copy-Item -Destination $InstallDir -Recurse -Force
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'config') | Out-Null
Copy-Item (Join-Path $sourceRoot 'config\bridge.example.json') (Join-Path $InstallDir 'config\bridge.example.json') -Force

$config = Get-Content (Join-Path $sourceRoot 'config\bridge.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$config.windows.nodeExe = $NodeExe
$config.windows.cockpitExe = $CockpitExe
$config.windows.installDir = $InstallDir
$config.windows.sidecarConfig = $sidecarConfig
$config.windows.sidecarManifest = $sidecarManifest
$config.windows.sidecarQuotaState = $sidecarQuota
$config.wsl.distro = $Distro
$config.wsl.home = $wslHome
$config.wsl.projectDir = $ProjectDir
$config.wsl.claudeBin = $ClaudeBin
$config.wsl.launcherPath = "$wslHome/.local/bin/claude-cockpit-bridge"

$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    (Join-Path $InstallDir 'config\bridge.local.json'),
    ($config | ConvertTo-Json -Depth 100),
    $encoding
)

$launcherLinuxPath = [string]$config.wsl.launcherPath
$launcherUnc = "\\wsl.localhost\$Distro\" + ($launcherLinuxPath.TrimStart('/') -replace '/', '\')
$launcherDir = Split-Path $launcherUnc
New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null

$projectQuoted = ConvertTo-ShellSingleQuoted $ProjectDir
$claudeQuoted = ConvertTo-ShellSingleQuoted $ClaudeBin
$adapterPort = [int]$config.adapter.listenPort
$launchRole = [string]$config.startup.launchModelRole
$launcherTemplate = @'
#!/usr/bin/env bash
set -euo pipefail
cd __PROJECT_DIR__
export NO_PROXY="localhost,127.0.0.1,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:__ADAPTER_PORT__/healthz >/dev/null 2>&1; then
    exec env -u ANTHROPIC_AUTH_TOKEN __CLAUDE_BIN__ --bare --model __MODEL_ROLE__
  fi
  sleep 1
done
echo "Cockpit bridge adapter on port __ADAPTER_PORT__ is not ready."
read -r -p "Press Enter to close..."
exit 1
'@
$launcher = $launcherTemplate.Replace('__PROJECT_DIR__', $projectQuoted)
$launcher = $launcher.Replace('__CLAUDE_BIN__', $claudeQuoted)
$launcher = $launcher.Replace('__ADAPTER_PORT__', [string]$adapterPort)
$launcher = $launcher.Replace('__MODEL_ROLE__', $launchRole)
$launcher = $launcher -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($launcherUnc, $launcher, $encoding)
& wsl.exe -d $Distro --exec chmod +x $launcherLinuxPath | Out-Null

if (-not $NoShortcuts) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    $targets = @(
        @{ Name = 'Claude Code - Cockpit Bridge.lnk'; Script = 'start.ps1' },
        @{ Name = 'Stop Cockpit Claude Bridge.lnk'; Script = 'stop.ps1' },
        @{ Name = 'Diagnose Cockpit Claude Bridge.lnk'; Script = 'diagnose.ps1' }
    )
    foreach ($target in $targets) {
        $shortcut = $shell.CreateShortcut((Join-Path $desktop $target.Name))
        $shortcut.TargetPath = 'powershell.exe'
        $scriptPath = Join-Path $InstallDir ("scripts\" + $target.Script)
        $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.Save()
    }
}

Write-Host "Installed to: $InstallDir"
Write-Host 'Keep CC Switch takeover/proxy mode OFF when using the direct bridge.'
Write-Host 'Run the desktop shortcut: Claude Code - Cockpit Bridge.'
