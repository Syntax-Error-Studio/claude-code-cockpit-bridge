$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$config = Read-BridgeConfig
$root = Get-BridgeRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$exe = [string]$config.windows.cockpitExe
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Cockpit sidecar executable not found: $exe"
}

$outLog = Join-Path $logDir 'sidecar.out.log'
$errLog = Join-Path $logDir 'sidecar.err.log'
$arguments = @(
    '--config', ('"' + [string]$config.windows.sidecarConfig + '"'),
    '--manifest', ('"' + [string]$config.windows.sidecarManifest + '"'),
    '--quota-reserve-state', ('"' + [string]$config.windows.sidecarQuotaState + '"'),
    '--parent-pid', [string]$PID
)

$process = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -Wait -NoNewWindow `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog
exit $process.ExitCode
