$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$config = Read-BridgeConfig
$root = Get-BridgeRoot
$logDir = Join-Path $root 'logs'

Write-Host '=== Configuration (secrets excluded) ==='
Write-Host "Distro:        $($config.wsl.distro)"
Write-Host "WSL home:      $($config.wsl.home)"
Write-Host "Project:       $($config.wsl.projectDir)"
Write-Host "Claude binary: $($config.wsl.claudeBin)"
Write-Host "Adapter:       127.0.0.1:$($config.adapter.listenPort)"
Write-Host "Sidecar:       127.0.0.1:$($config.adapter.upstreamPort)"

Write-Host "`n=== Listening processes ==="
foreach ($port in @([int]$config.adapter.listenPort, [int]$config.adapter.upstreamPort)) {
    $connections = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $connections) {
        Write-Host "Port $port: not listening"
        continue
    }
    foreach ($connection in $connections) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)"
        Write-Host "Port $port: PID $($connection.OwningProcess) $($process.Name)"
        Write-Host "  $($process.CommandLine)"
    }
}

Write-Host "`n=== Adapter health ==="
try {
    Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$($config.adapter.listenPort)/healthz" -TimeoutSec 5 |
        ConvertTo-Json -Depth 5
} catch {
    Write-Host $_.Exception.Message
}

foreach ($name in @('adapter.out.log', 'adapter.err.log', 'sidecar.out.log', 'sidecar.err.log')) {
    Write-Host "`n=== $name ==="
    Get-Content (Join-Path $logDir $name) -Tail 80 -ErrorAction SilentlyContinue |
        ForEach-Object {
            $_ -replace '(?i)(x-api-key|authorization|anthropic_api_key|anthropic_auth_token)[^,}\s]*', '$1=[REDACTED]'
        }
}

Write-Host "`nPress Enter to close."
[void](Read-Host)
