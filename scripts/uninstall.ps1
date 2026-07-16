param([switch]$RestoreClaudeSettings)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$config = Read-BridgeConfig
& (Join-Path $PSScriptRoot 'stop.ps1')

$desktop = [Environment]::GetFolderPath('Desktop')
foreach ($name in @(
    'Claude Code - Cockpit Bridge.lnk',
    'Stop Cockpit Claude Bridge.lnk',
    'Diagnose Cockpit Claude Bridge.lnk'
)) {
    Remove-Item (Join-Path $desktop $name) -Force -ErrorAction SilentlyContinue
}

if ($RestoreClaudeSettings) {
    $settingsLinuxPath = "$($config.wsl.home)/.claude/settings.json"
    $settingsPath = Convert-WslPathToUnc -Distro ([string]$config.wsl.distro) -LinuxPath $settingsLinuxPath
    $backup = "${settingsPath}.before-cockpit-bridge.bak"
    if (Test-Path -LiteralPath $backup) {
        Copy-Item -LiteralPath $backup -Destination $settingsPath -Force
        Write-Host 'Restored the pre-bridge Claude settings backup.'
    }
}

$distro = [string]$config.wsl.distro
$launcherPath = [string]$config.wsl.launcherPath
& wsl.exe -d $distro --exec rm -f $launcherPath 2>$null
Write-Host "Uninstall prepared. Delete the installation directory manually after this window closes: $(Get-BridgeRoot)"
Start-Sleep -Seconds 3
