$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'common.ps1')

$config = Read-BridgeConfig
$ports = @([int]$config.adapter.listenPort, [int]$config.adapter.upstreamPort)

foreach ($port in $ports) {
    Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
}

Start-Sleep -Seconds 1
Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -ieq 'powershell.exe' -and
        ($_.CommandLine -match 'sidecar-host\.ps1' -or $_.CommandLine -match 'adapter-host\.ps1')
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "Stopped adapter port $($config.adapter.listenPort) and sidecar port $($config.adapter.upstreamPort)."
Write-Host 'CC Switch was left untouched.'
Start-Sleep -Seconds 2
