$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$config = Read-BridgeConfig
$root = Get-BridgeRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Configure-ClaudeSettings {
    Write-Host '[1/5] Applying direct Claude configuration...'

    $distro = [string]$config.wsl.distro
    $wslHome = [string]$config.wsl.home
    $settingsLinuxPath = "$wslHome/.claude/settings.json"
    $settingsPath = Convert-WslPathToUnc -Distro $distro -LinuxPath $settingsLinuxPath

    & wsl.exe -d $distro --exec true | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path -LiteralPath $settingsPath)) {
        if ((Get-Date) -ge $deadline) {
            throw "Claude settings not found: $settingsPath"
        }
        Start-Sleep -Milliseconds 500
    }

    $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $settings) { $settings = [pscustomobject]@{} }
    if ($null -eq $settings.PSObject.Properties['env']) {
        $settings | Add-Member -NotePropertyName 'env' -NotePropertyValue ([pscustomobject]@{})
    }

    $envConfig = $settings.env
    $apiKey = [string]$envConfig.ANTHROPIC_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw 'ANTHROPIC_API_KEY is missing from WSL Claude settings. Select the Cockpit provider once in CC Switch or configure the key manually.'
    }

    $backupPath = "${settingsPath}.before-cockpit-bridge.bak"
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $settingsPath -Destination $backupPath -Force
    }

    $baseUrl = "http://127.0.0.1:$($config.adapter.listenPort)"
    $roles = $config.models.claudeRoles
    Set-JsonProperty $envConfig 'ANTHROPIC_BASE_URL' $baseUrl
    Set-JsonProperty $envConfig 'ANTHROPIC_MODEL' ([string]$roles.default)
    Set-JsonProperty $envConfig 'ANTHROPIC_DEFAULT_OPUS_MODEL' ([string]$roles.opus)
    Set-JsonProperty $envConfig 'ANTHROPIC_DEFAULT_OPUS_MODEL_NAME' ([string]$roles.opusDisplayName)
    Set-JsonProperty $envConfig 'ANTHROPIC_DEFAULT_SONNET_MODEL' ([string]$roles.sonnet)
    Set-JsonProperty $envConfig 'ANTHROPIC_DEFAULT_SONNET_MODEL_NAME' ([string]$roles.sonnetDisplayName)
    Set-JsonProperty $envConfig 'ANTHROPIC_DEFAULT_FABLE_MODEL' ([string]$roles.fable)
    Set-JsonProperty $envConfig 'ANTHROPIC_DEFAULT_FABLE_MODEL_NAME' ([string]$roles.fableDisplayName)
    Set-JsonProperty $envConfig 'ANTHROPIC_DEFAULT_HAIKU_MODEL' ([string]$roles.haiku)
    Set-JsonProperty $envConfig 'ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME' ([string]$roles.haikuDisplayName)
    $envConfig.PSObject.Properties.Remove('ANTHROPIC_AUTH_TOKEN')

    $json = $settings | ConvertTo-Json -Depth 100
    Write-Utf8NoBom -Path $settingsPath -Content $json
    & wsl.exe -d $distro --exec chmod 600 $settingsLinuxPath | Out-Null
    return $apiKey
}

function Invoke-BridgeWarmup {
    param([Parameter(Mandatory = $true)][string]$ApiKey)

    $headers = @{
        'x-api-key' = $ApiKey
        'anthropic-version' = '2023-06-01'
    }
    $body = @{
        model = [string]$config.startup.warmupModel
        max_tokens = 8
        messages = @(@{ role = 'user'; content = 'Reply only OK' })
    } | ConvertTo-Json -Depth 8 -Compress

    $uri = "http://127.0.0.1:$($config.adapter.listenPort)/v1/messages"
    $attempts = [int]$config.startup.warmupAttempts
    $delaySeconds = [int]$config.startup.warmupDelaySeconds
    $timeoutSeconds = [int]$config.startup.warmupTimeoutSeconds

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Headers $headers `
                -ContentType 'application/json; charset=utf-8' `
                -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $timeoutSeconds
            if ($response.StatusCode -eq 200) {
                Write-Host "BRIDGE_WARMUP_OK attempt=$attempt"
                return
            }
        } catch {
            $status = 0
            $detail = $_.Exception.Message
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch {}
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $responseBody = $reader.ReadToEnd()
                    if ($responseBody) { $detail = $responseBody }
                } catch {}
            }

            Write-Host "Warm-up attempt $attempt/$attempts failed: HTTP $status $detail"

            if ($detail -match 'auth_unavailable|no auth available') {
                throw @"
Cockpit has no usable account authentication.
Open Cockpit Tools, refresh or wake the API-service accounts, and confirm that at least one account is available.
Do not start a second sidecar on port $($config.adapter.upstreamPort).
"@
            }
        }
        Start-Sleep -Seconds $delaySeconds
    }

    throw "Bridge warm-up failed after $attempts attempts. Run Diagnose Cockpit Claude from the desktop for logs."
}

$apiKey = Configure-ClaudeSettings

Write-Host '[2/5] Starting Cockpit sidecar...'
$upstreamPort = [int]$config.adapter.upstreamPort
if (-not (Test-LocalPort -Port $upstreamPort)) {
    Start-HiddenPowerShell -ScriptPath (Join-Path $PSScriptRoot 'sidecar-host.ps1')
}
if (-not (Wait-LocalPort -Port $upstreamPort -Seconds 30)) {
    throw "Cockpit sidecar port $upstreamPort failed to start."
}

Write-Host '[3/5] Starting Windows adapter...'
$adapterPort = [int]$config.adapter.listenPort
if (-not (Test-LocalPort -Port $adapterPort)) {
    Start-HiddenPowerShell -ScriptPath (Join-Path $PSScriptRoot 'adapter-host.ps1')
}
if (-not (Wait-LocalPort -Port $adapterPort -Seconds 20)) {
    throw "Adapter port $adapterPort failed to start."
}

Write-Host '[4/5] Warming up the direct chain...'
Invoke-BridgeWarmup -ApiKey $apiKey
$null = Configure-ClaudeSettings

Write-Host '[5/5] Launching Claude Code in WSL...'
$distro = [string]$config.wsl.distro
$launcherPath = [string]$config.wsl.launcherPath
$windowTitle = 'Claude Code - Cockpit Bridge'
$terminal = Get-Command wt.exe -ErrorAction SilentlyContinue

if ($terminal) {
    $arguments = @(
        'new-tab', '--title', $windowTitle,
        'wsl.exe', '-d', $distro, '--exec', $launcherPath
    )
    & $terminal.Source @arguments | Out-Null
} else {
    Start-Process -FilePath 'wsl.exe' -ArgumentList @('-d', $distro, '--exec', $launcherPath) | Out-Null
}

Write-Host 'Ready. CC Switch takeover/proxy mode should remain OFF.'
Start-Sleep -Seconds 2
