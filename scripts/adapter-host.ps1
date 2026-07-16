$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$config = Read-BridgeConfig
$root = Get-BridgeRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$nodeExe = [string]$config.windows.nodeExe
if (-not (Test-Path -LiteralPath $nodeExe)) {
    throw "Node executable not found: $nodeExe"
}

$adapter = Join-Path $root 'src\adapter.mjs'
$configPath = Get-BridgeConfigPath
$outLog = Join-Path $logDir 'adapter.out.log'
$errLog = Join-Path $logDir 'adapter.err.log'

$arguments = @(('"' + $adapter + '"'), '--config', ('"' + $configPath + '"'))
$process = Start-Process -FilePath $nodeExe -ArgumentList $arguments -PassThru -Wait -NoNewWindow `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog
exit $process.ExitCode
